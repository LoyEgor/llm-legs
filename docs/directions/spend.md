# Spend (direction 4)

Tokens the harness itself costs: instructions, briefs, relays, hook text, review and doctor runs, worker startup,
and scripts models rewrite where one tool would do.

## Metric

- Fee index (tokenmap definition `pie-fee-task-3`): the harness's fee per task in a window, priced against the 7
  days before it. Below 1 means cheaper per task. Its consumers are Workers, Reviewers and Background; the night's
  runs (Doctors, Upkeep) stay out of it.
- Second number: Doctors' share of Claude usage over 7 days, Opus = 1 (Egor's ≈5 %, below): volume, mostly 547
  night fixers. Breakages' pilot (no row fixers) moves it, so no Spend goal is proven on it.

### Baseline (computed 2026-10-16)

Windows are full local days. The journals reach back past 10-02, so the prior window is complete.

| | 10-02…08 | 10-09…15 |
|---|---:|---:|
| **Fee index** (each window against its own 7 days before) | **0.49 (−51 %)** | **0.74 (−26 %)** |
| Fee, share of Claude spend | 13.3 % | 11.5 % |
| **Doctors' share of Claude usage** | **25.7 %** | **25.0 %** |
| Claude spend, plain limit tokens | 1,004M | 1,341M |
| tasks: Workers / Reviewers / Other | 677 / 372 / 160 | 662 / 903 / 194 |
| Spend-audit runs, Opus = 1 (plain) | — (they began 10-09) | 28: 7.63M (8.81M) |

- The index values are consecutive weekly drops in fee per task, not levels; spend's +34 % is load (Reviewers ×2.4).
- Not computed: Chat tasks before 10-09 (tokenmap shows "—").

Method, ≈90 s a window on an idle machine (over 10 min at load 130+):
- Fee index: `tokenmap tracking --since "2026-10-09 00:00" --until "2026-10-16 00:00" --json`. Read `harness_index`
  (`value`, `change`, `coverage`, the "Use (tasks)" section) and the `Claude spend` row.
