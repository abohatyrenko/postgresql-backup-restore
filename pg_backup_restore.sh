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

# Recent AWS CLI versions send CRC checksums by default, which many S3-compatible
# providers (DigitalOcean Spaces, older MinIO, ...) reject.
if [[ -n "$S3_ENDPOINT" ]]; then
  export AWS_ENDPOINT_URL_S3="$S3_ENDPOINT"
  export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"
  export AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}"
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

# Prints backup file names under s3 "directory" $1, oldest first.
list_backups() {
  aws s3 ls "${1}/" \
    | awk '$1 != "PRE" { line=$0; sub(/^[^ ]+ +[^ ]+ +[^ ]+ +/, "", line); print $1 " " $2 " " line }' \
    | sort -k1,1 -k2,2 \
    | cut -d' ' -f3- \
    | grep -E '\.(dump|dump\.age|tar\.gz)$' || true
}

remote_size() {
  aws s3 ls "$1" | awk '{ print $3; exit }'
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

do_backup() {
  require_env S3_BUCKET_PATH BACKUP_DATABASE_NAME POSTGRESQL_BACKUP_HOST POSTGRESQL_BACKUP_USER
  [[ "$BACKUP_KEEP_DAYS" =~ ^[0-9]+$ ]] || die "BACKUP_KEEP_DAYS must be a non-negative integer"

  local timestamp file_name s3_dir local_file upload_file s3_target local_size uploaded_size
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

  info "validating dump archive"
  pg_restore --list "$local_file" >/dev/null || die "dump archive is not readable by pg_restore"

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
  aws s3 cp --no-progress --only-show-errors "${upload_opts[@]}" "$upload_file" "$s3_target"

  local_size="$(stat -c %s "$upload_file")"
  uploaded_size="$(remote_size "$s3_target")"
  [[ "$uploaded_size" == "$local_size" ]] \
    || die "uploaded object size (${uploaded_size:-missing}) does not match local file size (${local_size})"
  info "upload verified (${local_size} bytes)"

  SUMMARY="${SUMMARY} -> ${s3_target}"
  [[ "$BACKUP_KEEP_DAYS" -gt 0 ]] && prune_backups "$s3_dir"

  info "backup finished: ${s3_target}"
}

# Deletes backups older than BACKUP_KEEP_DAYS. Only files following the
# <db>-<YYYYmmddTHHMMSSZ>.dump[.age] naming are considered; the newest backup is always kept.
prune_backups() {
  local s3_dir="$1" cutoff name ts newest
  cutoff="$(date -u -d "-${BACKUP_KEEP_DAYS} days" +%Y%m%dT%H%M%SZ)"
  newest="$(list_backups "$s3_dir" | tail -n 1)"
  info "removing backups older than ${BACKUP_KEEP_DAYS} day(s) (before ${cutoff})"

  local pattern="^${BACKUP_DATABASE_NAME//./\\.}-([0-9]{8}T[0-9]{6}Z)\\.dump(\\.age)?$"
  while IFS= read -r name; do
    [[ "$name" =~ $pattern ]] || continue
    ts="${BASH_REMATCH[1]}"
    if [[ "$ts" < "$cutoff" && "$name" != "$newest" ]]; then
      info "deleting expired backup ${name}"
      aws s3 rm --only-show-errors "${s3_dir}/${name}"
    fi
  done < <(list_backups "$s3_dir")
}

do_restore() {
  require_env S3_BUCKET_PATH RESTORE_DATABASE_NAME RESTORE_SOURCE_NAME POSTGRESQL_RESTORE_HOST POSTGRESQL_RESTORE_USER
  [[ "$RESTORE_CONFIRM" == "$RESTORE_DATABASE_NAME" ]] \
    || die "restore overwrites ${RESTORE_DATABASE_NAME}@${POSTGRESQL_RESTORE_HOST}; set RESTORE_CONFIRM=${RESTORE_DATABASE_NAME} to proceed"

  local s3_dir="${S3_BUCKET_PATH}/${RESTORE_SOURCE_NAME}" file_name="${1:-}" local_file
  SUMMARY="of ${RESTORE_DATABASE_NAME}@${POSTGRESQL_RESTORE_HOST}"

  if [[ -z "$file_name" ]]; then
    file_name="$(list_backups "$s3_dir" | tail -n 1)"
    [[ -n "$file_name" ]] || die "no backups found in ${s3_dir}/"
    info "no backup file given, using latest: ${file_name}"
  fi
  SUMMARY="${SUMMARY} from ${file_name}"

  make_tmp_dir
  local_file="${TMP_DIR}/${file_name}"

  info "downloading ${s3_dir}/${file_name}"
  aws s3 cp --no-progress --only-show-errors "${s3_dir}/${file_name}" "$local_file"

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

  info "validating dump archive"
  pg_restore --list "$local_file" >/dev/null || die "dump archive is not readable by pg_restore"

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
  local name="${2:-${BACKUP_DATABASE_NAME:-$RESTORE_SOURCE_NAME}}"
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
  list) do_list "$@" ;;
  -h | --help | help) usage ;;
  *) usage; exit 64 ;;
esac
