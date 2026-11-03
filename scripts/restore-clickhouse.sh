#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=error-trap.sh
. "${SCRIPT_DIR}/error-trap.sh"
RESTORE_STEP="restore"

DATABASE="${DB_NAME:-default}"

echo "Starting ClickHouse restore: ${DB_HOST}:${DB_PORT}/${DATABASE}"

AUTH_ARGS=""
if [ -n "${DB_USER:-}" ]; then
  AUTH_ARGS="--user ${DB_USER}"
fi
if [ -n "${DB_PASSWORD:-}" ]; then
  AUTH_ARGS="${AUTH_ARGS} --password ${DB_PASSWORD}"
fi

S3_PATH="S3('${S3_ENDPOINT}/${S3_BUCKET}/${S3_KEY}', '${S3_ACCESS_KEY}', '${S3_SECRET_KEY}')"

clickhouse-client \
  -h "${DB_HOST}" \
  --port "${DB_PORT}" \
  ${AUTH_ARGS} \
  --query "RESTORE DATABASE ${DATABASE} FROM ${S3_PATH}" || { echo "ERROR: ClickHouse restore failed" >&2; exit 5; }

echo "ClickHouse restore completed successfully"
