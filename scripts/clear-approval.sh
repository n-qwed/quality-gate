#!/bin/bash
# clear-approval.sh -- invalidate any pending Quality Gate approval.
#
# Call this whenever an approval must not be reused:
#   * at the start of a Quality Gate run
#   * when fixing resumes after a review
#   * on approval mismatch
#   * after a failed commit
#
# It NEVER touches the enable marker: clearing an approval does not disable the
# Quality Gate. Exits 0 whether or not an approval existed.
#
# Usage: clear-approval.sh [--quiet]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./quality-gate-state.sh
. "$SCRIPT_DIR/quality-gate-state.sh"

QUIET=0
case "${1:-}" in
  --quiet) QUIET=1 ;;
  -h|--help) sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") : ;;
  *) qg_die "Unknown argument: $1" ;;
esac

qg_require_repo

MARKER=$(qg_approval_marker) || exit 0

if [ -f "$MARKER" ]; then
  rm -f "$MARKER"
  [ "$QUIET" -eq 1 ] || printf 'Quality Gate approval cleared.\n'
else
  [ "$QUIET" -eq 1 ] || printf 'No Quality Gate approval was pending.\n'
fi

# Stale review artifacts are also invalid once the approval is gone.
for suffix in "" ".lastmsg" ".stdout" ".stderr" ".timedout" ".fingerprint"; do
  f=$(qg_git_path "quality-gate-review-latest.md${suffix}") || continue
  [ -f "$f" ] && rm -f "$f"
done

exit 0
