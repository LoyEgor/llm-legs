# Account routing contract

`worker-pick` answers one question per vendor — **which account** — from the pool toggles
and measured usage. One metric decides it: the **weekly budget per remaining day**. The
chosen account is the pin, or else the largest daily budget in the pool that neither the
five-hour deferral nor a fresh claim has pushed down the list. This page is the policy;
code bends to it, and anything the old implementation did beyond it is deleted, not
preserved.

## The metric

```
budget = limits_daily_budget(effective_pct; limits_days_remaining(resets_at; now))
```

Both halves are defined once, in `share/limits-view.sh`, and that file is their only home —
no surface re-derives either. What is left of the spending window divided by the days left
in it: `(100 - pct) / days`, with `pct` clamped into `[0, 100]` and `days` floored at `0.25`
so a window about to roll over cannot divide to infinity. A reset the limits view refuses to
print — a placeholder epoch, or one over a day past — answers `null` days, which the budget
reads as a neutral 7-day window rather than the floor, so a garbage timestamp cannot rank an
account first.

An account is measured on its **weekly** bucket and the reset that bucket carries. A vendor
that reports no weekly percentage at all is measured on its five-hour reading over the
neutral window instead — its five-hour reset says nothing about a week. A `--fable` query
reads the same formula against the fable bucket and the fable reset. An account whose budget
is `null` — no numeric percentage in either bucket — is not a candidate.

Two accounts at the same percentage are not equal: the one whose week resets sooner may
spend faster, and the budget says so. That is the whole point of the metric, and it is the
only pace math anywhere — one formula in one shared home, never a per-surface variant.

## The four rules

1. **Candidates.** An account is a candidate iff its "In pool" toggle is enabled,
   its auth is alive, and its budget is a number. There is **no session reserve**: the
   session account (`CLAUDE_LIMITS_ACCOUNT`) is an ordinary candidate in every role,
   ranked by its budget like any other, and no answer is marked `SESSION RESERVE`. The
   pool toggle is the only consent gate, and it applies to every consumer identically —
   worker dispatch, review-bench, the chat picker, anything else that asks.
