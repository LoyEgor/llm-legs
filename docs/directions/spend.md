# Spend (direction 4)

Tokens the harness itself costs: instructions, briefs, relays, hook text, review and doctor runs, worker startup,
and scripts models rewrite where one tool would do.

## Metric

- Fee index (tokenmap definition `pie-fee-task-3`): the harness's fee per task in a window, priced against the 7
  days before it. Below 1 means cheaper per task. The night cleanup is Upkeep and stays out of it.
- Doctors' share of Claude usage over 7 days, in limit tokens with Opus = 1. Goal ≈5 %.

### Baseline (computed 2026-10-16)

Windows are full local days. The journals reach back past 10-02, so the prior window is complete.

| | 10-02…08 | 10-09…15 |
|---|---:|---:|
| **Fee index** (each window against its own 7 days before) | **0.49 (−51 %)** | **0.74 (−26 %)** |
| Fee, share of Claude spend | 13.3 % | 11.5 % |
| **Doctors' share of Claude usage** | **25.7 %** | **25.0 %** |
| Claude spend, plain limit tokens | 1,004M | 1,341M |
| tasks: Workers / Reviewers / Other | 677 / 372 / 160 | 662 / 903 / 194 |
| Spend-audit runs (plain limit tokens) | 4 (0.9M), from 10-08 | 57 (16.6M) |

- The two index values are consecutive weekly drops in fee per task, not levels. Spend grew +34 %, which is load:
  Reviewers' tasks ×2.4.
- The Doctors' share is volume, mostly 547 night fixers. Breakages' pilot (no row fixers) moves it, so no goal here
  claims it.
- Not computed: Chat tasks before 10-09 (tokenmap shows "—"), and the audit runs in Opus = 1 units.

Method, ≈90 s a window:
- Fee index: `tokenmap tracking --since "2026-10-09 00:00" --until "2026-10-16 00:00" --json`. Read `harness_index`
  (`value`, `change`, `coverage`, the "Use (tasks)" section) and the `Claude spend` row.
