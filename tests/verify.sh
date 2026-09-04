#!/bin/bash
# Quality Gate installation verification. Uses a throwaway repo; no real repo is touched.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QG="$PLUGIN_ROOT/scripts"
HOOK="$PLUGIN_ROOT/hooks-handlers/block-unreviewed-commit.sh"
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/qg-verify.XXXXXX")
REPO="$TMPROOT/repo"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected=$3 got=$2)"; fi; }

# hook_decision <cwd> <command>  -> prints allow|deny|none
hook_decision() {
  local out
  out=$(jq -n --arg c "$1" --arg cmd "$2" \
        '{session_id:"t",transcript_path:"/dev/null",cwd:$c,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$cmd}}' \
        | "$HOOK" 2>/dev/null)
  if [ -z "$out" ]; then printf 'none\n'; return; fi
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "none"'
}

printf '\n== setup ==\n'
mkdir -p "$REPO"; cd "$REPO" || exit 1
git init -q -b main .
git config user.email qg@test.local
git config user.name  "QG Test"
printf 'v1\n' > app.txt
git add app.txt
git commit -qm "init"
ok "temp repo created at $REPO"

printf '\n== 1. installed files ==\n'
for f in "$PLUGIN_ROOT/.claude-plugin/plugin.json" \
         "$PLUGIN_ROOT/hooks/hooks.json" \
         "$PLUGIN_ROOT/skills/gate/SKILL.md" \
         "$PLUGIN_ROOT/skills/quick/SKILL.md" \
         "$PLUGIN_ROOT/skills/standard/SKILL.md" \
         "$PLUGIN_ROOT/skills/enable/SKILL.md" \
         "$PLUGIN_ROOT/skills/disable/SKILL.md" \
         "$PLUGIN_ROOT/skills/status/SKILL.md"; do
  [ -f "$f" ] && ok "exists: ${f#$HOME/}" || bad "missing: $f"
done
for s in quality-gate-state.sh cmux-status.sh codex-review.sh approve-commit.sh commit-reviewed.sh clear-approval.sh; do
  [ -x "$QG/$s" ] && ok "executable: $s" || bad "not executable: $s"
done
[ -x "$HOOK" ] && ok "executable: hooks/block-unreviewed-commit.sh" || bad "hook not executable"
jq -e '[.hooks.PreToolUse[]?|select(.matcher=="Bash")|.hooks[]?.command]|index("\"${CLAUDE_PLUGIN_ROOT}/hooks-handlers/block-unreviewed-commit.sh\"")' \
   "$PLUGIN_ROOT/hooks/hooks.json" >/dev/null 2>&1 \
   && ok "plugin registers the PreToolUse Bash hook" || bad "plugin hooks.json does not register the hook"
jq -e '.name == "qg"' "$PLUGIN_ROOT/.claude-plugin/plugin.json" >/dev/null 2>&1 \
   && ok "plugin.json declares name qg" || bad "plugin.json name wrong"

printf '\n== 2. default OFF ==\n'
"$QG/quality-gate-state.sh" enabled 2>/dev/null; chk "state: enabled exits non-zero when OFF" "$([ $? -ne 0 ] && echo yes || echo no)" "yes"
"$QG/quality-gate-state.sh" status | sed 's/^/        /'
chk "hook: OFF + git commit           -> allowed" "$(hook_decision "$REPO" 'git commit -m "x"')" "none"
chk "hook: non-repo cwd               -> allowed" "$(hook_decision "$TMPROOT" 'git commit -m "x"')" "none"

