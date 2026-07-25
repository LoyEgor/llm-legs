# Hammerspoon config mirror

Versioned mirror of `~/.hammerspoon/*.lua` (the live source of truth). Copy files
INTO `~/.hammerspoon` to deploy; copy FROM it to refresh the mirror before a commit.
`llm-limits.lua` is the opposite case: the repo module in `../` is the source and
`automation_menu.lua` requires it straight from this repo's path.

System map (what loads what, all via `init.lua` pcall/dofile):

- `init.lua` — monitor state machine (`MonitorAutomation`: MONITOR_ON / MONITOR_OFF /
  NO_PHYSICAL from screen names; physical display "PL3461WQ"), monitor-off action
  (BetterDisplay + Jump Desktop Connect via a 10s confirm timer that re-snapshots
  screens and defers while a Sidecar connect is in flight), dock auto-hide policy
  (auto-hide ON everywhere except during a live Sidecar session).
- `notify.lua` — `Notify.send/log`, log at `~/.hammerspoon/notify.log`.
- `claude_continue.lua` — `ClaudeContinue`: two resume-timer slots (app, terminal),
  persisted in `claude_continue_state.json`; consumed by repo `bin/claude-resume-timer`.
- `claude_chat_switch.lua` — chat switch typing driver (menu-only feature).
- `gpt_voice.lua` — GPT voice recording/transform states shown in the menubar title.
- `gpt_voice_keys.lua` — `GptVoiceKeys.postKey/returnKey`: Enter/Esc stamped with
  transcriptions-gpt's marker so its tap passes them through instead of treating
  them as the stop/cancel trigger of a live dictation. Used by every module that
  types into the frontmost window (`claude_continue`, `claude_chat_switch`, and
  claude-setup's `claude_compact`/`claude_trash`).
- `handoff.lua` — `HandoffGuard`: real macOS Handoff state (async defaults), reconnect cycle.
- `ipad_trigger.lua` — HTTP server :8765 for iPad shortcuts; Sidecar connect via
  `~/.local/bin/SidecarLauncher` (private SidecarCore CLI, built from
  github.com/Ocasio-J/SidecarLauncher) with AppleScript Displays UI as fallback;
  single-flight; instant HTTP replies (the iPad shortcut displays the response).
- `ipad_mode.lua` — `IpadMode`: iPad-mode flag (monitor off OR Sidecar OR Jump client);
  Jump sessions detected event-based from `~/Library/Logs/Jump Desktop/Agent_*.log`
  via hs.pathwatcher (proxy-mode pids only), with midnight-rollover recovery and a
  60s pid-liveness recheck.
- `automation_menu.lua` — the menubar: timers UI, Monitor/Handoff/Dock/For iPad block,
  LLM Limits submenu (repo `hammerspoon/llm-limits.lua`), iPad-only items
  (Copy / Paste / Enter / GPT Voice / GPT Transform) visible only in iPad mode.
- `type_whisper.lua` — typing helper.

User-facing notification strings are intentionally Russian (personal UX); code,
identifiers and comments stay English.
