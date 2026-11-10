#!/bin/bash
# Shim tests: restore-couchdb.sh must send _bulk_docs bodies over 128 KiB (the single-argument cap).
# s3-download.sh and curl are shims; jq is the real one. The curl shim copies the --data-binary file.
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

rows() { # count -> rows array with padded docs
  jq -c -n --argjson n "$1" '[range($n) | {id: "d\(.)", doc: {_id: "d\(.)", _rev: "1-x", pad: ("x" * 200)}}]'
}

new_env() { # fixture content
  WORK=$(mktemp -d)
  STUBS="$WORK/bin"
  mkdir -p "$STUBS" "$WORK/scripts" "$WORK/bodies"
  export STUB_LOG="$WORK/log" BODIES="$WORK/bodies"
  : >"$STUB_LOG"
  printf '%s' "$1" | gzip -c >"$WORK/fixture.json.gz"
  export FIXTURE="$WORK/fixture.json.gz"
  cp "$ROOT/scripts/restore-couchdb.sh" "$ROOT/scripts/error-trap.sh" "$WORK/scripts/"
  cat >"$WORK/scripts/s3-download.sh" <<'STUB'
#!/bin/bash
cp "$FIXTURE" "$3"
STUB
  cat >"$STUBS/curl" <<'STUB'
#!/bin/bash
echo "curl $*" >>"$STUB_LOG"
for a in "$@"; do
  case "$a" in
    @*) cp "${a#@}" "$BODIES/$(date +%s%N).json" ;;
  esac
done
exit 0
STUB
  chmod +x "$STUBS"/* "$WORK/scripts"/*
  export PATH="$STUBS:$PATH"
  export S3_BUCKET=backups S3_KEY=couchdb/x.json.gz DB_HOST=10.9.9.9 DB_PORT=8080
  unset DB_NAME ENCRYPTION_KEY DB_USER DB_PASSWORD
}

run_restore() {
  OUT=$(bash "$WORK/scripts/restore-couchdb.sh" 2>&1)
  RC=$?
  printf '%s\n' "$OUT" | sed 's/^/    | /'
}

rc_is() { [ "$RC" -eq "$1" ]; }
says() { printf '%s' "$OUT" | grep -qF -- "$1"; }
body_count_is() { [ "$(ls "$BODIES" | wc -l)" -eq "$1" ]; }
body_docs_are() { # file index (1-based, sorted by name), expected doc count
  local f
  f=$(ls "$BODIES" | sort | sed -n "${1}p")
  [ "$(jq '.docs | length' "$BODIES/$f")" -eq "$2" ]
}
body_has_no_rev() { ! grep -q '_rev' "$BODIES"/*; }
body_over_128k() { [ "$(wc -c <"$BODIES/$(ls "$BODIES" | sort | sed -n "${1}p")")" -gt 131072 ]; }

BIG=$(rows 1000)
SMALL=$(rows 2)

echo "multi-database dump with one database over 128 KiB"
new_env "{\"big\":{\"rows\":${BIG}},\"small\":{\"rows\":${SMALL}}}"
run_restore
expect "exit 0" rc_is 0
expect "success line" says "CouchDB restore completed successfully"
expect "two bodies sent" body_count_is 2
expect "big body is over 128 KiB" body_over_128k 1
expect "big body has all 1000 docs" body_docs_are 1 1000
expect "small body has 2 docs" body_docs_are 2 2
expect "_rev stripped" body_has_no_rev

echo "single-database dump (DB_NAME set) over 128 KiB"
new_env "{\"total_rows\":1000,\"rows\":${BIG}}"
export DB_NAME=solo
run_restore
expect "exit 0" rc_is 0
expect "success line" says "CouchDB restore completed successfully"
expect "one body sent" body_count_is 1
expect "body is over 128 KiB" body_over_128k 1
expect "body has all 1000 docs" body_docs_are 1 1000
expect "_rev stripped" body_has_no_rev

echo
echo "passed: $PASS, failed: $FAILN"
[ "$FAILN" -eq 0 ]
