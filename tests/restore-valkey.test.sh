#!/bin/bash
# Shim tests for restore-valkey.sh refusals: every refusal exits 5 and the target never sees a flush.
# valkey-cli, valkey-server, mc and openssl are shims that log their arguments (and stdin lines).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRET="secret"
PASS=0
FAILN=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAILN=$((FAILN + 1)); echo "  FAIL $1"; }
expect() {
  local d="$1"
  shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}

TARGET_HOST=10.9.9.9

new_env() { # header-bytes (printf format)
  WORK=$(mktemp -d)
  STUBS="$WORK/bin"
  mkdir -p "$STUBS"
  export STUB_LOG="$WORK/log"
  : >"$STUB_LOG"
  printf "$1" >"$WORK/fixture.rdb"
  export MC_FIXTURE="$WORK/fixture.rdb"
  cat >"$STUBS/mc" <<'STUB'
#!/bin/bash
[ "$1" = "cp" ] && cp "$MC_FIXTURE" "$3"
exit 0
STUB
  cat >"$STUBS/valkey-server" <<'STUB'
#!/bin/bash
echo "valkey-server $*" >>"$STUB_LOG"
while [ $# -gt 0 ]; do
  if [ "$1" = "--pidfile" ]; then pidfile="$2"; fi
  if [ "$1" = "--logfile" ]; then logfile="$2"; fi
  shift
done
if [ "${SHIM_LOADER_DIES:-0}" = "1" ]; then
  echo 999999 >"$pidfile"
  echo "# Internal error in RDB reading offset 0 -> Unexpected EOF reading RDB file" >"$logfile"
else
  sleep 120 >/dev/null 2>&1 &
  echo $! >"$pidfile"
fi
exit 0
STUB
  cat >"$STUBS/valkey-cli" <<'STUB'
#!/bin/bash
# Shim: loader = 127.0.0.1, anything else is the target. Logs args and stdin lines per side.
host=""
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
  [ "${args[$i]}" = "-h" ] && host="${args[$((i + 1))]}"
  i=$((i + 1))
done
if [ "$host" = "127.0.0.1" ]; then side=loader; else side=target; fi
echo "$side argv: $*" >>"$STUB_LOG"
if [ -n "${REDISCLI_AUTH:-}" ] && [ "$side" = target ]; then echo "target auth-env-set" >>"$STUB_LOG"; fi
all="$*"
if [ ! -t 0 ]; then
  stdin="$(cat)"
else
  stdin=""
fi
[ -n "$stdin" ] && printf '%s\n' "$stdin" | sed "s/^/$side stdin: /" >>"$STUB_LOG"
if [ "$side" = loader ]; then
  case "$all" in
    *"INFO persistence"*) echo "loading:0" ;;
    *"INFO keyspace"*) [ "${SHIM_EMPTY:-0}" = "1" ] || echo "db0:keys=3,expires=0,avg_ttl=0" ;;
    *"SCAN"*"TYPE"*)
      if [[ "$all" == *"TYPE string"* ]]; then printf '1) "0"\n2) 1) "k1"\n'; else printf '1) "0"\n2) (empty array)\n'; fi ;;
    *"SCAN"*) printf '1) "0"\n2) 1) "k1"\n   2) "k2"\n' ;;
    *SHUTDOWN*) ;;
    *)
      case "$stdin" in
        TYPE*) echo "${SHIM_TYPE:-string}" ;;
        COPY*) echo "1" ;;
        MIGRATE*) echo "${SHIM_MIGRATE_REPLY:-OK}" ;;
      esac ;;
  esac
else
  case "$all" in
    *FLUSHALL*) echo OK ;;
    *DEL*) echo 1 ;;
    *DBSIZE*) echo 3 ;;
  esac
fi
exit 0
STUB
  chmod +x "$STUBS"/*
  export PATH="$STUBS:$PATH"
  export S3_BUCKET=backups S3_KEY=valkey/x.rdb DB_HOST=$TARGET_HOST DB_PORT=6379 DB_USER="" DB_PASSWORD="$SECRET"
  export VALKEY_LOADER_WAIT_S=5
  unset ENCRYPTION_KEY SHIM_LOADER_DIES SHIM_EMPTY SHIM_TYPE SHIM_MIGRATE_REPLY
}

run_restore() {
  OUT=$(bash "$ROOT/scripts/restore-valkey.sh" 2>&1)
  RC=$?
  printf '%s\n' "$OUT" | sed 's/^/    | /'
}

rc_is() { [ "$RC" -eq "$1" ]; }
no_flush() { ! grep -q 'target.*FLUSHALL' "$STUB_LOG"; }
did_flush() { grep -q 'target.*FLUSHALL' "$STUB_LOG"; }
no_secret() { ! printf "%s" "$OUT" | grep -qF -- "$SECRET" && ! grep "argv:" "$STUB_LOG" | grep -qF -- "$SECRET"; }
says() { printf '%s' "$OUT" | grep -qF -- "$1"; }

refusal_case() { # name, header printf, expected message
  echo "$1"
  expect "exit 5" rc_is 5
  expect "message: $3" says "$3"
  expect "target never flushed" no_flush
  expect "no secret in output or argv log" no_secret
}

new_env 'VALKEY0001xxxx'
run_restore
refusal_case "VALKEY magic is refused" x "unsupported RDB format, target not modified"

new_env 'REDIS0013xxxx'
run_restore
refusal_case "RDB version above 12 is refused" x "unsupported RDB format, target not modified"

new_env 'REDIS0012garbage'
SHIM_LOADER_DIES=1
export SHIM_LOADER_DIES
run_restore
refusal_case "corrupt file (loader exits) is refused" x "Unexpected EOF"

new_env 'REDIS0012xxxx'
SHIM_EMPTY=1
export SHIM_EMPTY
run_restore
refusal_case "empty keyspace is refused" x "backup contains no keys; target not modified"

new_env 'REDIS0012xxxx'
SHIM_TYPE=ReJSON-RL
export SHIM_TYPE
run_restore
refusal_case "module type is refused" x "unsupported key type 'ReJSON-RL'"

new_env 'REDIS0012xxxx'
SHIM_MIGRATE_REPLY="ERR Target instance replied with error: ERR Bad data format"
export SHIM_MIGRATE_REPLY
run_restore
refusal_case "failing probe is refused" x "target does not accept"

echo "passing path: probe accepted, flush after the gates, MIGRATE carries AUTH in stdin only"
new_env 'REDIS0012xxxx'
run_restore
expect "exit 0" rc_is 0
expect "target flushed" did_flush
expect "completed line" says "Valkey/Redis restore completed: 3 keys in 1 databases"
expect "password only via stdin AUTH" grep -q 'loader stdin: MIGRATE .* AUTH "secret"' "$STUB_LOG"
expect "password never in any argv" bash -c '! grep -E "argv:.*secret" "$1"' _ "$STUB_LOG"
expect "target auth through REDISCLI_AUTH" grep -q 'target auth-env-set' "$STUB_LOG"

echo "passing path without password: no AUTH in MIGRATE"
new_env 'REDIS0012xxxx'
DB_PASSWORD=""
export DB_PASSWORD
run_restore
expect "exit 0" rc_is 0
expect "no AUTH in MIGRATE" bash -c '! grep -q "stdin: MIGRATE.*AUTH" "$1"' _ "$STUB_LOG"

echo
echo "passed: $PASS, failed: $FAILN"
[ "$FAILN" -eq 0 ]
