# llm-legs

Multi-account, multi-vendor LLM orchestration on subscriptions.

**Before debugging anything here, read `docs/DIAGNOSTICS.md`.**

**Any statusline work is bound by `docs/statusline-contract.md`.**

**Experiments are registered, announced, and removed whole** — `EXPERIMENTS.json`; procedure: the
`experiment` skill.

Cardinal rules:
- Never point a test or ad-hoc check at the real `~/.claude-profiles/.claudeb` store — `CLAUDEB_DIR`
  fixtures only; it holds the live account snapshots every routing decision reads.
- Never mutate the live Hammerspoon singleton (`package.loaded["llm-limits"]`) — read-only calls
  (`menuItems()`) only, or the user's real menubar breaks silently.

Cross-implementation invariants (bash/jq/Lua/prose) are guarded by `docs/shared-invariants.md` +
`bash tests/test_consistency.sh`.
