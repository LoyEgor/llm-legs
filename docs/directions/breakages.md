# Breakages (direction 1)

Whatever breaks and has to be reacted to: the harness's gates, hooks, worker-run, the night and the doctors
themselves; the legs (image, video, workers, reviewers); vendor CLI updates; what the nightly transcript read
finds; every row fixed more than once.

## Metric

New distinct problems per 100 units of work, 7 days against the 7 before.
- Source: the doctor snapshots `bin/night-run` writes at every night's start and close, pilot or not
  (`~/.cache/doctors/nights/<id>.json`, `doctor_problems_before`/`_after`: id → state; Harness, LLM, Updater). Not
  ledger rows: only a fixer files one (`docs/doctor-fix.md`) and a pilot night launches none.
- A new problem: an id first shown `new` (no ledger row yet), on its snapshot's local day, counted once.
- The sum keeps the rules the doctors had on 10-02 (`git log -S` of the rule's name in its doctor); later rules go
  on their own line. Out of it: log_audit (classes, below), test_*, suites_at_once, the audits, Speed's rules
  (floor, hook_*, statusline, menu_build, collector, wait_*, worker_orphans, load, opportunity, regression),
  time_floor, tool_idea, growth-* (installs), store_size, debt-*, ledger faults, Updater `event-waiting` (per event).
- Units: `strata.chat.units + strata.workers.units` of `~/.cache/harness-doctor/budget-days/<day>.json`, as Lost
  time; they start 10-03, so the prior window is 5 days.
- Repeats, the second number (target 0): ledger rows a snapshot shows `regressed`, distinct per window, with the
  sum's exclusions (log_audit's aside, below; Speed's, test_*, time_floor and growth-* rows out too).

### Baseline (computed 2026-10-16)

| per 100 units | 10-03…07 (855 units) | 10-08…14 (1,952 units) |
|---|---:|---:|
| Harness | 1.05 (9) | 0.20 (4) |
| LLM doctor (legs) | 1.29 (11) | 0.10 (2) |
| Updater | 0.35 (3) | 0 |
| **total** | **2.69** | **0.31** |
| ids of a rule born after 10-02 (own line) | 3 | 4 |
| repeats | 8 | 6 |

- Snapshots start 10-04, so the first window also holds what was open then; 9 of its 11 LLM ids are the image legs
  after the 10-03 media launch. The second misses 10-11; its repeats: worker-run-backstop's hook-error and
  hook-held rows, R1, W7, W8, W10.
- The log audit gives exactly 15 findings a night, its merge cap; the raw count (224 → 541) grows with the
  transcripts. Neither shows a trend, so the log audit is measured by classes.

## Sources

- Harness doctor (`latest.json`) minus `suite_audit`, `test_*` (Lost time), `cpu_audit` (System), `spend_audit` (Spend).
- LLM doctor (the legs); Updater doctor (`share/updater-ledger.json` is empty: its problems live in the snapshots).
- Log audit (`bin/log-audit`, nightly since 10-07): Haiku reads the day's transcripts in chunks (55 on 10-14), Sonnet
  merges them into 15 Harness problems; ≈0.8 % of worker-run spend (7 days to 10-15; unconfirmed, no method named).
  Kept: the only reader of the night's own waste.
- Ledgers: `share/harness-ledger.json`, `share/doctor-ledger.json` (LLM).

## Recurring classes

Each was fixed as an instance, then came back elsewhere. Ranked 10-15 by hand from the 105 log-audit rows of
10-07…14 and the doctors' rows; "nights": the rows' distinct first commits (Stop hooks: hook-error rows 10-03…14).

| class | rows | nights | instances fixed |
|---|---:|---:|---:|
| a gate refuses a legitimate command: text matching (10-09, 10-10, 10-13, 10-14), launch-gate brief-format refusals, a commit gate reading the session's repository instead of the commit's, the headroom guard's unstated rule | 13 | 7/7 | 12 |
| parallel night fixers collide: one ledger row or handoff, landing races, the same component fixed twice | 10 | 5/7 | 6 |
| a suite run dies with its caller at the 10- or 25-min Bash cap and runs again (all calls: goal bash-cap) | 9 | 6/7 | 4 |
| fan-out into a walled account, then the night idles (≈715 min est.) | 8 | 5/7 | 1 |
| a Stop hook outruns its 5 s cap (Harness `hook-error`) | 7 | 6 days | 6 |
| a reviewer's output takes a shape its reader did not expect (R1: empty findings, agy Markdown, the coverage floor) | 1 | | 7 fixes |
| night load breaks timing tests | 5 | 3/7 | 4 |
| a worker writes a repository its brief never granted (W3, W5, W7, W8, W9) | 5 | 3 days (W3, W5 filed before 10-03) | W3 5×, W5, W7 3×, W8, W9 |
| shell environment: bash 3.2, zsh word-splitting, a launchd PATH | 3 | 3/7 | 2 (1 open) |
| the LLM doctor files one cause again as a new row each day (callers' argument errors refused before spend: I23, I35, I41, I48, all not-a-bug) | 4 | 4 days | 0 |
| model behavior: re-asked decisions, unverified claims, unrequested mechanisms (not mechanics, so no fixer) | ≈25 | 7/7 | |

The collision, walled-account and timing-test rows (23) are the night's own fan-out, stopped only while PILOT is
set, so they stay open; rows merge by id since 10-08 (`share/merge_ledger.py`): fixers collide on a row, a handoff
or a component, not the file.

One fix per class, an existing tool before our own: the three goals below; a worker writes only where its brief
grants, through its CLI's sandbox (workdir plus `--add-dir`, `codex exec --sandbox workspace-write`); a reviewer's
output is held to a schema by its CLI (`claude --json-schema`, `codex exec --output-schema`); fixers spread over
accounts by room.

## Why rows come back (2026-10-15 audit)

- **Re-fixes.** 48 harness-ledger rows were fixed 2+ times: 22 Speed `opportunity` rows (optimised again), 8
  measured under load (noise read as a regression), the rest real returns.
- **Audits reopen on edits.** Suite, CPU and spend audits reopen on any source edit (`spend.moved`, read by
  `share/{suite_audit,cpu_audit,spend}.py`): on 10-15, 139 of 252 suites audited 10-13/14 were due, none slower.
- **Log-audit evidence carries the read's time.** `audit_verdicts` (`bin/harness-doctor`) stamps every quote with the
  audit's `at`: a fix landed before the read reads regressed (blind spots `audit-fix-inside-window`,
  `log-audit-evidence-read-time`).
- **Doctors miss each other's verdicts.** The statusline render, settled 10-06
  (`docs/handoffs/2026-10-05-hook-cuts-left.md`), was fixed again on the nights of 10-13 and 10-14.
- **A repeat had no cheap exit** under 10-13's measured-evidence rule (997f1d1a), so a change was the fixer's
  cheapest way out; the pilot's `repeat:` exit (Mechanics) answers it.
- **The night makes its own.** Parallel fixers load the machine (load 100–240): tests flake, timings turn to noise.

## Goals

Worked in order, one at a time (`bin/night-run` PILOT, carry); a landed goal moves to Done with its commit and
proof, a failed one stays with one line on what blocked it. Reads after landing are journals the load also moves.

### goal gates: every gate decides on the parsed command, never its text

Class: a gate refuses a legitimate command, 13 rows on 7/7 nights, 12 fixed one gate at a time (causes in the
table; awk dying on Cyrillic let calls through, `log_audit:pretooluse-awk-multibyte-error`: not this class).
- The gates: 15 of the 18 PreToolUse Bash hooks on 10-15 (all but statusline-workdir-hook, worker-tag-hook,
  chat-switch-link); six use `hooks/lib/readonly-command.sh` or `heredoc-cut.sh`, the rest grep the raw text.
- One that denies by program or subcommand alone becomes a `permissions.deny` rule and its hook goes: Claude Code
  splits compound commands, checks subshells, substitutions and loop bodies, never matches quoted text, and denies
  in every mode, `bypassPermissions` included (code.claude.com/docs/en/permissions).
- One that needs context (whose session, Egor's words, the brief) reads `shfmt --to-json`'s parse (Homebrew), never
  the raw text, and decides as today on what it cannot parse; the two libs go. `$(…)` in double quotes or an
  unquoted heredoc, and a heredoc or `-c` body fed to a shell, are commands; other quoted text and comments are data.
- A formality never denies: the gate rewrites the input (`updatedInput`) or adds a notice (Decision 09-29).
- Corpus `~/.cache/harness-doctor/gate-corpus/corpus.jsonl`: 231 denials 08-05…10-16 (Stop, PostToolUse out),
  labelled 10-16 by two blind labellers (`label`/`label_b`, `cause`, `why`, `agreed`); agreed on 196: 81 legitimate,
  111 rightly, 4 unclear; `unknown-hook` rows (19) are named by their denial text. The goal's worker settles the 35
  disputed against each gate's purpose first; as many allowed Bash calls from the same transcripts join. One test
  replays it for every gate, replacing the per-gate text cases.
- Target 0: the 37 Bash rows the parsed argv removes: quoted or heredoc text read as a command 14, help and
  `--dry-run` probes 13 (5 filed `text-match`), a relative path off the call's own `cd` 1, a `cd` to the input's
  `cwd` 9. A deny rule refuses probes and no-op cds too, so their gates stay hooks on the parse.
- Out, counted apart (not worse): 25 Bash: Egor's words unread 10 (the word readers), a gate's purpose misjudged 5
  (that gate's rule), a `review-bench waive` earlier in the call 3 (crediting a step before it runs passes a failed
  one), gate crashes 3 (the replay fails a crashing gate; a crashed dependency is its own bug), a variable naming
  the program or argument 4 (unparsable: as today). 19 not Bash: an unpinned memory 11 (instruction-bloat-gate's
  rule passes it now; the replay confirms), edit-conflict-notice 6 (a foreign run without a file list claims its
  workdir: worker-run's `files`; one a notice, Decision 09-29), english-gate's straight quotes 1, Mattermost words 1.
- Proof replays the agreed rows: the 37 → 0, the 44 not more, rightly 111 stay refused, allowed calls allowed. Read
  after landing: the next 7 days' denials labelled the same way, target causes 0. Re-runs after a denial show
  nothing: workers re-run rightly refused commands too (`log_audit:workers-route-around-denials`).

### goal stop-hooks: no Stop hook holds the stop

Class: a Stop hook outruns its slice, each case fixed alone: worker-run-backstop (10-03, 10-06, 10-14; its
hook-held row 4 times), notice-chat-names, ask-span-drill, ask-word-reading, ask-run-unfinished,
notice-connections, stop-dispatch with no timeout binary on a launchd PATH.
- Load drives it: at 80+ machine-wide live runs 16 of 26 stops (night 10-13) waited ≥5 s and 3 were killed at the
  15 s timeout; under 20 live runs 1 of 2,741. Killed stops used only 0.22–0.32 s CPU (`hooks/folded/20739.tsv`).
  Transcript size, run root and the session's own live runs are not drivers.
- stop-dispatch's busy scan runs before `start=$SECONDS`, outside its budget; the backstop then runs alone before
  any notice (6–12.6 s of those stops). 15 of 16 kills at 15 s left no stop-gate journal line, so the old read
  (`journal.jsonl` errors) cannot see them.
- Change: `"asyncRewake": true` on the one Stop entry of claude-setup `local-config/home/.claude/settings.json`
  (runs in the background, wakes the model on exit 2); stop-dispatch turns a block into exit 2 with the reason on
  stderr; its 5 s/10 s budget and serial order go.
- **Blocked** by the check (10-23, 2.1.309, interactive): a rewoken stop sets `stop_hook_active`, but an async
  hook's `systemMessage` never shows (exit 0 or 2), its `stop_hook_summary` has no `durationMs`, a timeout kill no
  `hook_cancelled`: every notice goes silent. Open: notices on a sync entry of their own (10-15: no new hooks) or
  relayed by the rewoken model, a turn each. `claude -p` stays sync (code read).
- Proof: stops ≥5 s (kills included), per 1,000, from `hookInfos[].durationMs` (uuid-deduped: forks copy records)
  by band of worker runs live at the stop (run dir birth → `exit_code` mtime). 10-14 22:00…10-23 04:00, 2,429
  stops: under 20 9.9 (23, 6 killed), 20–79 90 (9 of 100, 3 killed), 80+ empty. Target 0 per band, an empty band
  unclear. Transcripts 10-01…16: 7,179 stops, 120 ≥5 s, 16 killed. Not worse: asks/holds (64), notices (54)
  delivered, ≤23 repeats within 5 min, Stop CPU p50 0.29 s.

## Done

- bash-cap (llm-legs 35d604a3, 10-23): workers no longer export `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS`, so a
  Bash call at its cap moves to the background. Proof at a 60 s cap, `test_night_run` as one plain call, old and new
  interleaved: old 2 of 2 killed, no result; new 2 of 2 moved, PASS 529. Read: killed worker calls, `sleep` excluded,
  207 (10-09…23) → 0 per 14 days; not worse: final responses with a task unread, `worker_orphans`.

## Decisions

- 2026-10-16: the directions run in a queue: the next direction's goals start once these goals have landed, and
  this metric is read 7 days after the last of them. It replaces 10-15's "direction 1 runs alone until its metric
  moves". Parallel directions were declined: two at once collide (bash-cap is also Lost time's) and blur the proof.
  («Updater doctor»)
- 2026-10-15: the pilot plan approved: goals gates → bash-cap → stop-hooks, one at a time; Egor launches the night.
  («Updater doctor»)
- 2026-10-15: `doctor-fix close` takes `ruled-out` with evidence `repeat: <what was fixed before>` on a row whose
  ledger row carries a fix, unmeasured: approved with the pilot plan as the one exception to 10-13's
  measured-evidence rule (P1/P2 Speed and test rows, outside this metric).
- 2026-10-15: no new hooks. Mechanics only where obvious, such as a tool replacing a script models keep rewriting.
  («Updater doctor»)
- 2026-10-15: a goal's worker may leave a goal its own diagnosis shows has little to gain, saying why, and the
  night moves to the next one; no second model re-checks that exit. («Updater doctor»)
- 2026-10-13: fixers have no count cap: rows editing the same files share one fixer, batch size comes from the
  measured cost per closed row, concurrency from `slot_room`. Never "too many" or "too few" as a fixed number.
  («Updater doctor»)
- 2026-10-13: ruled-out on a P1/P2 Speed or test row needs measured evidence.
- 2026-10-12: every cut made by one of our own caps or thresholds is logged where the doctors read it, so the night
  can tell normal from a fault. («Token spending tracking and optimization»)
- 2026-10-05: load is weather: a fix makes the harness hold under load (timing tests, hooks, measurements), never
  asks for a quieter machine or pauses other load. («Updater doctor»)
- 2026-09-29: a gate never makes a model redo work over a formality: a deny must prevent more than the redo costs,
  cosmetic cases pass, rewriting the input or adding a notice beats a deny; destructive-action guards and Egor's
  permission words stay. A gate that fires often means prevention is missing upstream. («Token map хуки оптимизация»)
- 2026-09-29: every hook or gate change gets a worker's adversarial edge-case critique (missed cases, false
  refusals, interactions with other hooks) before it counts as done. («Token map хуки оптимизация»)

## Open

- `bin/night-run` `pilot_goal` skips every goal with a job tonight whatever its outcome, so a failed goal lets the
  next one in its direction start the same night, against the 10-16 queue.
