#!/bin/bash
# Integration test for backup-valkey.sh + restore-valkey.sh against REAL servers.
# Needs valkey-server and valkey-cli built from the pinned fork commit (see Dockerfile):
#   VALKEY_BIN_DIR=/tmp/valkey-src/src bash tests/restore-valkey.integration.sh
# Skipped (exit 0) when no valkey-server is available. Only mc is shimmed (it copies files).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -n "${VALKEY_BIN_DIR:-}" ]; then
  export PATH="$VALKEY_BIN_DIR:$PATH"
fi
if ! command -v valkey-server >/dev/null 2>&1 || ! command -v valkey-cli >/dev/null 2>&1; then
  echo "SKIP: valkey-server/valkey-cli not found (set VALKEY_BIN_DIR)"
  exit 0
fi

PASS=0
FAILN=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAILN=$((FAILN + 1)); echo "  FAIL $1"; }
expect() { # description, command...
  local d="$1"
  shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}

WORK="$(mktemp -d /tmp/valkey-it.XXXXXX)"
SHIMS="$WORK/shims"
STORE="$WORK/store"
mkdir -p "$SHIMS" "$STORE"
PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do
    [ -n "$p" ] && kill "$p" >/dev/null 2>&1
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

# redis-cli for backup-valkey.sh when only valkey-cli is present
if ! command -v redis-cli >/dev/null 2>&1; then
  ln -s "$(command -v valkey-cli)" "$SHIMS/redis-cli"
