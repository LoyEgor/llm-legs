# Speed doctor — design

Status: design, 2026-10-02, revised after seven T2 hunts (280 confirmed findings); reshaped 10-03 into the Speed block at the top of the Harness doctor, no doctor of its own:
- module `bin/speed-doctor`, exec'd by `bin/harness-doctor` after each run at background QoS within 2 s; its section is Harness's key `speed`, its lines open Harness's `menu.txt`; own state and journals under `${SPEED_DOCTOR_DIR:-~/.cache/speed-doctor}`;
- one ledger, `share/harness-ledger.json`.

Goal (Egor): every minute of his day lost to waiting, in one unit, owner minutes per day (OM/d), ranked and driven down every night, not only when something regresses.

Quality rule (Egor, 10-03): the speed of the current setup at the same intelligence. No lever touches the model, effort, reasoning, thinking or a role's vendor (`validate_levers` refuses such a row at load); each declares `quality: equivalent|risk`. Only `equivalent` (provably identical output) enters selection; `risk` shows only as needs-Egor with `quality_evidence` {compared, data, result}.

Sources: the 2026-10-02 research notes, now retired: [CT] chat turns, [HC] hooks/CLI, [WN] workers/night, [TS] tests, [MD] media, [MC] machine, [BG] background; each citation carries its number. Only raw numbers are reused, never a research owner-minute conversion. **[V]** marks numbers recomputed for this revision from the journals over the post-fix window 09-29 00:00 → 10-02 21:50 local (3.91 d, 39 owner chats). The tests §1 rates, media medians and workers W6 did not reproduce and go unused.

## 1. Owner-minute model

**Blocked minute**: something he launched is running, he is not acting elsewhere, and he takes up its result within R = 5 min. Three terms:

- **A, attended turn.** An owner-chat turn opened by his prompt or by a result notification or peer message (a *continuation*), whose end he answers in the same chat within R.
  - Start = max(opening prompt, previous turn end): a queued prompt starts at dequeue; `durationMs` is never used, so its stale-start bug cannot pull idle time in.
  - Clipped to the part after his last prompt in any other owner chat during the turn.
  - Dropped when an `away_summary` record lies between its end and his reaction.
  - Owner-question tools subtracted; machine-opened chats (`share/chat-open.sh` callers) out.
  - No cap in any sum; the 30-min cap applies to percentiles only, long turns get a count row.
  - Clipped at boots (`kern.boottime` change, pmset "powerd process is started") and pmset Sleep/Wake. A telemetry gap is *unknown coverage*, never sleep, and never drops a whole interval.
  - Chat start, CLI launch → first prompt ready, counts for chats he opens (C11).
- **B, blocked delegation.** Any background job a chat launched (Agent, `run_in_background` Bash, worker-run, review-waiter, media): from max(launch, his last prompt in any owner chat) to the notification, when he answers the follow-up turn within R of its end. That follow-up turn is A.
- **C, direct UI waits.** Menu click → display; Hammerspoon main-thread lag over 50 ms (`hs-lag.tsv`).

**OM/d** = |A ∪ B ∪ C| per local day. Parallel blocked chats share each minute equally, for attribution only.

**Presence (C8)**: a per-minute HID-idle and frontmost-bundle log, no window titles. Once it exists, a candidate minute counts only if HID idle < 2 min or it falls in the last R minutes before his reaction, for A and B alike. Only a row the log covers is judged this way; a row or minute it did not log is unknown, never away, and keeps the R proxy.

**Today [V]:**

| term | OM/d |
|---|---|
| A, his own turns (union, uncapped; the old 30-min cap hid ≈ 15) | 120 |
| after the other-chat clip | 68.5 |
| plus continuations | 105.7 |
| after `away_summary` drops | **99** |
| B, old rule (no prompt anywhere during the run, answer ≤ 2 min after notification) | 5.5 |
| B, new rule (union 81) | adds **70** |
| C (menu journal) | ≈ 0.02 |
| **headline** | **≈ 169** |

- The previous headline, 148 = 114 + 34, took B from [WN]'s 9.2-day window, which includes the 09-23..28 hook-timeout incident.
- **R sensitivity**: 88 at R = 2, 287 at R = 10, no plateau. The menu shows all three; the headline is R = 5. A **bound** (his reaction in *any* owner chat confirms presence) is shown, never summed.
- **Yield and proofs never use the headline's R-selection**: a component's exposure is frozen from its before window (attended share × all owner turns or calls of that class), so shortening a turn below his reaction cannot fake a saving.

