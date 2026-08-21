---
name: gate
description: Run tests, Codex review, fix valid findings, re-review, verify the exact final diff, and commit only after the quality gate passes.
disable-model-invocation: true
---

# Quality Gate

Claude Code implements. **Codex CLI reviews, independently.** A commit is the
final artifact of a passing gate — never a step along the way.

```
Implement → Working Tree → Test → Codex Review → Fix → Re-test
→ Codex Re-review → Stage → Final Codex Review → Exact Diff Approval → Commit
```

Scripts live in the plugin's `scripts/` directory. Set this once at the
start of the run and reuse it:

```bash
QG="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/qg}/scripts"
REVIEW=--full          # or --quick, see Modes below
```

---

## Absolute rules

Read these before doing anything else.

1. **Never commit before the final approval.** Not "to checkpoint", not "to be
   safe", not because a test passed. The only commit in this workflow is the last
   step, through `commit-reviewed.sh`.
2. **Never run `git commit` directly.** While the gate is on, a global
   `PreToolUse` hook blocks it. Do not try to work around the hook.
3. **Never destroy user work.** These are forbidden for the entire run:
   `git reset --hard`, `git checkout -- .`, `git restore .`, `git clean -fd`,
   `git stash`. The user may have unrelated changes in the tree.
4. **Never `git add .` or `git add -A`.** Stage only files you have confirmed
   belong to this task, by explicit path.
5. **Never push.** `git push`, `git push --force`, and `gh pr create` are out of
   scope. Only do them if the user asks separately, afterwards.
6. **Never enable the gate yourself.** If it is off, stop and tell the user.
7. **Never treat Codex output as automatically correct.** You evaluate every
   finding against the actual code.
8. **Empty, timed-out, or failed Codex output is not a pass.** Any non-`ok`
   status from `codex-review.sh` stops the run.

---

## Modes

`/qg:gate` runs **full** depth. Quick mode runs the same pipeline with
cheaper Codex reviews, and is selected by either `/qg:quick` or an
invocation argument of `quick` (`/qg:gate quick`).

| | full (default) | quick |
| --- | --- | --- |
| Codex reasoning effort | whatever `~/.codex/config.toml` sets | forced `low` |
| MCP servers / plugins | loaded | disabled (startup cost only) |
| Measured on a small diff | ~209 s per review | ~50 s per review |
| Max review passes | 3 | 2 |
| Post-staging final review | always a fresh Codex run | reused when the content is byte-identical |
| Finds | high **and** lower-severity findings | prioritises high-severity; **can miss the rest** |

Set the flag once at the start of the run:

```bash
REVIEW=--full     # /qg:gate
REVIEW=--quick    # /qg:gate quick
```

Everything that makes the gate trustworthy is identical in both modes: an
independent Codex reviewer, your own evaluation of the findings, tests, the
exact-diff approval, and the verified commit. Only review *depth* changes.

**Use full, not quick, when:** the change touches auth, permissions, crypto,
payments, migrations, or deletion paths; the diff is large or spans many files;
quick mode already produced findings you had to fix. If the user asked for quick
but the change looks like one of these, say so and recommend full — then follow
their decision.

---

## Start conditions

```bash
git rev-parse --show-toplevel
$QG/quality-gate-state.sh enabled; echo "gate_enabled_exit=$?"
```

If `enabled` exits non-zero, **stop immediately** and print exactly:

```
Quality Gate is disabled for this repository.

Run:

/qg:enable

to enable it.
```

Do not enable it. Do not run any phase. Do not offer to enable it as a side
effect of another action — the user runs `/qg:enable` themselves.

---

## Phase 0 — Safety

```bash
git rev-parse --show-toplevel
git status --short
$QG/clear-approval.sh          # invalidates any stale approval; keeps the gate ON
$QG/cmux-status.sh phase Inspecting
```

`clear-approval.sh` never removes the enable marker. Never delete the enable
marker during a run.

Note in your own working memory which changes were already in the tree before
this task, so you do not later stage someone else's work.

---

## Phase 1 — Inspect

```bash
git status --short
git diff
git diff --cached
git ls-files --others --exclude-standard
```

