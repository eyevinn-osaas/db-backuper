#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DUMP_FILE="/tmp/backup.json.gz"

AUTH=""
if [ -n "${DB_USER:-}" ] && [ -n "${DB_PASSWORD:-}" ]; then
  AUTH="${DB_USER}:${DB_PASSWORD}@"
fi
BASE_URL="http://${AUTH}${DB_HOST}:${DB_PORT}"

echo "Starting CouchDB backup: ${DB_HOST}:${DB_PORT}/${DB_NAME:-<all>}"

if [ -n "${DB_NAME:-}" ]; then
  # Single database backup
  curl -sf "${BASE_URL}/${DB_NAME}/_all_docs?include_docs=true" \
    | gzip > "${DUMP_FILE}" || { echo "ERROR: CouchDB dump failed" >&2; exit 2; }
else
  # All databases backup
  DBS=$(curl -sf "${BASE_URL}/_all_dbs" | jq -r '.[] | select(startswith("_") | not)') || { echo "ERROR: Failed to list databases" >&2; exit 2; }
  # Document data never goes through argv: one argument is capped at 128 KiB (MAX_ARG_STRLEN).
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  PARTS=("/dev/null")
  i=0
  for DB in ${DBS}; do
    echo "Backing up database: ${DB}"
    i=$((i + 1))
    curl -sf "${BASE_URL}/${DB}/_all_docs?include_docs=true" -o "${TMP}/raw.json" || { echo "ERROR: Failed to dump ${DB}" >&2; exit 2; }
    jq -c --arg db "$DB" '{($db): .}' "${TMP}/raw.json" > "${TMP}/${i}.json" || { echo "ERROR: Failed to dump ${DB}" >&2; exit 2; }
    rm -f "${TMP}/raw.json"
    PARTS+=("${TMP}/${i}.json")
  done
  jq -c -s 'add // {}' "${PARTS[@]}" | gzip > "${DUMP_FILE}"
fi

DUMP_SIZE=$(stat -c%s "${DUMP_FILE}" 2>/dev/null || stat -f%z "${DUMP_FILE}")
echo "Dump completed: ${DUMP_SIZE} bytes (compressed)"

UPLOAD_FILE="${DUMP_FILE}"
if [ -n "${ENCRYPTION_KEY:-}" ]; then
  ENCRYPTED_FILE="/tmp/backup.json.gz.enc"
  "${SCRIPT_DIR}/encrypt.sh" "${DUMP_FILE}" "${ENCRYPTED_FILE}"
  UPLOAD_FILE="${ENCRYPTED_FILE}"
fi

"${SCRIPT_DIR}/s3-upload.sh" "${UPLOAD_FILE}" "${S3_BUCKET}" "${S3_KEY}" || { echo "ERROR: S3 upload failed" >&2; exit 3; }

rm -f /tmp/backup.json.gz /tmp/backup.json.gz.enc
echo "CouchDB backup completed successfully"
