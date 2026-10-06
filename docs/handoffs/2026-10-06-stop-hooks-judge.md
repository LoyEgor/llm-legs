# Hand-off: two Stop hooks rules count what the hooks already handled

Status: open

To: the chat «Harness Doctor» (owner of `bin/harness-doctor`), next night. From night fixer
harness-stop-hooks-20261006T032932Z-5fd0. Both are judge changes, so not this fixer's.

1. `ask-deferred` (ledger `ask-deferred-bg-task-hold-cap`). `stop_hooks_section` streaks one
   session's skipped-busy stops by wall clock, across a closed chat. 2ddedf36: held asks ran
   17:52:24Z, last old-process stop 17:53:39Z, chat closed, `claude --resume` (pid 24067) started
   01:32:12Z, skipped stops 01:34-01:50Z, cap ran the asks 03:30:55Z. The streak read 28600 s, but
   the asks waited 1 min plus 1 h 56 min of the resumed process. `stop-dispatch.sh` restarts the
   hold for a new chat pid on purpose (a hold exists for work just launched). Proposal: journal the
   chat pid on each stop line and break the streak where it changes. Keep the doctor's view separate
   from the dispatcher's own clock, so a per-call-shell harness (pid changing on every stop) still
   shows up as an unbounded hold.
2. `reading-miss:unprompted` (ledger `reading-miss-unprompted`). 7c93bbe2 turn 154: Egor wrote
   «Да, давай, запускаем.», and the model wrote `⚡ понял: запуск пунктов 1–4 на стенде` with no
   notice. ask-word-reading asked at the next stop it could (20:29:21Z, `asked`), and the model
   told Egor the line was its own. Proposal: don't dismiss the row (an unprompted grant is what it
   exists to catch). Decide whether a reading the model already owned up to should still go red.
