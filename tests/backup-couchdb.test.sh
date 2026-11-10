#!/bin/bash
# Shim tests for backup-couchdb.sh. curl and s3-upload.sh are shims; jq and gzip are the real ones.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAILN=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAILN=$((FAILN + 1)); echo "  FAIL $1"; }
expect() {
  local d="$1"
  shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}

# _all_docs body with N documents, each padded so the body is large when N is large.
alldocs() { # count
  jq -c -n --argjson n "$1" '{total_rows: $n, offset: 0, rows: [range($n) | {id: "d\(.)", key: "d\(.)", value: {rev: "1-x"}, doc: {_id: "d\(.)", _rev: "1-x", pad: ("x" * 200)}}]}'
}

new_env() { # fixtures are written by the caller into $FIX/_all_dbs and $FIX/<db>.json
  WORK=$(mktemp -d)
  STUBS="$WORK/bin"
  FIX="$WORK/fix"
  mkdir -p "$STUBS" "$WORK/scripts" "$FIX"
  export STUB_LOG="$WORK/log" FIX WORK
  : >"$STUB_LOG"
  cp "$ROOT/scripts/backup-couchdb.sh" "$WORK/scripts/"
  cat >"$WORK/scripts/s3-upload.sh" <<'STUB'
#!/bin/bash
echo "upload $*" >>"$STUB_LOG"
cp "$1" "$WORK/uploaded.gz"
STUB
  cat >"$STUBS/curl" <<'STUB'
#!/bin/bash
# Usage: curl -sf URL [-o FILE]
url="$2"; out=""
[ "${3:-}" = "-o" ] && out="$4"
echo "curl $url" >>"$STUB_LOG"
case "$url" in
  */_all_dbs) cat "$FIX/_all_dbs"; exit 0 ;;
esac
db="${url#http://*/}"; db="${db%%/*}"
[ -f "$FIX/$db.json" ] || exit 22
if [ -n "$out" ]; then cat "$FIX/$db.json" >"$out"; else cat "$FIX/$db.json"; fi
STUB
  chmod +x "$STUBS"/* "$WORK/scripts"/*
  export PATH="$STUBS:$PATH"
  export S3_BUCKET=backups S3_KEY=couchdb/x.json.gz DB_HOST=10.9.9.9 DB_PORT=8080
  unset DB_NAME ENCRYPTION_KEY DB_USER DB_PASSWORD
}

run_backup() {
  OUT=$(bash "$WORK/scripts/backup-couchdb.sh" 2>&1)
  RC=$?
  printf '%s\n' "$OUT" | sed 's/^/    | /'
}

rc_is() { [ "$RC" -eq "$1" ]; }
says() { printf '%s' "$OUT" | grep -qF -- "$1"; }
no_upload() { ! grep -q '^upload' "$STUB_LOG"; }
dump_expr_is() { [ "$(gunzip -c "$WORK/uploaded.gz" | jq -c "$1")" = "$2" ]; }
restore_ids_are() { # db, expected JSON; same expression as restore-couchdb.sh multi-database branch
  [ "$(gunzip -c "$WORK/uploaded.gz" | jq -c --arg db "$1" '{docs: [.[$db].rows[].doc | del(._rev)]}' | jq -c '[.docs[]._id]')" = "$2" ]
}
no_curl_for() { ! grep -q "$1" "$STUB_LOG"; }
error_count_is() { [ "$(printf '%s\n' "$OUT" | grep -c "$1")" -eq "$2" ]; }
not_says() { ! printf '%s' "$OUT" | grep -qF -- "$1"; }

echo "large database (about 300 KB body, over the 128 KiB single-argument cap)"
new_env
echo '["bigdb"]' >"$FIX/_all_dbs"
alldocs 1200 >"$FIX/bigdb.json"
if [ "$(wc -c <"$FIX/bigdb.json")" -gt 262144 ]; then ok "fixture is over 256 KB"; else bad "fixture too small"; fi
run_backup
expect "exit 0" rc_is 0
expect "success line" says "CouchDB backup completed successfully"
expect "all documents in the dump" dump_expr_is '.bigdb.rows | length' 1200

echo "two databases, system database skipped"
new_env
echo '["_users","a","b"]' >"$FIX/_all_dbs"
alldocs 2 >"$FIX/a.json"
alldocs 3 >"$FIX/b.json"
run_backup
expect "exit 0" rc_is 0
expect "dump has exactly the two keys" dump_expr_is 'keys' '["a","b"]'
expect "a has 2 rows" dump_expr_is '.a.rows | length' 2
expect "b has 3 rows" dump_expr_is '.b.rows | length' 3
expect "_users not fetched" no_curl_for '_users/'
expect "round trip: restore expression returns the seeded docs of a" restore_ids_are a '["d0","d1"]'
expect "round trip: restore expression returns the seeded docs of b" restore_ids_are b '["d0","d1","d2"]'

echo "failing curl for one database"
new_env
echo '["a","missing"]' >"$FIX/_all_dbs"
alldocs 1 >"$FIX/a.json"
run_backup
expect "exit 2" rc_is 2
expect "exactly one ERROR: Failed to dump line" error_count_is '^ERROR: Failed to dump missing$' 1
expect "no upload" no_upload
expect "no success line" not_says "completed successfully"

echo "non-JSON body"
new_env
echo '["a"]' >"$FIX/_all_dbs"
echo 'not json' >"$FIX/a.json"
run_backup
expect "exit 2" rc_is 2
expect "ERROR line" says "ERROR: Failed to dump a"
expect "no upload" no_upload

echo "zero databases"
new_env
echo '["_users"]' >"$FIX/_all_dbs"
run_backup
expect "exit 0" rc_is 0
expect "dump is {}" dump_expr_is '.' '{}'

echo "single database (DB_NAME set) keeps the raw _all_docs shape"
new_env
alldocs 4 >"$FIX/solo.json"
export DB_NAME=solo
run_backup
expect "exit 0" rc_is 0
expect "dump is the raw response" dump_expr_is '.rows | length' 4

echo
echo "passed: $PASS, failed: $FAILN"
[ "$FAILN" -eq 0 ]
