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
the palette (RED, DIM_RED, DIM, GREEN) and aligned columns carry state; every other row lives
unchanged under `LLM details`. Fixture render:

```
Doctors: 8 problems
LLM          2             ▁▁▂▃▄▆█    3 ▸
Harness      3             ▁▁▂▃▄▆█    3 ▸
Updater      0             ▁▁▂▃▄▆█    3 ▸
Code         3             ▁▁▂▃▄▆█    3 ▸
Lost time   12 min/day     ▁▁▂▃▄▆█   25 ▸
Spend     0.46 index       ▁▁▂▃▄▆█ 0.71 ▸
System       2             ▁▁▂▃▄▆█    3 ▸
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

- Summary row, fixed cells: name (9, in the status color) · value (4, right) · unit (10: `min/day` for Lost time,
  `index` for Spend, blank for counts) · 7 bars · usual (4, right, DIM), no trend arrow. Counts are bare
  (Lost time, internally Speed: Harness time budget `lost_min_day`; Spend: tokenmap's `harness_index.value` from
  `tracking.json` via `share/spend.py`, two decimals, 1.00 = the previous 7 days' harness price per unit of use, the
  value RED/GREEN by its `tone`; the problems of both stay counted by Harness alone).
- Status color of the name (no dot: `●` is the LLM Limits pin mark): GREEN ok, RED problems or collector error, DIM_RED watch/blind/pending update, DIM no data or
  stale (Speed also without an observation dated today; Spend while `tracking.json` is past its `stale_after_hours`, has no `harness_index` or its value is null). Missing value: DIM `–`.
- Bars: six completed local dates and today, daily `max` of `problem-days.jsonl` (Speed: the daily
  maxima in Harness's `menu.txt` header; Spend: its stored index of each day, the 7-day window ending that day). Eight heights against the window maximum. An unmeasured date
  is a blank cell, never an invented bar or a dash; a zero is `▁` (as every other spark line, Chats → Other's
  load graph the model). Every bar is DIM, never RED.
- `usual` is the median of measured completed dates, never today.
- A doctor's first level: up to three issue rows (RED count, the problem's own short name;
  Speed's floor gaps in min/day, plus nonempty `Needs Egor` rows), Fix, fixer, separator,
  `LLM details`. The details hold every previous row in order, the non-ordinary status title
  (stale, failed, pending) first; Lost time's and Spend's details are Harness's `Lost time:` and `Spend:` subtrees.
- Harness's `menu.txt` carries `H<TAB><JSON>` right after `T`: status, problem ids/ledger refs,
  three group issues, Speed's status, timestamp, floor, daily series and three floor gaps. The menu
  reads it and `problem-days.jsonl` cached by inode, mtime and size, never Harness's `latest.json`;
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
| `problem_count` | the N of the menu's `N problems`: problems whose state is `new`, `open` or `regressed`; the harness doctor writes `null` when its collector failed |
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
- `id`, `doctor`, `area` (`all` for a day run, `release` for a vendor-fingerprint run), `night` or null;
- `created_at`, `launched_at`, `closed_at`, `abandoned_at`, `failed_at`: ISO UTC, or null. A run is
  closed, abandoned, failed (with its `note`) or open; a launch never leaves it in between;
- `account`, `session`, `command`: the day chat's Claude account, session and command file;
- `branch`, `worktrees`: a night run's `night/<night>/<id>` and its worktree paths;
- `judge_at_launch`, `judge_at_close`: the doctor document's `judge` (a night run's from its branch
  base), or null;
- `problems`: `[{id, state, fact, rule, ledger, area, component: {what, files, rule_at}}]`, the
  snapshot at launch;
- `quiet`: the same shape with state `quiet`: the ledger's `open` rows no problem of the document
  names (its window did not see them), assigned to areas like problems; they need no decision line;
- `decisions`: `[{id, verdict, purpose, evidence}]`;
- `knobs_at_launch` (a Harness night run): `{path: [lines]}`, the model, effort and thinking lines of
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
after the loud regressions, one run per row in area `speed-<lever>` (rows sharing a component file in one run): `bin/speed-doctor` `select` charges each regression its
component's cheapest lever, then takes every opportunity with a positive score by score, with no
count or worker-hour cap (the worker slots' admission paces them), one hook lever per night. The Code doctor's snapshot takes at most K problems per run, by judged
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
- `launch llm|harness|code|system`: the day chat. Refused when the document's `contract` is not 1 or it is
  older than 2 h, when it reads `ok` with no problem and no quiet open row, or while a run of that doctor opened less than
  12 h ago is open; an older open run is marked `abandoned_at`. The chat opens through
  `share/chat-open.sh` on `docs/doctor-fix.md`.
- `launch llm|harness|updater|code|system --night <night-id>`: no chat. Per area with problems or quiet rows and no open run
  of (doctor, area), a record, a worktree `<repo>/.claude/worktrees/night-<night>-<id>` on its branch,
  and `<runs>/<id>.brief.md`; one line `<id>\t<brief>\t<worktree>` each. Nothing to do prints
  nothing, but a harness night whose Speed section selects nothing first prints `harness: Speed selects nothing:
  <why_none>` on stderr; a failed worktree or brief fails its run and the exit status.
- `launch updater`: runs `vendor-cli-update now`. Every chat `vendor-fingerprint` opens writes its
  record through `doctor-fix record updater` (area `release`): `problems` are the event ids, and each
  event's `run` names the record. It closes through `record-close` when `vendor-fingerprint close`
  closes the last of its events, one decision per event (`verdict` integrated, not-applicable,
  blocked, or the event's status when its diff had no line; `purpose` null; `evidence` the count of
  its decision rows and its note).
- `abandon <id> [--reason TEXT]`: the deadline's verb; a closed run refuses it.

`doctor-fix close <id> --decisions <file> [--doc <document>] <note>` closes any other run:
- A night run needs `--doc`, a run-local contract-1 document of its doctor (never the shared
  `latest.json`); a day run defaults to the shared one. It refuses until that document's `as_of` is
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
- A Code run also refuses while `bin/code-doctor check <record> --base refs/night/<night>/base`
  prints a line (§6).
- A Harness night run also refuses every added or removed line that sets a model, effort or thinking
  knob (`KNOBS` in `bin/doctor-fix`): in its worktrees against `refs/night/<night>/base`, committed,
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
  `unproven · …` while E < 20. E is the largest exposure of the row's rules over a window that
  started after the fix; M counts the runs that judged a regression.
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
  harness-owned component whose audit is due (never audited, a source blob moved, share ≥ 1.5× its share at audit).
  Harness-owned: hook scripts, startup instruction parts (CLAUDE.md + memory index, nested CLAUDE.md, skill listing),
  worker cold resumes, subagent/worker spawns, re-write causes tokenmap flags `avoidable`; compaction summaries, the
  other re-writes and system + tools are Claude Code's, shown and never targeted. `spend.selection` names the one a
  night audits, area `speed-spend-<component>`; `spend.proofs` holds each audited component's share and part price
  against the audit, which the night's `roi` lines read.
  Its `suites` (`share/suite_audit.py`) adds `suite_audit:<repo>:<suite>` problems, group `Suite audits`, `watch`: every
  suite of the sweep and night helper repositories priced at CPU-min/day over 7 days of run-suites' journal (every
  runner), due when never audited, the suite or a tests/ helper it names has another blob, or CPU
  a run (passing runs' p50) ≥ 1.5× the audit's; a rise ≥ 1.5× and ≥ 30 s between commits or a new suite (not a split)
  over 3× the median suite a run is due at once and names its commit. `suites.selection` is the queue by CPU-min/day; a night takes the first its red test rules do not hold, area `speed-suite-audit-<repo>-<suite>`,
  brief header `STRONG: yes` (worker-run refuses Light and Gemini Flash). Audits are `suite:<repo>/<suite>` rows of
  `share/spend-ledger.json` (`bin/speed-doctor --suite-audit`), proven once 5 runs after it read ≤ 0.75× its CPU a run.
  A night's `roi` line proves a suite, hook or wait improvement per unit (CPU-s a run, ms a call per hook script,
  s a wait) once N samples follow the night (`time_budget.UNITS`); other classes keep the day totals.

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
- Fixer safety is mechanical, `code-doctor check`: a deletion needs a judged problem naming the
  unit, no live entry point, no rollup hits, a quoted purpose or retirement reason and, at landing,
  `--suites-passed`; no edit through a symlink into another repository; active work blocks; a
  cross-repository merge deletes the old copy only on a later night than its `migrated` stage.
- `bin/code-doctor record-fix` writes the fixed-pending row (with its identity and yield) and, with
  `--mechanism`, `share/canonical-mechanisms.json`, which review-bench's fit lens reads.

System doctor (added 2026-10-06, design `docs/system-doctor-design.md`):
- Machine rules `spawn`, `kernel`, `compressor`, `swap`, `swap-writes`, `ssd-writes`, `free-space`,
  `hammerspoon-crash`, `job-crash`, `unclean-reboot`, the job rule `job-loop` and the standing-cost
  rule `cohort`; ids `<rule>:<key>` (`machine`, a volume, a job name, a cohort item's name). A ledger
  row matches `{rule, key}` exactly; a row without both is `ledger:<id>`.
- Own problem keys: `label` (the menu's short name), `severity` (`review` | `heavy`) and `cause`
  `{name, share, owner, fix_target, files}`; `fix_target` is true only for an own cause whose name is a
  file of a sweep repository (`files`, `repo/path`); every other cause is report-only. A proven,
  refused or pending fix carries `proof` `{verdict, why, since, ...}`.
- `status` is `blind` while the newest tick is older than 10 min or the nightly pass older than 36 h
  (own key `blind`). Own keys: `measures`, `causes` (births and CPU by cause), `nightly`,
  `costs.tick`, `limits`.
- `doctor-fix launch system` snapshots only fix-target causes (plus ledger and collector faults);
  close runs `bin/system-doctor check --record` (design, Phase 2).
