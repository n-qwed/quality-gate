#!/bin/bash
# codex-review.sh -- run Codex CLI as an independent reviewer over the
# uncommitted changes of the current repository.
#
# Codex is a REVIEWER ONLY. It is invoked with a read-only sandbox and an
# approval policy of "never" so it cannot edit files or run mutating commands.
# All fixing is done by Claude Code afterwards.
#
# Usage:
#   codex-review.sh [--quick|--full] [--pass <n>] [--timeout <s>]
#                   [--label <text>] [--skip-unchanged]
#
# Modes:
#   --full  (default) whatever ~/.codex/config.toml specifies. Deepest review.
#   --quick reasoning effort forced to "low", MCP servers and plugins disabled.
#           Measured on a small diff: ~50s vs ~209s for full. Catches the
#           high-severity defects; may miss lower-severity ones.
#
#   --skip-unchanged  If the uncommitted content is byte-identical to what the
#           last successful review already saw, reuse that review instead of
#           calling Codex again (status "unchanged"). Intended for the final
#           post-staging review in quick mode.
#
# Exit codes:
#   0   review available                    (QG_CODEX_STATUS=ok|unchanged)
#   1   generic failure
#   2   not a Git repository / gate off / Codex CLI missing
#   3   no uncommitted changes to review     (QG_CODEX_STATUS=no-changes)
#   4   Codex produced empty output          (QG_CODEX_STATUS=empty)
#   5   Codex exited abnormally              (QG_CODEX_STATUS=error)
#   124 Codex timed out                      (QG_CODEX_STATUS=timeout)
#
# stdout always ends with a machine-readable trailer:
#   QG_CODEX_STATUS=<status>
#   QG_CODEX_MODE=<quick|full>
#   QG_CODEX_EXIT=<codex exit code>
#   QG_CODEX_REVIEW_FILE=<path>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./quality-gate-state.sh
. "$SCRIPT_DIR/quality-gate-state.sh"

MODE="full"
PASS_NO=""
TIMEOUT_SECS=""
LABEL=""
SKIP_UNCHANGED=0

while [ $# -gt 0 ]; do
  case "$1" in
    --quick)          MODE="quick"; shift ;;
    --full)           MODE="full"; shift ;;
    --mode)           MODE="${2:-full}"; shift 2 ;;
    --pass)           PASS_NO="${2:-}"; shift 2 ;;
    --timeout)        TIMEOUT_SECS="${2:-}"; shift 2 ;;
    --label)          LABEL="${2:-}"; shift 2 ;;
    --skip-unchanged) SKIP_UNCHANGED=1; shift ;;
    -h|--help)        sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) qg_err "Unknown argument: $1"; exit 1 ;;
  esac
done

case "$MODE" in
  quick|full) : ;;
  *) qg_err "Unknown mode: $MODE (expected quick or full)"; exit 1 ;;
esac

if [ -z "$TIMEOUT_SECS" ]; then
  if [ "$MODE" = "quick" ]; then TIMEOUT_SECS=300; else TIMEOUT_SECS=900; fi
fi

trailer() {
  printf '\n'
  printf 'QG_CODEX_STATUS=%s\n' "$1"
  printf 'QG_CODEX_MODE=%s\n' "$MODE"
  printf 'QG_CODEX_EXIT=%s\n' "$2"
  printf 'QG_CODEX_REVIEW_FILE=%s\n' "${3:-}"
}

# --- preconditions -----------------------------------------------------------
if ! qg_in_repo; then
  qg_err "Not inside a Git repository."
  trailer "not-a-repo" "-" ""
  exit 2
fi

if ! qg_is_enabled; then
  qg_err "Quality Gate is disabled for this repository. Run /qg:enable first."
  trailer "gate-off" "-" ""
  exit 2
fi

if ! command -v codex >/dev/null 2>&1; then
  qg_err "Codex CLI not found on PATH. Quality Gate cannot run an independent review."
  trailer "missing-cli" "-" ""
  exit 2
