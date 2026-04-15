FROM alpine:3.20

RUN apk add --no-cache \
    bash \
    postgresql16-client \
    mariadb-client \
    mariadb-connector-c \
    aws-cli \
    zstd \
    gzip \
    xz \
    docker-cli \
    coreutils

COPY db-backup.sh /usr/local/bin/db-backup
COPY restore.sh /usr/local/bin/db-restore
RUN chmod +x /usr/local/bin/db-backup /usr/local/bin/db-restore

ENTRYPOINT ["db-backup"]
