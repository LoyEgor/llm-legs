# Handoff — one report module for every report Egor reads (2026-09-24)

## What Egor wants

Every report that lands in his chat (review, round, bench, commit, push, unresolved, worker
notice, and any future one such as a report on changed md files) comes out of ONE module: one
frame, one width, one label column, one wrapping rule, one number grammar. A change of width or
style is made in one place and reaches every report. A new report cannot look different because
it has no other way to render. Reports that follow each other in the chat must not differ in size
or design.

His words: «чтобы к этому репорту все шли и от него все исходило». He also said to raise the
doubtful questions with him and to do the unambiguous work without asking.

## Order of work

1. **Hunt first.** Launch a review-bench T2 double task hunt that lists every difference between
   the reports: renderers, frames, widths, label columns, wrapping, time words, number grammar,
   separators, header and footer words, and state words. The hunt also names every producer the
   inventory below missed. Read the `review-bench` skill before launching; the task text is yours.
2. **Triage the findings.**
   - A difference that is plainly accidental gets unified.
   - A difference that may be deliberate goes to Egor as a question, batched into one message:
     one line on what unifying costs, one on what staying different loses, and a recommendation.
3. **Build the module.** Move every producer onto it, retire the copies, and add a mechanical
   guard (see below).

## Already decided — do not re-litigate

These were settled with Egor in the chat that wrote this handoff.

- **Width and label column.** The frame is 56 columns (review-bench `round.REPORT_FRAME_WIDTH`,
  claude-setup `hooks/commit-report.sh` `FRAME_WIDTH`). The label column is 14.
- **No wrapping.** Ordinary rows must not wrap. Egor asked for the width precisely so that
  nothing wraps.
- **Numbers are bare, joined by `/`, with no header.** Each number is right-aligned in its own
  column, so the slashes line up across rows.
  - Cells: `solo/real/found`.
  - Verifier: `kept/checked/sent`, e.g. `63/69/81`.
  - Judge: `confirmed/received`.
  - Egor remembers which column is which. Never add words like `kept` or `unchecked` back.
- **Where words go.**
  - A kill word (`cut`, `cap`, `stall`) follows the numbers.
  - A state word replaces the numbers entirely: `failed`, `quiet`, `off`, `walled`, `not needed`.
  - The name stays in the name column.
- **Time words.** `45s`, `6.7m`, `27m` — the words of the cells table.

## Inventory known so far

The hunt must complete this list.

- **review-bench** (`share/rbench/`) — the review, round and bench reports.
  - `report.py`: `report_frame_header`, `aligned_report_lines`, `_wrapped_report_value`,
    `report_block_lines`, `_report_item_rows`, `REPORT_LABEL_WIDTH = 14`, `cell_time_word`,
    `report_minutes`, and `_post_report_bus` (kind `review`).
  - `round.py`: `REPORT_FRAME_WIDTH`, `REPORT_END`.
  - `stats.py`: the `review-bench stats` table, printed to the chat but not framed.
- **claude-setup** `hooks/commit-report.sh` (about 1000 lines) — the commit, push and unresolved
  reports.
  - It is a bash copy of the same layout: `frame_header`, `wrap_value`, `block_row`,
    `LABEL_WIDTH=14`, `VALUE_LINES=2`.
  - Emitted through `hooks/lib/report-emit.sh`, which calls `report-bus emit`.
  - The only thing keeping it equal to review-bench is review-bench `tests/test_consistency.sh`
    row `ab` (`docs/shared-invariants.md`) — a sync test, not one source.
- **llm-legs `bin/worker-run`** — posts the worker notice (kind `notice`, around line 588) as
  unframed `OUTCOME: …` / `vendor/account/model/effort · wall-clock: Ns` / `files: N`. It has a
  different time grammar (`431s` against `7.2m`) and no frame at all.
- **llm-legs `bin/report-bus`** — delivery only. `docs/report-bus.md` says the bus "owns
  rendering" but passes bodies verbatim. The bus kinds are `review`, `commit`, `push`, `notice`
  and `unresolved`.
