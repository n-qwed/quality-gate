---
name: standard
description: Run the Quality Gate with medium-depth Codex reviews (gpt-6.1-sol, reasoning effort medium, MCP disabled). Faster than full, deeper than quick; same safety chain.
disable-model-invocation: true
---

# Quality Gate (standard)

Same gate, medium-depth reviews. The everyday middle ground between `/qg:gate`
(full: frontier model at high effort) and `/qg:quick` (shallow).

1. Read `${CLAUDE_PLUGIN_ROOT}/skills/gate/SKILL.md` in full.
2. Follow it exactly, with:

```bash
REVIEW=--standard
```

3. That means: Codex runs `gpt-6.1-sol` at reasoning effort `medium`, MCP
   servers and plugins disabled, a 900 s review timeout, max **3** review passes, and the
   post-staging final review uses `--skip-unchanged` so it is reused when
   nothing changed byte-for-byte since the previous review.

Nothing about the safety chain is relaxed: Codex still reviews independently,
you still evaluate every finding yourself, tests still run, the exact staged
diff is still approved, and the commit still goes through
`commit-reviewed.sh`. Only review **depth** is reduced.

## When to refuse standard and recommend full

Say so and recommend `/qg:gate` if the change touches authentication,
authorization, crypto, payments, data migrations, or deletion paths; if the diff
is large or spans many files; or if standard mode has already surfaced findings
you had to fix. State the reason in one line, then follow the user's decision.
