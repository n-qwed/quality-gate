---
name: status
description: Show whether the Codex-reviewed commit Quality Gate is enabled for the current Git repository, plus Codex CLI and cmux availability.
---

# Quality Gate status

Read-only. Reports state for the current repository and makes **no** changes.

## Steps

```bash
QG="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/qg}/scripts"
"$QG/quality-gate-state.sh" status
echo "Codex CLI: $(command -v codex >/dev/null 2>&1 && echo available || echo unavailable)"
echo "cmux: $(command -v cmux >/dev/null 2>&1 && echo available || echo unavailable)"
```

`status` prints `Quality Gate: ENABLED|DISABLED`, `Repository: <root>`, and when
enabled also `Pending approval: yes|no`.

## Reporting

When enabled:

```
Quality Gate

Status: ENABLED
Repository: /Users/example/project
Codex CLI: available
cmux: available
Pending approval: no
```

When disabled, keep it short — the extra lines are noise:

```
Quality Gate

Status: DISABLED
Repository: /Users/example/project
```

Outside a Git repository, report the script's error and stop.

## Hard rules

- Never modify the repository, the markers, or any settings from this skill.
- Never enable or disable the gate here; that is `/qg:enable` and
  `/qg:disable`.
