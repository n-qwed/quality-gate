#!/bin/bash
# approve-commit.sh -- freeze the exact staged diff that passed the final Codex
# review, so that commit-reviewed.sh can refuse anything that changed since.
#
# Usage:
#   approve-commit.sh [--note <text>]
#
# The approval marker lives inside the Git administrative directory
# (git rev-parse --git-path quality-gate-approved) so it is invisible to
# `git status` and can never be committed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./quality-gate-state.sh
. "$SCRIPT_DIR/quality-gate-state.sh"

NOTE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --note) NOTE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) qg_die "Unknown argument: $1" ;;
  esac
done

qg_require_repo
qg_require_enabled

if ! qg_has_staged_changes; then
  qg_die "Nothing is staged. Stage the reviewed files before creating a Quality Gate approval."
fi

HEAD_SHA=$(qg_head_sha)
DIFF_SHA=$(qg_staged_diff_sha) || qg_die "Could not hash the staged diff."
[ -n "$DIFF_SHA" ] || qg_die "Could not hash the staged diff (empty hash)."

MARKER=$(qg_approval_marker) || qg_die "Could not resolve the approval marker path."

# Record the working-tree state as well, purely for diagnostics.
UNSTAGED_COUNT=$(git diff --name-only | wc -l | tr -d ' ')
UNTRACKED_COUNT=$(git ls-files --others --exclude-standard | wc -l | tr -d ' ')
STAGED_FILES=$(git diff --cached --name-only)

umask 077
{
  printf 'head=%s\n' "$HEAD_SHA"
  printf 'diff_sha256=%s\n' "$DIFF_SHA"
  printf 'approved_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'repo=%s\n' "$(qg_repo_root)"
  printf 'branch=%s\n' "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  printf 'unstaged_files=%s\n' "$UNSTAGED_COUNT"
  printf 'untracked_files=%s\n' "$UNTRACKED_COUNT"
  [ -n "$NOTE" ] && printf 'note=%s\n' "$NOTE"
  printf 'staged_files_begin\n'
  printf '%s\n' "$STAGED_FILES"
  printf 'staged_files_end\n'
} > "$MARKER" || qg_die "Could not write the approval marker at: $MARKER"

printf 'Quality Gate approval created.\n'
printf '  HEAD:        %s\n' "$HEAD_SHA"
printf '  Staged diff: sha256:%s\n' "$DIFF_SHA"
printf '  Staged files:\n'
printf '%s\n' "$STAGED_FILES" | sed 's/^/    /'
if [ "$UNSTAGED_COUNT" != "0" ] || [ "$UNTRACKED_COUNT" != "0" ]; then
  printf '  Note: %s unstaged and %s untracked file(s) remain outside this approval.\n' \
    "$UNSTAGED_COUNT" "$UNTRACKED_COUNT"
fi
