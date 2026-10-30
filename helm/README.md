# postgresql-backup-restore Helm chart

Runs [postgresql-backup-restore](../README.md) as a Kubernetes CronJob, plus an optional on-demand restore job.

## Install

```sh
helm repo add postgresql-backup-restore https://abohatyrenko.github.io/postgresql-backup-restore/helm
helm repo update

helm upgrade --install pg-backup postgresql-backup-restore/postgresql-backup-restore -f values.yaml

# Uninstall
helm uninstall pg-backup
```

Example `values.yaml` for a DigitalOcean managed database and Spaces:

```yaml
backup:
  schedule: "0 2 * * *"
  timeZone: Europe/Kyiv
  env:
    BACKUP_KEEP_DAYS: "30"
    AGE_RECIPIENTS: age1...
    HEARTBEAT_URL: https://hc-ping.com/<uuid>

env:
  S3_BUCKET_PATH: s3://my-space/postgresql
  S3_ENDPOINT: https://fra1.digitaloceanspaces.com
  AWS_REGION: fra1
  BACKUP_DATABASE_NAME: app
  POSTGRESQL_BACKUP_HOST: db-postgresql-fra1-12345-do-user-1-0.b.db.ondigitalocean.com
  POSTGRESQL_BACKUP_PORT: "25060"
  POSTGRESQL_BACKUP_USER: backup
  PGSSLMODE: verify-full
  PGSSLROOTCERT: /etc/pg-ca/ca-certificate.crt

# Secret with keys aws_access_key_id, aws_secret_access_key, postgresql_backup, slack_webhook_url
existingSecret: pg-backup

extraVolumes:
  - name: pg-ca
    secret:
      secretName: do-pg-ca
extraVolumeMounts:
  - name: pg-ca
    mountPath: /etc/pg-ca
    readOnly: true

workDir:
  sizeLimit: 20Gi
```

Run a backup right away:

```sh
kubectl create job --from=cronjob/pg-backup-postgresql-backup-restore pg-backup-manual-$(date +%s)
```

## Restore

Restore is disabled by default. Ideally enable it in a separate release in the environment you restore into,
so the backup release never has credentials for writing to a database:

```yaml
backup:
  enabled: false
restore:
  enabled: true
  env:
    RESTORE_CONFIRM: app_staging
env:
  S3_BUCKET_PATH: s3://my-space/postgresql
  S3_ENDPOINT: https://fra1.digitaloceanspaces.com
  RESTORE_SOURCE_NAME: app
  RESTORE_DATABASE_NAME: app_staging
  POSTGRESQL_RESTORE_HOST: staging-db.example.com
  POSTGRESQL_RESTORE_PORT: "25060"
  POSTGRESQL_RESTORE_USER: app_staging
existingSecret: pg-restore # aws_*, postgresql_restore, age_identity
```

The restore CronJob is suspended and never scheduled. Start a restore of the latest backup with:

```sh
kubectl create job --from=cronjob/<release>-postgresql-backup-restore-restore restore-$(date +%s)
```

To restore a specific backup, set `restore.args: ["restore", "app-20261030T020000Z.dump"]`.

## Values

See [values.yaml](values.yaml) for all options. The most important ones:

| Key | Default | Description |
|---|---|---|
| `backup.enabled` | `true` | Create the backup CronJob |
| `backup.schedule` / `backup.timeZone` | `0 11 * * *` / controller time zone | |
| `backup.env` / `restore.env` / `env` | `{}` | Environment variables for backup jobs / restore jobs / both |
| `restore.enabled` | `false` | Create the suspended restore CronJob |
| `existingSecret` | | Secret with `aws_access_key_id`, `aws_secret_access_key`, `postgresql_backup`, `postgresql_restore`, `age_identity`, `slack_webhook_url` (all optional) |
| `secrets.*` | | Values for a Secret created by the chart when `existingSecret` is empty |
| `dbPasswordSecret.{backup,restore}_secret` | disabled | Read DB passwords from dedicated Secrets |
| `serviceAccount.annotations` | `{}` | e.g. `eks.amazonaws.com/role-arn` for IRSA instead of static AWS keys |
| `workDir.sizeLimit` | `10Gi` | Scratch space for the dump; must fit the whole compressed dump |
| `workDir.volume` | emptyDir | Custom volume for large databases (e.g. an ephemeral PVC) |
| `deployNotification.enabled` | `false` | Slack message on install/upgrade/rollback |

Backup jobs only receive the backup password; restore jobs only receive the restore password and the age identity.
