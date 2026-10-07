# Harness doctor

Status: built 2026-09-28. `bin/harness-doctor` is the collector, `M.harnessDoctorEntry` in
`hammerspoon/llm-limits.lua` is the renderer (shown under the Automation menu's `Doctors` entry by
`hammerspoon/doctors.lua`), and `launchd/com.egor.harness-doctor.plist` runs it
every 5 minutes. Tests: `tests/test_harness_doctor.sh` and the Harness case in
`tests/llm_limits_renderer_harness.lua`.

Egor's brief (2026-09-28): one menubar block for everything that is **not** the model and makes a
chat or worker wait, or slows the machine for everyone. That covers hooks, tests, machine load,
state that grows with history, and the edit or release that made any of them slower. It must be
readable at a glance: numbers in aligned columns, problems in red, each row saying what it affects.
The `Test time (temp)` experiment is folded into it.

Why it exists: for six days a PostToolUse hook's 10 s timeout added 7-8 s to every tool call of every chat, and nothing on the
machine showed it. The collector's backfill later found an earlier, unnoticed episode, 09-07 to
09-15, with trivial-Bash medians of 11-58 s.

## 1. Boundary

| belongs to | examples |
|---|---|
| **Harness doctor** | tool-call wait per project, hook time and hook cuts, session-start and turn-end hooks, memory guard, test time, stores that grow with history, the change that preceded a red row |
| **System doctor** | machine rows, since 2026-10-06: new processes, the kernel share, swap, compression, SSD writes, crashes, whole-machine CPU (`docs/system-doctor-design.md`); Harness keeps the busy, unaccounted, kernel and fork samples for its Load rows, week table, day summaries and change impact, and judges none of them |
| **LLM doctor** | API decode speed, time to first token, API time per cell or leg, failures, weather |

The block never shows API numbers. A future stage hands the transcript pass's API timings to LLM
doctor (§8).

## 2. What the block shows

The top-level entry is one line: `Harness doctor: OK` (dim) or `Harness doctor: N problems` (red),
plus `· stale N min` once the data is over 30 minutes old. N is the document's `problem_count`:
problems in state `new`, `open` or `regressed` (§10), so a second red row in one area counts too.
Each area line counts its own problems the same way: every problem carries the one area that
judged it (`group`), so the area lines sum to N.
`Harness doctor: blind · <areas>` (dim) means an input is missing, and `Harness doctor: error · …`
(red) that the collector failed. Its submenu is a dashboard, one line per area:

```
Waits: ok · a Bash call waits 1.7 s, fine under 3.0 s
Slow periods: watch · tool calls were slow 20 h 19 min of the last 24 h, last until 22:00
Hook waits: 1 problem · 10 trivial Bash calls waited 375 ms on hooks in the last hour · since 14:40
Hooks: 3 problems · 52 tool calls waited 1.5 s for commit-journal in the last hour · since 00:12
Load: 1 problem · 5.3 of 10 cores go to short-lived processes and the kernel · since 22:27
Tests: ok · 284 runs today, 10 h 08 min of wall clock, none slower than usual; 3 running now
Growth: 1 problem · logo-vectorizer-bench: 16 433 loose git objects slow its git, limit 13 400
-
24 h vs prev 24 h · worse, better
changes, 7 d
not measured
-
as of 23:12
window: 24 h
Refresh
```

Each area line opens its own submenu: for a problem, first the line `started HH:MM · N changes
before it` that opens those changes, then one table, then a separator with the navigation rows.
There are no description lines and no footnotes: Egor does not read them, so a row is a label, a
number whose unit sits in the header, or a state, and `section()` has no field a sentence could go
into. An inventory is capped at 20 rows (`top 20 of N …`), `latest 10` tests, and the last 20
changes, so the block's `menu.txt` stays near 300 lines.

| area | state comes from | table |
|---|---|---|
| **Waits** | the worst of short Bash per project (top 5 by calls, plus any not fine), Edit/Write, Read and the sampled chat events | calls 1 h · wait s 1 h · wait s 7 d · cuts 1 h |
| **Slow periods** | `watch` when `local_slow` has a window in the last 24 h | from · to · lasted min |
| **Hook waits** | the floor a call waits on hooks (§3.2): a problem when a class's 1 h median, ≥ 5 calls, is over its red limit; a watch over the note | class (Bash · trivial, Bash · other, Edit/Write, Read, other tools, message, turn end, subagent end, chat start, compact, chat end) · calls 1 h · wait ms 1 h · wait ms 24 h · set by 1 h; each row drills into its Pre and Post side with p95 and the hook that set it; a nav line gives the share of tool batches joined to their call |
| **Hooks** | a synchronous hook slow this hour or cut is a problem; one slow over 24 h, a failed fast-path probe, or any watch reason of §3.3 is a watch | hook · when · median ms 24 h · min 24 h · cuts 24 h (a script run by several events is one row, `when` naming the first `+N`; the statusline and each `menu build: <menu>` are rows of their own, a menu build red over its band); nav lines `on every tool call`, `full work on trivial Bash`, `by transcript size`, `by repositories in the chat`; lead line `fast paths` |
| **Load** | CPU busy, unaccounted CPU, memory guard | last hour · 7 days (shown once the samples cover more than 1.5 h) |
| **Tests** | a group's last run over twice its usual and within 6 h, 5+ suites at once in the last 6 h (`suites at once, 6 h: N` above the table), a test that failed under load in the last 6 h (`failed under load, 6 h: N`, §3.3), a suite over half of its repository's latest full run (`long pole, 24 h`, L), or a suite over 2 h of wall clock in 24 h (`daily cost, 24 h`, L), or a suite that hung in 24 h (`hung, 24 h: N`, L) | test · repo · runs today · min today · usual min · last min; `long pole` drills into repo · long pole · min · min over next · share of run, `daily cost` into suite · repo · runs · min 24 h · min a run |
| **Wait classes** | every wait of the wait journal (§12, row `ed`): a class red when today's longest wait passes its limit or today's total passes twice its usual day; every class shown dim even when normal; a lead line counts the processes worker runs ended today left behind outside their own tree (`worker-stats/runs.jsonl` `orphans`, row `ec`), red past `worker_orphans` | class · waits today · total today · p50 · p95 · max · usual day, 7 d; each drills into its days |
| **Growth** | loose git objects over the limit, a big store that doubled in a week, or a hook spool file older than 30 min (the collector stopped folding); a watch for a per-call store over 1 000 entries that doubled in a day (its cleanup stopped) | store · entries · a week ago (once a week of samples exists) · size MB |

### 2.1 Row grammar

- An area line is `Area: state · fact` (the menu convention in
  `docs/handoffs/2026-09-30-menu-consistency.md`). The state is `N problems` (red), the area's
  problems counted as the title counts them, or one of these words: `watch` (normal colour; also
  an area whose red rows the ledger dismissed or holds as fixed-pending), `blind`, and `ok` (dim,
  the area name undimmed). A problem no area judged has a line of its own in the same grammar:
  `Limiter holds` (its hold lines inside), `Collector`, `Ledger`.
- The fact is one plain sentence Egor can act on: the row that decided the state, its number with
  the unit, and the limit or the usual value beside it (`waits 22 s, fine under 3.0 s, only 2
  calls`). It names no hook, script, file or internal term: a row whose own `say` does carries a
  plain `head` for this line, and the submenu rows keep the detail. A problem that started after the collector's first run ends with `· since HH:MM`.
- Levels: `problem` means a hard limit broken on the last hour. `watch` means a soft limit, or a
  hard one on too few calls or over 24 h. A fixed problem clears within the hour.
