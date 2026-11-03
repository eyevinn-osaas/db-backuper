#!/bin/bash
set -euo pipefail

LOCAL_FILE="${1:?Usage: s3-upload.sh <local_file> <bucket> <key>}"
BUCKET="${2:?Usage: s3-upload.sh <local_file> <bucket> <key>}"
KEY="${3:?Usage: s3-upload.sh <local_file> <bucket> <key>}"

echo "Uploading to s3://${BUCKET}/${KEY}..."
mc mb --ignore-existing "backup/${BUCKET}" 2>/dev/null || true

# Up to 3 attempts (back-off 5s, 15s); auth errors are not retried.
AUTH_RE='Access Denied|Access Key Id you provided does not exist|signature we calculated does not match'
BACKOFF=(0 5 15)
rc=0
for attempt in 1 2 3; do
  if [ "${BACKOFF[$((attempt - 1))]}" -gt 0 ]; then
    sleep "${BACKOFF[$((attempt - 1))]}"
  fi
  if out=$(mc cp "$LOCAL_FILE" "backup/${BUCKET}/${KEY}" 2>&1); then
    echo "Upload complete"
    exit 0
  else
    rc=$?
  fi
  printf '%s\n' "$out" >&2
  if printf '%s' "$out" | grep -Eqi "$AUTH_RE"; then
    break
  fi
  echo "WARN: upload attempt ${attempt}/3 failed" >&2
done
exit "$rc"
