# pg_dump/pg_restore must be >= the server major version.
# A newer client can dump/restore older servers, so the latest major is a safe default.
ARG PG_VERSION=17

FROM postgres:${PG_VERSION}-alpine

# hadolint ignore=DL3018
RUN apk add --no-cache \
      age \
      aws-cli \
      bash \
      ca-certificates \
      coreutils \
      curl \
 && addgroup -S -g 10001 backup \
 && adduser -S -D -H -u 10001 -G backup -h /tmp backup

COPY --chmod=0755 pg_backup_restore.sh /usr/local/bin/pg_backup_restore.sh
# Backward compatible path used by older chart versions / docs
RUN ln -s /usr/local/bin/pg_backup_restore.sh /opt/pg_backup_restore.sh

ENV HOME=/tmp \
    WORK_DIR=/tmp/pg-backup-restore

USER 10001:10001
WORKDIR /tmp

ENTRYPOINT ["/usr/local/bin/pg_backup_restore.sh"]
CMD ["backup"]
