#!/usr/bin/env bash
#
# Logical backup/restore of a PostgreSQL database to/from S3-compatible storage.
#
# Usage:
#   pg_backup_restore.sh backup
#   pg_backup_restore.sh restore [backup-file-name]   # latest backup if omitted
#   pg_backup_restore.sh list
#
# All configuration is done through environment variables, see README.md.
# *_EXTRA_OPTS values are split on whitespace, so a single option value can't contain spaces.

set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="${0##*/}"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Storage
S3_BUCKET_PATH="${S3_BUCKET_PATH:-}"
S3_BUCKET_PATH="${S3_BUCKET_PATH%/}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_PROVIDER="${S3_PROVIDER:-}"
S3_UPLOAD_EXTRA_OPTS="${S3_UPLOAD_EXTRA_OPTS:-}"
export AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}"

# Backup source
BACKUP_DATABASE_NAME="${BACKUP_DATABASE_NAME:-}"
POSTGRESQL_BACKUP_HOST="${POSTGRESQL_BACKUP_HOST:-}"
POSTGRESQL_BACKUP_PORT="${POSTGRESQL_BACKUP_PORT:-5432}"
POSTGRESQL_BACKUP_USER="${POSTGRESQL_BACKUP_USER:-}"
PG_PASS_BACKUP="${PG_PASS_BACKUP:-}"
PG_DUMP_EXTRA_OPTS="${PG_DUMP_EXTRA_OPTS:-}"
BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-0}"

# Restore target
RESTORE_DATABASE_NAME="${RESTORE_DATABASE_NAME:-}"
RESTORE_SOURCE_NAME="${RESTORE_SOURCE_NAME:-${BACKUP_DATABASE_NAME:-$RESTORE_DATABASE_NAME}}"
POSTGRESQL_RESTORE_HOST="${POSTGRESQL_RESTORE_HOST:-}"
POSTGRESQL_RESTORE_PORT="${POSTGRESQL_RESTORE_PORT:-5432}"
POSTGRESQL_RESTORE_USER="${POSTGRESQL_RESTORE_USER:-}"
PG_PASS_RESTORE="${PG_PASS_RESTORE:-}"
RESTORE_CONFIRM="${RESTORE_CONFIRM:-}"
RESTORE_ROLE="${RESTORE_ROLE:-}"
RESTORE_CLEAN="${RESTORE_CLEAN:-true}"
RESTORE_NO_OWNER="${RESTORE_NO_OWNER:-true}"
RESTORE_NO_PRIVILEGES="${RESTORE_NO_PRIVILEGES:-true}"
RESTORE_SINGLE_TRANSACTION="${RESTORE_SINGLE_TRANSACTION:-true}"
PG_RESTORE_EXTRA_OPTS="${PG_RESTORE_EXTRA_OPTS:-}"

# Encryption (https://age-encryption.org)
AGE_RECIPIENTS="${AGE_RECIPIENTS:-}"
AGE_IDENTITY="${AGE_IDENTITY:-}"
AGE_IDENTITY_FILE="${AGE_IDENTITY_FILE:-}"

# Notifications
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
NOTIFY_ON="${NOTIFY_ON:-failure}" # failure | always | never
HEARTBEAT_URL="${HEARTBEAT_URL:-}"
HEARTBEAT_FAIL_URL="${HEARTBEAT_FAIL_URL:-}"

WORK_DIR="${WORK_DIR:-/tmp/pg-backup-restore}"

# Never fall back to an unencrypted connection unless explicitly asked to.
export PGSSLMODE="${PGSSLMODE:-require}"
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-30}"

# S3 is accessed with rclone. s3://bucket/path stands for an rclone S3 remote that takes
# credentials from the AWS credential chain (AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY, shared
# credentials file, IRSA / EKS Pod Identity, instance profile) and S3_ENDPOINT / AWS_REGION.
# No rclone config file is needed; without one rclone prints a notice on every call.
export RCLONE_CONFIG="${RCLONE_CONFIG:-/dev/null}"
export RCLONE_CONFIG_S3URL_TYPE=s3
export RCLONE_CONFIG_S3URL_ENV_AUTH=true
export RCLONE_CONFIG_S3URL_REGION="$AWS_REGION"
# Backup credentials usually may not create buckets
export RCLONE_CONFIG_S3URL_NO_CHECK_BUCKET=true
if [[ -n "$S3_ENDPOINT" ]]; then
  export RCLONE_CONFIG_S3URL_PROVIDER="${S3_PROVIDER:-Other}"
  export RCLONE_CONFIG_S3URL_ENDPOINT="$S3_ENDPOINT"
  # Outside AWS there is no instance profile. Without credentials the AWS SDK would retry
  # the EC2 metadata endpoint for minutes before failing.
  export AWS_EC2_METADATA_DISABLED="${AWS_EC2_METADATA_DISABLED:-true}"
