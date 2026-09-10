# Docker PaaS Platform

A minimal Docker-based Platform as a Service providing reverse proxy with automatic SSL, PostgreSQL database, Valkey cache, and automated S3 backups.

## Prerequisites

- Docker and Docker Compose
- Domain name with DNS pointing to your server
- Apache Bench (for password generation)

## Quick Start

1. Copy environment template:
   ```bash
   make .env
   ```

2. Configure `.env` with your settings:
   - Domain names
   - Email for Let's Encrypt
   - Database credentials
   - S3 backup configuration

3. Generate admin credentials:
   ```bash
   make gen-admin-auth USER=admin PASS=securepassword >> .env
   ```

4. Create external networks:
   ```bash
   docker network create proxy-net
   docker network create db-net
   ```

5. Start services:
   ```bash
   docker compose up -d
   ```

## Configuration

### Required Environment Variables

```bash
# Admin Access
ADMIN_HOSTNAME=admin.yourdomain.com
ADMIN_EMAIL=you@example.com
ADMIN_CREDENTIALS=admin:$apr1$hash...

# Database
POSTGRES_USER=postgres
POSTGRES_PASSWORD=changeme
POSTGRES_DB=postgres
```

### S3 Backup Setup

Configure one S3-compatible provider in `.env`:

**AWS S3:**
```bash
S3_ACCESS_KEY_ID=your_key
S3_SECRET_ACCESS_KEY=your_secret
S3_BUCKET=my-backup-bucket
S3_REGION=us-east-1
```

**Cloudflare R2:**
```bash
S3_ACCESS_KEY_ID=your_key
S3_SECRET_ACCESS_KEY=your_secret
S3_BUCKET=my-backup-bucket
S3_REGION=auto
S3_ENDPOINT=https://<account_id>.r2.cloudflarestorage.com
```

**Other supported providers:** DigitalOcean Spaces, Backblaze B2, Wasabi, MinIO

See `example.env` for complete provider configurations.

### Backup Settings

```bash
SCHEDULE=@daily
S3_PREFIX=paas/postgres
ENCRYPTION_PASSWORD=optional_encryption_key
POSTGRES_BACKUP_ALL=false
POSTGRES_EXTRA_OPTS='--schema=public --blobs'
DROP_PUBLIC=yes  # Restore setting: drops public schema before restore
```

## Adding Applications

Deploy services to the platform by adding Docker labels:

```yaml
services:
  myapp:
    image: myapp:latest
    networks:
      - proxy-net
      - db-net
    labels:
      - traefik.enable=true
      - traefik.http.routers.myapp.rule=Host(`app.yourdomain.com`)
      - traefik.http.routers.myapp.tls=true
      - traefik.http.routers.myapp.tls.certresolver=letsencrypt
```

**Database connection:** Connect to `postgres:5432` on `db-net`

**Valkey connection:** Connect to `valkey:6379` on `db-net`

## Make Commands

- `make .env` - Copy environment template
- `make gen-admin-auth USER=admin PASS=secret` - Generate admin credentials
- `make set-admin-auth USER=admin PASS=secret` - Update admin credentials in `.env`
- `make deploy` - Deploy docker-compose.yml, .env, Makefile, and backup/ to remote server (set `SERVER` and `REMOTE_PATH`)
- `make backup` - Trigger an immediate manual backup to S3
- `make restore` - Restore database from latest S3 backup

## Backing Up

To create an immediate backup:

```bash
make backup
```

This triggers an independent backup to S3. Each run waits for PostgreSQL, checks
the dump command's exit status, rejects empty SQL, and uses a private temporary
directory. Compression/encryption/upload failures return nonzero. The uploaded
object must have the expected size and SHA-256 metadata before success is reported.
The output records the exact `BACKUP_OBJECT` and `BACKUP_SHA256` for later verification.

The scheduler runs immediately at startup, then waits for the configured interval
after a successful backup (`@daily` by default). A failed attempt retries after
`BACKUP_RETRY_INTERVAL` seconds (default 300), rather than waiting another day.
`POSTGRES_WAIT_ATTEMPTS` and `POSTGRES_WAIT_INTERVAL` default to 30 attempts and
two seconds. A readiness check is not proof of valid credentials: a failed dump
still aborts without uploading anything.