- **Candidates to check.** Any other hook `systemMessage` Egor reads, and CLI tables he reads in
  the chat (`review-bench stats`, `llm-limits --table`, the llm-doctor copy-for-an-LLM brief).
  - Whether a CLI table belongs in the module is a question for Egor, not an assumption.
  - The Hammerspoon menubar is out of scope; it is a different surface.

## Known divergences and defects to fold in

- **Paths wrap mid-word.** The `integrity:` row of a review report breaks a path at column 56
  (`…/swif` + `t-lsp/…`). It should break at `/`, or the row should shorten the path.
- **The failed-cell streak clause still wraps at 56.** This is a `failed:` row whose cell failed
  several runs in a row (`cap · 3 runs in a row`).
- **Header durations use different time words.** The review header row reads
  `25.6 min / 17.8 min`, while the cells use `2.5m`.
- **`rejected:` and `confirmed:` spell counts in words** (`141 duplicate · 5 false · 6 noise`,
  `P1 14 · P2 25 · …`), while the tallies are bare slashes. Whether they move to the slash
  grammar is Egor's call — ask him.
- **One `failed:` fixture renders `cap 4m`**, the cause glued to the time with one space, next to
  `mismatch · theirs  30s`. Check whether it is a real inconsistency.

## Design leads — yours to choose, doubtful ones to Egor

- **Home: llm-legs.** review-bench already requires `LLM_LEGS_SHARE`, and claude-setup already
  depends on llm-legs' `report-bus` on PATH. The dependency direction allows it; the other
  repositories do not.
- **Shape.** One renderer takes rows (label, value, item continuation) and produces the framed
  block.
  - It can be a Python module producers import, with a thin CLI for bash producers.
  - Or `report-bus` itself can render structured bodies, since its doc already claims rendering.
  - Whichever it is, the width, label column, wrapping and number and time grammar live there
    alone.
- **Latency.** `commit-report.sh` runs in a hook on every commit and push. Measure the added cost
  of a Python start and keep it unnoticeable. Egor accepted about 50 ms in principle.
- **Guard (mechanical, not prose).** A test that fails when any producer draws its own frame,
  defines its own width or label constant, or posts an unframed body to report-bus outside the
  module. `test_consistency` row `ab` then goes away instead of growing. Record new
  cross-implementation invariants in llm-legs `docs/shared-invariants.md` and run
  `bash tests/test_consistency.sh`.

## How to verify

- **review-bench suites.** Run from a worktree:
  `LLM_LEGS_SHARE=/Volumes/Work/Projects/llm-legs/share CLAUDE_SETUP_ROOT=<claude-setup checkout> bash tests/run-all`.
  - Use the PATH `python3`; `/usr/bin/python3` is 3.9 and fails on `Path | None`.
  - `test_review_owner_gate.sh` fails from a worktree only because it resolves
    `$ROOT/../claude-setup`. That failure is environmental.
- **claude-setup:** `tests/test_commit_report.sh`, `tests/test_review_journal.sh`,
  `tests/test_review_flow_gate.sh`.
- **llm-legs:** `bash tests/run-all`, and `tests/test_consistency.sh` after touching an invariant.
- **Real reports.**
  - Render real runs next to fixtures. First copy a run directory from the bench store into a
    scratch `CLAUDEB_DIR` fixture; never point a check at the live `~/.claude-profiles/.claudeb`.
  - Show Egor before/after renders of each report kind as plain text blocks. He judges the look,
    not the diff.

## Rules and traps

- **Worktrees.** Work in `<repo>/.claude/worktrees/<branch>` in each repository. The main
  checkouts carry other chats' uncommitted work; never revert, stash or clean it.
- **Commits.** Only on Egor's word, one commit per word.
  - A `git rebase` counts as a new commit for the word gate.
  - To catch up with origin before a push, merge `origin/main` into the branch; a base merge needs
    no word.
- **Comments.** Near zero — only where a reader would otherwise break correct code.
- **Attribution.** No Claude Code attribution in commits.
