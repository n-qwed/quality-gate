#!/bin/bash
# PreToolUse hook (Bash tool) -- block direct `git commit` only in repositories
# where Quality Gate has been explicitly enabled.
#
# Design notes:
#  * Default OFF. If anything is unknown, unparseable, or absent, this hook stays
#    silent (exit 0, no output) which leaves Claude Code's normal permission flow
#    untouched. It never emits "allow" for arbitrary commands.
#  * Only Claude Code's Bash tool passes through here. A `git commit` the user
#    types in their own terminal is not affected.
#  * Self-contained on purpose: it must not break if the skill directory moves.

set -uo pipefail

# No decision -> normal permission flow.
pass() { exit 0; }

emit() {
  # $1 = allow|deny, $2 = reason
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg d "$1" --arg r "$2" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  fi
  exit 0
}

command -v jq >/dev/null 2>&1 || pass
command -v git >/dev/null 2>&1 || pass

payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || pass

tool_name=$(printf '%s' "$payload"   | jq -r '.tool_name // empty' 2>/dev/null || true)
command_str=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
hook_cwd=$(printf '%s' "$payload"    | jq -r '.cwd // empty' 2>/dev/null || true)

[ "$tool_name" = "Bash" ] || pass
[ -n "$command_str" ]     || pass

if [ -n "$hook_cwd" ] && [ -d "$hook_cwd" ]; then
  cd "$hook_cwd" 2>/dev/null || pass
fi

# --- 1. Git repository? ------------------------------------------------------
git rev-parse --git-dir >/dev/null 2>&1 || pass

# --- 2. Quality Gate enabled for this repository/worktree? -------------------
marker=$(git rev-parse --path-format=absolute --git-path quality-gate-enabled 2>/dev/null) || marker=""
if [ -z "$marker" ]; then
  rel=$(git rev-parse --git-path quality-gate-enabled 2>/dev/null) || pass
  case "$rel" in
    /*) marker="$rel" ;;
    *)  marker="$PWD/$rel" ;;
  esac
fi
[ -f "$marker" ] || pass

# --- git-commit detection ----------------------------------------------------
# Walks tokens, and for each `git` invocation resolves its subcommand while
# skipping global options (including the ones that take a separate value).
# Shell separators terminate an invocation so `git log | grep commit` is safe.
has_git_commit() {
  local cmd="$1" normalized a t i n
  normalized=$(printf '%s' "$cmd" \
    | tr '\n\r\t' '   ' \
    | sed -e 's/&&/ ; /g' -e 's/||/ ; /g' -e 's/|/ ; /g' \
          -e 's/;/ ; /g' -e 's/(/ ; /g' -e 's/)/ ; /g')

  local -a toks=()
  read -r -a toks <<< "$normalized"
  i=0
  n=${#toks[@]}
  while [ "$i" -lt "$n" ]; do
    t="${toks[$i]}"
    i=$((i + 1))
    case "$t" in
      git|*/git) ;;
      *) continue ;;
    esac
    while [ "$i" -lt "$n" ]; do
      a="${toks[$i]}"
      case "$a" in
        ';') break ;;
        -C|-c|--git-dir|--work-tree|--exec-path|--namespace|--config-env|--super-prefix)
          i=$((i + 2)); continue ;;
        -*) i=$((i + 1)); continue ;;
        commit) return 0 ;;
        *) break ;;
      esac
    done
  done
  return 1
}

# --- 3. The sanctioned reviewed-commit wrapper ------------------------------
# Allowed only when the command is not also smuggling a bare `git commit`.
case "$command_str" in
  *commit-reviewed.sh*)
    if ! has_git_commit "$command_str"; then
      emit allow "Quality Gate: reviewed-commit wrapper (approval is verified by the script itself)."
    fi
    ;;
esac

# --- 4. Direct git commit -> deny -------------------------------------------
if has_git_commit "$command_str"; then
  emit deny "Quality Gate is enabled for this repository.

Direct git commit is disabled.

Keep changes uncommitted and run /qg:gate.
The reviewed commit will be created at the end of the quality gate."
fi

pass
