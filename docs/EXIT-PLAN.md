# EXIT-PLAN — temporary scaffolding and its dismantling

The shadow-trial stack this file also inventoried (`llm-limitsd`, the shadow feed, the
divergence watch, their launchd jobs and suites, and the full `e2e_surfaces.sh` inside the
daily selfcheck) was dismantled on 2026-08-09. One temporary thing is left, below.

## Token-freeze experiment

decision-date: 2026-08-09 (verdict executed)

Anthropic's OAuth token endpoint intermittently 429s our accounts. Hypothesis under
test: our own automated refresh traffic earned the rate-limiting. Phase 1 froze every
ROBOT path and produced zero token-endpoint 429s from 2026-07-23 through 2026-07-27.
Phase 2 ran through 2026-08-03: scheduled automation remained frozen, while every
user-initiated menu refresh was allowed to drive the full refresh chain. On
2026-07-27 the global `Refresh` and `Refresh + Start Windows` actions began carrying the
same explicit user signal as per-account Hard refresh. That signal exempts the invocation's
warm, heal, and direct `oauth_refresh()` POSTs from the freeze; its journal entries carry
`"user":true`. The experiment isolates user-bidden traffic from scheduled traffic.

**Verdict (2026-08-09):** The verdict went to the parasite-mode branch. The curl token
path is vendor-blocked: 150/150 unbidden and 18/18 user-bidden curl refreshes got 429
after the freeze, while interactive CLI sessions rotate tokens instantly.
As a result, `~/.claude-profiles/.claudeb/token-freeze` was made indefinite (no `until`
condition) pending the replacement escalating refresh.

**Temporary inventory (what exits): the freeze FILE only** —
`~/.claude-profiles/.claudeb/token-freeze`. The switch (`token_freeze_active`), the
attempt journal (`token-attempts.jsonl` + `token_journal`), and the honest frozen
stale-cause in `llm-limits.sh` are permanent and cheap; they stay.

**Decisive finding 2026-07-31 (~03:35, owner at the keyboard) — read before choosing a
branch.** The 429 is NOT a per-account vendor window; it targets OUR OWN direct curl POST
to the token endpoint. From `token-attempts.jsonl`: three user-bidden curl refreshes on
alona 429'd (03:20–03:34, Retry-After 1800s, only ~3 POSTs went out — we were not
hammering), yet an INTERACTIVE CLI entry at ~03:35 rotated the same account's token
instantly, and the next hard refresh succeeded with fresh data. A headless
`claude -p /usage` never rotates a token at all (num_turns 0, proven twice in warm-logs);
only an interactive session does. Consequences: manual-traffic 429s do NOT justify the
plain "rejected → restore automation as-is" branch — "our automation was the sole cause"
is rejected only for the curl path, and the curl path itself is the wrong mechanism. The
evidence-backed direction is the parasite-mode branch, and its blocker is that a parasite
needs a real-session driver (the owner floated letting it open terminals and enter
accounts). Do not reuse the 2026-07-23 model ("inside a block window nothing refreshes,
interactive hangs too") — it came from a different failure.

**Deferred to this decision — staleness threshold recalibration.** The freeze exposed that
account age used to track the NEWEST window while passive `origin:"session"` traffic kept
`five_hour` perpetually fresh, so hours-old weekly/fable readings rendered as minutes-old.
The age itself was fixed in ecfbf85 (account/vendor age = oldest window carrying a non-null
`used_pct`), but the staleness thresholds (five_hour 1800s, weekly/fable 21600s —
`docs/shared-invariants.md` row a) still assume the auto-refresh era: under manual-only
refresh, 3h-old fable data renders unmarked and worker-pick trusts it. Whichever outcome is
chosen sets the real refresh cadence — recalibrate (or re-affirm) those thresholds against
it as part of executing this exit, not before.
*(Status 2026-08-09: Staleness-threshold recalibration remains deferred to the escalating refresh work.)*
