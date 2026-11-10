#!/bin/bash
# Tests for s3-wait.sh, mc cp retry and bucket ensure, driven through entrypoint.sh with stubbed tools.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRET="dummy-secret-key-do-not-leak"
PASS=0
FAILN=0

ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAILN=$((FAILN + 1)); echo "  FAIL $1"; }
check() { # description, status (0 = true)
  if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi
}
# expect <description> <test command...>
expect() {
  local d="$1"
  shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}

# Error shapes are source-derived (minio-go ErrorResponse nested under error.cause.error in mc --json).
AUTH_LS_OUT='{"status":"error","error":{"message":"Unable to list folder.","cause":{"message":"The Access Key Id you provided does not exist in our records.","error":{"Code":"InvalidAccessKeyId","Message":"The Access Key Id you provided does not exist in our records.","StatusCode":403}},"type":"error"}}'
NOTREADY_LS_OUT='{"status":"error","error":{"message":"Unable to list folder.","cause":{"message":"503 Service Temporarily Unavailable","error":{"Code":"","Message":"","StatusCode":503}},"type":"error"}}'
AUTH_CP_OUT='mc: <ERROR> Failed to copy `/tmp/x`. The Access Key Id you provided does not exist in our records.'
CP_503_OUT='mc: <ERROR> Failed to copy `/tmp/x`. <html><head><title>503 Service Temporarily Unavailable</title></head><body><center><h1>503 Service Temporarily Unavailable</h1></center><hr><center>nginx</center></body></html>'
MISSING_OUT='mc: <ERROR> Failed to copy `backup/backups/key`. Object does not exist.'

