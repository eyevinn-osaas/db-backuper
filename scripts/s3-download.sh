#!/bin/bash
set -euo pipefail

BUCKET="${1:?Usage: s3-download.sh <bucket> <key> <local_file>}"
KEY="${2:?Usage: s3-download.sh <bucket> <key> <local_file>}"
LOCAL_FILE="${3:?Usage: s3-download.sh <bucket> <key> <local_file>}"

echo "Downloading s3://${BUCKET}/${KEY}..."

# Up to 3 attempts (back-off 5s, 15s); auth errors and missing objects are not retried.
NO_RETRY_RE='Access Denied|Access Key Id you provided does not exist|signature we calculated does not match|Object does not exist'
BACKOFF=(0 5 15)
rc=0
for attempt in 1 2 3; do
  if [ "${BACKOFF[$((attempt - 1))]}" -gt 0 ]; then
    sleep "${BACKOFF[$((attempt - 1))]}"
  fi
  if out=$(mc cp "backup/${BUCKET}/${KEY}" "$LOCAL_FILE" 2>&1); then
    echo "Download complete: $(stat -c%s "$LOCAL_FILE" 2>/dev/null || stat -f%z "$LOCAL_FILE") bytes"
    exit 0
  else
    rc=$?
  fi
  printf '%s\n' "$out" >&2
  if printf '%s' "$out" | grep -Eqi "$NO_RETRY_RE"; then
    break
  fi
  echo "WARN: download attempt ${attempt}/3 failed" >&2
done
exit "$rc"
