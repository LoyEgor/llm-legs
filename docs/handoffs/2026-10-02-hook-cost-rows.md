# Hand-off: hook-cost rows the 2026-10-02 night fixer narrowed but did not close

Status: open

For the chat «Harness Doctor» (owner of `share/harness-ledger.json`). Written 2026-10-02 by night
fixer run `harness-hooks-20261002T093036Z-5607`. It fixed six of its eight problems (rows
`hook-sync-stop-dispatch`, `hook-grows-repos-stop-dispatch`, `hook-grows-size-stop-dispatch`,
`hook-sync-worker-limit-gate`, `hook-grows-repos-worker-limit-gate`, `hook-sync-worker-spawn-hook`).
Every number below was measured at night load 50-60. This continues `2026-10-01-hook-cost-rows.md`.

## 1. worker-pick's own floor (rows `hook-sync-worker-limit-gate`, `hook-sync-worker-spawn-hook`)

`worker-pick --account <vendor>` builds the whole four-vendor table to print one name: ~0.7 s at
load 50 after this run's cut (it skipped nothing before: the codex catalog check of e961a07 ran
`codexb models --own` for all 7 codex accounts on every call, ~0.9 s, now only for a codex or
table answer). Both Agent spawn hooks wait on it whenever they price or route a vendor spawn.
Under 150 ms needs an `--account` path that computes the asked vendor's section alone, or a
short-lived answer cache keyed on the limits file's mtime: a routing design change, yours.

## 2. edit-conflict-notice floor (row `hook-sync-edit-conflict-notice`)

195 ms p50 in 24 h. A probe on a dirty file: 426 ms over six git calls, shasum, two jq, one find,
none over 65 ms. The per-record forks went 2026-09-30. Under 150 ms needs one git status answering
both dirtiness and owner per Edit: a design change.

## 3. instruction-watch baseline floor (row `hook-sync-instruction-watch-baseline`)

Once per session. 530-600 ms warm over ~20 process starts, 2.6 s cold; the walk was cut on
2026-10-01. Under 150 ms needs the cached enumeration `hook-sync-instruction-watch-check` already
names. Its `reverts/` store holds 84 027 entries (663 MB): the `store_size` row, not this one.

## 4. Seen after launch, same components

`hook-p50-stop-dispatch` read `regressed` (1.8 s) and `hook_p50:worker-limit-gate.sh` `new` (2.7 s)
in the doctor's run after this one launched. Both are the causes fixed here (serial stop hooks,
worker-pick's catalog walk); judge them on the proof window after this branch lands.
