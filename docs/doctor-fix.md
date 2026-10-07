# Doctor fixer run

One run of one doctor's fixer: by day a chat Egor's Fix button opened, at night a headless worker on
one area (`docs/night-run.md`). Work autonomously and go deep. Updater release events follow
`docs/vendor-release.md`; shared shapes are in `docs/doctors-contract.md`.

## 0. Entry

- Run `bin/doctor-fix show <run id>` (a night brief carries it). Per problem: the snapshot, its
  ledger row, earlier runs' decisions, the component with its files and rule line, each file's first
  and last 5 commits, and the handoffs, invariant rows and memory files naming it. These ids are your
  scope; a problem that appeared after launch goes into the report for the next run.
- Its `known, quiet` rows are open ledger rows the doctor's window did not see: check in the code
  whether each cause still stands, then fix it or write in the row's `note` why not. They need no
  decision line.
- Read this common part and your own doctor's section below; skip the other doctors' sections.

## 1. Purpose before fixes

1. For each problem, before deciding anything, name the component that produces or suffers it: a hook, gate, collector, launcher, worker path, or
   a rule of the doctor itself. The packet names it when existing data can.
2. Learn why it exists: the packet first, then `git log -S`, the design doc, the handoffs.
3. Write its goal in one sentence. Then judge two things apart: does it do what it says, and does
   doing that reach the goal.

   Egor's example: a hook forcing English between models did what it said. It denied a message and
   made the model write it again. Yet its goal, fewer tokens, was missed, because the rewrite cost
   more than it saved. Only its history showed that.
4. A change that turns a row green while the goal stays missed is not a fix.

Each decision line's `purpose` column cites where the goal is stated, and it must touch the
component: one of its files (`path` or `path:line`), or `repo@hash` of a commit that changed one.
A problem whose packet names no component file (a machine-wide row) closes with its decision
recorded `component: unverified`, shown by `doctor-fix show` and `night-run report`.
`doctor-fix close` refuses anything else.

## 2. Decide every problem

| verdict | when | what you leave behind |
|---|---|---|
| `fixed` | a clear bug, or a component of ours that works as specified but misses its goal | the fix (a change or a deletion; deletions beat additions), a test red on the old code, a `fixes[]` entry and status `fixed-pending` per your doctor's section |
| `ruled-out` | not a bug of ours | an `open` ledger row narrowed to this cause, the reason in its `note`, and a handoff proposing the dismissal to the owner |
| `weather` | vendor-side or external | the same as `ruled-out` |
| `blind-spot` | cannot be measured yet | a ledger `blind_spots` row with `would_catch_if` |
| `handoff` | research cannot settle it here, or it would loosen the judge; to Egor only as a trade (`Cost:`/`Loss:`/`Recommendation:` lines); never test speed or `menu_build` (`close` refuses it) | `docs/handoffs/<date>-<topic>.md` with a `Status: open` line and the row's `handoff` pointing at it. It is addressed to the next night, whose `night-run carry` makes it a job; a chat is its addressee only while live right now |

Clear bugs are fixed, never handed off. A fixer never writes a `not-a-bug` or `weather` row: the
narrowed `open` row keeps the cause on record without loosening the judge, and the owner decides the
dismissal.

Done means the run is closed with every `fixed` row at `fixed-pending`. Proof is the doctor's later
job (your section says what it counts); never wait for it.

## 3. Watch for

- **Repeated or complex fixes.** A row with more than one `fixes[]` entry, or a `same_cause` group,
  means the earlier fixes missed the cause. Find the shared cause instead of patching again.
- **No bulk.** No new layer, switch, mode or prose rule where a deletion or an existing mechanism
  (journals, registries, trackers, word families) does the job.
- **The doctor's own blind spots, bounded.** When a cause you met was not a problem in the document,
  add a `blind_spots` row with `would_catch_if`. Record, do not build: a new detector is its owner's
  work, not a fix run's.
- **The judge is not yours to loosen.** See your doctor's section.

## 4. Ground rules

- Work in a worktree per repository you change, per `~/.claude/docs/worktrees.md`. By day the
  branch is `doctor-fix/<run id>`; at night see Night.
  - By day, pour the result into main uncommitted, as `docs/vendor-release.md` §3 step 14 does.
    Never revert, stash or overwrite someone else's uncommitted work. Never commit, push or review:
    Egor's end-of-day pass does all three.
