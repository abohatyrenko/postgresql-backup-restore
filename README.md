# PostgreSQL backup/restore script

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/postgresql-backup-restore)](https://artifacthub.io/packages/search?repo=postgresql-backup-restore)

This project contains backup/restore script for PostgrSQL DB's (DO) and store it in S3 bucket (AWS)

## Usage

```bash
$ git clone https://github.com/abohatyrenko/postgresql-backup-restore.git
$ cd postgresql-backup-restore
$ chmod +x pg_backup_restore.sh
$ ./pg_backup_restore.sh backup


# dynamic vars
S3_BUCKET=${S3_BUCKET:=s3://backup/postgresql}
S3_ENDPOINT=${S3_ENDPOINT:=https://s3.amazonaws.com}
AWS_REGION=${AWS_REGION:=eu-central-1}

DB_BACKUP=${DB_BACKUP:=example_backup_db}
DB_TO_RESTORE=${DB_TO_RESTORE:=example_restore_db}
# username should match db name when restoring (owner)
DB_USER=${DB_TO_RESTORE}

#backup
POSTGRESQL_BACKUP_HOST=${POSTGRESQL_BACKUP_HOST:=*ondigitalocean.com}
POSTGRESQL_BACKUP_USER=${POSTGRESQL_BACKUP_USER:=example_user}
POSTGRESQL_BACKUP_PORT=${POSTGRESQL_BACKUP_PORT:=25060}

#restore
POSTGRESQL_RESTORE_HOST=${POSTGRESQL_RESTORE_HOST:=*ondigitalocean.com}
POSTGRESQL_RESTORE_USER=${POSTGRESQL_RESTORE_USER:=example_user}
POSTGRESQL_RESTORE_PORT=${POSTGRESQL_RESTORE_PORT:=25060}

# static vars
BACKUP_DIR=/tmp/backup
RESTORE_DIR=/tmp/restore
ARTIFACT_NAME="${DB_BACKUP}-$(date +%Y-%m-%d).tar.gz"
S3_BUCKET_BACKUP_PREFIX="$DB_BACKUP"
S3_BUCKET_RESTORE_PREFIX="$DB_TO_RESTORE"
```


---
## Docker image:
```shell
docker build -t abohatyrenko/postgresql-backup-restore .
docker pull abohatyrenko/postgresql-backup-restore
```

---
## Helm chart

### Usage:
Go to helm [Readme](helm/README.md#Usage)

### Publish new version of helm-chart:
```sh
cd helm/packages
helm package ../
cd ../
helm repo index . --url https://abohatyrenko.github.io/postgresql-backup-restore/helm/
```
