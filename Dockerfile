FROM debian:11-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    postgresql-client \
    curl \
    unzip \
    wget

# pinned latest cli version (10.03.23)
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-2.11.1.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install \
&& rm -f awscliv2.zip \
&& rm -rf /var/lib/apt/lists/*

COPY ./pg_backup_restore.sh /opt/pg_backup_restore.sh

RUN chmod +x  /opt/pg_backup_restore.sh

CMD [ "/opt/backup_restore.sh" ]