printf '\n== 3. enable ==\n'
chk "enable prints 'enabled'"          "$("$QG/quality-gate-state.sh" enable)" "enabled"
chk "enable is idempotent"             "$("$QG/quality-gate-state.sh" enable)" "already-enabled"
"$QG/quality-gate-state.sh" enabled && ok "state: enabled exits 0 when ON" || bad "state: enabled should exit 0"
MARKER=$("$QG/quality-gate-state.sh" marker-path)
case "$MARKER" in /*) ok "marker path is absolute: ${MARKER#$TMPROOT/}";; *) bad "marker path not absolute: $MARKER";; esac
case "$MARKER" in *.git/*) ok "marker lives inside the Git dir";; *) bad "marker is NOT inside the Git dir: $MARKER";; esac
chk "marker invisible to git status"   "$(git status --porcelain | wc -l | tr -d ' ')" "0"
chk "marker not tracked"               "$(git ls-files | grep -c quality-gate || true)" "0"

printf '\n== 4. hook while ON ==\n'
chk "direct git commit                 -> deny"  "$(hook_decision "$REPO" 'git commit -m "wip"')" "deny"
chk "git commit --amend                -> deny"  "$(hook_decision "$REPO" 'git commit --amend --no-edit')" "deny"
chk "git -C <path> commit              -> deny"  "$(hook_decision "$REPO" "git -C $REPO commit -m x")" "deny"
chk "git -c k=v commit                 -> deny"  "$(hook_decision "$REPO" 'git -c user.name=x commit -m x')" "deny"
chk "chained  ... && git commit        -> deny"  "$(hook_decision "$REPO" 'npm test && git commit -m x')" "deny"
chk "wrapper + smuggled git commit     -> deny"  "$(hook_decision "$REPO" "$QG/commit-reviewed.sh -m x && git commit -m y")" "deny"
chk "commit-reviewed.sh                -> allow" "$(hook_decision "$REPO" "$QG/commit-reviewed.sh -m 'fix: x'")" "allow"
chk "git status                        -> allowed" "$(hook_decision "$REPO" 'git status --short')" "none"
chk "git add                           -> allowed" "$(hook_decision "$REPO" 'git add app.txt')" "none"
chk "git log | grep commit             -> allowed" "$(hook_decision "$REPO" 'git log --oneline | grep commit')" "none"
chk "git commit-tree (not commit)      -> allowed" "$(hook_decision "$REPO" 'git commit-tree abc123')" "none"
chk "echo mentioning commit            -> allowed" "$(hook_decision "$REPO" 'echo building')" "none"

printf '\n== 5. approval + reviewed commit ==\n'
printf 'v2\n' > app.txt
"$QG/approve-commit.sh" >/dev/null 2>&1; chk "approve refuses with nothing staged" "$([ $? -ne 0 ] && echo yes || echo no)" "yes"
git add app.txt
"$QG/approve-commit.sh" | sed 's/^/        /'
APPROVAL=$("$QG/quality-gate-state.sh" approval-path)
[ -f "$APPROVAL" ] && ok "approval marker created" || bad "approval marker missing"
case "$APPROVAL" in *.git/*) ok "approval marker inside the Git dir";; *) bad "approval marker outside the Git dir";; esac
chk "approval invisible to git status" "$(git status --porcelain | grep -c 'quality-gate' || true)" "0"
grep -q '^head=' "$APPROVAL" && ok "approval records HEAD" || bad "approval missing head="
grep -q '^diff_sha256=' "$APPROVAL" && ok "approval records staged diff sha256" || bad "approval missing diff_sha256="
grep -q '^approved_at=' "$APPROVAL" && ok "approval records timestamp" || bad "approval missing approved_at="

printf '\n== 6. tamper detection ==\n'
printf 'v3-tampered\n' > app.txt; git add app.txt
OUT=$("$QG/commit-reviewed.sh" -m "should be refused" 2>&1); RC=$?
chk "staged-diff drift refused"        "$([ $RC -ne 0 ] && echo yes || echo no)" "yes"
printf '%s' "$OUT" | grep -q 'staged diff changed after Codex approval' && ok "correct drift message" || bad "wrong drift message: $OUT"
[ ! -f "$APPROVAL" ] && ok "stale approval invalidated on drift" || bad "stale approval survived drift"

printf '\n== 7. happy-path reviewed commit ==\n'
"$QG/approve-commit.sh" >/dev/null
OUT=$("$QG/commit-reviewed.sh" -m "feat: bump app to v3" 2>&1); RC=$?
chk "reviewed commit succeeds"          "$RC" "0"
printf '%s' "$OUT" | sed 's/^/        /'
chk "commit landed"                     "$(git log --oneline | wc -l | tr -d ' ')" "2"
chk "commit message correct"            "$(git log -1 --pretty=%s)" "feat: bump app to v3"
[ ! -f "$APPROVAL" ] && ok "approval consumed after commit" || bad "approval not consumed"

printf '\n== 8. reuse / HEAD-drift protection ==\n'
printf 'v4\n' > app.txt; git add app.txt
OUT=$("$QG/commit-reviewed.sh" -m "no approval" 2>&1); RC=$?
chk "commit without approval refused"   "$([ $RC -ne 0 ] && echo yes || echo no)" "yes"
printf '%s' "$OUT" | grep -q 'No Quality Gate approval found' && ok "correct no-approval message" || bad "wrong message: $OUT"
"$QG/approve-commit.sh" >/dev/null
git commit -qm "sneaky out-of-band commit"    # simulate HEAD moving underneath
printf 'v5\n' > app.txt; git add app.txt
OUT=$("$QG/commit-reviewed.sh" -m "stale head" 2>&1); RC=$?
chk "HEAD drift refused"                "$([ $RC -ne 0 ] && echo yes || echo no)" "yes"
printf '%s' "$OUT" | grep -q 'HEAD changed after Codex approval' && ok "correct HEAD-drift message" || bad "wrong message: $OUT"

printf '\n== 9. clear-approval keeps the gate ON ==\n'
"$QG/approve-commit.sh" >/dev/null
"$QG/clear-approval.sh" | sed 's/^/        /'
[ ! -f "$APPROVAL" ] && ok "approval cleared" || bad "approval not cleared"
"$QG/quality-gate-state.sh" enabled && ok "gate still ON after clear-approval" || bad "clear-approval disabled the gate"
"$QG/clear-approval.sh" >/dev/null 2>&1; chk "clear-approval idempotent" "$?" "0"

printf '\n== 10. git worktree ==\n'
git worktree add -q "$TMPROOT/wt" -b wtbranch >/dev/null 2>&1
if [ -d "$TMPROOT/wt" ]; then
  WT_MARKER=$(cd "$TMPROOT/wt" && "$QG/quality-gate-state.sh" marker-path)
  [ "$WT_MARKER" != "$MARKER" ] && ok "worktree gets its own marker path" || bad "worktree shares the main marker path"
  case "$WT_MARKER" in *worktrees*) ok "worktree marker under .git/worktrees/";; *) bad "unexpected worktree marker: $WT_MARKER";; esac
  (cd "$TMPROOT/wt" && "$QG/quality-gate-state.sh" enabled) 2>/dev/null
  chk "worktree defaults to OFF (independent)" "$([ $? -ne 0 ] && echo yes || echo no)" "yes"
  chk "hook in OFF worktree -> allowed" "$(hook_decision "$TMPROOT/wt" 'git commit -m x')" "none"
  (cd "$TMPROOT/wt" && "$QG/quality-gate-state.sh" enable >/dev/null)
  chk "hook in ON worktree  -> deny"    "$(hook_decision "$TMPROOT/wt" 'git commit -m x')" "deny"
  chk "worktree marker invisible to git status" "$(cd "$TMPROOT/wt" && git status --porcelain | grep -c quality-gate || true)" "0"
else
  bad "could not create worktree"
fi

printf '\n== 11. disable ==\n'
chk "disable reports previous state"    "$("$QG/quality-gate-state.sh" disable)" "was-enabled"
"$QG/quality-gate-state.sh" enabled 2>/dev/null; chk "gate OFF after disable" "$([ $? -ne 0 ] && echo yes || echo no)" "yes"
chk "disable is idempotent"             "$("$QG/quality-gate-state.sh" disable)" "disabled"
chk "hook: OFF again -> git commit allowed" "$(hook_decision "$REPO" 'git commit -m x')" "none"
printf 'v6\n' > app.txt; git add app.txt; git commit -qm "normal commit after disable"
chk "normal git commit works after disable" "$?" "0"
[ ! -f "$MARKER" ] && ok "enable marker removed" || bad "enable marker survived disable"
chk "no quality-gate leftovers in working tree" "$(git status --porcelain | grep -c quality-gate || true)" "0"

printf '\n== 12. outside a Git repository ==\n'
OUT=$(cd "$TMPROOT" && "$QG/quality-gate-state.sh" status 2>&1); RC=$?
chk "status errors outside a repo"      "$([ $RC -ne 0 ] && echo yes || echo no)" "yes"
printf '%s' "$OUT" | grep -q 'Not inside a Git repository' && ok "clear out-of-repo error" || bad "unclear error: $OUT"

printf '\n== 13. cmux / codex availability ==\n'
"$QG/cmux-status.sh" available && ok "cmux: available" || printf '  INFO  cmux: unavailable (Quality Gate still works)\n'
command -v codex >/dev/null 2>&1 && ok "codex CLI: available ($(codex --version 2>/dev/null))" || bad "codex CLI: unavailable"
# Exercise the no-op path with cmux removed from PATH, so the live sidebar is untouched.
( PATH="/usr/bin:/bin"; "$QG/cmux-status.sh" phase Testing >/dev/null 2>&1 ); chk "cmux-status.sh no-ops without cmux" "$?" "0"
( PATH="/usr/bin:/bin"; "$QG/cmux-status.sh" notify-passed "x" >/dev/null 2>&1 ); chk "notify-passed no-ops without cmux" "$?" "0"

printf '\n== 14. codex invocation, all modes (stubbed CLI: no network, no tokens) ==\n'
STUB_DIR="$TMPROOT/stub"; mkdir -p "$STUB_DIR"
install_stub_json() {
cat > "$STUB_DIR/codex" <<'STUB'
#!/bin/bash
# Fake Codex CLI. Logs argv, emits a `--json` style event stream on stdout,
# honours -o, and exits with $QG_STUB_EXIT.
printf '%s\n' "$*" >> "$QG_STUB_LOG"
out=""; prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out="$a"; fi
  prev="$a"
done
printf '{"type":"thread.started","thread_id":"t"}\n'
printf '{"type":"turn.started"}\n'
printf '{"type":"item.started","item":{"type":"command_execution","command":"/bin/zsh -lc \\"git status --short && git diff\\"","status":"in_progress"}}\n'
printf '{"type":"item.completed","item":{"type":"command_execution","command":"/bin/zsh -lc \\"git status --short && git diff\\"","status":"completed"}}\n'
if [ "${QG_STUB_NO_AGENT_MSG:-0}" != "1" ]; then
  printf '{"type":"item.completed","item":{"type":"agent_message","text":"Stubbed review: no blocking issues found."}}\n'
fi
printf '{"type":"turn.completed"}\n'
if [ -n "$out" ] && [ "${QG_STUB_EMPTY:-0}" != "1" ]; then
  printf 'Stubbed review: no blocking issues found.\n' > "$out"
fi
exit "${QG_STUB_EXIT:-0}"
STUB
chmod +x "$STUB_DIR/codex"
}
install_stub_json
export QG_STUB_LOG="$TMPROOT/stub.log"

SREPO="$TMPROOT/stubrepo"; mkdir -p "$SREPO"; cd "$SREPO" || exit 1
git init -q -b main .; git config user.email qg@test.local; git config user.name "QG Test"
printf 'v1\n' > s.txt; git add s.txt; git commit -qm init
printf 'v2\n' > s.txt
"$QG/quality-gate-state.sh" enable >/dev/null

# stub_run <mode> -> prints "<exit> <status>"; stderr kept in $TMPROOT/stub.err
stub_run() {
  : > "$QG_STUB_LOG"
  local out
  out=$(PATH="$STUB_DIR:$PATH" "$QG/codex-review.sh" "$1" --pass t 2>"$TMPROOT/stub.err")
  local rc=$?
  printf '%s %s\n' "$rc" "$(printf '%s' "$out" | sed -n 's/^QG_CODEX_STATUS=//p')"
}

# This is the regression guard for the bash 3.2 empty-array bug: full mode built
# an empty QUICKCFG array and died on "${QUICKCFG[@]}" before reaching codex.
R=$(stub_run --full)
chk "full: exit + status"              "$R" "0 ok"
grep -q 'unbound variable' "$TMPROOT/stub.err" && bad "full: 'unbound variable' in stderr (bash 3.2 empty-array bug)" \
                                               || ok "full: no 'unbound variable' (bash 3.2 empty-array guard)"
grep -q 'sandbox_mode="read-only"' "$QG_STUB_LOG"      && ok "full: read-only sandbox passed"   || bad "full: sandbox flag missing"
grep -q 'approval_policy="never"' "$QG_STUB_LOG"       && ok "full: approval_policy=never"      || bad "full: approval flag missing"
grep -q 'model_reasoning_effort' "$QG_STUB_LOG"        && bad "full: must NOT force reasoning effort" \
                                                       || ok "full: leaves reasoning effort to config"
grep -q 'exec review --uncommitted' "$QG_STUB_LOG"     && ok "full: reviews uncommitted changes" || bad "full: wrong codex subcommand"

R=$(stub_run --quick)
chk "quick: exit + status"             "$R" "0 ok"
grep -q 'unbound variable' "$TMPROOT/stub.err" && bad "quick: 'unbound variable' in stderr" \
                                               || ok "quick: no 'unbound variable'"
grep -q 'model_reasoning_effort="low"' "$QG_STUB_LOG"  && ok "quick: forces reasoning effort low" || bad "quick: effort not lowered"
grep -q 'mcp_servers={}' "$QG_STUB_LOG"                && ok "quick: disables MCP servers"        || bad "quick: MCP not disabled"
grep -q 'plugins={}' "$QG_STUB_LOG"                    && ok "quick: disables plugins"            || bad "quick: plugins not disabled"
grep -q 'sandbox_mode="read-only"' "$QG_STUB_LOG"      && ok "quick: keeps read-only sandbox"     || bad "quick: sandbox flag missing"

R=$(stub_run --standard)
chk "standard: exit + status"          "$R" "0 ok"
grep -q 'unbound variable' "$TMPROOT/stub.err" && bad "standard: 'unbound variable' in stderr" \
                                               || ok "standard: no 'unbound variable'"
grep -q 'model_reasoning_effort="medium"' "$QG_STUB_LOG" && ok "standard: forces reasoning effort medium" || bad "standard: effort not medium"
grep -q 'mcp_servers={}' "$QG_STUB_LOG"                && ok "standard: disables MCP servers"     || bad "standard: MCP not disabled"
grep -q 'plugins={}' "$QG_STUB_LOG"                    && ok "standard: disables plugins"         || bad "standard: plugins not disabled"
grep -q 'sandbox_mode="read-only"' "$QG_STUB_LOG"      && ok "standard: keeps read-only sandbox"  || bad "standard: sandbox flag missing"
grep -q 'approval_policy="never"' "$QG_STUB_LOG"       && ok "standard: approval_policy=never"    || bad "standard: approval flag missing"
R=$(: > "$QG_STUB_LOG"; out=$(PATH="$STUB_DIR:$PATH" "$QG/codex-review.sh" --standard --pass t --skip-unchanged 2>/dev/null); printf '%s %s\n' "$?" "$(printf '%s' "$out" | sed -n 's/^QG_CODEX_STATUS=//p')")
chk "standard: --skip-unchanged reuses the review" "$R" "0 unchanged"
R=$(PATH="$STUB_DIR:$PATH" "$QG/codex-review.sh" --mode bogus --pass t 2>/dev/null; echo $?)
chk "unknown mode is rejected"          "$R" "1"

FP="$(cd "$SREPO" && "$QG/quality-gate-state.sh" marker-path | sed 's/quality-gate-enabled/quality-gate-review-latest.md.fingerprint/')"
[ -f "$FP" ] && ok "fingerprint recorded after a successful review" || bad "fingerprint not recorded"
R=$(: > "$QG_STUB_LOG"; out=$(PATH="$STUB_DIR:$PATH" "$QG/codex-review.sh" --quick --pass t --skip-unchanged 2>/dev/null); printf '%s %s\n' "$?" "$(printf '%s' "$out" | sed -n 's/^QG_CODEX_STATUS=//p')")
chk "--skip-unchanged reuses the review" "$R" "0 unchanged"
[ ! -s "$QG_STUB_LOG" ] && ok "--skip-unchanged did not invoke codex at all" || bad "codex was invoked despite unchanged content"

# timeout defaults: full 2400s, standard 900s, quick 300s, --timeout wins over all
stub_timeout() {
  : > "$QG_STUB_LOG"
  PATH="$STUB_DIR:$PATH" "$QG/codex-review.sh" "$@" --pass t 2>/dev/null \
    | sed -n 's/^QG_CODEX_TIMEOUT=//p'
}
chk "full default timeout"             "$(stub_timeout --full)" "2400"
chk "quick default timeout"            "$(stub_timeout --quick)" "300"
chk "standard default timeout"         "$(stub_timeout --standard)" "900"
chk "--timeout overrides full default" "$(stub_timeout --full --timeout 77)" "77"

R=$(QG_STUB_EMPTY=1 QG_STUB_NO_AGENT_MSG=1 stub_run --full)
chk "empty codex output is not a pass"  "$R" "4 empty"
R=$(QG_STUB_EXIT=3 stub_run --full)
chk "codex non-zero exit is not a pass" "$R" "5 error"

# A stub that rejects the overrides must trigger the documented plain retry.
cat > "$STUB_DIR/codex" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$QG_STUB_LOG"
case "$*" in
  *sandbox_mode*) printf 'error: unexpected argument\n' >&2; exit 2 ;;
esac
out=""; prev=""
for a in "$@"; do if [ "$prev" = "-o" ]; then out="$a"; fi; prev="$a"; done
[ -n "$out" ] && printf 'Stubbed review after retry.\n' > "$out"
exit 0
STUB
chmod +x "$STUB_DIR/codex"
R=$(stub_run --full)
chk "config-override rejection falls back and still reviews" "$R" "0 ok"


printf '\n== 15. live progress during a Codex review ==\n'
install_stub_json
: > "$QG_STUB_LOG"
PATH="$STUB_DIR:$PATH" "$QG/codex-review.sh" --full --pass t >/dev/null 2>&1
grep -q -- '--json' "$QG_STUB_LOG" && ok "codex is asked for a --json event stream" \
                                  || bad "--json not passed; live progress impossible"

RF=$(cd "$SREPO" && "$QG/quality-gate-state.sh" marker-path | sed 's/quality-gate-enabled/quality-gate-review-latest.md/')
: > "$QG_STUB_LOG"
PATH="$STUB_DIR:$PATH" "$QG/codex-review.sh" --full --pass t >/dev/null 2>&1
grep -q 'Codex inspected the repository with:' "$RF" \
  && ok "review artifact records what Codex inspected" || bad "activity trace missing from artifact"
grep -q 'git status --short' "$RF" && ok "trace shows the actual commands" || bad "trace has no commands"

# With no -o output the review must come from the event stream as prose,
# never as raw JSON.
R=$(QG_STUB_EMPTY=1 stub_run --full)
chk "review recovered from the event stream" "$R" "0 ok"
grep -q '"type":' "$RF" && bad "raw JSON leaked into the review artifact" \
                        || ok "artifact holds prose, not raw JSON"
grep -q 'Stubbed review' "$RF" && ok "agent_message became the review body" || bad "agent_message not extracted"

# The pill helpers must never break a run, with or without cmux.
( PATH="/usr/bin:/bin"; "$QG/cmux-status.sh" codex "1:23" "cat x.js" >/dev/null 2>&1 ); chk "codex pill no-ops without cmux" "$?" "0"
( PATH="/usr/bin:/bin"; "$QG/cmux-status.sh" codex-clear >/dev/null 2>&1 ); chk "codex-clear no-ops without cmux" "$?" "0"
"$QG/cmux-status.sh" codex-clear >/dev/null 2>&1; chk "codex-clear is safe to call anytime" "$?" "0"

# A quote in the command text must not corrupt the pill value (regression).
ACT=$(STDOUT_FILE="$TMPROOT/act.jsonl"
      printf '{"type":"item.started","item":{"type":"command_execution","command":"%s"}}\n' "'" > "$TMPROOT/act.jsonl"
      eval "$(sed -n '/^qg_codex_activity() {/,/^}/p' "$QG/codex-review.sh")"; qg_codex_activity)
chk "lone quote falls back instead of corrupting the pill" "$ACT" "starting"
ACT=$(STDOUT_FILE="$TMPROOT/act.jsonl"
      printf '{"type":"item.started","item":{"type":"command_execution","command":"/bin/zsh -lc \\"git status --short && git diff\\""}}\n' > "$TMPROOT/act.jsonl"
      eval "$(sed -n '/^qg_codex_activity() {/,/^}/p' "$QG/codex-review.sh")"; qg_codex_activity)
chk "escaped-quote command renders readably" "$ACT" "git status --short git diff"

"$QG/quality-gate-state.sh" disable >/dev/null
cd "$REPO" 2>/dev/null || cd "$TMPROOT" || exit 1

printf '\n== cleanup ==\n'
cd / || exit
rm -rf "$TMPROOT"
[ ! -d "$TMPROOT" ] && ok "temp repo removed" || bad "temp repo left behind: $TMPROOT"

printf '\n==================================\n'
printf 'PASS: %s   FAIL: %s\n' "$PASS" "$FAIL"
printf '==================================\n'
[ "$FAIL" -eq 0 ]
