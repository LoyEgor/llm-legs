# Doctors contract

What the LLM doctor (`bin/llm-doctor`), the Harness doctor (`bin/harness-doctor`), the Updater
doctor (`bin/updater-doctor`), the Code doctor (`bin/code-doctor`) and the System doctor (`bin/system-doctor`) share, so
that one menu entry and one fixer procedure can serve them all. Version 1, written 2026-09-29 by the chat «Updater doctor» from two
T2 hunts over both doctors. A doctor's owner chat may amend it here; the other owners follow the
amended text.

## 0. Egor's decisions (2026-09-29)

- One top-level "Doctors" menubar entry, English, looking like the entries around it (Better
  Terminal, Talking Tracking).
- Fixer chats start only on his button, never on a timer. Each doctor shows when its fixer last ran,
  so he judges it himself. Data collection may run on a schedule.
- Detectors stay separate. The shared parts are the document envelope (§1), the ledger row (§2),
  the blind-spot list (§3), the fixer run record (§4) and the fixer procedure (§5).
- A fixer fixes clear bugs itself. Only ambiguous items go to the doctor's owner chat as a handoff.
  It watches for the doctor's own blind spots and for causes fixed more than once, and adds no bulk.

### Menu layout

Egor scans the first level and each doctor's first level; he reads no captions there. Glyphs,
the palette (RED, DIM, GREEN) and aligned columns carry state; every other row lives
unchanged under `LLM details`. One meaning per colour:
- RED: act now: true now, actionable, and nobody already fixing it. Only a red problem counts in `Doctors: N problems`.
- DIM: no number to trust (no data, stale, a blind collector) or a row that only informs (a watch, a pending fix, a
  report-only cause).
- GREEN: nothing for Egor.

A red problem is a loud one (`new`, `open`, `regressed`) the menu does not calm. The view calms, in
`hammerspoon/doctors.lua` only: a problem an open fixer run holds (`runs/`, launched within `FIX_BUSY_S`, neither
closed, failed nor abandoned; its `problems[].id`); `CALM_RULES` (Updater `event-waiting`: a release waiting for its
integration; System `unregistered-store` and `swap-writes`: no cause, no lever); a System problem whose `cause` is no
`fix_target` (Apple, third-party, an own process outside the sweep repositories) unless it is `AT_RISK`
(`free-space`, `dir-growth`, `swap`: the machine itself at risk). Every document, `problem_count`, the night's
`doctor_snapshot` and doctor-fix keep each problem as it is (test: the night snapshot block of
`tests/doctors_menu_harness.lua`). Fixture render:

```
Doctors: 8 problems
LLM          2  ▁▁▂▃▄▆█    3 ▸
Harness      3  ▁▁▂▃▄▆█    3 ▸
Updater      0  ▁▁▂▃▄▆█    3 ▸
Code         3  ▁▁▂▃▄▆█    3 ▸
Lost time 0.93  ▁▁▂▃▄▆█      ▸
Spend     0.46  ▁▁▂▃▄▆█      ▸
System       2  ▁▁▂▃▄▆█    3 ▸
Last night 5 Oct · stopped early: no jobs
──────────
Cleanup now
Run everything now

LLM ▸     8  reviewers crashed
          4  review anchors
       Fix — open a fixer chat
       fixer: never ran
       ──────────
       LLM details ▸   (the doctor's whole previous tree)
```

- Summary row, fixed cells: name (9, in the status color) · value (4, right, plain) · 7 bars · usual (4, right, DIM), no
  unit, no trend arrow. Counts are bare. Lost time and Spend are indices, two decimals, 1.00 = the previous 7 days'
  fee per unit of work, and carry no usual (their reference is 1.00): Lost time, internally Speed, is the time budget's
  per-task `index` (docs/speed-doctor-design.md); Spend is tokenmap's `harness_index.value` from `tracking.json` via
  `share/spend.py`, per Claude request, Harness being the Spend tree's Harness leaves of every consumer; Lost time
  counts the Harness groups `SHOWN_BY` gives it, Spend none.
- Status color of the name (no dot: `●` is the LLM Limits pin mark): RED a red problem or a collector error (Lost
  time: a red Harness group it shows; Spend never: its audits only watch), DIM no data, blind or
  stale (Speed also without an index dated today; Spend while `tracking.json` is past its `stale_after_hours`, has no `harness_index` or its value is null), else GREEN. Missing value: DIM `–`.
  The value is the summary's red count.