`POSTGRES_BACKUP_ALL=true` uses `pg_dumpall` to include databases and global roles.
Otherwise, `POSTGRES_DATABASE` selects one database or a comma-separated list,
each with a separate `pg_dump` archive. `POSTGRES_EXTRA_OPTS` must contain options
supported by the selected tool; database-only flags cannot be passed to `pg_dumpall`.
Encryption remains compatible with existing AES-256-CBC archives. Passwords are
passed through the environment, not command arguments. Keep the encryption
password separately: an encrypted archive is not recoverable without it.

## Restoring from Backup

**⚠️ WARNING:** Restore operations destroy existing database data!

To restore the latest backup from S3:

```bash
make restore
```

The restore process:
1. Prompts for confirmation (type "YES" to proceed)
2. Displays target database and S3 location
3. Stops the postgres-backup service
4. Downloads the latest backup matching the configured database/cluster prefix,
   or the exact object selected with `BACKUP_KEY`
5. Verifies SHA-256 metadata when present, decrypts/decompresses, rejects empty
   dumps, and restores with PostgreSQL `ON_ERROR_STOP` enabled
6. Restarts the postgres-backup service if it was running, even when restore fails

### Restore Configuration

`DROP_PUBLIC` defaults to `no`. Set it to `yes` only for an intentional
single-database schema replacement; validation finishes before the schema is
dropped, and the selected database is used explicitly. It is rejected for
full-cluster restores.

Full-cluster dumps should be restored into a fresh PostgreSQL instance using a
temporary bootstrap superuser name that does not exist in the source cluster.
This avoids conflicts when the dump creates the original roles. Restore is not
atomic across databases: a SQL error stops immediately but may leave earlier
statements applied. Retry with a fresh local instance after correcting the error.

Prefer an explicit `BACKUP_KEY` when restoring from S3. Old archives without
checksum metadata remain readable, but are identified as legacy and still must
pass decryption, decompression, and nonempty-SQL checks.

### Local restore rehearsal

Build the backup image, download a chosen archive, and save its recorded SHA-256.
Keep archives and credentials outside the Git checkout with owner-only permissions.
Create a local `restore.env` containing a temporary `POSTGRES_PASSWORD` and the
archive's `ENCRYPTION_PASSWORD`; it does not need production database or S3 keys.

```bash
docker build -t paas-backup:verification backup
docker network create --internal backup-rehearsal
docker run -d --name backup-restore-db --network backup-rehearsal \
  --env-file /absolute/path/restore.env \
  -e POSTGRES_USER=restore_operator -e POSTGRES_DB=postgres postgres:18
docker run --rm --network backup-rehearsal \
  --env-file /absolute/path/restore.env \
  -v /absolute/path/downloads:/archives:ro \
  -e POSTGRES_HOST=backup-restore-db -e POSTGRES_USER=restore_operator \
  -e POSTGRES_BACKUP_ALL=true -e DROP_PUBLIC=no \
  -e RESTORE_FILE=/archives/all_CHOSEN_BACKUP.sql.gz.enc \
  -e BACKUP_SHA256=RECORDED_SHA256 \
  --entrypoint /restore.sh paas-backup:verification
```

No host ports are published, and the internal network blocks external connections.
Compare the restored database list, schema, table counts, and important records
before treating a backup as verified. Then remove only these rehearsal resources:

```bash
docker rm -fv backup-restore-db
docker network rm backup-rehearsal
```

### Tests

`make test` builds the image, runs failure-injection tests, and performs an encrypted
dump/restore against two disposable PostgreSQL 18 containers. The integration test
checks database schema, rows, roles, and sequence state. S3 is simulated locally;
no production credentials or database access are used. The same checks run in CI.

## Accessing Services

- **Traefik Dashboard:** `https://ADMIN_HOSTNAME` (uses basic auth)
- **PostgreSQL:** `localhost:5432` (internally: `postgres:5432`)
- **Valkey:** `localhost:6379` (internally: `valkey:6379`)

## Services

- **traefik** - Reverse proxy with automatic HTTPS
- **postgres** - PostgreSQL 18 database
- **valkey** - Redis-compatible cache
- **postgres-backup** - Custom backup service (built from `backup/`) for automated S3 backups
- **postgres-restore** - On-demand restore from S3 (run with `make restore`)

## Security

Pre-commit hooks prevent:
- Hardcoded passwords and credentials
- S3 credential exposure
- Invalid Docker Compose configurations
- Environment file commits

## License

MIT
