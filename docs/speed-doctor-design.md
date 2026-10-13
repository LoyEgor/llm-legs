# Speed doctor — design

The Speed block of the Harness doctor (`bin/speed-doctor`); ledger `share/harness-ledger.json`.

Goal (Egor): every minute of his day lost to waiting, in one unit, owner minutes per day (OM/d), ranked and driven down every night, not only when something regresses.

Quality rule (Egor): the speed of the current setup at the same intelligence. No lever touches the model, effort, reasoning, thinking or a role's vendor (`validate_levers` refuses such a row at load); each declares `quality: equivalent|risk`. Only `equivalent` (provably identical output) enters selection; `risk` shows only as needs-Egor with `quality_evidence` {compared, data, result}.

## 1. Owner-minute model

**Blocked minute**: something he launched is running, he is not acting elsewhere, and he takes up its result within R = 5 min. Three terms:

- **A, attended turn.** An owner-chat turn opened by his prompt or by a result notification or peer message (a *continuation*), whose end he answers in the same chat within R.
  - Start = max(opening prompt, previous turn end): a queued prompt starts at dequeue; `durationMs` is never used, so its stale-start bug cannot pull idle time in.
  - Clipped to the part after his last prompt in any other owner chat during the turn.
  - Dropped when an `away_summary` record lies between its end and his reaction.
  - Owner-question tools subtracted; machine-opened chats (`share/chat-open.sh` callers) out.
  - No cap in any sum; the 30-min cap applies to percentiles only, long turns get a count row.
  - Clipped at boots and sleeps (`kern.boottime`, `kern.sleeptime`, `kern.waketime`). A telemetry gap is *unknown coverage*, never sleep, and never drops a whole interval.
  - Chat start, CLI launch → first prompt ready, counts for chats he opens (C11).
- **B, blocked delegation.** Any background job a chat launched (Agent, `run_in_background` Bash, worker-run, review-bench, media): from max(launch, his last prompt in any owner chat) to the notification, when he answers the follow-up turn within R of its end. That follow-up turn is A.
- **C, direct UI waits.** Menu click → display; Hammerspoon main-thread lag over 50 ms (`hs/<day>.tsv`, rows `hs-lag`).

**OM/d** = |A ∪ B ∪ C| per local day. Parallel blocked chats share each minute equally, for attribution only.

**Presence (C8)**: a per-minute HID-idle and frontmost-bundle log, no window titles. A candidate minute counts only if HID idle < 2 min or it falls in the last R minutes before his reaction, for A and B alike. Only a row the log covers is judged this way; a row or minute it did not log is unknown, never away, and keeps the R proxy.

**Bound.** His reaction in *any* owner chat confirming presence gives a bound, shown, never summed.

**Yield and proofs never use the headline's R-selection**: a component's exposure is frozen from its before window (attended share × all owner turns or calls of that class), so shortening a turn below his reaction cannot fake a saving.