- Bars: six completed local dates and today, daily `max` of the red count in `red-days.jsonl` (the menu writes it when
  a day's max rises, 8 days kept; `problem-days.jsonl` stays every loud problem for the time budget). A date with no
  red-days row (before the menu kept them, or a doctor with no count that day) draws that day's loud `max` from
  `problem-days.jsonl` in the same DIM bar: red is a subset of loud, so a loud 0 is an exact red 0, and any other
  such date is a loud day, drawn but never in the `usual` (Lost time: `index_by_day` in Harness's
  `menu.txt` header, the 7-day window ending each day, today live; Spend: its stored index of each day, the same window). Eight heights against the window maximum. An unmeasured date
  is a blank cell, never an invented bar or a dash; a zero is `▁` (as every other spark line, Chats → Other's
  load graph the model). Every bar is DIM, never RED.
- `usual` is the median of measured completed dates, never today and never a loud day; index rows have none.
- A doctor's first level: up to three issue rows of red problems (RED count, the group or the problem's own short name,
  then ` · ` and the first red problem's `fact` where the document gives one; Spend's rows DIM;
  Lost time: the current window's `levels`, `min per order · chat` and `min per task · workers`, then the header's `rows`, plain aligned min/day, separators and sub-menus, a row flagged `{"dim": true}` (outside the index: model-written scripts, our tools) DIM whole, a `{"count": true}` row (Unused tools) a bare count opening its rows, plus nonempty `Needs Egor` rows), Fix, fixer, separator,
  `LLM details`. The details hold every previous row in order, the non-ordinary status title
  (stale, failed, pending) first; Lost time's and Spend's details are Harness's `Lost time:` and `Spend:` subtrees.
- Each doctor answers one question; the view moves, never the collectors (rule ids, groups, documents, areas and night
  kinds stay). `SHOWN_BY` in `hammerspoon/doctors.lua` maps a donor's group (and its level-0 `<Group>:` row) to the
  summary that shows it: Harness's Suite audits, Test flakes, Limiter holds and the row-less Speed, Tests, Wait
  classes, Hook waits, Hooks, Waits, Slow periods, Collector → Lost time (with the window rows and their chooser);
  CPU audits, Load (out of Lost time's subtree), Memory guard, Growth → System, kept at the end of its details;
  LLM's `debt` → Harness. Harness's details drop `Lost time:` and `Spend:`. Red counts move through the same table by
  each red problem's `group`, so each summary's count and issue rows change but the `Doctors: N problems` total never
  does.
- System's first level is seven fixed sections instead of issue rows: Processor, Memory, Disk writes, Disk space, Logs,
  Crashes, Background, each `name (13) · value (5) · unit (7) · 7 DIM bars · usual (5)` from the document's `measures` and `days`,
  the name RED when a red problem of its rules sits inside, DIM for a blind collector, else GREEN; a calm problem
  (watch, pending fix, report-only cause) is a DIM row. Inside, each rule's problem tones the measure it judges (a problem with no measure row gets its own row),
  lists carry human names (worker-run → workers, test suites → tests, helpers by their app), log groups open their
  labels as `size · retention · label` (the group's own retention for a split store; a label of several stores spans
  their days and opens one such row per registry `part`; no readers); Disk writes lists the root samples
  (`measures.ssd_sampled`) after the rusage rows as `process  directory` in GB/d, the week's mean times each share, and
  the unattributed rest DIM; a problem an Apple or third-party cause makes is a DIM row. The moved Harness rows show
  in their section by label and count (CPU audits, Load → Processor; Memory guard → Memory; Growth → Logs); a problem
  of a rule no section owns follows the sections while red. Background (rule `cohort`) lists `background.groups` as
  `B × · group · item count`, RED with a red problem inside, DIM under its limit, its value the groups at or over
  it; an item reads `B × · dominant term · name` (the group's prefix dropped, `✗` its job's file gone, `○` a job
  launchd does not hold with B 0) and opens its `about`, `place`, `label · schedule · state`, then each term per day
  and as a share of its limit, starts (`per_day.S`, unscored: B has no S) per second on a DIM row with no share,
  the unmeasured terms on one DIM row. The menu only places and formats what the
  document says.
- Harness's `menu.txt` carries `H<TAB><JSON>` right after `T`: status, problem ids/ledger refs (a loud one also its
  `state`, `group` and `fact`), three group issues, every loud group's count (`groups`), Speed's status, timestamp, index, its daily series, levels and budget rows. The menu
  reads it and `red-days.jsonl` cached by inode, mtime and size, never Harness's `latest.json`;
  a header-less file shows open Harness ledger rows as `known, awaiting snapshot`.

Who builds what:
- **Each doctor's owner chat** builds its document and ledger in this shape, its section of
  `docs/doctor-fix.md`, and the tests that hold both.
