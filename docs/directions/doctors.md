# Doctors (direction 7)

The doctors (LLM, Harness with Speed, Updater, Code, System) and the night's use of them. Two parts:
- Doctor fixes: `doctor-fix launch --night` on a full night (`docs/doctor-fix.md`).
- Deep search: the night looks for what no doctor shows and makes a doctor see it. A doctor is a helper that gives
  hints, never the scope (Decisions).

## Metric

False-alarm share: the share of decided doctor rows whose fixer run changed nothing because there was nothing of
ours to change (verdict `ruled-out`, `weather` or `not-applicable`), 7 days against the 7 before. Target: falls and
stays down.
- It is a ratio of the rows the night actually spent a fixer on, so it does not grow with the number of rows or
  nights. Each false alarm is a full fixer reading paid for nothing. `handoff` and `blind-spot` rows are real and
  count as found. A run's local day is its `created_at` in EEST.
- Out of it: `suite_audit`, `cpu_audit` and `spend_audit`, whose reopens belong to their audit (Lost time, Decision
  10-16; goals `suite-own-cost`, `cpu-audit-own-number`, `audit-due`). Own line here; their drop is a bonus.
- Second number, outside-found share (Deep search part, falls too): real problems first recorded outside a doctor's
  rules, over all real problems first recorded in the window. Outside means a log-audit row (`match.rule
  log_audit`) or a `blind_spots` row; inside means any other ledger row. Real means its status today is not
  `not-a-bug`, `ruled-out` or `weather`.
- Guard: neither number sees a row not launched, so holding a Fix row back (ruling-holds, doctor-fix's skips, a
  muted false rule) lowers the first and leaves the second flat. Beside them: rows held a night (in the document,
  not launched) and held rows later decided `fixed`. Nothing records holds today (skips go to stderr); ruling-holds
  adds the run's `held` list. Baseline, its replay: 26 held in 10-06…12's six nights, 24 in 10-13…14's two, 10 / 4
  of them decided `fixed` at that launch. A fall with a guard number above baseline is unclear, never better.

### Baseline (computed 2026-10-20)

No night has run since 10-14. The run records sit in six nights, then two (`20261012T233034Z-3131` on 10-13, `20261014T013750Z-8004` on 10-14). `20261014T010328Z-6468` started 10-14 and launched no fixer.

| | 10-06…12 | 10-13…19 |
|---|---:|---:|
| fixer runs / decided rows, all rules | 166 / 345 | 133 / 671 |
| **false-alarm share** (non-audit rows) | **24.6 % (79 of 321)** | **38.1 % (82 of 215)** |
| their share of Claude spend / fixer wall-min | 1.21 % / 1,206 | 1.38 % / 4,330 |
| audit rows, own line: false of decided (share of spend) | 18 of 24 (0.45 %) | 166 of 456 (2.25 %) |
| **outside-found share** | **41.6 % (84 of 202)** | **36.9 % (38 of 103)** |
| outside: log-audit rows / blind spots added | 57 / 27 | 12 / 26 |
| blind spots closed (open on 10-20: 81) | 5 | 0 |

- First point after the baseline: 10-20's day wave (46 fixer runs a chat launched unasked, stopped midway): false-alarm
  share **48.1 % (13 of 27)**, audit rows 21 of 29.

- Recompute the false-alarm share in about 1 s:
  ```
  python3 -c 'import json,glob,os,datetime as T
  A={"suite_audit","cpu_audit","spend_audit"};F={"ruled-out","weather","not-applicable"};n={}
  for f in glob.glob(os.path.expanduser("~/.cache/doctors/runs/*.json")):
    d=json.load(open(f));v={x["id"]:x["verdict"] for x in d.get("decisions") or []}
    day=str((T.datetime.fromisoformat(d["created_at"].replace("Z","+00:00"))+T.timedelta(hours=3)).date())
    w="A" if "2026-10-06"<=day<="2026-10-12" else "B" if "2026-10-13"<=day<="2026-10-19" else 0
    for p in d.get("problems") or []:
      if w and p["id"] in v and p.get("rule") not in A: c=n.setdefault(w,[0,0]);c[0]+=1;c[1]+=v[p["id"]] in F
  print(n)'
  ```
- Outside-found share: `git log --reverse --format='%H %ct' -- share/<doctor>-ledger.json` for harness, doctor,
  system and code (not updater, not spend). The first commit that contains a row id or a `blind_spots` id dates it
  (`%ct` as EEST). A row counts only when today's status is outside `not-a-bug`, `ruled-out` and `weather`
  (`match.rule` `log_audit` is outside, any other rule inside). A blind spot counts on that first day even if
  today's file has dropped it. Closed means the id's last removal from `blind_spots` falls in the window: 10-06
  memory-owners and launchd-runs; 10-07 short-lived-origin, load-red-unattributed and wait-caller-kind
  (wait-caller-kind also left and returned on 10-06).
