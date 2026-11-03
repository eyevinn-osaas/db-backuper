#!/bin/bash
# Sourced by entrypoint.sh (OPERATION=restore) and by every restore-*.sh.
#
# Gives every failure that has no explicit handler one fixed-class line on stderr:
#   ERROR: restore failed during <step>
# and exits with the failing command's own status. The console shows the last ERROR: line of
# the job log.
#
# The ERR trap fires only for failures that set -e would turn into an exit. A command on the
# left of `|| { echo "ERROR: ..."; exit N; }`, and refuse() in restore-valkey.sh, never reach
# it, so those paths keep printing exactly the line they print today and nothing is added.
#
# The trap never prints $BASH_COMMAND: it can hold a database URL, a password or a key.
# RESTORE_STEP is set by the caller before each phase:
#   download | decrypt | decompress | restore | configure S3
set -E

RESTORE_STEP="${RESTORE_STEP:-restore}"

_restore_error_trap() {
  local rc=$?
  # Subshells (command substitutions, pipelines) inherit the trap. Only the main shell prints,
  # so one failure yields one line; the subshell passes the status up.
  if [ "${BASHPID:-$$}" = "$$" ]; then
    echo "ERROR: restore failed during ${RESTORE_STEP}" >&2
  fi
  exit "$rc"
}
trap _restore_error_trap ERR
