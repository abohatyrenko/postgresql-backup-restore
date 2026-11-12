# pg_dump/pg_restore must be >= the server major version.
# A newer client can dump/restore older servers, so the latest major is a safe default.
ARG PG_VERSION=18
# Both stages use the same Alpine release, so the client tools run against the
# library versions they were built with.
ARG ALPINE_VERSION=3.24

# Only the client tools are taken from the official image: the server, its LLVM JIT
# and the rest of the official image would add ~250 MB the backup never uses.
# Any major the official image has works, Alpine packages only cover the newest ones.
FROM postgres:${PG_VERSION}-alpine${ALPINE_VERSION} AS postgres

FROM alpine:${ALPINE_VERSION}

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

COPY --from=postgres /usr/local/bin/pg_dump /usr/local/bin/pg_restore /usr/local/bin/psql /usr/local/bin/
COPY --from=postgres /usr/local/lib/libpq.so.5* /usr/local/lib/

# The shared libraries the client tools link to are installed by soname, so the list
# follows the PostgreSQL version instead of being kept by hand.
# rclone comes from Alpine: its package is rebuilt when Go gets security fixes, which the
# official rclone binaries are not between rclone releases (vulnerability scanners flag those).
# hadolint ignore=DL3018,SC2046
RUN apk add --no-cache \
      age \
      bash \
      ca-certificates \
      coreutils \
      curl \
      rclone \
      $(scanelf --needed --nobanner --format '%n#p' \
          /usr/local/bin/pg_dump /usr/local/bin/pg_restore /usr/local/bin/psql /usr/local/lib/libpq.so.5 \
        | tr ',' '\n' | sort -u | grep -v '^libpq\.so' | sed 's/^/so:/') \
 && pg_dump --version && pg_restore --version && psql --version && rclone version \
 && addgroup -S -g 10001 backup \
 && adduser -S -D -H -u 10001 -G backup -h /tmp backup

COPY --chmod=0755 pg_backup_restore.sh /usr/local/bin/pg_backup_restore.sh

ENV HOME=/tmp \
    WORK_DIR=/tmp/pg-backup-restore

USER 10001:10001
WORKDIR /tmp

ENTRYPOINT ["/usr/local/bin/pg_backup_restore.sh"]
CMD ["backup"]
