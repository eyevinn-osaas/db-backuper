#!/bin/bash
# Wait until the S3 endpoint answers an authenticated request.
# Always exits 0: on timeout or rejected credentials the real transfer decides the outcome.
set -uo pipefail

S3_ENDPOINT="${S3_ENDPOINT:-}"
TIMEOUT="${S3_READY_TIMEOUT_SECONDS:-300}"
INTERVAL="${S3_READY_INTERVAL_SECONDS:-5}"

# AWS S3 is always up; nothing to wait for.
if [[ "$S3_ENDPOINT" == *amazonaws.com* ]]; then
  exit 0
fi

echo "Waiting for S3 endpoint ${S3_ENDPOINT} ..."
START=$SECONDS
while true; do
  out=$(mc --json ls backup/ 2>&1)
  if [ $? -eq 0 ]; then
    echo "S3 endpoint ready after $((SECONDS - START))s"
    exit 0
  fi
  if printf '%s' "$out" | grep -Eq 'AccessDenied|InvalidAccessKeyId|SignatureDoesNotMatch'; then
    echo "WARN: S3 endpoint rejected the credentials, not waiting" >&2
    exit 0
  fi
  if [ $((SECONDS - START)) -ge "$TIMEOUT" ]; then
    echo "WARN: S3 endpoint not ready after $((SECONDS - START))s, proceeding" >&2
    exit 0
  fi
  sleep "$INTERVAL"
done
