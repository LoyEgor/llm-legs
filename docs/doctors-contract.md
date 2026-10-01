# Doctors contract

What the LLM doctor (`bin/llm-doctor`), the Harness doctor (`bin/harness-doctor`) and the Updater
doctor (`bin/updater-doctor`) share, so that one menu entry and one fixer
procedure can serve all three. Version 1, written 2026-09-29 by the chat «Updater doctor» from two
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

Who builds what:
- **Each doctor's owner chat** builds its document and ledger in this shape, its section of
  `docs/doctor-fix.md`, and the tests that hold both.
- **The chat «Updater doctor»** builds the Doctors menu entry, the Fix button, the launcher, the run
  record, the common part of `docs/doctor-fix.md`, and the Updater doctor.

## 1. Document envelope

Each doctor keeps writing its `latest.json` (`~/.cache/llm-doctor/`, `~/.cache/harness-doctor/`,
`~/.cache/updater-doctor/`)
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

`new` means that no ledger row matched. Catch-all rows are not allowed (§2), so an unseen cause is
always `new`.

## 2. Ledger

There is one file per doctor, with the same row shape:
- `share/doctor-ledger.json` for the LLM doctor;
- `share/harness-ledger.json` for the Harness doctor;
- `share/updater-ledger.json` for the Updater doctor, whose rows match an exact `{rule, key}`.

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
- `note`.

Areas: the LLM doctor's block (from the ledger row, the id or the document's blocks), else its health
row (the ledger row's `match.health`, or the `health[]` row whose `rules` hold the problem's rule); the
Harness doctor's section of the rule; else `doctor` (`share/doctor-areas.json` `own`), which is every
Updater rule but `event-waiting`. Old runs' `health`, `self` and `machinery` read as `debt`, `doctor`
and `doctor` (`renamed`). The snapshot keeps the problems not `watch` or
`fixed-pending`, plus, for the Harness doctor, the top 8 `watch` rows of Hooks and Hook waits by
value × exposure.

The menu reads `doctor-fix runs [doctor] [--open] [--json]` (newest first) to show "fixer ran N d ago
· closed / still open". `doctor-fix show <id>` prints the run and, per problem, the packet: its
ledger row, earlier decisions on the id, the component and its git history, and the handoffs,
invariant rows and memory files naming it. Launch:
- `launch llm|harness`: the day chat. Refused when the document's `contract` is not 1 or it is
  older than 2 h, when it reads `ok` with no problem and no quiet open row, or while a run of that doctor opened less than
  12 h ago is open; an older open run is marked `abandoned_at`. The chat opens through
  `share/chat-open.sh` on `docs/doctor-fix.md`.
- `launch llm|harness|updater --night <night-id>`: no chat. Per area with problems or quiet rows and no open run
  of (doctor, area), a record, a worktree `<repo>/.claude/worktrees/night-<night>-<id>` on its branch,
  and `<runs>/<id>.brief.md`; one line `<id>\t<brief>\t<worktree>` each. Nothing to do prints
  nothing; a failed worktree or brief fails its run and the exit status.
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
  install-failed log lines for `cli-behind`, the codex homes for `client-too-old`, and null for
  `pass-stale`.
- Its own key `vendors[]` carries, per vendor, what the menu shows: installed, latest, result, the
  catalog newest first (12 at most) and the last 5 events.
