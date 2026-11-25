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

This repository is also a Claude Code plugin marketplace (`quality-gate`).
In Claude Code 2.1.275 or later:

```
/plugin install qg --marketplace n-qwed/quality-gate
```

Or in two steps (any version with marketplaces):

```
/plugin marketplace add n-qwed/quality-gate
/plugin install qg@quality-gate
```

It loads as `qg@quality-gate`.

**Update.** Users receive a new release when `version` in
`.claude-plugin/plugin.json` is raised, so bump it with every release.
Marketplaces you add yourself do not auto-update by default: run
`/plugin marketplace update quality-gate`, or turn on auto-update for it in the
`/plugin` Marketplaces tab.

**Uninstall** with `/plugin uninstall qg@quality-gate`
(`/plugin disable qg@quality-gate` to switch it off temporarily).

**Team rollout (optional).** Commit this to a project's `.claude/settings.json`
so teammates are offered the marketplace once they trust the folder:

```json
{
  "extraKnownMarketplaces": {
    "quality-gate": {
      "source": { "source": "github", "repo": "n-qwed/quality-gate" }
    }
  },
  "enabledPlugins": { "qg@quality-gate": true }
}
```

Each teammate still installs it once with
`claude plugin install qg@quality-gate --scope project`.

### Developing from a clone

To hack on the plugin itself, clone it into the skills directory instead:

```bash
git clone git@github.com:n-qwed/quality-gate.git ~/.claude/skills/qg
```

Then `/reload-plugins`; it loads as `qg@skills-dir`. If the marketplace copy is
also installed, it takes precedence and the clone shows as "Not loaded" in the
`/plugin` Errors tab, so disable `qg@quality-gate` while you work on the clone.

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

The repository is judged where each `git commit` actually runs: the session
directory, followed through `cd <dir>`, subshells `( ... )`, command
substitutions `$( ... )` / backticks (parsed recursively) and `git -C <dir>`.
Quotes are respected, so a message like `-m "fix(api): x && cd y"` is not
mistaken for a command. Here-document bodies fed to a shell (`bash <<EOF`,
`cat <<EOF | sh`) are judged as commands; other bodies are data, but one that
looks like `git ... commit` still counts as a commit at that point.

It fails closed on doubt. When the directory cannot be known — a variable,
`cd -`, `pushd`/`popd`, `--git-dir`/`--work-tree`, `GIT_DIR=...`, or a `cd`
whose effect depends on control flow (after `&&`/`||`, or before `||`, `|`,
`&`) — every directory the command visited, including the session directory,
is checked as well.

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
| Codex model | `gpt-6.2-astra` | `gpt-6.2-astra` | `gpt-6.2-astra` |
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
`~/.codex/config.toml`; the reasoning effort stays pinned per mode. To go back
to the previous default, for example:

```zsh
export QG_MODEL_FULL=gpt-6.1-sol QG_MODEL_STANDARD=gpt-6.1-sol QG_MODEL_QUICK=gpt-6.1-sol
```

### Why `gpt-6.2-astra`

All three modes were benchmarked with `gpt-6.1-sol`, `gpt-6.2-sol` and
`gpt-6.2-astra` (27 reviews) on throwaway repositories with planted defects,
including subtle cross-file ones (a signature check that accepts mismatched
lengths, session expiry written in ms but checked in s, a cache that skips the
ownership check, a transaction update sent through the pool).

| | `gpt-6.1-sol` | `gpt-6.2-sol` | `gpt-6.2-astra` |
| --- | --- | --- | --- |
| Planted defects found (hard set, 6 reviews) | 47/48 | 48/48 | 48/48 |
| Rated "sessions never expire" P1 or higher | 1/6 | 0/6 | 6/6 |
| Median time, quick / standard / full | 65 / 64 / 143 s | 76 / 105 / 138 s | 69 / 67 / 88 s |
| Input tokens, full | 107k–145k | 98k–112k | 40k–46k |
| False positives on correct decoy code | 0 | 0 | 0 |

`gpt-6.2-astra` found as much as the others, rated severity most accurately at
every effort level, and was the fastest in full mode. Raising the effort barely
slows it down (high ≈ +30 % time over medium), while the `sol` models roughly double.
Deeper business-logic findings (refunds on unpaid orders, payments lost after a
cancellation) appeared only at medium/high effort.

Not yet measured: how much of the Codex usage limit `gpt-6.2-astra` consumes
per review compared with `gpt-6.1-sol`. An earlier frontier model (`gpt-6-astra`)
used about five times as much, so watch the weekly limit after switching.

## Safety rules baked in

The gate never runs `git reset --hard`, `git checkout -- .`, `git restore .`,
`git clean -fd`, or `git stash`, never uses `git add .` / `git add -A`, never
pushes or opens PRs, and never enables itself. Empty, timed-out, or failed Codex
output is never treated as a pass.

## Tests

```bash
~/.claude/skills/qg/tests/verify.sh
```

Runs ~176 checks in throwaway repositories and deletes them afterwards; it never
touches a real repository. Codex is stubbed for the invocation tests, so the
suite needs no network, no tokens, and finishes in seconds. It covers the
default-OFF contract, hook allow/deny decisions, marker invisibility to
`git status`, approval drift and HEAD drift refusal, worktree independence, and
the argument assembly of all three review modes.

## Layout

```
qg/
├── .claude-plugin/
│   ├── plugin.json                         plugin manifest (name, version)
│   └── marketplace.json                    makes this repo the `quality-gate` marketplace
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
