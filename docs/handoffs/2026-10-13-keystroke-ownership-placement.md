# Hand-off: the keystroke-ownership guard lives outside the repository it guards

Status: settled 20261014T013750Z-8004: moved to hammerspoon `tests/`, `HS_ROOT` defaulting to the repository

claude-setup `tests/test_chat_keystroke_ownership.sh` globbed `$HS_ROOT` (default `~/.hammerspoon`, the
hammerspoon MAIN checkout): no hammerspoon change selected it, and a worktree's new key press was
unseen until it landed (a `keyStroke` appended to `claude_compact.lua` in a worktree: red now).