- A submenu shows one table of at most 5 columns. The unit sits in the header (`wait s`,
  `median s`, `today min`, `size MB`) and the cells are bare numbers. Rows of different quantities
  (Load) carry the unit in every cell instead. A column with no data yet is left out rather than
  filled with dashes.
- The cause is attached to the problem: `started 22:27 · 26 changes before it` opens the changes
  of the 6 h before, each with the short Bash median and new processes/s as `before→after`. It
  names candidates, not a proven cause. A problem present at the first run reads `started before
  HH:MM · cause unknown`.

### 2.2 Period against period

`<W> vs prev <W>` is Token tracking's comparison for this block, over the window LLM doctor's
picker selects (3 h, 6 h, 12 h, 24 h, 3 d, 7 d; default 24 h). One selection serves both doctor
blocks: `window: <W>` sits at the bottom of each, above Refresh. Choosing it in LLM doctor re-runs
that collector; in this block it only switches which precomputed comparison shows. The columns are
`<W> · prev <W> · Δ`, the Δ text and tone are tokenmap `tracking.py`'s `delta` (`×N` from 11 times,
a tone only from 10 %), worse red and better green. The line names them without a count: `· worse, better`.

- The current period is `[now − W, now]`, the previous one `[now − 2W, now − W]`.
- `3 d` and `7 d` read the day summaries: today and the N − 1 local days before, against the N
  before those. Medians come from the merged day histograms; rates divide by the days covered,
  today counting as its elapsed share; load rows are the mean of the daily means.
- The hour windows read the raw rows: `c` rows of `events/` for the waits, `h`/`x` rows for chat
  start and turn end (as the Waits area pairs them), the `slow` windows in `state.json`, the hook
  journal's 10-minute slots for hook time (a slot counts when its midpoint is in the window;
  spool runs included), the floors of §3.2 for hook wait, `samples.jsonl`
  for load and the test history. A rate divides by the days the source covers, so every window
  keeps the per-day unit; load rows are the mean of the samples.
- A tone needs 20 runs in each period for a median. A rate or a mean needs 2 covered days at 3 d,
  3 at 7 d, and half of each period for an hour window (the sources' first row or file, samples
  counted by 5-minute slot).
- Rows: Bash, Edit and Read wait, chat start and turn end, hook wait ms (tool-call floors merged,
  turn events left out), slow h/day, hooks h/day, CPU busy, kernel, new processes, unaccounted
  cores, tests h/day. Bash opens per project, hook wait per floor class, hooks per hook (median
  ms), tests per test (median min). Floors reach a day summary once the day ends; the hour windows
  read them from `state.json`.
- `by week`, under `7 d` only, shows the same rows over 8 calendar weeks, Mon–Sun, the current one
  partial.
- Waits history reaches back 28 days (the transcripts), the raw events 8 days, the hook journal
  3; hooks and load start with their first row, so their previous period fills in over time.

## 3. Signals

| row | source | metric |
|---|---|---|
| Bash · project | transcripts (`~/.claude/projects`, incremental) | tool_use → tool_result of a **trivial** Bash call. Every pipe segment starts with ls, cat, pwd, true, echo, head, tail, wc, date, stat, file, test, which, basename, dirname, printf, grep, sed, awk, jq, cut, sort, uniq, tr, readlink or realpath. There is no `;`, `&`, redirect, backtick, `$(` or `||`, no recursive grep and no `sed -i`. `2>/dev/null`, `>/dev/null` and `2>&1` are ignored. |
| who counts | transcript `entrypoint` and `permissionMode` | sdk-cli counts as a worker; cli or desktop in bypassPermissions counts as a chat. Any other call may include a human's permission wait, so it is left out of the waits. |
| project | transcript `cwd` | the git toplevel's basename, with worktrees folded into their repository; the home directory is `~` and scratch paths are `tmp` |
| cut | `hook_cancelled` attachments | PreToolUse, SessionStart and UserPromptSubmit carry the command, duration and timeout. PostToolUse carries only the tool-use id, so the hook is inferred (§3.1). |
| hook median, total | the hook journal (§5.1) | every run of every hook that sources `hook-time.sh`; for a hook outside it, `hook_success` attachments of runs that printed. Total is the time the hook ran, summed: hooks on one event run together, so it is cost, not wait |
| statusline render | the statusline journal (§5.1) | median per render and total per 24 h, once the statusline writes its line |
| hooks can hold a chat | settings.json | a synchronous hook with no timeout (the default is about 600 s), or one whose script renices itself (`renice` or `nice -n`) |
| CPU busy, kernel | `host_statistics` ticks via ctypes | the delta since the previous run, valid when the gap is ≤ 1 h (a run takes minutes under load); wrap at 2^32, reboot dropped |
| new processes | spawn `/usr/bin/true`, wait 2 s, spawn again | PID delta mod 99 999 ÷ elapsed. There is no sysctl fork counter. |
| unaccounted CPU | busy × ncpu − the visible cores in memlogd's `chats.json` title | CPU that per-process sampling misses: short-lived forks. The title parse is fragile coupling. |
| memory | `kern.memorystatus_level` and memlogd's guard alarm | red on the guard alarm |
| tests | `~/.cache/claude-statusline/test-history.jsonl`, written by `bin/statusline-work-probe.sh` for every test it saw end; `ok` (true/false) when the writer knows the outcome; `suite_secs` on a `suites` run, chat or worker, from its `.status` files | wall clock is the union of overlapping runs, so parallel suites are not double-counted |
| running now | `~/.cache/claude-statusline/work-*` newer than 30 s | the `main tests` lines |
| growth | daily sample | entries and bytes of the instruction-watch reverts, read-only notes, inflight and closed marks and temp leftovers (`*.tsv.<n>`), the review journal and its `.hashes`/`.ref` files, context-nudge state, statusline cache, review benches, this doctor's state and the transcripts, plus `git count-objects` per repository seen in the last 7 days; the hook spool's file count and oldest age live, every run |
| cause | collector state | first-red time per row key, attached to the area it decides. A row red since the collector's first run claims no cause. |
| change log | collector | content hashes of `~/.claude/hooks` (resolved to claude-setup), llm-legs `bin` and `share`, and every hook script in settings.json; hooks added, removed or re-timed; Claude Code versions by first sight |

### 3.1 PostToolUse cut attribution

A cancelled PostToolUse hook is not named in the transcript. The collector takes the call's
latency L and blames the synchronous PostToolUse hooks matching the tool whose timeout T satisfies
`L − max(3, 0.2·L) ≤ T ≤ L + 1`. Among those candidates it picks the largest T; ties are listed
with `|` and counted as `+N?` on each tied hook. Cuts from before the settings.json mtime count
as `cut, hook unknown`, because they ran under other timeouts. That rule is what stopped the 09-22
incident's cuts from being blamed on today's report-flush and commit-report.

### 3.2 Hook waits: the floor a call pays

Hooks on one event run in parallel, so a call waits for the slowest of them, not their sum.

- **Batches**: journal runs (`hooks/*.tsv` and the folded spool runs, `hooks/folded/*.tsv`) are
  grouped per ppid in start order. A run joins the open batch when it starts within 1 s of the
  batch's first start, its key is not in the batch yet, and some (event, tool) the settings allow
  for it is allowed for every run already in. A batch's floor is last end − first start; the hook
  with the latest end set it.
- **Join to the call**: a Pre batch belongs to the transcript tool_use whose time lies 50 ms after
  to 500 ms before the batch's start (measured: p50 34 ms, p95 91 ms). A Post batch belongs to the
  call whose tool_result lies 50 ms before to 3 s after the batch's end. A ppid's session is the one
  its unique Pre joins name (≥ 2 votes and ≥ 60 %); later joins keep to it, so two chats sharing a
  second do not swap calls. 85–87 % of live tool batches join; the line
  `tool batches joined to their call, 24 h` shows the share.
