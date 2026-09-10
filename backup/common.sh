#!/usr/bin/env bash
# Shared helpers; callers enable strict shell error handling before sourcing.

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

init_postgres() {
  export PGPASSWORD="${POSTGRES_PASSWORD:-}"
  export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-5}"
  PG_ARGS=(-h "${POSTGRES_HOST:-postgres}" -p "${POSTGRES_PORT:-5432}" -U "${POSTGRES_USER:-postgres}")
}

wait_for_postgres() {
  local attempts="${POSTGRES_WAIT_ATTEMPTS:-30}" interval="${POSTGRES_WAIT_INTERVAL:-2}" attempt
  [[ "$attempts" =~ ^[1-9][0-9]*$ && "$interval" =~ ^[0-9]+$ ]] || fail "Invalid PostgreSQL wait settings"
  for ((attempt=1; attempt<=attempts; attempt++)); do
    if pg_isready "${PG_ARGS[@]}" >/dev/null 2>&1; then
      return
    fi
    if ((attempt < attempts)); then sleep "$interval"; fi
  done
  fail "PostgreSQL did not become ready; no backup or restore was attempted"
}

init_s3() {
  [[ -n "${S3_ACCESS_KEY_ID:-}" && -n "${S3_SECRET_ACCESS_KEY:-}" && -n "${S3_BUCKET:-}" ]] || fail "S3 credentials and bucket are required"
  export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
  export AWS_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"
  export AWS_DEFAULT_REGION="${S3_REGION:-us-east-1}"
  AWS_ARGS=()
  if [[ -n "${S3_ENDPOINT:-}" ]]; then AWS_ARGS=(--endpoint-url "$S3_ENDPOINT"); fi
  OBJECT_PREFIX="${S3_PREFIX:-}"
  OBJECT_PREFIX="${OBJECT_PREFIX#/}"
  OBJECT_PREFIX="${OBJECT_PREFIX%/}"
  if [[ -n "$OBJECT_PREFIX" ]]; then OBJECT_PREFIX+="/"; fi
}

init_workdir() {
  umask 077
  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/postgres-backup.XXXXXXXX")
  trap 'rm -rf -- "$WORK_DIR"' EXIT
}
