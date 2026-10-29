# Doctors (direction 7)

The doctors (LLM, Harness with Speed, Updater, Code, System) and the night's use of them. Two parts:
- Doctor fixes: `doctor-fix launch --night` (`docs/doctor-fix.md`).
- Deep search: the night looks for what no doctor shows and makes a doctor see it.

## Metric

False-alarm share: the share of decided doctor rows whose fixer run changed nothing because there was nothing of
ours to change (verdict `ruled-out`, `weather` or `not-applicable`), 7 days against the 7 before. Target: falls,
stays down.
- A ratio of rows a fixer was spent on, so it does not grow with rows or nights; `handoff` and `blind-spot` rows are
  real. A run's local day is its `created_at` in EEST.
- Out of it: `suite_audit`, `cpu_audit`, `spend_audit`, whose reopens belong to their audit (Lost time, Decision
  10-16; goals `suite-own-cost`, `cpu-audit-own-number`, `audit-due`). Own line; their drop is a bonus.
- Second number, outside-found share (Deep search part, falls too): of the real problems first recorded in the
  window (status today not `not-a-bug`, `ruled-out` or `weather`), those outside a doctor's rules: a log-audit row
  (`match.rule log_audit`) or a `blind_spots` row.
- Guard: holding a Fix row back (ruling-holds, doctor-fix's skips, a muted false rule) lowers the first, not
  the second. Beside them, from each launch's `held` list: rows held a night and held rows later decided `fixed`;
  replayed, 26 held in A's six nights, 24 in 10-13…14's two, 10 / 4 `fixed` at that launch. A fall with a guard
  above baseline is unclear, never better.

### Baseline (computed 2026-10-20)

Runs: six nights, then two (3131, 8004; 6468 launched no fixer).

| | 10-06…12 | 10-13…19 |
|---|---:|---:|
| fixer runs / decided rows, all rules | 166 / 345 | 133 / 671 |
| **false-alarm share** (non-audit rows) | **24.6 % (79 of 321)** | **38.1 % (82 of 215)** |
| their share of Claude spend / fixer wall-min | 1.21 % / 1,206 | 1.38 % / 4,330 |
| audit rows, own line: false of decided (share of spend) | 18 of 24 (0.45 %) | 166 of 456 (2.25 %) |
| **outside-found share** | **41.6 % (84 of 202)** | **36.9 % (38 of 103)** |
| outside: log-audit rows / blind spots added | 57 / 27 | 12 / 26 |
| blind spots closed (open on 10-20: 81) | 5 | 0 |

- After the baseline: 10-20's day wave (46 fixer runs a chat launched unasked): false-alarm
  share **48.1 % (13 of 27)**, audit rows 21 of 29.

- Recompute the false-alarm share:
  ```
  python3 -c 'import json,glob,os,datetime as T;n={}
  for f in glob.glob(os.path.expanduser("~/.cache/doctors/runs/*.json")):
    d=json.load(open(f));v={x["id"]:x["verdict"] for x in d.get("decisions") or []}
    w=str(T.datetime.fromisoformat(d["created_at"][:19])+T.timedelta(hours=3))[:10];w="A"if"2026-10-06"<=w<="2026-10-12"else"B"if"2026-10-13"<=w<="2026-10-19"else 0
    for p in d.get("problems") or []:
      if w and p["id"]in v and p.get("rule")not in("suite_audit","cpu_audit","spend_audit"):c=n.setdefault(w,[0,0]);c[0]+=1;c[1]+=v[p["id"]]in("ruled-out","weather","not-applicable")
  print(n)'
  ```
- Outside-found share: `git log --reverse --format='%H %ct' -- share/<doctor>-ledger.json` for harness, doctor,
  system and code; the first commit holding a row or `blind_spots` id dates it (EEST). A row counts while its status
  today is real; a blind spot counts on that day even if dropped since; closed = its last removal in the window.
- Spend: `~/.local/share/tokenmap/tokenmap.sqlite3` `requests` (`mode=ro`), dollar `sum(cost_in+cost_out)`,
  `vendor='claude'`, `cwd` like `%/worktrees/night-<night>-<run file stem>%`, split evenly over the run's problems
  (no `night`, nothing); window totals by UTC `ts` from `2026-10-05T21:00:00` (A) and `2026-10-12T21:00:00` (B), 7
  days each. Fixer wall-min: `launched_at` → `closed_at` split the same way (0 unclosed), waits included.

## Sources

- Fixer runs `~/.cache/doctors/runs/<id>.json`: `problems` (launch snapshot, with `component`), `decisions`
  (`verdict`, `evidence`), times, `night`; nights `~/.cache/doctors/nights/<id>.json`.
- Ledgers `share/{harness,doctor,system,code,updater}-ledger.json`: rows (`status`, `fixes`, `ruled_at`),
  `blind_spots`. Documents `~/.cache/<doctor>-doctor/latest.json` (contract §1); log audit `~/.cache/doctors/log-audit/`.

## Recurring classes

Both windows, A / B, spend and wall split as in Baseline. Class 0: the false-alarm command's false audit rows. Class
1 by command: the ruling-holds replay's count (non-audit, `ruled-out` or `weather` after such a verdict closed ≤ 168 h
before the launch). Classes 2–5 (*): a hand keyword partition of the 79 and 82 false non-audit rows.

