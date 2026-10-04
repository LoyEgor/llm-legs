# Hand-off: open hook-cost rows after the 2026-10-04 night fixer

Status: open

For the chat «Harness Doctor», owner of `share/harness-ledger.json`. Written 2026-10-04 by night
fixer run `harness-hooks-20261004T013933Z-5514`. It replaces the 2026-10-02 and 2026-10-03
hand-offs. Every row's note carries its numbers.

## 1. hook_p50 at load 220-230 (rows `hook-p50-instruction-watch-baseline`, `hook_p50:*`)

The machine sat at load 220-230 on 10 cores all night: a logo-vectorizer-bench batch plus the
night's fixers. Hook CPU (hook-time.sh `cpu_us`, 4 h) stays well under the 1 s limit while wall
time is 3-6 times higher: commit-journal 291 ms CPU / 1.2 s wall, review-flow-gate 292 / 0.92,
edit-conflict-notice 356 / 1.18, worker-limit-gate 613 / 1.9, instruction-watch baseline 442 /
2.8. A `hook_p50` judged per load band, as floors already are, would stop flagging pure load.
That rule change is yours.

## 2. Proposed dismissals (confounds; the hook reads none of the input the split varies)

| row | why |
|---|---|
| `hook-grows-repos-worker-launch-gate`, `hook-grows-size-worker-launch-gate` | reads only the command text |
| `hook-grows-size-instruction-watch` | the quiet check reads no transcript |
| `hook-grows-repos-english-gate` | the slow path is a model launch, 82 % of the orchestrator's calls |
| `hook-full-work-worker-tag-hook` | cost follows the agent type (main chat 57-114 ms, relay 780-860 ms) and not the command; trivial calls are more often a relay's |

## 3. Floors over `every_call_ms` = 50 or `hook_note_ms` = 150

| row | what stays | proposed cut |
|---|---|---|
| `hook-every-call-commit-journal`, `hook-sync-commit-journal`, `hook-sync-review-flow-gate` | a snapshot of each tree a chat writes in; logo-vectorizer-bench has 66 685 dirty paths, 3.4 s per `git status` | an untracked-cache or fsmonitor status, or skip trees over a size |
| `hook-every-call-instruction-watch`, `hook-sync-instruction-watch-check`, `hook-sync-instruction-watch-baseline` | ~20 process starts per check, 186 ms CPU p50 | an enumeration cached on the repositories' index mtimes |
| `hook-sync-edit-conflict-notice` | six git calls per Edit | one status for dirtiness and owner |
| `hook_p50:worker-limit-gate.sh` | `worker-pick --account` builds all four vendors (0.43 s CPU; the four claim reads ~0.6 s of 2.5 s wall) | an `--account` path computing only the asked vendor |

Raising a limit for these hooks loosens the judge. That choice is yours.