new_env() {
  WORK=$(mktemp -d)
  STUBS="$WORK/bin"
  mkdir -p "$STUBS"
  export STUB_LOG="$WORK/log"
  : > "$STUB_LOG"
  export STUB_DIR="$WORK"
  export MC_LS_FAIL=0 MC_CP_FAIL=0 MC_LS_MODE=notready MC_CP_MODE=503
  export AUTH_LS_OUT NOTREADY_LS_OUT AUTH_CP_OUT CP_503_OUT MISSING_OUT
  printf 'SELECT 1;\n' | gzip > "$WORK/fixture.gz"
  export MC_FIXTURE="$WORK/fixture.gz"

  cat > "$STUBS/mc" <<'STUB'
#!/bin/bash
counter() { local f="$STUB_DIR/$1.count"; local n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$f"; echo "$n"; }
case "$1" in
  alias) echo "mc alias set" >> "$STUB_LOG"; exit 0 ;;
  mb) echo "mc $*" >> "$STUB_LOG"; exit 0 ;;
  --json)
    echo "mc $*" >> "$STUB_LOG"
    n=$(counter ls)
    if [ "$MC_LS_MODE" = "auth" ]; then echo "$AUTH_LS_OUT"; exit 1; fi
    if [ "$n" -le "$MC_LS_FAIL" ]; then echo "$NOTREADY_LS_OUT"; exit 1; fi
    exit 0 ;;
  cp)
    echo "mc cp" >> "$STUB_LOG"
    n=$(counter cp)
    if [ "$n" -le "$MC_CP_FAIL" ]; then
      case "$MC_CP_MODE" in
        auth) echo "$AUTH_CP_OUT" >&2 ;;
        missing) echo "$MISSING_OUT" >&2 ;;
        *) echo "$CP_503_OUT" >&2 ;;
      esac
      exit 1
    fi
    case "$2" in
      backup/*) cp "$MC_FIXTURE" "$3" ;;
      *) cp "$2" /dev/null ;;
    esac
    exit 0 ;;
esac
echo "mc $*" >> "$STUB_LOG"
exit 0
STUB
  cat > "$STUBS/pg_dump" <<'STUB'
#!/bin/bash
while [ $# -gt 0 ]; do if [ "$1" = "-f" ]; then echo dump > "$2"; fi; shift; done
exit 0
STUB
  cat > "$STUBS/mysql" <<'STUB'
#!/bin/bash
cat > /dev/null
echo "mysql" >> "$STUB_LOG"
exit 0
STUB
  cat > "$STUBS/clickhouse-client" <<'STUB'
#!/bin/bash
echo "clickhouse-client" >> "$STUB_LOG"
exit 0
STUB
  cat > "$STUBS/sleep" <<'STUB'
#!/bin/bash
echo "sleep $1" >> "$STUB_LOG"
if [ "$1" -le 1 ]; then /bin/sleep "$1"; fi
exit 0
STUB
  chmod +x "$STUBS"/*

  export PATH="$STUBS:$PATH"
  export S3_ENDPOINT=https://tenantbackups.minio-minio.auto.dev.osaas.io
  export S3_ACCESS_KEY=dummyaccess S3_SECRET_KEY="$SECRET" S3_BUCKET=backups S3_KEY=db/key.dump
  export S3_READY_INTERVAL_SECONDS=1
  unset S3_READY_TIMEOUT_SECONDS ENCRYPTION_KEY
}

run_entry() { # operation database-url
  # Mirror the Dockerfile: scripts are copied and made executable.
  mkdir -p "$WORK/opt"
  cp "$ROOT"/scripts/*.sh "$WORK/opt/"
  chmod +x "$WORK"/opt/*.sh
  OUT=$(OPERATION="$1" DATABASE_URL="$2" "$WORK/opt/entrypoint.sh" 2>&1)
  RC=$?
}

count() { grep -c -- "$1" "$STUB_LOG" || true; }
line_of() { grep -n -m1 -- "$1" "$STUB_LOG" | cut -d: -f1; }
has() { printf '%s' "$OUT" | grep -qF -- "$1"; }
count_is() { [ "$(count "$1")" -eq "$2" ]; }
rc_is() { [ "$RC" -eq "$1" ]; }
before() { # a b: both present and a's first line < b's first line
  local a b
  a=$(line_of "$1")
  b=$(line_of "$2")
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
no_leak() { ! printf '%s' "$OUT" | grep -qF -- "$SECRET"; }

PG=postgres://u:p@127.0.0.1:5432/db
MARIA=mariadb://u:p@127.0.0.1:3306/db
CH=clickhouse://u:p@127.0.0.1:9000/db

echo "AC1 backup waits for a 503 endpoint, then uploads"
new_env; MC_LS_FAIL=4; run_entry backup $PG
expect "exit 0" rc_is 0
expect "one ready line" [ "$(printf '%s\n' "$OUT" | grep -c 'S3 endpoint ready after')" -eq 1 ]
expect "Upload complete" has "Upload complete"
expect "5 ls calls" count_is 'mc --json ls' 5
expect "5th ls precedes first cp" [ "$(grep -n 'mc cp' "$STUB_LOG" | head -1 | cut -d: -f1)" -gt 5 ]
expect "no secret leak" no_leak

echo "AC2 restore waits, then restores"
new_env; MC_LS_FAIL=4; run_entry restore $MARIA
expect "exit 0" rc_is 0
expect "restore message" has "MariaDB restore completed successfully"
expect "5 ls calls" count_is 'mc --json ls' 5
expect "no mb on restore" count_is 'mc mb' 0
expect "no secret leak" no_leak

echo "AC3 cp retried with back-off"
new_env; MC_CP_FAIL=2; run_entry backup $PG
expect "exit 0" rc_is 0
expect "3 cp calls" count_is 'mc cp' 3
expect "sleep 5 then sleep 15" before 'sleep 5' 'sleep 15'
expect "Upload complete" has "Upload complete"
expect "no secret leak" no_leak

echo "AC4 auth rejection: no wait, no retry"
new_env; MC_LS_MODE=auth; MC_CP_FAIL=999; MC_CP_MODE=auth; run_entry backup $PG
expect "exit 3" rc_is 3
expect "1 ls call" count_is 'mc --json ls' 1
expect "warn line" has "WARN: S3 endpoint rejected the credentials"
expect "1 cp call" count_is 'mc cp' 1
expect "upload failed" has "ERROR: S3 upload failed"
expect "no secret leak" no_leak

echo "AC5 budget exhaustion proceeds to the transfer"
new_env; export S3_READY_TIMEOUT_SECONDS=2; MC_LS_FAIL=999; MC_CP_FAIL=999; run_entry backup $PG
expect "not ready warn" has "WARN: S3 endpoint not ready after"
expect "proceeding" has "proceeding"
expect "3 cp calls" count_is 'mc cp' 3
expect "upload failed" has "ERROR: S3 upload failed"
expect "exit 3" rc_is 3
expect "no secret leak" no_leak

echo "AC6 download of a missing object is not retried"
new_env; MC_CP_FAIL=999; MC_CP_MODE=missing; run_entry restore $MARIA
expect "1 cp call" count_is 'mc cp' 1
expect "download failed" has "ERROR: S3 download failed"
expect "exit 3" rc_is 3
expect "no secret leak" no_leak

echo "AC7 AWS endpoint skips the wait"
new_env; S3_ENDPOINT=https://s3.eu-north-1.amazonaws.com; run_entry backup $PG
expect "exit 0" rc_is 0
expect "0 ls calls" count_is 'mc --json ls' 0
expect "Upload complete" has "Upload complete"
expect "no secret leak" no_leak

echo "AC8 ClickHouse backup: ls, then mb, then clickhouse-client"
new_env; run_entry backup $CH
expect "exit 0" rc_is 0
expect "ls before mb" before 'mc --json ls' 'mc mb --ignore-existing backup/backups'
expect "mb before clickhouse-client" before 'mc mb' 'clickhouse-client'
expect "no secret leak" no_leak

echo "AC8 ClickHouse restore: ls, no mb, then clickhouse-client"
new_env; run_entry restore $CH
expect "exit 0" rc_is 0
expect "ls before clickhouse-client" before 'mc --json ls' 'clickhouse-client'
expect "no mb" count_is 'mc mb' 0
expect "no secret leak" no_leak

echo "Unknown type fails before waiting"
new_env; run_entry backup nosql://u:p@h/db
expect "exit 1" rc_is 1
expect "no ls" count_is 'mc --json ls' 0

echo
echo "passed=$PASS failed=$FAILN"
[ "$FAILN" -eq 0 ]
