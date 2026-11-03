#!/bin/bash
# Valkey/Redis restore.
#
# The backup is an RDB file. It is loaded into a local, throwaway valkey-server
# (built from the same fork commit as the OSC catalog build, see Dockerfile) and
# the keys are then copied to the target with MIGRATE. The target is only
# flushed after the backup has been proven loadable and the target has been
# proven to accept payloads of this RDB version. Every refusal exits 5 and
# leaves the target untouched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=error-trap.sh
. "${SCRIPT_DIR}/error-trap.sh"

DB_HOST="${DB_HOST:-}"
if [ -z "$DB_HOST" ]; then
  echo "ERROR: missing required variable DB_HOST" >&2
  exit 1
fi
DB_PORT="${DB_PORT:-6379}"
DB_USER="${DB_USER:-}"
DB_PASSWORD="${DB_PASSWORD:-}"
LOADER_PORT="${VALKEY_LOADER_PORT:-6390}"
MIGRATE_TIMEOUT_MS="${VALKEY_MIGRATE_TIMEOUT_MS:-60000}"
LOADER_WAIT_S="${VALKEY_LOADER_WAIT_S:-3600}"
BATCH_SIZE=500
SUPPORTED_RDB_MAX=12

WORK="$(mktemp -d /tmp/restore-valkey.XXXXXX)"
DUMP_FILE="${WORK}/dump.rdb"
LOADER_PID="${WORK}/loader.pid"
LOADER_LOG="${WORK}/loader.log"
PROBE_KEY="__db_backuper_probe__:${RANDOM}${RANDOM}${RANDOM}"
LOADER_STARTED=0

refuse() {
  echo "ERROR: $*" >&2
  exit 5
}

cleanup() {
  local rc=$?
  if [ "$LOADER_STARTED" = "1" ]; then
    valkey-cli -h 127.0.0.1 -p "$LOADER_PORT" SHUTDOWN NOSAVE >/dev/null 2>&1 || true
    if [ -f "$LOADER_PID" ]; then
      kill "$(cat "$LOADER_PID" 2>/dev/null)" >/dev/null 2>&1 || true
    fi
  fi
  rm -rf "$WORK"
  exit "$rc"
}
trap cleanup EXIT

# Calls against the target. The password goes through REDISCLI_AUTH, never argv.
tcli() {
  if [ -n "$DB_PASSWORD" ]; then
    if [ -n "$DB_USER" ]; then
      REDISCLI_AUTH="$DB_PASSWORD" valkey-cli --no-auth-warning --user "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" "$@"
    else
      REDISCLI_AUTH="$DB_PASSWORD" valkey-cli --no-auth-warning -h "$DB_HOST" -p "$DB_PORT" "$@"
    fi
  else
    valkey-cli -h "$DB_HOST" -p "$DB_PORT" "$@"
  fi
}

# Calls against the local loader.
lcli() {
  valkey-cli -h 127.0.0.1 -p "$LOADER_PORT" "$@"
}

# Quote a string so that valkey-cli's stdin parser reads it back unchanged.
quote() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

# Auth part of a MIGRATE command. Three cases: no password, password, user and password.
migrate_auth() {
  if [ -z "$DB_PASSWORD" ]; then
    return 0
  elif [ -z "$DB_USER" ]; then
    printf 'AUTH %s' "$(quote "$DB_PASSWORD")"
  else
    printf 'AUTH2 %s %s' "$(quote "$DB_USER")" "$(quote "$DB_PASSWORD")"
  fi
}