- **The chat «Updater doctor»** builds the Doctors menu entry, the Fix button, the launcher, the run
  record, the common part of `docs/doctor-fix.md`, and the Updater doctor.

## 1. Document envelope

Each doctor keeps writing its `latest.json` (`~/.cache/llm-doctor/`, `~/.cache/harness-doctor/`,
`~/.cache/updater-doctor/`, `~/.cache/code-doctor/`, `~/.cache/system-doctor/`)
and adds these top-level keys. Its own keys stay as they are.

| key | value |
|---|---|
| `contract` | `1` |
| `doctor` | `llm` \| `harness` \| `updater` |
| `as_of` | ISO-8601 with offset |
| `judge` | sha256 over the doctor's code, ledger and limits; it changes whenever the judge changes |
| `status` | `ok` \| `problems` \| `blind` \| `error` |
| `problem_count` | problems whose state is `new`, `open` or `regressed` (the menu counts the red ones among them, "Menu layout"); the harness doctor writes `null` when its collector failed |
| `problems` | list of problems, below |
| `blind_spots` | list from §3 |
| `self` | `{collector_s, error}`, where `error` is null or one line |

Status rules:
- `blind`: an input the doctor needs is missing, empty or unjoinable. It is never reported as `ok`.
- `error`: the collector failed. The menu shows the error, never the previous document's colour.
- The menu never recomputes a state or a count.

Problem fields:

| field | value |
|---|---|
| `id` | Stable across reruns. It is the ledger row id when a row matches. Otherwise it is `<rule>:<key>`, built from identity fields only: never display text, clipped labels, worktree names or counts. |
| `rule` | the name of the constant rule that judged it |
| `state` | `new` \| `open` \| `regressed` \| `fixed-pending` \| `watch` |
| `fact` | one English line for the menu |
| `value`, `limit`, `unit`, `window_h` | the measured number and the line it crossed |
| `exposure` | how many events this rule judged in the window (legs, calls, runs); `0` means "cannot tell" |
| `count` | events the rule judged bad in its window (legs, calls, runs, journal lines, samples over the limit); null when the rule judges an aggregate or a state with no single events |
| `first_seen`, `last_seen` | ISO, computed from data |
| `evidence` | Up to 3 items of `{at, ref, account, excerpt}`. `ref` names exactly ONE event (a run id, a log line's ts plus account, a `tool_use_id`). `excerpt` is at most 300 characters of the raw text the matcher read. |
| `ledger` | row id or null |
| `near` | optional: rolling p50/p95 of the rule's value, so a cost under the limit stays visible |
| `group` | LLM and Harness doctors: the one menu group (block, area) that counts the problem; a group row counts its `new`/`open`/`regressed` problems, so the rows sum to `problem_count` |

`new` means that no ledger row matched. Catch-all rows are not allowed (§2), so an unseen cause is
always `new`.

## 2. Ledger

There is one file per doctor, with the same row shape:
- `share/doctor-ledger.json` for the LLM doctor;
- `share/harness-ledger.json` for the Harness doctor;
- `share/updater-ledger.json` for the Updater doctor, whose rows match an exact `{rule, key}`;
- `share/code-ledger.json` for the Code doctor, whose rows match an exact `{cause}` or a structural
  `{identity}` (§6).

The top level is `{owner, rows, blind_spots}`:
- `owner` is the chat that owns the doctor, and every handoff about the doctor goes to it.
- The LLM ledger also keeps `owners` per block, naming the owner of what the block judges; none of
  them may be null.

Row fields:

| field | value |
|---|---|
| `id`, `title` | |
| `match` | The doctor's own matcher fields. It must narrow below a whole rule or word. |
| `status` | `open` \| `fixed-pending` \| `fixed` \| `not-a-bug` \| `weather` |
| `fixes` | List of `{at, by, files, in, regressed_at}`. `by` is a chat name. `files` are `repo/path`. `in` is `repo@hash`, or null while uncommitted. |
| `same_cause` | ids of sibling rows for one cause |
| `last_reviewed`, `reviewed_by`, `note` | |
| `handoff` | path of the handoff file, or null |

The fix lifecycle:
- A fix poured into main uncommitted is `fixed-pending` with `in: null`.
- Once the sweep commits those files, the doctor itself turns the row `fixed` and fills `in`. No chat
  edits `in` by hand.
- A measuring run never writes a tracked file (shared-invariants row `ej`): what it settles (`in`,
  `regressed_at`, `fixed-pending` → `fixed`) goes to its overlay `<state dir>/ledger-settled.json`,
  keyed by row id and fix `at`. Every reader merges it through `share/fix_commit.py` `load_merged`, a
  value the tracked file holds winning; the night's `doctor-fix ledger-sync` commits it.
- A repeat fix appends to `fixes` and never overwrites it. More than one fix on a row, or on a
  `same_cause` group, is a complexity signal: the fixer looks for the shared cause instead of
  patching again.

A matching event regresses a fix only if it ran on code that holds the fix:
- It must have started after the last fix: its `at`, or once `in` is filled the time `in` reached
  HEAD of the watched checkout, whichever is later (the commit's own time when it sits on HEAD's
  first-parent line, else the merge that brought it in). A fix committed on a night branch holds
  from its landing, never from the branch commit. Its end time is not enough.
- A doctor that records the code revision per event uses that instead.

Proof of a fix: the doctor shows `fixed · E events since · 0 matched`. While E is below the doctor's
own minimum exposure, the row reads `unproven`, never `fixed`.

Guarding the judge, enforced by each doctor's own tests:
- No dismissal row (`not-a-bug`, `weather`) without a narrowing matcher field.
- No catch-all row.
- The limits table, the exemption lists and the ours/theirs word lists are pinned in a test.
- A fixer never loosens its judge. A loosening goes to the owner chat as a handoff.
- `judge` in the document shows that the judge changed. The run record (§4) compares it at launch
  and at close.

## 3. Blind spots

A blind spot is a row `{id, what, reason, since, would_catch_if}` in the ledger's `blind_spots`. The
doctor emits these rows in its document.

A fixer that meets a cause the doctor did not catch adds a row here, with what would catch it. It
never builds the detector in a fix run: that is the doctor owner's work.

## 4. Fixer run record (built by «Updater doctor»)

`bin/doctor-fix` keeps one record per run in `${DOCTORS_DIR:-~/.cache/doctors}/runs/<id>.json`, the
id being `<doctor>-<area>-<UTC %Y%m%dT%H%M%SZ>-<4 hex>`, unique under parallel launch. Every
read-modify-write holds the runs directory's lock (`share/store-lock.sh`). Fields:
- `id`, `doctor`, `area` (`all` for an old day run, `release` for a vendor-fingerprint run), `night` or null;
- `created_at`, `launched_at`, `closed_at`, `abandoned_at`, `failed_at`: ISO UTC, or null. A run is
  closed, abandoned, failed (with its `note`) or open; a launch never leaves it in between;
- `account`, `session`, `command`: a day run's orchestrator chat's Claude account, session and command file;
- `branch`, `base`, `worktrees`: `night/<night>/<id>` from `refs/night/<night>/base` at night, `doctor-fix/<id>`
  from `refs/doctor-fix/<id>/base` (main at launch) by day, and its worktree paths;
- `judge_at_launch`, `judge_at_close`: the doctor document's `judge` (a night run's from its branch
  base), or null;
