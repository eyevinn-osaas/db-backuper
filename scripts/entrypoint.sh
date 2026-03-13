#!/bin/bash
set -euo pipefail

OPERATION="${OPERATION:?OPERATION env var is required (backup|restore)}"
DATABASE_URL="${DATABASE_URL:?DATABASE_URL env var is required}"
S3_ENDPOINT="${S3_ENDPOINT:?S3_ENDPOINT env var is required}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:?S3_ACCESS_KEY env var is required}"
S3_SECRET_KEY="${S3_SECRET_KEY:?S3_SECRET_KEY env var is required}"
S3_BUCKET="${S3_BUCKET:?S3_BUCKET env var is required}"
S3_KEY="${S3_KEY:?S3_KEY env var is required}"

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
echo "Encryption:    ${ENCRYPTION_KEY:+enabled}${ENCRYPTION_KEY:-disabled}"
echo "=================="

# Configure Minio client
MC_OPTS="--api S3v4"
if [ "${S3_INSECURE:-false}" = "true" ]; then
  MC_OPTS="${MC_OPTS} --insecure"
  export MC_INSECURE=true
fi
mc alias set backup "${S3_ENDPOINT}" "${S3_ACCESS_KEY}" "${S3_SECRET_KEY}" ${MC_OPTS} 2>/dev/null

# Dispatch to the correct script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${SCRIPT_DIR}/${OPERATION}-${DB_TYPE}.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "ERROR: Script not found: ${SCRIPT}" >&2
  exit 1
fi

exec "$SCRIPT"
