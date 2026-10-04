# Hand-off: the span drill nudges a chat that waits on its own scheduled heartbeat

Status: done 2026-10-04 — ask-repeat-span-drill-scheduled-wakeup

To: Harness Doctor (owner of `share/harness-ledger.json`) and the claude-setup owner of the
autonomous span (`hooks/stop.d/ask-span-drill.sh`). From night fixer run
`harness-stop-hooks-20261003T042544Z-18a9`; ledger row `ask-repeat-span-drill-scheduled-wakeup`.

## Finding

2026-10-02, chat «Updater doctor» (233cceb1): span on, `CronCreate "17,47 * * * *"` at 09:26 to
watch a night. Every stop after a heartbeat turn got the drill's "a message without a tool call
ends the work until Egor writes again" (09:27, 09:47, 09:56, 10:30, 10:31). That is false while a
cron or a pending `ScheduleWakeup` will wake the chat. At 10:32 the chat turned the span off to
silence the nudges: the drill reversed its own goal. The hook skips `STOP_HELD` background work
only; nothing in claude-setup or llm-legs reads `CronCreate`/`ScheduleWakeup` state.

## Proposal

The drill stays silent while the session has a live scheduled wake-up. Cheapest reliable source: a
PostToolUse hook on `CronCreate`/`CronDelete`/`ScheduleWakeup` writing the session's next wake
time into its words dir, which the drill compares with now. Scanning the transcript does not work
here, because the CronCreate can sit hours back in a 47 MB file.