else
  export RCLONE_CONFIG_S3URL_PROVIDER="${S3_PROVIDER:-AWS}"
fi

COMMAND="${1:-}"
TMP_DIR=""
SUMMARY=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${*:2}" >&2; }
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
die() { log ERROR "$@"; exit 1; }

require_env() {
  local name missing=()
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || missing+=("$name")
  done
  ((${#missing[@]} == 0)) || die "missing required environment variable(s): ${missing[*]}"
}

is_true() { [[ "${1,,}" =~ ^(1|true|yes|on)$ ]]; }

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

notify_slack() {
  [[ -n "$SLACK_WEBHOOK_URL" ]] || return 0
  curl -fsS -m 15 --retry 3 -H 'Content-Type: application/json' \
    -d "{\"text\": \"$(json_escape "$1")\"}" "$SLACK_WEBHOOK_URL" >/dev/null \
    || warn "failed to send Slack notification"
}

ping_url() {
  [[ -n "$1" ]] || return 0
  curl -fsS -m 15 --retry 3 "$1" >/dev/null || warn "failed to ping heartbeat URL"
}

on_exit() {
  local rc=$?
  [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf -- "$TMP_DIR"
  case "$COMMAND" in backup | restore) ;; *) return "$rc" ;; esac

  local context="${COMMAND}${SUMMARY:+ ${SUMMARY}}"
  if ((rc == 0)); then
    [[ "$NOTIFY_ON" == "always" ]] && notify_slack ":white_check_mark: ${context} succeeded"
    [[ "$COMMAND" == "backup" ]] && ping_url "$HEARTBEAT_URL"
  else
    log ERROR "${context} failed with exit code ${rc}"
    [[ "$NOTIFY_ON" != "never" ]] && notify_slack ":x: ${context} FAILED (exit code ${rc}), check the job logs"
    [[ "$COMMAND" == "backup" ]] && ping_url "$HEARTBEAT_FAIL_URL"
  fi
  return "$rc"
}
trap on_exit EXIT

make_tmp_dir() {
  mkdir -p -- "$WORK_DIR"
  TMP_DIR="$(mktemp -d "${WORK_DIR}/run.XXXXXX")"
}

# rclone with s3://bucket/path arguments translated to the "s3url" remote, so that
# logs and messages can use the paths as the user wrote them
rcl() {
  local arg args=()
  for arg in "$@"; do
    [[ "$arg" == s3://* ]] && arg="s3url:${arg#s3://}"
    args+=("$arg")
  done
  rclone "${args[@]}"
}

# Prints backup file names under s3 "directory" $1, oldest first (by upload time, not by name).
# A directory that does not exist yet has no backups; any other listing error is fatal,
# so that a restore never reports "no backups" because the bucket was not readable.
# *.tar.gz are backups from image 0.x: custom-format dumps despite the extension, so pg_restore reads them.
list_backups() {
  local listing status=0
  listing="$(rcl lsf --files-only --use-server-modtime --format tp --separator $'\t' "${1}/")" || status=$?
  # rclone exit code 3: directory not found
  ((status == 0 || status == 3)) || die "cannot list ${1}/ (rclone exit code ${status})"
  sort -t $'\t' -k1,1 <<<"$listing" | cut -f2- | grep -E '\.(dump|dump\.age|tar\.gz)$' || true
}

# S3_UPLOAD_EXTRA_OPTS took `aws s3 cp` options before 2.0.0. Checked before the dump,
# which may take hours, instead of failing at the upload.
check_upload_opts() {
  local opt opts=()
  read -r -a opts <<<"$S3_UPLOAD_EXTRA_OPTS"
  for opt in "${opts[@]}"; do
    case "${opt%%=*}" in
      --sse | --sse-c | --sse-c-key | --sse-kms-key-id | --storage-class | --acl | --grants | --content-type | --cache-control | --expires)
        die "S3_UPLOAD_EXTRA_OPTS has the aws-cli option ${opt%%=*}; since image 2.0.0 it takes rclone flags, e.g. --s3-server-side-encryption AES256 --s3-storage-class STANDARD_IA (https://rclone.org/s3/)"
        ;;
    esac
  done
}

validate_dump() {
  info "validating dump archive"
  pg_restore --list "$1" >/dev/null || die "dump archive is not readable by pg_restore"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

do_backup() {
  require_env S3_BUCKET_PATH BACKUP_DATABASE_NAME POSTGRESQL_BACKUP_HOST POSTGRESQL_BACKUP_USER
  [[ "$BACKUP_KEEP_DAYS" =~ ^[0-9]+$ ]] || die "BACKUP_KEEP_DAYS must be a non-negative integer"
  check_upload_opts

  local timestamp file_name s3_dir local_file upload_file s3_target
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  file_name="${BACKUP_DATABASE_NAME}-${timestamp}.dump"
  s3_dir="${S3_BUCKET_PATH}/${BACKUP_DATABASE_NAME}"
  SUMMARY="of ${BACKUP_DATABASE_NAME}@${POSTGRESQL_BACKUP_HOST}"

  make_tmp_dir
  local_file="${TMP_DIR}/${file_name}"

  local -a dump_opts=()
  read -r -a dump_opts <<<"$PG_DUMP_EXTRA_OPTS"

  info "dumping ${BACKUP_DATABASE_NAME} from ${POSTGRESQL_BACKUP_HOST}:${POSTGRESQL_BACKUP_PORT} (sslmode=${PGSSLMODE})"
  PGPASSWORD="$PG_PASS_BACKUP" pg_dump \
    --host="$POSTGRESQL_BACKUP_HOST" \
    --port="$POSTGRESQL_BACKUP_PORT" \
    --username="$POSTGRESQL_BACKUP_USER" \
    --dbname="$BACKUP_DATABASE_NAME" \
    --format=custom \
    --no-password \
    --file="$local_file" \
    "${dump_opts[@]}"

  validate_dump "$local_file"

  upload_file="$local_file"
  if [[ -n "$AGE_RECIPIENTS" ]]; then
    local -a recipients=() age_args=()
    local r
    read -r -a recipients <<<"${AGE_RECIPIENTS//,/ }"
    for r in "${recipients[@]}"; do age_args+=(--recipient "$r"); done
    info "encrypting dump for ${#recipients[@]} age recipient(s)"
    age "${age_args[@]}" --output "${local_file}.age" "$local_file"
    rm -f -- "$local_file"
    upload_file="${local_file}.age"
  fi

  s3_target="${s3_dir}/${upload_file##*/}"
  local -a upload_opts=()
  read -r -a upload_opts <<<"$S3_UPLOAD_EXTRA_OPTS"
  info "uploading $(du -h "$upload_file" | cut -f1) to ${s3_target}"
  # rclone compares size and checksum of the uploaded object with the local file
  rcl copyto "${upload_opts[@]}" "$upload_file" "$s3_target"

  SUMMARY="${SUMMARY} -> ${s3_target}"
  [[ "$BACKUP_KEEP_DAYS" -gt 0 ]] && prune_backups "$s3_dir"

  info "backup finished: ${s3_target}"
}

# Deletes backups older than BACKUP_KEEP_DAYS. Only files following the
# <db>-<YYYYmmddTHHMMSSZ>.dump[.age] naming are considered; the newest backup is always kept.
prune_backups() {
  local s3_dir="$1" cutoff listing name ts newest
  cutoff="$(date -u -d "-${BACKUP_KEEP_DAYS} days" +%Y%m%dT%H%M%SZ)"
  # Not read in a process substitution, where a listing error would not stop the script
  listing="$(list_backups "$s3_dir")"
  newest="$(tail -n 1 <<<"$listing")"
  info "removing backups older than ${BACKUP_KEEP_DAYS} day(s) (before ${cutoff})"

  local pattern="^${BACKUP_DATABASE_NAME//./\\.}-([0-9]{8}T[0-9]{6}Z)\\.dump(\\.age)?$"
  while IFS= read -r name; do
    [[ "$name" =~ $pattern ]] || continue
    ts="${BASH_REMATCH[1]}"
    if [[ "$ts" < "$cutoff" && "$name" != "$newest" ]]; then
      info "deleting expired backup ${name}"
      rcl deletefile "${s3_dir}/${name}"
    fi
  done <<<"$listing"
}

do_restore() {
  require_env S3_BUCKET_PATH RESTORE_DATABASE_NAME RESTORE_SOURCE_NAME POSTGRESQL_RESTORE_HOST POSTGRESQL_RESTORE_USER
  [[ "$RESTORE_CONFIRM" == "$RESTORE_DATABASE_NAME" ]] \
    || die "restore overwrites ${RESTORE_DATABASE_NAME}@${POSTGRESQL_RESTORE_HOST}; set RESTORE_CONFIRM=${RESTORE_DATABASE_NAME} to proceed"

  local s3_dir="${S3_BUCKET_PATH}/${RESTORE_SOURCE_NAME}" file_name="${1:-}" local_file listing
  SUMMARY="of ${RESTORE_DATABASE_NAME}@${POSTGRESQL_RESTORE_HOST}"

  if [[ -z "$file_name" ]]; then
    listing="$(list_backups "$s3_dir")"
    file_name="$(tail -n 1 <<<"$listing")"
    [[ -n "$file_name" ]] || die "no backups found in ${s3_dir}/"
    info "no backup file given, using latest: ${file_name}"
  fi
  SUMMARY="${SUMMARY} from ${file_name}"

  make_tmp_dir
  local_file="${TMP_DIR}/${file_name}"

  info "downloading ${s3_dir}/${file_name}"
  rcl copyto "${s3_dir}/${file_name}" "$local_file"

  if [[ "$local_file" == *.age ]]; then
    local identity_file="$AGE_IDENTITY_FILE"
    if [[ -z "$identity_file" ]]; then
      [[ -n "$AGE_IDENTITY" ]] || die "backup is encrypted, set AGE_IDENTITY or AGE_IDENTITY_FILE"
      identity_file="${TMP_DIR}/identity.txt"
      printf '%s\n' "$AGE_IDENTITY" >"$identity_file"
    fi
    info "decrypting backup"
    age --decrypt --identity "$identity_file" --output "${local_file%.age}" "$local_file"
    rm -f -- "$local_file"
    local_file="${local_file%.age}"
  fi

  validate_dump "$local_file"

  local -a restore_opts=() psql_opts=()
  is_true "$RESTORE_CLEAN" && restore_opts+=(--clean --if-exists)
  is_true "$RESTORE_NO_OWNER" && restore_opts+=(--no-owner)
  is_true "$RESTORE_NO_PRIVILEGES" && restore_opts+=(--no-privileges)
  is_true "$RESTORE_SINGLE_TRANSACTION" && psql_opts+=(--single-transaction)
  [[ -n "$RESTORE_ROLE" ]] && restore_opts+=(--role="$RESTORE_ROLE")
  local -a extra_opts=()
  read -r -a extra_opts <<<"$PG_RESTORE_EXTRA_OPTS"

  # pg_restore renders SQL and psql applies it, instead of pg_restore connecting
  # directly: a newer pg_restore emits settings older servers reject
  # (e.g. "SET transaction_timeout" from v17), which are dropped from the preamble here.
  # The preamble is a few dozen lines; only the first 100 are filtered so a table row
  # that happens to look like this setting is never touched.
  info "restoring into ${RESTORE_DATABASE_NAME} on ${POSTGRESQL_RESTORE_HOST}:${POSTGRESQL_RESTORE_PORT} (sslmode=${PGSSLMODE})"
  pg_restore --file=- "${restore_opts[@]}" "${extra_opts[@]}" "$local_file" \
    | awk 'NR <= 100 && /^SET transaction_timeout = /{ next } { print }' \
    | PGPASSWORD="$PG_PASS_RESTORE" psql \
      --host="$POSTGRESQL_RESTORE_HOST" \
      --port="$POSTGRESQL_RESTORE_PORT" \
      --username="$POSTGRESQL_RESTORE_USER" \
      --dbname="$RESTORE_DATABASE_NAME" \
      --no-password \
      --no-psqlrc \
      --quiet \
      --set=ON_ERROR_STOP=1 \
      "${psql_opts[@]}" \
      >/dev/null

  info "restore finished: ${RESTORE_DATABASE_NAME} from ${file_name}"
}

do_list() {
  require_env S3_BUCKET_PATH
  local name="${1:-${BACKUP_DATABASE_NAME:-$RESTORE_SOURCE_NAME}}"
  [[ -n "$name" ]] || die "pass a database name or set BACKUP_DATABASE_NAME"
  list_backups "${S3_BUCKET_PATH}/${name}"
}

usage() {
  cat >&2 <<EOF
Usage:
  ${SCRIPT_NAME} backup                 dump BACKUP_DATABASE_NAME and upload it to S3
  ${SCRIPT_NAME} restore [file-name]    restore RESTORE_DATABASE_NAME (latest backup if no file given)
  ${SCRIPT_NAME} list [database-name]   list available backups, oldest first
EOF
}

case "$COMMAND" in
  backup) do_backup ;;
  restore) do_restore "${2:-}" ;;
  list) do_list "${2:-}" ;;
  -h | --help | help) usage ;;
  *) usage; exit 64 ;;
esac
