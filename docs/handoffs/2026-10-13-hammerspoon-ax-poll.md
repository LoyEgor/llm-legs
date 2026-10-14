# Hammerspoon: 100 ms Terminal tab poll

Status: settled 20261014T013750Z-8004: the idle-adaptive poll it recommends landed in hammerspoon@b4a4941 (0.1 s only for a 2 s burst after input or a context event, away-gated) and @75d60db (0.45 s idle, first chord after quiet still warm); test_claude_cmd_keys green

From night fixer harness-speed-cpu-statusline-render (20261012T233034Z-3131): `cpu:process/Hammerspoon` 92
CPU-min/day, mostly `claude_cmd_keys.lua` walking Terminal's AX tree every 100 ms.
