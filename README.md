# PostgreSQL backup/restore to S3

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/postgresql-backup-restore)](https://artifacthub.io/packages/search?repo=postgresql-backup-restore)
[![security-scan](https://github.com/abohatyrenko/postgresql-backup-restore/actions/workflows/security-scan.yml/badge.svg)](https://github.com/abohatyrenko/postgresql-backup-restore/actions/workflows/security-scan.yml)

Logical backups (`pg_dump`, custom format) of a PostgreSQL database to any S3-compatible storage
(AWS S3, DigitalOcean Spaces, MinIO, ...) and restore from them. Ships as a Docker image and a Helm chart
that runs backups as a Kubernetes CronJob.

Features:

- PostgreSQL 18 client tools: backs up servers from 9.2 to 18, restores into older servers too (as long as the dump uses no newer features)
- every dump is validated with `pg_restore --list`, rclone verifies size and checksum of the upload
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
  -e BACKUP_DATABASE=app \
  -e BACKUP_HOST=db.example.com \
  -e BACKUP_USER=backup \
  -e BACKUP_PASSWORD=... \
  abohatyrenko/postgresql-backup-restore backup
```

Commands:

| Command | Description |
|---|---|
| `backup` | Dump `BACKUP_DATABASE` and upload it to `S3_BUCKET_PATH/<db>/<db>-<YYYYmmddTHHMMSSZ>.dump[.age]` |
| `restore [file]` | Restore the latest backup (or the given file name) of `RESTORE_SOURCE_DATABASE` into `RESTORE_DATABASE` |
| `list [db]` | List backups, oldest first |

The script also runs outside Docker; it needs `bash`, `pg_dump`/`pg_restore`/`psql`, [rclone](https://rclone.org), `curl` and, for encryption, `age`.

### Configuration

**Storage**

| Variable | Default | Description |
|---|---|---|
| `S3_BUCKET_PATH` | (required) | e.g. `s3://my-bucket/postgresql` |
| `S3_ENDPOINT` | AWS | Endpoint of S3-compatible storage, e.g. `https://fra1.digitaloceanspaces.com` |
| `S3_PROVIDER` | `AWS`, or `Other` with `S3_ENDPOINT` | rclone [S3 provider](https://rclone.org/s3/#s3-provider), e.g. `DigitalOcean`, `Minio`, `Cloudflare` |
| `AWS_REGION` | | Region of the bucket. Required on AWS unless the bucket is in `us-east-1` |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | | Optional, any [AWS SDK credential source](https://docs.aws.amazon.com/sdkref/latest/guide/standardized-credentials.html) works: shared credentials file, IRSA, EKS Pod Identity, instance profile. With `S3_ENDPOINT` the EC2 instance profile is off (`AWS_EC2_METADATA_DISABLED=true`) unless set otherwise |
| `S3_UPLOAD_EXTRA_OPTS` | | Extra [rclone flags](https://rclone.org/s3/) for the upload, e.g. `--s3-server-side-encryption AES256 --s3-storage-class STANDARD_IA` |
| `RCLONE_<FLAG>` | | Any [rclone flag](https://rclone.org/flags/) for all S3 calls, e.g. `RCLONE_BWLIMIT=10M`, `RCLONE_RETRIES=5` |

**Backup**

| Variable | Default | Description |
|---|---|---|
| `BACKUP_DATABASE` | (required) | |
| `BACKUP_HOST` | (required) | |
| `BACKUP_PORT` | `5432` | DigitalOcean managed databases use `25060` |
| `BACKUP_USER` | (required) | |
| `BACKUP_PASSWORD` | | |
| `PG_DUMP_EXTRA_OPTS` | | e.g. `--schema=public` or `--exclude-table-data=audit_log` |
| `BACKUP_KEEP_DAYS` | `0` (keep all) | Delete backups older than N days after a successful backup. The newest backup is never deleted. A failed cleanup is reported (log, Slack) without failing the backup |
| `AGE_RECIPIENTS` | | age public key(s), comma or space separated. When set, backups are encrypted |

**Restore**

| Variable | Default | Description |
|---|---|---|
| `RESTORE_DATABASE` | (required) | Target database, must exist |
| `RESTORE_CONFIRM` | (required) | Must equal `RESTORE_DATABASE` |
| `RESTORE_SOURCE_DATABASE` | `BACKUP_DATABASE`, else `RESTORE_DATABASE` | Which database's backups to restore, e.g. restore `app` backups into `app_staging` |
| `RESTORE_HOST` | (required) | |
| `RESTORE_PORT` | `5432` | |
| `RESTORE_USER` | (required) | |
| `RESTORE_PASSWORD` | | |
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
  -e RESTORE_SOURCE_DATABASE=app \
  -e RESTORE_DATABASE=app_staging -e RESTORE_CONFIRM=app_staging \
  -e RESTORE_HOST=staging-db.example.com \
  -e RESTORE_USER=app_staging -e RESTORE_PASSWORD=... \
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
server ([SeaweedFS](https://github.com/seaweedfs/seaweedfs)) in Docker, in both version directions (13 → 18, 18 → 16):

- encrypted and plain backup/restore, retention, restore of the latest or a specific backup, repeated restores
- restore into an older server, rollback of a restore that fails midway
- restore guard, missing decryption key and bad credentials fail the job; a backup killed by `SIGTERM` (job deadline, eviction) is reported as failed
- TLS: `verify-full` with a CA certificate; an unknown CA, a host name mismatch and a server without TLS are rejected
- AWS credentials from a shared credentials file instead of environment variables; no credentials or a bucket that can't be listed fail the job
- rclone flags in `S3_UPLOAD_EXTRA_OPTS` (multipart upload)

The Helm chart is linted, its values are validated against `values.schema.json`, the rendered manifests are
validated with kubeconform, and it was tested manually in a kind cluster.

The image is scanned with [Trivy](https://trivy.dev) before it is published: CI fails on critical or high
vulnerabilities that have a fix. The published `latest` image is rescanned every week.

Not tested yet (should work, feedback welcome): DigitalOcean Spaces and other hosted S3-compatible storage,
managed PostgreSQL services, IRSA / EKS Pod Identity (credentials come from the standard AWS SDK credential chain).

## Development

```sh
docker build -t postgresql-backup-restore .
test/e2e.sh   # see "What is tested" above
```

Older PostgreSQL client versions: `docker build --build-arg PG_VERSION=17 .` (any major that has an official
`postgres:<major>-alpine<ALPINE_VERSION>` image; only its client tools are copied into the image).

### Release

The chart and the image share one version: `X.Y.Z` means chart `X.Y.Z` with image `X.Y.Z`.

1. Run `scripts/release.sh X.Y.Z` (sets the version in `helm/Chart.yaml`) and describe the release in
   `artifacthub.io/changes` there.
2. Merge the PR.
3. Push the tag `vX.Y.Z` on the merge commit. CI checks that the tag matches the chart version, scans the image,
   publishes it to Docker Hub and then publishes the chart to `oci://ghcr.io/abohatyrenko/charts`.
4. Create the GitHub Release for the tag.

Release candidates (`vX.Y.Z-rc.N`) are published without the `latest` and `X.Y` tags; pre-release chart
versions are only installed with `--devel` or an explicit `--version`.

## License

[MIT](LICENSE)
