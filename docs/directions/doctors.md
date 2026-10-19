# Doctors (direction 7)

The doctors (LLM, Harness with Speed, Updater, Code, System) and the night's use of them. Two parts:
- Doctor fixes: every doctor's Fix rows, `doctor-fix launch` on a full night (`docs/doctor-fix.md`).
- Deep search: the night looks for what no doctor shows and makes a doctor see it. A doctor is a helper that gives
  hints, never the scope (Decisions).

## Metric

False-alarm share: the share of decided doctor rows whose fixer run changed nothing because there was nothing of
ours to change (verdict `ruled-out`, `weather` or `not-applicable`), 7 days against the 7 before. Target: falls and
stays down.
- It is a ratio of the rows the night actually spent a fixer on, so it does not grow with the number of rows or
  nights. Each false alarm is a full fixer reading paid for nothing. `handoff` and `blind-spot` rows are real and
  count as found. A run's local day is its `created_at` in EEST.
- Out of it: `suite_audit`, `cpu_audit` and `spend_audit`. Audit reopens belong to their audit (Lost time,
  Decision 10-16), with goals in Lost time (`suite-own-cost`), System (`cpu-audit-own-number`) and Spend
  (`audit-due`). They get their own line here, and
  when those goals land their drop is a bonus here, never this block's proof.
- Second number, outside-found share (Deep search part, falls too): real problems first recorded outside a doctor's
  rules, over all real problems first recorded in the window. Outside means a log-audit row (`match.rule
  log_audit`) or a `blind_spots` row; inside means any other ledger row. Real means its status today is not
  `not-a-bug`, `ruled-out` or `weather`. The two numbers guard each other: muting rules lowers the first and raises
  the second.

### Baseline (computed 2026-10-20)

No night has run since 10-14, so the second window holds two nights (10-13, 10-14) and the first holds six.

| | 10-06…12 | 10-13…19 |
|---|---:|---:|
| fixer runs / decided rows, all rules | 166 / 345 | 133 / 671 |
| **false-alarm share** (non-audit rows) | **24.6 % (79 of 321)** | **38.1 % (82 of 215)** |
| their share of Claude spend / fixer wall-min | 1.21 % / 1,206 | 1.38 % / 4,330 |
| audit rows, own line: false of decided (share of spend) | 18 of 24 (0.44 %) | 166 of 456 (2.25 %) |
| **outside-found share** | **41.6 % (84 of 202)** | **36.9 % (38 of 103)** |
| outside: log-audit rows / blind spots added | 57 / 27 | 12 / 26 |
| blind spots closed (open on 10-20: 81) | 5 | 0 |

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
- Outside-found share, about 10 s: walk `git log --reverse --format='%H %ct' -- share/<doctor>-ledger.json` for
  harness, doctor, system and code. `git show` each commit's ledger, and the first commit holding a row id or a
  `blind_spots` id dates it (EEST). Classify the row by its `match.rule` and its status in today's file.
  Blind spots closed are ids gone from today's file (10-06 memory-owners and launchd-runs, 10-07 short-lived-origin
  and load-red-unattributed, 10-10 wait-caller-kind).
- Spend: tokenmap `requests` (`mode=ro`), `sum(cost_in+cost_out)` where `vendor='claude'` and `cwd` is the run's
  night worktree (`%/worktrees/night-<night>-<run id>%`), split evenly over the run's problems, over the window's
  Claude total. The weight is rate ÷ Opus rate (`tokenmap/pie.py` `model_weight`), so the share in Opus = 1 units
  is the same. Fixer wall-min is the run's `launched_at` → `closed_at` split the same way. It includes slot and
  limit waits, so it says how long a row held a slot, not how long it was worked.
- Chat-found problems have no record (Open). Egor's messages in harness chats that use fault words came to 123
  and 77 in these windows. That is unconfirmed: nobody checked those against doctor rows. One confirmed
  instance: swap writing ≈400 GiB/day since 10-14, with no doctor seeing who uses the memory («Updater doctor»,
  10-15 02:44). The `memory-owners` blind spot had been closed on 10-06.

## Sources

- Fixer runs `~/.cache/doctors/runs/<id>.json`: `problems` (the snapshot at launch, with `component`),
  `decisions` (`verdict`, `evidence`), times, `night`. Night records `~/.cache/doctors/nights/<id>.json`.
- Ledgers `share/{harness,doctor,system,code,updater}-ledger.json`: rows (`status`, `fixes`, `ruled_at`) and
  `blind_spots` (63, 8, 6, 1, 3 on 10-20). Documents `~/.cache/<doctor>-doctor/latest.json` (contract §1).
  Log audit `~/.cache/doctors/log-audit/`.
- The 10-20 night-cost research (applied in c746800c): Spend reopens 11 of 12 ruled out; suite source-edit re-audits 13 measured drops in 61; CPU's biggest find from a source-edit reopen.

## Recurring classes

Ranked by spend share, non-audit rows, both windows. Labels come from keywords over each row's `fact` and
`evidence` (spot-checked by hand, unconfirmed beyond that). Rows are A / B.

