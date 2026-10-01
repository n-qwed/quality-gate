#!/bin/bash
# codex-review.sh -- run Codex CLI as an independent reviewer over the
# uncommitted changes of the current repository.
#
# Codex is a REVIEWER ONLY. It is invoked with a read-only sandbox and an
# approval policy of "never" so it cannot edit files or run mutating commands.
# All fixing is done by Claude Code afterwards.
#
# Usage:
#   codex-review.sh [--quick|--standard|--full] [--pass <n>] [--timeout <s>]
#                   [--label <text>] [--skip-unchanged]
#
#   --timeout defaults to 2400s in full mode, 900s in standard mode and 300s
#   in quick mode.
#
# Modes (model / reasoning effort):
#   --full  (default) gpt-6-astra / high. MCP servers and plugins loaded.
#           Deepest review; the slot for auth, payments, migrations, large diffs.
#   --standard gpt-6.1-sol / medium, MCP servers and plugins disabled.
#           Sits between quick and full: the everyday review.
#   --quick gpt-6.1-sol / low, MCP servers and plugins disabled. Catches the
#           high-severity defects; may miss lower-severity ones.
#
#   The model per mode can be overridden with QG_MODEL_FULL, QG_MODEL_STANDARD
#   and QG_MODEL_QUICK. Setting one to the empty string leaves the model to
#   ~/.codex/config.toml. Reasoning effort is always pinned per mode.
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
#   QG_CODEX_MODE=<quick|standard|full>
#   QG_CODEX_MODEL=<model slug, or "config" when left to config.toml>
#   QG_CODEX_TIMEOUT=<seconds the watchdog allowed>
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
    --standard)       MODE="standard"; shift ;;
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
  quick|standard|full) : ;;
  *) qg_err "Unknown mode: $MODE (expected quick, standard or full)"; exit 1 ;;
esac

if [ -z "$TIMEOUT_SECS" ]; then
  case "$MODE" in
    quick)    TIMEOUT_SECS=300 ;;
    standard) TIMEOUT_SECS=900 ;;
    *)        TIMEOUT_SECS=2400 ;;
  esac
fi

# Model per mode. `${VAR-default}` (no colon) so an explicitly empty override
# means "do not pin a model; follow ~/.codex/config.toml".
case "$MODE" in
  quick)    MODEL="${QG_MODEL_QUICK-gpt-6.1-sol}";    EFFORT="low" ;;
  standard) MODEL="${QG_MODEL_STANDARD-gpt-6.1-sol}"; EFFORT="medium" ;;
  *)        MODEL="${QG_MODEL_FULL-gpt-6-astra}";     EFFORT="high" ;;
esac