Decide, per file, whether it belongs to **this** task. Unrelated pre-existing
modifications are common; they stay untouched and unstaged. If you cannot tell
whether a file belongs to the task, ask the user rather than guessing.

If there are no uncommitted changes at all, stop and report:

```
No uncommitted changes found.

The implementation may already have been committed.
Quality Gate requires the reviewed changes to remain uncommitted.
```

Do not "recover" by running `git reset`, `git revert`, or undoing a commit.

---

## Phase 2 — Test

```bash
$QG/cmux-status.sh phase Testing
```

Quality checks are **project-specific — never assume a command exists.**
Discover them, in this order, and only run what you actually found:

1. `CLAUDE.md`
2. `AGENTS.md`
3. `README*`
4. `package.json` (`scripts`)
5. `Makefile`
6. `pyproject.toml`
7. `Cargo.toml`
8. `go.mod`
9. `composer.json`
10. any other project-specific config (`.github/workflows/*`, `justfile`, `mise.toml`, `tox.ini`, …)

Run what is relevant to the change: lint, typecheck, unit tests, integration
tests, build. Prefer targeted tests over a full suite when the change is
localised, but do not skip a check that plausibly covers the change.

If a project has **no** discoverable checks, say so explicitly in the final
report rather than inventing a command.

**A known, related failing test blocks the run.** Fix it before Codex review.
A pre-existing failure clearly unrelated to this change does not block, but must
be named in the report.

No commits in this phase.

---

## Phase 3 — Codex review

```bash
$QG/cmux-status.sh phase "Codex Review"
$QG/codex-review.sh $REVIEW --pass 1
```

The script enforces the preconditions (repo, gate on, Codex present,
uncommitted changes present), runs `codex exec review --uncommitted` with a
read-only sandbox, and ends its stdout with:

```
QG_CODEX_STATUS=ok|unchanged|no-changes|empty|error|timeout|missing-cli|gate-off
QG_CODEX_MODE=quick|full
QG_CODEX_EXIT=<codex exit code>
QG_CODEX_REVIEW_FILE=<path>
```

Check that trailer. Only `ok` and `unchanged` continue — `unchanged` means the
uncommitted content is byte-identical to what the previous successful review
already saw, so that review still applies. For anything else:

```bash
$QG/cmux-status.sh error "Codex review failed: <status>"
```

then stop and report the status, the exit code, and the stderr tail to the user.
**Never fall back to reviewing the code yourself and calling the gate passed** —
the whole point is an independent reviewer.

Codex reviews staged, unstaged, and untracked changes together. Codex never
edits files; all fixes are yours.

---

## Phase 4 — Review evaluation

For every Codex finding, open the actual code and judge it. Classify:

**BLOCKING** — must be fixed before commit:
bug · security issue · data loss · regression · API contract violation ·
race condition · type error · missing validation · missing error handling ·
missing meaningful test · anything that causes a runtime failure

**NON-BLOCKING** — fix only if the benefit is clear, the risk is low, and it is
inside this task's scope:
style preference · speculative refactoring · premature abstraction ·
over-engineering · improvements unrelated to this change · pure taste

Rules:

- A finding you verified as wrong is dismissed. Say so in the report, with the
  one-line reason.
- "Codex said so" is not a reason to change code.
- Do not expand scope to satisfy a non-blocking suggestion.

---

## Phase 5 — Fix → Re-test → Re-review

While BLOCKING findings remain:

```bash
$QG/cmux-status.sh phase Fixing
# fix the code
$QG/cmux-status.sh phase Re-testing
# re-run the relevant checks from Phase 2
$QG/cmux-status.sh phase "Codex Review"
$QG/codex-review.sh $REVIEW --pass <n>
```

**Maximum 3 review passes in full mode, 2 in quick mode.** If BLOCKING findings
have not converged by then, **do not commit.** In quick mode, one option to offer
the user is a single full-mode review instead of giving up — but never silently
switch modes. Otherwise run:

```bash
$QG/cmux-status.sh error "Quality Gate did not converge after 3 review passes"
```

and report the outstanding findings, what you tried, and your recommendation.
Leave all changes uncommitted in the working tree.

Still no commits in this phase.

---

## Phase 6 — Stage

Only once the review has converged:

