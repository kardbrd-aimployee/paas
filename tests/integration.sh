#!/usr/bin/env bash
# Real PostgreSQL and encryption, with a local filesystem standing in for S3.
set -euo pipefail
REPO_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
TEST_IMAGE="${TEST_IMAGE:-paas-backup:verification}"
TEST_DIR=$(mktemp -d)
TEST_DIR=$(cd "$TEST_DIR" && pwd -P)
TEST_ID="backup-test-$$-$RANDOM"
SOURCE_CONTAINER="$TEST_ID-source"
TARGET_CONTAINER="$TEST_ID-target"
cleanup() {
  docker rm -fv "$SOURCE_CONTAINER" "$TARGET_CONTAINER" >/dev/null 2>&1 || true
  docker network rm "$TEST_ID" >/dev/null 2>&1 || true
  rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT

docker network create --internal "$TEST_ID" >/dev/null
docker run -d --name "$SOURCE_CONTAINER" --network "$TEST_ID" \
  -e POSTGRES_PASSWORD=fixture-password -e POSTGRES_DB=postgres postgres:18 >/dev/null
docker run -d --name "$TARGET_CONTAINER" --network "$TEST_ID" \
  -e POSTGRES_USER=restore_operator -e POSTGRES_PASSWORD=fixture-password \
  -e POSTGRES_DB=postgres postgres:18 >/dev/null

for container in "$SOURCE_CONTAINER" "$TARGET_CONTAINER"; do
  ready=false
  for ((attempt=1; attempt<=30; attempt++)); do
    if docker exec "$container" pg_isready -q; then ready=true; break; fi
    sleep 1
  done
  [[ "$ready" == true ]] || { echo "Fixture PostgreSQL did not start" >&2; exit 1; }
done
docker exec -i "$SOURCE_CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE ROLE fixture_reader;
CREATE DATABASE backup_fixture;
\connect backup_fixture
CREATE TABLE example (id serial PRIMARY KEY, value text NOT NULL);
INSERT INTO example(value) SELECT 'fixture-' || i FROM generate_series(1, 100) AS i;
CREATE TABLE "odd table" (value text);
INSERT INTO "odd table" VALUES (E'line one\nline two\t\\end');
GRANT SELECT ON example TO fixture_reader;
SQL

mkdir -p "$TEST_DIR/bin"
ln -s /work/tests/fake_commands.py "$TEST_DIR/bin/aws"
# Keep private fixture files owned by the invoking user on Linux bind mounts.
docker run --rm --user "$(id -u):$(id -g)" --network "$TEST_ID" \
  -v "$REPO_DIR:/work:ro" -v "$TEST_DIR:/test-data" \
  -e PATH=/test-data/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  -e FAKE_ROOT=/test-data -e S3_ACCESS_KEY_ID=fixture -e S3_SECRET_ACCESS_KEY=fixture \
  -e S3_BUCKET=fixture -e S3_PREFIX=backups -e POSTGRES_BACKUP_ALL=true \
  -e POSTGRES_HOST="$SOURCE_CONTAINER" -e POSTGRES_PASSWORD=fixture-password \
  -e ENCRYPTION_PASSWORD=fixture-encryption -e SCHEDULE='**None**' \
  "$TEST_IMAGE"

archive=$(find "$TEST_DIR/objects" -type f -name '*.enc')
[[ -n "$archive" ]] || { echo "Encrypted fixture backup missing" >&2; exit 1; }
docker run --rm --network "$TEST_ID" -v "$TEST_DIR:/test-data:ro" \
  -e RESTORE_FILE="/test-data/${archive#"$TEST_DIR/"}" -e POSTGRES_BACKUP_ALL=true \
  -e POSTGRES_HOST="$TARGET_CONTAINER" -e POSTGRES_USER=restore_operator \
  -e POSTGRES_PASSWORD=fixture-password -e ENCRYPTION_PASSWORD=fixture-encryption \
  --entrypoint /restore.sh "$TEST_IMAGE"

rows=$(docker exec "$TARGET_CONTAINER" psql -U restore_operator -d backup_fixture -Atc 'SELECT count(*) FROM example')
next_id=$(docker exec "$TARGET_CONTAINER" psql -U restore_operator -d backup_fixture -Atc "SELECT nextval('example_id_seq')")
role=$(docker exec "$TARGET_CONTAINER" psql -U restore_operator -d postgres -Atc "SELECT count(*) FROM pg_roles WHERE rolname='fixture_reader'")
[[ "$rows" == 100 && "$next_id" == 101 && "$role" == 1 ]] || { echo "Restored database validation failed" >&2; exit 1; }
for database in postgres backup_fixture; do
  source_schema=$(docker exec "$SOURCE_CONTAINER" pg_dump -U postgres -d "$database" --schema-only --no-owner --no-privileges | sed '/^\\restrict /d; /^\\unrestrict /d' | shasum -a 256)
  target_schema=$(docker exec "$TARGET_CONTAINER" pg_dump -U restore_operator -d "$database" --schema-only --no-owner --no-privileges | sed '/^\\restrict /d; /^\\unrestrict /d' | shasum -a 256)
  [[ "$source_schema" == "$target_schema" ]] || { echo "Schema mismatch for $database" >&2; exit 1; }
done
echo "Real PostgreSQL restore passed: databases, schema, data, role, and sequence verified"
