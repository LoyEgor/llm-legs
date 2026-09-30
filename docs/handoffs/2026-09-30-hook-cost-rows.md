# Hand-off: four hook-cost rows the night fixer did not close

Status: open

For the chat «Harness Doctor» (owner of `share/harness-ledger.json`). Written 2026-09-30 by night
fixer run `harness-hooks-20260930T001647Z-0f22`. It fixed the four `hook_grows_*` rows of
commit-journal and review-flow-gate. The cause was one snapshot per registered repository, taken
one after another before and after each call. They now run as parallel jobs (claude-setup
`rj_snapshot_repos`, commit-journal `consume_apart`). The four rows below are yours to decide.

## 1. Proposed dismissals (narrowed `open` rows)

| row | why it is not the hook's own cost | evidence |
|---|---|---|
| `hook-grows-repos-report-flush` | `report-flush.sh` and `bin/report-bus flush` read no repository and no `.repos` registry | Its p50 is 90 ms when a commit-journal run in the same PostToolUse batch took over 300 ms, and 49-57 ms otherwise. The window was 2026-09-29 19:00 to 2026-09-30 03:20 local, joined on ppid within ±50 ms. |
| `hook-grows-size-instruction-watch` | the quiet `check` path reads no transcript; only `revert_growth` does, on a changed guarded file | The same size split shows on report-flush, which reads neither input. |

Both rules measure a correlation, not a cost the hook itself pays. Sessions over 10 MB and 5+
repositories are the orchestrators. Their sibling hooks and the load around them slow every hook
in the batch. A rule change that could separate the two is also yours: for example, compare
against the batch's own sibling runs, or name the input the hook actually reads.

## 2. Every-call limit against hooks that must work per write call

| row | cut this run | what stays |
|---|---|---|
| `hook-every-call-commit-journal` | the multi-repository part | Bash start, a 2.3k-line `review-journal.sh` source (about 40 ms at load 170), jq and one `git status` on a one-repository call |
| `hook-every-call-instruction-watch` | the `~/.claude` walk skips `file-history` (3 596 of 5 784 entries, no watched file); `tr` instead of perl | the enumeration: three `git ls-files`, perl, a stat and two awk |

Neither hook can fit under `every_call_ms` = 50 in bash while it keeps its function. Either the
design changes, for example a cached enumeration or a lighter library split, or the limit changes
for this class of hook. Both choices are the owner's. Changing the limit loosens the judge.

## 3. Note for proof

These numbers were measured while the machine ran at load 110-380, during the night run. Read the
proof windows with that in mind.
