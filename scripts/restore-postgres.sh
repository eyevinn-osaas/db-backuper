#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=error-trap.sh
. "${SCRIPT_DIR}/error-trap.sh"
DUMP_FILE="/tmp/restore.dump"

echo "Starting PostgreSQL restore: ${DB_HOST}:${DB_PORT}/${DB_NAME:-<all>}"

RESTORE_STEP="download"
"${SCRIPT_DIR}/s3-download.sh" "${S3_BUCKET}" "${S3_KEY}" "/tmp/download.dump" || { echo "ERROR: S3 download failed" >&2; exit 3; }

if [ -n "${ENCRYPTION_KEY:-}" ]; then
  RESTORE_STEP="decrypt"
  "${SCRIPT_DIR}/decrypt.sh" "/tmp/download.dump" "${DUMP_FILE}" || { echo "ERROR: Decryption failed" >&2; exit 4; }
  rm -f /tmp/download.dump
else
  mv /tmp/download.dump "${DUMP_FILE}"
fi

RESTORE_STEP="restore"
export PGPASSWORD="${DB_PASSWORD}"

pg_restore \
  -h "${DB_HOST}" \
  -p "${DB_PORT}" \
  -U "${DB_USER}" \
  ${DB_NAME:+-d "${DB_NAME}"} \
  --clean \
  --if-exists \
  "${DUMP_FILE}" || { echo "ERROR: pg_restore failed" >&2; exit 5; }

rm -f "${DUMP_FILE}"
echo "PostgreSQL restore completed successfully"