- **Floor per call**: Pre floor + Post floor, counted only when every side the settings expect was
  joined. Classes follow the Waits area: Bash trivial and other, Edit/Write, Read, other tools.
  Turn events (UserPromptSubmit, Stop, SubagentStop, SessionStart, PreCompact, SessionEnd) are
  their batch's floor. Floors older than 10 minutes go into the day's summary.

### 3.3 Hook cost, per hook

Each is a watch on the hook's row, with its reason in the row's sentence, checked in this order
after the red and >1 s rules. B and E read only journaled runs: `hook_success` samples come only
from runs that printed, so their median is biased.

| class | rule |
|---|---|
| E, synchronous | a synchronous hook's median over 150 ms: over 1 h with ≥ 5 runs, else 24 h |
| B, every call | a hook matching `*` or every tool (`every_call`) over 50 ms; `on every tool call` ranks them by median × calls a day |
| F, transcript size | the joined runs split by the transcript's size at the call (the tool_use's byte offset): ≥ 10 runs under 1 MB and over 10 MB, the big median ≥ 1.5 × the small and 20 ms more; subagent transcripts are left out |
| F, repositories | the joined runs split by the line count of the chat's `~/.cache/claude/review-journal/<session>.repos` (never pruned; review-flow-gate walks it) at the run's time: ≤ 2, 3-4, ≥ 5 repositories, same rule as transcript size. The collector keeps each active chat's count history in `state.json` (`journal.repos`); a run before the first count takes that count |
| C, full work | a Bash hook's joined runs on trivial calls against the rest: ≥ 10 each, the trivial median over 10 ms and ≥ 0.8 × the rest, over the last hour when the hook ran on a Bash call in it, else over 24 h; the table shows both, so a fix shows within the hour |
| I, menu build | `menu/<YYYY-MM-DD>.tsv` lines `start_us end_us menu`: a problem when ≥ 3 builds in the last hour have a median over 300 ms, a watch over 100 ms in 24 h |
| D, silent fallback | every quiet `. lib 2>/dev/null` / `source lib 2>/dev/null` in a settings hook script is resolved and loaded under the hook's shell (`/bin/bash` or `bash`); a library that does not load is red, and a known fast path whose probe answers wrong is red (`readonly-command.sh`: `ls` read-only, `rm x` not). One line `fast paths: N quiet libraries load` leads the area; the probes run in parallel, about 50-100 ms |
| H, load failure | a failed test (`ok: false`) with ≥ 3 suite runs overlapping it and a passing run of the same test with at most one other run overlapping, within the hour after; red for 6 h (`failed under load`). A run with a memory-guard `KILLED <epoch>` line of memlogd's day log (`$MEMLOGD_DIR/YYYY-MM-DD.log`, written by chat-load) within 5 s of its span is left out: the guard, not load, ended it |
| L, long pole | a `suites` history row's `suite_secs` (each suite's seconds, off its `.status` files) on the latest full run (`full` or `all` scope) of each repository in 24 h: the longest suite's share of the run's wall clock and its lead over the next suite. Over half is red once the suite takes 5 min, a watch below; the fix is to split it into parallel shards |
| L, hang | a run-suites journal suite ended by its per-suite bound (rc 124 in a `suites` row), or killed by a signal (rc 128+N, any row) after running at least that bound, recomputed as `share/run-suites.sh` `suite_bound` does, in 24 h: red from the first one, never normal load. The fact names the count, the seconds lost, the run or session and the TIMEOUT log under `$TMPDIR/run-suites.*/`. A run-suites run killed as a whole drops its running suites from the row, so their hang is unseen |
| L, daily cost | each suite's runs in 24 h, alone or inside a `suites` run's `suite_secs`, summed: over 2 h is red, over 1 h a watch; the top 20 are shown as data. A `suites` run without suite times (older rows) is one unattributed menu row, never judged |

## 4. Limits and their calibration

The limits sit in one `LIMITS` table at the top of `bin/harness-doctor`. The calibration comes
from this machine on 2026-09-28, from the 28-day backfill and a day of samples:

| limit | red | note | evidence |
|---|---|---|---|
| tool call median, 1 h, ≥ 5 calls | > 5 s | > 3 s | the healthy daily median was 1.5-3.5 s (Sep 1-22), 10-11 s during the incident, and 11-58 s during 09-07..09-15 |
| cut share, 1 h | ≥ 3 cuts and > 1 % | – | a healthy day has 0 cuts |
| event median (session start, …), ≥ 3 | > 5 s | – | the SessionStart baseline hook cut at 10 s on every start in the incident |
| hook p50, ≥ 5 samples | > 1 s | – | healthy printed hooks run at 0.1-0.6 s |
| hook wait (floor), trivial Bash, Read, other tools, 1 h, ≥ 5 calls | > 300 ms | > 150 ms | 09-29 replay: trivial Bash 375 ms (1 h), 711 ms (24 h) before the fix; one call at 133 ms after |
| hook wait, Bash other and Edit/Write | > 500 ms | > 150 ms | these calls need the snapshot and the tripwire: 451 / 303 ms before, 354 / 410 ms after |
| hook wait, a turn event | > 1 s | > 150 ms | chat start 517 ms before, 948 ms after (SessionStart runs the baselines) |
| synchronous hook median (E) | – | > 150 ms | instruction-watch check 256, baseline 673, worker-launch-gate 167 ms before; check 145-150 after |
| hook on every call (B) | – | > 50 ms | context-nudge 79 ms (1 h) before, 62 ms after the 64 KiB tail; statusline-workdir-hook 55 ms |
| full work (C) | – | trivial ≥ 0.8 × rest and > 10 ms | 12 of 12 journaled Bash hooks before |
| transcript size, repositories (F) | – | big ≥ 1.5 × small and +20 ms | live 09-29 20:15: review-flow-gate 255 ms with ≤ 2 repositories, 333 ms with ≥ 5 (1.3 ×, shown, not flagged); report-flush 54 → 183 ms is flagged |
| menu build (I) | median > 300 ms, 1 h, ≥ 3 builds | > 100 ms | 100 ms is the classic limit under which a response feels instant; a menu that opens 300 ms late is a visible stall, which is how Egor noticed the Automation menu on 09-29. No build had been timed before |
| per-call store (G) | – | > 1 000 entries and × 2 in a day | the stores hold live or recent calls: 4-51 instruction-watch marks, 436 context-nudge files, 723 review-journal `.hashes`/`.ref`/`.heads` on 09-29 |
| failed under load (H) | ≥ 3 suites at once, passed alone within 1 h | – | 09-29 17:38-18:04: three `run-all` at once failed `test_claudeb.sh` and `test_worker_run.sh`, both passed alone by 18:15 |
| hook spool, oldest file | > 30 min | – | the collector folds every 5 min; 152-396 files, all under 5 min, is normal |
| suite runs at once, peak over the last 6 h | ≥ 5 | ≥ 3 | a daily peak of 3-4 is normal, because `run-suites` runs ncpu/2 in parallel |
| a test group's last run | > 2 × its usual and > 10 min, with ≥ 3 runs of its scope | – | usual = the median of the earlier runs of the same scope (full, all, changed, named or partial, §8) once the test marks its partial runs, else their p75: test_worker_run's full runs take 7-21 min and its partial ones 21-197 s, and a median over both (≈ 4 min) turned an ordinary 614 s full run red |
| long pole (L), latest full run in 24 h | one suite > 50 % of the run's wall clock and ≥ 5 min | > 50 % under 5 min | the brief of 2026-09-30: `test_worker_run.sh` bounds llm-legs `run-all` (81 suites, `-j 5`); the calibration replay's full run, its suites' times from `run-suites/times.tsv` of 09-30 in the 678 s wall clock of that day's chat run, reads it at 649 s, 96 %, 310 s over `test_instruction_gate.sh`. Under 5 min a split saves at most 2.5 min a run, so it stays a watch |
| daily cost (L), 24 h | > 2 h | > 1 h | 2 h is a quarter of an 8-hour day of one agent waiting on one suite. The history of 09-26..30 shows one or two suites a day over it (`test_worker_run` 106-150 min alone, `test_instruction_gate` 99-167 min) and the next three at 60-100 min, which stay watches; the calibration replay reads 173 min and 145 min |
| loose git objects | > 13 400 | > 6 700 | logo-vectorizer-bench had 16 430 and llm-legs 8 113 |
| any other store | > 50 000 entries or > 1 GiB **and** × 2 in 7 days | big alone | a store that is only big is shown as a note, not a problem |
| the same stop-hook ask again (`stop_repeat_s`) | within 30 min | – | llm-doctor's `hooks_health` value, moved as is (§11) |
| stop-hook asks deferred by one reason (`ask_deferred_s`) | ≥ 2 h | ≥ 1 h | same |
| no stop line, or no tripwire baseline, while chats ran (`silent_s`) | > 6 h | > 3 h | same |
| instruction-file growth no gate passed (`growth_min_b`) | > 120 B | ≥ 60 B | same |
| instruction-watch heartbeat age (`watch_tick_s`) | > 2 ticks of 120 s | – | same |
| worker-run orphans ended today (`worker_orphans`) | > 3 | – | the first one, 2026-10-05: a `bash -x tests/test_slots.sh` reparented to launchd before its run ended held the landed worktree 14 min later; a few a day are information |