- `problems`: `[{id, state, fact, rule, ledger, area, component: {what, files, rule_at}}]`, the
  snapshot at launch;
- `quiet`: the same shape with state `quiet`: the ledger's `open` rows no problem of the document
  names (its window did not see them), assigned to areas like problems; they need no decision line;
- `decisions`: `[{id, verdict, purpose, evidence}]`;
- `knobs_at_launch` (a Harness or System run): `{path: [lines]}`, the model, effort and thinking lines of
  the live settings and worker-model files at launch;
- `note`.

Areas: the LLM doctor's block (from the ledger row, the id or the document's blocks), else its health
row (the ledger row's `match.health`, or the `health[]` row whose `rules` hold the problem's rule); the
Harness doctor's section of the rule; else `doctor` (`share/doctor-areas.json` `own`), which is every
Updater rule but `event-waiting`; the Code doctor's one area `code` and the System doctor's one area
`system` (`whole`), labelled a bare `Code fixer` and `System fixer`. Old runs' `health`, `self` and `machinery` read as `debt`, `doctor`
and `doctor` (`renamed`). The snapshot keeps the problems not `watch` or
`fixed-pending`, plus, for the Harness doctor, the top 8 `watch` rows of Hooks and Hook waits by
value × exposure.

**Top-K exception (the Code doctor and Harness's Speed block).** Speed's `watch` opportunities enter
the snapshot only as its `speed.selection` names them, in that order and `quality: equivalent` only,
after the loud regressions, in sized runs per context (speed-doctor-design Selection), area `speed-<first lever>`: `bin/speed-doctor` `select` takes every
positive-score opportunity; all Speed rows rank in one order (`time_budget.speed_rank`). The Code doctor's snapshot takes at most K problems per run, by judged
`value`: `TOP_K` 3, or `TOP_K_LOW_YIELD` 1 while its yield per 1000 tokens spent is under
`LOW_YIELD_PER_KTOK` (`bin/code-doctor` `queue_k`). Before ranking it drops the problems in active
work (an uncommitted path of a main checkout or another worktree, a path a live branch changed, an open
review claim), the needs-Egor problems, and the problems whose units changed since the night base,
whose verdicts go back to the judge. The rest stay counted and wait for a later night: a code queue is
months of work, and a run sized to the whole of it never closes.

The menu reads `doctor-fix runs [doctor] [--open] [--json]` (newest first) to show "fixer ran N d ago
· closed / still open". `doctor-fix show <id>` prints the run and, per problem, the packet: its
ledger row, earlier decisions on the id, the component and its git history, and the handoffs,
invariant rows and memory files naming it. Launch:
- `launch llm|harness|updater|code|system [--night <night-id>]`: per area with problems or quiet rows and no open run
  of (doctor, area) opened less than 12 h ago (an older one is marked `abandoned_at`), a record, a worktree
  `<repo>/.claude/worktrees/<branch, / -> ->` and `<runs>/<id>.brief.md`; one line `<id>\t<brief>\t<worktree>` each.
  Refused when the document's `contract` is not 1 or it is older than 2 h. By day (not `updater`) it then
  opens one orchestrator chat on those lines (`orchestrate <lines>`, `docs/fix-orchestrator.md`; no chat fails the runs and drops their worktrees) and refuses
  nothing to fix; at night nothing to do prints nothing, but a harness night whose Speed section selects nothing first prints `harness: Speed selects nothing:
  <why_none>` on stderr; a failed worktree or brief fails its run and the exit status.
- `launch updater`: runs `vendor-cli-update now`. Every per-vendor run `vendor-fingerprint` makes writes its
  record through `doctor-fix record updater` (area `release`): `problems` are the event ids, and each
  event's `run` names the record. It closes through `record-close` when `vendor-fingerprint close`
  closes the last of its events, one decision per event (`verdict` integrated, not-applicable,
  blocked, or the event's status when its diff had no line; `purpose` null; `evidence` the count of
  its decision rows and its note).
- `abandon <id> [--reason TEXT]`: the deadline's verb; a closed run refuses it.

`doctor-fix close <id> --decisions <file> [--doc <document>] <note>` closes any other run:
- A run with a worktree reruns its doctor there into a run-local document (never the shared
  `latest.json`); an old day run without one reads the shared one. It refuses until that document's `as_of` is
  later than `launched_at`, and it refuses an abandoned or failed run.
- The file has one line per problem id of the snapshot:
  `id<TAB>fixed|ruled-out|weather|blind-spot|handoff<TAB>purpose<TAB>evidence`. `purpose` says where
  the component's goal is stated, must resolve (`repo@hash` committed in
  `/Volumes/Work/Projects/<repo>`, or an existing file: absolute, relative to llm-legs, `repo/path`
  or in a worktree of the run; a `:line` suffix is allowed) and must touch the component: one of its
  `files`, or a commit that changed one. With no component file, resolving is enough. `evidence`
  is not empty.
