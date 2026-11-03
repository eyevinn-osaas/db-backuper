#!/bin/bash
# Tests that entrypoint.sh reports only whether ENCRYPTION_KEY is set, never its value.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRET="secret-value-123"
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
  mkdir -p "$WORK/opt" "$WORK/bin"
  cp "$ROOT/scripts/entrypoint.sh" "$WORK/opt/entrypoint.sh"
  chmod +x "$WORK/opt/entrypoint.sh"
  printf '#!/bin/bash\nexit 0\n' > "$WORK/bin/mc"
  chmod +x "$WORK/bin/mc"
  OUT="$WORK/out"
}

# run_entry [VAR=value ...]: with no backup-postgres.sh beside it, the entrypoint prints the header
# and exits 1 at "Script not found". That exit is expected.
run_entry() {
  env -u ENCRYPTION_KEY PATH="$WORK/bin:$PATH" \
    S3_ENDPOINT=http://127.0.0.1:9 S3_ACCESS_KEY=ak S3_SECRET_KEY=sk S3_BUCKET=b S3_KEY=k \
    OPERATION=backup DATABASE_URL=postgres://u:p@127.0.0.1:5432/db \
    "$@" bash "$WORK/opt/entrypoint.sh" > "$OUT" 2>&1
}

has_line() { grep -qxF "$1" "$OUT"; }
no_secret() { ! grep -qF "$SECRET" "$OUT"; }

echo "ENCRYPTION_KEY set: reports enabled, never the value"
new_env; run_entry ENCRYPTION_KEY="$SECRET"
expect "line is exactly 'Encryption:    enabled'" has_line "Encryption:    enabled"
expect "key value not in output" no_secret

echo "ENCRYPTION_KEY unset: reports disabled"
new_env; run_entry
expect "line is exactly 'Encryption:    disabled'" has_line "Encryption:    disabled"

echo "ENCRYPTION_KEY empty: reports disabled"
new_env; run_entry ENCRYPTION_KEY=
expect "line is exactly 'Encryption:    disabled'" has_line "Encryption:    disabled"

echo
echo "passed=$PASS failed=$FAILN"
[ "$FAILN" -eq 0 ]
