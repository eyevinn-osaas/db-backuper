#!/bin/bash
# Lint, then run every tests/*.test.sh; exit non-zero if any fails.
cd "$(dirname "$0")" || exit 1
fail=0

# Lint: an `exit <N>` with N not 0 in entrypoint.sh or restore-*.sh must be preceded, on the same
# line or on the line directly before it, by an `ERROR:` echo (refuse() is the one wrapper;
# its own echo sits on the line before its exit). Otherwise the job log ends without an ERROR: line for the console to show.
echo "### lint: exit <N> without ERROR:"
lint_out=$(awk '
  FNR == 1 { n = 0 }
  { hist[++n] = $0 }
  /^[[:space:]]*#/ { next }
  /(^|[^[:alnum:]_])exit[[:space:]]+[1-9][0-9]*/ {
    found = ($0 ~ /ERROR:/)
    for (i = n - 1; i >= 1 && i >= n - 1 && !found; i--) {
      if (hist[i] ~ /ERROR:/) found = 1
    }
    if (!found) printf "%s:%d: exit without a preceding ERROR: echo: %s\n", FILENAME, FNR, $0
  }
' ../scripts/entrypoint.sh ../scripts/restore-*.sh)
if [ -n "$lint_out" ]; then
  printf '%s\n' "$lint_out"
  fail=1
else
  echo "  ok"
fi

for t in ./*.test.sh ./*.integration.sh; do
  echo "### $t"
  bash "$t" || fail=1
done
if [ "$fail" -ne 0 ]; then echo "SOME TEST FILES FAILED"; exit 1; fi
echo "ALL TEST FILES PASSED"