- A judge that changed since launch also needs `judge<TAB>changed<TAB>purpose<TAB>why`, the purpose
  touching the doctor's code or ledger.
- It refuses while any line is undecided or unresolvable, listing every one, the same gate as
  `vendor-fingerprint close`. `doctor-fix touches <record> <id> <purpose>` exposes the purpose rule.
- Every worktree's `*.md` bytes must not have grown since the run's `base`.
- A Code run also refuses while `bin/code-doctor check <record> --base <base>` prints a line (§6).
- A Harness or System run also refuses every added or removed line that sets a model, effort or thinking
  knob (`KNOBS` in `share/knobs.py`): in its worktrees against its `base`, committed,
  uncommitted or untracked, and in the live settings and worker-model files against
  `knobs_at_launch`. Sites: settings `model`, `effortLevel`, `alwaysThinkingEnabled`,
  `MAX_THINKING_TOKENS`, `modelSettings`; `worker-model`; the `share/worker-model.sh` table;
  `share/worker-policy.md` effort lines; review-bench `share/rbench/catalog.py` tier efforts and
  rosters; agent `model:`/`effort:` frontmatter; claudeb's default model (`bin/claudeb`,
  `share/chat-open.sh`); brief-template `EFFORT:`/`MODEL:` lines. Each refusal names the site and
  `file:line`.

