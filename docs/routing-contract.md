# Account routing contract

`worker-pick` answers one question per vendor — **which account** — from the pool toggles
and measured usage. No scoring. Every selection must be verifiable by one glance at the
menu: the chosen account is the pin, or else the lowest spending-bucket percentage in the
pool that the five-hour deferral has not pushed down the list. This page is the policy;
code bends to it, and anything the old implementation did beyond it is deleted, not
preserved.

## The four rules

1. **Candidates.** An account is a candidate iff its "In worker pool" toggle is enabled,
   its auth is alive, and its spending bucket has a measured percentage. The session
   account (`CLAUDE_LIMITS_ACCOUNT`) is the reserve: it joins the candidates only when no
   other candidate is selectable, still requires its own pool toggle, and the answer is
   marked `SESSION RESERVE`. The reserve applies to every consumer identically — worker
   dispatch, review-bench, anything else that asks; the toggle is the only gate. The one
   role it does not reach is `chat` (see Roles).
2. **Selection.** The vendor pin wins when usable — a pin overrides the pool toggle and
   the reserve status, and lapses loudly with a reason when it cannot serve. Otherwise:
   the candidate with the lowest effective percentage in the **bucket the task will
   spend** — weekly for ordinary work (every vendor), the fable bucket only for an
   explicitly-requested fable task. Ties break by lower five-hour percentage, then
   non-`main` before `main`, then name.
   Above all of that sits the **five-hour deferral**: a candidate whose five-hour effective
   percentage is 80% or more ranks behind every candidate below 80%, whatever the spending
   buckets say. Within each of those two groups the order is exactly the one above, and an
   unmeasured five-hour window is not a reading of 80% — it never defers.
   An account with no measured spending bucket is not a candidate (rule 1), so a vendor
   with no usage numbers answers exit 3 / no quota data. Fable exhaustion alone never
   disqualifies an account from ordinary work.
3. **Wall.** An account is skipped only when walled: effective 100% in the spending
   bucket or in the five-hour bucket, or dead auth. Below 100% nothing blocks — no
   floors, no headroom, no soft reserves beyond rule 1, with **one** deliberate exception:
   the five-hour deferral of rule 2. An account picked on weekly headroom that walls after
   the first task is the wrong no-brainer answer. It stays soft — a deferred account is still
   the answer once nothing below the threshold remains — it is one named constant
   (`FIVE_HOUR_DEFER_PCT`, 80) and never a config key, and it is visible where the answer is
   read: a ` 5h!` tag in the vendor row beside `WALLED`/`PINNED`. It is the only soft rule
   there is; no second one may be added beside it. A caller that watches an account
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

## Sanctioned launchers

Reachability is only half of visibility. A vendor launched as a bare headless CLI call from a
chat's Bash — `claude -p`, `claudeb … -p`, `codex exec`, `codexb … exec`, `gemini -p`,
`geminib … --print`, `agy … --print`, `opencode run` — leaves no `worker-run` record, no statusline
tag, no journal ownership, no pool refusal, no limit signature and no stall watch, so nothing
downstream can tell a worker ran at all. Every headless run therefore goes through `worker-run` or
a tool that owns its own launches, and this is the whole list: `worker-run`, `review-bench`,
`llm-limits`, `claudeb revive`, `claudeb warm`, `claude-session-driver`, `codex-image`,
`gemini-image`, `opencode-go`. `bin/worker-launch-gate.sh` is the mechanical half — a PreToolUse
Bash gate denying a command that spells a bare launch unless the same command names one of those
launchers. It reads the whole command string, and a vendor name counts only where a
shell would run it: quoted text collapses into one operand word before the quotes come off, so
`'claude' -p` and `X="a b" claude -p` are denied while a launch quoted inside an echo or a grep is
the operand it is. It fails open on its own errors. Interactive launches — no `-p` / `--print` /
`--prompt`, no `exec`, no `run` — are the user, not a worker, and are never gated.

## Roles

A vendor serves three roles — `workers` (implementation), `reviewers` (review-bench raters) and
`chat` (where Egor's own session should move next) — and `<vendor>_workers` /
`<vendor>_reviewers` in `~/.claude/worker-model` are per-role walls layered over the pool: the
literal value `off` closes that vendor for that role, an absent key or any other value leaves it
open. There is no `<vendor>_chat` key and none is to be invented — the pool toggle is the whole
gate for a chat. The default role is `workers`, so every existing caller keeps its meaning; a
rater asks with `worker-pick --account <vendor> --role reviewers`, the chat picker with
`--role chat`.

The ladder is **pin > roles > pool**. A closed role walls everything the pool would choose:
without a usable pin the query answers exit 3 / `<vendor> is switched off for <role>`, and the
pool's own candidate is never handed over instead. The pin overrides it the same way it overrides
pool exclusion — a usable pin answers the workers query and the workers table even while
`<vendor>_workers=off`, and rule 3 still ends it at its wall, unchanged.

The pin is **workers-only**. A reviewers or chat query never sees it: it is neither an override
nor a forced choice there, and the pinned account stands in those answers as an ordinary
candidate ranked by pool and spending like any other. `<vendor>_reviewers=off` is therefore final
— no pin opens it.

`chat` is the same candidates under the same walls, minus the two things that are about workers.
An account Egor took out of the pool is not one to move a chat onto either. The pin it never sees
(above), and there is no reserve — `CLAUDE_LIMITS_ACCOUNT` is where the chat already is, so under
this role it ranks as an ordinary candidate rather than rule 1's last resort, and no answer is
marked `SESSION RESERVE`. A chat query decides nothing about workers and therefore never clears a
walled pin. It answers for every vendor under those same rules, `claudeb` being the only one with
a caller today, and its machine face is the others': one bare account name on stdout, exit 3 when
none is selectable.

In the human table — the workers view — a workers-off vendor with no pin serving reads
`<vendor> — off for workers` in `NEXT:`, trails the ordering and is never auto-selected, while its
account listing stays intact: a closed role is not a limit, and the menu still shows what those
accounts hold. `worker-run` refuses a closed vendor for explicit accounts and pin fallbacks alike,
the vendor pin excepted, and reports it the way it reports an empty pool —
`OUTCOME: <VENDOR>_UNAVAILABLE`, never as a usage limit.

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
