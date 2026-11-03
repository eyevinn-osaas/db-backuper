#!/bin/bash
set -euo pipefail

# First output line of every job: lets a release check read the loader commit from the logs.
echo "db-backuper: valkey loader ${DB_BACKUPER_VALKEY_LOADER_COMMIT:-none}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Required variables: unset or empty fails with exit 1. The name is printed, never the value.
for name in OPERATION DATABASE_URL S3_ENDPOINT S3_ACCESS_KEY S3_SECRET_KEY S3_BUCKET S3_KEY; do
  if [ -z "${!name:-}" ]; then
    echo "ERROR: missing required variable ${name}" >&2
    exit 1
  fi
done

# One fixed-class ERROR line for any restore failure without an explicit handler.
if [ "$OPERATION" = "restore" ]; then
  # shellcheck source=error-trap.sh
  . "${SCRIPT_DIR}/error-trap.sh"
  RESTORE_STEP="configure S3"
fi

# URL-decode a string (e.g. %21 -> !, %40 -> @)
urldecode() {
  printf '%b' "${1//%/\\x}"
}

# Parse DATABASE_URL scheme to determine database type
DB_SCHEME="${DATABASE_URL%%://*}"

# Strip scheme
URL_REMAINDER="${DATABASE_URL#*://}"

# Parse credentials (user:password@host:port/db)
if [[ "$URL_REMAINDER" == *@* ]]; then
  CREDENTIALS="${URL_REMAINDER%%@*}"
  HOST_PART="${URL_REMAINDER#*@}"
  if [[ "$CREDENTIALS" == *:* ]]; then
    export DB_USER="$(urldecode "${CREDENTIALS%%:*}")"
    export DB_PASSWORD="$(urldecode "${CREDENTIALS#*:}")"
  else
    export DB_USER="$CREDENTIALS"
    export DB_PASSWORD=""
  fi
else
  HOST_PART="$URL_REMAINDER"
  export DB_USER=""
  export DB_PASSWORD=""
fi

# Parse host:port/db
if [[ "$HOST_PART" == */* ]]; then
  HOST_PORT="${HOST_PART%%/*}"
  export DB_NAME="${HOST_PART#*/}"
else
  HOST_PORT="$HOST_PART"
  export DB_NAME=""
fi

if [[ "$HOST_PORT" == *:* ]]; then
  export DB_HOST="${HOST_PORT%%:*}"
  export DB_PORT="${HOST_PORT#*:}"
else
  export DB_HOST="$HOST_PORT"
  export DB_PORT=""
fi

# Set default ports per database type
case "$DB_SCHEME" in
  postgres|postgresql)
    DB_TYPE="postgres"
    export DB_PORT="${DB_PORT:-5432}"
    ;;
  mariadb|mysql)
    DB_TYPE="mariadb"
    export DB_PORT="${DB_PORT:-3306}"
    ;;
  valkey|redis)
    DB_TYPE="valkey"
    export DB_PORT="${DB_PORT:-6379}"
    ;;
  clickhouse)
    DB_TYPE="clickhouse"
    export DB_PORT="${DB_PORT:-9000}"
    ;;
  couchdb)
    DB_TYPE="couchdb"
    export DB_PORT="${DB_PORT:-5984}"
    ;;
  *)
    echo "ERROR: Unsupported database scheme: ${DB_SCHEME}" >&2
    exit 1
    ;;
esac

echo "=== db-backuper ==="
echo "Operation:     ${OPERATION}"
echo "Database type: ${DB_TYPE}"
echo "Host:          ${DB_HOST}:${DB_PORT}"
echo "Database:      ${DB_NAME:-<all>}"
echo "S3 target:     s3://${S3_BUCKET}/${S3_KEY}"
if [ -n "${ENCRYPTION_KEY:-}" ]; then echo "Encryption:    enabled"; else echo "Encryption:    disabled"; fi
echo "=================="

# Configure Minio client
MC_OPTS="--api S3v4"
if [ "${S3_INSECURE:-false}" = "true" ]; then
  MC_OPTS="${MC_OPTS} --insecure"
  export MC_INSECURE=true
fi
mc alias set backup "${S3_ENDPOINT}" "${S3_ACCESS_KEY}" "${S3_SECRET_KEY}" ${MC_OPTS} 2>/dev/null

# Dispatch to the correct script
SCRIPT="${SCRIPT_DIR}/${OPERATION}-${DB_TYPE}.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "ERROR: Script not found: ${SCRIPT}" >&2
  exit 1
fi

# exec of a non-executable file ends the job with status 126 and no ERROR: line.
if [ ! -x "$SCRIPT" ]; then
  echo "ERROR: Script is not executable: ${SCRIPT}" >&2
  exit 126
fi

# Wait for the S3 endpoint (a freshly provisioned store answers 503 for a while).
"${SCRIPT_DIR}/s3-wait.sh" || true

# Ensure the bucket exists on backup (ClickHouse BACKUP ... TO S3 does not create it).
if [ "$OPERATION" = "backup" ]; then
  mc mb --ignore-existing "backup/${S3_BUCKET}" 2>/dev/null || true
fi

exec "$SCRIPT"