| class | rows | share of Claude spend | fixer wall-min | owner |
|---|---:|---:|---:|---|
| 0. an audit comes due with nothing to change (suite, CPU, spend) | 18 / 166 | 0.45 / 2.25 % | 959 / 12,850 | its audit's block (10-16) |
| 1. a ruled-out row raised and ruled out again, nothing new | 16 / 12 | 0.34 / 0.11 % | 309 / 690 | here |
| 2.* a priced lever measured absent (Speed `opportunity`, `test_hang` lock waits) | 9 / 23 | 0.29 / 0.48 % | 300 / 2,053 | here, Open |
| 3.* load or noise read as a rise (`regression`, `opportunity`, `floor`) | 4 / 14 | 0.13 / 0.31 % | 57 / 632 | rise-beyond-noise |
| 4.* a log-audit reading of model or chat conduct sent to a fixer | 23 / 7 | 0.18 / 0.10 % | 98 / 138 | open (conduct-gate stopped) |
| 5.* a landed fix's pre-fix tail still in a 7-day window | 9 / 12 | 0.11 / 0.10 % | 122 / 227 | closed (cf193646, ebf5bde1) |
| 6. a cause no doctor shows: blind spots added and never built | 27 / 26 added, 5 / 0 closed | | | here |
| 7. a landed fix that was not needed goes unseen (retro sample, 10-28) | 11 of 40 | | | fix-audit, worth-bar |

Why they come back:
1. Only the Harness doctor remembered a ruling; other rows came back and were ruled out again (LLM M2, M4, `I48`,
   `machine/contention`, 10-06…14).
2. Speed ranks an opportunity by its estimated saving (blind spot `delegation-model-time`); a ruling holds it (Open).
4. Every log-audit finding becomes a Harness row; none of the 105 packets of 10-06…19 names a component file, and
   conduct (re-asked decisions, a chat's brief) has no fixer.
5. The contract's after-fix rule (§2: an event regresses a fix only if it ran on code holding it) covers matching,
   not values: a 7-day aggregate re-raises a landed fix until its tail leaves the window (6 `test-health/heavy`
   rows ruled "already cut" or "3 shards" on 10-12; 9 false System `cohort` rows on 10-14, by the false-alarm command).
6. A fixer records a blind spot, never builds it (`docs/doctor-fix.md` §3); owners were day chats, no night job took
   them. 53 added in 14 days, 5 closed, one came back.

## Goals

Reads need section 7 back (How the block runs at night).
Deep search 10-23, window 10-09…23 (no fixer run after 10-20): non-audit false-alarm share 33.5 % (150 of 448),
103 of the 150 from `opportunity` and `log_audit`.

### goal rise-beyond-noise: a fix reads slower only past the noise band

Class 3, rule `regression`, decided A / B: 2 / 19; ruled out 0 / 7 (B 0.12 % of spend, 152 wall-min), fixed only in
the measurer 1 / 8 (0.04 / 0.12 %, 38 / 265), in code 1 / 4, only 05eb by its fix (`test_wait_journal` 4.5 → 19 s).
10-25: 27 rows `new` (26 `measured slower`, `machine.probe_ms`).
- Cause, `time_budget.unit_proof`: the median of the first n runs after the night over 1.3 × the n before × load,
  n ≥ 2, where a median's p95 noise rise is 3.2 (suite_audit); load under 1 (23 of 26) on controls the night's
  audits sped up; since tests-once the after runs span days (25 of 26); a batch job's ids share its files (8 name
  suites it never changed). cef6's Close raised none: HEAD raises the 26 before it.
