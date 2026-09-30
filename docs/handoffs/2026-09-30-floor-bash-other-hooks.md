# Hand-off: the Bash and Edit hook floors wait on three hooks another run owns

Status: open

For the chat «Harness Doctor» (`share/harness-ledger.json` `owner`). Written 2026-09-30 by the
night fixer run harness-hook-waits (night 20260930T001419Z-8480), ledger rows `floor-bash-other-hooks`
and `floor-edit-hooks`.

## Measured

Per-hook split of the joined batches, 3 h before 2026-09-30 03:18 (hooks of one batch run in
parallel, so a floor is the slowest hook of each side):

| class | side | slowest hook | p50 ms | p90 ms | next |
|---|---|---|---|---|---|
| bash:other | before | review-flow-gate | 253 | 841 | worker-launch-gate 179 |
| bash:other | after | commit-journal | 178 | 843 | instruction-watch check 170 |
| edit | before | edit-conflict-notice | 392 | 627 | instruction-bloat-gate 83 |
| edit | after | commit-journal | 280 | 389 | instruction-watch check 237 |

## Done here

The edit before side: `edit-conflict-notice` walked every unswept worker-run record of every
repository, forking `head`, `sed | head` and a `same_owner` subshell per record before asking whether
the record concerns the file. It now reads records with builtins and resolves their workdir in the
shell (claude-setup, branch `night/20260930T001419Z-8480/harness-hook-waits-20260930T001647Z-16ac`,
test in `tests/test_edit_conflict_notice.sh`: 24 records working elsewhere cost 72 head/sed processes
on the old hook).

## Yours

`review-flow-gate`, `commit-journal` and `instruction-watch check` are this night's harness-hooks
run's problems (`hook_every_call:*`, `hook_grows_repos:*`, `hook_grows_size:*`). Tuning them in two
branches at once would conflict, so this run changed none of them. Once that run lands:
- if `floor:bash:other` is still red, the next fixer starts from the table above;
- the edit floor also needs the after side under 500 ms together with the before side.