2. **Selection.** The vendor pin tier wins when usable — usable here being auth alive, a numeric
   budget and no run-observed wall, and nothing else: a pin overrides the pool toggle (rule 4), so pool
   membership is no part of that test. It is the top override of worker routing, so every usable
   pinned account leads the ranked NEXT rows (and the `--account` answer for that vendor is that
   vendor's rank-1 tier member) whatever budget an unpinned account holds; pins among themselves
   share the same vector, and every unpinned account ranks after the whole tier. Limits at
   100% do not skip a pin. A run-observed wall or dead auth lapses that one name loudly for this query
   and leaves the rest of the ranking.
   Otherwise the candidates are ranked on one key vector, ascending, identical for all four
   vendors, and the NEXT table applies it across vendors:

   `[five-hour deferral, fresh claim, late auth, −budget, name]`

   The **five-hour deferral** comes first: a candidate whose five-hour effective percentage
   is 80% or more ranks behind every candidate below 80%, whatever the budgets say, because
   an account that walls after the first task is the wrong no-brainer answer. An unmeasured
   five-hour window is not a reading of 80% — it never defers.
   A **fresh claim** comes next: an account a caller took within the claim TTL is already
   carrying a run this data has not seen, so it ranks behind every unclaimed candidate (see
   Claims).
   **Late auth** is the grok-only softening below. Then the largest budget, then the name.
   An account with no budget is not a candidate (rule 1), so a vendor with no usage numbers
   answers exit 3 / no quota data. Fable exhaustion alone never disqualifies an account from
   ordinary work.
   Two vendor-shaped notes, and no third is to be invented: **grok** measures a weekly bucket and
   nothing else, so the deferral can never fire for it; and a grok account whose access token has
   `expired` is one the CLI refreshes silently, so it stays a candidate and merely ranks behind
   every signed-in one, while `needs_login` is dead auth like anywhere else.
   `main` is no longer a ranking key on any vendor — the budget decides, and the **main-account
   shield** (below) is what keeps a base account from being spent by workers.
3. **Wall.** An account is skipped for exactly two reasons, and they are never one word.
   **Walled** is a USAGE verdict and nothing else: effective 100% in the spending bucket or in
   the five-hour bucket. **Dead auth** keeps an account out of every answer just as firmly, but
   it is a login for the owner to fix rather than a window to wait out, so the rows say
   `login needed` where they say `WALLED` for the other — `WALLED` printed over an account whose
   quota nobody spent sends the reader hunting a limit that does not exist. Where the selector
   needs the single fact "cannot serve", it reads the union (`unavailable`), which is what pin
   acceptance is spelled against: the pin overrides the pool, never capability. Below 100% nothing blocks — no
   floors, no headroom, no reserves — with exactly **two** deliberate softenings, both of
   them rank keys and neither of them a skip: the five-hour deferral and the claim, both in
   rule 2. Each stays soft — a deferred or claimed account is still the answer once nothing
   above it remains. The deferral is one named constant (`FIVE_HOUR_DEFER_PCT`, 80) and never
   a config key, and it is visible where the answer is read: a ` 5h!` tag in the vendor row
   beside `WALLED`/`PINNED`. No third softening may be added beside them. A caller that watches an account
   wall mid-task re-queries with `--exclude`; when every candidate is walled the answer
   is exit 3 / `ALL WALLED` and the orchestrator asks the owner.
   A pin names an **account**, never a vendor, and is a tier: Egor may pin any number of
   accounts across vendors (`<vendor>_profile=<name>[,<name>...]`). Every pinned account ranks
   first (among themselves on the same vector as the pool), then everyone else. A pin is always
   tried first — stale usage at 100% does not skip it, because the owner knows more than stale
   data. The only skip is a run-observed wall record (`claude-worker-runs/walls/<vendor>-<account>`)
   whose reset has not passed and that no llm-limits reading newer than the record has shown open. A wall that was actually MET — the run launched on that pinned
   account and the vendor answered limit — writes that record and removes that one name from
   `~/.claude/worker-model`; `worker-pick` clears a still-present pin the same way once when it
   finds an unexpired record. Stale llm-limits data never skips or clears a pin. Dead auth still
   lapses it as a login to fix. `worker-run` continues a walled pin or `--account` on the next
   account of the ranking (the next pinned name if any, else the pool); only `--resume` stays,
   because the session lives there.

4. **Reachability.** The pool toggle is not advice to the selector, it is the wall: an account
   outside the pool cannot carry a headless run however it is named: the four vendor CLIs
   refuse it (`claudeb … -p`, `codexb <name> exec`, `geminib … --print`, `grokb … -p`), and so do
   `worker-run` and the `codex-image`/`gemini-image`/`grok-image` launchers, which launch a vendor
   binary directly. review-bench raters
   take their accounts from `worker-pick` and are bound by rule 1; `claudeb warm` is exempt
   because token warming keeps an account loggable-in, it does not spend work quota. The pin is
   the only override, because naming an account there is the deliberate "use this one anyway".
   Interactive launches are the user, not a worker, and are never gated; an empty pool is
   therefore a legitimate state meaning "no worker may run", answered as
   `every <vendor> account is out of the worker pool`
   and reported by `worker-run` as `OUTCOME: <VENDOR>_UNAVAILABLE`, never as a usage limit.

## Whose account is this chat?

Every surface that reads a usage row for the session it runs in asks one resolver,
`share/chat-account.sh`, and none re-derives it: `CLAUDEGPT_ACCOUNT` names a **codex** account (a
`claudegpt` chat is Claude Code on an OpenAI subscription — `docs/claudegpt.md`), else
`CLAUDE_LIMITS_ACCOUNT`, else the profile `CLAUDE_CONFIG_DIR` points at, and otherwise nothing:
the shared `~/.claude` names no account, and what stands in there is the caller's own business —
`main` for `worker-pick`, `notcom` for `claude-resume-timer`, an openly-labelled `.claudeb-state`
guess for `workflow-burn-gate.sh`. The answer is a vendor AND an account, because the same name
lives in both stores (`com` is a claudeb profile and a gateway login), and it decides which
`.vendors.<vendor>.accounts[]` row a surface reads: `bin/worker-pick` (the `*` own-row marker and
its prediction file), `bin/claude-resume-timer`, `bin/workflow-burn-gate.sh` and the
`resume-timer-nudge` hook.

`worker-pick`'s prediction file follows that answer: `worker-pick.line.<account>` for a Claude
chat, `worker-pick.line.codex@<account>` for a gateway one — `@` is the one character no account
name in either store admits, and the Claude form is the name `bin/claudeb` prunes when a profile is
removed. `bin/statusline.sh` builds the same two names from the same fact, so a gateway chat reads
the prediction it owns and nothing writes into a Claude account's file (shared-invariants row `c`).

## Claims

Usage data lags a run by minutes, so two callers asking in that window would both be handed the
same account and both spend it. A caller that is about to spend the answer asks with `--claim`:
the query records the account it printed, and every query for the next `WORKER_CLAIMS_TTL`
seconds (default `600`) ranks that account behind the unclaimed ones. It is a rank key, never a
wall — a claimed account is still the answer when nothing else is selectable.

`share/worker-claims.sh` is the whole mechanism and its only home: `worker_claims_record`,
`worker_claims_fresh` and `worker_claims_prune` over one empty marker file per claim, whose mtime
is the entire state. A claim nobody renews simply ages out; nothing releases it explicitly.

`--claim` is valid only with `--account`, and only a caller that is about to launch passes it.
`worker-run` and `gemini-research` are those callers. The image launchers (`codex-image`, `gemini-image`, `grok-image`) pick
without `--claim`, validate the profile they would launch, then call `worker_claims_record` themselves
so a missing account directory does not burn the TTL. The human table and the statusline prediction
**never** claim: they report a decision, they do not take one. A query that cannot read the claims
directory answers as if there were no claims rather than refusing to route.

## The main-account shield

Ranking no longer holds a base account back — `main` is not a rank key. The shield that replaces
it lives on the pool side, not here: `share/worker-pool.sh` plus `llm-limits.sh` remove a main
account from the worker pool once its budget falls below `WORKER_POOL_SHIELD_PER_DAY` (3 %/day),
recording that removal with a marker in the pool directory. Enabling the account by hand overrides
the shield until the week rolls over. To `worker-pick` the result is an ordinary pool exclusion,
with no rule of its own.

## Sanctioned launchers

Reachability is only half of visibility. A vendor launched as a bare headless CLI call from a
chat's Bash — `claude -p`, `claudeb … -p`, `codex exec`, `codexb … exec`, `gemini -p`,
`geminib … --print`, `agy … --print`, `opencode run`, `grok … -p`, `grokb … --prompt-file`,
`claudegpt p <acct> -p` (Claude Code print run on a Codex account — the interactive
`claudegpt p <acct>` is the human, like `claudeb profile x`) —
leaves no `worker-run` record, no statusline tag, no journal ownership, no pool refusal, no limit
signature and no stall watch, so nothing downstream can tell a worker ran at all. The per-account
wrapper is denied beside the bare binary, never instead of it: isolating a profile is not
recording a run. Every headless run therefore goes through `worker-run` or a tool that owns its
own launches, and this is the whole list: `worker-run`, `review-bench`,
`llm-limits`, `claudeb revive`, `claudeb warm`, `claude-session-driver`, `opencode-go`,
`gemini-research`, plus the
OWNED pair — `worker-run start|wait`, which only a relay agent may spell, and `codex-image` /
`gemini-image` / `grok-image`, which only the `image-gen` agent may: a run or an image started from
the main chat's Bash belongs to a turn nothing renders. `bin/worker-launch-gate.sh` is the
mechanical half — a PreToolUse Bash gate denying a command that spells a bare launch unless the
same command names one of those launchers, and denying an owned one outside the agent type that
owns it. It reads the whole command string, and a vendor name counts only where a
shell would run it: quoted text collapses into one operand word before the quotes come off, so
`'claude' -p` and `X="a b" claude -p` are denied while a launch quoted inside an echo or a grep is
the operand it is. It fails open on its own errors. Interactive launches — no `-p` / `--print` /
`--prompt`, no `exec`, no `run` — are the user, not a worker, and are never gated.

The other half of the same rule is the Agent tool, and the gate there is
`bin/worker-limit-gate.sh`. Workers are unified: every run that edits, reviews, verifies or scans
is a relay worker through `worker-run`, so on an **orchestrator** session a NATIVE agent type —
`general-purpose`, `claude`, `fork`, anything custom — is refused outright, because it runs on the
session's own model, which is the one quota the whole relay design exists to spare. Four
`general-purpose` read-only checks at 35–45k tokens each on a live Fable chat is the case this
closes. An orchestrator session is Fable **or** a `claudegpt` gateway chat (`anthropic.ccr.sol` /
`anthropic.ccr.astra`) — Claude Code on an OpenAI subscription, spending the one session quota the
relay design exists to spare, so it is the same rule and not a second one. The shape of that model
list lives in `orchestrator_model` in the gate and nowhere else (shared-invariants row `bt`). The allowlist is `Plan`, `claude-code-guide`, `gemini-research`
(shared-invariants row `bt`): `claude-code-guide` is a narrow documentation lookup exception and `Plan` is the context-dependent planning exception. Research is rewritten into `gemini-research` with its prompt prefixed by one `Repositories:` line; explicit tool models and prose escape phrases cannot bypass this routing. The compatibility entrypoint submits a tracked read-only Gemini worker-run. No broad native read-only exception exists. Relay types and `image-gen` are untouched, off Fable nothing is judged at all,
and a session whose model cannot be read fails open. The refusal carries no retry: a stamped
one-shot deny is a rule a model walks through by calling twice.

## Roles

A vendor serves five roles — `workers` (implementation), `reviewers` (review-bench raters),
`chat` (where Egor's own session should move next), `research` (read-only Gemini research) and
`image` (subscription image/video generation) — and `<vendor>_workers` /
`<vendor>_reviewers` in `~/.claude/worker-model` are per-role walls layered over the pool: the
literal value `off` closes that vendor for that role, an absent key or any other value leaves it
open. There is no `<vendor>_chat`, `<vendor>_research` or `<vendor>_image` key and none is to be invented — the pool
toggle is the whole gate for `chat` and `research`. The default role is `workers`, so every existing caller keeps its meaning; a
rater asks with `worker-pick --account <vendor> --role reviewers`, the chat picker with
`--role chat`, the research launcher with `--role research`, and the image scripts / fan-out with
`--role image`.

`gemini-research` submits through `worker-run` and maps a picker refusal containing `WALLED` to exit 3 / `GEMINI_USAGE_LIMIT`;
paused, switched-off, empty-pool and missing-data refusals are availability failures at exit 4.
After a Gemini run hits a quota wall, automatic selection re-queries with every tried account in
`--exclude` and claims the next answer. Once that retry query has no account left, the observed
runtime walls make the launch a usage-limit exit even though exclusion can make the picker's line
say the pool is empty. An explicit `--account` never rotates.

The ladder is **pin > roles > pool**. A closed role walls everything the pool would choose:
without a usable pin the query answers exit 3 / `<vendor> is switched off for <role>`, and the
pool's own candidate is never handed over instead. The pin overrides it the same way it overrides
pool exclusion — a usable pin answers the workers query and the workers table even while
`<vendor>_workers=off`, and rule 3 still ends it at its wall, unchanged.

The pin is **workers-only**. A reviewers, chat, research or image query never sees it: it is
neither an override nor a forced choice there, and the pinned account stands in those answers as
an ordinary candidate ranked by pool and spending like any other. `<vendor>_reviewers=off` is
therefore final — no pin opens it.

`image` ignores `<vendor>_workers=off` and the pin alike: a picture is not code work, so an image
query is pool membership + login + not walled, ordered by free budget, and a fan-out that asks
every vendor still reaches a vendor whose code workers are paused. Walls, the five-hour deferral,
pool exclusion and missing login still apply, unchanged.

`chat` is the same candidates under the same walls, minus the one thing that is about workers.
An account Egor took out of the pool is not one to move a chat onto either. The pin it never sees
(above); the session account ranks as an ordinary candidate here as it does everywhere else,
there being no reserve to be an exception to. A chat query decides nothing about workers and
therefore never clears a walled pin. It answers for every vendor under those same rules, `claudeb` being the only one with
a caller today, and its machine face is the others': one bare account name on stdout, exit 3 when
none is selectable.

In the human table — the workers view — a workers-off vendor with no pin serving holds no rank at
all and states the switch in place of its rows: `<vendor>: off for workers`. A closed role is a
setting, not a reading, and what those accounts hold is for the vendor's own menu section to show,
not for the router. `worker-run` refuses a closed vendor for explicit accounts and pin fallbacks alike,
the vendor pin excepted, and reports it the way it reports an empty pool —
`OUTCOME: <VENDOR>_UNAVAILABLE`, never as a usage limit.

## Pause

`<vendor>_paused=on` in the same file is the deliberate, months-long **parking** of a vendor, and
it is not a role. A role `off` closes a vendor the surfaces still know about: it walls it, names it
`off for <role>`, and leaves its account rows intact. A pause removes it. Vendors are
`claudeb|codex|gemini|grok|opencode` (store keys `claude|codex|gemini|grok|opencode` — claudeb is
`claude` in the store), the literal `on` is the only veto — an absent key and any other value are
both "running" — and a duplicated key resolves first-line-wins, exactly as the role keys do. The
roles under a pause are untouched in both directions: deleting the line restores the vendor whole,
and the switch writes nothing anywhere else.

The mechanism is the one a leg this machine never installed already produces — **absence from the
store**, the same absence "Interface kept stable" states for `vendors.grok`. `llm-limits.sh` runs
no collector for a parked vendor (zero network: no OAuth or usage call, no `grokb`/`codex`/`agy`
helper, no `opencode-go` probe), reconciles none of its worker-pool shields, and deletes its entry
after the merge, so a reading the previous snapshot carried cannot survive the pause. Every render
path then simply has nothing to print — `--table`, `--plain`, the menu, the statusline, the
worker-pick cache line — and `vendors.claude` is as deletable as any other. `worker-pick` adds three answers of its own on top of that absence: a pin on a parked vendor is ignored rather than honoured (pause stands above the pin, the inverse of the roles ladder), a global `worker=<parked vendor>` reads as `auto` with no warning, and only when EVERY vendor is parked does it say why nothing routes — `NEXT: nothing routable — every vendor is paused`, exit 0, an empty cache line — since a bare `NEXT:` names no reason. `worker-pick --account <parked vendor>` refuses at exit 3 with the `is paused` line below, the shape `worker-run` and review-bench parse. `bin/llm-refresh` gives
a parked vendor no cadence entry, no tick and no journal line, so no account of it is ever revived,
probed or token-touched.

What is NAMED is refused rather than silently skipped, because a silent skip reports a parked
vendor's old numbers as a fresh reading: `llm-limits.sh --refresh-account <vendor>[/<account>]`
answers one stderr line — `<vendor> is paused (<vendor>_paused=on in ~/.claude/worker-model)`, the
vendor spelled as the switch spells it — and exits non-zero. review-bench refuses a named cell of a
parked vendor in those same words.

The one visible trace is a single menubar row, `<Label> — paused`, whose only item is **Resume**. The menu reads the pause off `~/.claude/worker-model` and not off the store — the store has no entry to read — so the row appears for every parked vendor alike, OpenCode included, whether or not a reading ever existed.
Resume deletes the line and then refreshes that vendor, because the store holds nothing for a
vendor that was parked and the section would otherwise stay empty until the next poll. Both
directions are Egor's hand only: `share/worker-model.sh` `worker_model_set_paused` refuses a
session (`CLAUDECODE`) the way the role writer does, so the menubar is the only way in.

## Models

`worker-pick` answers which ACCOUNT. `share/worker-model.sh` (`worker_model_table`) is the
source for allowed models, default efforts, brief efforts and efforts requiring Egor's word
(`docs/shared-invariants.md` row `bq`; policy table in `share/worker-policy.md`). Default models
are claudeb `opus`, codex `gpt-6-astra`, gemini `flash38`, grok `auto` (`grok-4.6` also allowed).
Opus defaults to `high`; brief efforts are `high`, `xhigh`, and word efforts are `low`, `medium`, `max`.
claudeb `fable` and codex `gpt-5.6-sol` require Egor's explicit ask in this chat, as do word efforts.

The model check covers `MODEL:` forwarded as `--model`, vendor `*_model=` values consumed by
`worker-run`, and table defaults. Codex's default comes from the table, including `--model default`,
not `~/.codex/config.toml`.
`worker-run` prints `OUTCOME: MODEL_REFUSED` and exits `4` BEFORE the account is resolved:
nothing is picked, no run directory exists and no quota is spent. Stderr names the offered
model and the vendor's allowed list. Correct the model; no account is walled or rerouted.

`worker-run` prints `OUTCOME: EFFORT_REFUSED` and exits `4` BEFORE the account is resolved
when effort is outside the resolved model's union of brief and word efforts. Nothing is picked,
no run directory exists and no quota is spent. Stderr names the offered effort and allowed union.
Correct the effort; no account is walled or rerouted. Neither Codex model permits `max`.
Effort precedence is `--effort` (brief `EFFORT:`) > `<vendor>_effort` in `~/.claude/worker-model`
> `worker_model_default_effort` for the resolved model. A Codex resume retains its session effort
unless the brief explicitly overrides it.

`/worker` refuses to store a model outside the table or an effort outside the model's union;
`worker-pin-gate.sh` guards model writes. The union is mechanical validation; requiring Egor's
word for word efforts and word-only models is orchestrator policy.

## Deleted with this contract (not configurable, not dormant)

`FLOOR_PCT` / `HEADROOM_PCT`, the night-window relaxation (`awake_until_reset` / `relax`),
the R1/R2/R3/R8/R9 rungs and their weights, the fable-gap exclusion, the session score, the
least-burnt fallback, the session reserve, `main` as a ranking key, account tiers as a
selection input (the `$100`/`$200` label is gone from this output and stays in the menu), codex
reset-credits as a selection input (`↻n` is gone from it too, on every vendor), and the model/effort
recommendation ladder.

The earlier version of this page also forbade score and runway math outright. **That clause is
superseded by The metric above**: pace math is no longer banned, it is centralized. The
difference is the point — one formula, `limits_daily_budget` over `limits_days_remaining`, living
in `share/limits-view.sh` and read by every surface, rather than each surface inventing its own
rungs and weights. The old prohibition existed because the math was per-surface and unverifiable;
what replaces it is verifiable from the menu, since the two inputs are the percentage and the
reset the menu already shows.
Effort comes only from `~/.claude/worker-model` defaults plus per-brief overrides and the model
comes from the fixed list above — quota state never silently degrades work quality. The multi-paragraph
`POLICY:` prose block is no longer printed, and `share/worker-policy.md` loses every
routing-math paragraph the rules above replace.

## Interface kept stable

- Human output is one table, the same one for every vendor: a `NEXT` header, the top five usable
  ACCOUNTS across vendors — several per vendor allowed, since the block answers where the next runs
  go rather than nominating one account per leg — as ranked rows
  `<rank> <budget> <wk> <5h> <vendor>/<account> <model>·<eff> [flags]`. The ordering rule is:
  pin tier first, then `[five-hour deferral, fresh claim, late auth, −budget, name]`; apply it
  across vendors and cap the result at five rows. `ACCOUNT: <name>` names row 1, then one section
  per vendor carrying that vendor's rows with the exact reset (`↺ Mon 09:30`), then `DATA:`. A run
  that ranked nothing prints one `NEXT: <reason>` line instead of the table. The session account
  is marked `*` with a footnote under its vendor — there is no `SESSION:` line, and `--fable` is
  the query that asks for the fable pick. The statusline cache line keeps its format
  (model·effort sourced from worker-model only). Grok appends a fourth cache field tagged `gr` after `cx`/`cb`/`gx`, and a store
  carrying no `vendors.grok` at all produces no grok segment, line or field: a vendor this
  machine has not installed is absent from the answer, never walled and never a failed
  lookup.
- `worker-pick --account <vendor> [--exclude a,b] [--claim]` keeps its contract: bare account
  name on stdout, exit 3 when no candidate remains. In `auto`, the ranking leads with every
  pinned account, then applies the rest of rule 2's vector to all rows — pins among themselves the
  same way; a vendor with nothing selectable, or switched off for workers, holds no row at all. A
  MODE (`worker=gemini`, `worker=grok`) is the one thing above the metric: the vendor it names
  keeps row 1 with the account it selected, and every other account, its own siblings included,
  falls back into the budget order below.
- Advisory warnings (≥85%) live in hooks and never block below a wall.
- Data hygiene is unchanged: `effective_pct` / stale / expired semantics per
  `docs/shared-invariants.md` row y; a bucket past its reset reads as 0%.
- EVERY vendor's account rows print the one metric that ranked them, as the division it is:
  `<n>%/d ×<d>d` — the daily budget of rule 2 beside the remaining-days divisor it was paced over
  (the `0.25`-day floor and the neutral `7`-day window of `docs/shared-invariants.md` row `bl`
  included, so a row a reader cannot reconcile with the reset beside it does not exist). An
  unmeasured budget prints `-` and an unmeasured percentage `?`; a vendor with no five-hour window
  at all prints `–` in that column, which is a different statement from `?`. Models print their
  short alias (`opus`, `astra`, `f38`, `grok`; `auto` is a knob value and is never displayed) and
  efforts abbreviate to `low`/`med`/`high`/`xhigh`. The `*` session marker and `off` are unchanged.
- The `DATA:` line names rows, never the table. It reads `fresh (<n> min old)` when every account
  behind the answer is fresh, and otherwise `STALE — <vendor>/<account> <age>, …` listing exactly
  the rows whose newest measured bucket is older than `LIMITS_STALE_ROUTING` (row `a`, no local
  literal) — so a stale grok account can no longer brand a table of otherwise fresh claude rows.
  A store written long ago with no account reading behind it at all says so in those words, and a
  store with no timestamp reads `no timestamp`.
- Reset credits and the account tier label are absent from this output entirely. Neither enters
  the rank vector on any vendor, both are rendered by the menubar where the reset is spent (both
  vendors publish `reset_credits_expires_at` and both have a redeem RPC behind that click), and a
  number printed beside a row nobody ranks on reads as one that ranked it.
- review-bench affordability derives from worker-pick's answer under these same rules —
  it keeps no thresholds of its own.

Pool membership is read from the live vendor pool files on every pick; snapshot `.enabled` is the fallback only when the live pool cannot be read. Pool, role, pause and pin writes invalidate the statusline candidate cache, and successful menu toggles refresh Routing immediately.
