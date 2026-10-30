# PostgreSQL backup/restore to S3

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/postgresql-backup-restore)](https://artifacthub.io/packages/search?repo=postgresql-backup-restore)

Logical backups (`pg_dump`, custom format) of a PostgreSQL database to any S3-compatible storage
(AWS S3, DigitalOcean Spaces, MinIO, ...) and restore from them. Ships as a Docker image and a Helm chart
that runs backups as a Kubernetes CronJob.

Features:

- PostgreSQL 17 client tools: backs up servers from 9.2 to 17, restores into older servers too (as long as the dump uses no newer features)
- every dump is validated with `pg_restore --list`, and the uploaded object size is verified
- optional client-side encryption with [age](https://age-encryption.org)
- retention (`BACKUP_KEEP_DAYS`)
- atomic restore (single transaction): a failed restore leaves the target database untouched
- restore guard: a restore only runs when `RESTORE_CONFIRM` equals the target database name
- Slack notifications and heartbeat pings (healthchecks.io, Better Stack, Cronitor, ...)
- TLS required by default (`PGSSLMODE=require`)
- AWS credentials from env vars or the default credential chain (IRSA, instance profile, ...)
- non-root, read-only root filesystem friendly image for `linux/amd64` and `linux/arm64`

## Usage

```sh
docker run --rm \
  -e AWS_ACCESS_KEY_ID=... -e AWS_SECRET_ACCESS_KEY=... \
  -e S3_BUCKET_PATH=s3://my-bucket/postgresql \
  -e BACKUP_DATABASE_NAME=app \
  -e POSTGRESQL_BACKUP_HOST=db.example.com \
  -e POSTGRESQL_BACKUP_USER=backup \
  -e PG_PASS_BACKUP=... \
  abohatyrenko/postgresql-backup-restore backup
```

Commands:

| Command | Description |
|---|---|
| `backup` | Dump `BACKUP_DATABASE_NAME` and upload it to `S3_BUCKET_PATH/<db>/<db>-<YYYYmmddTHHMMSSZ>.dump[.age]` |
| `restore [file]` | Restore the latest backup (or the given file name) of `RESTORE_SOURCE_NAME` into `RESTORE_DATABASE_NAME` |
| `list [db]` | List backups, oldest first |

The script also runs outside Docker; it needs `bash`, `pg_dump`/`pg_restore`/`psql`, `aws` CLI v2, `curl` and, for encryption, `age`.

### Configuration

**Storage**

| Variable | Default | Description |
|---|---|---|
| `S3_BUCKET_PATH` | (required) | e.g. `s3://my-bucket/postgresql` |
| `S3_ENDPOINT` | AWS | Endpoint of S3-compatible storage, e.g. `https://fra1.digitaloceanspaces.com` |
| `AWS_REGION` | `eu-central-1` | |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | | Optional, any [AWS CLI credential source](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-authentication.html) works |
| `S3_UPLOAD_EXTRA_OPTS` | | Extra `aws s3 cp` options, e.g. `--sse AES256 --storage-class STANDARD_IA` |

**Backup**

| Variable | Default | Description |
|---|---|---|
| `BACKUP_DATABASE_NAME` | (required) | |
| `POSTGRESQL_BACKUP_HOST` | (required) | |
| `POSTGRESQL_BACKUP_PORT` | `5432` | DigitalOcean managed databases use `25060` |
| `POSTGRESQL_BACKUP_USER` | (required) | |
| `PG_PASS_BACKUP` | | |
| `PG_DUMP_EXTRA_OPTS` | | e.g. `--schema=public` or `--exclude-table-data=audit_log` |
| `BACKUP_KEEP_DAYS` | `0` (keep all) | Delete backups older than N days after a successful backup. The newest backup is never deleted |
| `AGE_RECIPIENTS` | | age public key(s), comma or space separated. When set, backups are encrypted |

**Restore**

| Variable | Default | Description |
|---|---|---|
| `RESTORE_DATABASE_NAME` | (required) | Target database, must exist |
| `RESTORE_CONFIRM` | (required) | Must equal `RESTORE_DATABASE_NAME` |
| `RESTORE_SOURCE_NAME` | `BACKUP_DATABASE_NAME`, else `RESTORE_DATABASE_NAME` | Which database's backups to restore, e.g. restore `app` backups into `app_staging` |
| `POSTGRESQL_RESTORE_HOST` | (required) | |
| `POSTGRESQL_RESTORE_PORT` | `5432` | |
| `POSTGRESQL_RESTORE_USER` | (required) | |
| `PG_PASS_RESTORE` | | |
| `RESTORE_ROLE` | | Run the restore as this role (`SET ROLE`), so restored objects are owned by it |
| `RESTORE_CLEAN` | `true` | Drop existing objects before restoring them |
| `RESTORE_NO_OWNER` / `RESTORE_NO_PRIVILEGES` | `true` | Skip ownership / GRANTs from the dump (useful when roles differ between environments) |
| `RESTORE_SINGLE_TRANSACTION` | `true` | All or nothing |
| `PG_RESTORE_EXTRA_OPTS` | | Extra `pg_restore` options |
| `AGE_IDENTITY` / `AGE_IDENTITY_FILE` | | age secret key (content or file path) to decrypt `.age` backups |

**Connection, notifications**

| Variable | Default | Description |
|---|---|---|
| `PGSSLMODE` | `require` | Use `verify-full` with `PGSSLROOTCERT` to also verify the server certificate (DigitalOcean provides a CA certificate) |
| `PGSSLROOTCERT`, `PGCONNECT_TIMEOUT`, ... | | Any [libpq environment variable](https://www.postgresql.org/docs/current/libpq-envars.html) |
| `SLACK_WEBHOOK_URL` | | Slack incoming webhook |
| `NOTIFY_ON` | `failure` | `failure`, `always` or `never` |
| `HEARTBEAT_URL` | | Pinged after every successful backup. Use a dead man's switch to get alerted when backups stop running at all |
| `HEARTBEAT_FAIL_URL` | | Pinged when a backup fails, e.g. `https://hc-ping.com/<uuid>/fail` |
| `WORK_DIR` | `/tmp/pg-backup-restore` | Scratch space; needs room for the full dump |

### Encryption

```sh
docker run --rm --entrypoint age-keygen abohatyrenko/postgresql-backup-restore
# Public key: age1...        -> AGE_RECIPIENTS for backups
# AGE-SECRET-KEY-1...        -> AGE_IDENTITY for restores, store it somewhere safe outside the cluster
```

Only the public key is needed to make backups, so a compromised backup job cannot read old backups.

### Restoring

```sh
docker run --rm \
  -e S3_BUCKET_PATH=s3://my-bucket/postgresql \
  -e RESTORE_SOURCE_NAME=app \
  -e RESTORE_DATABASE_NAME=app_staging -e RESTORE_CONFIRM=app_staging \
  -e POSTGRESQL_RESTORE_HOST=staging-db.example.com \
  -e POSTGRESQL_RESTORE_USER=app_staging -e PG_PASS_RESTORE=... \
  abohatyrenko/postgresql-backup-restore restore                 # latest
  # ...                                   restore app-20261030T110000Z.dump
```

Test your restores regularly, e.g. with a scheduled restore into a scratch database.

## Recommendations for production

- Enable versioning and Object Lock (or at least a lifecycle rule) on the bucket, and give the backup
  credentials only `s3:PutObject`, `s3:GetObject`, `s3:ListBucket` (+ `s3:DeleteObject` if `BACKUP_KEEP_DAYS` is used).
- Use a database role with read-only access for backups.
- Set `HEARTBEAT_URL` or alert on failed Kubernetes Jobs (e.g. `kube_job_status_failed` from kube-state-metrics).
- Logical dumps give daily (or hourly) restore points. If you need point-in-time recovery,
  use the provider's PITR or WAL archiving tools ([WAL-G](https://github.com/wal-g/wal-g), [pgBackRest](https://pgbackrest.org)) in addition.

## Helm chart

See the [chart README](helm/README.md).

## What is tested

Every CI run executes [`test/e2e.sh`](test/e2e.sh) against real PostgreSQL servers and an S3-compatible
server ([SeaweedFS](https://github.com/seaweedfs/seaweedfs)) in Docker, in both version directions (13 → 17, 17 → 16):

- encrypted and plain backup/restore, retention, restore of the latest or a specific backup, repeated restores
- restore into an older server, rollback of a restore that fails midway
- restore guard, missing decryption key and bad credentials fail the job
- TLS: `verify-full` with a CA certificate; an unknown CA, a host name mismatch and a server without TLS are rejected
- AWS credentials from a shared credentials file instead of environment variables; no credentials fail the job

The Helm chart is linted and validated with kubeconform, and was tested manually in a kind cluster.

Not tested yet (should work, feedback welcome): DigitalOcean Spaces and other hosted S3-compatible storage,
managed PostgreSQL services, IRSA / EKS Pod Identity (credentials come from the standard AWS CLI credential chain).

## Development

```sh
docker build -t postgresql-backup-restore .
test/e2e.sh   # see "What is tested" above
```

Older PostgreSQL client versions: `docker build --build-arg PG_VERSION=16 .`

### Release

1. Push a `vX.Y.Z` tag: CI runs the tests and publishes the multi-arch image to Docker Hub.
   Release candidates (`vX.Y.Z-rc.N`) are published without the `latest` and `X.Y` tags.
2. Bump `version` / `appVersion` in `helm/Chart.yaml`, then publish the chart:

```sh
cd helm/packages
helm package ../
cd ../
helm repo index . --url https://abohatyrenko.github.io/postgresql-backup-restore/helm/ --merge index.yaml
```

Pre-release chart versions (e.g. `1.0.0-rc.1`) are only installed with `--devel` or an explicit `--version`.

## Upgrading to 1.0.0 (image 0.x / chart 0.1.x)

- Backup files are now named `<db>-<YYYYmmddTHHMMSSZ>.dump` (several backups per day, correct extension).
  Old `*.tar.gz` backups can still be listed and restored by name. Retention only deletes files using the new naming.
- The whole database is dumped. Set `PG_DUMP_EXTRA_OPTS=--schema=public` for the previous behaviour.
- `S3_BUCKET_PATH`, `BACKUP_DATABASE_NAME`, hosts and users have no defaults anymore; ports default to `5432`
  (set `25060` for DigitalOcean).
- `PGSSLMODE` defaults to `require` (was `allow`).
- Restore requires `RESTORE_CONFIRM`, fails on errors instead of reporting success, and restores backups of
  `RESTORE_SOURCE_NAME` (defaults to `BACKUP_DATABASE_NAME`). The `--role=<db name>` restore option is now opt-in via `RESTORE_ROLE`.
- The image entrypoint is the script itself: pass `backup` / `restore` as arguments.
- Chart values: `app.cronSchedule` → `backup.schedule`, `jobAnnotations` → `podAnnotations`,
  `command`/`args` → `backup.args` / `restore.args`, `notificationSlack` → `secrets.slack_webhook_url` + `deployNotification.enabled`.
