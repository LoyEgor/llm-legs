# Hammerspoon: 100 ms Terminal tab poll

Status: open
To: Egor. From: night fixer harness-speed-cpu-statusline-render (20261012T233034Z-3131).

`cpu:process/Hammerspoon` is 92 CPU-min/day (`sample`: ~6 % of one core, ~62 % in timers). The dominant timer is
`claude_cmd_keys.lua` `refreshTimer = hs.timer.doEvery(0.1, pollFrontTab)`: while Terminal is frontmost it walks the AX
tree (`childrenWithRole`, `AXValue`, `AXTabs`) every 100 ms; it already exits early for other apps. The same poll
spawns `osascript` (`ttyRefreshAfter` 1 s) and `ps -t` (`refreshAfter` 0.35 s): `cohort:Hammerspoon`, 3.7 births/s.

Cost: Lua in the hammerspoon repo; an input feature that cannot be UI-checked at night.
Loss: a slower or event-driven poll (`hs.application.watcher`, AX observer) risks a stale tab context on a Cmd press.
Recommendation: try an idle-adaptive poll (100 ms after a key or tab event, 1 s idle) with Egor present to test it.