fi

if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
  cat >&2 <<'MSG'
No uncommitted changes found.

The implementation may already have been committed.
Quality Gate requires the reviewed changes to remain uncommitted.
MSG
  trailer "no-changes" "-" ""
  exit 3
fi

REVIEW_FILE=$(qg_git_path "quality-gate-review-latest.md") || REVIEW_FILE=""
[ -n "$REVIEW_FILE" ] || { qg_err "Could not resolve a path for the review artifact."; exit 1; }
LAST_MSG_FILE="${REVIEW_FILE}.lastmsg"
STDOUT_FILE="${REVIEW_FILE}.stdout"
STDERR_FILE="${REVIEW_FILE}.stderr"
FINGERPRINT_FILE="${REVIEW_FILE}.fingerprint"

emit_review() {
  printf '===== CODEX REVIEW BEGIN =====\n'
  cat "$REVIEW_FILE"
  printf '\n===== CODEX REVIEW END =====\n'
}

# Fingerprint of everything `codex exec review --uncommitted` looks at:
# tracked changes against HEAD plus the content of untracked files.
qg_uncommitted_fingerprint() {
  {
    git diff HEAD --binary 2>/dev/null
    git ls-files --others --exclude-standard -z 2>/dev/null \
      | while IFS= read -r -d '' f; do
          printf '\n--- untracked: %s ---\n' "$f"
          cat -- "$f" 2>/dev/null
        done
  } | qg_sha256
}

CURRENT_FP=$(qg_uncommitted_fingerprint 2>/dev/null || echo "")

# --- reuse an identical previous review -------------------------------------
if [ "$SKIP_UNCHANGED" -eq 1 ] && [ -n "$CURRENT_FP" ] \
   && [ -f "$FINGERPRINT_FILE" ] && [ -s "$REVIEW_FILE" ]; then
  PREV_FP=$(cat "$FINGERPRINT_FILE" 2>/dev/null)
  if [ "$PREV_FP" = "$CURRENT_FP" ]; then
    qg_info "Uncommitted content is byte-identical to the last successful review; reusing it."
    emit_review
    trailer "unchanged" "0" "$REVIEW_FILE"
    exit 0
  fi
fi

rm -f "$LAST_MSG_FILE" "$STDOUT_FILE" "$STDERR_FILE"

# --- portable timeout (no coreutils `timeout` on stock macOS) ----------------
TIMED_OUT_FLAG="${REVIEW_FILE}.timedout"
rm -f "$TIMED_OUT_FLAG"

run_codex() {
  codex "$@" >"$STDOUT_FILE" 2>"$STDERR_FILE" &
  cpid=$!
  (
    waited=0
    while [ "$waited" -lt "$TIMEOUT_SECS" ]; do
      kill -0 "$cpid" 2>/dev/null || exit 0
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 "$cpid" 2>/dev/null; then
      : > "$TIMED_OUT_FLAG"
      kill -TERM "$cpid" 2>/dev/null
      sleep 5
      kill -KILL "$cpid" 2>/dev/null
    fi
  ) &
  wpid=$!
  wait "$cpid"
  rc=$?
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  if [ -f "$TIMED_OUT_FLAG" ]; then
    rm -f "$TIMED_OUT_FLAG"
    return 124
  fi
  return "$rc"
}

# Codex must not be able to modify the tree; it is a reviewer, not a fixer.
HARDENING=(-c 'sandbox_mode="read-only"' -c 'approval_policy="never"')

# Quick mode: the dominant cost is reasoning effort (config.toml may pin "max").
# MCP servers and plugins only add startup latency to a review.
QUICKCFG=()
if [ "$MODE" = "quick" ]; then
  QUICKCFG=(-c 'model_reasoning_effort="low"' -c 'mcp_servers={}' -c 'plugins={}')
fi

# NOTE: `codex exec review --uncommitted` rejects a custom PROMPT argument,
# so review scope/verbosity can only be tuned through config overrides.
BASE_ARGS=(exec review --uncommitted -o "$LAST_MSG_FILE")
[ -n "$LABEL" ] && BASE_ARGS+=(--title "$LABEL")