- Tests use fixtures only. Never point one at `~/.claude-profiles/.claudeb`, and never mutate the
  live Hammerspoon singleton.
- A hook or gate change gets an adversarial edge-case critique (missed catches, false catches)
  before it counts as done. A worker's "done" is a claim: diff every test it changed against HEAD.
- Comments near zero. Never generate an image.

## 5. Close

1. Rerun the doctor. By day, `bin/llm-doctor --quiet`, `bin/harness-doctor --quiet` or
   `bin/updater-doctor --quiet` rewrites `latest.json`; at night close reruns it (see Night).
2. Write a decisions file with one line per problem id of the run:
   `id<TAB>fixed|ruled-out|weather|blind-spot|handoff<TAB>purpose<TAB>evidence`. `evidence` is a
   test name, a `file:line`, a document fact or a handoff path. If `judge` moved since launch, add
   `judge<TAB>changed<TAB>purpose<TAB>why`, the purpose a file of the judge (the doctor or its
   ledger) or a commit that changed one.
3. Run `bin/doctor-fix close <run id> --decisions <file> <one-line note>`. It refuses until every
   id is decided, every citation resolves and touches its component, and every `fixed` id reads
   `fixed-pending` or is gone in the doctor's document, which must not read `status: error`; it
   refuses an abandoned or failed run. A launch on a `status: error` document snapshots one
   problem, `collector:error`, whose component is the doctor itself.
4. Rewrite the `Status:` line of every handoff you settled.

## 6. Report

By day to Egor in short Russian, at night to the orchestrator in English: per problem the verdict,
one line of why and where it was fixed and tested; handoffs and blind spots added; what was poured
(day) or committed as `repo@hash` (night). No session ids, diffs or transcripts.

## Night

The brief (`<runs>/<id>.brief.md`) names your area, worktree and branch `night/<night-id>/<run-id>`.
It replaces the pour:
- Work only in that worktree and the `ADD-DIR:` worktrees at the top of the brief: one per other
  repository the components name (every sweep repository for a run holding test speed), on the same branch, started from that repository's
  `refs/night/<night>/base` (main as pressed, uncommitted work included). A change in any other
  repository is a handoff. Never write a main checkout: hooks and other chats read it.
- Commit on your branch (one long line). Never push, review or merge: the orchestrator reviews the
  branch, has you fix findings, rebases and pushes.
- Never ask Egor anything and never stop on a question: decide, or hand off (§2).
- Close from the worktree. It reruns `bin/<doctor>-doctor --json` there itself into
  `<runs>/<id>.d/latest.json` (live journals, your branch's code and ledger, nothing shared written),
  never the shared `latest.json` that launchd and other fixers rewrite. The judge is compared with
  your branch's base, so a limit or dismissal you changed shows.
- Markdown is net zero: `close` refuses a worktree whose `*.md` bytes (committed, untracked, deleted)
  grew since `refs/night/<night>/base`; cut stale lines (`~/.claude/docs/context-file-hygiene.md`).
- No deadline ends a run. A worker the `worker-run` watchdog stopped for no progress is hung: the
  orchestrator abandons its run, which closes no more, and its branch stays unmerged.

## Updater doctor

Owner: the chat «Updater doctor» (`share/updater-ledger.json` `owner`). Scope at night: the doctor's
own machinery (`pass-stale`, `pass-failed`, `cli-behind`, `client-too-old`, `probe-broken`,
`event-stuck`, …) and `caps-stale`: re-verify that manifest section through its route's own check (one smallest
`bin/media-run` take, the media skill), edit it until the footer reads fresh, bump `verified`; never research
vendor options by hand. `event-waiting` is `vendor-fingerprint`'s. Read `latest.json` `vendors[]` and
`blind[]`, then the ledger; recompute with `bin/updater-doctor --json`. The judge (`bin/updater-doctor`,
its ledger, `LIMITS`, `PASS_OK`) is not yours to loosen; a loosening is a handoff to the owner.

## Harness doctor

Owner: the chat «Harness Doctor» (`share/harness-ledger.json` `owner`). Scope: what makes a chat or
a worker wait that is not the model — call waits, hook floors, hook cost and cuts, load, tests,
store growth.

### Read first, in this order

1. `~/.cache/harness-doctor/latest.json`: `status`, `problems[]` (`id`, `rule`, `state`, `value`
   against `limit`, `exposure`, `evidence[].ref`), `blind_spots[]`, `self`. `status: error` means
   the collector failed: `self.error` names the exception and its line; fix that first.
