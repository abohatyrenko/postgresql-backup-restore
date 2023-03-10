# PostgreSQL backup/restore script

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/postgresql-backup-restore)](https://artifacthub.io/packages/search?repo=postgresql-backup-restore)

This project contains backup/restore script for PostgrSQL DB's (DO) and store it in S3 bucket (AWS)

## Usage

```bash
$ git clone https://github.com/abohatyrenko/postgresql-backup-restore.git
$ cd postgresql-backup-restore
$ chmod +x pg_backup_restore.sh
$ ./pg_backup_restore.sh backup

# dynamic environment variables

S3_BUCKET_PATH=${S3_BUCKET_PATH:=s3://backup/postgresql}
S3_ENDPOINT=${S3_ENDPOINT:=https://s3.eu-central-1.amazonaws.com}
AWS_REGION=${AWS_REGION:=eu-central-1}

BACKUP_DATABASE_NAME=${BACKUP_DATABASE_NAME:=example_backup_db}
RESTORE_DATABASE_NAME=${RESTORE_DATABASE_NAME:=example_restore_db}

#backup
POSTGRESQL_BACKUP_HOST=${POSTGRESQL_BACKUP_HOST:=*ondigitalocean.com}
POSTGRESQL_BACKUP_USER=${POSTGRESQL_BACKUP_USER:=example_user}
POSTGRESQL_BACKUP_PORT=${POSTGRESQL_BACKUP_PORT:=25060}

#restore
POSTGRESQL_RESTORE_HOST=${POSTGRESQL_RESTORE_HOST:=*ondigitalocean.com}
POSTGRESQL_RESTORE_USER=${POSTGRESQL_RESTORE_USER:=example_user}
POSTGRESQL_RESTORE_PORT=${POSTGRESQL_RESTORE_PORT:=25060}
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