- Doctors' share: `tokenmap.tracking.compute_spend(db.connect(db.DEFAULT_DB), tracking.windows_for(since=…,
  until=…))`, tree node `Doctors` `value / total[0]`, then `prev / prev_total[0]`. `tokenmap spend` takes no
  `--since`.
- Audit runs: take the run dirs whose `~/.cache/claude-worker-runs/*/brief` matches
  `harness-speed-spend|spend:(fee|hook|startup|spawn|turns|rewrites|resumes|loaded|menus)` and whose
  `meta.json` `started_at` falls in the window (local days). Their session is the `session` file, else
  `worker-session`; deduplicate (resumed runs share one). Sum `limits.request_sql('r')` over `requests.root_session`
  = each session, in `tokenmap.sqlite3` opened `mode=ro`; a run is the session with requests. 10-09…15: 73 dirs,
  61 sessions, 57 with requests, 16.64M (0.292M a run).

## Sources

- tokenmap `~/.local/share/tokenmap/tracking.json`, `harness_index`: value, coverage, `cells` (price per task by
  consumer × leaf), `sources`, and `loaded` (harness jobs that loaded Egor's configuration). Its hourly write
  covers a rolling 7 days, so a baseline uses the command above.
- The Spend pie (`compute_spend`). `spend-7d.json` is the menu's copy and the night's `Doctors 7d`
  (`share/night_spend.py doctors_share()`). It was last written 10-14 02:20.
- `share/spend-ledger.json`: 64 Spend rows on 10-16 (17 cut, 47 kept), keyed `fee:`, `hook:`, `startup:`, `spawn:`,
  `turns:`, `rewrites:`, `resumes`. Its 339 `suite:` and `cpu:` rows, and their audits' reopens, belong to Lost
  time and System.
- Harness doctor `~/.cache/harness-doctor/latest.json` → `speed.spend`: the Fee index by day, the audits due (14 on
  10-16) and their proofs.
- `share/harness-ledger.json`, log-audit rows (classes 5–7). First-seen dates come from `git log -S` on the ledger.
- `tokenmap.sqlite3`, tables `requests`, `parts` and `doctor_windows`: what each call starts with, night against day.

## Recurring classes

Ranked 2026-10-16 by size, from the 64 Spend rows, the log-audit rows and tokenmap. Class 1's rows are hand labels
from each row's `.note` (rows not keyed `suite:`/`cpu:`); its three causes overlap (20 + 7 + 8 labels on 31 rows).
An independent pass on 10-16 labelled 34 (21 / 7 / 9).

| class | rows | size, 10-09…15 | days | instances fixed |
|---|---:|---:|---:|---:|
| 1. a Spend audit reopens a settled component: a cut whose pre-cut cells still sit in the 7-day window (20), a rise that was load (7), a part kept before under another key (8) | 31 of 64 | ≈half of 16.6M | 4 audit days, 10-10…14 | 31, each closed alone |
| 2. a worker request re-writes its context on a cache miss with no idle, org or shrink cause | 823 events | 11.0M waste | daily | 0, undiagnosed |
| 3. a harness launch carries the interactive configuration it never uses, cut one surface at a time | 12 + 2 due | 6.2M | 10-05…15 | 9 |
| 4. a session re-writes its whole context cold: idle past the cache, or another org's account | 5 | 0.04M since 10-14 | 10-10…14 | 1, held |
| 5. a run re-derives what a ledger holds: known reds, fixed rows re-proved, ledger ground re-profiled, a whole read redone | 5 | | 4 nights | 3 |
| 6. a run sized past what settles it, then run again: a 289-panel judge grid for ≈22 votes, a cap that measured itself, a biased answer key, Haiku cells on Sonnet, 241 images to one worker | 5 | | 2+ nights | 1 |
| 7. rework from an unsettled spec (Spend menu, Fee index rebuilt 3×, batch sizing, lens tuning): model behavior, no fixer | 6 | | 3 nights | 0 |

Why they come back:
1. `share/spend.py` `due()` reopens a component four ways: never audited, source changed (`moved()`), still
   loading after a cut, share ×1.5 (`SHARE_RISE`). The share moves with load. Row keys follow tokenmap's labels
   (`hook:`, `startup:` and `spawn:` became `fee:` on 10-14), so a renamed key reads as never audited. A cut's tail
   stays in the window for 7 days. The audits cost 1.2 % of Claude spend in 10-09…15, ≈0.29M a run. The same
   reopens on `suite:` rows are Lost time's, on `cpu:` rows System's.
2. tokenmap `requests.waste_cause='cache miss'`, `sessions.zone='worker'`, `waste_eff`, local days: 823 events
   (23.3M limit tokens re-written) in 10-09…15, 3,420 (23.2M waste) in 10-02…08. The review-bench zone's 3,368
   (12.0M waste) are review spend, Debt's, paused. Cause not diagnosed.
3. Every launcher sets its own flags: worker-run, review-bench `launch.py`, `ask_claude.sh`, `web-search.sh`. The 9
   fixes (10-05…14, in Done) each cut one surface. The class is back at 173 one-request worker sessions in 10-09…15 (118 Haiku, 46 Sonnet, 9 Opus; ≈161 are the
   log audit's chunk reads and merge). Each started with ≈36k of configuration before its prompt, against 8.0k for
   `ask_claude.sh`'s stripped launch.
4. Fixed for claudeb by the 10-14 resume refusal (9864be9d). Cold worker re-writes fell from 32 events (8.5M) on
   10-13 to 2 (0.04M) in 10-14…16. Account-switch re-writes: 10 events (3.5M), none since 10-13. Method:
   `requests` joined to `sessions.zone='worker'`, `waste_cause` in (`expired (1h+ idle)`, `idle 5-60min`) or
   `account switch`, local days, summed by `limits.request_sql('r')`. No goal.
5.–7. come from the night's fan-out and from model behavior. Breakages' pilot removes the fan-out. Class 6 lives in
   repositories outside the sweep.

## Goals

The pilot works these after Breakages' goals, one at a time. A goal that lands moves to Done with its commit and
proof. One that fails stays here with one line on what blocked it. Bash-cap runs belong to Breakages' `bash-cap`.

### goal audit-due: a Spend audit comes due only on its own price per task

Class 1. 31 of 64 Spend rows closed with nothing new to change, ≈half the audits' 1.2 % of Claude spend.
- Change, in llm-legs `share/spend.py` `due()`, for every key but `suite:` and `cpu:`:
  - the share ×1.5 rule (`SHARE_RISE`) becomes a ×1.5 rise of the price per task, the ratio `proof()` already
    reads from `harness_index.cells`; the share basis goes;
  - a moved source alone no longer makes a component due ("source changed"): the price rule decides;
  - a renamed key keeps its audit: a ledger row names the keys it was audited under, and the component reads that
    row instead of "never audited";
  - a component whose 7-day `charged` (or `loaded[].tokens`) is below one audit run's 0.292M plain limit tokens
    is never due, "never audited" included.
- Proof, old → new on the 10-16 05:32 `tracking.json` and the same ledger: 14 audits due. The floor drops 9
  (Gates, Commit check, Memory files, Handoffs, Agents list, Started by cwd.sh, Started by worker-run,
  loaded:Started by cwd.sh, loaded:Browser check at 0.291M), leaving at most 5, the menus check (share 0) among
  them. On the ledger, class 1's rows kept under another key (8; e.g. `fee:Skills list` re-audits
  `startup:skill listing`, `fee:Tool schemas` `startup:deferred tool list`) would have read their old row.
- Once the full night is back: audit runs a week and their tokens, 57 runs (16.6M) in 10-09…15, by the method
  above. Rows closed as an earlier cut, as load or as kept under another key fall to 0.
- Must not get worse: the Fee index. The components under the floor stay at or under 0.14 % of spend together
  (1.20M of the 845.5M Opus-priced `harness_index.claude` in the 05:32 file).

### goal scripted-bare: every one-request launch takes one shared bare configuration

Class 3. Each launcher sets its own flags, so each cut lands on one surface and the next caller misses it.
- Change, in llm-legs: the stripped launch `ask_claude.sh` uses (an empty cwd, `--safe-mode`,
  `--setting-sources project`, `--disable-slash-commands`, only the declared tools) lives in one place. Every
  one-request launcher takes it instead of its own flags: `ask_claude.sh`, `share/web-search.sh`'s claudeb argv,
  and `worker-run` for a one-request brief (`bin/log-audit`'s chunk reads and merge, the end-of-day report).
  Model, effort and the account worker-pick names stay the same. The launchers' own flag lists go.
- Proof, config tokens per call, before → after: a call is a Claude session with exactly one non-sidechain
  request, in any zone (a temp-cwd call lands in `chat`; `unknown` is counted too), configuration = tokenmap
  `parts.est_tokens` except `user: your text`, the callers named by their run dir or log, not by zone.
  10-09…15 (`ts` 10-08T21:00Z…10-15T21:00Z): `worker` 173 calls at 36.1k (6.24M), `chat` 164 at 11.2k (of which
  the 40 temp-cwd stripped calls at 8.0k), `review-bench` 24 at 16.2k. After: the same callers at ≤8.0k.
- Outputs equal on a replay: one night's log-audit chunks and merge and one web search, through both launches on
  the same machine; identical, or a Sonnet judge reads the differences.
- Must not get worse: log-audit wall minutes.

## Done

| date | change | result | evidence |
|---|---|---|---|
| 10-05/08 | settings cuts | skill listing per main context −48 % | |
| 10-08/09 | relays retired, delegation made relay-free | relay spend to 0; per worker task 64.5k → 11.7k | ee185fa8 |
| 10-13 | workers skip the user CLAUDE.md; Workflow and ListAgents off workers | | 063ad0c8, 863668df |
| 10-13 | lighter review cells | | review-bench 35f6562 |
| 10-13/14 | md-compact passes | global CLAUDE.md 7.6 → 5.6 KB; llm-legs CLAUDE.md 2.1 → 0.8 KB; DIAGNOSTICS 196 → 124 KB | |
| 10-14 | stale RESUME refused | cold resumes had been 2.2 % of spend: median 199k rewritten, against 31k for a fresh worker | 9864be9d |
| 10-14 | Agent tool off workers | worker startup per task 29.4k → 19.4k | 5d780fd1 |
| 10-14 | first mined tool, `doctor-fix problems` | net proof needs 7 scanned days (≈10-21) | 2580854c |

## Decisions

- Model, effort and thinking are never the lever.
- The hook dispatcher was declined (10-05).
- Index doctrine (10-11): fee per unit of work against the previous 7 days; raw growth is load.
- Doctors ≈5 % of 7-day usage. The quality trade is decided only at the backlog plateau.
- Cold resumes were cut (10-14), over the 10-08 keep.
- A tool stays only if it net-saves. No tool for its own sake.
- md-compact has no quota.
- 10-15: the overhead nodes are audited and kept, with no night pass on them. The lever is volume, meaning how many
  fixers and review cells run, which is the direction 1 pilot.

## Open

- Review startup: re-measure ≈10-20, once the cells from before the 10-13 cut leave the window. Review spend
  itself is Debt's, paused.
- Cache-miss re-writes (class 2): diagnose the cause before any goal; workers' 11.0M is Spend's.
- The night's `Doctors 7d` reads `spend-7d.json`, which nothing has rewritten since 10-14 02:20.
- Night fixers' first request in llm-legs worktrees, 10-14…16 (36 fixers): the brief is 8.1k against 2.6k for a
  day worker in llm-legs, and the configuration is equal. Re-measure when the full night returns.
