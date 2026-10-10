# Log audit of night 20261009T023738Z-817e (run harness-doctor-20261009T024650Z-5055)

Status: settled 20261010T031219Z-4c4e: the six rows and the five older owner-only ones (overbuilt-before-asking, reports-jargon-and-unverified-claims, memory-guard-lane-pause, night-worker-queue-wait, detached-chain-dies-with-builder) dismissed not-a-bug: model conduct, no component

Ruled out as harness bugs, dismissal proposed:

- **hung-commands-25min-timeout**: a headless worker's Bash stdin is /dev/null; the stalls were the model's own
  `sleep 1500` polls, a backgrounded child holding a pipe and an unscoped recursive grep.
- **padding-claim-unverified**, **landing-wrapper-rebuilt**: model conduct. A guard against one rebuilt name is the
  one-incident ban Egor declined.
- **relay-retirement-parity-missed**: the process of one finished migration (ee185fa8).
- **trace-stale-retrace-after-code-change**: lane planning in the chat «Vector Magic macOS ARM migration».
- **token-map-rule-and-menu-rework**: token-map's own process in its owner chat; the log/app split landed (0106037b).
