# Account routing contract

`worker-pick` answers one question per vendor — **which account** — from the pool toggles
and measured usage. No scoring. Every selection must be verifiable by one glance at the
menu: the chosen account is the pin, or else the lowest spending-bucket percentage in the
pool. This page is the policy; code bends to it, and anything the old implementation did
beyond it is deleted, not preserved.

## The four rules

1. **Candidates.** An account is a candidate iff its "In worker pool" toggle is enabled,
   its auth is alive, and its spending bucket has a measured percentage. The session
   account (`CLAUDE_LIMITS_ACCOUNT`) is the reserve: it joins the candidates only when no
   other candidate is selectable, still requires its own pool toggle, and the answer is
   marked `SESSION RESERVE`. The reserve applies to every consumer identically — worker
   dispatch, review-bench, anything else that asks; the toggle is the only gate.
2. **Selection.** The vendor pin wins when usable — a pin overrides the pool toggle and
   the reserve status, and lapses loudly with a reason when it cannot serve. Otherwise:
   the candidate with the lowest effective percentage in the **bucket the task will
   spend** — weekly for ordinary work (every vendor), the fable bucket only for an
   explicitly-requested fable task. Ties break by lower five-hour percentage, then
   non-`main` before `main`, then name.
   An account with no measured spending bucket is not a candidate (rule 1), so a vendor
   with no usage numbers answers exit 3 / no quota data. Fable exhaustion alone never
   disqualifies an account from ordinary work.
3. **Wall.** An account is skipped only when walled: effective 100% in the spending
   bucket or in the five-hour bucket, or dead auth. Below 100% nothing blocks — no
   floors, no headroom, no soft reserves beyond rule 1. A caller that watches an account
   wall mid-task re-queries with `--exclude`; when every candidate is walled the answer
   is exit 3 / `ALL WALLED` and the orchestrator asks the owner.
   A **pinned** account that walls is the one case where a query writes: the pin is removed
   from `~/.claude/worker-model` outright, because it is pinned to be spent and the owner does
   not want it back when the window rolls over. Only the usage wall clears it — dead auth is a
   login to fix — and only on data this run calls fresh; every other lapse leaves the pin standing.

4. **Reachability.** The pool toggle is not advice to the selector, it is the wall: an account
   outside the pool cannot carry a headless run however it is named: the three vendor CLIs
   refuse it (`claudeb … -p`, `codexb <name> exec`, `geminib … --print`), and so do `worker-run`
   and `codex-image`, which launch a vendor binary directly. review-bench raters take their
   accounts from `worker-pick` and are bound by rule 1; `claudeb warm` is exempt because token
   warming keeps an account loggable-in, it does not spend work quota. The pin is the only
   override, because
   naming an account there is the deliberate "use this one anyway". Interactive launches are
   the user, not a worker, and are never gated; an empty pool is therefore a legitimate state
   meaning "no worker may run", answered as `every <vendor> account is out of the worker pool`
   and reported by `worker-run` as `OUTCOME: <VENDOR>_UNAVAILABLE`, never as a usage limit.

## Deleted with this contract (not configurable, not dormant)

score / runway / pre-reset cap math, `FLOOR_PCT` / `HEADROOM_PCT`, the night-window
relaxation (`awake_until_reset` / `relax`), the R1/R2/R3/R8/R9 rungs and their weights,
the fable-gap exclusion, the session score, the least-burnt fallback, account tiers as a
selection input (the `$100`/`$200` label stays display-only), codex reset-credits as a
selection input (`↻n` stays display-only), and the model/effort recommendation ladder.
Model and effort come only from `~/.claude/worker-model` defaults plus per-brief
overrides — quota state never silently degrades work quality. The multi-paragraph
`POLICY:` prose block is no longer printed, and `share/worker-policy.md` loses every
routing-math paragraph the rules above replace.

## Interface kept stable

- Human output keeps the `NEXT:` / per-vendor lines / `DATA:` / `SESSION:` shapes, and
  the statusline cache line keeps its format (model·effort sourced from worker-model
  only).
- `worker-pick --account <vendor> [--exclude a,b]` keeps its contract: bare account name
  on stdout, exit 3 when no candidate remains.
- Advisory warnings (≥85%) live in hooks and never block below a wall.
- Data hygiene is unchanged: `effective_pct` / stale / expired semantics per
  `docs/shared-invariants.md` row y; a bucket past its reset reads as 0%.
- review-bench affordability derives from worker-pick's answer under these same rules —
  it keeps no thresholds of its own.
