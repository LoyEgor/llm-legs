# Hand-off: open hook-cost rows after the 2026-10-03 night fixer

Status: open

For the chat «Harness Doctor», which owns `share/harness-ledger.json`. Written 2026-10-03 by night
fixer run `harness-hooks-20261003T042542Z-1344`. It replaces the 2026-09-30 and 2026-10-01
hand-offs, and the 2026-10-02 one stays open for its own rows. This run fixed
`hook-grows-repos-report-flush`: report-bus pruned on every flush. It also cut the orchestrator's
launcher-registry sweep and the library start on read-only and common calls
(claude-setup@9171da1). Every row's note carries the numbers, measured at night load 60-90.

## 1. Proposed dismissals (narrowed `open` rows)

| row | why it is not the hook's own cost |
|---|---|
| `hook-grows-repos-worker-launch-gate`, `hook-grows-size-worker-launch-gate` | the gate reads only the command text. It reads a transcript only for a relay's `worker-run start` or a legs/scheduler hit. |
| `hook-grows-size-instruction-watch` | the quiet `check` reads no transcript; only `revert_growth` does, on a changed guarded file |
| `hook-grows-repos-english-gate` | the slow path is a model launch. Launches are 82 % of the orchestrator's Bash calls and 1 % elsewhere; the common path is 132 ms against 118 ms. |

Chats with 5+ repositories or a transcript over 10 MB are the orchestrators. Where the split had a
real cause (stop-dispatch, worker-limit-gate, report-flush, commit-journal), that cause was found
and fixed. These four have none on their path. A rule that compares against the batch's sibling
runs, or names the input a hook reads, would stop flagging them. That rule change is yours.

## 2. Floors over `every_call_ms` = 50 or `hook_note_ms` = 150

| row | what stays | proposed cut |
|---|---|---|
| `hook-every-call-commit-journal`, `hook-sync-commit-journal`, `hook-sync-review-flow-gate` | a snapshot of every tree the chat writes in. The p50 is 363 ms outside the orchestrator, and one large tree dominates it: logo-vectorizer-bench has 33 704 untracked paths and takes 0.5-1.5 s per `git status`. | an untracked-cache or fsmonitor status, or skip trees over a size. Blind spot `snapshot-cost-per-repo` |
| `hook-sync-worker-launch-gate` | about 60 process starts per non-read-only Bash call | one jq; one `grep -Eq` over all owned and launch regexes before the per-class greps. It is a deny gate, so each skip needs an adversarial pass. |
| `hook-every-call-instruction-watch`, `hook-sync-instruction-watch-check` | about 20 process starts per quiet check: library source ~21 ms, three `git ls-files` ~31 ms, state subshells ~28 ms | an enumeration cached on the repositories' index mtimes |

Raising a limit for these hooks loosens the judge. That choice is yours.

## 3. Not a row yet

- `worker-run-backstop.sh` was journalled at `exit 124`, its 5 s cap, at one live stop. The load
  was 250 with 16 background tasks; in isolation it takes 57-94 ms.
- `words_journal.readings` still reads a whole transcript on any turn where a notice fired.