- Change: slower only when the fastest of the first PROOF_RUNS runs after is ≥ WALL_RISE × the median of the
  RECENT_RUNS before, after `suite_audit.slowdown` (load on suites the night never names, ≥ 1, else wall beyond CPU);
  `machine.probe_ms`, load itself, leaves `judge_regressions`.
- First step: 10-02…09, unchanged suites' fastest-of-5 / median-of-20 under 2 in 95 % of windows; 04e0
  (`test_worker_run_grok_outcomes` 51 → 100 s) flat at fix^ vs fix on one machine; else stop.
- Proof, fixed in advance: HEAD's `slower_fixes` vs the new rule, nights e2f7…cef6, at 10-13 12Z, 10-14 08Z / 20Z,
  10-20 21Z, 10-25 09Z: 2 / 16 / 23 / 33 / 38 → 0 / 1 / 1 / 1 / 1 fixes; the 27 of 10-25 go; 05eb (real) stays.
- Must not get worse: proven gains and Speed yield equal HEAD's; hooks and stop as HEAD; a suite whose fastest run
  doubled is raised.

### goal fix-audit: every landed fix is read again, blind, a week later

Class 7. Retro audit 10-28: 40 judge-confirmed fixes of fit, legacy and speed rounds 09-30…10-14. Two blind Opus
readers judged them, and the key and packets are in `~/.cache/fix-audit/retro-2026-10-28*`. Results, as needed /
useless / false / harmful:
- found by Haiku: 13 / 6 / 0 / 1;
- found by Opus: 16 / 1 / 3 / 0 (speed 1 / 1 / 3 / 0 of 5; fit 15 of 15);
- not-fixed: 0;
- Sonnet fixers: 9 of 12 needed.

Git caught 1 of the 11 (the reverted `DIM_GREEN`), and kept-or-changed lines split no verdict. Run records before
10-19 are pruned, so 363 of 784 fixed findings map to no hunk.
- Change: a fixer commit names its round and finding positions. `share/fix-ledger.json` records the commit, lens,
  cell model, fixer model and the audit's verdict. A weekly `fix-audit` job reads 20 fixes ≥ 7 days old per lens
  × finder model, blind. The reader is outside the judge's family when the toggles allow, else Opus.
  - False and harmful fixes become Harness rows whose fixer reverts them.
  - A useless fix is reverted only if it added code.
  - Per kind: cost per needed fix (Opus = 1) and the share not needed.
- First step: the retro audit (done).
- Proof, fixed in advance:
  - the 40 retro items through `fix-audit` give the same verdict for ≥ 36;
  - a fixture night's fixer commits all map to their findings;
  - a fixture `false` verdict raises a row.
- Must not get worse: night spend + ≤ 1 % for the audit; fixer wall unchanged.

### goal worth-bar: the judge confirms a finding only for a gain that matters

Class 7. Of the retro 40, the judge confirmed 10 that were not needed:
- 5 speed savings under a second a day, or on a path that never blocks;
- 2 comment and line-number touch-ups;
- 3 claimed costs the pre-fix code did not have, all from Opus speed cells.
- Change: the judge, and doctor-fix for its own rows, rejects a finding that does not meet the bar:
  - speed: ≥ 1 s a day, or on a path that blocks a chat or the night, with its frequency;
  - fit and legacy: the code shrinks or one owner replaces copies.
  The judge also re-reads the pre-fix code for the claimed cost.
- First step: the 10 claims state no frequency or name no blocking path, or the code lacks the cost; else stop.
- Proof, fixed in advance: the judge, replayed blind over the 40 claims, rejects ≥ 7 of the 10 and keeps ≥ 28 of
  the 29 needed.
- Must not get worse: confirmed P1 and P2 kept; judge wall.

## How the block runs at night

- It brings back README "The whole night" sections Doctor fixes and Deep search, both block 7. `bin/night-run`:
  `PILOT` (default `doctors legacy vendors`) starts here. Once no goal is left here, `pilot_goal` prints one
  `fixer<TAB><doctor>` line per doctor, then `deep-search<TAB><date>`, before the next direction's goals, held
  while those jobs work. Carry runs `doctor-fix launch <doctor>` once per doctor (`.block7`, which alone opens a
  pilot night to doctor-fix; a failed launch is recorded, never retried); `PILOT_RULES` adds System and Code doctor
  prep. Audit rules wait (`--no-audits`) while [Lost time](lost-time.md), [System](system.md) or [Spend](spend.md)
  holds a goal.
