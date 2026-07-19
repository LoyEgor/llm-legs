# llm-legs

Subscription-only multi-account/multi-vendor LLM orchestration: `llm-limits.sh` collects
Claude/Codex/Gemini usage into `~/.llm-limits.json`; `bin/claudeb` + `bin/claudebd` (rotating
proxy on `127.0.0.1:45789`) rotate and heal multiple Claude accounts; `bin/codexb` does the
same for Codex; `hammerspoon/llm-limits.lua` renders it all in the macOS menubar.

**Before debugging anything here, read `docs/DIAGNOSTICS.md`** — it has the system map, a
symptom→command lookup table, the 429 taxonomy, and the test suites.

**Any statusline work is bound by `docs/statusline-contract.md`** — every segment must declare
its source of truth, update trigger, staleness/dim policy, and removal condition; "render once
and forget" is forbidden. Keep that table exhaustive and update `tests/test_statusline_hooks.sh`
whenever you add, remove, or change a segment (`bin/statusline.sh` or a `statusline-*` hook/probe).

Cardinal rules:
- Never point a test or ad-hoc check at the real daemon on port 45789 or the real
  `~/.claude-profiles/.claudeb` store — use `CLAUDEB_DIR`/`CLAUDEBD_PORT`/`CLAUDEBD_UPSTREAM`.
- Never mutate the live Hammerspoon singleton (`package.loaded["llm-limits"]`) — read-only
  calls (`menuItems()`) only, or the user's real menubar breaks silently.
- Never commit without the user's explicit, per-commit permission.

Run the suites: `bash tests/test_llm_limits.sh && bash tests/test_claudeb.sh && bash tests/test_claudebd.sh && bash tests/test_claudebd_live.sh && bash tests/e2e_surfaces.sh && bash tests/test_codexb.sh`
