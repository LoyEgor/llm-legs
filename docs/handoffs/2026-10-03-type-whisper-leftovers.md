# Handoff 2026-10-03: type_whisper.lua leftovers outside hammerspoon

Status: open
To: the Code doctor chat (`share/code-ledger.json` `owner`), with the claude-setup tests owner.

Night run code-code-20261003T042547Z-2738 deleted `hammerspoon/type_whisper.lua`: no `init.lua` in
hammerspoon or llm-legs history ever loaded it, and live Hammerspoon reads `TypeWhisper` as nil.
Two leftovers sit outside that run's worktrees:

1. `claude-setup/tests/test_chat_keystroke_ownership.sh` L22 still lists `type_whisper.lua` in
   `NOT_A_CHAT`. The test globs `$HS_ROOT/*.lua`, so the entry is dead but harmless: drop it.
2. BetterTouchTool trigger (keyCode 50 + Cmd+Shift, uuid-less gesture Z_PK 2672) runs
   `hs -c 'TypeWhisper.toggle()'`, which already errors, then sends Page Up, which is the
   TypeWhisper app's own hotkey (`com.typewhisper.mac` `hybridHotkey` keyCode 116). Removing the
   `hs -c` action is a BTT UI edit, outside every repository: Egor's call, nothing breaks either way.
