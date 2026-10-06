# qg — Quality Gate for Claude Code

Claude Code implements. **Codex CLI reviews, independently.** A commit only
happens after the exact staged diff has passed review.

**Off by default.** Installing this plugin changes nothing until you opt a
repository in with `/qg:enable`. Every other repository keeps its normal Git
workflow.

```
Implement → Test → Codex Review → Fix → Re-test → Codex Re-review
→ Stage → Final Codex Review → Exact Diff Approval → Commit
```

## Commands

| Command | What it does |
| --- | --- |
| `/qg:enable` | Opt this repository in |
| `/qg:status` | Show gate state, Codex/cmux availability, pending approval |
| `/qg:gate` | Run the full gate and commit at the end |
| `/qg:standard` | Same gate, medium-depth Codex reviews (the everyday default) |
| `/qg:quick` | Same gate, faster/shallower Codex reviews |
| `/qg:disable` | Opt out, back to the normal Git workflow |

## Install

```bash
git clone git@github.com:n-qwed/quality-gate.git ~/.claude/skills/qg
```

Then `/reload-plugins`, or restart Claude Code. It loads as `qg@skills-dir`.

Update with `git -C ~/.claude/skills/qg pull`. Uninstall by deleting the
directory (`claude plugin disable qg@skills-dir` to switch it off temporarily).

## Requirements

| | |
| --- | --- |
| **Required** | `git`, `jq`, Bash, [Codex CLI](https://github.com/openai/codex) authenticated |
| **Optional** | [cmux](https://cmux.dev) for sidebar progress and a completion notification — the gate works fine without it |
| **Platforms** | macOS and Linux. Written for **bash 3.2** (the macOS default), so no GNU coreutils and no bash 4 features: `sha256sum`/`shasum` are auto-detected and a built-in watchdog replaces `timeout`. |

## How the gate is enforced

A `PreToolUse` hook on the Bash tool (`hooks/hooks.json`) denies `git commit`
**only** when the current repository has the gate enabled. It stays completely
silent otherwise, so it never interferes with normal work, and it never touches
`git commit` typed by you in your own terminal — Claude Code's Bash tool is the
only thing it sees.

Commits go through `scripts/commit-reviewed.sh`, which immediately before
committing re-checks that `HEAD` and the SHA-256 of `git diff --cached --binary`
still match what was approved after the final Codex review. Any drift is
refused and the stale approval is invalidated.

## Seeing it work

A Codex review is one long blocking call, so the gate reports progress
out-of-band. While `codex exec review` runs, a cmux pill is refreshed every 5
seconds with the elapsed time and the command Codex is currently running:

```
[⚡ Running]  [🔍 Codex 1:23 · ls -la; git ls-files]
```

It is cleared when the call returns. Without cmux this is a silent no-op and the
review is unaffected. The review artifact also records every command Codex ran,
so you can check afterwards that it really looked at your changes.

## State lives inside the Git directory

Markers are written to paths from `git rev-parse --git-path`:

| Marker | Meaning |
| --- | --- |
| `quality-gate-enabled` | the gate is on for this repository/worktree |
| `quality-gate-approved` | `HEAD` + staged-diff SHA-256 that passed review |
| `quality-gate-review-latest.md` | the last Codex review, plus its content fingerprint |

So nothing ever shows up in `git status`, nothing can be committed by accident,
and linked worktrees get independent state.

## Modes

| | `/qg:gate` (full) | `/qg:standard` | `/qg:quick` |
| --- | --- | --- | --- |
| Codex model | `gpt-6.1-sol` | `gpt-6.1-sol` | `gpt-6.1-sol` |
| Codex reasoning effort | `high` | `medium` | `low` |
| MCP servers / plugins | loaded | disabled | disabled |
| Max review passes | 3 | 3 | 2 |
| Review timeout (default) | 2400 s | 900 s | 300 s |
| Final review after staging | always fresh | reused when content is byte-identical | reused when content is byte-identical |

Standard and quick mode reduce review **depth only**. The independent reviewer,
your own evaluation of every finding, the tests, the exact-diff approval and the
verified commit are identical in all modes. Use full mode for auth, crypto,
payments, migrations, deletion paths, and large diffs.

The model per mode can be overridden with `QG_MODEL_FULL`, `QG_MODEL_STANDARD`
and `QG_MODEL_QUICK`. Setting one to the empty string leaves the model to
`~/.codex/config.toml`; the reasoning effort stays pinned per mode.

## Safety rules baked in

The gate never runs `git reset --hard`, `git checkout -- .`, `git restore .`,
`git clean -fd`, or `git stash`, never uses `git add .` / `git add -A`, never
pushes or opens PRs, and never enables itself. Empty, timed-out, or failed Codex
output is never treated as a pass.

## Tests

```bash
~/.claude/skills/qg/tests/verify.sh
```

Runs ~133 checks in throwaway repositories and deletes them afterwards; it never
touches a real repository. Codex is stubbed for the invocation tests, so the
suite needs no network, no tokens, and finishes in seconds. It covers the
default-OFF contract, hook allow/deny decisions, marker invisibility to
`git status`, approval drift and HEAD drift refusal, worktree independence, and
the argument assembly of all three review modes.

## Layout

```
qg/
├── .claude-plugin/plugin.json
├── hooks/hooks.json                        PreToolUse registration
├── hooks-handlers/
│   └── block-unreviewed-commit.sh          self-contained; fails open
├── skills/{gate,standard,quick,enable,disable,status}/SKILL.md
└── scripts/
    ├── quality-gate-state.sh               state + shared library
    ├── codex-review.sh                     independent Codex review
    ├── approve-commit.sh                   freeze HEAD + staged diff hash
    ├── commit-reviewed.sh                  the only sanctioned commit path
    ├── clear-approval.sh                   invalidate a pending approval
    └── cmux-status.sh                      optional cmux feedback
```
