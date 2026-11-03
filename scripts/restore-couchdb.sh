#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=error-trap.sh
. "${SCRIPT_DIR}/error-trap.sh"
DUMP_FILE="/tmp/restore.json"

AUTH=""
if [ -n "${DB_USER:-}" ] && [ -n "${DB_PASSWORD:-}" ]; then
  AUTH="${DB_USER}:${DB_PASSWORD}@"
fi
BASE_URL="http://${AUTH}${DB_HOST}:${DB_PORT}"

echo "Starting CouchDB restore: ${DB_HOST}:${DB_PORT}/${DB_NAME:-<all>}"

RESTORE_STEP="download"
"${SCRIPT_DIR}/s3-download.sh" "${S3_BUCKET}" "${S3_KEY}" "/tmp/download.json.gz" || { echo "ERROR: S3 download failed" >&2; exit 3; }

if [ -n "${ENCRYPTION_KEY:-}" ]; then
  RESTORE_STEP="decrypt"
  "${SCRIPT_DIR}/decrypt.sh" "/tmp/download.json.gz" "/tmp/decrypted.json.gz" || { echo "ERROR: Decryption failed" >&2; exit 4; }
  RESTORE_STEP="decompress"
  gunzip -c /tmp/decrypted.json.gz > "${DUMP_FILE}"
  rm -f /tmp/download.json.gz /tmp/decrypted.json.gz
else
  RESTORE_STEP="decompress"
  gunzip -c /tmp/download.json.gz > "${DUMP_FILE}"
  rm -f /tmp/download.json.gz
fi

RESTORE_STEP="restore"
if [ -n "${DB_NAME:-}" ]; then
  # Single database restore
  echo "Restoring database: ${DB_NAME}"

  # Create database if it doesn't exist
  curl -sf -X PUT "${BASE_URL}/${DB_NAME}" 2>/dev/null || true

  # Extract docs and strip _rev for clean insert
  DOCS=$(jq '{docs: [.rows[].doc | del(._rev)]}' "${DUMP_FILE}")
  curl -sf -X POST "${BASE_URL}/${DB_NAME}/_bulk_docs" \
    -H "Content-Type: application/json" \
    -d "${DOCS}" > /dev/null || { echo "ERROR: _bulk_docs failed for ${DB_NAME}" >&2; exit 5; }
else
  # Multi-database restore
  # Read the list in an assignment: a failure inside a for-loop word list is ignored by set -e.
  DBS=$(jq -r 'if type == "object" then keys[] else error("not an object") end' "${DUMP_FILE}") || { echo "ERROR: Dump is not a valid multi-database CouchDB dump" >&2; exit 5; }
  # shellcheck disable=SC2086
  for DB in ${DBS}; do
    echo "Restoring database: ${DB}"

    # Create database if it doesn't exist
    curl -sf -X PUT "${BASE_URL}/${DB}" 2>/dev/null || true

    # Extract docs for this database
    DOCS=$(jq --arg db "$DB" '{docs: [.[$db].rows[].doc | del(._rev)]}' "${DUMP_FILE}")
    curl -sf -X POST "${BASE_URL}/${DB}/_bulk_docs" \
      -H "Content-Type: application/json" \
      -d "${DOCS}" > /dev/null || { echo "ERROR: _bulk_docs failed for ${DB}" >&2; exit 5; }
  done
fi

rm -f "${DUMP_FILE}"
echo "CouchDB restore completed successfully"
