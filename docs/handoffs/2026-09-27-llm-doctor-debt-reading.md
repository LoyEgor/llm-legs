# Hand-off: the LLM doctor's Debt row counts raw gap lines, not open problems

For the chat that owns `bin/llm-doctor` (`debt_health`). Written 2026-09-27 by the chat «Debt
hardening handoff», which fixed the recording side the same day (claude-setup hooks, review-bench
store). Nothing in `bin/llm-doctor` was edited: every item below is the doctor's to change.

## What the row said, and what was true

`llm-doctor --window 168` on 2026-09-27 reported `debt problem 1119`. The same week held 16 open
gap groups (`review-anchors gaps --days 7`). The difference:

| cause | lines the doctor counted | open problems behind them |
|---|---|---|
| one `hash-cap` gap repeated on every Bash call in one repository | 1090 | 1 (and a false one, see below) |
| gaps a review had already settled | counted | 0 |
| every other kind | ~29 | ~15 |

The `hash-cap` flood was a recording bug, now fixed on the recording side: the hook wrote the gap on
every Bash call that saw more than 500 dirty paths, even a read-only `git status`, and never
deduplicated it. Since the fix, `hash-cap` is written only when a capped path really changed, and
any gap line identical to one written in the last 120 s is not written again. Old lines stay in
the gaps files, so the doctor still has to stop counting lines.

## 1. Count open gaps, not lines (the main fix)

`debt_health` reads `~/.cache/claude/review-debt/gaps/*` line by line and counts every line inside
the window, settled or not, repeated or not. A gap is settled when a review anchor covers it; only
review-anchors knows that (`open_gaps`, per session and per repository family).

Read review-bench's reader instead of the files:

```
review-anchors gaps --days 7 --json
```

It prints one JSON object per open (session, kind, detail) group:
`{"session", "kind", "detail", "count", "first", "last"}`. Dead sessions are included, settled gaps
are not, and an unreadable store or gaps file is skipped with one stderr line. Count one problem per
row. `count` is how often it repeated, which is worth showing but is not a number of problems.
Contract: review-bench `docs/review-anchors-contract.md`, the gaps section.

## 2. The loss log exists now

The row's note `losses.jsonl not written yet` is out of date. `~/.cache/claude/review-debt/losses.jsonl`
gets one JSON line per deliberate drop of unreviewed lines:

`{"at": <epoch int>, "kind", "session", "repo", "path", "lines", "detail"}`

| kind | writer | session |
|---|---|---|
| `untouch` | review-anchors `untouch` | the chat whose touches were dropped |
| `migrate` | review-anchors `migrate` | empty; the touchers are in `detail` |
| `run-fold-skip` | review-anchors `run-fold`, a path the run changed that got no fix anchor | the launching chat |
| any gap kind | claude-setup `hooks/commit-journal.sh`, a gap with no session owner | empty |

The doctor already reads `at`, `kind`, `lines` and `session`. Two kinds carry an empty
`session`. Group those by `repo` so they do not merge into one nameless item.

## 3. The window hides old open gaps

The test `cutoff <= at <= now + 3600` drops a gap whose line is older than the window while it is
still open. With the reader in item 1, judge recency by `last` and keep showing an open gap for as
long as the reader returns it (`--days` bounds that).

## Test

`tests/test_llm_doctor.sh` covers the Debt row. It needs a stub `review-anchors` on PATH printing
`gaps --json` rows: two lines of one gap read as one problem, a settled gap is absent, and a
`losses.jsonl` row with an empty session is grouped by its repository.