**Exclusive partition.** Every blocked minute is split once, in precedence: hook batch > queue (suite slot, media lock, worker slot; charged to the slot holder's job: night, worker or chat) > suite > media local phase > other tool > compaction > generation > residual. B splits along its critical path: pre-CLI, per-attempt run, reroute loss, suites inside, relay tail, notification, continuation turn. Media is a component of A and B with its own drill. Area lines are "of which" and sum to the headline.

**Load.** A local span (tool body, hook batch, stop hook, chat start, residual, media local phase) counts its unloaded service time (its class's p50 in the lowest load band) toward its own component; the excess goes to the contention pool **P**. So a hook fix and a background consumer never claim the same minute.
- [V] Owner-chat Bash Pre+Post hook floors average 1.67 s per call (hooks journals, owner pids), 0.82 s on the lightest day 09-29. At ≈ 331 attended Bash calls/day: ≈ 4.5 OM/d direct, ≈ 4.7 in P.
- P ≈ 10–14 OM/d (*est.*; s from the contention probe once C6 exists).

**P split** by **self-reported CPU-seconds** (C7: hook, statusline, suite, collector and worker-pick rows carry `times`/rusage), with fork origin from census bursts; the remainder is shown as `unattributed`, never spread.
- Memory pressure is its own mechanism: blocked local minutes in memlogd incident mode go to `memory`, split by RSS growth per process tree.
- Shares are *allocated estimates*; a removal saving counts only after an intervention proves it (§3).
- Load from Speed's or the night's own runs is tagged `self-load`: shown, never a regression.

**Savings are counterfactual**: shorten the component's spans, recompute the union and the dependency's critical path, read the drop. Δ unit × exposure is only a first ranking estimate. A non-critical parallel suite, worker or media branch saves 0.

**Zero and weather.**
- Unattended work counts 0. The night counts only through B, P and queue holds overlapping blocked minutes; its wall time is a secondary metric, in hours.
- Weather is tagged per span or attempt, never per day: owner-request decode rate and TTFR outside their band (the LLM doctor's same-hour headless TTFT as control); attempts with `walled_accounts`, `*_USAGE_LIMIT` or a `wall` kill; long silent requests. Media rc 3 is a quota wall: 0 minutes, not weather. Local hook, test, menu and collector samples are never dropped for weather.

## 2. Areas, metrics, collectors

**Areas**, the same in the menu and `doctor-fix`: `chat`, `delegation`, `hooks`, `tests`, `machine`, `background`, `night`.

**Two forms per metric**: a **unit metric** for regressions and proofs, its **OM/d** for ranking. Normalisation: chat totals per 100 prompts; background per open session-hour; tests per (suite set, sha); delegation per run class; nights per completed job.

**Bands**, per class, never a cross product:
- load = loadavg ÷ ncpu (< 1, 1–2, 2–4, > 4), overlap-weighted over the span from memlogd's 15-s ticks; unknown when no tick within 60 s. CPU busy saturates ([V] 959 samples: mean 0.78, p50 0.87, 68 % above 0.7);
- hooks: load × transcript size (< 1, 1–10, > 10 MB);
- TTFR: cache hit/miss × thinking (0, < 500, ≥ 500 tokens);
- generation, TTFR and turn metrics: not banded, judged on pooled 7-day windows, never ratcheted.

| area · metric | unit / OM | source | traps |
|---|---|---|---|
| chat · turns | A split by the partition; TTFR from dequeue; thinking s; compaction s; context cost Σ 0.7 s/100 k × (context − 50 k); cache misses × s; residual | C1 | usage repeats per block line (dedupe by `requestId`); `compactMetadata` is a JSON object (string fallback); TTFR at xhigh inflated by completion-time logging; the 09-23..28 incident |
| chat · call waits, slow periods | moved `wait`, `local_slow` | Harness `c` events | as Harness |
| chat · start | launch → ready, by SessionStart source (startup/resume/compact), cold/warm | C11 | compact starts belong to compaction |
| delegation · blocked | B on the critical path; `result-turn` | C1 `d` rows + C3 | `started_at` is restamped on purpose (slot wait, reroute): queue = `pid_started_at → cli_starts[0]`; owner-decision pauses and `blocked-on-egor` stop the clock; deadline kills are a waste metric followed to a usable result |
| delegation · overhead | pre-CLI, reroute loss (tail sum), relay tail, notification lag, stragglers, adjudication | C3, `runs.jsonl`, review-log | judged only on task-size-free components, ≥ 50 runs per class, ≥ 30 rounds per tier; wall per vendor × effort × role × warm/cold RESUME is display-only |
| delegation · media | queue (lock acquisition incl. failures), prep, launch, render, download, recovery, per (tool, route, requested model, action, size) | C9 | render and failures stay judged by the LLM doctor (Speed converts minutes and links its problem id); rates per active day; only legs inside A ∪ B are judged, ≥ 30 attended legs per cohort, a concurrency band |
| hooks · per call | batch floor + timeout of every cut hook; per-hook counterfactual floor without h; hook count/CPU term | C2 joined to calls inside A ∪ B (chat, subagent, worker on B's path) | slowest hook, never a sum; grows with transcript size; SubagentStop and SessionStart included; non-bypass sessions keep their floors (only permission waits drop); statusline-only gate keys belong to background |
| hooks · turn end | stop.d part ms | C2 (`stop.d/<name>`) | attended stop ≈ 0.7 OM/d [CT] |
| tests · suites | per suite CPU-s, forks, max RSS (unit); wall per load band (OM); queue; reruns after `ok:false`, load flake vs real fail | C5 | complete coverage only (killed runs are not fast runs); ident map across shards and renames; cold or first-after-edit runs apart; full-run wall = max(longest suite, Σ suite-s ÷ j) + serial tail: rank only the binding term |
| tests · moved | `test_*`, `suites_at_once` (standalone runs counted) | C5 | |
| machine · P | P per attended local minute; probe slowdown; consumer shares; memory; swap MB + swap-in rate (never a share: macOS swap is dynamic); reboots charged (restart + cold cache) | C6, C7 | [V] 10-01 swap peak 11 019 MB, available 3 618 MB; process-min ≠ CPU-min |
| machine · git | loose objects per repo, git-op p50 inside hooks | Harness Growth | |
| background | statusline renders and CPU per session-hour, idle share; `worker-pick --menu` and merge-kick runs/CPU; menu click wait, `doctors:bg` builds, hs lag; CPU per launchd label; doctor collectors wall/CPU × runs | statusline fold, C7, C10 | idle = no transcript line, no running tool or background task, no work-probe child; a menu with no lines reads "not measured" |
| night | wall, first landing, slot queue, debt round, branch review, adjudication, suite passes, landing wait | C4 | |

**Clocks.** Durations come from monotonic or elapsed counters where the writer has them; wall jumps and `secs < 0` are flagged, never summed; a span crossing a boot or sleep boundary loses only that slice.

**Collectors**, one append each, all with env overrides for fixtures:
- **C1, transcript rows**, extending Harness's incremental pass (no second reader): `t` turn rows (session, start, end, origin, R = 2/5/10 flags, partition); `d` delegation rows (launch, notification, follow-up end, reaction); media phase spans by the `media-run` Bash call's tool id; in-flight state kept in `state.json` across passes; model and effort per request (owner chats run Fable as well: ≈ 26.0 k opus xhigh vs ≈ 13.3 k Fable requests in 14 d).
- **C2, hooks**: `hook-time.sh` appends user+sys CPU (bash `times`); `stop-dispatch` exports `HOOK_TIME_PPID` and tags parts `stop.d/<name>`, kept out of floor batching; day summaries keep floor histograms per (class, band) and per hook, with the counterfactual, ≥ 28 days.
- **C3, worker-run**: `started_at` keeps its watchdog meaning; adds `cli_starts[]` per attempt, `ended_at`, terminal reason, attempt durations; exports `WORKER_RUN_ID` to children; appends one row per finished run to `worker-stats/runs.jsonl`, kept ≥ 35 d (run dirs are pruned at 7). `worker-relay-hold.sh` adds `relay_returned_at` next to `stopped=`; `notified_at` comes from the transcript queue-operation.
- **C4, night-run**: `job add/set` stamp their own times; append-only phase events with predecessor ids (debt rounds, repository validation, suite passes, landings, owner pauses).
- **C5, suites**: one row per run: `queued_at`, `started_at`, `ended_at`, repo_root, HEAD, scope, suite-set digest, `WORKER_RUN_ID` and session (read before `run_one` unsets them), j, slot, signal, complete; per suite {rc, secs, cpu_s, forks}. `tests/lib/suite-journal.sh` covers direct `bash tests/x.sh` runs, composing with suite EXIT traps and capturing its destination before HOME is replaced. `statusline-work-probe.sh` stops writing rows for runs with a C5 row; `times.tsv` drops suites whose file is gone; opt-in phase timing for the top-Σ suites.
- **C6, machine sampler in memlogd's 15-s loop**: loadavg, swap MB and swap-in rate, a thermal flag, boot id, and a contention probe once a minute (N × fork/exec of `/usr/bin/true` plus one `jq` over a fixed input); s = probe ÷ its quiet-hour floor.
- **C7, CPU attribution**: spawner self-reports (C2, statusline, C5, C10, worker-pick); short census bursts for fork origin by ancestor chain; long-lived processes as `ps` deltas keyed by (boot, pid, start time), mapped to a launchd label through the `~/.local/libexec` wrappers; unresolved = `unattributed`.
- **C8, presence**: a separate Hammerspoon watcher (never the `llm-limits` singleton) writes `presence.tsv`: minute, HID idle s, frontmost bundle id.
- **C9, media** (`share/image-leg.sh`, browser engines): phases with failures included (prep, lock acquisition, launch with a `clone_built` flag, render, download, recovery); `action`, requested vs served model, size, `CLAUDE_LAUNCHER_SESSION`, `WORKER_RUN_ID`; the lock holder in a sibling `${lock_dir}.holder` removed in `cleanup` (a file inside the dir breaks `rmdir`); receipts for direct `gemini-web`/`chatgpt-web` operations. "Interactive" is derived at read time from A ∪ B, never from `[ -t 0 ]`.
- **C10, background journals**: every doctor appends `{doctor, start, wall_s, cpu_s, trigger}` to `~/.cache/doctors/collector-runs.jsonl`; the actions log gains pid, source and sub-second times, and Hammerspoon test harnesses redirect it; `backgroundMenu` builds journal as `doctors:bg`, plus an hs-lag probe line over 50 ms; the merge-kick journals each `llm-limits.sh` run; `llm-refresh` journals a tick id.
- **C11, chat start**: `claudeb` stamps `EPOCHREALTIME` at entry and before exec; an MCP log fold of the newest `mcp-logs` lines.

**Cost.** Harness is already at its 30 s collector limit, so its extension carries its own measured per-phase budget, ≤ +1 s per run (stage 1 gate). `bin/speed-doctor` reads only derived files and the new journals by offset, ≤ 2 s; Harness execs it after each successful run (no own `StartInterval`), at `ProcessType Background`. It is a consumer in P and judges its own `collector_time:speed`. Its first run backfills the turn and delegation rows of the 28-day baseline window from the owner transcripts through Harness's C1 reader (Harness's offsets predate C1), at most 20 s a run in 4 MB reads, resumed by later runs, rows Harness already holds counted once; later runs read only its own backfill files. It reads the newest transcripts first, and a day enters the window only once every transcript that could hold it is read, so OM/d is never diluted by unread days. Egor (2026-10-03): Speed fixes from whatever data exists; history only ranks recurring against one-off and proves before/after, so short coverage lowers confidence and never empties the selection.

## 3. Judging, proof, selection

**Regression** (red, counted): a unit metric over 1.3 × baseline on two consecutive band-matched days with its class's exposure minimum (hooks 200 calls per band-day, tests 3 complete runs, delegation and media as above, nights ≥ 5), **and** the component is worth ≥ 0.5 OM/d with a lever path. Moved Harness absolute limits are pinned ceilings shown as `watch`, red only at ≥ 0.5 OM/d; collector ceilings are per doctor; the statusline contract's warm p95 ≤ 150 ms (lowest band) joins as a ceiling.

**Opportunity** (`watch`, never counted): a component ≥ 0.5 OM/d, seen on ≥ 3 days or ≥ 3 sessions (both scaled to the covered share of the 7 days, at least 1), with a `LEVERS` row. Id `opportunity:<area>/<component>`; field `opportunity {om_day, saving, confidence, effort_h, night_cost_h, score, levers[], seen_days, data_confidence}`, every field stored and the score recomputed from them; the backlog ranks by `recoverable_min_day`, then score × `data_confidence` (seen days of 7).

**Score** = saving × confidence ÷ (effort_h + night_cost_h), night_cost_h being the slot-queue and first-landing delay its run adds. Confidence 0.8 measured with a mechanical lever, 0.5 estimated, 0.3 unmeasured. Effort S 1 h, M 3 h; an L lever is split into budget-fitting stages; classes recalibrate to closed runs.

**Discovery.** An unmeasured component ≥ 1 OM/d (the residual once above 5 % of A; today ≈ 10 %) is a §3 blind spot with `would_catch_if`, for the owner chat, never a fixer. Needs-Egor levers are ranked and shown, never taken.

**Baseline** per (metric, ident, band): the trailing 28-day median of daily values. It drops only to a proven fix's after-value (no min-ratchet); raising it is an owner handoff. A shard or rename records an ident map (old → regex of new) in the ledger; comparisons cross it on repo Σ.

**Proof, by lever class**; outcome `proven`, `pending-exposure`, `inconclusive` or `disproven`:

| class | proof |
|---|---|
| per-call latency (hooks) | paired: old and new code on the same replayed payloads, interleaved in one scratch session, ≥ 200 pairs, Δ mean and p95; then passive confirmation over 3 band-matched days |
| frequency / volume | runs and CPU-s per session-hour |
| elimination | zero occurrences plus a drop of the parent component |
| contention | probe slowdown at matched background load; share of attended local minutes in high-load bands; P with s frozen from before. Never band reweighting, which cancels exactly this effect |
| tail / total | attended aggregate and p95 |
| tests | Σ suite CPU-s and forks per (suite set, sha) from C5; run-all wall in a matched band over ≥ 3 complete runs |
| orchestration | fixture replay of worker-run / night-run plus the passive window |
| media | offline local-phase benches plus the passive window; never a paid run |

Proven reads `fixed · −X <unit> · ≈Y OM/d`. Only `disproven` counts toward the freeze (two disproven fixes freeze a component); a freeze lifts on a structural change (the component's code digest or a new ident), never on volume. `pending-exposure` waits as long as it needs; a later regression stamps `regressed_at`.

**Floor** (`share/time_budget.py`). Each class is judged against a floor, not its own history: zero for hooks, Stop hooks,
gates, suite and slot waits, retries and locks (plain Claude Code has none of them); `TEST_BUDGET_MIN_DAY` (60) of suites
running per day; workers model-active ≥ 70 % of their wall. The gap in min/day is the class's `recoverable_min_day`;
their sum (workers aside, they overlap the waits) is `lost_min_day`, Speed's headline (`<lost> min/day over the floor`,
then the owner-minute view). The 7-day band only names sudden regressions as holes. A class gap ≥ 0.5 min/day adds to the
best-ranked opportunity whose fix `time_budget.improvement_class` scores against that class (hooks and Stop → chat/hooks,
suites → chat/tests, suite wait → chat/queue), else it is `opportunity:time/<class>` (`TIME_LEVERS`); the score comes from the recoverable minutes, so the
night takes the biggest gap even when nothing regressed, and an empty pick names the recoverable minutes in `why_none`.
**Floor rows** (rule `time_floor`, counted, ledger states as regressions): `time_floor:<class>` more than `FLOOR_ROW_MIN_DAY` (30)
over its floor in the last day, `time_floor:workers-active` when the last night's workers were model-active under 30 %; the
proof of a fix is the measurement back under it (no row).

**ROI** (`night-run report`, `roi ·` lines). A fixer job whose problem is a Speed or time row (`opportunity`,
`regression`, `time_floor`, `test_*`) is an improvement: weighted spend, lines changed, and min/day saved = its class's mean
over up to 3 settled days before the night minus the mean over up to 3 settled days after a full day of the change
(pending until then). A day with zero recorded time predates the measurement: it is unmeasured, never a zero day,
and stays out of the band, the floors and both sides; a job with no measured day on a side reads `unmeasured before
or after it` and its spend stays out of the return. Per night: improvement spend against minutes gained; cumulative
over the trend's nights. No gain reads `spend without result` — a measurement, never a revert or a gate.

**Selection.**
- Regressions (with a lever and ≥ 0.5 OM/d) first, then every qualifying opportunity by recoverable min/day. No count or worker-hour cap: the night's speed is the goal, and how many fixers run at once is the worker slots' load/memory admission (`share/slots.sh` `slot_room`), a queue included. A loud row without a lever (`time_floor`) takes no hook turn (`bin/doctor-fix` dispatches it on its own); an opportunity on a lever a regression took rides with it.
- At most one hooks/statusline/Hammerspoon lever per night (`HOOK_LEVERS`; one commit, one proof): they share the chat's hook floor, so two landing the same night cannot be told apart by its paired replay or its band-matched days.
- One owner per cause file per night across doctors; the other doctor's row links as `same_cause`.
- Skipped: active work (the Code doctor's rule), `pending-exposure`, frozen components, savings below their proof's noise.
- No score floor: any equivalent, positive-score, non-needs-Egor lever qualifies. An empty pick's `why_none` names its true cause: the hook turn taken, levers needing Egor, not equivalent or scoring 0, or no opportunity.

**Own keys**: `cost {collector_cpu_min_day, fixer_worker_min, review_min, slot_queue_min, landing_delay_min}`, `yield {proven_om_day, pending_om_day}`.

**Judge**: sha256 over `bin/speed-doctor`, the ledger's dismissals, `LIMITS`, `LEVERS`, `TIME_LEVERS`, the floors, `HOOK_LEVERS`, R, the bands and the proof table.

## 4. Menu

Illustrative, the top of Harness's menu:
```
Harness doctor: 2 problems
Speed: 1 problem · 169 OM/d · 3.9 of 7 days covered · R 2/10: 88/287
  Chat turns: 99 min/day · model 50 · tools 31 · compaction 4
  Delegation: +70 min/day · workers 56 · background Bash 14 · media <1
  Hooks and tests: of which 4.5 and 9 min/day
  Machine: 12 min/day contention · load 2.3/core · 31 % unattributed
  Background: statusline 0.9 CPU-cores · 18 % of P
  Night: last 5 h 50 m · first landing 4 h 47 m
  Opportunities · top 10 · Needs Egor · not measured · cost · yield
  Waits · Slow periods · Hook waits · Hooks · Load · Tests · Collector
Stop hooks · Guards · Growth · Hook health · Test flakes · Memory guard · Limiter holds
```

The headline is the strict OM/d. Area lines are "of which" and sum to it (Harness §2.1 shape); means appear only in drills; model minutes are a measured leaf with no lever. An opportunity row reads rank · target · saving · effort · lever · protection; a needs-Egor row adds its evidence. `bin/speed-doctor` lays out its lines, `bin/harness-doctor` `menu_text` places them.

**Each rule judged once.** The time rules stay in their Harness sections, now under Speed: `wait`, `local_slow`, `floor`, `hook_*`, `statusline`, `menu_build`, `load`, `test_*`, `collector`. Once Speed judges a component against a ≥ 7-day baseline, its `covers` (chat: `wait`, `wait_cut`, `local_slow`; background/statusline: `statusline`) turn those verdicts `watch` with `judged_by`, keeping `was_state`, so `problem_count` counts each rule once. Health lines leave for Hook health (`fastpath`, `unjournaled`), Test flakes (`test_load_fail`) and Memory guard. Code's `heavy_tests`/`hot_hooks` become Speed opportunities, kept `protected` by `test_requirement`, a hook charged only for days after its last commit. Harness stays the data plane; the LLM doctor keeps per-leg judging and reads `local_slow` from Harness.

**Ledger.** Speed rows are Harness rows matched by rule `regression` or `opportunity`; nothing moves between ledgers.

## 5. Fixer

`doctor-fix launch harness [--night]` makes one run per area with chosen problems; the snapshot is the regressions plus the chosen opportunities (contract §4's top-K exception, extended to Speed). Component resolution names hook setters, statusline files and Hammerspoon builders as Harness's does.

**May change** (sweep repos, in worktrees):
- hooks: a raw fast path only when the payload provably lacks every trigger substring and contains no backslash escape; per-call work O(1) in transcript size and repository count (offset or mtime caches); detaching a writer only with an ordering guarantee (the next Pre hook waits on a per-session pending-touch marker, or the touch write stays synchronous and only hashing is deferred); the `verdict` poll's external `sleep 0.1` loop replaced by `wait` plus a watchdog;
- statusline: segment caches keyed on every source the contract row names; idle reprint only for segments whose inputs' stat is unchanged, keeping the work line, ctx TTL and work probe live; every change updates the contract table and `test_statusline_hooks.sh`; changing a contract row is needs-Egor;
- tests: mocked sleeps and clocks, cached fixtures; a shard only when its longest suite exceeds Σ ÷ j for that repo; a serial suite leaves `serial_suite` only after its wall-clock budget becomes an injected clock, proven by a run inside the wave; reuse of a hermetic result only on unchanged source, fixture, environment and scope digests, landing verification always run;
- background QoS for unattended work: `ProcessType Background` / `taskpolicy -b` for the merge-kick, statusline probes, worker-pick, night worker trees and worker/night suites; attended suites at nice 0 with a reserved slot (wall-clock suites, the `serial_suite` list, exempt);
- routing churn: `llm-limits.sh` skips the store rewrite when content minus timestamps is unchanged; `onStoreChanged` forks worker-pick only when the hash of its routing inputs changes;
- Hammerspoon refresh throttles, under the one-lever-per-night rule and the Hammerspoon canary;
- doctor collectors' read paths, proven by that doctor's suite and a phase timing;
- media: absolute binary paths in the media instructions; `timeout 590 tail -F log | grep -m1 '^exit='` instead of sleep polling; lock-aware atomic pick among eligible accounts for unpinned new requests only; fetch before regenerate; event-driven hiding instead of the 0.2 s `osascript` loop; Chrome reuse within a batch and a clone pre-built after an update;
- worker-run and night-run orchestration, within the Never list.

**Never** (each a needs-Egor item with its exact step):
- `settings.json` (matchers, `async`, `refreshInterval`, registrations, hence the hook dispatcher), his `modelSettings` effort, `autoCompactWindow`, and `claude mcp remove codex` (the entry lives in the profiles' `.claude.json`);
- a new deny class in a gate; a gate's deny classes narrowed; a gate made async;
- an assertion removed without a witness test or a requirement dropped across shards (requirement-to-case map); a timing assert loosened beyond load-robust; a suite moved to `--all`;
- caps in `share/run-suites.sh` / `share/slots.sh` or a machine-wide suite budget (nested runs would need token lending); night slots; `WORKER_RUN_DEADLINE`, `WORKER_RUN_IDLE_S`, `WORKER_RUN_SILENT_S`, `WALL_SETTLE`; straggler cutoffs, dropped raters, review-bench tier efforts; a night deadline; the pre-landing suite gate; the one-debt-round rule;
- orphan sweeps keyed on PPID 1 or a name; unregistering LaunchAgents (homebrew mysql, redis, php, nginx, transcriptions-gpt become needs-Egor rows with measured CPU); `git gc --prune` (unreachable `-w` blobs are load-bearing; only a niced `git maintenance run --task=loose-objects`);
- paid media runs; breaking resume or explicit-account affinity;
- a baseline or limit raised, or a score floor on the night pick; robot curl refresh; silent account rotation; the `.claudeb` store; the live Hammerspoon singleton.

**Proof obligations of a `fixed` line:**
1. The before value (unit and OM/d) with journal refs, snapshotted before its sources are pruned.
2. A deterministic work-not-done test, red on the old code (a fork count through a PATH shim, no git on an idle render, no sleep); a shard instead shows disjoint, complete suite sets and the Σ and longest-suite numbers.
3. The §3 recipe for its class, within a bounded bench (never 50 full runs).
4. Isolation: every replay and bench runs with HOME, `HARNESS_DOCTOR_DIR` and store paths in scratch and `CLAUDE_PROJECT_DIR` unset, and asserts the live stores' mtimes unchanged.
5. Output equivalence, every class: identical decisions or results on the replay, recorded as the fix's `equivalence` {compared, data, result}; hooks and gates on ≥ 500 replayed real calls (inputs rebuilt from transcripts); per-decision-class fixtures (deny, malformed input, timeout, Stop and SessionStart payloads); a generated JSON-escape corpus for fast paths; a two-call race test (edit, then commit within 100 ms) for anything detached.
6. Touched repos' suites green, assertion inventories ≥ base through the requirement map, mutation-checked on the changed seam.

**Unattended safety.** Night isolation rules apply; the single hooks/statusline/Hammerspoon branch lands last; suites pass after the rebase and before push. Within the hour the close runs a correctness canary: no new hook error, cut or unjournaled hook; decisions unchanged; statusline time segments advance; read-only `menuItems()` calls succeed and the hs-lag probe shows no new stall; the suite failure rate has not risen. Latency reverts only past a pinned ceiling, or > 1.3 × with ≥ 200 band-matched calls. Otherwise the orchestrator reverts the commit and records the job `left`.

## 6. Backlog, recomputed

Saving is gross (direct + P part). Score = saving × confidence ÷ effort_h.

| # | opportunity | OM/d → saved | evidence | lever | eff · conf · score |
|---|---|---|---|---|---|
| 1 | review-flow-gate sets the Pre-Bash floor | ≈ 2.6 → 2.0 | [V] counterfactual Pre mean −0.47 s/call, owner pids 09-29..10-02 | provable-absence fast path; then `statusline-workdir-hook` (jq before its `bash_worktree` check, no Read branch) and the other full-work hooks, one per night | S · 0.8 · 1.6 |
| 2 | unattended work at foreground QoS during his hours | P share ≈ 5 → 3 (*est.*) | busy p50 0.87 [V]; merge-kick un-niced; night 12:26–18:16 inside his day [WN] | background QoS, attended suite priority | S · 0.5 · 1.5 |
| 3 | commit-journal (+ commit-report) Post | ≈ 2.9 → 2.5 | [V] Post mean −0.30..−0.55 s without it | ordering-guaranteed detach; commit-report fast path | M · 0.8 · 0.67 |
| 4 | relay tail | ≈ 4 → 3 (*est.*) | [WN W4] p95 11 min; reruns of run-all | relays return the report without re-verifying (`risk`); sized by C3 | M · 0.3 · 0.3 |
| 5 | Σ suite work in llm-legs run-all (throughput-bound) | 9 attended → 1.5 | [V] 2 810 s run: Σ 13 899 s ÷ 5 ≈ wall, pole test_worker_pick 1 838 s; test_llm_limits ≈ 53 machine-min/day, 13 unmocked sleeps | mock sleeps and clocks, test_llm_limits first; staged M | M · 0.5 · 0.25 |
| 6 | hook work grows with transcript size | ≈ 1.5 → 1 (*est.*) | review-flow-gate 145 → 375 ms from < 1 to 1–10 MB [HC] | O(1) per call | M · 0.5 · 0.17 |
| 7 | chat start: `instruction-watch.sh baseline` sets the SessionStart p95 21.9 s | ≈ 0.7 (*est.*) | p50 0.76 s [HC] | baseline off the start path, built lazily | S · 0.5 · 0.35 |
| 8 | codex reroute loss | tail gaps 82–185 min (*unverified*) | worker-attempts | wall-aware account ranking before launch | M · 0.3 · after C3 |
| 9 | statusline idle work | P share ≈ 2–3 → 1.2 (*est.*) | ≈ 18–20 % of new processes; 54 % idle renders | segment caches, contract-safe reprint | M · 0.3 · 0.12 |
| 10 | `verdict` poll forks | ≈ 0.4 (*est.*) | 22 855 runs/day, p95 8.9 s | `wait` + watchdog | S · 0.5 · 0.2 |

**Below the 0.5 OM/d floor** (`watch`): `worker-pick --menu` churn (≈ 0.4); the codex-image lock (attended < 0.1; the lever is unattended throughput, others were idle in most queued waits); cache breaks from account or `/model` switches (≈ 0.2); media poll overshoot (unattended).

**Needs-Egor, ranked**: the owner-chat poll deny (≈ 1–2, overshoot only); compaction window and context (compaction 4.3 + context ≈ 5, optimum unknown until C1 measures injection volume); settings steps (Q3); non-repo daemons.

**Totals.** Within the fixer's reach ≈ 15 OM/d of 169 (≈ 9 %); ≈ 40 with the owner trades.
- **Night 1** (one hook lever): #1, #2, #5 stage 1 (≈ 5 h).
- **Night 2**: #3 as the hook lever; #4 and #8 once C3 holds a week.

## 7. Build stages

Fixtures only, through env overrides: `HOME`, `HARNESS_DOCTOR_DIR`, `HARNESS_DOCTOR_NOW`, `SPEED_DOCTOR_DIR`, `DOCTORS_DIR`, `WORKER_RUN_DIR`, `WORKER_STATS_DIR`, `STATUSLINE_CACHE_DIR`, `RUN_SUITES_TIMES`, `MEMLOGD_DIR`, `IMAGE_LEG_LOG`; never a live store. Stages land in order, one landing each.

1. **Harness headroom.** Files: `bin/harness-doctor` (`journal_runs` by offset; per-phase timing; the sampler's fixed 2 s sleep reported apart from collector CPU; its C10 row). Tests: `tests/test_harness_doctor.sh` (an offset fixture proves only new bytes are read; a phase-timing key). Invariants: `da` names `collector-runs.jsonl`. Verify: 24 h collector p50 ≤ 15 s before stage 2 lands. Landing: no rule moves.
2. **Hook and statusline journals (C2, C7 self-reports).** Files: claude-setup `hooks/lib/hook-time.sh` (CPU column, `HOOK_TIME_PPID`), `hooks/stop-dispatch.sh` (`stop.d/<name>`); `bin/statusline.sh` (CPU column); `bin/harness-doctor` (banded per-hook day histograms with counterfactuals, 28 d; the statusline fold keeps session-hours and idle state). Tests: claude-setup `tests/test_hook_time.sh`, `tests/test_stop_dispatch.sh`; `tests/test_statusline_hooks.sh`; `tests/test_harness_doctor.sh`. Invariants: `da` (trailing column, stop.d keys). Verify: one hook-time ↔ transcript join settles the UserPromptSubmit ordering (if the hooks precede the prompt stamp, A starts at the prompt minus that ppid's UPS floor). Landing: trailing column, old readers unaffected.
3. **Transcript rows (C1).** Files: `bin/harness-doctor`. Tests: `tests/test_harness_doctor.sh` fixtures for stale start, queued prompt, notification mid-turn, continuation, other-chat clip, `away_summary`, a boot inside a turn, `requestId` dedupe, `compactMetadata` as dict and as string. Invariants: a new row for `t`/`d` rows. Verify: the 09-29..10-02 replay gives A 99 ± 5, B +70 ± 7 (pinned).
4. **Machine (C6, C7 census, C11).** Files: `bin/memlogd`; `bin/harness-doctor` (census bursts, label map); `bin/claudeb` entry stamps; the MCP log fold. Tests: `tests/test_memlogd.sh` (`MEMLOGD_DIR`, PATH-shimmed `sysctl`); `tests/test_harness_doctor.sh`. Invariants: the memlogd line-format row (or a new one). Verify: the probe floor is stable across three quiet hours.
5. **Delegation, night, suites, media, background (C3, C4, C5, C9, C10).** Files: `bin/worker-run`; claude-setup `hooks/worker-relay-hold.sh`; `bin/night-run`; `share/run-suites.sh`, new `tests/lib/suite-journal.sh`, `bin/statusline-work-probe.sh`; `share/image-leg.sh`, `bin/codex-image` (sibling holder), browser engines; `hammerspoon/llm-limits.lua` (actions-log tags), `hammerspoon/doctors.lua` (`doctors:bg`, hs-lag); `bin/llm-limits.sh` merge journal; `bin/llm-refresh` tick id. Tests: `test_worker_run_stamps.sh`, `test_worker_run_watchdog.sh` (`started_at` semantics unchanged), `test_worker_relay_hold.sh`, `test_night_run.sh`, `test_slots.sh`, new `tests/test_run_suites_journal.sh`, `test_statusline_hooks.sh` (probe dedupe), `test_codex_image.sh` (release with holder, concurrent acquire, crash), `test_doctors_menu.sh`. Invariants: `da`; new rows for `runs.jsonl`, the C5 schema, the legs schema, the actions-log line. Verify: a fixture replay per writer; no journal doubles a row.
6. **Speed block.** Files: `bin/speed-doctor` (stdlib; `--json` the section, `--menu` Harness's menu with it, `--quiet`); `bin/harness-doctor` (`exec_speed`, `apply_speed`, `speed_block`); the Harness notes of `docs/doctors-contract.md`; `docs/DIAGNOSTICS.md`. Tests: `tests/test_speed_doctor.sh` over `tests/fixtures/speed-calibration/` pins the headline, the R band, partition sum = headline, the backlog order and scores, the quality rule and each rule counted once. Roster `dj` stays four doctors.
7. **Menu.** Inside Harness's `menu.txt`; `hammerspoon/doctors.lua` caches latest-run summaries instead of rescanning per open. Tests: `test_doctors_menu.sh`, `doctors_menu_harness.lua`, `test_harness_doctor.sh`.
8. **Regroup, one landing.** `bin/harness-doctor` `regroup` puts the time sections under Speed and splits out Hook health, Test flakes and Memory guard; `covers` supersede a verdict only past a 7-day baseline; `bin/code-doctor` drops `heavy_tests`/`hot_hooks` for Speed opportunities. Tests: `test_harness_doctor.sh`, `test_code_doctor.sh`, `test_speed_doctor.sh`.
9. **doctor-fix and night.** `doctor-fix launch harness` takes the regressions plus Speed's `selection` (area `speed`); a harness night's close refuses any added or removed line setting a model, effort or thinking knob (`KNOBS` in `bin/doctor-fix`; live settings and worker-model against their launch lines). Tests: `test_doctor_fix.sh`: Night 1 over the calibration fixture, a diff per site, a knob-free diff closes.
10. **Presence (C8).** `hammerspoon/presence.lua` writes `presence/<day>.tsv` (row `eb`; `tests/test_presence.sh`); started by nothing yet. Effect: A and B move from the reaction proxy to presence; the R band narrows.

## 8. Owner questions (trades)

1. **Settings steps, five minutes once**: drop Read from `statusline-workdir-hook`'s PostToolUse matcher; `claude mcp remove codex` in three profiles; allow the hook-dispatcher registration. Gain ≈ 0.5 OM/d now plus ≈ 2 later via the dispatcher; loss: none measured. Recommend: yes.
2. **A foreground-poll deny in owner chats only** (relays and headless exempt). Gain ≈ 1–2 OM/d of overshoot; loss: a 5–10 s re-plan per false denial. Recommend: yes, after a 14-day transcript replay shows zero denials of non-poll commands.
3. **Night: split the debt round and commit/land per repository** (changes night-run.md's one-round rule), keeping 5 slots. Gain ≈ 1 OM/d on nights inside his day (−2 h of overlap × P rate); loss ≈ 0. The alternative, 8 slots, adds ≈ +0.9 OM/d of P during the overlap, netting ≈ 0. Recommend: the split, 5 slots.

**Unverified**: P and every CPU share until C6/C7; the relay, reroute and QoS savings; detach ordering; payload rebuilding from transcripts; OTel.

## Appendix: Rejected findings

P1 and P2: none rejected; each changed the design above, duplicates merged into the same change.

P3, grouped:
- 20261002T192129Z-098df4b, [MC] cores (25.2 h/day ≈ 2.9) and MOT α factors: duplicate of this design's refusal of research owner-minute conversions.
- 20261002T192143Z-b38af3f, [BG] burn × contention factor (1 512 core-min/day × 0.025): the same duplicate.
- 20261002T192143Z-b38af3f, [BG] worker-pick launches (2 098–2 427/day): the design already uses these actions-log counts.