The limits are absolute. A self-adjusting baseline is what let LLM doctor's `mark_slow` absorb the
09-22 step, so `wait s 7 d` is shown next to the current value but never lowers a limit. Every
rule emits its `value`, `limit` and `near` (p50/p95 of the values it judged), so a cost under its
limit stays visible and can be ranked. `tests/test_harness_doctor.sh` pins this table (`PINNED`):
raising a value fails it, and a loosening goes to the owner chat as a handoff.

Below the red band, since 2026-09-29: one or two cuts of a hook or a call in the hour are a watch,
and a test run over 2 × its usual but under 10 min is a watch. The collector's own run is judged
too, since 2026-10-07 on its own CPU (wall stays context): over 20 CPU-s (`collector_cpu_s`), except the
first backfill, is a problem.

Machine load is weather (Egor, 2026-10-05): `load:busy` and `load:unseen` are shown, never judged
(2026-10-07). Each sample records the run-suites and night-fixer slots a live process holds (`held`).
A full `suites` run that another run-suites run of
the same `repo_root` overlapped (`runs.jsonl`) stays a watch however slow, and `suites at once`
counts the runs that journal holds as well as `test-history.jsonl`.

The hook-wait bands come from the hand-off of 2026-09-29 and were replayed with `--json` on the
preserved journal (`~/.cache/harness-hook-calibration-2026-09-29/`), `HARNESS_DOCTOR_NOW` at 15:55
over all of it and at 18:26 over the runs from 18:00:

- **before**: Hook waits is a problem, trivial Bash 375 ms, set by worker-launch-gate before the
  tool and instruction-watch check after it; E names instruction-watch check, baseline and
  worker-launch-gate; B names context-nudge; C flags all 12 Bash hooks.
- **after, journal only (18:00-18:26)**: Hook waits is a watch (Bash other, Edit/Write and chat
  start over 150 ms). B still names context-nudge at 62 ms: its tail read cut it from ~90 ms, not
  under the 50 ms band, and the band stays where the hand-off put it rather than above today's
  value.
- **after, journal plus the `/bin/bash` runs (18:43-20:10, `folded-20725.tsv`)**: trivial Bash waits
  189 ms (worker-edit-guard before, commit-report after), a watch. That is a real remaining cost,
  so it stays visible rather than dim. Bash other waits 474 ms with review-flow-gate setting the Pre
  side in 56 % of calls and commit-journal the Post side; Edit/Write 655 ms (edit-conflict-notice,
  commit-journal) and other tools 486 ms (worker-limit-gate, report-flush) are red.
- **review-flow-gate before 16:00 cannot be named**: it runs under `/bin/bash` 3.2, and the
  collector kept those runs per run only from 18:43 on (`hooks/folded/` did not exist before); the
  earlier ones were folded into histograms and deleted. Its slots in `state.json` showed a median in
  the 500-750 ms bucket before and 200-300 ms after.
- **tests (L), added 2026-09-30**: `tests/fixtures/harness-calibration/statusline/test-history.jsonl`
  holds the real llm-legs `test_worker_run` and `test_instruction_gate` runs of the 24 h before the
  replay time and one full run whose `suite_secs` are composed as the long-pole row says, since the
  history kept no suite times before. The replay pins `test_long_pole` on `test_worker_run` (0.957)
  and `test_daily_cost` on both suites (8 577 s and 10 377 s; a 137 s probe duplicate collapsed).

## 5. Collector

`bin/harness-doctor` uses Python 3.9+ and the standard library only.

- **State**: `~/.cache/harness-doctor/` (override `HARNESS_DOCTOR_DIR`) holds:
  - `state.json`: per-transcript offset, size, mtime, a hash of the first 512 bytes, pending
    tool_uses, mode, entrypoint and toplevel; plus the watched file hashes, the hooks snapshot,
    the versions, first-red and first-watch times with each rule family's first evaluation (a
    rule first seen after an upgrade claims no cause), the birth time and CPU ticks;
  - `events/YYYY-MM-DD.jsonl`, kept 8 days;
  - `days/YYYY-MM-DD.json` summaries (`"v": 2`), kept 60 days, which feed §2.2 and the Waits
    `wait s 7 d` column: a histogram per waiter (`bash:<project>`, `edit`, `read`,
    `event:<hook event>`), the day's slow seconds, the hook journal's histograms per hook
    (accumulated in `state.json` under `journal.days` until the day ends) and the load means. A
    day is summarized once it ends. When the format version changes, days whose events are pruned
    are rebuilt once from the transcripts (28 days, about 25 s); `state.json` `rebuilt` records it;
  - `samples.jsonl` (8 days), `growth.jsonl` (daily), `changes.jsonl` (60 days);
  - `latest.json` and `menu.txt`.
- **Incremental scan**:
  - The first run backfills 28 days. Later runs read only new files and appended bytes, up to
    the last newline.
  - A file is rescanned from 0 when its head hash changes or it shrinks below the offset.
  - A tool_use whose result is not read yet stays pending across runs and is dropped after 2 h.
- **`local_slow`**: `latest.json` carries the merged periods in which a Waits call row (trivial Bash
  per project, edit, read) was red. They are replayed on a 5-minute grid from the events, each
  from its first slow call to the end of its last, and kept 8 days. The state holds them
  incrementally and re-evaluates the last hour each run. LLM doctor's `mark_slow` reads them to
  label a slow leg `local slow` instead of weather. The contract is row `cz` of
  `docs/shared-invariants.md`.
- **Journals** (§5.1): `hooks/` and `statusline/`, read by byte offset, histograms in
  `state.json` under `journal`, with the settled floors per local day (`floor_days`, up to
  `floor_upto`) until the day's summary takes them.