- Doctors' share: `tokenmap.tracking.compute_spend(db.connect(db.DEFAULT_DB), tracking.windows_for(since=…,
  until=…))`, node `Doctors` `value / total[0]`, then `prev / prev_total[0]` (`tokenmap spend` takes no `--since`).
- Audit runs: run dirs whose `~/.cache/claude-worker-runs/*/brief` holds `# Fixer run harness-speed-spend-` and
  whose `meta.json` `started_at` is in the window (a `spend:` key match also takes log-audit chunks, which quote
  transcripts: 23 sessions, 7.15M plain); `started_at` is epoch seconds, read as a local day. Session: the run dir's
  `session` file, else its `worker-session` file; resumes share it. Sum
  `limits.request_sql('r')` × `tokenmap.pie.model_weight(model, day, speed, prompt)` over `requests.root_session`
  in `tokenmap.sqlite3` (`mode=ro`). 10-09…15: 39 dirs, 30 run tags, 28 of them (33 sessions) with requests.

## Sources

- tokenmap `~/.local/share/tokenmap/tracking.json`, `harness_index`: value, coverage, `cells` (tasks `units` and
  price per task `price` by consumer × leaf, this window then the one before), `sources`, and `loaded` (harness jobs
  that loaded Egor's configuration). Its hourly write covers a rolling 7 days, so a baseline uses the command above.
- The Spend pie (`compute_spend`); its copy `spend-7d.json` is the night's `Doctors 7d` (`share/night_spend.py
  doctors_share()`; Open).
- `share/spend-ledger.json`: 64 Spend rows on 10-16 (17 cut, 47 kept), keyed `fee:`, `hook:`, `startup:`, `spawn:`,
  `turns:`, `rewrites:`, `resumes`; its 339 `suite:`/`cpu:` rows and their reopens are Lost time's and System's.
- Audit packets `~/.cache/doctors/runs/harness-speed-spend-*.brief.md` (each problem's `audit due:` reason) and
  `<tag>.d/decisions.tsv` (its verdict and commit).
- Harness doctor `~/.cache/harness-doctor/latest.json` → `speed.spend`: the Fee index by day, the audits due (14 on
  10-16) and their proofs.
- `share/harness-ledger.json`, log-audit rows (classes 4–6). First-seen dates come from `git log -S` on the ledger.
- `tokenmap.sqlite3`, tables `requests`, `parts` and `doctor_windows`: what each call starts with, night against day.

## Recurring classes

Ranked 2026-10-16 by size in Opus = 1, from the audit packets, the 64 Spend rows, the log-audit rows and tokenmap.
Class 1's rows are hand labels from each row's `.note` (rows not keyed `suite:`/`cpu:`); its causes overlap (20 cut
tails + 7 load + 8 other key on 31 rows; an independent pass on 10-16 labelled 34: 21 / 7 / 9).

| class | count | size, 10-09…15 | days | instances fixed |
|---|---:|---:|---:|---:|
| 1. a Spend audit comes due with nothing new to change: a cut whose tail still sits in the 7-day window, a rise that was load or a tokenmap measurement change, a part kept before under another key | 78 of 81 audited problems; 31 of 64 rows | 6.65M of the audits' 7.63M (25 of 28 runs) | 5 audit nights, 10-09…14 | 31 rows, each closed alone |
| 2. a scripted one-request call carries the configuration it never uses | 173 worker calls | 6.94M; ≈0.05M a week left | 10-05…15 | 7 |
| 3. a session re-writes its whole context cold: idle past the cache, or another org's account | 5 | 0.11M since 10-14 (0.04M plain) | 10-10…14 | 1, held |
| 4. a run re-derives what a ledger holds: known reds, fixed rows re-proved, ledger ground re-profiled, a whole read redone | 5 | | 4 nights | 3 |
| 5. a run sized past what settles it, then run again: a 289-panel judge grid for ≈22 votes, a cap that measured itself, a biased answer key, Haiku cells on Sonnet, 241 images to one worker | 5 | | 2+ nights | 1 |
| 6. rework from an unsettled spec (Spend menu, Fee index rebuilt 3×, batch sizing, lens tuning): model behavior, no fixer | 6 | | 3 nights | 0 |

Why they come back:
1. `share/spend.py` `due()` reopens a component four ways: never audited, source changed (`moved()`), still
   loading after a cut, share ×1.5 (`SHARE_RISE`); the 81 came due as 69, 7, 0 and 5. Only `menus` has sources:
   the 7 were `hook:` rows before the 10-14 relabel to `fee:`, after which every relabelled key read as never
   audited, as does a component cut before its first audit while its tail stays 7 days. The share moves with load
   and with tokenmap's measurement changes (re-ingest, re-split: deferred tool list ×5.4, Review summary +26 %). The
   3 that changed something were Breakages' `gates` false catches (review-flow-gate, dia-not-chrome, english-gate).
2. 761cf189 made the stripped ask_* legs the launch for scripted model calls, yet 161 of the 173 calls are
   `bin/log-audit`'s chunk reads (115 Haiku, 39 Sonnet) and merges (7), 6 the end-of-day report, 1 code-doctor's
   critical judge, all through `worker-run`. Two 10-12 commits fixed most of it: the 39 Sonnet reads (4.37M, 33 past
   100k) predate reads on Haiku (ffdf3b0d), the 26 Haiku reads past 100k (briefs 155–262 kB) the 120 kB cap
   (6741fcf8); the 81 Haiku reads after it: 0 past 100k, max 84.9k, 7.3k Opus = 1 each. Left is configuration:
   ≈13–16k tokens a worker launch against ≈6k stripped (`parts` fixed + config of first requests), 1.1k Opus = 1 a
   chunk read, 16–20k an end-of-day report; stripping saves ≈0.05M a week now (no night, so no log audit, since
   10-14), ≈0.3M with one every night. No goal: `worker-run` cannot tell a one-request run at launch (scripted
   `doctor-fix`, `image-fanout` need tools; `ROUND: none` is any brief's), so each caller would add a flag.
   Method: one-request sessions (distinct `request_id`), `ts` 10-08T21:00Z…10-15T21:00Z, `zone = 'worker'`, caller
   from the transcript's first user text (run dirs pruned before 10-14), priced as the audit runs.
3. Fixed for claudeb by the 10-14 resume refusal (9864be9d): cold worker re-writes 32 (8.5M) on 10-13, 2 (0.04M)
   in 10-14…16; account switches 10 (3.5M), none since 10-13. Method: `requests` on `sessions.zone='worker'`,
   `waste_cause` in (`expired (1h+ idle)`, `idle 5-60min`, `account switch`), `request_sql('r')`. No goal.
4.–6. come from the night's fan-out, which Breakages' pilot removes, and from model behavior. Log-audit's whole
   reread is not fan-out: it runs in pilot prep (`bin/night-run` `PILOT_RULES`), and a stopped read restarts from
   its `since` (last 10-14). Class 5's one fix was review-bench's (909514f); the rest were the chat's choices.

## Goals

Goal scripted-bare was stopped on 10-23 by its first step (class 2 above). Bash-cap runs belong to Breakages'
`bash-cap`.

### goal audit-due: a Spend audit comes due only on its own price per task

Class 1. Every due reason but a new component reads a ledger row or a share, which load, relabels and tails move.
- Change, in llm-legs `share/spend.py` `due()`:
  - a `fee:` component is due when its price per task rose ×1.5 against the 7 days before (its tokenmap cells:
    this window's tasks at this window's over the previous window's prices, `units[0]`, `price[0]`, `price[1]`; a
    cell new to the window has a previous price of 0), or when it has no previous price and no ledger row. Its
    "never audited", "source changed" and `SHARE_RISE` go: a relabel shows in both windows, a cut's tail lowers
    the price, and a kept row returns only on a measured rise (the 10-15 decision holds);
  - `loaded:` (no cells) keeps "never audited" and "still loading after the cut"; `menus` (no tokens) comes due on
    a commit to its sources since its audit that no Speed audit run made (`foreign()`, `run_start()` and
    `landings()` stay for it; `git log` only, no blobs, no `moved()`);
  - a component under one audit run (7.63M / 28 = 0.27M Opus = 1; 0.31M plain `loaded[].tokens`) is never due;
  - `spend.moved` goes from Spend only: 11 of 12 Spend reopens were ruled out (0.078 %), while Suite's and CPU's
    source-edit reopens find real speedups, so `moved()` and `blobs()` stay for them (2026-10-20 night-cost research).
- Proof, a replay (the pilot runs no audits): old and new `due()` on the same inputs, the windows ending at the
  five audit nights' starts, 10-09…14 (`tokenmap tracking --since/--until --json`), each with the ledger at that
  night's base, and 10-09…15 (`--until "2026-10-16 00:00"`) with the ledger at b0698b17, where old `due()` gives 14,
  13 never audited. Before is old `due()`'s list on each input, never the packets' 81 (tokenmap and the ledger
  moved since). Better: new under half of old, summed over the six; a component old lists that an audit then
  changed (the 3 gates false catches) stays due under new.
- Once the full night is back: audit runs a week, 28 (7.63M Opus = 1) in 10-09…15, by the method above.
- Must not get worse: the components under the floor stay at or under 0.09 % of spend together (the `fee:`
  sources' `charged` under 0.27M: 7 sources, 0.785M of the 872.5M Opus-priced `harness_index.claude` on 10-09…15;
  the `loaded:` ones under 0.31M, Browser check and cwd.sh, add 0.26M plain).
- Blocked 10-23, the two criteria conflict: as written 178 → 54 but fee:Hooks (the gates) not due on n3/n4 (92abd4f2); fee: never audited kept due, Hooks due but 178 → 140 (899a2b2c).

## Done

| date | change | result | evidence |
|---|---|---|---|
| 10-05/08 | settings cuts | skill listing per main context −48 % | |
| 10-08/09 | relays retired, delegation made relay-free | relay spend to 0; per worker task 64.5k → 11.7k | ee185fa8 |
| 10-13 | workers skip the user CLAUDE.md; Workflow and ListAgents off workers | | 063ad0c8, 863668df |
| 10-13 | the ask_* legs launch stripped: empty cwd, `--safe-mode`, no tool schemas unless declared | Daily note replay: same `judge_needed` on 22.7k context instead of 71.3k | 761cf189 |
| 10-13 | lighter review cells | | review-bench 35f6562 |
| 10-13/14 | md-compact passes | global CLAUDE.md 7.6 → 5.6 KB; llm-legs CLAUDE.md 2.1 → 0.8 KB; DIAGNOSTICS 196 → 124 KB | |
| 10-14 | stale RESUME refused | cold resumes had been 2.2 % of spend: median 199k rewritten, against 31k for a fresh worker | 9864be9d |
| 10-14 | Agent tool off workers | worker startup per task 29.4k → 19.4k | 5d780fd1 |
| 10-14 | first mined tool, `doctor-fix problems` | net proof needs 7 scanned days (≈10-21) | 2580854c |
| 10-23 | bench gate counts the script's writing (`adhoc_write_s`) | dropped ledger lookup 0.034 vs 0.029 s: refused → passes (+2.46 s); 1 ledger bench, no flip | 286cbd24 |
| 10-23 | other vendors' uncaused re-send under 1 h scores 0 | 10-09…15 `cache miss` 4,258 → 0; Claude 1,233 same | token-map 22a55f2 |

## Decisions

- Model, effort and thinking are never the lever.
- The hook dispatcher was declined (10-05).
- Index doctrine (10-11): fee per unit of work against the previous 7 days; raw growth is load.
- Doctors ≈5 % of 7-day usage: the night's natural cost once the backlog is gone, never a cap a night is squeezed
  to fit (10-12). The quality trade is decided only at the backlog plateau.
- Cold resumes were cut (10-14), over the 10-08 keep.
- A tool stays only if it net-saves. No tool for its own sake.
- md-compact has no quota.
- 2026-10-15: the overhead nodes are audited and kept, with no night pass on them. The lever is volume, meaning how
  many fixers and review cells run, which is the direction 1 pilot.
- 2026-10-14: spend is compared in Opus = 1 (tokenmap's model coefficients), never in plain tokens or weekly-limit
  percentages: work moved to cheaper models must read cheaper. («Updater doctor»)
- 2026-10-13: a Fee cut with no downside is made unasked; one with a downside goes to Egor as a trade naming it.
  («Token spending tracking and optimization»)
- 2026-10-13: the 1-hour prompt cache stays for chats and workers; 5 minutes for all is unwanted (10-08 check:
  worker cache expiries 1601 → 7 a week). («Token spending tracking and optimization»)
- 2026-10-13: a small follow-up goes to the running worker (`RESUME`) only while it is far from compaction; equal
  tasks run in parallel; a job too big for one context is split up front, never left to self-compact. («Token
  spending tracking and optimization»)
- 2026-10-11: a benchmark takes the smallest grid that settles its decision and stops once a variant leads.
  («Updater doctor»)

## Open

- Review startup: re-measure ≈10-20, once the cells from before the 10-13 cut leave the window. Review spend
  itself is Debt's, paused.
- `spend-7d.json` is written only by `tokenmap spend --range 7d --write`, run by the menu's 7-day view (last 10-14
  02:20), so the night's `Doctors 7d` is stale; the night can run it first.
- Advisor 14 and Daily note 15 runs a week for one launch a day each (ledger notes, 7 days to 10-13), extras
  untraced; audit-due's price rule makes both due (×1.75, ×1.81 on 10-09…15, `cells` `price[0] / price[1]`).
- Night fixers' first request in llm-legs worktrees, 10-14…16 (36 fixers): brief 8.1k against 2.6k for a day
  worker there, configuration equal. Re-measure when the full night returns.
- One worker given 241 images self-compacted repeatedly; the harness ledger ruled it the chat's choice
  (`log_audit:one-worker-241-images`), against the split-up-front decision above. No class measures it.
- Focus-off experiment (claude-setup `EXPERIMENTS.json`, 2–3 % of Fee): Egor rules at its 10-20 review; the
  baseline's 10-09…15 window holds 10-13…15 of it.