fi
# mc shim: "backup/<bucket>/<key>" maps to $STORE/<bucket>/<key>
cat >"$SHIMS/mc" <<'EOF'
#!/bin/bash
case "$1" in
  cp)
    src="$2"; dst="$3"
    case "$src" in backup/*) src="$STORE/${src#backup/}" ;; esac
    case "$dst" in backup/*) dst="$STORE/${dst#backup/}"; mkdir -p "$(dirname "$dst")" ;; esac
    cp "$src" "$dst" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$SHIMS/mc"
export STORE
export PATH="$SHIMS:$PATH"

SRC_PORT=6401
T_PW_PORT=6402
T_NOPW_PORT=6403
EMPTY_PORT=6404
PW=secret

start_server() { # port dir [extra args...]
  local port="$1" dir="$2"
  shift 2
  mkdir -p "$dir"
  valkey-server --port "$port" --bind 127.0.0.1 --dir "$dir" --save "" --appendonly no \
    --daemonize yes --pidfile "$dir/pid" --logfile "$dir/log" "$@" >/dev/null 2>&1
  for _ in $(seq 1 50); do
    if REDISCLI_AUTH="${REQ_AUTH:-}" valkey-cli -p "$port" PING >/dev/null 2>&1; then break; fi
    sleep 0.2
  done
  PIDS+=("$(cat "$dir/pid" 2>/dev/null)")
}

q() { # port db password -- reads quoted-input commands on stdin
  local port="$1" db="$2" pw="$3"
  if [ -n "$pw" ]; then
    REDISCLI_AUTH="$pw" valkey-cli --no-auth-warning --quoted-input -p "$port" -n "$db"
  else
    valkey-cli --quoted-input -p "$port" -n "$db"
  fi
}

start_server "$SRC_PORT" "$WORK/src"
REQ_AUTH=$PW start_server "$T_PW_PORT" "$WORK/tpw" --requirepass "$PW"
start_server "$T_NOPW_PORT" "$WORK/tnopw"
start_server "$EMPTY_PORT" "$WORK/empty"

echo "seed the source"
q "$SRC_PORT" 0 "" >/dev/null <<'EOF'
SET s1 hello
HSET h1 f v
RPUSH l1 a b c
SADD set1 x
ZADD z1 1 a 2 b
XADD st1 1-1 f v
SET ttl1 keep EX 1000
SET "sp ace\nnl\xffend" bin
EOF
q "$SRC_PORT" 3 "" >/dev/null <<'EOF'
SET d3 three
EOF

echo "backup with backup-valkey.sh"
# backup-valkey.sh detects BGSAVE completion by LASTSAVE (1 s resolution): let the start-up second pass
sleep 2
export S3_BUCKET=backups S3_KEY=valkey/good.rdb
(
  export DB_HOST=127.0.0.1 DB_PORT=$SRC_PORT DB_PASSWORD=""
  bash "$ROOT/scripts/backup-valkey.sh" >"$WORK/backup.out" 2>&1; sed "s/^/    | /" "$WORK/backup.out"
)
expect "backup exits 0" [ -f "$STORE/backups/valkey/good.rdb" ]
head -c 9 "$STORE/backups/valkey/good.rdb" >"$WORK/hdr"
expect "backup header is REDIS0012 (fork format)" [ "$(cat "$WORK/hdr")" = "REDIS0012" ]

# empty and corrupt backups
q "$EMPTY_PORT" 0 "" >/dev/null <<'EOF'
SAVE
EOF
mkdir -p "$STORE/backups/valkey"
cp "$WORK/empty/dump.rdb" "$STORE/backups/valkey/empty.rdb"
size="$(stat -c%s "$STORE/backups/valkey/good.rdb")"
head -c $((size / 2)) "$STORE/backups/valkey/good.rdb" >"$STORE/backups/valkey/corrupt.rdb"
printf 'NOTRDB-garbage' >"$STORE/backups/valkey/badheader.rdb"

run_restore() { # key port user password
  OUT="$(
    S3_KEY="valkey/$1" DB_HOST=127.0.0.1 DB_PORT="$2" DB_USER="$3" DB_PASSWORD="$4" \
      bash "$ROOT/scripts/restore-valkey.sh" 2>&1
  )"
  RC=$?
  echo "$OUT" | sed 's/^/    | /'
}

val() { # port pw db  <command on stdin> -> prints reply
  q "$1" "$3" "$2" | tr -d '\r'
}

verify_target() { # port pw label
  local port="$1" pw="$2" label="$3"
  expect "$label: string" [ "$(echo 'GET s1' | val "$port" "$pw" 0)" = "hello" ]
  expect "$label: hash" [ "$(echo 'HGET h1 f' | val "$port" "$pw" 0)" = "v" ]
  expect "$label: list" [ "$(echo 'LRANGE l1 0 -1' | val "$port" "$pw" 0 | tr '\n' ,)" = "a,b,c," ]
  expect "$label: set" [ "$(echo 'SMEMBERS set1' | val "$port" "$pw" 0)" = "x" ]
  expect "$label: zset" [ "$(echo 'ZRANGE z1 0 -1 WITHSCORES' | val "$port" "$pw" 0 | tr '\n' ,)" = "a,1,b,2," ]
  expect "$label: stream" [ "$(echo 'XLEN st1' | val "$port" "$pw" 0)" = "1" ]
  expect "$label: type of stream" [ "$(echo 'TYPE st1' | val "$port" "$pw" 0)" = "stream" ]
  ttl="$(echo 'TTL ttl1' | val "$port" "$pw" 0)"
  expect "$label: TTL kept (${ttl}s)" [ "$ttl" -gt 0 ]
  expect "$label: key with space, newline and \\xff" [ "$(echo 'GET "sp ace\nnl\xffend"' | val "$port" "$pw" 0)" = "bin" ]
  expect "$label: db 3" [ "$(echo 'GET d3' | val "$port" "$pw" 3)" = "three" ]
  expect "$label: pre-existing extra key is gone" [ "$(echo 'EXISTS extra' | val "$port" "$pw" 0)" = "0" ]
  expect "$label: db 0 has 8 keys" [ "$(echo 'DBSIZE' | val "$port" "$pw" 0)" = "8" ]
}

echo "restore into the password target (requirepass)"
echo 'SET extra before' | q "$T_PW_PORT" 0 "$PW" >/dev/null
echo 'SET extra3 before' | q "$T_PW_PORT" 3 "$PW" >/dev/null
run_restore good.rdb "$T_PW_PORT" "" "$PW"
expect "pw target: exit 0" [ "$RC" -eq 0 ]
expect "pw target: completed line" grep -q 'Valkey/Redis restore completed: 9 keys in 2 databases' <<<"$OUT"
verify_target "$T_PW_PORT" "$PW" "pw target"

echo "restore into the no-password target"
echo 'SET extra before' | q "$T_NOPW_PORT" 0 "" >/dev/null
run_restore good.rdb "$T_NOPW_PORT" "" ""
expect "no-pw target: exit 0" [ "$RC" -eq 0 ]
verify_target "$T_NOPW_PORT" "" "no-pw target"

echo "wrong password is refused before the flush"
echo 'SET keepme 1' | q "$T_PW_PORT" 0 "$PW" >/dev/null
run_restore good.rdb "$T_PW_PORT" "" "wrong"
expect "wrong password: exit 5" [ "$RC" -eq 5 ]
expect "wrong password: target intact" [ "$(echo 'GET keepme' | val "$T_PW_PORT" "$PW" 0)" = "1" ]
expect "wrong password: password not printed" bash -c '! grep -q "wrong" <<<"$1"' _ "$OUT"

for name in corrupt empty badheader; do
  echo "$name backup is refused and the target stays intact"
  echo 'SET keepme 1' | q "$T_NOPW_PORT" 0 "" >/dev/null
  run_restore "$name.rdb" "$T_NOPW_PORT" "" ""
  expect "$name: exit 5" [ "$RC" -eq 5 ]
  expect "$name: target keys intact" [ "$(echo 'GET keepme' | val "$T_NOPW_PORT" "" 0)" = "1" ]
  expect "$name: other keys intact" [ "$(echo 'GET s1' | val "$T_NOPW_PORT" "" 0)" = "hello" ]
done

echo
echo "passed: $PASS, failed: $FAILN"
[ "$FAILN" -eq 0 ]