2. `share/harness-ledger.json`: the row named by a problem's `ledger` (the packet shows it).
3. `docs/harness-doctor-design.md` §3 (signals) and §4 (limits and their calibration) for the rule.
4. `docs/DIAGNOSTICS.md`, the Harness doctor rows.

`evidence[].ref` names one event: `tool_use <id>`, `test-history <repo> <label> <end>`, a cut's
event and time, the Stop hooks/Guards refs of design §11, or `holds/<file>` (design §12).
A `new` problem has no ledger row; add one with a `match` of `{rule, ident}` whose `ident`
regex matches that problem's identity only: at least 3 literal characters, never the empty ident,
none of the doctor's random probe idents, and for `not-a-bug`/`weather` one exact ident with no
pattern. Anything wider is a ledger fault: the row judges nothing and shows as `ledger:<id>`.

### Recompute and prove

- Now, writing nothing: `bin/harness-doctor --json | jq '.problems'`; at a given time prefix
  `HARNESS_DOCTOR_NOW=<epoch>`. `bash tests/test_harness_doctor.sh` replays the committed fixture
  `tests/fixtures/harness-calibration/` and pins its problem ids.

Proof (the doctor's, later): `fixed · E events since · 0 matched` with E ≥ 20 (`PROOF_MIN_EXPOSURE`)
over a window after the fix's `at`; a quiet row alone proves nothing. Record a `fixes[]` entry with
`in: null` and status `fixed-pending`; the doctor fills `in` once every listed file is committed.
Never edit `in` by hand.

### Test speed and menu delays are yours

`test_long_pole`, `test_daily_cost`, `test_slow`, `suites_at_once`, `test_hang` and `menu_build` are fixed by the
run that holds them, never handed off: `close` refuses a `handoff` line for them. Test speed: split a
long pole into independent suite files `tests/run-all` runs in parallel, cut redundant cases, make
timing asserts load-robust, cache fixtures, in any sweep repository (a night run holding one gets a
worktree in each); every assert keeps its coverage. A hung suite (`test_hang`) is the same: fix why it
blocks (stdin from /dev/null, a timeout on a waiting child, a tty probe) until the doctor reads no
`test_hang` row for it. Menu delays: the packet names the menu's build
files (`hammerspoon/automation_menu.lua`, `llm-legs/hammerspoon/llm-limits.lua`).

### Speed: same intelligence, less waiting

A `speed` run holds the Speed block's regressions and its chosen `opportunity:` rows; each carries
its lever, saving and proof in `opportunity` and `docs/speed-doctor-design.md` §5 bounds what may
change. Never touch a model, effort or thinking knob: a night `close` refuses any such added or
removed line and names it (`docs/doctors-contract.md` §4).

### The judge is not yours to loosen

The judge is `LIMITS` and the rules in `bin/harness-doctor`, the dismissal rows of
`share/harness-ledger.json`, and the pins in `tests/test_harness_doctor.sh` (`PINNED`,
`PROOF_MIN_EXPOSURE`, the ledger guards). `latest.json` `judge` changes whenever any of them does.
A fixer never raises a limit, widens a `match`, or adds a `not-a-bug`/`weather` row to make a
problem go away; a loosening goes to the owner chat as a handoff.

## LLM doctor

Owner: the chat «LLM Doctor меню refactoring» (`share/doctor-ledger.json` `owner`); each block's
triage chat is in `owners`. Scope: why review cells, worker runs, light runs and image legs fail,
escape or run slow; the review machinery classes; review-debt health. Stop hooks, word notices and
the instruction-watch guards are the Harness doctor's.

### Read first, in this order

1. `~/.cache/llm-doctor/latest.json` (`bin/llm-doctor --dry-run --json` prints a fresh one):
   `status`, `problems[]` (`id`, `rule`, `state`, `value` against `limit`, `exposure`,
   `evidence[]`), `blind` and `inputs[]` (a required store that is not `ok`), `blind_spots`, `self`.
   `status: error` means the collector failed: `self.error` names the exception; fix that first.
2. `share/doctor-ledger.json`: the row named by a problem's `ledger` (the packet shows it).
3. `bin/llm-doctor --block <block> --dry-run --json`: the block's `problems[]` with the same `id`
   carry every incident (`event`, `ref`, `detail`, `chat`) and the 14-day `daily` series.
4. `docs/DIAGNOSTICS.md`, row "Which legs keep failing", and shared-invariants rows `cq`/`cw`.

`evidence[].ref` names one event: `bench:<run>/<rater>#<index>` (a `rater_runs` row),
`bench:<run>/judge|panel`, `run:<name>[/walled:<account>]`, `prelaunch:<ts>/<account>`,
`image:<ts>/<tool>/<account>`, `gaps:<session>/<kind>/<at>`, `losses:<at>/<kind>`, `snapshot:<class>/<row>`. A
`new` problem has no ledger row; add one whose `match` names its word plus a `model` or `detail`
regex that matches this cause only. A catch-all is a ledger fault: it judges nothing and shows as
`ledger:<id>`.

Triage notes that outlived their rows: a `pool empty` on reviewers is a cell staffed on a vendor
closed before its run began (closed mid-run reads `off`; a pool empty only because every account is
walled is `walled`); a `bad command` is only the CLI's own refusal after launch (a prelaunch
`EFFORT_REFUSED`/`MODEL_REFUSED` is the guard working, `off`); an `escaped` can be legitimate for a
cross-repository brief — triage it with a model or detail row, never by dismissing the class.