- **Call rows**: a `c` event row is `c, t, project, tool, trivial, latency, who, id, session,
  kb`; `session` is the transcript's first 8 characters (a subagent's parent), `kb` the transcript
  offset at the tool_use (none for subagents). Rows written before these fields have 8.
- **Lock**: a non-blocking `flock`. A second run exits 0 and writes nothing.
- **CLI**: `--json` prints the document and `--menu` prints the menu lines; both persist nothing.
  `--quiet` is the LaunchAgent's mode.
- **Environment**, for fixtures: `CLAUDE_PROJECTS_DIR`, `HARNESS_SETTINGS`,
  `STATUSLINE_CACHE_DIR`, `MEMLOGD_DIR`, `INSTRUCTION_WATCH_STATE`, `CLAUDEB_DIR` /
  `WORKER_STATS_DIR`, `HARNESS_WATCH_ROOTS`, `HARNESS_DOCTOR_NOW` and
  `HARNESS_DOCTOR_FAKE_SAMPLE` (JSON; an empty string means no sample).
- **Cost**: a steady run takes about 2 s wall time, most of it the 2 s fork-rate sleep. The first
  backfill took about 35 s at normal priority and 72 s under the LaunchAgent's Background priority.
- **LaunchAgent**: `com.egor.harness-doctor` runs `~/.local/libexec/harness-doctor` (source copy
  `launchd/harness-doctor`) every 300 s, with RunAtLoad, `ProcessType Standard` and `Nice 10`. Never
  `Background`: that band gets no CPU while the cores are saturated. On 2026-09-30, at load 240, one
  run got 2.7 s of CPU in 48 min, held the lock and froze the menu block exactly when load was the
  story.
  It logs to `~/Library/Logs/harness-doctor.log`. After editing the wrapper or the plist, copy
  both into place and `launchctl bootout` / `bootstrap` the job.

### 5.1 Hook and statusline journals

The contract is row `da` of `docs/shared-invariants.md`.

- **Writer**: `../claude-setup/hooks/lib/hook-time.sh`, sourced as the first code line of every
  settings hook. It records only inside Claude Code (`CLAUDE_PROJECT_DIR` set), uses builtins only,
  and leaves the exit status and stderr alone. bash 5 appends one `start_us end_us key exit ppid`
  line to `hooks/<epoch day>.tsv`. `/bin/bash` 3.2 has no sub-second clock, so it writes the key to
  `hooks/spool/<pid>.<random>` at the start and `exit ppid` at the end; the file's birth and change
  times are the run. The key is the script's basename plus its first argument, the same key the
  collector derives from the settings command (`hook_key`).
- **Traps**: a hook with its own EXIT trap calls `hook_time_end` first inside it
  (instruction-bloat-gate, limits-triage-nudge, memory-prune). A hook that `exec`s is lost, so
  cite-before-building runs its Python without `exec`. A SIGKILLed bash 5 run leaves no line; a
  3.2 run leaves a spool file without an end, folded after 15 min as unfinished.
- **Statusline**: `statusline/<YYYY-MM-DD>.tsv`, `start_us end_us session` per render, written by
  the statusline (owned by the harness-fix chat, bound by `docs/statusline-contract.md`).
- **Menu builds**: `menu/<YYYY-MM-DD>.tsv` (local day of the end), `start_us end_us menu` per
  build. `hammerspoon/llm-limits.lua` `M.menuItems` goes through `M.timedMenu("llm-limits", build)`,
  which appends the line through `M.menuJournal` with `hs.timer.secondsSinceEpoch`; every step is
  under `pcall`, and a missing folder drops the line, never the menu. A line is the time a click
  waits: a build inside `M.backgroundMenu(build)` writes none. The hammerspoon repository's
  `automation_menu.lua` answers a click through `timedMenu("automation", buildMenu)`, which assembles
  cached sections (LLM Limits, Better Terminal, Token tracking, Doctors, Reports); a background
  refresh rebuilds them one per main-thread slice under `backgroundMenu`, every 5 s while the user
  is active and every 60 s once idle, so `menu build: automation` is the click's own wait and
  `llm-limits`/`doctors` lines stop. The collector makes `menu/` on each run and prunes it after 3 days.
- **Reader**: incremental by byte offset up to the last newline; spool files are folded and removed,
  their runs appended first to `hooks/folded/<epoch day>.tsv` in the journal's line format, so the
  batch join of §3.2 sees `/bin/bash` hooks too. The key is the text up to the first tab and exit
  and ppid come from the last line, because a spool file has been seen carrying a hook's own stdout
  between them (5 `review-flow-gate.sh verdict`/`autonomous` runs on 09-29).
  Each run lands in a 10-minute slot per key: count, sum, min, max, non-zero exits, unfinished runs,
  and a histogram on fixed edges from 5 ms to 600 s. The median interpolates inside its bucket,
  clamped to the slot's min and max. Slots are kept 25 h and journal files 3 days.
- **Coverage**: a settings hook whose script does not source the lib is a blind spot by name,
  and `../claude-setup/tests/test_hook_time.sh` fails for a claude-setup hook without the line.

## 6. Renderer

`M.harnessDoctorEntry` reads `menu.txt`, never `latest.json`. `hs.json.decode` of the 40 KB document
took about 39 ms on every menu open, while the whole menu was already at about 60 ms. The laid-out
lines cost one pattern match each. The format:

```
T<TAB>red<TAB>as_of<TAB>title
depth<TAB>flags<TAB>spans<TAB>text
```

- `depth`: 0 is the block's own submenu; a deeper line nests under the line above it.
- `flags`: letters, then an optional `w<hours>` token (`dw24`). `d` is dim, `s` is a separator.
  `w<hours>` marks every line of one window's comparison (§2.2), nested lines included; the
  renderer shows an untagged line always and a tagged one only when it matches the selected window.
  `a` marks a clickable row: the text is followed by `<TAB>` and the argv joined by `\x1f`. The
  renderer runs it with `hs.task` (never a shell, never a terminal) only when `argv[0]` is
  `/usr/bin/open` or a bare name that is a file in llm-legs `bin/`; any other action leaves the
  row disabled. A row with an action is enabled and not dim; every other row stays disabled.
- `spans`: comma-separated `style:byte:bytes` entries. `r` is red, `g` is Token tracking's green
  (a better Δ), and `n` stays undimmed on a dim line (the area name of an `ok` area). Offsets are UTF-8 bytes, because the text contains `·`,
  `–` and `…`.

The collector does all the layout, padding columns by character count in Menlo, so every glyph
must be one Menlo cell: the statusline's worktree mark `⧉` is rewritten to `wt`. The renderer names
no row. It only adds `refreshing…` or `Refresh` (which runs the collector through
`startDiagnosticsTask`) and the stale suffix. Menu construction starts no task. The parsed items are
cached on `menu.txt`'s inode, mtime and size: the collector replaces the file by rename every 5
minutes, so a menu open between two runs parses nothing, and `M.harnessDoctorEntry` copies the cached
list before adding `Refresh`.

## 7. What the design review changed

Frontier round 20260928T182730Z-401a30e confirmed 31 findings against the first draft. The ones
that reshaped it:

- **The change log** watches file content hashes (hooks, `bin`, `share`, hook scripts), not only
  settings.json. The 09-22 step came from an uncommitted edit to `share/instruction-files.sh`,
  which a settings-only log would have missed.
- **Tests** show the union of overlapping runs, not the sum: the old headline `13h 52m today`
  double-counted parallel suites. The concurrency limit was raised to 5, because `run-suites`
  launches ncpu/2 = 5 suites by design.
