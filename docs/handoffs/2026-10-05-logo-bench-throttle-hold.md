# Hand-off: logo-bench-throttle waits (`limiter_hold:logo-bench-throttle`)

Status: open
To: «Vector Magic macOS ARM migration»

Ledger rows `limiter-hold-logo-bench-throttle` and the slot-wait `log_audit:` rows of night 20261029T012849Z-5e69;
blind spot `wait-journal-throttle-py`. The throttle works as designed; both items are in `bench/throttle.py`.

1. `hold_clear` unlinks the hold without journaling its wait, so the Wait classes never saw a
   logo-bench-throttle wait (design §12 "every wait is measured", invariant `ed`); the night of 10-29
   met ~8 h of them only through log-audit readings. Copy `wait_note` from llm-legs
   `share/limiter_hold.py` and call it in `hold_clear` as that file does. Then llm-legs adds
   throttle.py to row `ed`'s writers and a `tests/test_consistency.sh` assert beside row `dc`'s.
2. `all busy, 4 of 8 slots open, pressure level 1` names no cause: the 4 is `QUIET_JOBS` (keyboard input
   within `BENCH_IDLE_SECONDS`), yet the lane chat read it as memory pressure and two log-audit readings as
   4 free slots. Name the clamp in `status` (`keyboard in use`, `pressure`, `< 25 % free`) beside the count.
