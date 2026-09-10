#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
SCHEDULE="${SCHEDULE:-@daily}"

if [[ "$SCHEDULE" == '**None**' ]]; then
  echo "Running one-time backup..."
  exec "$SCRIPT_DIR/do-backup.sh"
fi

case "$SCHEDULE" in
  @yearly|@annually) INTERVAL=31536000 ;;
  @monthly) INTERVAL=2592000 ;;
  @weekly) INTERVAL=604800 ;;
  @daily|@midnight) INTERVAL=86400 ;;
  @hourly) INTERVAL=3600 ;;
  @every_minute) INTERVAL=60 ;;
  *) echo "Unsupported schedule: $SCHEDULE" >&2; exit 1 ;;
esac
RETRY_INTERVAL="${BACKUP_RETRY_INTERVAL:-300}"
[[ "$RETRY_INTERVAL" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid backup retry interval" >&2; exit 1; }

echo "Backup schedule: $SCHEDULE (every ${INTERVAL}s after success)"
while true; do
  if "$SCRIPT_DIR/do-backup.sh"; then
    echo "Next backup in ${INTERVAL}s..."
    sleep "$INTERVAL"
  else
    echo "ERROR: Backup failed; retrying in ${RETRY_INTERVAL}s" >&2
    sleep "$RETRY_INTERVAL"
  fi
done
