# llm-legs

Subscription-only multi-account/multi-vendor LLM orchestration: `llm-limits.sh` collects
Claude/Codex/Gemini usage into `~/.llm-limits.json`; `bin/claudeb` + `bin/claudebd` (rotating
proxy on `127.0.0.1:45789`) rotate and heal multiple Claude accounts; `bin/codexb` does the
same for Codex; `hammerspoon/llm-limits.lua` renders it all in the macOS menubar.

**Before debugging anything here, read `docs/DIAGNOSTICS.md`** — it has the system map, a
symptom→command lookup table, the 429 taxonomy, and the test suites.

**Temporary scaffolding lives in `docs/EXIT-PLAN.md`** — the shadow-trial stack (llm-limitsd,
shadow-feed, divergence watch, full-e2e-in-selfcheck) is planned-temporary. After that file's
decision-date, any session must proactively propose executing the exit plan; never treat those
components as permanent architecture.

**Any statusline work is bound by `docs/statusline-contract.md`** — every segment must declare
its source of truth, update trigger, staleness/dim policy, and removal condition; "render once
and forget" is forbidden. Keep that table exhaustive and update `tests/test_statusline_hooks.sh`
whenever you add, remove, or change a segment (`bin/statusline.sh` or a `statusline-*` hook/probe).

**Experiments are registered, announced, and removed whole.** `EXPERIMENTS.json` is the
registry of live trials; `bash tests/test_experiments_registry.sh` fails on an unregistered
`TEMP-<NAME>(<scope>)` tag, on an entry whose code is gone, and on any entry past its
`review_by` — that failure IS the standing reminder to ask the owner for a decision. Never
extend a date or weaken that test yourself, and never leave residue behind: a finished
experiment is removed completely per its `how_to_remove`, registry entry last. Setting one up
(or reviewing an overdue one) is what the `experiment` skill is for — it holds the full
procedure, so nothing about experiments needs to live in this file beyond this paragraph.

Cardinal rules:
- Never point a test or ad-hoc check at the real daemon on port 45789 or the real
  `~/.claude-profiles/.claudeb` store — use `CLAUDEB_DIR`/`CLAUDEBD_PORT`/`CLAUDEBD_UPSTREAM`.
- Never mutate the live Hammerspoon singleton (`package.loaded["llm-limits"]`) — read-only
  calls (`menuItems()`) only, or the user's real menubar breaks silently.
- Never commit without the user's explicit, per-commit permission.

Run the suites: `bash tests/test_llm_limits.sh && bash tests/test_claudeb.sh && bash tests/test_claudebd.sh && bash tests/test_claudebd_live.sh && bash tests/e2e_surfaces.sh && bash tests/test_codexb.sh && bash tests/test_geminib.sh && bash tests/test_experiments_registry.sh`

Cross-implementation invariants (values duplicated across bash/jq/Lua/prose) are guarded by
`docs/shared-invariants.md` + `bash tests/test_consistency.sh` — run it after touching any
staleness threshold, the keychain service formula, the worker-pick cache format, or the weather
HTTP class lists.