### Stuck review rounds

`machinery:closure_pending` rounds of the sweep repositories (`~/.claude/sweep-repos`) are yours to
settle, not the owner's or Egor's; the class row itself stays `open`. A round of any other project is
never touched, read or listed: its project is Egor's (2026-10-01). `review-bench doctor --json` lists
them (`id`, `repo`, `session`); `review-bench fix <id> --print` prints a round's unsettled findings. Per round:

- Skip it while its chat is live: a `~/.claude/sessions/*.json` with its `sessionId` whose `pid` is alive.
- Judge each finding against the code in `repo` now, read-only:
  - resolved → `review-bench record <id> --verdicts <file>` with a row
    `{"kind":"fixer","finding":<index>,"outcome":"fixed"}`;
  - its code gone → once every finding left is gone, `review-bench close <id> --nofix --reason "code gone: <what>"`;
  - still holds → leave it open: night debt, named in the report with its round and index for the
    orchestrator to fix;
  - you cannot judge it → leave it open and name it in the report.
- The store is written only through the review-bench CLI. The decision's evidence counts each outcome.

Browser words (`browser drift|upload|download|not sent|no output|price|profile|hide|owner step|other`,
image block) are failed steps of the hidden-Chrome routes: `gemini-video`/`gemini-sfx` on Google Flow,
`gemini-music` on the Gemini app (`share/gemini_web.py`, `share/gemini_music.py`, Playwright clicking the
real page). The excerpt is the engine's `BROWSER_FAILURE` line: route, account, `shot=` (the screenshot
under `~/.gemini-web/failures/`, with a `.txt` beside it: URL, open dialogs, toasts, visible buttons, page
text) and the reason. Read both files before touching a selector: most causes are a renamed button, a
new dialog or notice, or a changed upload flow. Reproduce for free with `gemini-web generate … --dry-run`
or `media-run music --vendor gemini -- --dry-run …`; a live generation spends credits and needs
Egor's word. Never replace a UI step with an RPC replay. `owner step` is an account that needs Egor's
one-time action (sign-in, a rights notice: the excerpt names it); relay it to him, never click it yourself
without his yes. Superseded attempts (`…#n` refs) are accounts the rotation skipped before another one
served: `watch` after `RECOVERED_MIN`. A ledger row narrows with `{word, detail}`, `detail` a regex over
the reason (`^Upload files opened no file chooser`).

### Recompute and prove

- Now, writing nothing: `bin/llm-doctor --json | jq '.problems'`; at a given time prefix
  `LLM_DOCTOR_NOW=<epoch>`; from fixtures `bash tests/test_llm_doctor.sh`.

