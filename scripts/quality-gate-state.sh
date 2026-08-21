#!/bin/bash
# quality-gate-state.sh -- Quality Gate ON/OFF state for the current Git repository.
#
# State lives inside the Git administrative directory, never in the working tree,
# so it never shows up in `git status` and never gets committed. Paths come from
# `git rev-parse --git-path`, which resolves correctly in linked worktrees too
# (state is then per-worktree, which is the intended behaviour).
#
# Usage:
#   quality-gate-state.sh enabled        # exit 0 if ON, non-zero if OFF
#   quality-gate-state.sh enable         # create the enable marker
#   quality-gate-state.sh disable        # remove enable + approval markers
#   quality-gate-state.sh status         # human-readable status
#   quality-gate-state.sh marker-path    # print absolute enable-marker path
#   quality-gate-state.sh approval-path  # print absolute approval-marker path
#   quality-gate-state.sh repo-root      # print repository root
#
# This file is also a library: other Quality Gate scripts `source` it to reuse
# the helpers below. Dispatch only happens when executed directly.

set -uo pipefail

QG_ENABLE_MARKER_NAME="quality-gate-enabled"
QG_APPROVAL_MARKER_NAME="quality-gate-approved"

qg_err()  { printf 'ERROR: %s\n' "$*" >&2; }
qg_info() { printf 'INFO: %s\n' "$*" >&2; }

qg_die() { qg_err "$*"; exit 1; }

qg_in_repo() { git rev-parse --git-dir >/dev/null 2>&1; }

qg_require_repo() {
  qg_in_repo || qg_die "Not inside a Git repository. Quality Gate requires a Git repository."
}

# Absolute path to a file inside the Git administrative directory.
qg_git_path() {
  local name="$1" p=""
  p=$(git rev-parse --path-format=absolute --git-path "$name" 2>/dev/null) || p=""
  if [ -z "$p" ]; then
    p=$(git rev-parse --git-path "$name" 2>/dev/null) || return 1
    case "$p" in
      /*) : ;;
      *)  p="$PWD/$p" ;;
    esac
  fi
  printf '%s\n' "$p"
}

qg_enable_marker()   { qg_git_path "$QG_ENABLE_MARKER_NAME"; }
qg_approval_marker() { qg_git_path "$QG_APPROVAL_MARKER_NAME"; }
qg_repo_root()       { git rev-parse --show-toplevel 2>/dev/null; }

qg_is_enabled() {
  local m
  m=$(qg_enable_marker) || return 1
  [ -f "$m" ]
}

qg_require_enabled() {
  qg_require_repo
  if ! qg_is_enabled; then
    cat >&2 <<'MSG'
Quality Gate is disabled for this repository.

Run:

/qg:enable

to enable it.
MSG
    exit 1
  fi
}

# SHA-256 of stdin. Works with GNU coreutils and macOS/BSD.
qg_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    qg_err "Neither sha256sum nor shasum is available; cannot hash the staged diff."
    return 1
  fi
}

# SHA-256 of the exact staged diff (binary-safe).
qg_staged_diff_sha() {
  git diff --cached --binary | qg_sha256
}

qg_head_sha() {
  git rev-parse HEAD 2>/dev/null || printf 'NO_HEAD\n'
}

qg_has_staged_changes() {
  ! git diff --cached --quiet
}

qg_remove_review_artifacts() {
  local f suffix
  for suffix in "" ".lastmsg" ".stdout" ".stderr" ".timedout" ".fingerprint"; do
    f=$(qg_git_path "quality-gate-review-latest.md${suffix}") || continue
    [ -f "$f" ] && rm -f "$f"
  done
  return 0
}

qg_remove_approval() {
  local m
  m=$(qg_approval_marker) || return 0
  [ -e "$m" ] && rm -f "$m"
  return 0
}

qg_cmd_enable() {
  qg_require_repo
  local m
  m=$(qg_enable_marker) || qg_die "Could not resolve the Quality Gate marker path."
  if [ -f "$m" ]; then
    printf 'already-enabled\n'
    return 0
  fi
  mkdir -p "$(dirname "$m")" 2>/dev/null || true
  {
    printf 'enabled_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'repo=%s\n' "$(qg_repo_root)"
  } > "$m" || qg_die "Could not write the Quality Gate marker at: $m"
  printf 'enabled\n'
}

qg_cmd_disable() {
  qg_require_repo
  local m was="disabled"
  m=$(qg_enable_marker) || qg_die "Could not resolve the Quality Gate marker path."
  if [ -f "$m" ]; then
    rm -f "$m" || qg_die "Could not remove the Quality Gate marker at: $m"
    was="was-enabled"
  fi
  qg_remove_approval
  qg_remove_review_artifacts
  printf '%s\n' "$was"
}

qg_cmd_status() {
  qg_require_repo
  local root approval state="DISABLED" pending="no"
  root=$(qg_repo_root)
  qg_is_enabled && state="ENABLED"
  approval=$(qg_approval_marker) || approval=""
  [ -n "$approval" ] && [ -f "$approval" ] && pending="yes"
  printf 'Quality Gate: %s\n' "$state"
  printf 'Repository: %s\n' "$root"
  if [ "$state" = "ENABLED" ]; then
    printf 'Pending approval: %s\n' "$pending"
  fi
}

# ---- CLI dispatch (only when executed, not when sourced) --------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    enabled)       qg_require_repo; qg_is_enabled ;;
    enable)        qg_cmd_enable ;;
    disable)       qg_cmd_disable ;;
    status)        qg_cmd_status ;;
    marker-path)   qg_require_repo; qg_enable_marker ;;
    approval-path) qg_require_repo; qg_approval_marker ;;
    repo-root)     qg_require_repo; qg_repo_root ;;
    ""|-h|--help)
      sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
      ;;
    *) qg_die "Unknown subcommand: ${1}. Try: enabled|enable|disable|status|marker-path|approval-path|repo-root" ;;
  esac
fi