## 5. Fixer procedure

The procedure is `docs/doctor-fix.md`. «Updater doctor» writes the common part, and each owner
writes its doctor's section. A section says:
- the read-first order;
- the command that recomputes the document from a committed fixture or at a given time, and what
  counts as proven (value under the limit with exposure ≥ N);
- where the judge lives, and that it is not the fixer's to loosen;
- the blind-spot question: "would the doctor have caught this?"

Handoffs are `docs/handoffs/<date>-<topic>.md`. The first line after the title is
`Status: open`, and the chat that settles it rewrites that line as
`Status: done <date> — <ledger ids>`.

## 6. Per-doctor notes

Harness doctor (added 2026-09-29 by its owner chat):
- `as_of` is ISO as §1 says; the epoch stays under the doctor's own key `as_of_s`, which `menu.txt`
  carries.
- `local_slow`, read by the LLM doctor, is fed only by rule `wait`: a red Waits call row, per project
  and tool. A red hook-wait floor (`floor`) is already inside the call wait it feeds, and a busy
  machine (`load`) with no slow call slowed no leg, so neither marks a period local.
- Proof of a fix is the `fact` of a `fixed-pending` problem: `fixed · E events since · M matched`, or
  `unproven · …` while E < 20. E is the row's rules' exposure (quiet verdicts included) over
  non-overlapping windows that started after the fix; M counts the runs that judged a regression. The
  rate proof and Speed's rules: `bin/harness-doctor` (`speed_proof`, `PROOF_MIN_PREDICTED`).
- `count` is the number of events the rule judged bad in its window: calls, hook runs, batches,
  cuts, test runs, journal lines, load samples over the limit (the hour's), the latest store sample,
  the stuck spool's files, a slow collector run. It is `null` where the rule judges a median over
  histogram buckets or a state rather than events: `hook_every_call`, `hook_full_work`,
  `hook_grows_size`, `hook_grows_repos`, `statusline`, `menu_build`, `fastpath`, `unjournaled`.
  The number of collector runs in the last 24 h that judged the problem is the doctor's own key
  `runs_red`.
- Own key `speed` (design `docs/speed-doctor-design.md`): `bin/speed-doctor`, run after each Harness run,
  writes it and lays its block at the top of `menu.txt`. Its problems carry `"speed": true` and group `Speed`:
  `regression:<metric>|<ident>|<band>` counts, `opportunity:<component>` is `watch`. A rule whose component
  Speed judges against a baseline is `watch` with `judged_by`, its own state kept as `was_state`, so no rule
  counts twice in `problem_count`; each problem carries its verdict's `ident`, which Speed's `covers` match.
  Its `spend` (`share/spend.py`) adds `spend:<component>` problems, rule `spend_audit`, group `Spend`, `watch`: a
  component whose audit is due (never audited, a source blob moved, share ≥ 1.5× its share at audit). Components:
  `menus` first (its sources are the Token tracking and Doctors menu code, so it is due when they change: the night
  checks both menus against what it reads), then `loaded:<job>`, a job whose last run loaded the config
  (`harness_index.loaded`; workers: runs.jsonl `user_md_loaded`; due again after a cut), then `fee:<source>`, each source of tokenmap's Fee index
  (`harness_index.sources`) by its share of Fee. `spend.selection` lists every due
  audit, area `speed-spend-<component>`; `spend.proofs` (share, part price at audit) feed night `roi` lines.
  `cpu` (`share/cpu_audit.py`): `cpu:<component>` rows, group `CPU audits`, own, wasted CPU-min/day, due as
  Spend's, never under 1 CPU-min/day (`FLOOR_MIN_DAY`; the head counts the rows it skipped). In every audit block a
  source moved only by `merge …harness-speed-…` landings (main's reflog) since the audit's run started, or since the
  last main commit holding its recorded blob, reopens nothing (`spend.moved`); any other commit or an uncommitted
  edit does.
  Its `tests` (`share/test_health.py`, design § Test health) is the Test health block in Speed's menu lines and
  `opportunity:test-health/...` problems in min/day, its lines over their usual `regression:test-health/<line>` rows;
  its `candidates` (dead, pinned and uncaught suites) feed `suites`; `catches` holds the 7-day episode classes.
  Its `suites` (`share/suite_audit.py`) adds `suite_audit:<repo>:<suite>` problems, group `Suite audits`, `watch`: every
  suite of the sweep and night helper repositories priced at wall-min/day, CPU-min/day beside it (its last 20 runs' median wall and CPU times its runs over 7 days of run-suites' journal, every
  runner), due when a Test health candidate is dead or pinned and unaudited since, never audited, the suite or a tests/ helper it names has another blob, or wall
  a run held ≥ 2× the audit's by every newest passing run over 2 days (`HELD_S`; CPU stays a column); every run after a commit, over 2 days, ≥ 2× and ≥ 30 s
  over the fastest before it once divided by the machine's slowdown (`load`: the median, over ≥ 3 suites whose sources
  no commit changed between the runs compared, of their fastest after over fastest before; ≥ 1), or a new suite (not
  a split) over 3× the median suite a run, is due at once and names its commit. A suite under 1 wall-min/day
  (`FLOOR_MIN_DAY`) is never due unless dead or pinned; the head counts the ones skipped. `suites.selection` is the queue by wall-min/day; a night takes the first its red test rules do not hold, area `speed-suite-audit-<repo>-<suite>`,
  brief header `STRONG: yes` (worker-run refuses Light and Gemini Flash). Audits are `suite:<repo>/<suite>` rows of
  `share/spend-ledger.json` (`bin/speed-doctor --suite-audit`), proven once the fastest of 5 runs after it reads ≤ 0.65× its wall a run (its fastest of 20).
  A night's `roi` line proves a suite or hook fix per unit (median wall-s a run, hook ms a call) once N samples
  follow it (`time_budget.UNITS`), a wait, refusal or run cut per unit of work (`VOLUME`), load-matched or
  `unmeasured`, as are day totals (other classes).

LLM doctor (added 2026-09-29 by its owner chat):
- `as_of` is ISO as §1 says; the epoch stays under the doctor's own key `as_of_s`, which the menu
  reads.
- `judge` is sha256 over `bin/llm-doctor`, the ledger's dismissal rows (`id`, `block`, `match`,
  `status`) and `limits()`. Tracking a fix (`open`, `fixed-pending`, `fixed`, `fixes`, notes)
  leaves it unchanged.