Proof (the doctor's, later): `fixed Nd · E since · 0 matched` with E ≥ 10 (`PROOF_MIN`) final legs
of the row's block (and model) that STARTED after the last fix's `at`, or after its `in` reached
main when that came later. Record a `fixes[]` entry
`{at, by, files, in: null, regressed_at: null}` (`files` as `repo/path`, one repository per entry)
and status `fixed-pending`; the doctor fills `in` once git shows every file committed after `at`.
Never edit `in` by hand. A regressed fix keeps its entry (set `regressed_at`); the re-fix is a new one.

### The judge is not yours to loosen

The judge is `bin/llm-doctor` (the vocabulary copied from review-bench `panel.py`, which words are
`theirs`, the exemptions `PROFILE_HOME_RE`/`MAIN_STATE_RE`/`is_scratch_path`, `PRELAUNCH_SKIP`, and
the thresholds `limits()` lists), the ledger's `not-a-bug`/`weather` rows, and the pins in
`tests/test_llm_doctor.sh`. `latest.json` `judge` changes whenever any of them does. A fixer never
raises a limit, widens a `match`, moves a word to `theirs`, or adds a dismissal to make a problem go
away; a loosening goes to the ledger's `owner` as a handoff. Caps are caps: an agy cap kill is
weather, never a reason to drop a cell or a vendor or to raise a cap.

## Code doctor

Owner: `share/code-ledger.json` `owner`. Design: `docs/code-doctor-design.md`. Scope: the problems the
snapshot hands you, top-K by judged value (`docs/doctors-contract.md` §4): dead units, heavy tests,
hooks and always-loaded text, duplicate mechanisms, promises no code keeps (`kind: broken` with `fix: code | claim`, or
`untested`), each with the judge's `plan` and `proofs`. A promise fix lands a test red without it, or rewrites the claim
to what the code does and says why the code stays; an overclaim fix makes the mechanism print a receipt.
A `code-doctor --repo` document of a repository outside sweep-repos is report-only (`launch code`
refuses it, its snapshot is empty, `check` fails): its problems are for Egor to read.

### Read first, in this order
1. Each problem's `plan`, `proofs` and units in `latest.json`, and the judgment in
   `~/.cache/code-doctor/verdicts.json` (its `reason` quotes the purpose or retirement record).
2. The ledger row, if any: `protected`, `keep`, `intentional` and `retired` say what must stay.
3. The units' git history (`doctor-fix show <id>`).

### Recompute and prove
- `bin/code-doctor refresh` reindexes and recomputes; `bin/code-doctor check <record> --base
  refs/night/<night>/base` is the proof close runs: a deletion names a judged unit with no live entry
  point, no rollup hits and a quoted reason. Run the suites of every repository you touched; the
  orchestrator lands the job with `night-run job set … state=merged suites=passed`, which reruns the
  check against main as it is then.
  The check reads the run's own snapshot, never the live document; a run whose worktree is gone fails it,
  and a day run (no worktree) is checked over main's commits since its launch.
- A unit that changed since the night base is not yours: its verdict went back to the judge.
- After a landed cleanup, `bin/code-doctor record-fix <cause> --by <run id> --files … --lines-removed N`
  (plus `--mechanism`, `--canonical`, `--replaced` when one module now owns the job), so the doctor
  reads it `fixed-pending`, counts the yield, and review-bench's fit lens learns the canonical module.

### Never
- Edit through a symlink into another repository, or a registration outside the repositories (the
  night judge settles dangling PATH links and LaunchAgents; you edit an in-repo settings file).
- Delete both copies' old paths of a cross-repository merge in one night: the shared module and the
  callers land first (ledger row `merges: [{stage: "migrated", night}]`), the old copy on a later night.
- Loosen `LIMITS`, the ledger's protections or a verdict: that is a handoff to the owner.

## System doctor

Owner: `share/system-ledger.json` `owner`. Design: `docs/system-doctor-design.md`. Scope: problems whose
top cause is an own script of the sweep repositories; Apple and third-party causes never reach you.

- Read each problem's `fact` and `cause` in `~/.cache/system-doctor/latest.json`, its `causes`
  (births and CPU by script) and the packet's levers. Find what makes that script spawn or burn CPU.
- Output-equivalent changes only; never touch a model, effort or thinking knob (close refuses one).
- Record a fix as a ledger row `{id, title, status: "fixed-pending", match: {rule, key, cause},
  fixes: [{at, by, files, in: null, regressed_at: null}]}`. Close runs `bin/system-doctor check
  --record`: a `fixed` births/CPU cause needs that row and 30 sightings in the 7 days before.
- Proof is the doctor's (design, Proof): `bin/system-doctor check <cause>`. Not proven stays open
  with its numbers for the next run.
- The judge (`LIMITS`, `PROOF`, the ledger's dismissals, `tests/test_system_doctor.sh` pins) is not
  yours to loosen: a handoff to the owner.