**Exclusive partition.** Every blocked minute is split once, in precedence: hook batch > queue (suite slot, media lock, worker slot; charged to the slot holder's job: night, worker or chat) > suite > media local phase > other tool > compaction > generation > residual. B splits along its critical path: pre-CLI, per-attempt run, reroute loss, suites inside, notification, continuation turn. Media is a component of A and B with its own drill. Area lines are "of which" and sum to the headline.

**Load.** A local span (tool body, hook batch, stop hook, chat start, residual, media local phase) counts its unloaded service time (its class's p50 in the lowest load band) toward its own component; the excess goes to the contention pool **P**. So a hook fix and a background consumer never claim the same minute.

**P split** by **self-reported CPU-seconds** (C7: hook, statusline, suite, collector and worker-pick rows carry `times`/rusage), with fork origin from census bursts; the remainder is shown as `unattributed`, never spread.
- Memory pressure is its own mechanism: blocked local minutes in memlogd incident mode go to `memory`, split by RSS growth per process tree.
- Shares are *allocated estimates*; a removal saving counts only after an intervention proves it (§3).
- Load from Speed's or the night's own runs is tagged `self-load`: shown, never a regression.

**Savings are counterfactual**: shorten the component's spans, recompute the union and the dependency's critical path, read the drop. Δ unit × exposure is only a first ranking estimate. A non-critical parallel suite, worker or media branch saves 0.

**Zero and weather.**
- Unattended work counts 0. The night counts only through B, P and queue holds overlapping blocked minutes; its wall time is a secondary metric, in hours.
- Weather is tagged per span or attempt, never per day: owner-request decode rate and TTFR outside their band (the LLM doctor's same-hour headless TTFT as control); attempts with `walled_accounts`, `*_USAGE_LIMIT` or a `wall` kill; long silent requests. Media rc 3 is a quota wall: 0 minutes, not weather. Local hook, test, menu and collector samples are never dropped for weather.

## 2. Areas, metrics, collectors


**Two forms per metric**: a **unit metric** for regressions and proofs, its **OM/d** for ranking. Normalisation: chat totals per 100 prompts; background per open session-hour; tests per (suite set, sha); delegation per run class; nights per completed job.

**Bands**, per class, never a cross product:
- load = loadavg ÷ ncpu (< 1, 1–2, 2–4, > 4), overlap-weighted over the span from memlogd's 15-s ticks; unknown when no tick within 60 s. CPU busy saturates;
- hooks: load × transcript size (< 1, 1–10, > 10 MB);
- generation, TTFR and turn metrics: not banded, judged on pooled 7-day windows, never ratcheted.

| area · metric | unit / OM | source | traps |
|---|---|---|---|
| chat · turns | A split by the partition; TTFR from dequeue; thinking s; compaction s; context cost Σ 0.7 s/100 k × (context − 50 k); cache misses × s; residual | C1 | usage repeats per block line (dedupe by `requestId`); `compactMetadata` is a JSON object (string fallback); TTFR at xhigh inflated by completion-time logging |
| chat · call waits, slow periods | moved `wait`, `local_slow` | Harness `c` events | as Harness |
| chat · start | launch → ready, by SessionStart source (startup/resume/compact), cold/warm | C11 | compact starts belong to compaction |
| delegation · blocked | B on the critical path; `result-turn` | C1 `d` rows + C3 | `started_at` is restamped on purpose (slot wait, reroute): queue = `pid_started_at → cli_starts[0]`; owner-decision pauses and `blocked-on-egor` stop the clock; deadline kills are a waste metric followed to a usable result |
| delegation · overhead | pre-CLI, reroute loss (tail sum), notification lag, stragglers, adjudication | C3, `runs.jsonl`, review-log | judged only on task-size-free components, ≥ 50 runs per class, ≥ 30 rounds per tier; wall per vendor × effort × role × warm/cold RESUME is display-only |
| delegation · media | queue (lock acquisition incl. failures), prep, launch, render, download, recovery, per (tool, route, requested model, action, size) | C9 | render and failures stay judged by the LLM doctor (Speed converts minutes and links its problem id); rates per active day; only legs inside A ∪ B are judged, ≥ 30 attended legs per cohort, a concurrency band |
| hooks · per call | batch floor + timeout of every cut hook; per-hook counterfactual floor without h; hook count/CPU term | C2 joined to calls inside A ∪ B (chat, subagent, worker on B's path) | slowest hook, never a sum; grows with transcript size; SubagentStop and SessionStart included; non-bypass sessions keep their floors (only permission waits drop); statusline-only gate keys belong to background |
| hooks · turn end | stop.d part ms | C2 (`stop.d/<name>`) | |
| tests · suites | per suite CPU-s (unit); wall per load band (OM); queue; reruns after `ok:false`, load flake vs real fail | C5 | complete coverage only (killed runs are not fast runs); ident map across shards and renames; cold or first-after-edit runs apart; full-run wall = max(longest suite, Σ suite-s ÷ j) + serial tail: rank only the binding term |
| tests · moved | `test_*`, `suites_at_once` (standalone runs counted) | C5 | |
| machine · P | P per attended local minute; probe slowdown; consumer shares; memory; swap MB + swap-in rate (never a share: macOS swap is dynamic); reboots charged (restart + cold cache) | C6, C7 | process-min ≠ CPU-min |
| machine · git | loose objects per repo, git-op p50 inside hooks | Harness Growth | |
| background | statusline renders and CPU per session-hour, idle share; `worker-pick --menu` and merge-kick runs/CPU; menu click wait, `doctors:bg` builds, hs lag; CPU per launchd label; doctor collectors wall/CPU × runs | statusline fold, C7, C10 | idle = no transcript line, no running tool or background task, no work-probe child; a menu with no lines reads "not measured" |
| night | wall, first landing, slot queue, debt round, branch review, adjudication, suite passes, landing wait | C4 | |

**Clocks.** Durations come from monotonic or elapsed counters where the writer has them; wall jumps and `secs < 0` are flagged, never summed; a span crossing a boot or sleep boundary loses only that slice.

**Collectors**, one append each, with env overrides for fixtures; the labels the code and tests use, each journal's
schema in its shared-invariants row: C1 transcript rows (Harness's incremental pass, no second reader), C2 hooks, C3
worker-run, C4 night-run, C5 suites, C6 machine sampler (memlogd), C7 CPU attribution, C8 presence, C9 media, C10
background journals, C11 chat start. Media "interactive" is derived at read time from A ∪ B, never from `[ -t 0 ]`.

**Cost.** `bin/speed-doctor` reads only derived files and the new journals by offset, ≤ 2 s; Harness execs it after each successful run (no own `StartInterval`), at the run's own priority, never `taskpolicy -b` (it starved Speed for 50 min). The exec keeps Harness's pid, so the System doctor tags both runs' disk counters `speed-doctor`. It is a consumer in P and reports its own cost as `cost.collector_cpu_min_day`. A first run backfills the 28-day window from the owner transcripts through Harness's C1 reader, newest first and resumable; a day enters the window only once every transcript that could hold it is read, so OM/d is never diluted by unread days. Egor: Speed fixes from whatever data exists; history only ranks recurring against one-off and proves before/after, so short coverage lowers confidence and never empties the selection.

## 3. Judging, proof, selection

**Regression** (red, counted): a unit metric over 1.3 × baseline on two consecutive band-matched days with its class's exposure minimum (hooks 200 calls per band-day, tests 3 complete runs, delegation and media as above, nights ≥ 5), **and** the component is worth ≥ 0.5 OM/d; one no `LEVERS` row names gets `levers: []` and a find-the-cause brief. Moved Harness absolute limits are pinned ceilings shown as `watch`, red only at ≥ 0.5 OM/d; collector ceilings are per doctor; the statusline contract's warm p95 ≤ 150 ms (lowest band) joins as a ceiling.

**Opportunity** (`watch`, never counted): a component ≥ 0.5 OM/d, seen on ≥ 3 days or ≥ 3 sessions (both scaled to the covered share of the 7 days, at least 1), with a `LEVERS` row. Id `opportunity:<area>/<component>`; field `opportunity {om_day, saving, confidence, effort_h, night_cost_h, score, levers[], seen_days, data_confidence}`, every field stored and the score recomputed from them; the backlog ranks by `recoverable_min_day`, then score × `data_confidence` (seen days of 7).

**Admission.** No minimum gain: every Speed row (opportunity, regression, spend, suite or CPU audit) enters, priced or not, but suite and CPU audits are due only at ≥ 1 min/day of their unit (`FLOOR_MIN_DAY`); `expected_min_day` in a problem or its ledger row prices one without an opportunity estimate. A pure `class: measurement fix` job enters only beside an admitted row its `blind_for` names. Floor, `test_*` and `hook_*` rows outside Speed keep `time_budget.GAIN_MIN_DAY` (5). Speed prints skipped ids and reasons on one line.

**Score** = saving × confidence ÷ (effort_h + night_cost_h), night_cost_h being the slot-queue and first-landing delay its run adds (`CONFIDENCE`, `EFFORT_H` in `bin/speed-doctor`); an L lever is split into budget-fitting stages; classes recalibrate to closed runs.

**Discovery.** An unmeasured component ≥ 1 OM/d (the residual once above 5 % of A) is a §3 blind spot with `would_catch_if`, for the owner chat, never a fixer. Needs-Egor levers are ranked and shown, never taken.

**Baseline** per (metric, ident, band): the trailing 28-day median of daily values, recomputed each run in both directions. A shard or rename records an ident map (old → regex of new) in the ledger; comparisons cross it on repo Σ.

**Proof, by lever class**; a `fixed` row is proven only with its output-equivalence proof beside the saving, else pending (`speed_yield`):

| class | proof |
|---|---|
| per-call latency (hooks) | paired: old and new code on the same replayed payloads, interleaved in one scratch session, ≥ 200 pairs, Δ mean and p95; then passive confirmation over 3 band-matched days |
| frequency / volume | runs and CPU-s per session-hour |
| elimination | zero occurrences plus a drop of the parent component |
| contention | probe slowdown at matched background load; share of attended local minutes in high-load bands; P with s frozen from before. Never band reweighting, which cancels exactly this effect |
| tail / total | attended aggregate and p95 |
| tests | Σ suite CPU-s per (suite set, sha) from C5; run-all wall in a matched band over ≥ 3 complete runs |
| orchestration | fixture replay of worker-run / night-run plus the passive window |
| media | offline local-phase benches plus the passive window; never a paid run |

Proven reads `fixed · −X <unit> · ≈Y OM/d`. A later regression stamps `regressed_at`.

**Lost time** (`share/time_budget.py`, whose `ROWS` are the classes; Egor). Wall-clock overhead around the work, never
the work, in min/day: each class is the union of its intervals, so parallel runs count once; the overhead
(`overhead_s`) is the union of all classes, never their sum. No floors, free-machine deductions or "could save"
estimates; a class exists only where its intervals are already journaled.

**Lost time index** (Egor; the title number). Fee per unit of work against the previous 7 days, Paasche per stratum
as token-map's `_price_index`; 1.00 = the same, no norms or thresholds. It must not move with volume, parallelism,
vendor, night/day or presence, so a stratum's overhead is the SUM over its agents, each agent's own spans unioned
(the cross-agent union of the min/day rows moves with overlap). Unmeasured time is unknown, not loss. A day before
`horizon()` has no strata, and any such day in either window means no value, never a partial one.

**Test health** (`share/test_health.py`, Speed's `tests` key; the one place test time is shown; its lines, bands and
levers are that module's constants). The heaviest suites rank by their median day of the trailing seven 24 h days,
not the mean: a 3-day mean still carries a third of one heavy day, the median ignores up to three. A suite run on
under four days reads 0 (sporadic cost is no daily lever) unless its first journaled run falls inside the seven. Each
row's wall splits once (`allocate`), so concurrent suites never sum past the wall. Nothing here deletes a test: dead
and pinned suites go to Suite audits' queue.

**ROI** (`night-run report`, `roi ·` lines; the mechanics are `share/time_budget.py`'s). Each Speed or time row of a
fixer job is an improvement of its own, with an even share of the job's spend. A gain is proven per unit against
frozen exposure (the 7 days before), load-matched, so neither sample count nor an earlier drop proves it. Over the
trend a key's gain is claimed once: the earliest positive claim takes it, later fixes read `shared with <ref>`.
Commits touching only measurers and their suites, ledgers, docs or other suites read `measurement fix`, never a gain.
No gain reads `spend without result`, never a revert or a gate; a fix > 1.3× slower: `regression:fix/<job>`, cause or
revert.

**Selection.**
- One rank over every admitted row (`time_budget.speed_rank`): priced by expected gain, unpriced by measured loss in min/day, spend audits by share of spend. A landed fix measured slower (`fix_commits`) ranks first. How many run at once is `share/slots.sh` `slot_room`. The cut-off is also time: the night's speed work has a 6-hour wall-clock window from the night's `started_at` (`bin/night-run` `SPEED_WINDOW_H`, `docs/night-run.md`). Nothing carries over: the next night's pick recomputes from the data, so its levers rank again. A partition slice no `LEVERS` row names ranks on the generic slice lever (`slice_levers`).
- Ranked rows of a context fill fixers of `batch_sizes`: least cost per closed row, own curve at 2+ sizes else pooled, no 1-run minimum, ×2 at the largest.
- One owner per cause file per night across doctors; the other doctor's row links as `same_cause`.
- Skipped: active work (the Code doctor's rule), levers not output-equivalent, measurement fixes without an admitted blind row.
- No score or gain floor: every equivalent, positive-score, non-needs-Egor lever qualifies. An empty pick's `why_none` names its true cause: levers needing Egor, not equivalent or scoring 0, or no opportunity.

**Own keys**: `cost {collector_cpu_min_day}` (no other cost is mechanically recorded, so none is shown as a zero), `yield {proven_om_day, pending_om_day}` from roi gains.

## 4. Menu

`bin/speed-doctor` lays out its lines and `bin/harness-doctor` `menu_text` places them at the top of Harness's menu; Machine and Background are System's. How Speed's `covers` keep each rule counted once: `docs/doctors-contract.md`, own key `speed`. Code's `heavy_tests`/`hot_hooks` become Speed opportunities, kept `protected` by `test_requirement`, a hook charged only for days after its last commit. Harness stays the data plane; the LLM doctor keeps per-leg judging and reads `local_slow` from Harness.

**Ledger.** Speed rows are Harness rows matched by rule `regression` or `opportunity`; nothing moves between ledgers.

## 5. Fixer

**May change** (sweep repos, in worktrees):
- hooks: a raw fast path only when the payload provably lacks every trigger substring and contains no backslash escape; per-call work O(1) in transcript size and repository count (offset or mtime caches); detaching a writer only with an ordering guarantee (the next Pre hook waits on a per-session pending-touch marker, or the touch write stays synchronous and only hashing is deferred); the `verdict` poll's external `sleep 0.1` loop replaced by `wait` plus a watchdog;
- statusline: segment caches keyed on every source the contract row names; idle reprint only for segments whose inputs' stat is unchanged, keeping the work line, ctx TTL and work probe live; every change updates the contract table and `test_statusline_hooks.sh`; changing a contract row is needs-Egor;
- tests: mocked sleeps and clocks, cached fixtures; a shard only when its longest suite exceeds Σ ÷ j for that repo; a serial suite leaves `serial_suite` only after its wall-clock budget becomes an injected clock, proven by a run inside the wave;
- unattended suites at presence-gated nice 10 (`share/run-suites.sh` `unattended()`), never `ProcessType Background` / `taskpolicy -b` or a static nice on night or worker trees (they starve Speed, research runs and the llm-refresh collector); attended suites at nice 0 with a reserved slot (wall-clock suites, the `serial_suite` list, exempt);
- routing churn: `llm-limits.sh` skips the store rewrite when content minus timestamps is unchanged; `onStoreChanged` forks worker-pick only when the hash of its routing inputs changes;
- Hammerspoon refresh throttles, under the one-lever-per-night rule;
- doctor collectors' read paths, proven by that doctor's suite and a phase timing;
- media: absolute binary paths in the media instructions; `timeout 590 tail -F log | grep -m1 '^exit='` instead of sleep polling; lock-aware atomic pick among eligible accounts for unpinned new requests only; fetch before regenerate; event-driven hiding instead of the 0.2 s `osascript` loop; Chrome reuse within a batch and a clone pre-built after an update;
- worker-run and night-run orchestration, within the Never list.

**Never** (each a needs-Egor item with its exact step):
- `settings.json` (matchers, `async`, `refreshInterval`, registrations, hence the hook dispatcher), his `modelSettings` effort, `autoCompactWindow`, and `claude mcp remove codex` (the entry lives in the profiles' `.claude.json`);
- a new deny class in a gate; a gate's deny classes narrowed; a gate made async;
- an assertion removed without a witness test or a requirement dropped across shards (requirement-to-case map); a timing assert loosened beyond load-robust; a suite moved to `--all`;
- caps in `share/run-suites.sh` / `share/slots.sh` or a machine-wide suite budget (nested runs would need token lending); worker slots; `WORKER_RUN_DEADLINE`, `WORKER_RUN_IDLE_S`, `WORKER_RUN_SILENT_S`, `WALL_SETTLE`; straggler cutoffs, dropped raters, review-bench tier efforts; a night deadline; the pre-landing suite gate; the one-debt-round rule;
- orphan sweeps keyed on PPID 1 or a name; unregistering LaunchAgents (homebrew mysql, redis, php, nginx, transcriptions-gpt become needs-Egor rows with measured CPU); `git gc --prune` (unreachable `-w` blobs are load-bearing; only a niced `git maintenance run --task=loose-objects`);
- paid media runs; breaking resume or explicit-account affinity; suite pass reuse;
- a baseline or limit raised, or a score floor on the night pick; robot curl refresh; silent account rotation.

**Proof obligations of a `fixed` line:**
1. The before value (unit and OM/d) with journal refs, snapshotted before its sources are pruned.
2. Work-not-done proof remains required for a speed fix even when a refactor needs no new behaviour test: a deterministic test, red on the old code (a fork count through a PATH shim, no git on an idle render, no sleep); a shard instead shows disjoint, complete suite sets and the Σ and longest-suite numbers.
3. The §3 recipe for its class, within a bounded bench (never 50 full runs).
4. Isolation: every replay and bench runs with HOME, `HARNESS_DOCTOR_DIR` and store paths in scratch and `CLAUDE_PROJECT_DIR` unset, and asserts the live stores' mtimes unchanged.
5. Output equivalence, every class: identical decisions or results on the replay, recorded as the fix's `equivalence` {compared, data, result}; hooks and gates on ≥ 500 replayed real calls (inputs rebuilt from transcripts); per-decision-class fixtures (deny, malformed input, timeout, Stop and SessionStart payloads); a generated JSON-escape corpus for fast paths; a two-call race test (edit, then commit within 100 ms) for anything detached.
6. Touched repos' suites green, assertion inventories ≥ base through the requirement map, mutation-checked on the changed seam.

**Unattended safety.** Night isolation rules apply; the single hooks/statusline/Hammerspoon branch lands last; landing follows `docs/fix-orchestrator.md`. No canary runs after landing, so the fix's own proof shows: no new hook error, cut or unjournaled hook; decisions unchanged; statusline time segments advance; read-only `menuItems()` calls succeed and the hs-lag probe shows no new stall; the suite failure rate has not risen; latency stays under its pinned ceiling and within 1.3 × over ≥ 200 band-matched calls.
