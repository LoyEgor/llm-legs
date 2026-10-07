# Hand-off: two Stop hooks rules count what the hooks already handled

Status: settled 20261006T233611Z-7777: (1) the doctor ends a deferral streak where a new chat pid repeats, live once claude-setup stop-dispatch.sh journals `pid` (row fixed-pending until then); (2) an owned-up unprompted reading stays red

To: the chat «Harness Doctor» (owner of `bin/harness-doctor`), next night. From night fixer
harness-stop-hooks-20261006T032932Z-5fd0.

1. `ask-deferred` (ledger `ask-deferred-bg-task-hold-cap`). `stop_hooks_section` streaked one
   session's skipped-busy stops by wall clock across a closed chat (2ddedf36: 28600 s read, asks
   waited 1 min + 1 h 56 min of the resumed process). Proposal: journal the chat pid on each stop
   line and break the streak where it changes, while a per-call-shell harness (pid new on every
   stop) still shows an unbounded hold.
2. `reading-miss:unprompted` (ledger `reading-miss-unprompted`). 7c93bbe2 turn 154: a `⚡` reading
   with no notice, owned up to at the next ask. Decide whether an owned-up reading should go red.
