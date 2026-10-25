# Doctors (direction 7)

The doctors (LLM, Harness with Speed, Updater, Code, System) and the night's use of them. Two parts:
- Doctor fixes: `doctor-fix launch --night` on a full night (`docs/doctor-fix.md`).
- Deep search: the night looks for what no doctor shows and makes a doctor see it.

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
  not launched) and held rows later decided `fixed`. Holds: each launch's `held` list. Baseline, its replay: 26 held in 10-06…12's six nights, 24 in 10-13…14's two, 10 / 4
  of them decided `fixed` at that launch. A fall with a guard number above baseline is unclear, never better.

### Baseline (computed 2026-10-20)

No night has run since 10-14; the run records sit in six nights, then two (3131, 8004; 6468 launched no fixer).

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

- Recompute the false-alarm share:
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
  today's file has dropped it. Closed means the id's last removal from `blind_spots` falls in the window.
- Spend: `~/.local/share/tokenmap/tokenmap.sqlite3` `requests` (`mode=ro`), `sum(cost_in+cost_out)`, `vendor='claude'`,
  `cwd` like `%/worktrees/night-<night>-<run file stem>%`, split evenly over every problem in the run record; a run
  with no `night` adds nothing. Window totals by UTC `ts`: A `2026-10-05T21:00:00`…`2026-10-12T21:00:00`, B
  `2026-10-12T21:00:00`…`2026-10-19T21:00:00`. Dollar cost, not `model_weight`. Fixer wall-min: `launched_at` → `closed_at` split the same way,
  0 with no `closed_at`, slot and limit waits included.
- Chat-found problems have no record (Open).

## Sources

- Fixer runs `~/.cache/doctors/runs/<id>.json`: `problems` (the snapshot at launch, with `component`),
  `decisions` (`verdict`, `evidence`), times, `night`. Night records `~/.cache/doctors/nights/<id>.json`.
- Ledgers `share/{harness,doctor,system,code,updater}-ledger.json`: rows (`status`, `fixes`, `ruled_at`) and
  `blind_spots`. Documents `~/.cache/<doctor>-doctor/latest.json` (contract §1).
  Log audit `~/.cache/doctors/log-audit/`.

## Recurring classes

Numbered as the goals cite them, both windows; rows are A / B, spend and wall split as in Baseline. Class 0 is
the false audit rows from the false-alarm command (`rule` in `suite_audit`, `cpu_audit`, `spend_audit`). Class 1
is by command: the ruling-holds replay's count (non-audit, verdict `ruled-out` or `weather`, an earlier run's such
verdict closed within 168 h before this launch). Classes 2–5 (*) are a hand keyword
partition of the 79 and 82 false non-audit rows, no command reproduces.

| class | rows | share of Claude spend | fixer wall-min | owner |
|---|---:|---:|---:|---|
| 0. an audit comes due with nothing to change (suite, CPU, spend) | 18 / 166 | 0.45 / 2.25 % | 959 / 12,850 | its audit's block (10-16) |
| 1. a row ruled out is raised and ruled out again, nothing new since the ruling | 16 / 12 | 0.34 / 0.11 % | 309 / 690 | here |
| 2.* a priced lever measured absent (Speed `opportunity`, `test_hang` lock waits) | 9 / 23 | 0.29 / 0.48 % | 300 / 2,053 | here, Open |
| 3.* load or noise read as a rise (`regression`, `opportunity`, `floor`) | 4 / 14 | 0.13 / 0.31 % | 57 / 632 | Lost time (its rows) |
| 4.* a log-audit reading of model or chat conduct sent to a fixer | 23 / 7 | 0.18 / 0.10 % | 98 / 138 | conduct-gate |
| 5.* a landed fix's pre-fix tail still in a 7-day window | 9 / 12 | 0.11 / 0.10 % | 122 / 227 | heavy-tail |
| 6. a cause no doctor shows: blind spots added and never built | 27 / 26 added, 5 / 0 closed | | | here |

Why they come back:
1. Only the Harness doctor remembers a ruling (`problems_from`, below). LLM, System, Speed `watch` rows without a
   ledger row, and log-audit rows reach the next snapshot whatever a run decided, so the fixer finds the earlier
   decision and rules the row out again (LLM M2, M4, `I48`, `machine/contention`, 10-06…14).