# List the keys of a loader db (quoted, one per line). Optional type filter.
scan_keys() {
  local db="$1" type="${2:-}" cursor=0 out line
  while :; do
    if [ -n "$type" ]; then
      out="$(lcli -n "$db" --no-raw SCAN "$cursor" COUNT 1000 TYPE "$type")" || return 1
    else
      out="$(lcli -n "$db" --no-raw SCAN "$cursor" COUNT 1000)" || return 1
    fi
    cursor=""
    while IFS= read -r line; do
      if [ -z "$cursor" ] && [[ "$line" =~ ^1\)\ \"([0-9]+)\"$ ]]; then
        cursor="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^([0-9]+\)[[:space:]])?[[:space:]]*[0-9]+\)\ (\".*\")$ ]]; then
        printf '%s\n' "${BASH_REMATCH[2]}"
      fi
    done <<<"$out"
    [ -n "$cursor" ] || return 1
    [ "$cursor" = "0" ] && break
  done
  return 0
}

echo "Starting Valkey/Redis restore: ${DB_HOST}:${DB_PORT}"

# a. Download and decrypt
RESTORE_STEP="download"
"${SCRIPT_DIR}/s3-download.sh" "${S3_BUCKET}" "${S3_KEY}" "${WORK}/download.rdb" || { echo "ERROR: S3 download failed" >&2; exit 3; }
if [ -n "${ENCRYPTION_KEY:-}" ]; then
  RESTORE_STEP="decrypt"
  "${SCRIPT_DIR}/decrypt.sh" "${WORK}/download.rdb" "$DUMP_FILE" || { echo "ERROR: Decryption failed" >&2; exit 4; }
  rm -f "${WORK}/download.rdb"
else
  RESTORE_STEP="download"
  mv "${WORK}/download.rdb" "$DUMP_FILE"
fi

RESTORE_STEP="restore"

# b. Header gate: REDIS + 4 digit version 1..12
HEADER="$(head -c 9 "$DUMP_FILE" | LC_ALL=C tr -c '[:print:]' '?')"
if [[ ! "$HEADER" =~ ^REDIS[0-9]{4}$ ]]; then
  refuse "unsupported RDB format, target not modified"
fi
RDB_VERSION=$((10#${HEADER:5:4}))
if [ "$RDB_VERSION" -lt 1 ] || [ "$RDB_VERSION" -gt "$SUPPORTED_RDB_MAX" ]; then
  refuse "unsupported RDB format, target not modified"
fi

# c. Start the loader
valkey-server --bind 127.0.0.1 --port "$LOADER_PORT" --protected-mode yes \
  --dir "$WORK" --dbfilename "dump.rdb" --save "" --appendonly no \
  --daemonize yes --pidfile "$LOADER_PID" --logfile "$LOADER_LOG" >/dev/null 2>&1 || true
LOADER_STARTED=1

loader_alive() {
  local pid
  [ -f "$LOADER_PID" ] || return 1
  pid="$(cat "$LOADER_PID" 2>/dev/null)"
  kill -0 "$pid" >/dev/null 2>&1 || return 1
  # An exited daemon can linger as a zombie (no init reaping it in the pod): treat as dead.
  if [ -r "/proc/${pid}/status" ] && grep -q '^State:[[:space:]]*Z' "/proc/${pid}/status"; then
    return 1
  fi
  return 0
}
loader_failure() {
  local last
  last="$(grep -v '^[[:space:]]*$' "$LOADER_LOG" 2>/dev/null | tail -n 1 || true)"
  refuse "backup could not be loaded (${last:-loader did not start}), target not modified"
}

waited=0
loaded=0
while [ "$waited" -lt "$LOADER_WAIT_S" ]; do
  if ! loader_alive; then
    # The pidfile can appear a moment after the process starts.
    sleep 1
    loader_alive || loader_failure
  fi
  if lcli INFO persistence 2>/dev/null | tr -d '\r' | grep -q '^loading:0$'; then
    loaded=1
    break
  fi
  sleep 1
  waited=$((waited + 1))
done
[ "$loaded" = "1" ] || refuse "loader did not finish loading within ${LOADER_WAIT_S}s, target not modified"

# d. Loadable gate
declare -A DB_KEYS
TOTAL_KEYS=0
while IFS= read -r line; do
  if [[ "$line" =~ ^db([0-9]+):keys=([0-9]+) ]]; then
    DB_KEYS[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
    TOTAL_KEYS=$((TOTAL_KEYS + BASH_REMATCH[2]))
  fi
done < <(lcli INFO keyspace | tr -d '\r')
if [ "$TOTAL_KEYS" -eq 0 ]; then
  refuse "backup contains no keys; target not modified"
fi
DB_LIST="$(printf '%s\n' "${!DB_KEYS[@]}" | sort -n)"
DB_COUNT="$(printf '%s\n' "$DB_LIST" | grep -c .)"

# e. Target acceptance probe, one key per type, before any destructive write
declare -A PROBE_SAMPLE # type -> "db<TAB>quoted key"
for db in $DB_LIST; do
  for t in string list set zset hash stream; do
    [ -n "${PROBE_SAMPLE[$t]:-}" ] && continue
    first="$(scan_keys "$db" "$t" | head -n 1 || true)"
    [ -n "$first" ] && PROBE_SAMPLE[$t]="${db}"$'\t'"${first}"
  done
  # Any other type (a module type) cannot be probed or restored. Sample the first keys.
  while IFS= read -r qkey; do
    [ -n "$qkey" ] || continue
    ktype="$(printf 'TYPE %s\n' "$qkey" | lcli -n "$db" | tr -d '\r')"
    case "$ktype" in
      string | list | set | zset | hash | stream) ;;
      *) refuse "backup contains unsupported key type '${ktype}', target not modified" ;;
    esac
  done < <(scan_keys "$db" | head -n 1000 || true)
done
[ "${#PROBE_SAMPLE[@]}" -gt 0 ] || refuse "no probe key could be selected, target not modified"

AUTH_PART="$(migrate_auth)"
for t in "${!PROBE_SAMPLE[@]}"; do
  db="${PROBE_SAMPLE[$t]%%$'\t'*}"
  qkey="${PROBE_SAMPLE[$t]#*$'\t'}"
  printf 'COPY %s %s REPLACE\n' "$qkey" "$(quote "$PROBE_KEY")" | lcli -n "$db" >/dev/null \
    || refuse "target probe failed for type ${t}, target not modified"
  reply="$(printf 'MIGRATE %s %s %s %s 5000 REPLACE %s\n' "$(quote "$DB_HOST")" "$DB_PORT" "$(quote "$PROBE_KEY")" "$db" "$AUTH_PART" | lcli -n "$db" 2>&1 | tr -d '\r' | head -n 1 || true)"
  tcli -n "$db" DEL "$PROBE_KEY" >/dev/null 2>&1 || true
  lcli -n "$db" DEL "$PROBE_KEY" >/dev/null 2>&1 || true
  if [ "$reply" != "OK" ]; then
    refuse "target does not accept ${t} payloads of RDB ${RDB_VERSION} (${reply:-no reply}), target not modified"
  fi
done

# f. In-place semantics: flush only after every gate has passed
flush_reply="$(tcli FLUSHALL SYNC 2>&1 || true)"
[ "$flush_reply" = "OK" ] || refuse "flush of the target failed (${flush_reply:-no reply}), target not modified"

# g. Transfer
MOVED=0
for db in $DB_LIST; do
  expected="${DB_KEYS[$db]}"
  keyfile="${WORK}/keys.${db}"
  scan_keys "$db" >"$keyfile" || refuse "target partially restored: ${MOVED} of ${TOTAL_KEYS} keys (key listing of db ${db} failed)"
  rm -f "${keyfile}.part."*
  split -l "$BATCH_SIZE" "$keyfile" "${keyfile}.part."
  for part in "${keyfile}.part."*; do
    [ -f "$part" ] || continue
    n="$(grep -c . "$part")"
    start="$(date +%s)"
    cmd="MIGRATE $(quote "$DB_HOST") ${DB_PORT} \"\" ${db} ${MIGRATE_TIMEOUT_MS} COPY REPLACE ${AUTH_PART} KEYS $(tr '\n' ' ' <"$part")"
    reply="$(printf '%s\n' "$cmd" | lcli -n "$db" 2>&1 | tr -d '\r' | head -n 1 || true)"
    cmd=""
    if [ "$reply" != "OK" ] && [ "$reply" != "NOKEY" ]; then
      refuse "target partially restored: ${MOVED} of ${TOTAL_KEYS} keys (db ${db}, ${reply:-no reply})"
    fi
    MOVED=$((MOVED + n))
    echo "db ${db}: migrated ${n} keys in $(($(date +%s) - start))s"
    rm -f "$part"
  done
  rm -f "$keyfile"
  echo "db ${db}: ${expected} keys on the loader"
done

# i. Verify: the target must hold at least as many keys as the loader in every db
for db in $DB_LIST; do
  have="$(tcli -n "$db" DBSIZE 2>&1 | tr -d '\r' || true)"
  [[ "$have" =~ ^[0-9]+$ ]] || refuse "target partially restored: ${MOVED} of ${TOTAL_KEYS} keys (DBSIZE of db ${db} failed)"
  if [ "$have" -lt "${DB_KEYS[$db]}" ]; then
    refuse "target partially restored: db ${db} holds ${have} of ${DB_KEYS[$db]} keys"
  fi
done

# j.
echo "Valkey/Redis restore completed: ${TOTAL_KEYS} keys in ${DB_COUNT} databases"
