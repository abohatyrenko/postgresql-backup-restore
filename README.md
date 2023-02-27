# PostgreSQL backup/restore script

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/postgresql-backup-restore)](https://artifacthub.io/packages/search?repo=postgresql-backup-restore)

This project contains backup/restore script for PostgrSQL DB's (DO) and store it in S3 bucket (AWS)

## Script


#### Download and execute the script:

```bash
$ git clone https://github.com/abohatyrenko/postgresql-backup-restore.git
$ cd postgresql-backup-restore
$ chmod +x pg_backup_restore.sh && chmod +x pg_backup_restore.sh
$ ./pg_backup_restore.sh
```



## Default Configuration

### Edit preferences

```bash
S3_BUCKET=${S3_BUCKET:=s3://backup/postgresql}
S3_ENDPOINT=${S3_ENDPOINT:=https://s3.amazonaws.com}

DB_BACKUP=${DB_BACKUP:=*}
DB_TO_RESTORE=${DB_TO_RESTORE:=*}
# username will match db name when restoring (owner)
DB_USER=${DB_TO_RESTORE}

#backup
POSTGRESQL_BACKUP_HOST=${POSTGRESQL_BACKUP_HOST:=*ondigitalocean.com}
POSTGRESQL_BACKUP_USER=${POSTGRESQL_BACKUP_USER:=*}
POSTGRESQL_BACKUP_PORT=${POSTGRESQL_BACKUP_PORT:=25060}
#restore
POSTGRESQL_RESTORE_HOST=${POSTGRESQL_RESTORE_HOST:=*}
POSTGRESQL_RESTORE_USER=${POSTGRESQL_RESTORE_USER:=*}
POSTGRESQL_RESTORE_PORT=${POSTGRESQL_RESTORE_PORT:=25060}
```