- Spend: `~/.local/share/tokenmap/tokenmap.sqlite3` `requests` (`mode=ro`), `sum(cost_in+cost_out)`, `vendor='claude'`,
  `cwd` like `%/worktrees/night-<night>-<run file stem>%`, split evenly over every problem in the run record; a run
  with no `night` adds nothing. Window totals by UTC `ts`: A `2026-10-05T21:00:00`…`2026-10-12T21:00:00`, B
  `2026-10-12T21:00:00`…`2026-10-19T21:00:00`. Dollar cost, not `tokenmap/pie.py` `model_weight` (that share is
  1.095 / 1.318 %, audit false 0.495 / 2.29 %). Fixer wall-min: `launched_at` → `closed_at` split the same way,
  0 with no `closed_at`; it includes slot and limit waits (how long a row held a slot, not how long it was worked).
- Chat-found problems have no record (Open). Egor's fault-word messages in harness chats: 123 and 77, unconfirmed
  (no command, chats not read). One sourced instance: System `swap_gib_day` 398 GiB on 10-14, then 79, 118, 0.3,
  32, 74, 1,112 through 10-20; `swap-writes` shows the bytes, not who writes them (`memory-owners` closed 10-06).

## Sources

- Fixer runs `~/.cache/doctors/runs/<id>.json`: `problems` (the snapshot at launch, with `component`),
  `decisions` (`verdict`, `evidence`), times, `night`. Night records `~/.cache/doctors/nights/<id>.json`.
- Ledgers `share/{harness,doctor,system,code,updater}-ledger.json`: rows (`status`, `fixes`, `ruled_at`) and
  `blind_spots` (63, 8, 6, 1, 3 on 10-20). Documents `~/.cache/<doctor>-doctor/latest.json` (contract §1).
  Log audit `~/.cache/doctors/log-audit/`.
- The 10-20 night-cost research (applied in c746800c): Spend reopens 11 of 12 ruled out; suite source-edit re-audits 13 measured drops in 61; CPU's biggest find from a source-edit reopen.

## Recurring classes

Numbered as the goals cite them, both windows; rows are A / B, spend and wall split as in Baseline. Class 0 is
the false audit rows from the false-alarm command (`rule` in `suite_audit`, `cpu_audit`, `spend_audit`). Class 1
is by command: the ruling-holds replay's count (non-audit, verdict `ruled-out` or `weather`, an earlier run's such
verdict closed within 168 h before this launch). The hand pass had it at 31 / 20 (0.47 / 0.29 %, 592 / 1,166
min); its extra rows are not reproduced. Classes 2–5 (*) are hand-made: a keyword partition of the 79 and 82 false
non-audit rows on `fact` and `evidence` that a fresh pass on 2026-10-20 did not recover from a command.

| class | rows | share of Claude spend | fixer wall-min | owner |
|---|---:|---:|---:|---|
| 0. an audit comes due with nothing to change (suite, CPU, spend) | 18 / 166 | 0.45 / 2.25 % | 959 / 12,850 | its audit's block (10-16) |
| 1. a row ruled out is raised and ruled out again, nothing new since the ruling | 16 / 12 | 0.34 / 0.11 % | 309 / 690 | here |
| 2.* a priced lever measured absent (Speed `opportunity`, `test_hang` lock waits) | 9 / 23 | 0.29 / 0.48 % | 300 / 2,053 | here, Open |
| 3.* load or noise read as a rise (`regression`, `opportunity`, `floor`) | 4 / 14 | 0.13 / 0.31 % | 57 / 632 | Lost time (its rows) |
| 4.* a log-audit reading of model or chat conduct sent to a fixer | 23 / 7 | 0.18 / 0.10 % | 98 / 138 | here, Open |
| 5.* a landed fix's pre-fix tail still in a 7-day window | 9 / 12 | 0.11 / 0.10 % | 122 / 227 | here, Open |
| 6. a cause no doctor shows: blind spots added and never built | 27 / 26 added, 5 / 0 closed | | | here |

Why they come back:
1. Only the Harness doctor remembers a ruling (`problems_from`, below). LLM, System, Speed `watch` rows without a
   ledger row, and log-audit rows reach the next snapshot whatever a run decided, so the fixer finds the earlier
   decision and rules the row out again: LLM M2's stuck round 10-06, 10-07, 10-08; M4's one 09-30 handoff on 5
   nights; `I48` re-filed; `machine/contention` and `chat/tools` re-checked 10-12 and 10-14.