- `status` ranks `error` > `blind` > `problems` > `ok`; a blind document still counts
  `problem_count`, and `blind[]` names the required inputs that are not `ok`.
- ids without a ledger row: `leg-failure:<block>/<word>`, `leg-escape:<block>/escaped`,
  `machinery:<class>`, `<rule>:<key>` for review debt, and `ledger:<row>` for a ledger
  fault — one per faulty row whatever its faults, `ledger:rows[<index>]` for a row with no id. A
  faulty row judges nothing.
- `watch` also marks a `fixed` row still short of its proof, and a cause every retry hid:
  `recovered` of those attempts ≥ 3 (`RECOVERED_MIN`), with `lost_s` their seconds. A
  `fixed-pending` row is listed under rule `fix-proof`.
- Ledger `match` is one of: `{word, model?, detail?, until?}` with a `model` or `detail` regex of at
  least three literal letters or digits that never matches empty text; `{machinery}` on a
  `reviewers` row, matching one whole review-bench doctor class (that detector's own rule, already
  narrower than a word), which may be open or fixed but never dismissed; `{health, key}` for debt, `key` a narrow regex over
  `<rule>:<key>`.
- One repository per `fixes[]` entry: the doctor asks that repository's git whether the files are
  committed. Every `in` must name a commit there; one that does not is a ledger fault.
- Proof reads `fixed Nd · E since · M matched`, plus `· unproven` while E < 10 (`PROOF_MIN`). E is
  the final legs of the row's block (and model) that started after the last fix.
- `count` is the number of events (legs, anomalies, journal lines) in the window.
- `near` is top-level, one entry per threshold: the largest value a rule measured between half its
  limit and the limit. Per-problem p50/p95 is not built; each block's `speed` carries
  `ratio_p50`/`ratio_p95` of leg duration against its baseline.

Updater doctor (added 2026-09-30 by «Updater doctor»):
- `as_of_s` beside `as_of`; `blind[]` names the inputs that are not ok (`state.json`, `pass`).
- `judge` is sha256 over `bin/updater-doctor`, `share/updater-ledger.json` and its limits
  (`LIMITS`, `PASS_OK`).
- `exposure` is the number of vendors checked. `count` is 1 for an event rule, the busy or
  install-failed log lines for `cli-behind`, the codex homes for `client-too-old`, the stale checks since
  the last fresh one for `caps-stale`, and null for `pass-stale`.
- Its own key `vendors[]` carries, per vendor, what the menu shows: installed, latest, result, the
  catalog newest first (12 at most) and the last 5 events.

Code doctor (added 2026-10-02, design `docs/code-doctor-design.md`):
- Groups `dead`, `heavy`, `duplicate`, `promise` (plus `ledger` for a faulty row) under the own key `groups`;
  they sum to `problem_count`, one unit: a problem is one cause, however many units it spans.
