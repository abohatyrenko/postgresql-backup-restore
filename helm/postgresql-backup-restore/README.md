This is a backup/restore script for PostgrSQL DB's (DO) and store it in S3 bucket (AWS)

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/postgresql-backup-restore)](https://artifacthub.io/packages/search?repo=postgresql-backup-restore)

### Usage:
```sh
helm repo add postgresql-backup-restore https://abohatyrenko.github.io/postgresql-backup-restore/helm
helm repo update

helm upgrade --install postgresql-backup-restore postgresql-backup-restore/postgresql-backup-restore

# Uninstall
helm uninstall postgresql-backup-restore
```