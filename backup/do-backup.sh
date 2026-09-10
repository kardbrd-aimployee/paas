#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
source "$SCRIPT_DIR/common.sh"

init_postgres
init_s3
init_workdir
wait_for_postgres
read -r -a EXTRA_ARGS <<< "${POSTGRES_EXTRA_OPTS:-}"

if [[ "${POSTGRES_BACKUP_ALL:-false}" == true ]]; then
  DATABASES=(all)
else
  IFS=, read -r -a DATABASES <<< "${POSTGRES_DATABASE:-postgres}"
fi

for database in "${DATABASES[@]}"; do
  [[ -n "$database" ]] || fail "An empty database name was configured"
  dump_file="$WORK_DIR/dump.sql"
  if [[ "${POSTGRES_BACKUP_ALL:-false}" == true ]]; then
    echo "Creating dump of all databases..."
    pg_dumpall "${PG_ARGS[@]}" "${EXTRA_ARGS[@]}" --file="$dump_file"
  else
    echo "Creating dump of database: $database"
    pg_dump "${PG_ARGS[@]}" "${EXTRA_ARGS[@]}" --dbname="$database" --file="$dump_file"
  fi
  [[ -s "$dump_file" ]] || fail "Database dump is empty; refusing to upload"
  sql_bytes=$(wc -c < "$dump_file")
  gzip -c "$dump_file" > "$WORK_DIR/dump.sql.gz"
  gzip -t "$WORK_DIR/dump.sql.gz"
  upload_file="$WORK_DIR/dump.sql.gz"
  # Nanoseconds and a unique suffix avoid collisions between scheduled/manual runs.
  object_key="${OBJECT_PREFIX}${database}_$(date -u +'%Y-%m-%dT%H:%M:%S.%NZ')_${WORK_DIR##*.}.sql.gz"
  if [[ -n "${ENCRYPTION_PASSWORD:-}" ]]; then
    export ENCRYPTION_PASSWORD
    # Preserve compatibility with existing encrypted archives; keep the password
    # out of process arguments. Restore also supports these legacy AES archives.
    openssl enc -aes-256-cbc -in "$upload_file" -out "$upload_file.enc" -pass env:ENCRYPTION_PASSWORD
    upload_file+=".enc"
    object_key+=".enc"
  fi
  checksum=$(sha256sum "$upload_file")
  checksum="${checksum%% *}"
  expected_size=$(wc -c < "$upload_file")
  aws "${AWS_ARGS[@]}" s3 cp "$upload_file" "s3://$S3_BUCKET/$object_key" \
    --only-show-errors --metadata "sha256=$checksum"
  remote_info=$(aws "${AWS_ARGS[@]}" s3api head-object --bucket "$S3_BUCKET" --key "$object_key" \
    --query '[ContentLength, Metadata.sha256]' --output text)
  read -r remote_size remote_checksum <<< "$remote_info"
  [[ "$remote_size" == "$expected_size" && "$remote_checksum" == "$checksum" ]] || fail "Uploaded object verification failed"
  echo "BACKUP_OBJECT=s3://$S3_BUCKET/$object_key"
  echo "BACKUP_SQL_BYTES=$sql_bytes BACKUP_OBJECT_BYTES=$expected_size BACKUP_SHA256=$checksum"
  echo "SQL backup uploaded and verified successfully"
  rm -f -- "$WORK_DIR"/dump.sql*
done
