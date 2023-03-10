# Backup from DigitalOcean managed DB and store in S3 bucket (AWS)

#!/bin/bash

set -eu

# Environment variables are placed here according priority, any changes could lead to issues

BACKUP_DIR=/tmp/backup
RESTORE_DIR=/tmp/restore
ARTIFACT_NAME="${BACKUP_DATABASE_NAME}-$(date +%Y-%m-%d).tar.gz"
S3_BUCKET_PATH_BACKUP_PREFIX="$BACKUP_DATABASE_NAME"
S3_BUCKET_PATH_RESTORE_PREFIX="$RESTORE_DATABASE_NAME"

S3_BUCKET_PATH=${S3_BUCKET_PATH:=s3://backup/postgresql}
S3_ENDPOINT=${S3_ENDPOINT:=https://s3.amazonaws.com}
S3_TARGET=$S3_BUCKET_PATH/$S3_BUCKET_PATH_BACKUP_PREFIX/$ARTIFACT_NAME
AWS_REGION=${AWS_REGION:=eu-central-1}

BACKUP_DATABASE_NAME=${BACKUP_DATABASE_NAME:=example_backup_db}
RESTORE_DATABASE_NAME=${RESTORE_DATABASE_NAME:=example_restore_db}
# username should match db name when restoring (owner)
DB_USER=${RESTORE_DATABASE_NAME}

#backup
POSTGRESQL_BACKUP_HOST=${POSTGRESQL_BACKUP_HOST:=*ondigitalocean.com}
POSTGRESQL_BACKUP_USER=${POSTGRESQL_BACKUP_USER:=example_user}
POSTGRESQL_BACKUP_PORT=${POSTGRESQL_BACKUP_PORT:=25060}

#restore
POSTGRESQL_RESTORE_HOST=${POSTGRESQL_RESTORE_HOST:=*ondigitalocean.com}
POSTGRESQL_RESTORE_USER=${POSTGRESQL_RESTORE_USER:=example_user}
POSTGRESQL_RESTORE_PORT=${POSTGRESQL_RESTORE_PORT:=25060}


if [ -z "$AWS_ACCESS_KEY_ID" ]
then
  echo "`date -R` : ENV var missing: AWS_ACCESS_KEY_ID"
  exit 1
fi

if [ -z "$AWS_SECRET_ACCESS_KEY" ]
then
  echo "`date -R` : ENV var missing: AWS_SECRET_ACCESS_KEY"
  exit 1
fi

if [ -z "$AWS_REGION" ]
then
  echo "`date -R` : ENV var missing: AWS_REGION"
  exit 1
fi

# By default with restore argument the latest backup will be uploaded from S3 bucket.
# As a second argument you can pass specific backup file name to restore. Example (if RESTORE_DATABASE_NAME=*) - "*-2022-08-01.tar.gz"
LATEST_BACKUP_FILE=`aws s3 ls $S3_BUCKET_PATH/$RESTORE_DATABASE_NAME/$S3_BUCKET_PATH_RESTORE_PREFIX --endpoint-url $S3_ENDPOINT | sort | tail -n 1 | awk '{print $4}'`

case $1 in

  backup)
    if [ -z "$PG_PASS_BACKUP" ]
    then
      echo "`date -R` : ENV var missing: PG_PASS_BACKUP"
      exit 1
    fi

    echo "`date -R` : Backing up $BACKUP_DATABASE_NAME to $BACKUP_DIR"
    mkdir -p $BACKUP_DIR

    cd $BACKUP_DIR

    echo "`date -R` : Making backup of $BACKUP_DATABASE_NAME from $POSTGRESQL_BACKUP_HOST:$POSTGRESQL_BACKUP_PORT"
    # NOTE: for external DO db connection will be needed PGSSLROOTCERT=/pathto/ca-certificate.crt
    PGPASSWORD=$PG_PASS_BACKUP PGSSLMODE=allow pg_dump --verbose --no-owner --host=$POSTGRESQL_BACKUP_HOST --port=$POSTGRESQL_BACKUP_PORT --username=$POSTGRESQL_BACKUP_USER -Fc --file $ARTIFACT_NAME -n public $BACKUP_DATABASE_NAME

    ## Check if local backup file exists
    if [ -f "$BACKUP_DIR/$ARTIFACT_NAME" ]; then
        echo "`date -R` : $BACKUP_DIR/$ARTIFACT_NAME exists, moving to upload step"
    else
        echo "`date -R` : $BACKUP_DIR/$ARTIFACT_NAME does not exist, exiting"
        exit 1
    fi

    echo "`date -R` : Uploading $ARTIFACT_NAME to $S3_BUCKET_PATH/$S3_BUCKET_PATH_BACKUP_PREFIX/"
    aws s3 cp --no-progress $BACKUP_DIR/$ARTIFACT_NAME $S3_TARGET --endpoint-url $S3_ENDPOINT

    ## Check if backup file size is not 0 Bytes

    echo "`date -R` : Checking postgresql backup size"
    SIZE=$(aws s3 ls $S3_TARGET --region $AWS_REGION --endpoint-url $S3_ENDPOINT | sort | tail -n 1 | awk '{print $3}');

    if [ "$SIZE" -gt "1" ];
      then
        echo "`date -R` : size is $SIZE its ok"
      else
        echo "`date -R` : size is $SIZE its NOT ok"
        exit 1
    fi

    echo "`date -R` : Finished: Uploaded $ARTIFACT_NAME to $S3_BUCKET_PATH/$S3_BUCKET_PATH_BACKUP_PREFIX/"

    echo "`date -R` : Cleanup : removing $BACKUP_DIR/$ARTIFACT_NAME"

    rm -rf $BACKUP_DIR/$ARTIFACT_NAME

  ;;

  restore)
    if [ -z "$PG_PASS_RESTORE" ]
    then
      echo "`date -R` : ENV var missing: PG_PASS_RESTORE"
      exit 1
    fi

    if [ -z "$2" ]
    then
      echo "`date -R` : No backup file name provided as 2nd arg, please follow the naming - "${BACKUP_DATABASE_NAME}-$(date +%Y-%m-%d).tar.gz" if needed"
      echo "`date -R` : Using Latest backup: $LATEST_BACKUP_FILE"
    fi

    echo "`date -R` : Preparing directory to restore - $RESTORE_DIR"
    mkdir -p $RESTORE_DIR
    cd $RESTORE_DIR

    echo "`date -R` : Downloading backup from  $S3_BUCKET_PATH/$RESTORE_DATABASE_NAME/${2:-$LATEST_BACKUP_FILE}"
    aws s3 cp --no-progress $S3_BUCKET_PATH/$RESTORE_DATABASE_NAME/${2:-$LATEST_BACKUP_FILE} . --endpoint-url $S3_ENDPOINT

    echo "`date -R` : Restoring $RESTORE_DATABASE_NAME to $POSTGRESQL_RESTORE_HOST:$POSTGRESQL_RESTORE_PORT from ${2:-$LATEST_BACKUP_FILE}"
    # NOTE: for external DO db connection will be needed PGSSLROOTCERT=/pathto/ca-certificate.crt
    PGPASSWORD=$PG_PASS_RESTORE PGSSLMODE=allow pg_restore --clean --no-privileges --format=c --verbose --host=$POSTGRESQL_RESTORE_HOST --port=$POSTGRESQL_RESTORE_PORT --username=$POSTGRESQL_RESTORE_USER --role=$DB_USER --dbname=$RESTORE_DATABASE_NAME ${2:-$LATEST_BACKUP_FILE} || true

    echo "`date -R` : Finished: Restored $RESTORE_DATABASE_NAME to $POSTGRESQL_RESTORE_HOST:$POSTGRESQL_RESTORE_PORT"

    echo "`date -R` : Cleanup : removing $RESTORE_DIR/${2:-$LATEST_BACKUP_FILE}"

    rm -rf ${2:-$LATEST_BACKUP_FILE}

  ;;


  *)
    echo "Possible options: backup/restore"
    exit 1
  ;;

esac
