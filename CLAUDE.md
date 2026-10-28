# llm-legs

Multi-account, multi-vendor LLM orchestration on subscriptions.

**Before debugging anything here, grep `docs/DIAGNOSTICS.md` for the symptom.**

**Any statusline work is bound by `docs/statusline-contract.md`.**

**Experiments: registered, announced, removed whole**; `EXPERIMENTS.json`,
`claude-setup/skills-on-demand/experiment`.

Cardinal rules:
- Never point a test or ad-hoc check at the real `~/.claude-profiles/.claudeb` store — `CLAUDEB_DIR`
  fixtures only; it holds the live account snapshots every routing decision reads.
- Never mutate the live Hammerspoon singleton (`package.loaded["llm-limits"]`) — read-only calls
  (`menuItems()`) only, or the user's real menubar breaks silently.

Cross-implementation invariants (bash/jq/Lua/prose) are guarded by `docs/shared-invariants.md` +
`bash tests/test_consistency.sh`.
