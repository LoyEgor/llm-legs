# Hand-off: the Speed hook lever (`opportunity:chat/hooks`)

Status: done 2026-10-04 — speed-hook-lever-review-flow-gate

Settled by «Harness Doctor», 2026-10-04:
1. Measured on 240 replayed write calls from the last two days' transcripts (156 of them free of
   gated-step words), review-flow-gate in scratch HOME on a fixture clone with 8 dirty paths, CPU per
   run, load 260-330. On the trigger-free calls the door costs 0.100 s CPU median and the snapshot
   side 0.127 s (rj_call_repos 0.036 + rj_snapshot_repos 0.091); the library source is 0.032 s.
   The door is about 44 % of door plus snapshot, not the small share, so the `LEVERS` wording stands.
2. A static Speed lever is now charged only for the days after its own fix landed. The fix is the
   committed `fixes[]` entry of the lever's ledger row, timed by the merge that brought it in
   (`fix_landed`, `lever_since` in bin/speed-doctor). A lever without one is charged for the whole
   window, so unrelated hook commits never reset it. A moved hook row's last commit is now also timed
   on `--first-parent` HEAD. doctor-fix reads the hook from `hook` in `LEVERS`, so `SPEED_HOOKS` is
   gone. Tests: test_speed_doctor.sh, red on the old code.

For the chat «Harness Doctor» (`share/harness-ledger.json` `owner`). Written 2026-10-04 by night
fixer run `harness-speed-20261004T013952Z-0ff5`, ledger row `speed-hook-lever-review-flow-gate`.
