# Harness doctor

Status: built 2026-09-28. `bin/harness-doctor` is the collector, `appendHarness` in
`hammerspoon/llm-limits.lua` is the renderer, and `launchd/com.egor.harness-doctor.plist` runs it
every 5 minutes. Tests: `tests/test_harness_doctor.sh` and the Harness case in
`tests/llm_limits_renderer_harness.lua`.

Egor's brief (2026-09-28): one menubar block for everything that is **not** the model and makes a
chat or worker wait, or slows the machine for everyone. That covers hooks, tests, machine load,
state that grows with history, and the edit or release that made any of them slower. It must be
readable at a glance: numbers in aligned columns, problems in red, each row saying what it affects.
The `Test time (temp)` experiment is folded into it.

The evidence behind it is `docs/handoffs/2026-09-28-speed-investigation.md`. For six days a
PostToolUse hook's 10 s timeout added 7-8 s to every tool call of every chat, and nothing on the
machine showed it. The collector's backfill later found an earlier, unnoticed episode, 09-07 to
09-15, with trivial-Bash medians of 11-58 s.

## 1. Boundary

| belongs to | examples |
|---|---|
| **Harness doctor** | tool-call wait per project, hook time and hook cuts, session-start and turn-end hooks, CPU and fork pressure, memory guard, test time, stores that grow with history, the change that preceded a red row |
| **LLM doctor** | API decode speed, time to first token, API time per cell or leg, failures, weather |

The block never shows API numbers. A future stage hands the transcript pass's API timings to LLM
doctor (§8).

## 2. What the block shows

The top-level entry is one line: `Harness doctor: OK` (dim) or `Harness doctor: N problems` (red),
plus `· stale N min` once the data is over 30 minutes old. N counts the areas in the `problem`
state, the same rows the reader sees. Its submenu is a dashboard, one line per area:

