---
name: quick
description: Run the Quality Gate with faster, shallower Codex reviews (reasoning effort low, MCP disabled). Same safety chain, less review depth.
disable-model-invocation: true
---

# Quality Gate (quick)

Same gate, cheaper reviews.

1. Read `${CLAUDE_PLUGIN_ROOT}/skills/gate/SKILL.md` in full.
2. Follow it exactly, with:

```bash
REVIEW=--quick
```

3. That means: max **2** review passes, and the post-staging final review uses
   `--skip-unchanged` so it is reused when nothing changed byte-for-byte since
   the previous review.

Nothing about the safety chain is relaxed: Codex still reviews independently,
you still evaluate every finding yourself, tests still run, the exact staged
diff is still approved, and the commit still goes through
`commit-reviewed.sh`. Only review **depth** is reduced.

## When to refuse quick and recommend full

Say so and recommend `/qg:gate` if the change touches authentication,
authorization, crypto, payments, data migrations, or deletion paths; if the diff
is large or spans many files; or if quick mode has already surfaced findings you
had to fix. State the reason in one line, then follow the user's decision.
