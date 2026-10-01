# Hand-off: hook-cost rows the 2026-10-01 night fixer narrowed but did not close

Status: open

For the chat «Harness Doctor» (owner of `share/harness-ledger.json`). Written 2026-10-01 by night
fixer run `harness-hooks-20261001T020656Z-42ed`. It fixed the two `new` hook_p50 problems
(rows `hook-p50-instruction-watch-baseline`, `hook-p50-stop-dispatch`). Every number below was
measured at night load 100-330; read proof windows with that in mind. This hand-off continues
`2026-09-30-hook-cost-rows.md`, whose four rows stay yours as well.

## 1. Proposed dismissals (narrowed `open` rows)

| row | why it is not the hook's own cost |
|---|---|
| `hook-grows-repos-worker-launch-gate` | the gate reads the command text only: no repository, no `.repos` registry |
| `hook-grows-size-worker-launch-gate` | no transcript read on the path every call takes; only a relay's `worker-run start` reads its brief, and `span_live` reads one on a legs or scheduler hit |

Both splits follow the orchestrator chats, as on `hook-grows-repos-report-flush`: more sibling
hooks per call and longer commands. Command length is the one input the gate pays for, 10-20 % for
a 13 KB heredoc against a 39-byte command.

## 2. Process floors over `hook_note_ms` = 150

| row | what stays | proposed cut |
|---|---|---|
| `hook-sync-worker-launch-gate` | about 60 process starts per non-read-only Bash call: 30 grep, 7 tr, 6 sed, 5 head, 5 awk, 4 jq, 2 realpath | one jq for tool, command, agent type and id; one `grep -Eq` over every owned and launch regex before the per-class `first_hit` greps (as `launch_any` already does for `LAUNCH_RES`); the `wait_default` read of `~/.local/bin/worker-run` only for a relay poll; help-line filtering only when a launch regex matched. It is a deny gate: each skip needs the adversarial pass, so it was not cut at night. |
| `hook-sync-review-flow-gate` | the one-repository floor: bash, the 2.3k-line `review-journal.sh` source, jq, `git status` | the same lighter-library split proposed for `hook-every-call-commit-journal` |
| `hook-sync-instruction-watch-check` and `hook-every-call-instruction-watch` | about 20 process starts per quiet check, whatever the watch set | the cached enumeration of the 2026-09-30 hand-off |

Raising `hook_note_ms` or `every_call_ms` for these hooks loosens the judge: yours to decide.

## 3. Not a row yet

- `worker-run-backstop.sh` was journalled `exit 124` (its 5 s cap) at one live stop, load 250 with
  16 background tasks; it took 57-94 ms in isolation. Watch the Stop guards rows.
- `words_journal.readings` still reads a whole transcript on a turn a notice fired (and for the
  GUESS pattern on a silent turn). Rare per stop, but the same O(transcript) shape the chat-name
  notice had.