2. Speed ranks an opportunity by its estimated saving (blind spot `delegation-model-time`); a ruling holds it (Open).
4. Every log-audit finding becomes a Harness row; none of the 105 packets of 10-06…19 names a component file, and
   conduct (re-asked decisions, a chat's brief, a bench lane) has no fixer.5. The contract's after-fix rule (§2: an event regresses a fix only if it ran on code holding it) covers matching,
   not values. A 7-day aggregate re-raises a landed fix until its tail leaves the window (6 `test-health/heavy`
   rows on 10-12 ruled out as "already cut" or "already 3 shards"; 9 false System `cohort` rows on 10-14, the
   false-alarm command with `cohort` in the id).
6. A fixer records a blind spot, never builds it (`docs/doctor-fix.md` §3); owners were day chats, no night job took
   them. 53 added in 14 days, 5 closed, one came back.

## Goals

Doctors' goals run after blocks 1–6 (PILOT order). Their reads need section 7 back (How the block runs at night).
Deep search 10-23, window 10-09…23 (no fixer run after 10-20): non-audit false-alarm share 33.5 % (150 of 448),
103 of the 150 from `opportunity` and `log_audit`.

### goal heavy-tail: a test-health row reads only runs on code past its last fix

Class 5. `opportunity`: 59 of 174 rows false (0.49 % of Claude spend); 24 are first-raised `test-health` rows ruled
"already sharded / cut"; its 16 repeats ruling-holds covers.
- Change: the `test-health` opportunity reads only runs on code past the row's last fix.
- First step: the 24 rows' last fixes landed before their raising runs' window ended, else stop.
- Proof, fixed in advance: a replay of the 24 rows raises at most 5, and every `test-health` row later decided
  `fixed` is still raised; ≈ −24 rows, ≈ 5 points.
- Must not get worse: held rows later `fixed` (the guard); a suite that really slowed after its fix is raised.

### goal conduct-gate: a log-audit finding naming no component file goes to blind_spots, not a fixer

Class 4. `log_audit`: 44 of 75 rows false (59 %, 0.29 % of spend, no repeats), 20 conduct readings by keyword
(split unconfirmed); the ledger gives 36 of 105 false all-time (34 %), not reconciled with the 59 %.
- Change: a log-audit finding naming no component file goes to `blind_spots`, not to a fixer.
- First step: reconcile 59 % with 34 % on the 75 rows; the false ones mostly name no component file, else stop.
- Proof, fixed in advance: a replay of the 75 rows keeps all 31 real ones on a fixer; up to −44 rows.
- Must not get worse: outside-found share (a `blind_spots` row stays outside); real log-audit rows reach a fixer.

## How the block runs at night

- It brings back README "The whole night" sections Doctor fixes and Deep search, both block 7. `bin/night-run`:
  the `PILOT` default already holds `vendors` and `doctors`. Carry prints neither section today (`pilot_goal` gives goal and
  directions-refresh lines; fixers are the sweep's `doctor-fix launch`, refused on a pilot). Once PILOT
  reaches `doctors` with no goal left, `pilot_goal` adds one `fixer<TAB><doctor><TAB>llm-legs<TAB>doctor-fix launch
  <doctor>` line per doctor, then `deep-search<TAB><date><TAB>llm-legs<TAB>share/briefs/deep-search.md` (new kind;
  brief landed); `PILOT_RULES` and doctor-fix's pilot check except them. Audit rules launch once their owners' goals (blocks 2–4) landed.
- First night: those lines once each. Judged by its false-alarm share of decided non-audit rows against 38.1 % and
  24.6 % (target below 24.6 %) with the guard at or under baseline, rows ruled out again within a window 0, fixer
  spend per decided row from the night header (c746800c), meter closes ≥ blind spots added. If it does not cope,
  the night says why and what would do the same for fewer tokens. A promise that did not hold, or a guard over its
  baseline, is reverted.

## Done

- ruling-holds (79ed36db, d39e0be5): `snapshot()` holds a row an earlier run ruled out or called weather until
  something new. Replay 10-06…14: the 28 re-ruled rows launched → held 28; of the 11 later `fixed`, 2 regressed
  launch, 9 held ≤ 168 h after the ruling; regressed held 0 of 34. Read once section 7 is back: re-ruled 0 a night,
  guard ≤ baseline, class 1 < 0.11 %.
- blind-spot-builder (de43909e): Deep search's queue `doctor-fix blind-spots`, brief `share/briefs/deep-search.md`.
  Baseline from ledger git: meter closes / added 3 / 27, 0 / 26; outside-found 41.6 / 36.9 % (36.5 % by 10-23 statuses); open 81 → 83 by 10-23. Read
  weekly once Deep search runs: closes ≥ added, open falls, outside-found < 36.9 %; a meter with no real row in 14
  days reverts; not worse: false-alarm share, CPU a run.

## Decisions

- 2026-10-20: a fixer or night launches only on his own act (click, terminal, launchd, his word), never another
  chat's: the five Fix buttons went, `doctor-fix launch` runs only in a full night (4f742b19). Menu red means act now
  (3ea8810a), the night still reads every problem, the bars keep their history (93e9cd4b). («Компьютер тормозит и
  зависает», «Updater doctor»)
- 2026-10-20: a fix removes its class's root cause and its proof shows the class stops coming back; the nights
  stopped because they spent a great many tokens while problems grew. («Updater doctor»)
- 2026-10-19: Deep search means caring for the doctors: finding what no doctor covers and adding it to one. It
  joins the Fix rows in block 7. «Доктор я сделал как помощник, чтобы находить подсказки». («Updater doctor»)
- 2026-10-13: when the night finds what a doctor does not log (workers hitting limits), the doctor learns to log
  it: a self-developing system. An item reviewed and unchanged is not re-checked unless its number moves a lot,
  read as a 7- or 3-day trend, never a one-day spike. Fixing everything is a utopia: by priority, P1 first, the
  rest only when the limits allow. («Updater doctor»)
- 2026-10-04: what is not measured is not fixed; every wait is a doctor metric («make land for multiple workers
  in one repository»). Never a guard for a one-off, since a doctor catching it is enough («Updater doctor»).
- 2026-09-29: the doctor shows everything as it is, for whole classes of blind spots, and what stays unmeasured
  goes into its blind-spot list. («Harness Doctor»)
- 2026-09-29: a fixer learns a component's purpose before changing it and judges whether the goal is met, not
  whether the row turns green. Fixers run only on Egor's button (the night), never on a timer. («Updater doctor»)

## Open

- Class 2 (lever measured absent): `select` reads no verdict; doctor-fix `snapshot()` holds a ruled-out lever 168 h
  or to a 1.5× rise (`held_since`). 10-12…14: all 13 launched levers ruled earlier held, so a `select` drop adds 0;
  no fix found one flat. Goal only if re-rulings past the hold climb.
- Chat-found problems have no record, so outside-found misses Egor's and chats' finds; a chat writing a
  `blind_spots` row is conduct, not mechanism.