| class | rows | share of Claude spend | fixer wall-min | owner |
|---|---:|---:|---:|---|
| 0. an audit comes due with nothing to change (suite, CPU, spend) | 18 / 166 | 0.44 / 2.25 % | 959 / 12,850 | its audit's block (10-16) |
| 1. a row ruled out is raised and ruled out again, nothing new since the ruling | 31 / 20 | 0.47 / 0.29 % | 592 / 1,166 | here |
| 2. a priced lever measured absent (Speed `opportunity`, `test_hang` lock waits) | 9 / 23 | 0.29 / 0.48 % | 300 / 2,053 | here, Open |
| 3. load or noise read as a rise (`regression`, `opportunity`, `floor`) | 4 / 14 | 0.13 / 0.31 % | 57 / 632 | Lost time (its rows) |
| 4. a log-audit reading of model or chat conduct sent to a fixer | 23 / 7 | 0.18 / 0.10 % | 98 / 138 | here, Open |
| 5. a landed fix's pre-fix tail still in a 7-day window | 9 / 12 | 0.11 / 0.10 % | 122 / 227 | here, Open |
| 6. a cause no doctor shows: blind spots added and never built | 27 / 26 added, 5 / 0 closed | | | here |

Why they come back:
1. Only the Harness doctor remembers a ruling. `problems_from` (`bin/harness-doctor`, the `ruled_at` test) keeps a
   ruled-out ledger row quiet until an event after the ruling, or for one `window_h` when it has no times. LLM,
   System, Speed `watch` rows without a ledger row, and log-audit rows reach the next snapshot whatever a run
   decided. So the fixer reads the packet, finds the earlier decision and rules the row out again. Examples: LLM
   M2 raised the same stuck round 10-06, 10-07 and 10-08. M4 cited one 09-30 handoff on 5 nights. `I48` was
   re-filed. `machine/contention` and `chat/tools` were re-checked 10-12 and 10-14.
2. Speed ranks an opportunity by its estimated saving (a generic share for delegation, blind spot
   `delegation-model-time`), and the next night ranks it the same way after a fixer measured it flat. Unconfirmed
   whether any measured result feeds back.