- **Red is judged on 1 h only.** Growth is red only on big plus doubling. The first version's
  trial showed 16 problems on a healthy evening; the built one showed 3 real ones.
- **Rescans** trigger on a head-hash change, not only on shrinkage, because compaction rewrites
  a transcript in place.
- **The memory guard** stays visible as a Load row. `appendChats` was not moved.
- **Blind spots** are listed as their own row: the review named worker-run supervise loops,
  MCP start-up and statusline render cost, which the collector cannot see yet.
- **The experiment**: `test-time` was retired through the `experiment` skill. The journal writer
  in `statusline-work-probe.sh` became permanent, and `bin/test-history`, its summary text and the
  TEMP tags were removed.

The per-hook journal and the statusline reader were built later (§5.1); the statusline writer is
the harness-fix chat's.

### 7.1 What the UX reviews changed

Egor's verdict on the first build: a giant table, columns that do not align, units that cannot be
told apart, no base picture. Two panels answered it: frontier round 20260928T195641Z-61d93ef on the
layout, and standard round 20260928T195909Z-61d93ef, which first listed the questions a user of such
a harness asks about speed without reading the code, then checked the block against them.

- Six stacked tables, each with its own widths, became one aligned line per area; the tables
  moved into the area's submenu (all cells of both rounds agreed).
- One vocabulary of three states replaced red/note/dim plus ad hoc words, and the title counts the
  same problem lines the reader sees, not rows.
- A reassuring aggregate no longer hides a bad row: a project at 22 s on 2 calls is a `watch`.
- Headers name the unit and the statistic; one-off facts (swap, the suite peak, run by chats or
  workers) moved from grid cells into sentences; `24 h` and `7 d` columns that only repeated the
  current window are hidden until the samples cover them.
- The separate Steps table, whose `now` column kept values after a row recovered, became the cause
  line of the problem it explains.
- A hook is a problem only while it slows calls this hour. `commit-report` at 6.6 s on 12 printed
  runs a day is a `watch`, and the p50 of printed runs is stated as such.
- `local_slow`, computed for LLM doctor only, became the `Slow periods` line: it answers
  "was today slow, and is it over".
- Egor, 2026-09-29: every description line went (leads, footnotes, `before→after: …`, `the latest
  N of M`), and the block got Token tracking's week comparison (§2.2), because "is this week
  better than the last" had no answer. `best day s` became `wait s 7 d`.
- 2026-09-29: the fixed week comparison became one per window of LLM doctor's picker, one shared
  selection for both doctor blocks ahead of their merge into one Doctor menu (§2.2); the suite peak
  is judged over the last 6 h, so a night burst no longer stays red until midnight.

## 8. Blind spots and next stages

The `not measured` line lists the document's `blind_spots`: the rows of
`share/harness-ledger.json` `blind_spots` (interpreter start, MCP and worker spawn and relay,
worker-run loops, launchd and Hammerspoon tasks, calls from sessions outside bypassPermissions,
spool stdout, join precision), plus the ones the collector finds:
- each settings hook with no hook-time line. Such a hook is also a problem of its own (rule
  `unjournaled`, a red lead line in Hooks) unless the ledger dismisses its exact ident; today only
  the inline SessionStart branch check is dismissed;
- statusline cost per render, while no render journal line arrived in 24 h;
- menu build time, while no menu journal line arrived in 24 h;
- word notices with no reading line, while there is no words journal.

Detection classes of the 2026-09-29 hand-off left out:
- **K, `--bench`**: a timed replay of each hook on a trivial and a writing Bash call was not built;
  the journal join (§3.2) measures the same thing from real calls.
- **Join precision**: the join is by time and reaches 85-87 % of tool batches. The tool_use_id in
  hook-time's line (contract row `da`) would make it exact; not needed while the share stays there.
- **F by repository count** is approximate for a chat first seen after its registry grew: runs before
  the first count take that count.
- **Load failures before 2026-09-29**: the history rows had no `ok` field. `ok` is written for whole
  `run-suites` runs only, so H names a failed suite run, not the test inside it.
- **Spool files carrying stdout**: 5 of 4 561 folded review-flow-gate runs on 09-29 had
  `STATUS=… LINES=…` between key and exit, which means that output did not reach its reader. The
  cause is in claude-setup (`hook-time.sh` naming `spool/$$.$RANDOM`, or the `verdict` caller's
  redirect) and is that repository's to fix; the reader here tolerates it.

Also pending:
- numeric fields in memlogd's `chats.json`, to replace the title parse behind
  `unaccounted CPU`, and a line naming the heaviest chat or daemon;
- the transcript pass's API timings, handed to LLM doctor under a document key, with a note to
  its owner chat;
- test scope in the history row itself: the probe (`bin/statusline-work-probe.sh`, another chat's)
  sees the script, not the env that narrowed it, so a run declares its scope in a marker
  (`share/test-scope.sh` → `test-scope.jsonl` `{start, label, scope, pid, repo_root}`, joined on
  label, `repo_root` and start within 5 s). `share/run-suites.sh` marks every `suites` run `full`,
  `all`, `changed` or `named`; a `test_worker_run_*.sh` part marks itself `partial` when a
  `WORKER_RUN_TEST_*CASE` selector it reads is set (`test_scope_narrowed` derives the set
  from the file). A run of a marked label with no marker of its own is `full`; runs are compared
  only with runs of the same scope. A label with no marker is judged against the p75 of its earlier
  runs of the same scope, a marked label against the median of its known-scope runs. The probe
  could write `scope` into the row once it reads the marker; `ps -E` was not measured and is not
  used.


## 9. The questions it answers

The standard round listed the questions a user asks about a harness like this one. Status after
the rework:

| question | where | status |
|---|---|---|
| Is something slowing my chats right now? | Waits | answered at a glance |
| Was today slow, and is it over? Is it the model or us? | Slow periods; LLM doctor marks legs `local slow` | answered |
| Which hook is the wait, and are hooks cut? | Hooks | answered: every run of every journaled hook, with a daily total |
| What does a call wait on hooks, and which hook sets it? | Hook waits | answered per tool class and turn event, split Pre and Post, for the joined 85-87 % of calls |
| Which hook costs every call, does full work for nothing, or grows with the transcript? | Hooks' nav lines | answered for journaled hooks |
| Did a hook's shortcut silently stop working? | Hooks, `fast paths` | answered for quiet library loads and the known read-only classifier |
| Did a test fail only because the machine was busy? | Tests, `failed under load` | answered once the history carries `ok` |
| Is the Hammerspoon menu slow? | Hooks, `menu build: <menu>` | answered for the whole Automation menu and its LLM Limits part |
| Is the Mac overloaded, and by what? | the System doctor; Load for busy CPU; the Chats block for chats; Hooks' totals | births and CPU attributed to our scripts by the System doctor |
| Are tests the reason? What is running now? | Tests | answered |
| Which suite bounds a full run, and which suites cost the most machine time a day? | Tests, `long pole, 24 h` and `daily cost, 24 h` | answered for runs journaled with `suite_secs` (from 2026-09-30); older `suites` rows stay unattributed |
| Did a change make it slower? | the cause line of a problem; `changes, 7 d` | candidates ranked: the change naming the red row's hook or script first, then the biggest step in the measure of the rule that went red (hook wait ms for floors and hooks, CPU busy for Load, suite min for Tests, short Bash s otherwise), then the nearest; watched: `~/.claude/hooks`, llm-legs `bin`, `share`, `hammerspoon`, `~/.hammerspoon`, every settings.json key |
| Is a growing store slowing things? | Growth | size and limit answered; the 7-day trend appears after a week of samples |
| Is this week (or these hours) better than the last? | `<W> vs prev <W>` over the picker's window, `by week` | answered for waits (28 days back); hooks and load from 2026-09-29 on |
| Why did my worker finish late? | – | missing: needs worker-run stage timestamps minus LLM doctor's API time per leg |
| Is the statusline eating the machine? | Hooks, `statusline (not a hook)` | reader built; a blind spot while no render journal line arrived in 24 h |

## 10. Contract document and ledger

`latest.json` carries the envelope of `docs/doctors-contract.md` §1 next to the menu keys:
`contract`, `doctor`, ISO `as_of` (epoch in `as_of_s`), `judge`, `status`, `problem_count`,
`problems`, `blind_spots`, `self`. `red` stays the count of areas in `problem`.

- **Verdicts.** Every row that a rule judges carries `judge`: one verdict per rule with `rule`,
  `ident`, `value`, `limit`, `unit`, `window_h`, `exposure`, `level` (red, watch or none), `near`
  and up to three evidence items. The ident is identity only: `bash:<project>` or a tool class for
  waits and floors, the hook key, `<repo>:<label>` for a test (a worktree's runs fold into their
  repository through the history row's `repo_root`; a row without it outside a main checkout reads
  `worktree:<worktree>:<label>`; a long pole or daily cost names the suite file without its extension,
  which `doctor-fix` resolves to `<repo>/tests/<suite>` as the component), a slug of the store for growth. Rules: `wait`, `wait_cut`, `floor`, `hook_p50`, `hook_sync`,
  `hook_cut`, `hook_every_call`, `hook_full_work`, `hook_grows_size`, `hook_grows_repos`,
  `statusline`, `menu_build`, `fastpath`, `unjournaled`, `load`, `test_slow`, `suites_at_once`,
  `test_load_fail`, `test_long_pole`, `test_daily_cost`, `test_hang`, `store_size`, `store_runaway`, `loose_objects`, `spool_stuck`, `collector`, and
  the §11 rules.
- **Problems.** Red and watch verdicts become problems; the id is the ledger row's when its
  `match {rule, ident regex}` matches, else `<rule>:<ident>`. State: `new` (no row), `open`,
  `regressed` (evidence started after the last fix, or the whole window did), `fixed-pending`,
  `watch`. A watch under a fixed row is its proof, not a problem.
- **History.** `state.json` `seen` keeps each problem's first and last run for 30 days;
  `first_seen` resets only after a 24 h gap. `firstred`/`firstwatch` stay for the cause line.
  A problem's `count` is the events its rule judged bad in the window (each verdict's `bad`; null for
  the median and state rules the contract §6 names); `runs_red` is the collector runs in 24 h that
  judged it.