run_codex "${HARDENING[@]}" "${QUICKCFG[@]}" "${BASE_ARGS[@]}"
CODEX_RC=$?

# A CLI that rejects the overrides still has to produce a review; retry plain.
if [ "$CODEX_RC" -ne 0 ] && [ "$CODEX_RC" -ne 124 ] \
   && grep -qEi 'unexpected argument|invalid value|unknown field|failed to parse|unrecognized' "$STDERR_FILE" 2>/dev/null; then
  qg_info "Codex rejected the config overrides; retrying without them (review will run at config defaults)."
  MODE="full-fallback"
  run_codex "${BASE_ARGS[@]}"
  CODEX_RC=$?
fi

# --- assemble the review text ------------------------------------------------
: > "$REVIEW_FILE"
{
  printf '# Codex review'
  [ -n "$PASS_NO" ] && printf ' (pass %s)' "$PASS_NO"
  printf '\n\n'
  printf 'Repository: %s\n' "$(qg_repo_root)"
  printf 'Generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'Mode: %s\n' "$MODE"
  if [ "$MODE" = "quick" ]; then
    printf 'Depth: reduced (reasoning effort low) -- high-severity findings prioritised.\n'
  fi
  printf 'Command: codex exec review --uncommitted\n\n'
} >> "$REVIEW_FILE"

REVIEW_BODY_BYTES=0
if [ -s "$LAST_MSG_FILE" ]; then
  cat "$LAST_MSG_FILE" >> "$REVIEW_FILE"
  REVIEW_BODY_BYTES=$(wc -c < "$LAST_MSG_FILE" | tr -d ' ')
elif [ -s "$STDOUT_FILE" ]; then
  cat "$STDOUT_FILE" >> "$REVIEW_FILE"
  REVIEW_BODY_BYTES=$(wc -c < "$STDOUT_FILE" | tr -d ' ')
fi

# --- classify ----------------------------------------------------------------
if [ "$CODEX_RC" -eq 124 ]; then
  rm -f "$FINGERPRINT_FILE"
  qg_err "Codex review timed out after ${TIMEOUT_SECS}s. Do NOT proceed to commit."
  [ -s "$STDERR_FILE" ] && { printf -- '--- codex stderr (tail) ---\n'; tail -n 40 "$STDERR_FILE"; } >&2
  trailer "timeout" "$CODEX_RC" "$REVIEW_FILE"
  exit 124
fi

if [ "$CODEX_RC" -ne 0 ]; then
  rm -f "$FINGERPRINT_FILE"
  qg_err "Codex exited with status ${CODEX_RC}. Treat this as a failed review; do NOT proceed to commit."
  [ -s "$STDERR_FILE" ] && { printf -- '--- codex stderr (tail) ---\n'; tail -n 40 "$STDERR_FILE"; } >&2
  [ "$REVIEW_BODY_BYTES" -gt 0 ] && emit_review
  trailer "error" "$CODEX_RC" "$REVIEW_FILE"
  exit 5
fi

if [ "$REVIEW_BODY_BYTES" -eq 0 ]; then
  rm -f "$FINGERPRINT_FILE"
  qg_err "Codex exited 0 but produced no review output. Empty output is NOT a pass."
  [ -s "$STDERR_FILE" ] && { printf -- '--- codex stderr (tail) ---\n'; tail -n 40 "$STDERR_FILE"; } >&2
  trailer "empty" "$CODEX_RC" "$REVIEW_FILE"
  exit 4
fi

# Record what this successful review actually saw.
if [ -n "$CURRENT_FP" ]; then
  printf '%s\n' "$CURRENT_FP" > "$FINGERPRINT_FILE"
else
  rm -f "$FINGERPRINT_FILE"
fi

emit_review
trailer "ok" "$CODEX_RC" "$REVIEW_FILE"
exit 0
