# Hammerspoon config mirror

Versioned mirror of `~/.hammerspoon/*.lua` (the live source of truth). Copy files
INTO `~/.hammerspoon` to deploy; copy FROM it to refresh the mirror before a commit.
`llm-limits.lua` is the opposite case: the repo module in `../` is the source and
`automation_menu.lua` requires it straight from this repo's path.

System map (what loads what, all via `init.lua` pcall/dofile):

- `init.lua` — Sidecar screen watcher and unified iPad connect/disconnect actions:
  unconditional BetterDisplay dummy, Jump Desktop Connect, SonoBus group, transcription
  input device, iPad overlay, and Jump service wake-on-attempt watcher.
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
- `ipad_mode.lua` — `IpadMode`: iPad-present flag (Sidecar OR Jump client);
  Jump sessions detected event-based from `~/Library/Logs/Jump Desktop/Agent_*.log`
  via hs.pathwatcher (proxy-mode pids only), with midnight-rollover recovery and a
  60s pid-liveness recheck.
- `ipad_overlay.lua` — supervisor for the PyObjC panel in
  `../ipad_overlay_app/`. Reload contract: a helper alive at load time is
  replaced by a fresh one (launched with `--show`) or shut down — never
  adopted, so `hs.reload()` really reloads its code. What crosses the reload is
  the last explicit visibility, stored with the Hammerspoon pid so the replayed
  iPad-connected action cannot switch a hidden overlay back on.
- `automation_menu.lua` — the menubar: timers UI, iPad controls,
  LLM Limits submenu (repo `hammerspoon/llm-limits.lua`), iPad-only items
  (Copy / Paste / Enter / GPT Voice / GPT Transform) visible only in iPad mode.
- `type_whisper.lua` — typing helper.

User-facing notification strings are intentionally Russian (personal UX); code,
identifiers and comments stay English.
