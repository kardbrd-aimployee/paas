#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
source "$SCRIPT_DIR/common.sh"

init_workdir
expected_checksum="${BACKUP_SHA256:-}"
if [[ -n "${RESTORE_FILE:-}" ]]; then
  [[ -f "$RESTORE_FILE" ]] || fail "Local restore archive does not exist"
  archive_name="${RESTORE_FILE##*/}"
  cp -- "$RESTORE_FILE" "$WORK_DIR/archive"
else
  init_s3
  object_key="${BACKUP_KEY:-}"
  if [[ -z "$object_key" ]]; then
    if [[ "${POSTGRES_BACKUP_ALL:-false}" == true ]]; then
      database_prefix=all
    else
      database_prefix="${POSTGRES_DATABASE:-postgres}"
      [[ "$database_prefix" != *,* ]] || fail "Restore one database at a time"
    fi
    object_key=$(aws "${AWS_ARGS[@]}" s3api list-objects-v2 --bucket "$S3_BUCKET" \
      --prefix "${OBJECT_PREFIX}${database_prefix}_" \
      --query 'sort_by(Contents, &LastModified)[-1].Key' --output text)
    [[ -n "$object_key" && "$object_key" != None ]] || fail "No matching backup found"
  fi
  archive_name="${object_key##*/}"
  expected_checksum=$(aws "${AWS_ARGS[@]}" s3api head-object --bucket "$S3_BUCKET" --key "$object_key" \
    --query 'Metadata.sha256' --output text)
  aws "${AWS_ARGS[@]}" s3 cp "s3://$S3_BUCKET/$object_key" "$WORK_DIR/archive" --only-show-errors
fi

if [[ -n "$expected_checksum" && "$expected_checksum" != None ]]; then
  [[ "$expected_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "Invalid backup checksum"
  actual_checksum=$(sha256sum "$WORK_DIR/archive")
  [[ "${actual_checksum%% *}" == "$expected_checksum" ]] || fail "Archive checksum mismatch; database is unchanged"
else
  echo "Archive has no recorded SHA-256 (legacy/local backup); validating archive contents"
fi

source_file="$WORK_DIR/archive"
if [[ "$archive_name" == *.enc ]]; then
  [[ -n "${ENCRYPTION_PASSWORD:-}" ]] || fail "The archive requires ENCRYPTION_PASSWORD"
  export ENCRYPTION_PASSWORD
  openssl enc -aes-256-cbc -d -in "$source_file" -out "$WORK_DIR/decrypted" -pass env:ENCRYPTION_PASSWORD
  source_file="$WORK_DIR/decrypted"
  archive_name="${archive_name%.enc}"
fi
case "$archive_name" in
  *.sql.gz) gzip -dc "$source_file" > "$WORK_DIR/restore.sql" ;;
  *.sql) cp -- "$source_file" "$WORK_DIR/restore.sql" ;;
  *) fail "Unsupported archive type" ;;
esac
[[ -s "$WORK_DIR/restore.sql" ]] || fail "The SQL dump is empty; database is unchanged"

database="${POSTGRES_DATABASE:-postgres}"
if [[ "${POSTGRES_BACKUP_ALL:-false}" == true ]]; then
  [[ "${DROP_PUBLIC:-no}" != yes ]] || fail "DROP_PUBLIC is only valid for single-database restores; restore a cluster into a fresh instance"
  database=postgres
else
  [[ "$database" != *,* ]] || fail "Restore one database at a time"
  [[ "$archive_name" != all_* ]] || fail "Cluster archive requires POSTGRES_BACKUP_ALL=true"
fi

init_postgres
wait_for_postgres
if [[ "${DROP_PUBLIC:-no}" == yes ]]; then
  psql "${PG_ARGS[@]}" -X --set=ON_ERROR_STOP=1 --dbname="$database" \
    --command='DROP SCHEMA public CASCADE; CREATE SCHEMA public;'
fi
echo "Restoring validated SQL dump..."
# Discard successful command output: SQL can emit sensitive role/session values.
# Fail immediately on SQL errors, including failures in another database reached
# by a pg_dumpall \connect command.
psql "${PG_ARGS[@]}" -X --set=ON_ERROR_STOP=1 --dbname="$database" --file="$WORK_DIR/restore.sql" >/dev/null
echo "Restore completed successfully"
