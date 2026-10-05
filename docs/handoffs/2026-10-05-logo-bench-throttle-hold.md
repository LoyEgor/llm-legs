# Hand-off: logo-bench-throttle holds (`limiter_hold:logo-bench-throttle`)

Status: open

Ledger row `limiter-hold-logo-bench-throttle`; night fixer run `harness-doctor-20261005T061224Z-4873`.

1. For the chat «Vector Magic macOS ARM migration» (logo-vectorizer-bench): `bench/throttle.py`
   `hold_clear` unlinks the hold without journaling its wait, so the Wait classes never saw one
   logo-bench-throttle wait (no row in `~/.cache/harness-doctor/waits/*.jsonl`) against design §12
   "every wait is measured" and invariant `ed`. Copy `wait_note` from llm-legs
   `share/limiter_hold.py` and call it in `hold_clear` as that file does. Then in llm-legs add
   throttle.py to row `ed`'s writers and a `tests/test_consistency.sh` assert beside row `dc`'s.
2. For the chat «Harness Doctor»: the hold itself is the throttle as designed. 2026-10-05 06:12Z
   9 bench jobs waited up to 9 min under macOS pressure level 2 (warn) at 43 % free, so
   `WARN_JOBS` = 3 slots ran; at 11:00Z 4 jobs of two chats still held at level 2, 47-52 % free,
   swap 5.7 of 6 GB used, load average ~330 under the night (6 night-workers holds). The row stays open; whether a hold under a night's own requested
   load is judged like the load rows (`load-busy-night-concurrency`) is your call.