2. Speed ranks an opportunity by its estimated saving (blind spot `delegation-model-time`), and ranks it the same
   after a fixer measured it flat; unconfirmed whether any measured result feeds back.
4. Every log-audit finding becomes a Harness row; none of the 105 packets of 10-06…19 names a component file, and
   conduct (re-asked decisions, a chat's brief, a bench lane) has no fixer. It shrank 23 → 7 on its own.
5. The contract's after-fix rule (§2: an event regresses a fix only if it ran on code holding it) covers matching,
   not values. A 7-day aggregate re-raises a landed fix until its tail leaves the window (6 `test-health/heavy`
   rows on 10-12 ruled out as "already cut" or "already 3 shards"; 9 false System `cohort` rows on 10-14, the
   false-alarm command with `cohort` in the id).
6. Contract §3: a fixer records a blind spot and "never builds the detector in a fix run: that is the doctor
   owner's work"; owners are day chats, no night job takes them. 53 added in 14 days, 5 closed, one came back.

## Goals

Doctors' goals run after blocks 1–6 (PILOT order). Their reads need section 7 back (How the block runs at night).

### goal ruling-holds: every doctor's ruling holds until something new, by the Harness doctor's rule

Class 1. The fix goes where every doctor's rows pass, so a new doctor gets it too.
- Change, in llm-legs `bin/doctor-fix` `snapshot()`: a problem not `regressed`, whose id an earlier closed run
  decided `ruled-out` or `weather`, is held: out of `problems` and `quiet` (the packet shows `quiet` to the fixer),
  into the run's `held` list with that run's id. The Harness rule (`problems_from`, the `ruled_at` test), with that
  run's `closed_at` as `ruled_at`: it launches once an `evidence[].at` is later, or with no times once its own
  `window_h` (168, 24 or 48 h today) has passed. Two differences: Egor's 10-13 rule, absent there, launches it when
  `value` ≥ `spend.SHARE_RISE` (1.5×) its value at the ruling, read only when `window_h` ≥ 72 h (his 7- or 3-day
  trend, never a one-day spike; the snapshot starts recording `value`); a problem with no `window_h` (137 of 399
  Harness rows on 10-20) holds 168 h; the Harness rule has no case for it. Menu and Harness ledger rule untouched.
- Proof, a replay (no pilot night runs fixers). Run `snapshot()` old and new over the run records 10-06…14: each
  run's `problems` stand in for the document, and the decisions of runs closed before its launch stand in for
  history (any earlier run, not only 10-06…14). Before, non-audit rows only: 28 whose verdict is `ruled-out` or
  `weather` and whose id has an earlier `ruled-out` or `weather` with `closed_at` within 168 h of this launch
  (16 / 12; the 168 h cap removes none), and 11 decided `fixed` with exactly one such earlier verdict inside 168 h.
  Snapshots kept no evidence times or values, so that part is unclear and the read below settles it. Target: new
  launches none of the 28, and each of the 11 launches again by 7 days after its ruling (delayed, not lost). Not
  worse: `regressed` rows all launch. Net lines of `bin/doctor-fix` and its test shown; none of the 28 held → revert.
- Read after section 7 is back: rows ruled out again within `window_h` of a ruling, target 0 a night. Fixes after
  a ruling still arrive, about 11 per 14 days before; the Metric's guard (held a night, held then `fixed`) stays at
  or under its baseline. Class 1's spend share goes below 0.11 %.

### goal blind-spot-builder: the night builds what a blind spot says would catch it

Class 6, Egor's 10-13 rule: when the night finds what a doctor does not log, the doctor learns to log it.
- Change: the Deep search job (README, The whole night) takes the open `blind_spots` of every ledger as its queue.
  The order is the outside finds that name a blind spot's area (log-audit `~N min`, fixer evidence) by cost. It
  takes the top ones a night, as far as its time bound allows (no count cap), and for each one either builds the
  `would_catch_if` meter as that doctor's rule, with the row's id leaving `blind_spots`, or marks it
  `unmeasurable` with its why (it stays in `blind_spots`, out of the open count). In contract §3, "the doctor
  owner's work" gains "or the night's Deep search". Fixers still only record.
- Proof, fixed now: per 7 days, meter closes only (an id leaving `blind_spots` in a commit changing that doctor's
  code; `unmeasurable` marks and plain drops shown beside, never counted) against added: 3 / 27 and 0 / 26 before,
  hand-read: 73e74b214 (memory-owners, launchd-runs) and 59f456ca3 (wait-caller-kind) built meters, fc93e639a
  dropped short-lived-origin and load-red-unattributed when Load stopped judging. Outside-found share 41.6 % and
  36.9 %. A built meter raises a real row (`fixed`, `handoff`, `blind-spot`) within 14 days of landing or is
  reverted, net lines shown. Target: meter closes ≥ added each week, open (81) falls, outside-found below 36.9 %.
- Not worse: the false-alarm share (a new meter's ruled-out rows count against it); the doctor's CPU a run
  (System's `doctor-run-flat`).

## How the block runs at night

- It brings back README "The whole night" sections Doctor fixes and Deep search, both block 7. `bin/night-run`:
  the `PILOT` default (line 31) ends at `legacy`, so `vendors` (block 6) joins first, then `doctors`, each once its
  file is checked (README, Ready). Carry prints neither section today (`pilot_goal` gives goal and
  directions-refresh lines; fixers are the sweep's `doctor-fix launch`, refused on a pilot). Once PILOT
  reaches `doctors` with no goal left, `pilot_goal` adds one `fixer<TAB><doctor><TAB>llm-legs<TAB>doctor-fix launch
  <doctor>` line per doctor, then `deep-search<TAB><date><TAB>llm-legs<TAB>share/briefs/deep-search.md` (new kind
  and brief); `PILOT_RULES` and doctor-fix's pilot check except them. Audit rules launch once their owners' goals (blocks 2–4) landed.
- First night: those lines once each. Judged by its false-alarm share of decided non-audit rows against 38.1 % and
  24.6 % (target below 24.6 %) with the guard at or under baseline, rows ruled out again within a window 0, fixer
  spend per decided row from the night header (c746800c), meter closes ≥ blind spots added. If it does not cope,
  the night says why and what would do the same for fewer tokens. A promise that did not hold, or a guard over its
  baseline, is reverted.

## Done

None yet.

## Decisions

- 2026-10-20: a block is judged by a metric that converges. A fix removes the root cause of its class, and the
  proof shows the class stops coming back. Never code for code: the nights stopped because they spent a great
  many tokens and problems grew. («Updater doctor»)
- 2026-10-19: Deep search means caring for the doctors: finding what no doctor covers and adding it to one. It
  joins the Fix rows in block 7. The block list 0–10 was agreed on 10-20 (94466968). («Updater doctor»)
- 2026-10-19: the night is a singularity: it digs deep for what the doctor does not show. «Доктор я сделал как
  помощник, чтобы находить подсказки». A night section is dropped only by an explicit word. («Updater doctor»)
- 2026-10-13: when the night finds what a doctor does not log (workers hitting limits), the doctor learns to log
  it: a self-developing system. An item reviewed and unchanged is not re-checked unless its number moves a lot,
  read as a 7- or 3-day trend, never a one-day spike. Fixing everything is a utopia: by priority, P1 first, the
  rest only when the limits allow. («Updater doctor»)
- 2026-10-12: the Doctors share comes down to about 5 % of 7-day usage once the backlog plateaus; quality trades
  are decided there. («Updater doctor»; memory doctors-share-goal)
- 2026-10-04: what is not measured is not fixed; every wait is a doctor metric («make land for multiple workers
  in one repository»). Never a guard for a one-off, since a doctor catching it is enough («Updater doctor»).
- 2026-09-29: the doctor shows everything as it is, for whole classes of blind spots, and what stays unmeasured
  goes into its blind-spot list. («Harness Doctor»)
- 2026-09-29: a fixer learns a component's purpose before changing it and judges whether the goal is met, not
  whether the row turns green. Fixers run only on Egor's button (the night), never on a timer. («Updater doctor»)
- Reviews: no bugs round on fresh code (2026-10-06); a change under ≈150 lines is never auto-reviewed
  (2026-10-01). No new hooks (2026-10-15, «Updater doctor»).

## Open

- Class 2 (lever measured absent): no goal yet. First check whether Speed's `select` reads a fixer's measured
  "no effect"; if not, the measured result replaces the estimate, replayed `select` old and new over 10-12…14.
- Class 4 (conduct readings): `kind` does not separate conduct (10-14: ruled-out in wait 3, gate, rework,
  instruction, repeat; fixed in gate 2, wait 3, rework). It fell 23 → 7 unchanged; a goal only if it climbs back.
- Class 5 (a fix's tail): reading values only after a row's last fix would quiet it, but 41 rows were fixed again
  within 7 days of a first fix, payoff unmeasured (Breakages: 22 Speed rows), so it cannot yet be told from hiding.
- Chat-found problems have no record, so outside-found misses Egor's and chats' finds; a chat writing a
  `blind_spots` row is conduct, not mechanism.