```
Waits         ok       a Bash call waits 1.7 s, fine under 3.0 s
Slow periods  watch    tool calls were slow 20 h 19 min of the last 24 h, last until 22:00
Hooks         problem  52 tool calls waited 1.5 s for commit-journal in the last hour (+2 more) · since 00:12
Load          problem  5.3 of 10 cores go to short-lived processes and the kernel · since 22:27
Tests         ok       284 runs today, 10 h 08 min of wall clock, none slower than usual; 3 running now
Growth        problem  logo-vectorizer-bench: 16 433 loose git objects slow its git, limit 13 400
-
7 days vs prev 7 · 5 worse
changes, 7 d: 164
not measured: 4 blind spots
-
as of 23:12
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
| **Hooks** | a synchronous hook slow this hour or cut is a problem; one slow over 24 h is a watch | hook · when · median s 24 h · min 24 h · cuts 24 h (a script run by several events is one row, `when` naming the first `+N`; the statusline is a row of its own) |
| **Load** | CPU busy, kernel share, new processes, unaccounted CPU, memory guard, swap | last hour · 7 days (shown once the samples cover more than 1.5 h) |
| **Tests** | a group's last run over twice its usual, or 5+ suites at once (`suites at once today: N` above the table) | test · repo · runs today · min today · usual min · last min |
| **Growth** | loose git objects over the limit, or a big store that doubled in a week | store · entries · a week ago (once a week of samples exists) · size MB |

### 2.1 Row grammar

- An area line is `area · state · fact`. The state is one of three words, each with one look:
  `problem` (the word is red), `watch` (normal colour) and `ok` (dim, the area name undimmed).
- The fact is one plain sentence: the row that decided the state, its number with the unit, and
  the limit or the usual value beside it (`waits 22 s, fine under 3.0 s, only 2 calls`). A second
  row in the same state adds `(+N more)`. A problem that started after the collector's first run
  ends with `· since HH:MM`.
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

### 2.2 Week against week

`7 days vs prev 7` is Token tracking's comparison for this block: the same columns (`7 days ·
prev 7 · Δ`), the same Δ text and tone (tokenmap `tracking.py` `delta`: `×N` from 11 times, a
tone only from 10 %), worse red and better green. The top line counts them: `· 3 worse, 2 better`.

- `7 days` is today and the 6 days before, `prev 7` the 7 before those. Medians come from the
  merged day histograms; rates (`slow h/day`, `hooks h/day`, `tests h/day`) divide by the days
  covered, today counting as its elapsed share; load rows are the mean of the daily means.
- A tone needs 20 runs in each week for a median and 3 covered days for a rate or a mean.
- Rows: Bash, Edit and Read wait, chat start and turn end, slow h/day, hooks h/day, CPU busy,
  kernel, new processes, unaccounted cores, tests h/day. Bash opens per project, hooks per hook
  (median s), tests per test (median min).
- `by week` shows the same rows over 8 calendar weeks, Mon–Sun, the current one partial.
- Waits history reaches back 28 days (the transcripts); hooks start with the hook journal and
  load with the first 5-minute sample, so their `prev 7` fills in over two weeks.

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
| CPU busy, kernel | `host_statistics` ticks via ctypes | the delta since the previous run, valid when the gap is ≤ 15 min; the counters wrap at 2^32 |
| new processes | spawn `/usr/bin/true`, wait 2 s, spawn again | PID delta mod 99 999 ÷ elapsed. There is no sysctl fork counter. |
| unaccounted CPU | busy × ncpu − the visible cores in memlogd's `chats.json` title | CPU that per-process sampling misses: short-lived forks. The title parse is fragile coupling. |
| memory | `vm.swapusage`, `kern.memorystatus_level`, and memlogd's guard alarm | red on the guard alarm or swap > 90 % |
| tests | `~/.cache/claude-statusline/test-history.jsonl`, written by `bin/statusline-work-probe.sh` for every test it saw end | wall clock is the union of overlapping runs, so parallel suites are not double-counted |
| running now | `~/.cache/claude-statusline/work-*` newer than 30 s | the `main tests` lines |
| growth | daily sample | entries and bytes of the instruction-watch reverts, statusline cache, review benches, this doctor's state and the transcripts, plus `git count-objects` per repository seen in the last 7 days |
| cause | collector state | first-red time per row key, attached to the area it decides. A row red since the collector's first run claims no cause. |
| change log | collector | content hashes of `~/.claude/hooks` (resolved to claude-setup), llm-legs `bin` and `share`, and every hook script in settings.json; hooks added, removed or re-timed; Claude Code versions by first sight |

### 3.1 PostToolUse cut attribution

A cancelled PostToolUse hook is not named in the transcript. The collector takes the call's
latency L and blames the synchronous PostToolUse hooks matching the tool whose timeout T satisfies
`L − max(3, 0.2·L) ≤ T ≤ L + 1`. Among those candidates it picks the largest T; ties are listed
with `|` and counted as `+N?` on each tied hook. Cuts from before the settings.json mtime count
as `cut, hook unknown`, because they ran under other timeouts. That rule is what stopped the 09-22
incident's cuts from being blamed on today's report-flush and commit-report.

## 4. Limits and their calibration

The limits sit in one `LIMITS` table at the top of `bin/harness-doctor`. The calibration comes
from this machine on 2026-09-28, from the 28-day backfill and a day of samples:

| limit | red | note | evidence |
|---|---|---|---|
| tool call median, 1 h, ≥ 5 calls | > 5 s | > 3 s | the healthy daily median was 1.5-3.5 s (Sep 1-22), 10-11 s during the incident, and 11-58 s during 09-07..09-15 |
| cut share, 1 h | ≥ 3 cuts and > 1 % | – | a healthy day has 0 cuts |
| event median (session start, …), ≥ 3 | > 5 s | – | the SessionStart baseline hook cut at 10 s on every start in the incident |
| hook p50, ≥ 5 samples | > 1 s | – | healthy printed hooks run at 0.1-0.6 s |
| CPU busy, 1 h mean | > 90 % | > 70 % | a normal loaded day is 54-72 % |
| kernel share | > 50 % | > 30 % | about 30 % is standing |
| new processes | > 2 500/s | > 1 000/s | 1 200-1 330/s is standing, with one sample at 890 |
| not seen per process | > 5 cores | > 2 cores | – |
| swap | > 90 % | > 50 % | – |
| suite runs at once, peak today | ≥ 5 | ≥ 3 | a daily peak of 3-4 is normal, because `run-suites` runs ncpu/2 in parallel |
| a test group's last run | > 2 × its usual and > 10 min, with ≥ 3 runs | – | – |
| loose git objects | > 13 400 | > 6 700 | logo-vectorizer-bench had 16 430 and llm-legs 8 113 |
| any other store | > 50 000 entries or > 1 GiB **and** × 2 in 7 days | big alone | a store that is only big is shown as a note, not a problem |

The limits are absolute. A self-adjusting baseline is what let LLM doctor's `mark_slow` absorb the
09-22 step, so `best 28 d` is shown next to the current value but never lowers a limit.

## 5. Collector

`bin/harness-doctor` uses Python 3.9+ and the standard library only.

- **State**: `~/.cache/harness-doctor/` (override `HARNESS_DOCTOR_DIR`) holds:
  - `state.json`: per-transcript offset, size, mtime, a hash of the first 512 bytes, pending
    tool_uses, mode, entrypoint and toplevel; plus the watched file hashes, the hooks snapshot,
    the versions, first-red times, the birth time and CPU ticks;
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
  `state.json` under `journal`.
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
  `launchd/harness-doctor`) every 300 s, with RunAtLoad, `ProcessType Background` and `Nice 10`.
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
- **Reader**: incremental by byte offset up to the last newline; spool files are folded and removed.
  Each run lands in a 10-minute slot per key: count, sum, min, max, non-zero exits, unfinished runs,
  and a histogram on fixed edges from 5 ms to 600 s. The median interpolates inside its bucket,
  clamped to the slot's min and max. Slots are kept 25 h and journal files 3 days.
- **Coverage**: a settings hook whose script does not source the lib is a blind spot by name,
  and `../claude-setup/tests/test_hook_time.sh` fails for a claude-setup hook without the line.

## 6. Renderer

`appendHarness` reads `menu.txt`, never `latest.json`. `hs.json.decode` of the 40 KB document
took about 39 ms on every menu open, while the whole menu was already at about 60 ms. The laid-out
lines cost one pattern match each. The format:

```
T<TAB>red<TAB>as_of<TAB>title
depth<TAB>flags<TAB>spans<TAB>text
```

- `depth`: 0 is the block's own submenu; a deeper line nests under the line above it.
- `flags`: `d` is dim, `s` is a separator.
- `spans`: comma-separated `style:byte:bytes` entries. `r` is red, `g` is Token tracking's green
  (a better Δ), and `n` stays undimmed on a dim line (the area name of an `ok` area). Offsets are UTF-8 bytes, because the text contains `·`,
  `–` and `…`.

The collector does all the layout, padding columns by character count in Menlo, so every glyph
must be one Menlo cell: the statusline's worktree mark `⧉` is rewritten to `wt`. The renderer names
no row. It only adds `refreshing…` or `Refresh` (which runs the collector through
`startDiagnosticsTask`) and the stale suffix. Menu construction starts no task. The parsed items are
cached on `menu.txt`'s inode, mtime and size: the collector replaces the file by rename every 5
minutes, so a menu open between two runs parses nothing, and `appendHarness` copies the cached
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

## 8. Blind spots and next stages

The `not measured: N blind spots` line lists them:

1. **Hooks outside the journal**, by name: today only the inline SessionStart branch check,
   which cannot source a file. The journal times a hook's body, not the interpreter start
   before its first line: about 4 ms for `/bin/bash`, about 11 ms for Homebrew bash 5.
2. **Statusline cost per render**, until the statusline writes its journal line.
3. MCP server start-up, worker spawn and relay latency.
4. worker-run supervise loops, worker-pick and review-cell preparation.
5. launchd jobs and Hammerspoon's own tasks.

Also pending:
- numeric fields in memlogd's `chats.json`, to replace the title parse behind
  `unaccounted CPU`, and a line naming the heaviest chat or daemon;
- the transcript pass's API timings, handed to LLM doctor under a document key, with a note to
  its owner chat.


## 9. The questions it answers

The standard round listed the questions a user asks about a harness like this one. Status after
the rework:

| question | where | status |
|---|---|---|
| Is something slowing my chats right now? | Waits | answered at a glance |
| Was today slow, and is it over? Is it the model or us? | Slow periods; LLM doctor marks legs `local slow` | answered |
| Which hook is the wait, and are hooks cut? | Hooks | answered: every run of every journaled hook, with a daily total |
| Is the Mac overloaded, and by what? | Load; the Chats block for chats; Hooks' totals | load answered; hook totals attribute part of the short-lived processes, the rest are not attributed |
| Are tests the reason? What is running now? | Tests | answered |
| Did a change make it slower? | the cause line of a problem; `changes, 7 d` | candidates with the short Bash median and new processes/s in the hour before and after each change |
| Is a growing store slowing things? | Growth | size and limit answered; the 7-day trend appears after a week of samples |
| Is this week better than the last? | `7 days vs prev 7`, `by week` | answered for waits (28 days back); hooks and load from 2026-09-29 on |
| Why did my worker finish late? | – | missing: needs worker-run stage timestamps minus LLM doctor's API time per leg |
| Is the statusline eating the machine? | Hooks, `statusline (not a hook)` | reader built; waits for the statusline's writer (blind spot 2) |
