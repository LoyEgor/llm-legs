# llm-legs

Multi-account, multi-vendor LLM orchestration on subscriptions.

**Before debugging anything here, read `docs/DIAGNOSTICS.md`** — system map, symptom→command table,
the 429 taxonomy, suites.

Robot curl refresh is permanently disabled in code — never restore automated curl refreshes; the
user-explicit menu refresh stays. Temporary scaffolding is tracked in `docs/EXIT-PLAN.md`.

**Any statusline work is bound by `docs/statusline-contract.md`** — keep its segment table
exhaustive and update `tests/test_statusline_hooks.sh` whenever a segment changes.

**Experiments are registered, announced, and removed whole** — `EXPERIMENTS.json`, enforced by
`tests/test_experiments_registry.sh`; its overdue failure IS the ask-the-owner reminder, never extend
a date or weaken that test yourself. Procedure: the `experiment` skill.

Cardinal rules:
- Never point a test or ad-hoc check at the real `~/.claude-profiles/.claudeb` store — `CLAUDEB_DIR`
  fixtures only; it holds the live account snapshots every routing decision reads.
- Never mutate the live Hammerspoon singleton (`package.loaded["llm-limits"]`) — read-only calls
  (`menuItems()`) only, or the user's real menubar breaks silently.

Suites: `bash tests/run-all` (`--all` adds the live ones). Cross-implementation invariants
(bash/jq/Lua/prose) are guarded by `docs/shared-invariants.md` + `bash tests/test_consistency.sh` —
run it after touching a staleness threshold, the keychain service formula, the pin file paths or
the weather HTTP class lists.

## launchd / autostart jobs
Every LaunchAgent created or modified for Egor must be identifiable in macOS Login Items by a
meaningful name: ProgramArguments points at a wrapper in `~/.local/libexec/<descriptive-name>`
(e.g. `llm-refresh-heartbeat`, `memlogd`) that `exec`s the real interpreter+script — never bare
`python3`/`bash`/`node` as the visible program. Keep repo plists consistent with it. Renaming or
toggling a Login Item reloads the job (SIGTERM + restart) — harmless service restarts are expected.
