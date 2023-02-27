This is a backup/restore script for PostgrSQL DB's (DO) and store it in S3 bucket (AWS)

### Usage:
```sh
helm repo add postgresql-backup-restore https://abohatyrenko.github.io/postgresql-backup-restore/helm
helm repo update

helm upgrade --install postgresql-backup-restore postgresql-backup-restore/postgresql-backup-restore

# Uninstall
helm uninstall postgresql-backup-restore
```