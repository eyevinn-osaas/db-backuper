#!/bin/bash
# Every restore failure path ends the job log with exactly one ERROR: line, the exit status of
# each path is unchanged, and no database URL, password or key reaches the output.
#
# Paths with no explicit handler (implicit) get "ERROR: restore failed during <step>" from
# scripts/error-trap.sh. Paths that already printed ERROR: keep their own line.
#
# Exit status per path (identical before and after this change):
#
#   path                                         status  line
#   -------------------------------------------  ------  ---------------------------------------------
#   mariadb: corrupt gzip                        1       ERROR: restore failed during decompress
#   couchdb: corrupt gzip                        1       ERROR: restore failed during decompress
#   couchdb: invalid JSON (single database)      jq's    ERROR: restore failed during restore
#   entrypoint: mc alias set fails               mc's    ERROR: restore failed during configure S3
#   postgres: mv fails                           1       ERROR: restore failed during download
#   entrypoint: missing required variable        1       ERROR: missing required variable <NAME>
#   entrypoint: restore script not executable    126     ERROR: Script is not executable: <path>
#   valkey: corrupt RDB (loader cannot load it)  5       ERROR: backup could not be loaded (<log>), ...
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DBPASS="dbpass-s3cret"
S3SECRET="s3-secret-key-777"
ENCKEY="enc-key-424242"
PASS=0
FAILN=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAILN=$((FAILN + 1)); echo "  FAIL $1"; }
expect() {
  local d="$1"
  shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}