```bash
git add <explicit/path/one> <explicit/path/two>
git status --short
git diff --cached
git diff --check
```

Explicit paths only. `git diff --check` must be clean (no whitespace errors or
conflict markers). If files outside this task got staged, unstage them with
`git restore --staged <path>` — which only touches the index, never the working
tree.

---

## Phase 7 — Final Codex review

```bash
$QG/cmux-status.sh phase "Final Review"
# full mode:
$QG/codex-review.sh --full --pass final --label "Quality Gate final review"
# quick mode:
$QG/codex-review.sh --quick --pass final --label "Quality Gate final review" --skip-unchanged
```

Required after staging, even if Phase 3/5 already passed — staging can change
what is under review.

In quick mode `--skip-unchanged` lets the script reuse the previous review when
the uncommitted content has not changed by a single byte since then (staging
alone does not change it). That is why quick mode usually costs one Codex call,
not two. Any edit after a review invalidates the reuse and forces a fresh run.

If the final review yields BLOCKING findings: fix → test → stage → run the final
review again. Code that changed after a review is unreviewed code; it must never
reach a commit.

---

## Phase 8 — Exact diff approval

```bash
$QG/cmux-status.sh phase Approved
$QG/approve-commit.sh
```

This freezes the reviewed state: it records the current `HEAD` and the SHA-256 of
`git diff --cached --binary` into `git rev-parse --git-path quality-gate-approved`
(with `sha256sum`/`shasum` auto-detected).

After this point, **do not touch the code, the index, or HEAD.** Any edit
invalidates the approval and Phase 9 will refuse to commit.

---

## Phase 9 — Reviewed commit

Write the message from the **actual staged diff**. Follow the repository's
existing convention — check `git log --oneline -20` first. If it uses
Conventional Commits, use the right type (`feat:`, `fix:`, `refactor:`, `test:`,
`docs:`, `chore:`, `perf:`).

```bash
$QG/cmux-status.sh phase Committing
$QG/commit-reviewed.sh -m "fix: validate login request"
```

For a multi-line or punctuation-heavy message, write it to a temp file outside
the repository and use `-F`:

```bash
$QG/commit-reviewed.sh -F "$TMPDIR/qg-msg.txt"
```

`commit-reviewed.sh` re-verifies the gate, the approval marker, HEAD, and the
staged diff hash immediately before committing, consumes the approval on
success, and invalidates it on any failure or mismatch. If it refuses:

- *staged diff changed* → re-run `/qg:gate` from Phase 1.
- *HEAD changed* → re-run `/qg:gate`; the old review no longer applies.

Never bypass it with a direct `git commit`.

On success:

```bash
$QG/cmux-status.sh phase Completed
$QG/cmux-status.sh notify-passed "<short summary>"
```

`notify-passed` is the **only** notification this workflow emits. Do not notify
on ordinary turn completion.

---

## Push is out of scope

The gate ends at the commit. Do not run `git push`, `git push --force`, or
`gh pr create` unless the user explicitly asks in a separate request.

---

## Final report

Keep it tight. On success:

```
Quality Gate passed

Tests:
- npm run typecheck
- npm test -- auth

Codex:
- Mode: quick
- Review passes: 2
- Fixed:
  - missing validation in login handler
- Non-blocking:
  - naming suggestion not applied

Commit:
- SHA: abc1234
- Message: fix: validate login request
```

On failure, report the phase that stopped the run, why, what remains
uncommitted, and the recommended next step. Also run
`$QG/cmux-status.sh error "<reason>"` so the failure is visible in cmux.

---

## Script reference

| Script | Purpose |
| --- | --- |
| `quality-gate-state.sh enabled\|enable\|disable\|status` | gate state; markers live inside the Git dir |
| `codex-review.sh [--quick\|--full] --pass <n> [--skip-unchanged]` | independent Codex review of uncommitted changes |
| `approve-commit.sh` | freeze HEAD + staged-diff SHA-256 |
| `commit-reviewed.sh -m\|-F\|--stdin` | the only sanctioned commit path |
| `clear-approval.sh` | invalidate a pending approval (keeps the gate ON) |
| `cmux-status.sh phase\|log\|ok\|error\|notify-passed\|clear` | optional cmux feedback; no-ops without cmux |