- A problem exists only once the judge (worker-run, under the night's token and wall budget) ruled
  it `problem`; an unjudged candidate is the own key `candidates.waiting`, never counted. A
  dangling outside registration needs no judge: its git research is the proof; `needs Egor:` is
  only a trade (its `trade` field) research could not settle, never no fixer by rule.
- `judge` is sha256 over `bin/code-doctor`, the ledger's `protected`, `keep`, `intentional`,
  `retired` and dismissal rows, and `LIMITS`; fix tracking leaves it unchanged.
- ids are `cause:<smallest unit>` (`<repo>/<path>[#<symbol>]`), stable while that unit lives; a
  ledger row matches `{cause}` exactly or `{identity}` (sketch overlap ≥ `clone_jaccard`), so a cause
  that returns under a new id is still `regressed`. A row with neither is a fault, `ledger:<id>`.
- A verdict is cached under a structural digest (unit digests, callers, registrations, purpose
  records, detector version), never counts or timestamps; `not-now` expires after 90 days.
- `count` and `window_h` are null; `exposure` is the cause's unit count; `value` is the judged net
  benefit. Own keys: `candidates`, `cost`, `cost_per_cause`, `yield`, `queue_k`, `coverage`
  (rollup window, deep-pass slices), `index`, `last_judge`.
- Fixer safety is mechanical, `code-doctor check` at `doctor-fix close`: a deletion needs a judged
  problem naming the unit, no live entry point, no rollup hits and a quoted purpose or retirement reason;
  a unit changed since its judgment on the base or on main goes back to the judge; no edit through a
  symlink into another repository; active work blocks; a cross-repository merge deletes the old copy
  only on a later night than its `migrated` stage.
- `bin/code-doctor record-fix` writes the fixed-pending row (with its identity and yield) and, with
  `--mechanism`, `share/canonical-mechanisms.json`, which review-bench's fit lens reads.

System doctor (added 2026-10-06, design `docs/system-doctor-design.md`):
- Machine rules `spawn`, `kernel`, `compressor`, `swap`, `swap-writes`, `ssd-writes`, `free-space`,
  `hammerspoon-crash`, `job-crash`, `unclean-reboot`, the job rule `job-loop`, the standing-cost
  rule `cohort`, the log rules `log-store`, `log-growth`, `unregistered-store`, `log-unread` (registry
  `share/log-stores.json`), `dir-growth` (a giant folder crossing 20 GB or growing 10 GB a week), `orphan-profile` and
  `profile-size`; ids `<rule>:<key>` (`machine`, a volume, a job name, a cohort
  item's name, a log store's name, `total`, a directory path). A ledger
  row matches `{rule, key}` exactly; a row without both is `ledger:<id>`.
- Own problem keys: `label` (the menu's short name), `severity` (`review` | `heavy`) and `cause`
  `{name, share, owner, fix_target, files}`; `fix_target` is true only for an own cause whose name is a
  file of a sweep repository (`files`, `repo/path`); every other cause is report-only. doctor-fix adds a
  `collector:<name>` problem per name in the document's `blind`. A proven,
  refused or pending fix carries `proof` `{verdict, why, since, ...}`.
- `status` is `blind` while the newest tick is older than 10 min or the nightly pass older than 36 h
  (own key `blind`). Own keys: `measures`, `causes` (births and CPU by cause), `nightly`,
  `costs.tick`, `log_stores` (total, growth, per store, unregistered, sweep, `apps` (an app store with a criterion
  against it), `profiles`: every LLM profile dir
  `{label, name, path, mb, age_d, status[, owner]}`, status `menu` | `off` | `home` | `unknown`, owner `llm-doctor`
  on a browser profile; a path gone since the scan is left out; `tidied`: what `system-doctor tidy` moved to the
  Trash within 7 days `{path, mb, age_d, why}`), `background` `{covered_days, groups: [{name, B, items: [{name,
  owner, B, terms, per_day, unknown, place, job, about}]}]}` (B null before 7 covered days; `terms` C W D R M L,
  `per_day` those plus S, births a day, which no B reads; `per_day.C` includes
  reaped children's CPU, the statusline journal's on `llm-legs/bin/statusline.sh`, not `claude`; `job` `{label, plist,
  schedule, missing, loaded}`, `loaded` null before any dumpstate), `limits`.
- `doctor-fix launch system` snapshots only fix-target causes (plus ledger and collector faults);
  close runs `bin/system-doctor check --record` (design, Phase 2).
