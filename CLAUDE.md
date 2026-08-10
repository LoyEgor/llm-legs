# llm-legs

Subscription-only multi-account/multi-vendor LLM orchestration: `llm-limits.sh` collects
Claude/Codex/Gemini usage into `~/.llm-limits.json`; `bin/claudeb` manages explicit Claude
profiles and heals their snapshots; `bin/codexb` does the
same for Codex; `hammerspoon/llm-limits.lua` renders it all in the macOS menubar.

**Before debugging anything here, read `docs/DIAGNOSTICS.md`** — it has the system map, a
symptom→command lookup table, the 429 taxonomy, and the test suites.

**Temporary scaffolding lives in `docs/EXIT-PLAN.md`** — the shadow-trial stack is gone; the
one piece still temporary is the token-freeze marker `~/.claude-profiles/.claudeb/token-freeze`,
which exits with the escalating-refresh work that replaces it. Never treat it as permanent
architecture, and never restore automated curl refreshes around it.

**Any statusline work is bound by `docs/statusline-contract.md`** — keep its segment table
exhaustive and update `tests/test_statusline_hooks.sh` whenever a segment changes
(`bin/statusline.sh` or a `statusline-*` hook/probe).

**Experiments are registered, announced, and removed whole.** `EXPERIMENTS.json` is the
registry; `tests/test_experiments_registry.sh` enforces it, and its overdue failure IS the
ask-the-owner reminder — never extend a date or weaken that test yourself. Removal is total,
per the entry's `how_to_remove`. The `experiment` skill holds the full procedure.

Cardinal rules:
- Never point a test or ad-hoc check at the real `~/.claude-profiles/.claudeb` store — use
  `CLAUDEB_DIR` for fixtures.
- Never mutate the live Hammerspoon singleton (`package.loaded["llm-limits"]`) — read-only
  calls (`menuItems()`) only, or the user's real menubar breaks silently.

Core suites (a subset — the full set is `ls tests/`; run the suites covering what you touched):
`bash tests/test_llm_limits.sh && bash tests/test_claudeb.sh && bash tests/e2e_surfaces.sh && bash tests/test_codexb.sh && bash tests/test_geminib.sh && bash tests/test_legs_routing.sh && bash tests/test_experiments_registry.sh`

Cross-implementation invariants (values duplicated across bash/jq/Lua/prose) are guarded by
`docs/shared-invariants.md` + `bash tests/test_consistency.sh` — run it after touching any
staleness threshold, the keychain service formula, the worker-pick cache format, or the weather
HTTP class lists.