- **Ledger.** `share/harness-ledger.json`. A fixed or fixed-pending row is shown as
  `fixed · E events since · M matched` for 7 days, and while unproven. When the collector writes, it
  turns a `fixed-pending` row `fixed` with `in: repo@hash` once every file of its last fix is
  committed, and stamps `regressed_at` on a regression, both in its overlay `ledger-settled.json`,
  never the tracked file (contract §2). Before judging, `ledger_faults` drops every
  faulty row and reports it as problem `ledger:<row id>`, rule `ledger_fault`, its fact naming the
  faults; the file keeps the row. A row is faulty without `{rule, ident}` or a known status, with a
  duplicate id, or with an `ident` that has fewer than 3 literal characters, fullmatches the empty
  ident or fullmatches any of 240 seeded random idents in the real shapes (`bash:<w>`, `<w>.sh`,
  `inline-<w>`, `~/<w>/<w>.md` …); a `not-a-bug` or `weather` row's `ident` must also be one exact
  literal ident, with no regex metacharacter left unescaped.
- **Blind and error.** An area whose input is empty reads `blind`, never `ok`: Hook waits with no
  batch joined, Load with no sample in the hour, Hooks with no journal line in 24 h. An exception in
  the collector writes `status: error` with the exception and its line, and a red `menu.txt`.

## 11. Stop hooks and Guards (moved from LLM doctor)

The Hooks and Guards rows of `bin/llm-doctor` (`hooks_health`, `guards_health`) are ported here as
two areas over 24 h, rule for rule and with the same limits; `bin/llm-doctor` keeps its rows until
its owner chat removes them. Each (rule, ident) is one row and one problem `<rule>:<ident>`, with
up to three events as evidence (`stop:<ts>/<session>`, `words:<ts>/<session>`, `gates:<at>/<gate>`,
`events:<at>/<file>`, `heartbeat:<mtime>`, `transcripts:<mtime>`).

- **Stop hooks** reads the stop journal (`STOP_GATE_JOURNAL`, `~/.cache/claude/stop-gate/journal.jsonl`)
  and the words journal (`WORDS_DIR`). `hook-error`, `hook-held`, `ask-busy` and `ask-repeat` are
  keyed by hook; `ask-deferred` by a slug of the deferral reason (`busy <task>`, `stop hook active`),
  its streak ending where a stop line's `pid` repeats after a change (a resumed chat, not a per-call shell);
  `word-miss` by the word hook; `reading-miss` is `unprompted`; `stop-silent` is `stop-dispatch`.
  No stop journal reads `blind`; no words journal is a blind spot.
- **Guards** reads the instruction-watch state (`INSTRUCTION_WATCH_STATE`): `gate-fault` keyed by
  gate; `growth-denied` and `growth-ungated` by the root the file grew under, with the home as `~`
  and the worktree segment dropped, or `between-sessions`; `stamp-forged` by file;
  `changed-while-watcher-off`, `baseline-missing`, `dropped` and `baseline-silent` are `tripwire`;
  `watcher-down` is `never-started`, `stale`, `error` or `no-root`. No state directory reads `blind`.
  Not judged: ungated growth of a skill or plugin under `~/.claude/{skills,plugins}/synced/<bucket>`
  that the bucket's `manifest.json` lists, with a `lastUpdated` within 15 min of the growth or the
  entry's `updatedAt` (vendor version time) up to 1 h before it; growth that re-lands bytes the same real path grew by, or a gate priced, in another checkout
  within 24 h (a merge, patch or copy between a worktree and its main checkout), each sibling growth
  excusing one landing of its bytes; ungated growth git delivered, i.e. the file's repository reflog
  shows a checkout, merge, pull or rebase in the 24 h before the growth (60 s after it allowed) to a
  commit whose blob the file still holds, shown as one dim `upstream instruction growth · <repo> · +N B`
  row per repository (incident 2026-10-05: one release checkout read as 55 problems); a `baseline-missing` whose sid no chat transcript owns. Known
  hole: a hand edit to a listed synced skill followed by a content sync of that bucket reads as the
  sync. The write gate reads a program file run by path (`python3 $S/x.py`, 256 KB) as one inline
  program, and a guarded directory literal joined through a variable (`C + n`, `Path(C) / n`) as a write
  into it. Unread, so only the tripwire reports them as `growth-ungated`: a name built at run time from
  no guarded literal (`'CLAU'+'DE.md'`), a prefixed literal (`r'…'`, `f'…'`), an annotated assignment (`p: str = '…'`) and perl's parenthesis-free `open my $f, ">>", $p`.
- **Growth roots.** One change is one problem per root: the skill directory (the nearest one holding a
  `SKILL.md`), else the `docs` tree it sits in, else the file. Its value is the bytes the change added
  under that root, its count the files, and the files are listed in the evidence. Incident
  2026-09-30 13:32: one install of third-party skills under `~/.claude/skills` read as 233 problems.
