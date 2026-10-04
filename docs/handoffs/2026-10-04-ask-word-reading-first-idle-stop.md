# Hand-off: ask-word-reading drops owed turns at a chat's first idle stop

Status: done 2026-10-04 — word-miss-first-idle-stop-no-checkpoint

For the chat «Harness Doctor» (owner of `share/harness-ledger.json`), to land in claude-setup at the
next stop-hooks run that has a claude-setup worktree. Written 2026-10-04 by night fixer run
`harness-stop-hooks-20261004T013955Z-04b5` (no claude-setup worktree, so no commit there).

## Problem

`word-miss:review+span`: `words:1791035730/ec2ea43a…`, turn 2 noticed `⚡ review  ⚡ span on`, the model
read only `span on`. Every stop from 13:55Z to 14:41Z was `skipped-busy` (bg-task); the first idle
stop (14:45:46Z, turn ≥4) ran `ask-word-reading.sh` and stayed silent. The model's miss is its own;
the backstop failing to ask is ours.

## Cause

`hooks/lib/words_journal.py` `ask()`: with no `reading-checked` file yet, `num("")` is -1, so
`low = num(turn)` and only the current turn is read. The ledger row
`word-miss-deferred-reading-lost` (fix claude-setup@959efae) covers a chat that already had a
checkpoint; a chat whose stops were all busy until then never has one.

## Fix (probed in a /tmp copy against a fixture)

    low = num(low) if turn.isdigit() and 0 <= num(low) <= num(turn) else 0 if not low else num(turn)

Old code: no ask, `reading-checked` moves to 4, turn 2 is lost for good. Patched: one block naming
the turn-2 notice, the next stop silent. Add the case to `tests/test_words_log.sh` (no
`reading-checked`, an owed row two turns back, red on the old code). Side effect: a chat from before
2026-09-30 resumed now is asked once for its unread notices; those are real misses.