trailer() {
  printf '\n'
  printf 'QG_CODEX_STATUS=%s\n' "$1"
  printf 'QG_CODEX_MODE=%s\n' "$MODE"
  printf 'QG_CODEX_MODEL=%s\n' "${MODEL:-config}"
  printf 'QG_CODEX_TIMEOUT=%s\n' "$TIMEOUT_SECS"
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

# Compact "what is Codex doing right now", read from the JSONL event stream.
# Deliberately grep/sed rather than jq: this runs on a timer and the last line
# of the file may still be partially written.
qg_codex_activity() {
  local raw clean
  [ -s "$STDOUT_FILE" ] || { printf 'starting\n'; return 0; }
  # The JSON string may contain escaped quotes, so a plain [^"]* stops short.
  raw=$(grep -oE '"command":"([^"\\]|\\.)*"' "$STDOUT_FILE" 2>/dev/null | tail -n1 \
        | sed -e 's/^"command":"//' -e 's/"$//')
  if [ -n "$raw" ]; then
    # Unescape, drop the shell wrapper, then keep only characters that cannot
    # confuse the status-setting CLI. A stray quote here corrupted the pill.
    clean=$(printf '%s' "$raw" \
      | sed -e 's/\\\\n/ /g' -e 's/\\\\t/ /g' -e 's/\\"/ /g' \
            -e "s|^/bin/[a-z]*sh -lc *||" \
      | tr -d '\\"'"'"'`$\\\\' \
      | tr -cd '[:alnum:][:space:]._/:;,=+-' \
      | tr -s '[:space:]' ' ' \
      | sed -e 's/^ *//' -e 's/ *$//' \
      | cut -c1-34)
    # Anything shorter than this is noise, not information.
    if [ "${#clean}" -ge 3 ]; then
      printf '%s\n' "$clean"
      return 0
    fi
  fi
  if grep -q '"type":"turn.started"' "$STDOUT_FILE" 2>/dev/null; then
    printf 'reading the diff\n'
  else
    printf 'starting\n'
  fi
}

qg_fmt_elapsed() {
  local t="$1"
  printf '%d:%02d\n' "$((t / 60))" "$((t % 60))"
}

run_codex() {
  codex "$@" >"$STDOUT_FILE" 2>"$STDERR_FILE" &
  cpid=$!
  (
    waited=0
    while [ "$waited" -lt "$TIMEOUT_SECS" ]; do
      kill -0 "$cpid" 2>/dev/null || exit 0
      sleep 1
      waited=$((waited + 1))
      # Codex blocks for minutes with no terminal output. Refresh the cmux pill
      # every few seconds so it is visibly alive, and cheap enough for a
      # 2400s ceiling.
      if [ $((waited % 5)) -eq 0 ]; then
        "$SCRIPT_DIR/cmux-status.sh" codex "$(qg_fmt_elapsed "$waited")" \
          "$(qg_codex_activity)" >/dev/null 2>&1 || true
      fi
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
  "$SCRIPT_DIR/cmux-status.sh" codex-clear >/dev/null 2>&1 || true
  if [ -f "$TIMED_OUT_FLAG" ]; then
    rm -f "$TIMED_OUT_FLAG"
    return 124
  fi
  return "$rc"
}

# IMPORTANT (bash 3.2 / macOS default): under `set -u`, expanding an EMPTY
# array as "${ARR[@]}" is an "unbound variable" error. Never build an array
# that can be empty and then expand it -- accumulate into one array that
# always has at least one element.

# Codex must not be able to modify the tree; it is a reviewer, not a fixer.
CODEX_ARGS=(-c 'sandbox_mode="read-only"' -c 'approval_policy="never"')

# Every mode pins its reasoning effort; full additionally gets the frontier
# model. Quick/standard drop MCP servers and plugins, which only add startup
# latency to a review.
CODEX_ARGS+=(-c "model_reasoning_effort=\"$EFFORT\"")
if [ -n "$MODEL" ]; then
  CODEX_ARGS+=(-c "model=\"$MODEL\"")
fi
case "$MODE" in
  quick|standard) CODEX_ARGS+=(-c 'mcp_servers={}' -c 'plugins={}') ;;
esac

# NOTE: `codex exec review --uncommitted` rejects a custom PROMPT argument,
# so review scope/verbosity can only be tuned through config overrides.
BASE_ARGS=(exec review --uncommitted --json -o "$LAST_MSG_FILE")
if [ -n "$LABEL" ]; then
  BASE_ARGS+=(--title "$LABEL")
fi
CODEX_ARGS+=("${BASE_ARGS[@]}")

run_codex "${CODEX_ARGS[@]}"
CODEX_RC=$?

# A CLI that rejects the overrides still has to produce a review; retry plain.
if [ "$CODEX_RC" -ne 0 ] && [ "$CODEX_RC" -ne 124 ] \
   && grep -qEi 'unexpected argument|invalid value|unknown field|failed to parse|unrecognized' "$STDERR_FILE" 2>/dev/null; then
  qg_info "Codex rejected the config overrides; retrying without them (review will run at config defaults)."
  MODE="full-fallback"
  MODEL=""
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
  printf 'Model: %s (reasoning effort %s)\n' "${MODEL:-config.toml default}" "$EFFORT"
  case "$MODE" in
    quick)    printf 'Depth: reduced -- high-severity findings prioritised.\n' ;;
    standard) printf 'Depth: balanced -- everyday changes; use full for sensitive paths.\n' ;;
    full)     printf 'Depth: full -- frontier model, all severities.\n' ;;
  esac
  printf 'Command: codex exec review --uncommitted\n'
  if [ -s "$STDOUT_FILE" ] && command -v jq >/dev/null 2>&1; then
    trace=$(jq -r 'select(.type=="item.started" and .item.type=="command_execution")
                   | .item.command
                   | gsub("\n"; " ")
                   | sub("^/bin/[a-z]*sh -lc +"; "")' "$STDOUT_FILE" 2>/dev/null \
            | cut -c1-110 | head -n 8)
    if [ -n "$trace" ]; then
      printf '\nCodex inspected the repository with:\n'
      printf '%s\n' "$trace" | sed 's/^/  - /'
    fi
  fi
  printf '\n'
} >> "$REVIEW_FILE"

REVIEW_BODY_BYTES=0
if [ -s "$LAST_MSG_FILE" ]; then
  cat "$LAST_MSG_FILE" >> "$REVIEW_FILE"
  REVIEW_BODY_BYTES=$(wc -c < "$LAST_MSG_FILE" | tr -d ' ')
elif [ -s "$STDOUT_FILE" ] && command -v jq >/dev/null 2>&1; then
  # stdout is a JSONL event stream (--json); the review text is the agent
  # message. Never dump raw JSON into the review.
  AGENT_MSG_FILE="${REVIEW_FILE}.agentmsg"
  jq -r 'select(.item.type=="agent_message") | .item.text' "$STDOUT_FILE" \
    > "$AGENT_MSG_FILE" 2>/dev/null || : > "$AGENT_MSG_FILE"
  if [ -s "$AGENT_MSG_FILE" ]; then
    cat "$AGENT_MSG_FILE" >> "$REVIEW_FILE"
    REVIEW_BODY_BYTES=$(wc -c < "$AGENT_MSG_FILE" | tr -d ' ')
  fi
  rm -f "$AGENT_MSG_FILE"
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
