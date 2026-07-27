# EXIT-PLAN — temporary scaffolding and its dismantling

decision-date: 2026-07-26

This file is the authoritative inventory of everything in llm-legs that exists ONLY for
the shadow trial / stabilization period. None of it is meant to survive. Any session
(human or LLM, with or without prior context) that reads this after the decision date
must proactively propose executing the exit below — the owner has explicitly asked not
to have to remember or re-ask. `llm-selfcheck` emits a daily "exit-plan review due"
reminder after the decision date; that reminder is itself part of the scaffolding.

## Why the trial exists

Five uncoordinated bash writers do read-modify-write on locked JSON snapshots
(`~/.llm-limits.json`, `~/.claude-profiles/.claudeb/limits/<account>.json`,
`oauth-attempts.json`), historically causing lost updates and stuck verdicts
("writers rot"). The shadow ledger observes whether this class still fires in real
life, without touching the real data path.

## Temporary inventory (ALL of it goes away at exit)

1. `bin/llm-limitsd` + `launchd/com.llm-limitsd.plist` + `~/.llm-limits-shadow.json`
   + `~/.claude-profiles/.claudeb/limitsd.sqlite` (daemon on 127.0.0.1:45791)
2. `bin/llm-limitsd-shadow-feed` + `launchd/com.llm-limitsd-shadow-feed.plist`
   + `~/.claude-profiles/.claudeb/shadow-feed.state`
3. `bin/llm-shadow-divergence` + the `shadow-divergence` step in `bin/llm-selfcheck`
4. Full `e2e_surfaces.sh` inside the DAILY selfcheck (at exit it slims to the hermetic
   suites plus a ~10s live smoke: hs alive + menu builds; the full e2e stays as a
   manual/change-time tool)
5. The `exit-plan-review` reminder step in `bin/llm-selfcheck` and this file's
   `decision-date` mechanism
6. `tests/test_llm_limitsd.sh`, `tests/test_llm_limitsd_shadow_feed.sh` and the
   shadow-related asserts in `tests/test_llm_selfcheck.sh`

## Exit decision (one of two outcomes)

**Default — dismantle and simplify (expected).** If the divergence watch stayed clean
through the trial (no real writers-rot divergences, only feeder/propagation noise):

- Give the ~5 bash writers one shared serialized write-helper (single global lock +
  atomic merge; the proven pattern is `glock` in `bin/claudeb`'s `oauth_refresh`).
- Dismantle EVERYTHING in the inventory: `launchctl bootout gui/$UID` both shadow
  jobs, delete the two plists (repo + `~/Library/LaunchAgents`), delete the binaries,
  suites, shadow projection, sqlite db, state files, the selfcheck shadow/reminder
  steps, and slim the selfcheck e2e per item 4. Remove this file last, plus its
  pointer in CLAUDE.md.
- End state: zero extra daemons, one write discipline, nothing labeled temporary.

**Escalation — only on hard evidence.** If the trial logged REAL writer-rot
divergences that a shared lock cannot fix (semantic merge conflicts, not timing):
proceed to the original step 3-4 cutover (writers post observations; the ledger owns
`~/.llm-limits.json`), and then still dismantle the feeder, the divergence comparator,
and the replaced writer code paths. The daemon survives only in this branch.

The judgment call between the two belongs to the session executing the exit, based on
`~/.claude-profiles/.claudeb/selfcheck.log` history and the ledger's divergence record.

## Token-freeze experiment

decision-date: 2026-08-03

Anthropic's OAuth token endpoint intermittently 429s our accounts. Hypothesis under
test: our own automated refresh traffic earned the rate-limiting. Phase 1 froze every
ROBOT path and produced zero token-endpoint 429s from 2026-07-23 through 2026-07-27.
Phase 2 runs through 2026-08-03: scheduled automation remains frozen, while every
user-initiated menu refresh is allowed to drive the real Claude CLI warm path. On
2026-07-27 the global `Refresh` and `Refresh + Start Windows` actions began carrying the
same explicit user signal as per-account Hard refresh. Direct `oauth_refresh()` POSTs
remain frozen; the experiment now isolates manual warm traffic from scheduled traffic.

**Temporary inventory (what exits): the freeze FILE only** —
`~/.claude-profiles/.claudeb/token-freeze`. The switch (`token_freeze_active`), the
attempt journal (`token-attempts.jsonl` + `token_journal`), and the honest frozen
stale-cause in `llm-limits.sh` are permanent and cheap; they stay.

**Exit decision (one of two outcomes).** Review `token-attempts.jsonl` plus the owner's
menu-refresh experience. The journal legitimately carries more than `frozen-skip`:
user-initiated menu warms (`kind=warm`) and keychain adoptions from manual CLI sessions
(`kind=adopt`) are expected. What must NOT appear is an unbidden `curl-refresh` with a
real HTTP outcome — that would mean a robot POSTed the token endpoint despite the freeze:

- **Hypothesis holds** (manual refreshes stay 429-free through the window): keep
  automation off and make its measured reintroduction a separate parasite-mode task,
  piggy-backing on the CLI's own refreshes instead of posting independently.
- **Hypothesis rejected or incomplete** (429s return under manual-only traffic): our
  automation was not the sole cause; delete the freeze file and restore automation as-is.