- **On-demand skill files are out of scope.** The rule prices context that loads into every chat
  with no audit. Only a skill's own `SKILL.md` loads that way. Its `references/` and other files load
  when the skill runs and its `SKILL.md` points to them, and the rule still watches that `SKILL.md`.
  Their growth is left out of the value and the count, and the evidence names how many were left out.
- **Deploys** compares every copy in `DEPLOYS` (shared-invariants row ef) with its source in the main
  checkout (`HARNESS_DEPLOY_SOURCE`; deployed wrappers under `HARNESS_LIBEXEC_DIR`, default
  `~/.local/libexec`): a byte copy must match, a generated wrapper must exec the source script, a
  generated plist must run its wrapper. A group none of whose copies exists is not installed and not
  judged; a missing or differing copy of an installed one is `deploy-drift` keyed by the copy, its fix
  the installer command. Incident: memlogd ran a 28 Sep copy without `machine_tick` for a week.
- **Browser** reads only what the supervisor writes — `WORKER_RUN_DIR`'s `browse/accounts.json` (enrollment) and
  `browse/log.jsonl` (one line per browser run, 7 days) — plus Dia's process arguments; never a file a browser
  writes (Chrome and Dia rewrite theirs live: a compacted leveldb hid a device, 2026-10-06). One row per enrolled
  account (`Profile 1 · ok · proven 2 h ago · 72 h: BROWSER_INTERRUPTED ×1`); `browser-account` watches a
  `needs-login` (fix: the login brief), another non-ok status or 7 days without a success (fix: `--enroll`);
  `browser-repair` is red for a 72 h workaround, `HARNESS_NEEDS_REPAIR` or `missing`; `browser-applescript-js`
  watches a Dia without its JS flag. A writing run starts `worker-run browse --canary` (`HARNESS_BROWSE_CMD`)
  detached when `browse/canary.stamp` is older than 23 h; the canary's receipts land in the same log.
  A running Dia without the flag adds a clickable `Restart Dia with AppleScript JS — unsaved input may be lost`
  row → `bin/dia-js --relaunch`: Egor's click, never the collector.
- Two differences from llm-doctor: a value between half the limit and the limit is a watch (deferral,
  silence, growth), and a growth value is the largest single change under one root, not the day's sum.

## 12. Limiter holds

Any mechanism that holds work (waits, never denies: a deny already reaches its caller) tells the
chats it holds and Egor. Incident 2026-09-29: `logo-vectorizer-bench/bench/throttle.py` held every
job of one chat for about 4 h under memory pressure and nothing reached Egor.

- **Path.** `${HARNESS_HOLDS_DIR:-${HARNESS_DOCTOR_DIR:-$HOME/.cache/harness-doctor}/holds}/<limiter>-<pid>[-<key>].json`,
  one file per held job. `key` is optional and required whenever one process holds several jobs
  at once (threads, background subshells sharing `$$`): per thread, so one job acquiring never
  clears another's file. Invariant row `dc`.
- **Format.** `{limiter, pid, held: {what, session, cwd}, since, why, until}`: `since` and `until`
  are unix epochs, `until` null when unbounded, `session` the `CLAUDE_CODE_SESSION_ID` if known.
  Written to `<file>.tmp` and renamed; removed when the hold ends, on every exit path.
- **Stale.** A hold is live only while its pid runs a process that started no later than `since`
  (+2 s for `etime` rounding; `ps -o pid=,etime=`): a dead pid, or one reused by a later
  process, is a leak. The doctor reports it once (`limiter_hold_leak:<limiter>`, a watch) and a
  persisting run then deletes the file; a SIGKILLed or SIGTERMed holder cannot clean up. The
  writers install no signal handler: Python allows one only on the main thread, where
  `throttle.py`'s pool threads never wait, and a host's own handler must stay.
- **Writers.** `share/limiter-hold.sh` (`hold_raise <limiter> <what> <why> [until] [key]`,
  `hold_clear`, needs jq) and `share/limiter_hold.py` (`key=`): a few lines each, copied or
  sourced, nothing of llm-legs but the path; hold I/O never raises into the limiter or fails a
  `set -e` caller, a failed write leaves no `.tmp`, and a non-finite or non-numeric `until` is
  written as null.
  `throttle.py` carries a copy keyed by `threading.get_ident()`.
- **Doctor.** Rule `limiter_hold`, id `limiter_hold:<limiter>`, one problem per limiter however
  many files: value the longest live hold, count the held jobs (live files), evidence one hold file
  each, fact `<limiter> holds N jobs, longest <wait>: <why of the longest>`. A watch from 60 s; red
  only while `bin/chat-load` judges the queue stuck (`chats.json` `queues[].stuck`, a snapshot under
  600 s old): no job of that limiter got its slot for `queue_stuck_s` (1800 s). A long wait in a
  queue that moves is a benchmark doing its job, not a problem; the incident was a queue that never
  moved. A line per judged limiter, inside the `Limiter holds` line, names what it holds, for how long and why.
- **Menu.** The holds live inside `Chats/other` (`docs/memory-guard.md`): `⏳<jobs> <longest>` on the
  row of the chat whose process waits, a `queued <limiter>` row for one no chat launched, red with
  the `Chats/other` title only while the queue is stuck. The LLM Limits menu draws no hold line of
  its own.
- **Title alert.** The one existing path: `~/.hammerspoon/automation_menu.lua` `refreshTitle`
  (every 30 s) prefixes the menubar title with ⚠ from `llmLimits.refreshState().warning`.
  `refreshState` sets `warning` while a fresh `chats.json` (≤ 120 s) holds a stuck queue and
  carries its text as `holdText`, plus `refreshWarning` for the refresh's own warning.
  `refreshTitle` shows ⚠ for a stuck queue even while a refresh is busy (⟳ otherwise), and its
  tooltip carries the queue's text and, when both hold, the refresh warning's under it;
  `refreshState().prefix` follows the same order.
- **llm-legs limiters.** `share/slots.sh` `slot_wait` writes one: `run-suites` (at most
  `RUN_SUITES_SLOTS` suite runs machine-wide: cores / 3 clamped 2–4 always, up to 4 while `slot_room`
  finds room) and `night-workers` (`worker-run` on a `night/*/*` branch, `NIGHT_FIXER_SLOTS`: cores / 2
  clamped 2–8 always, up to the cores capped at 12 while `slot_room` finds room; `run_suites_slots` and
  `night_worker_slots` in `share/slots.sh`). Room only adds slots above the old defaults. Room = memory pressure normal, available
  memory above `bin/chat-load` `GUARD_AVAIL_MB` + `SLOTS_ROOM_MB` (1500), and load1 within the cores of
  load15 (the benchmark's base). A night worker's `started_at` stays its launch; its deadline clock is
  `slot_at`. A queued suite run is
  no test yet (no `suites-<pid>` pointer); the `worker-run` watchdog counts a live hold in its run's
  process tree as activity. **Every wait is measured** even when normal: `hold_clear`, a lock that
  slept and `worker-run wait`'s poll lag each write one `wait_note` row (row `ed`) the Wait classes area reads.
  `share/store-lock.sh` waits at most 60 s and then fails visibly; `claudeb`'s refresh convergence backoff (≤ 240 s) runs under the menu's ⟳ busy
  title; `share/run-suites.sh` queues suites behind its own `-j` inside one run the statusline
  shows as `suites n/m`; browser and deadline waits in `worker-run`/`codex-image` are bounded
  under 60 s or are kill ceilings. The gates (`worker-limit-gate`, `worker-launch-gate`,
  `workflow-burn-gate`, `worker-relay-hold`) deny or send a relay back, which the caller sees.
