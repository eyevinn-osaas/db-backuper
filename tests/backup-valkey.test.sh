#!/bin/bash
# Tests for backup-valkey.sh around BGSAVE: a rejected BGSAVE (another save running) must wait and succeed,
# any other BGSAVE failure must exit 2 with ERROR: BGSAVE failed. redis-cli, mc and sleep are shims on PATH.
# A real-server case runs when valkey-server is available (VALKEY_BIN_DIR), otherwise it is skipped.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRET="s3cretpw"
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
  mkdir -p "$STUBS"
  # The image chmods the scripts; a checkout may not carry the exec bit
  cp -r "$ROOT/scripts" "$WORK/scripts"
  chmod +x "$WORK/scripts"/*.sh
  export STUB_LOG="$WORK/log" STATE="$WORK/state" TMPDIR="$WORK"
  : >"$STUB_LOG"
  echo 0 >"$STATE"
  # redis-cli shim: BGSAVE reply from SHIM_BGSAVE; INFO persistence from SHIM_INFO_SEQ (space separated
  # in_progress values, last one repeats) and SHIM_SAVE_STATUS. LASTSAVE is deliberately not served.
  cat >"$STUBS/redis-cli" <<'STUB'
#!/bin/bash
echo "argv: $*" >>"$STUB_LOG"
case "$*" in
  *BGSAVE*) printf '%s\n' "${SHIM_BGSAVE:-Background saving started}" ;;
  *"INFO persistence"*)
    n=$(cat "$STATE")
    read -r -a seq <<<"${SHIM_INFO_SEQ:-0}"
    idx=$n
    [ "$idx" -ge "${#seq[@]}" ] && idx=$((${#seq[@]} - 1))
    echo $((n + 1)) >"$STATE"
    printf 'rdb_bgsave_in_progress:%s\r\nrdb_last_bgsave_status:%s\r\n' "${seq[$idx]}" "${SHIM_SAVE_STATUS:-ok}" ;;
  *--rdb*)
    out="${*: -1}"
    printf 'REDIS0012data' >"$out" ;;
  *LASTSAVE*) echo "LASTSAVE must not be used" >&2; exit 1 ;;
esac
exit 0
STUB
  cat >"$STUBS/mc" <<'STUB'
#!/bin/bash
[ "$1" = "cp" ] && echo "uploaded $2 -> $3" >>"$STUB_LOG"
exit 0
STUB
  printf '#!/bin/bash\nexit 0\n' >"$STUBS/sleep"
  chmod +x "$STUBS"/*
  export PATH="$STUBS:$PATH"
  export S3_BUCKET=backups S3_KEY=valkey/x.rdb DB_HOST=10.9.9.9 DB_PORT=6379 DB_PASSWORD="$SECRET"
  unset ENCRYPTION_KEY SHIM_BGSAVE SHIM_INFO_SEQ SHIM_SAVE_STATUS
}

run_backup() {
  OUT=$(bash "$WORK/scripts/backup-valkey.sh" 2>&1)
  RC=$?
  printf '%s\n' "$OUT" | sed 's/^/    | /'
}

rc_is() { [ "$RC" -eq "$1" ]; }
says() { printf '%s' "$OUT" | grep -qF -- "$1"; }
uploaded() { grep -q '^uploaded ' "$STUB_LOG"; }
not_uploaded() { ! uploaded; }
no_secret_in_output() { ! printf '%s' "$OUT" | grep -qF -- "$SECRET"; }

echo "rejected BGSAVE (save already running) waits, then succeeds"
new_env
SHIM_BGSAVE="ERR Background save already in progress"
SHIM_INFO_SEQ="1 0"
export SHIM_BGSAVE SHIM_INFO_SEQ
run_backup
expect "exit 0" rc_is 0
expect "says it is waiting for the running save" says "A background save is already running, waiting for it to finish"
expect "BGSAVE completed" says "BGSAVE completed"
expect "uploaded" uploaded

echo "normal BGSAVE succeeds"
new_env
run_backup
expect "exit 0" rc_is 0
expect "BGSAVE completed" says "BGSAVE completed"
expect "uploaded" uploaded

echo "completion does not depend on LASTSAVE (idle and ok on the first poll)"
new_env
SHIM_INFO_SEQ="0"
export SHIM_INFO_SEQ
run_backup
expect "exit 0" rc_is 0
expect "LASTSAVE never called" bash -c '! grep -q LASTSAVE "$1"' _ "$STUB_LOG"

for reply in "NOAUTH Authentication required." "WRONGPASS invalid username-password pair" "ERR Another child process is active" "Background saving scheduled"; do
  echo "BGSAVE reply '$reply' fails"
  new_env
  SHIM_BGSAVE="$reply"
  export SHIM_BGSAVE
  run_backup
  expect "exit 2" rc_is 2
  expect "ERROR: BGSAVE failed" says "ERROR: BGSAVE failed"
  expect "no password in output" no_secret_in_output
  expect "not uploaded" not_uploaded
done

echo "last background save status err fails"
new_env
SHIM_SAVE_STATUS=err
export SHIM_SAVE_STATUS
run_backup
expect "exit 2" rc_is 2
expect "ERROR: BGSAVE failed" says "ERROR: BGSAVE failed"
expect "not uploaded" not_uploaded

echo "save never finishes: bounded failure"
new_env
SHIM_INFO_SEQ="1"
export SHIM_INFO_SEQ
run_backup
expect "exit 2" rc_is 2
expect "timeout message" says "ERROR: BGSAVE did not complete within 120 seconds"
expect "not uploaded" not_uploaded

# Real-server case: two concurrent backups, the second starts while the first save is running.
if [ -n "${VALKEY_BIN_DIR:-}" ]; then
  export PATH="$VALKEY_BIN_DIR:$PATH"
fi
echo "real server: concurrent backups"
if ! command -v valkey-server >/dev/null 2>&1 || ! command -v valkey-cli >/dev/null 2>&1; then
  echo "  SKIP: valkey-server/valkey-cli not found (set VALKEY_BIN_DIR)"
else
  RW=$(mktemp -d /tmp/backup-valkey-it.XXXXXX)
  SHIMS="$RW/shims"
  STORE="$RW/store"
  mkdir -p "$SHIMS" "$STORE" "$RW/data" "$RW/a" "$RW/b"
  cp -r "$ROOT/scripts" "$RW/scripts"
  chmod +x "$RW/scripts"/*.sh
  ln -s "$(command -v valkey-cli)" "$SHIMS/redis-cli"
  cat >"$SHIMS/mc" <<'EOF'
#!/bin/bash
if [ "$1" = "cp" ]; then
  dst="${3#backup/}"
  mkdir -p "$(dirname "$STORE/$dst")"
  cp "$2" "$STORE/$dst"
fi
exit 0
EOF
  chmod +x "$SHIMS/mc"
  export STORE
  PORT=6411
  valkey-server --port $PORT --bind 127.0.0.1 --dir "$RW/data" --save "" --appendonly no --enable-debug-command yes \
    --daemonize yes --pidfile "$RW/pid" --logfile "$RW/log" >/dev/null 2>&1
  for _ in $(seq 1 50); do valkey-cli -p $PORT PING >/dev/null 2>&1 && break; sleep 0.2; done
  valkey-cli -p $PORT DEBUG POPULATE 3000 >/dev/null 2>&1
  valkey-cli -p $PORT CONFIG SET rdb-key-save-delay 1000 >/dev/null 2>&1 # about 3 s per save
  # Real sleep and mc, no unit-test shims
  export PATH="$SHIMS:$(echo "$PATH" | tr ':' '\n' | grep -v "$WORK/bin" | paste -sd:)"
  export DB_HOST=127.0.0.1 DB_PORT=$PORT DB_PASSWORD=""
  (TMPDIR="$RW/a" S3_KEY=a.rdb bash "$RW/scripts/backup-valkey.sh" >"$RW/a.out" 2>&1; echo $? >"$RW/a.rc") &
  for _ in $(seq 1 50); do
    valkey-cli -p $PORT INFO persistence | grep -q 'rdb_bgsave_in_progress:1' && break
    sleep 0.1
  done
  (TMPDIR="$RW/b" S3_KEY=b.rdb bash "$RW/scripts/backup-valkey.sh" >"$RW/b.out" 2>&1; echo $? >"$RW/b.rc") &
  wait
  sed 's/^/    a| /' "$RW/a.out"
  sed 's/^/    b| /' "$RW/b.out"
  expect "run A exit 0" grep -qx 0 "$RW/a.rc"
  expect "run B exit 0" grep -qx 0 "$RW/b.rc"
  expect "run B saw the running save" grep -q "A background save is already running" "$RW/b.out"
  expect "upload A is an RDB" bash -c 'head -c 5 "$1" | grep -q REDIS' _ "$STORE/backups/a.rdb"
  expect "upload B is an RDB" bash -c 'head -c 5 "$1" | grep -q REDIS' _ "$STORE/backups/b.rdb"
  valkey-cli -p $PORT SHUTDOWN NOSAVE >/dev/null 2>&1
  rm -rf "$RW"
fi

echo
echo "passed: $PASS, failed: $FAILN"
[ "$FAILN" -eq 0 ]