- First night: those lines once each. Judged by its false-alarm share of decided non-audit rows against 38.1 % and
  24.6 % (target below 24.6 %) with the guard at or under baseline, rows ruled out again within a window 0, fixer
  spend per decided row from the night header (c746800c), meter closes ≥ blind spots added. If it does not cope,
  the night says why and what would do the same for fewer tokens. A promise that did not hold, or a guard over its
  baseline, is reverted.

## Done

- ruling-holds (79ed36db, d39e0be5): `snapshot()` holds a row an earlier run ruled out or called weather until
  something new. Replay 10-06…14: 28 re-ruled rows → held 28; of 11 later `fixed`, 2 regressed launch, 9 held ≤ 168 h
  after the ruling; regressed held 0 of 34. Read once section 7 is back: re-ruled 0 a night, guard ≤ baseline,
  class 1 < 0.11 %.
- blind-spot-builder (de43909e): Deep search's queue `doctor-fix blind-spots`, brief `share/briefs/deep-search.md`.
  Ledger git: meter closes / added 3 / 27, 0 / 26; outside-found 36.5 % by 10-23 statuses; open 81 → 83 by 10-23.
  Read weekly once Deep search runs: closes ≥ added, open falls, outside-found < 36.9 %; a meter with no real row in
  14 days reverts; not worse: false-alarm share, CPU a run.
- heavy-tail, stopped at its First step 10-29 (no change): the class was already closed by cf193646 (a suite's
  test-health row counts only runs after its own ledger fix's day) and ebf5bde1 (heavy/pole/fan-out left
  test_health). Replay of the 24 rows on HEAD: 12 raised, so ≤ 5 cannot be reached by any cut; 6 have no fix ever
  recorded, 6 fire only on post-fix runs (124 runs, every head holds its fix). What is left is load or measurement
  read as idle, class 3, not a pre-fix tail.
- conduct-gate, stopped at its First step 10-29 (no change): 59 % and 34 % are one set read two ways (run verdicts
  of 10-09…14: 44 of 75 false; ledger status today: 36 of 105, 13 of the 44 still `open`). No packet names a
  component file (`audit_verdicts` drops the finding's `fix`), so the gate would take all 31 real rows off a fixer;
  by the merge input's `fix`, 19 of the 44 false name no file (not mostly) and 3 real ones none either; `kind` does
  not split them either.

## Decisions

- 2026-10-28: a job kind moves to a cheaper model (Sonnet, Haiku) only through `fix-audit`. The move is one routing
  line, run as an experiment with rounds interleaved. It holds when the needed share stays within the sample's noise
  of the incumbent and the cost per needed fix falls. Haiku stays in fit, legacy and speed cells
  (`haiku-review-cells` retired). («Updater doctor»)

- 2026-10-20: a fixer or night launches only on his own act (click, terminal, launchd, his word), never another
  chat's: the five Fix buttons went, `doctor-fix launch` runs only in a night (4f742b19). Menu red means act now
  (3ea8810a), the night still reads every problem, the bars keep their history (93e9cd4b). («Компьютер тормозит и
  зависает», «Updater doctor»)
- 2026-10-20: a fix removes its class's root cause and its proof shows the class stops coming back; the nights
  stopped because they spent a great many tokens while problems grew. («Updater doctor»)
- 2026-10-19: Deep search means caring for the doctors: finding what no doctor covers and adding it to one.
  «Доктор я сделал как помощник, чтобы находить подсказки». («Updater doctor»)
- 2026-10-13: when the night finds what a doctor does not log (workers hitting limits), the doctor learns to log
  it: a self-developing system. An item reviewed and unchanged is not re-checked unless its number moves a lot,
  read as a 7- or 3-day trend, never a one-day spike. Fixing everything is a utopia: by priority, P1 first, the
  rest only when the limits allow. («Updater doctor»)
- 2026-10-04: what is not measured is not fixed; every wait is a doctor metric («make land for multiple workers
  in one repository»). Never a guard for a one-off, since a doctor catching it is enough («Updater doctor»).
- 2026-09-29: the doctor shows everything as it is, for whole classes of blind spots, and what stays unmeasured
  goes into its blind-spot list. («Harness Doctor»)

## Open

- Class 2 (lever measured absent): `select` reads no verdict; `snapshot()` holds a ruled-out lever 168 h or to a 1.5×
  rise (`held_since`); 10-12…14 all 13 launched levers ruled earlier held, so a `select` drop adds 0. Goal only if
  re-rulings past the hold climb.
- Chat-found problems have no record, so outside-found misses Egor's and chats' finds; a chat writing a
  `blind_spots` row is conduct, not mechanism.
