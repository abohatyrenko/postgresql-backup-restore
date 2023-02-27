# Backup from DigitalOcean DB and store in S3 bucket (AWS)

#!/bin/bash

set -e

# dynamic vars
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

if [[ -z "$AWS_ACCESS_KEY_ID" ]]
then
  echo "`date -R` : ENV var missing: AWS_ACCESS_KEY_ID"
  exit 1
fi

if [[ -z "$AWS_SECRET_ACCESS_KEY" ]]
then
  echo "`date -R` : ENV var missing: AWS_SECRET_ACCESS_KEY"
  exit 1
fi

if [[ -z "$AWS_REGION" ]]
then
  echo "`date -R` : ENV var missing: AWS_REGION"
  exit 1
fi

# static vars
BACKUP_DIR=/tmp/backup
RESTORE_DIR=/tmp/restore
ARTIFACT_NAME="${DB_BACKUP}-$(date +%Y-%m-%d).tar.gz"
S3_BUCKET_BACKUP_PREFIX="$DB_BACKUP"
S3_BUCKET_RESTORE_PREFIX="$DB_TO_RESTORE"

# By default with restore argument the latest backup will be uploaded from S3 bucket.
# As a second argument you can pass specific backup file name to restore. Example (if DB_TO_RESTORE=*) - "*-2022-08-01.tar.gz"
LATEST_BACKUP_FILE=`aws s3 --endpoint-url="$S3_ENDPOINT" ls $S3_BUCKET/$DB_TO_RESTORE/$S3_BUCKET_RESTORE_PREFIX | sort | tail -n 1 | awk '{print $4}'`

case $1 in

  backup)
    if [[ -z "$PG_PASS_BACKUP" ]]
    then
      echo "`date -R` : ENV var missing: PG_PASS_BACKUP"
      exit 1
    fi

    echo "`date -R` : Backing up $DB_BACKUP to $BACKUP_DIR"
    mkdir -p $BACKUP_DIR

    cd $BACKUP_DIR

    echo "`date -R` : Making backup of $DB_BACKUP from $POSTGRESQL_BACKUP_HOST:$POSTGRESQL_BACKUP_PORT"
    # NOTE: for external DO db connection will be needed PGSSLROOTCERT=/pathto/ca-certificate.crt
    PGPASSWORD=$PG_PASS_BACKUP PGSSLMODE=allow pg_dump --verbose --no-owner --host=$POSTGRESQL_BACKUP_HOST --port=$POSTGRESQL_BACKUP_PORT --username=$POSTGRESQL_BACKUP_USER -Fc --file $ARTIFACT_NAME -n public $DB_BACKUP

    ## Check if local backup file exists

    if [ -f "$BACKUP_DIR/$ARTIFACT_NAME" ]; then
        echo "`date -R` : $BACKUP_DIR/$ARTIFACT_NAME exists, moving to upload step"
    else
        echo "`date -R` : $BACKUP_DIR/$ARTIFACT_NAME does not exist, exiting"
        exit 1
    fi

    echo "`date -R` : Uploading $BACKUP_DIR/$ARTIFACT_NAME to $S3_BUCKET"
    aws s3 --endpoint-url="$S3_ENDPOINT" cp --no-progress $BACKUP_DIR/$ARTIFACT_NAME $S3_BUCKET/$S3_BUCKET_BACKUP_PREFIX/

    ## Check if backup file size is not 0 Bytes

    echo "`date -R` : checking postgresql backup size"

    SIZE=$(aws s3 --endpoint-url="$S3_ENDPOINT" ls $S3_BUCKET/$DB_BACKUP --recursive | sort | tail -n 1 | awk '{print $3}');

    if [ "$SIZE" -gt "1" ];
      then
        echo "`date -R` : size is $SIZE its ok"
      else
        echo "`date -R` : size is $SIZE its NOT ok"
        exit 1
    fi

    echo "`date -R` : Finished: Uploaded $ARTIFACT_NAME to $S3_BUCKET/$S3_BUCKET_BACKUP_PREFIX/"

    echo "`date -R` : Cleanup : removing $BACKUP_DIR/$ARTIFACT_NAME"

    rm -rf $BACKUP_DIR/$ARTIFACT_NAME

  ;;

  restore)
    if [[ -z "$PG_PASS_RESTORE" ]]
    then
      echo "`date -R` : ENV var missing: PG_PASS_RESTORE"
      exit 1
    fi

    if [ -z "$2" ]
    then
      echo "`date -R` : No backup file name provided as 2nd arg, please follow the naming - "${DB_BACKUP}-$(date +%Y-%m-%d).tar.gz" if needed"
      echo "`date -R` : Using Latest backup: $LATEST_BACKUP_FILE"
    fi

    echo "`date -R` : Preparing directory to restore - $RESTORE_DIR"
    mkdir -p $RESTORE_DIR
    cd $RESTORE_DIR

    echo "`date -R` : Downloading backup from  $S3_BUCKET/$DB_TO_RESTORE/${2:-$LATEST_BACKUP_FILE}"
    aws s3 cp --no-progress $S3_BUCKET/$DB_TO_RESTORE/${2:-$LATEST_BACKUP_FILE} .

    echo "`date -R` : Restoring $DB_TO_RESTORE to $POSTGRESQL_RESTORE_HOST:$POSTGRESQL_RESTORE_PORT from ${2:-$LATEST_BACKUP_FILE}"
    # NOTE: for external DO db connection will be needed PGSSLROOTCERT=/pathto/ca-certificate.crt
    PGPASSWORD=$PG_PASS_RESTORE PGSSLMODE=allow pg_restore --clean --no-privileges --format=c --verbose --host=$POSTGRESQL_RESTORE_HOST --port=$POSTGRESQL_RESTORE_PORT --username=$POSTGRESQL_RESTORE_USER --role=$DB_USER --dbname=$DB_TO_RESTORE ${2:-$LATEST_BACKUP_FILE} || true

    echo "`date -R` : Finished: Restored $DB_TO_RESTORE to $POSTGRESQL_RESTORE_HOST:$POSTGRESQL_RESTORE_PORT"

    echo "`date -R` : Cleanup : removing $RESTORE_DIR/${2:-$LATEST_BACKUP_FILE}"

    rm -rf ${2:-$LATEST_BACKUP_FILE}

  ;;


  *)
    echo "Possible options: backup/restore"
    exit 1
  ;;

esac