4. Every log-audit finding becomes a Harness row, and none of the 105 log-audit packets of 10-06…19 names a
   component file. Conduct (re-asked decisions, a chat's brief, a bench lane) has no fixer. The class shrank
   23 → 7 on its own.
5. The contract's after-fix rule (§2: an event regresses a fix only if it ran on code holding it) covers matching,
   not values. A 7-day aggregate re-raises a landed fix until its tail leaves the window (6 `test-health/heavy`
   rows on 10-12 ruled out as "already cut" or "already 3 shards"; 8 System `cohort` legacy tags).
6. Contract §3: a fixer that meets an unseen cause records a blind spot and "never builds the detector in a fix
   run: that is the doctor owner's work". The owners are day chats, and no night job takes blind spots. So 53
   were added in 14 days, 5 were closed, and one closed gap came back (memory owners, above).

## Goals

Doctors' goals run after blocks 1–6 (PILOT order). Their reads need section 7 back (How the block runs at night).

### goal ruling-holds: every doctor's ruling holds until something new, as the Harness doctor's does

Class 1. The fix goes where every doctor's rows pass, so a new doctor gets it too.
- Change, in llm-legs `bin/doctor-fix` `snapshot()`: a problem not `regressed`, whose id an earlier closed run
  decided `ruled-out` or `weather`, moves to the run's `quiet` list for its `window_h` (168 h when absent) after
  that run closed. It still launches when one of its `evidence[].at` is later than that close, or its `value` is
  ≥ `spend.SHARE_RISE` (1.5×) the value at that run, Egor's 10-13 rule. The snapshot starts recording `value`.
  The menu is untouched, and the Harness ledger rule stays (it also feeds the menu).
- Proof, a replay (no pilot night runs fixers). Run `snapshot()` old and new over the run records 10-06…14: each
  run's `problems` stand in for the document, and the decisions of runs closed before its launch stand in for
  history. Before: 28 rows ruled out or weathered again within 7 days of an earlier such verdict (16 / 12) and 11
  fixed after one. Snapshots kept no evidence times, so a row with a later event cannot be seen; that part is
  unclear and the read below settles it. Target: new launches none of the 28 that lack a newer value, and each of
  the 11 launches again by 7 days after its ruling (delayed, not lost). Not worse: `regressed` rows all launch.
- Read after section 7 is back: rows ruled out again within `window_h` of a ruling, target 0 a night. Fixes after
  a ruling still arrive, about 11 per 14 days before. Class 1's spend share goes below 0.29 %.

### goal blind-spot-builder: the night builds what a blind spot says would catch it

Class 6, Egor's 10-13 rule: when the night finds what a doctor does not log, the doctor learns to log it.
- Change: the Deep search job (README, The whole night) takes the open `blind_spots` of every ledger as its queue.
  The order is the outside finds that name a blind spot's area (log-audit `~N min`, fixer evidence) by cost. It
  takes the top ones a night, as far as its time bound allows (no count cap), and for each one either builds the
  `would_catch_if` meter as that doctor's rule, with the row's id leaving `blind_spots`, or closes it with
  `reason` saying why it cannot be measured. In contract §3, "the doctor owner's work" gains "or the night's Deep
  search". Fixers still only record.
- Proof, fixed now: per 7 days, blind spots closed by a meter against added, 5 / 27 and 0 / 26 before; the
  outside-found share, 41.6 % and 36.9 %. Each built meter must raise at least one real row within 14 days of
  landing (verdict `fixed`, `handoff` or `blind-spot`, from the run records) or it is reverted, net lines shown.
  Target: closed ≥ added each week, open (81) falls, outside-found share below 36.9 %.
- Not worse: the false-alarm share (a new meter's ruled-out rows count against it); the doctor's CPU a run
  (System's `doctor-run-flat`).

## How the block runs at night

- It brings back two sections of README "The whole night", both block 7: Doctor fixes (`doctor-fix launch`) and
  Deep search.
- `bin/night-run` changes. `PILOT_RULES` forbids `doctor-fix launch` in a pilot night; it allows it once PILOT's
  current direction is `doctors`, after that direction's goals have landed. `doctors` joins the `PILOT` default
  (line 31) once this file is checked (README, Ready). The audit rules launch only once their owners' goals have
  landed: they are blocks 2–4, so they have by then.
- First night: one `doctor-fix launch` for every doctor, then one Deep search job. It is judged by that night's
  false-alarm share of decided non-audit rows against 38.1 % and 24.6 % (target: below 24.6 %). Rows ruled out
  again within a window: 0. Fixer spend per decided row comes from the night header's spend per goal (c746800c),
  and blind spots must close at least as fast as they are added. If it does not cope, the night says why and what
  would do the same for fewer tokens. Code that moved no number is reverted.

## Done

None yet.

## Decisions

- 2026-10-20: a block is judged by a metric that converges. A fix removes the root cause of its class, and the
  proof shows the class stops coming back. Never code for code: the nights stopped because they spent a great
  many tokens and problems grew. («Updater doctor»)
- 2026-10-19: Deep search means caring for the doctors: finding what no doctor covers and adding it to one. It
  joins the Fix rows in block 7. The block list 0–10 was agreed on 10-20 (94466968). («Updater doctor»)
- 2026-10-19: the night is a singularity: it must dig deep and find non-obvious things the doctor does not show.
  «Доктор я сделал как помощник, чтобы находить подсказки». A night section is dropped only by an explicit word.
  («Updater doctor»)
- 2026-10-13: when the night finds what a doctor does not log (workers hitting limits), the doctor learns to log
  it: a self-developing system. An item reviewed and unchanged is not re-checked unless its number moves a lot,
  read as a 7- or 3-day trend, never a one-day spike. («Updater doctor»)
- 2026-10-13: fixing everything is a utopia. Fix by priority, P1 first; the rest only when the limits allow.
  («Updater doctor»)
- 2026-10-12: the Doctors share comes down to about 5 % of 7-day usage once the backlog plateaus; quality trades
  are decided there. («Updater doctor»; memory doctors-share-goal)
- 2026-10-04: what is not measured is not fixed; every wait is a doctor metric («make land for multiple workers
  in one repository»). Never a guard for a one-off, since a doctor catching it is enough («Updater doctor»).
- 2026-09-29: the doctor shows everything as it is, for whole classes of blind spots, and what stays unmeasured
  goes into its blind-spot list. («Harness Doctor»)
- 2026-09-29: a fixer learns a component's purpose before changing it, and judges whether the goal is met, not
  whether the row turns green. Fixers run only on Egor's button (the night is that button), never on a timer.
  («Updater doctor»)
- Reviews: no bugs round on fresh code (2026-10-06); a change under ≈150 lines is never auto-reviewed
  (2026-10-01). No new hooks (2026-10-15, «Updater doctor»).

## Open

- Class 2 (lever measured absent): no goal yet. First check whether Speed's `select` reads a fixer's measured
  "no effect". If it does not, the fix is the measured result replacing the estimate; the replay would be
  `select` old and new over 10-12…14.
- Class 4 (conduct readings): the finding's `kind` does not separate conduct. On 10-14 the 15 findings' ruled-out
  ones fall in wait 3, gate, rework, instruction and repeat, and the fixed ones in gate 2, wait 3 and rework. The
  class fell 23 → 7 with no change. It is watched, and is a goal only if it climbs back.
- Class 5 (a fix's tail): values read only after a row's last fix landing would quiet it. But the replay shows 41
  rows fixed again within 7 days of a first fix, and whether those second fixes pay off is unmeasured (Breakages:
  22 Speed rows optimised again). So a tail rule cannot yet be told from hiding a fix that did not hold.
- Chat-found problems have no record, so the outside-found share misses Egor's and chats' finds. The record that
  exists is a `blind_spots` row; a chat that finds a gap writing one is conduct, not mechanism.
