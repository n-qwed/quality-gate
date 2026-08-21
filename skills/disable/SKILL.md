---
name: disable
description: Turn off the Codex-reviewed commit Quality Gate for the current Git repository and return to the normal Git workflow. Only the user may invoke this.
disable-model-invocation: true
---

# Disable Quality Gate

Turns Quality Gate OFF for **this repository only** and clears any pending
approval so it can never be reused later.

## Steps

```bash
QG="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/qg}/scripts"
"$QG/quality-gate-state.sh" disable && "$QG/quality-gate-state.sh" status
```

`disable` removes the enable marker, the approval marker, and any stale Codex
review artifact. It prints `was-enabled` or `disabled`, and exits 0 in both
cases — already being off is **not** an error.

Optionally clear the sidebar (best effort, no notification):

```bash
"${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/qg}/scripts/cmux-status.sh" clear
```

## Reporting

On success:

```
Quality Gate disabled for this repository.

Claude Code can now use the normal Git commit workflow.
```

If it was already off, say so plainly and do not treat it as a failure.

Outside a Git repository, report the script's error and stop.

## Hard rules

- Never create, modify, or delete any file in the working tree.
- Never commit the enable/disable change — there is nothing in the working tree
  to commit by design.
