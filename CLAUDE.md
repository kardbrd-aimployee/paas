# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A minimal Docker-based Platform as a Service providing:
- Traefik reverse proxy with automatic Let's Encrypt SSL
- PostgreSQL 18 database
- Valkey (Redis-compatible) cache
- Automated S3 backups with optional encryption

## Commands

```bash
# Setup
make .env                              # Create .env from example.env
make gen-admin-auth USER=x PASS=y      # Generate admin credentials (append >> .env)
make set-admin-auth USER=x PASS=y      # Update admin credentials in existing .env

# Services
docker compose up -d                   # Start all services
docker compose logs -f <service>       # View service logs

# Backup/Restore
make backup                            # Trigger immediate backup to S3
make restore                           # Restore from latest S3 backup (destructive!)

# Deploy to remote server
make deploy SERVER=user@host REMOTE_PATH=paas
```

## Architecture

### Networks (external, must be created manually)
- `proxy-net`: Connects Traefik to web-facing services
- `db-net`: Connects PostgreSQL and Valkey to backend services

### Services
- **reverse-proxy (traefik)**: Routes traffic, handles SSL via Let's Encrypt
- **postgres**: Shared PostgreSQL database (port 5432)
- **valkey**: Redis-compatible cache (port 6379)
- **postgres-backup**: Scheduled S3 backups (interval loop, built from `backup/`)
- **postgres-restore**: On-demand restore (uses `--profile restore`)

### Backup System (`backup/` directory)
Custom Docker image based on postgres:18 with AWS CLI:
- `backup.sh`: Entry point - runs once or schedules backups, retrying failed attempts
- `do-backup.sh`: Waits for PostgreSQL, validates pg_dump/pg_dumpall, optionally encrypts, uploads and verifies S3 metadata
- `restore.sh`: Validates a selected S3 or local archive and restores with SQL error checking
- `common.sh`: Shared PostgreSQL readiness, S3 configuration, and private temporary-file helpers

Run `make test` for failure tests and an encrypted restore against disposable
PostgreSQL 18 instances. Full-cluster restore requires a fresh target with a
bootstrap superuser absent from the source dump. Do not test restore against the
production database. Keep downloaded archives and credentials outside Git.

Supports multiple S3-compatible providers: AWS S3, Cloudflare R2, DigitalOcean Spaces, Backblaze B2, Wasabi, MinIO.

## Adding Applications

Deploy services by adding Docker labels and connecting to the external networks:
```yaml
services:
  myapp:
    networks:
      - proxy-net  # For web access via Traefik
      - db-net     # For database/cache access
    labels:
      - traefik.enable=true
      - traefik.http.routers.myapp.rule=Host(`app.domain.com`)
      - traefik.http.routers.myapp.tls=true
      - traefik.http.routers.myapp.tls.certresolver=letsencrypt
```

Internal hostnames: `postgres:5432`, `valkey:6379`

## Pre-commit Hooks

The repo uses pre-commit hooks that:
- Validate docker-compose.yml syntax
- Block .env file commits
- Detect hardcoded passwords/credentials in docker-compose.yml
- Check Makefile uses tabs (not spaces)
