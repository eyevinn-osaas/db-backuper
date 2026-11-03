#!/bin/bash
# Shim tests for the multi-database branch of restore-couchdb.sh (DB_NAME unset).
# s3-download.sh and curl are shims; jq is the real one.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRET="s3cr3t-pw-value"
PASS=0
FAILN=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAILN=$((FAILN + 1)); echo "  FAIL $1"; }
expect() {
  local d="$1"
  shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}

new_env() { # fixture content
  WORK=$(mktemp -d)
  STUBS="$WORK/bin"
  mkdir -p "$STUBS" "$WORK/scripts"
  export STUB_LOG="$WORK/log"
  : >"$STUB_LOG"
  printf '%s' "$1" | gzip -c >"$WORK/fixture.json.gz"
  export FIXTURE="$WORK/fixture.json.gz"
  # Scripts are committed as mode 644: run copies made executable.
  cp "$ROOT/scripts/restore-couchdb.sh" "$ROOT/scripts/error-trap.sh" "$WORK/scripts/"
  cat >"$WORK/scripts/s3-download.sh" <<'STUB'
#!/bin/bash
cp "$FIXTURE" "$3"
STUB
  cat >"$STUBS/curl" <<'STUB'
#!/bin/bash
echo "curl $*" >>"$STUB_LOG"
exit 0
STUB
  chmod +x "$STUBS"/* "$WORK/scripts"/*
  export PATH="$STUBS:$PATH"
  export S3_BUCKET=backups S3_KEY=couchdb/x.json.gz DB_HOST=10.9.9.9 DB_PORT=5984 DB_USER=admin DB_PASSWORD="$SECRET"
  unset DB_NAME ENCRYPTION_KEY
}

run_restore() {
  OUT=$(bash "$WORK/scripts/restore-couchdb.sh" 2>&1)
  RC=$?
  printf '%s\n' "$OUT" | sed 's/^/    | /'
}

rc_is() { [ "$RC" -eq "$1" ]; }
says() { printf '%s' "$OUT" | grep -qF -- "$1"; }
not_says() { ! printf '%s' "$OUT" | grep -qF -- "$1"; }
error_lines_are() { [ "$(printf '%s\n' "$OUT" | grep -c '^ERROR:')" -eq 1 ] && printf '%s\n' "$OUT" | grep -qx 'ERROR: Dump is not a valid multi-database CouchDB dump'; }
no_curl() { ! grep -q '^curl' "$STUB_LOG"; }
no_bulk() { ! grep -q '_bulk_docs' "$STUB_LOG"; }
no_secret() { ! printf '%s' "$OUT" | grep -qF -- "$SECRET"; }
curl_count() { [ "$(grep -c -- "$1" "$STUB_LOG")" -eq "$2" ]; }

refusal_case() {
  echo "$1"
  expect "exit 5" rc_is 5
  expect "exactly one ERROR line, the fixed message" error_lines_are
  expect "no success line" not_says "completed successfully"
  expect "no _bulk_docs call" no_bulk
  expect "no secret in output" no_secret
}

new_env '{"a":{"rows":[{"doc":{"_id":"1"'
run_restore
refusal_case "truncated JSON is refused"

new_env 'null'
run_restore
refusal_case "null is refused"

new_env '[1,2]'
run_restore
refusal_case "array is refused"

new_env '"x"'
run_restore
refusal_case "string is refused"

echo "empty object: nothing to restore, still success"
new_env '{}'
run_restore
expect "exit 0" rc_is 0
expect "success line" says "CouchDB restore completed successfully"
expect "no curl call" no_curl
expect "no secret in output" no_secret

echo "two databases"
new_env '{"a":{"rows":[{"doc":{"_id":"1","_rev":"1-x"}}]},"b":{"rows":[]}}'
run_restore
expect "exit 0" rc_is 0
expect "restores a" says "Restoring database: a"
expect "restores b" says "Restoring database: b"
expect "a before b" bash -c 'printf "%s" "$1" | grep "Restoring database" | head -1 | grep -q ": a"' _ "$OUT"
expect "PUT per database" curl_count 'X PUT' 2
expect "_bulk_docs POST per database" curl_count '_bulk_docs' 2
expect "success line" says "CouchDB restore completed successfully"
expect "no secret in output" no_secret

echo
echo "passed: $PASS, failed: $FAILN"
[ "$FAILN" -eq 0 ]
