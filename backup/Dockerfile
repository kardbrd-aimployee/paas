FROM postgres:18

RUN apt-get update && apt-get install -y \
    curl \
    gzip \
    openssl \
    unzip \
    awscli \
    python3 \
    && rm -rf /var/lib/apt/lists/*

COPY backup.sh /backup.sh
COPY do-backup.sh /do-backup.sh
COPY restore.sh /restore.sh
COPY common.sh /common.sh

RUN chmod +x /backup.sh /do-backup.sh /restore.sh /common.sh

ENV SCHEDULE=@daily
ENV POSTGRES_HOST=postgres
ENV POSTGRES_PORT=5432
ENV POSTGRES_USER=postgres
ENV POSTGRES_PASSWORD=
ENV POSTGRES_DATABASE=postgres
ENV S3_BUCKET=
ENV S3_REGION=us-east-1
ENV S3_PREFIX=backup
ENV POSTGRES_BACKUP_ALL=false
ENV POSTGRES_EXTRA_OPTS=
ENV ENCRYPTION_PASSWORD=
ENV DROP_PUBLIC=no

CMD ["/bin/bash", "/backup.sh"]