new_env() {
  WORK=$(mktemp -d)
  STUBS="$WORK/bin"
  SCRIPTS="$WORK/scripts"
  mkdir -p "$STUBS"
  cp -R "$ROOT/scripts" "$SCRIPTS"
  chmod +x "$SCRIPTS"/*.sh   # the repo stores them 644; the image chmods them
  rm -f /tmp/download.* /tmp/decrypted.* /tmp/restore.*
  export STUB_LOG="$WORK/log"
  : >"$STUB_LOG"
  export MC_ALIAS_RC=0
  cat >"$STUBS/mc" <<'STUB'
#!/bin/bash
# alias: exit MC_ALIAS_RC. cp: copy MC_FIXTURE to the target when set.
case "$1" in
  alias) exit "${MC_ALIAS_RC:-0}" ;;
  cp) [ -n "${MC_FIXTURE:-}" ] && cp "$MC_FIXTURE" "$3"; exit 0 ;;
esac
exit 0
STUB
  cat >"$STUBS/mysql" <<'STUB'
#!/bin/bash
echo "mysql called" >>"$STUB_LOG"
exit 0
STUB
  cat >"$STUBS/curl" <<'STUB'
#!/bin/bash
echo "curl called" >>"$STUB_LOG"
exit 0
STUB
  chmod +x "$STUBS"/*
  unset MC_FIXTURE ENCRYPTION_KEY
}

# run_script <engine> [VAR=value ...]: run scripts/restore-<engine>.sh directly.
run_script() {
  local engine="$1"
  shift
  OUT=$(env PATH="$STUBS:$PATH" \
    DB_HOST=10.9.9.9 DB_PORT=1234 DB_USER=dbuser DB_PASSWORD="$DBPASS" DB_NAME= \
    S3_ENDPOINT=http://127.0.0.1:9 S3_ACCESS_KEY=ak S3_SECRET_KEY="$S3SECRET" S3_BUCKET=b S3_KEY=k \
    "$@" bash "$SCRIPTS/restore-${engine}.sh" 2>&1)
  RC=$?
  printf '%s\n' "$OUT" | sed 's/^/    | /'
}

# run_entry [VAR=value ...]: run entrypoint.sh with OPERATION=restore. Use VAR= to blank one.
run_entry() {
  OUT=$(env PATH="$STUBS:$PATH" \
    S3_ENDPOINT=http://127.0.0.1:9 S3_ACCESS_KEY=ak S3_SECRET_KEY="$S3SECRET" S3_BUCKET=b S3_KEY=k \
    OPERATION=restore DATABASE_URL="postgres://dbuser:${DBPASS}@10.9.9.9:5432/db" \
    S3_READY_TIMEOUT_SECONDS=1 \
    "$@" bash "$SCRIPTS/entrypoint.sh" 2>&1)
  RC=$?
  printf '%s\n' "$OUT" | sed 's/^/    | /'
}

rc_is() { [ "$RC" -eq "$1" ]; }
one_error() { [ "$(printf '%s\n' "$OUT" | grep -c '^ERROR:')" -eq 1 ]; }
last_error_is() { [ "$(printf '%s\n' "$OUT" | grep '^ERROR:' | tail -n 1)" = "$1" ]; }
no_secret() {
  local s
  for s in "$DBPASS" "$S3SECRET" "$ENCKEY"; do
    if printf '%s' "$OUT" | grep -qF -- "$s"; then return 1; fi
  done
  return 0
}
not_logged() { ! grep -q "$1" "$STUB_LOG"; }

check() { # status, exact ERROR line
  expect "exit status $1" rc_is "$1"
  expect "exactly one ERROR: line" one_error
  expect "line is: $2" last_error_is "$2"
  expect "no password, key or URL in output" no_secret
}

gz() { printf '%s' "$1" | gzip -c; }

echo "mariadb: corrupt gzip"
new_env
printf 'this is not gzip' >"$WORK/fixture"
export MC_FIXTURE="$WORK/fixture"
run_script mariadb
check 1 "ERROR: restore failed during decompress"
expect "mysql never called" not_logged "mysql called"

echo "couchdb: corrupt gzip"
new_env
printf 'this is not gzip' >"$WORK/fixture"
export MC_FIXTURE="$WORK/fixture"
run_script couchdb
check 1 "ERROR: restore failed during decompress"

echo "couchdb: invalid JSON, single database"
new_env
gz 'this is {not json' >"$WORK/fixture"
export MC_FIXTURE="$WORK/fixture"
run_script couchdb DB_NAME=mydb
JQ_RC=0; printf "%s" "this is {not json" | jq . >/dev/null 2>&1 || JQ_RC=$?
check "$JQ_RC" "ERROR: restore failed during restore"
expect "no _bulk_docs POST after the parse failure" bash -c '[ "$(grep -c "curl called" "$1")" -le 1 ]' _ "$STUB_LOG"

echo "entrypoint: mc alias set fails with status 7"
new_env
export MC_ALIAS_RC=7
run_entry
check 7 "ERROR: restore failed during configure S3"

echo "postgres: mv fails"
new_env
run_script postgres
check 1 "ERROR: restore failed during download"

echo "entrypoint: missing required variable"
new_env
run_entry S3_KEY=
check 1 "ERROR: missing required variable S3_KEY"
new_env
run_entry OPERATION=
check 1 "ERROR: missing required variable OPERATION"

echo "entrypoint: restore script not executable"
new_env
chmod -x "$SCRIPTS/restore-postgres.sh"
run_entry
check 126 "ERROR: Script is not executable: $SCRIPTS/restore-postgres.sh"

echo "entrypoint: restore script missing keeps its explicit line"
new_env
rm -f "$SCRIPTS/restore-postgres.sh"
run_entry
check 1 "ERROR: Script not found: $SCRIPTS/restore-postgres.sh"

echo "explicit handlers print only their own line"
new_env
printf 'x' >"$WORK/fixture"
export MC_FIXTURE="$WORK/fixture"
export ENCRYPTION_KEY="$ENCKEY"
printf '#!/bin/bash\nexit 9\n' >"$SCRIPTS/decrypt.sh"
run_script mariadb ENCRYPTION_KEY="$ENCKEY"
check 4 "ERROR: Decryption failed"
new_env
printf '#!/bin/bash\nexit 9\n' >"$SCRIPTS/s3-download.sh"
run_script postgres
check 3 "ERROR: S3 download failed"
new_env
gz 'select 1;' >"$WORK/fixture"
export MC_FIXTURE="$WORK/fixture"
printf '#!/bin/bash\ncat >/dev/null\nexit 1\n' >"$STUBS/mysql"
run_script mariadb
check 5 "ERROR: mysql restore failed"

echo "valkey: corrupt RDB goes through refuse() and keeps the loader's last log line (named exception)"
new_env
printf 'REDIS0012garbage' >"$WORK/fixture"
export MC_FIXTURE="$WORK/fixture"
cat >"$STUBS/valkey-server" <<'STUB'
#!/bin/bash
while [ $# -gt 0 ]; do
  if [ "$1" = "--pidfile" ]; then pidfile="$2"; fi
  if [ "$1" = "--logfile" ]; then logfile="$2"; fi
  shift
done
echo 999999 >"$pidfile"
echo "# Internal error in RDB reading offset 0 -> Unexpected EOF reading RDB file" >"$logfile"
exit 0
STUB
printf '#!/bin/bash\nexit 0\n' >"$STUBS/valkey-cli"
chmod +x "$STUBS"/*
run_script valkey DB_HOST=10.9.9.9 VALKEY_LOADER_WAIT_S=5
check 5 "ERROR: backup could not be loaded (# Internal error in RDB reading offset 0 -> Unexpected EOF reading RDB file), target not modified"

echo "valkey: missing DB_HOST"
new_env
run_script valkey DB_HOST=
check 1 "ERROR: missing required variable DB_HOST"

echo "clickhouse: failing client keeps its explicit line"
new_env
printf '#!/bin/bash\nexit 1\n' >"$STUBS/clickhouse-client"
chmod +x "$STUBS/clickhouse-client"
run_script clickhouse
check 5 "ERROR: ClickHouse restore failed"

echo "trap never prints the failing command line"
new_env
OUT=$(env PATH="$STUBS:$PATH" bash -c ". '$SCRIPTS/error-trap.sh'; set -e; RESTORE_STEP=restore; /bin/false 'postgres://u:${DBPASS}@h/db'" 2>&1)
RC=$?
expect "status of the failing command" rc_is 1
expect "exactly one ERROR: line" one_error
expect "no password in output" no_secret

echo "subshell failure yields one line"
new_env
OUT=$(env PATH="$STUBS:$PATH" bash -c ". '$SCRIPTS/error-trap.sh'; set -e; RESTORE_STEP=decrypt; x=\$(exit 3)" 2>&1)
RC=$?
expect "status 3 preserved" rc_is 3
expect "exactly one ERROR: line" one_error
expect "line is: ERROR: restore failed during decrypt" last_error_is "ERROR: restore failed during decrypt"

echo
echo "passed: $PASS, failed: $FAILN"
[ "$FAILN" -eq 0 ]
