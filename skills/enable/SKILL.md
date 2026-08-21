---
name: enable
description: Turn on the Codex-reviewed commit Quality Gate for the current Git repository. Only the user may invoke this.
disable-model-invocation: true
---

# Enable Quality Gate

Turns Quality Gate ON for **this repository only**. Every other repository is
unaffected — Quality Gate is OFF by default everywhere.

State is written to `git rev-parse --git-path quality-gate-enabled`, i.e. inside
the Git administrative directory. It never appears in `git status` and can never
be committed. In a linked worktree the marker is worktree-local, which is
intended.

## Steps

Run exactly this:

```bash
QG="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/qg}/scripts"
"$QG/quality-gate-state.sh" enable && "$QG/quality-gate-state.sh" status
```

`enable` prints `enabled` on success, or `already-enabled` if it was already on.
It fails with a clear error outside a Git repository.

Then give the sidebar a short marker (best effort, no notification):

```bash
"${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/qg}/scripts/cmux-status.sh" log "Quality Gate enabled"
```

## Reporting

On success:

```
Quality Gate enabled for this repository.

Direct commits by Claude Code will now be blocked.
Run /qg:gate when you are ready to review and commit.
```

If it was already on — this is **not** an error:

```
Quality Gate is already enabled for this repository.
```

Outside a Git repository, report the script's error and stop.

## Hard rules

- Never create, modify, or delete any file in the working tree.
- Never `git add`, `git commit`, or otherwise record this change in Git.
- Do not run tests, reviews, or any part of `/qg:gate` here.
