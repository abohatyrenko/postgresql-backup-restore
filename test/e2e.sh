#!/usr/bin/env bash
#
# End-to-end test: builds the image and runs backup/restore against real
# PostgreSQL servers and an S3-compatible endpoint (SeaweedFS) in Docker.
#
# Usage: test/e2e.sh [image-tag]

set -Eeuo pipefail

cd "$(dirname "$0")/.."

IMAGE="${1:-postgresql-backup-restore:e2e}"
SOURCE_PG_VERSION="${SOURCE_PG_VERSION:-14}"
TARGET_PG_VERSION="${TARGET_PG_VERSION:-17}"
S3_IMAGE="${S3_IMAGE:-chrislusf/seaweedfs:latest}"
ID="pgbr-e2e-$$"
NET="$ID"
PASS="s3cr3t:p@ss'word"

log() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

cleanup() {
  docker rm -f "$ID-src" "$ID-dst" "$ID-s3" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_pg() {
  for _ in $(seq 60); do
    docker exec "$1" pg_isready -U postgres -q && return 0
    sleep 1
  done
  fail "postgres $1 did not become ready"
}

psql_in() {
  local container="$1" db="$2" sql="$3"
  docker exec -e PGPASSWORD="$PASS" "$container" psql -U postgres -d "$db" -tAX -v ON_ERROR_STOP=1 -c "$sql"
}

if [[ -z "${SKIP_BUILD:-}" ]]; then
  log "building image $IMAGE"
  docker build -t "$IMAGE" .
fi

AGE_KEY="$(docker run --rm --entrypoint age-keygen "$IMAGE" 2>/dev/null)"
AGE_PUB="$(grep -o 'age1[0-9a-z]*' <<<"$AGE_KEY")"

log "starting postgres ${SOURCE_PG_VERSION} (source), postgres ${TARGET_PG_VERSION} (target) and an S3 server (SeaweedFS)"
docker network create "$NET" >/dev/null
docker run -d --name "$ID-src" --network "$NET" -e POSTGRES_PASSWORD="$PASS" "postgres:${SOURCE_PG_VERSION}-alpine" >/dev/null
docker run -d --name "$ID-dst" --network "$NET" -e POSTGRES_PASSWORD="$PASS" "postgres:${TARGET_PG_VERSION}-alpine" >/dev/null
docker run -d --name "$ID-s3" --network "$NET" \
  -e AWS_ACCESS_KEY_ID=test-key -e AWS_SECRET_ACCESS_KEY=test-secret "$S3_IMAGE" server -s3 -dir=/data >/dev/null
wait_pg "$ID-src"
wait_pg "$ID-dst"

psql_in "$ID-src" postgres "CREATE DATABASE app"
psql_in "$ID-dst" postgres "CREATE DATABASE app_staging"
psql_in "$ID-src" app "
  CREATE TABLE public.users (id serial PRIMARY KEY, name text NOT NULL);
  INSERT INTO public.users (name) SELECT 'user-' || g FROM generate_series(1, 1000) g;
  CREATE SCHEMA billing;
  CREATE TABLE billing.invoices (id serial PRIMARY KEY, user_id int REFERENCES public.users(id), amount numeric);
  INSERT INTO billing.invoices (user_id, amount) SELECT g, g * 1.5 FROM generate_series(1, 500) g;"
# Pre-existing data in the target that must be replaced by the restore
psql_in "$ID-dst" app_staging "CREATE TABLE public.users (id int, name text); INSERT INTO public.users VALUES (-1, 'stale');"

COMMON_ENV=(
  -e AWS_ACCESS_KEY_ID=test-key
  -e AWS_SECRET_ACCESS_KEY=test-secret
  -e S3_ENDPOINT="http://$ID-s3:8333"
  -e AWS_ENDPOINT_URL_S3="http://$ID-s3:8333" # for direct aws calls in this test
  -e S3_BUCKET_PATH=s3://backups/postgresql
  -e PGSSLMODE=disable
  -e BACKUP_DATABASE_NAME=app
  -e POSTGRESQL_BACKUP_HOST="$ID-src"
  -e POSTGRESQL_BACKUP_USER=postgres
  -e PG_PASS_BACKUP="$PASS"
  -e RESTORE_DATABASE_NAME=app_staging
  -e POSTGRESQL_RESTORE_HOST="$ID-dst"
  -e POSTGRESQL_RESTORE_USER=postgres
  -e PG_PASS_RESTORE="$PASS"
)
run() { docker run --rm --network "$NET" --read-only --tmpfs /tmp "${COMMON_ENV[@]}" "$@"; }

bucket_created=""
for _ in $(seq 60); do
  run --entrypoint aws "$IMAGE" s3 mb s3://backups >/dev/null 2>&1 && bucket_created=1 && break
  sleep 1
done
[[ -n "$bucket_created" ]] || fail "could not create S3 bucket"

log "seeding an expired backup for retention test"
run --entrypoint sh "$IMAGE" -c \
  'echo old | aws s3 cp - s3://backups/postgresql/app/app-20200101T000000Z.dump --only-show-errors'

log "backup (encrypted, retention 7 days)"
run -e AGE_RECIPIENTS="$AGE_PUB" -e BACKUP_KEEP_DAYS=7 "$IMAGE" backup

log "list"
listing="$(run "$IMAGE" list)"
echo "$listing"
grep -q 'app-20200101T000000Z.dump' <<<"$listing" && fail "expired backup was not pruned"
grep -qE '^app-[0-9]{8}T[0-9]{6}Z\.dump\.age$' <<<"$listing" || fail "encrypted backup not found"

log "restore without RESTORE_CONFIRM must be refused"
if run -e AGE_IDENTITY="$AGE_KEY" "$IMAGE" restore; then
  fail "restore ran without confirmation"
fi

log "restore without decryption key must fail"
if run -e RESTORE_CONFIRM=app_staging "$IMAGE" restore; then
  fail "restore of encrypted backup succeeded without a key"
fi

log "restore latest backup into app_staging (twice, to check it is repeatable)"
run -e RESTORE_CONFIRM=app_staging -e AGE_IDENTITY="$AGE_KEY" "$IMAGE" restore
run -e RESTORE_CONFIRM=app_staging -e AGE_IDENTITY="$AGE_KEY" "$IMAGE" restore

users="$(psql_in "$ID-dst" app_staging 'SELECT count(*) FROM public.users')"
invoices="$(psql_in "$ID-dst" app_staging 'SELECT count(*) FROM billing.invoices')"
stale="$(psql_in "$ID-dst" app_staging 'SELECT count(*) FROM public.users WHERE id = -1')"
[[ "$users" == 1000 ]] || fail "expected 1000 users, got $users"
[[ "$invoices" == 500 ]] || fail "expected 500 invoices, got $invoices"
[[ "$stale" == 0 ]] || fail "stale data was not replaced"

log "unencrypted backup + restore of a specific file"
run -e PG_DUMP_EXTRA_OPTS="--compress=9" "$IMAGE" backup
file="$(run "$IMAGE" list | grep -E '\.dump$' | tail -n 1)"
run -e RESTORE_CONFIRM=app_staging "$IMAGE" restore "$file"

log "restore into an older server (pg_restore ${TARGET_PG_VERSION} -> postgres ${SOURCE_PG_VERSION})"
psql_in "$ID-src" postgres "CREATE DATABASE app_old"
run -e RESTORE_CONFIRM=app_old -e RESTORE_DATABASE_NAME=app_old -e POSTGRESQL_RESTORE_HOST="$ID-src" "$IMAGE" restore "$file"
users="$(psql_in "$ID-src" app_old 'SELECT count(*) FROM public.users')"
[[ "$users" == 1000 ]] || fail "expected 1000 users in app_old, got $users"

log "failed restore must exit non-zero"
if run -e RESTORE_CONFIRM=app_staging -e POSTGRESQL_RESTORE_USER=nobody "$IMAGE" restore "$file"; then
  fail "restore with bad credentials reported success"
fi

log "restore failing midway must roll back completely"
# A public-only dump cannot --clean public.users while billing.invoices references it
psql_in "$ID-dst" app_staging "INSERT INTO public.users (id, name) VALUES (5000, 'marker')"
run -e PG_DUMP_EXTRA_OPTS="--schema=public" "$IMAGE" backup
if run -e RESTORE_CONFIRM=app_staging "$IMAGE" restore; then
  fail "conflicting restore reported success"
fi
marker="$(psql_in "$ID-dst" app_staging 'SELECT count(*) FROM public.users WHERE id = 5000')"
[[ "$marker" == 1 ]] || fail "failed restore was not rolled back"

log "ALL TESTS PASSED"
