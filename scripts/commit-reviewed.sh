#!/bin/bash
# commit-reviewed.sh -- the only sanctioned way to create a commit while Quality
# Gate is enabled for a repository.
#
# It re-verifies, immediately before committing, that the staged diff and HEAD
# are byte-for-byte the ones that passed the final Codex review. Any drift is
# refused and the stale approval is invalidated.
#
# Usage:
#   commit-reviewed.sh -m "<commit message>"
#   commit-reviewed.sh -F <file>              # message read from a file
#   commit-reviewed.sh --message-file <file>  # same as -F
#   commit-reviewed.sh --stdin                # message read from stdin
#
# Optional:
#   --no-verify        pass through to git commit (only if the repo needs it)
#
# Exit codes: 0 committed, 1 refused/failed, 2 precondition failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./quality-gate-state.sh
. "$SCRIPT_DIR/quality-gate-state.sh"

MSG=""
MSG_FILE=""
READ_STDIN=0
NO_VERIFY=0

while [ $# -gt 0 ]; do
  case "$1" in
    -m|--message)      MSG="${2:-}"; shift 2 ;;
    -F|--message-file) MSG_FILE="${2:-}"; shift 2 ;;
    --stdin)           READ_STDIN=1; shift ;;
    --no-verify)       NO_VERIFY=1; shift ;;
    -h|--help)         sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) qg_err "Unknown argument: $1"; exit 2 ;;
  esac
done

# --- 1. Quality Gate must be ON ---------------------------------------------
qg_require_repo
if ! qg_is_enabled; then
  qg_err "Quality Gate is not enabled for this repository."
  qg_err "Use the normal git workflow, or run /qg:enable first."
  exit 2
fi

# --- resolve the commit message ---------------------------------------------
if [ "$READ_STDIN" -eq 1 ]; then
  MSG="$(cat)"
elif [ -n "$MSG_FILE" ]; then
  [ -f "$MSG_FILE" ] || { qg_err "Message file not found: $MSG_FILE"; exit 2; }
  MSG="$(cat "$MSG_FILE")"
fi

if [ -z "${MSG//[[:space:]]/}" ]; then
  qg_err "A commit message is required (-m, -F <file>, or --stdin)."
  exit 2
fi

# --- 2. approval marker must exist ------------------------------------------
MARKER=$(qg_approval_marker) || { qg_err "Could not resolve the approval marker path."; exit 2; }
if [ ! -f "$MARKER" ]; then
  cat >&2 <<'MSGX'
ERROR: No Quality Gate approval found.

Run /qg:gate to test, review with Codex, and approve the exact diff
before committing.
MSGX
  exit 1
fi

APPROVED_HEAD=$(sed -n 's/^head=//p' "$MARKER" | head -n1)
APPROVED_DIFF=$(sed -n 's/^diff_sha256=//p' "$MARKER" | head -n1)

if [ -z "$APPROVED_HEAD" ] || [ -z "$APPROVED_DIFF" ]; then
  qg_err "The Quality Gate approval marker is malformed. Refusing to commit."
  qg_remove_approval
  exit 1
fi

# --- staged changes must still exist ----------------------------------------
if ! qg_has_staged_changes; then
  qg_err "Nothing is staged. Refusing to create an empty commit."
  qg_remove_approval
  exit 1
fi

# --- 3/4. current state ------------------------------------------------------
CURRENT_HEAD=$(qg_head_sha)
CURRENT_DIFF=$(qg_staged_diff_sha) || { qg_err "Could not hash the staged diff."; exit 1; }

# --- 5. HEAD comparison ------------------------------------------------------
if [ "$CURRENT_HEAD" != "$APPROVED_HEAD" ]; then
  cat >&2 <<'MSGX'
ERROR: HEAD changed after Codex approval.

The previous review approval is no longer valid.
MSGX
  printf 'Approved HEAD: %s\nCurrent  HEAD: %s\n' "$APPROVED_HEAD" "$CURRENT_HEAD" >&2
  qg_remove_approval
  exit 1
fi

# --- 6. staged diff comparison ----------------------------------------------
if [ "$CURRENT_DIFF" != "$APPROVED_DIFF" ]; then
  cat >&2 <<'MSGX'
ERROR: The staged diff changed after Codex approval.

Run /qg:gate again before committing.
MSGX
  printf 'Approved diff sha256: %s\nCurrent  diff sha256: %s\n' "$APPROVED_DIFF" "$CURRENT_DIFF" >&2
  qg_remove_approval
  exit 1
fi

# --- commit ------------------------------------------------------------------
TMP_MSG=$(mktemp "${TMPDIR:-/tmp}/qg-commit-msg.XXXXXX") || { qg_err "mktemp failed."; exit 1; }
printf '%s\n' "$MSG" > "$TMP_MSG"

GIT_ARGS=(commit -F "$TMP_MSG" --cleanup=strip)
[ "$NO_VERIFY" -eq 1 ] && GIT_ARGS+=(--no-verify)

if git "${GIT_ARGS[@]}"; then
  NEW_SHA=$(git rev-parse --short HEAD 2>/dev/null)
  NEW_SHA_FULL=$(git rev-parse HEAD 2>/dev/null)
  rm -f "$TMP_MSG"
  # Approval is single-use.
  qg_remove_approval
  printf '\nReviewed commit created.\n'
  printf '  SHA:     %s\n' "$NEW_SHA"
  printf '  Full:    %s\n' "$NEW_SHA_FULL"
  printf '  Message: %s\n' "$(printf '%s' "$MSG" | head -n1)"
  printf '  Approval marker consumed.\n'
  exit 0
else
  RC=$?
  rm -f "$TMP_MSG"
  qg_err "git commit failed (exit ${RC}). Invalidating the Quality Gate approval so it cannot be reused."
  qg_remove_approval
  qg_err "Re-run /qg:gate after resolving the failure."
  exit 1
fi
