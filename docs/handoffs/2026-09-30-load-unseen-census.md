# Hand-off: load:unseen and load:busy are the night's requested work, not a bug

Status: open

For «Harness Doctor» (`share/harness-ledger.json` `owner`). Rows `load-unseen-suites-statusline`
and `load-busy-night-concurrency`, both `open`. Load fixers 2026-09-30, 10-01, 10-02 and 10-03
(harness-load-20261003T042543Z-5d17) each found nothing to fix; no limit, match or status moved.

## Facts (2026-10-03 07:30-09:30 local, night 20261003T042136Z-e9f1)

- Unseen 8.4 of 10 cores (limit 5), busy 100 % (limit 90 %), kernel 60 %, load average ~63.
- Page faults ~745 000/s, ~180 000/s copy-on-write: kernel time is fork and exec. Memory
  compression is not it (~200 decompressions/s).
- Live 30 s ancestor census (`proc_listallpids` + `KERN_PROCARGS2`, 1 350-1 840 new processes/s):
  test suites 44-62 %, statusline 19-25 %, hooks 8-19 %, worker-run 9 %, review-bench under 1 %.
- Both caps hold: three `run-suites` slots taken (`RUN_SUITES_SLOTS`, share/run-suites.sh) and
  night workers under `NIGHT_FIXER_SLOTS` (bin/worker-run, Egor 2026-10-01 in badbf8f). The
  concurrency question is settled; what remains is requested parallel work.
- The statusline is llm-legs `bin/statusline.sh` (`~/.claude/statusline.sh` links to it), not
  claude-setup. Per render: ~65-100 bash subshells; repo debt starts a `review-debt` Python walk
  every 15 s per shown tree (0.73 CPU-s, 0.40 of it kernel). Cuts that keep every segment as fresh
  (`$(file_mtime)` and `$(pct_colored)` forks) save about 1 % of the machine's forks; anything
  larger makes a segment staler, item 2 of `2026-09-28-harness-performance-fix.md`, Egor's word.

## Proposed to the owner

The judge re-launches a night load fixer every night for these two rows, and each one costs a
worker run to re-measure the same workload. Decide one of:

1. Judge `load:unseen` and `load:busy` only over samples where no suite slot and no night worker
   slot is held (`share/slots.sh` store locks under `~/.cache/run-suites/slots` and
   `<doctors>/fixer-slots`), so a red row means load nobody asked for.
2. Or accept both as night workload by your own dismissal.

Either loosens the judge, so a fixer may not do it. Recommendation: 1, since it keeps the daytime
signal that an idle chat waits on someone else's forks.
