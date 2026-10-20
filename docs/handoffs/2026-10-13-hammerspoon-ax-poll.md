# Hammerspoon: menu rebuild on every limits notify

Status: settled 2026-10-20: hammerspoon@3800a5f, a limits notify rebuilds LLM Limits alone, a busy start or end its own section, the rest keep a ttl (Doctors 5 min, Token tracking and Reports 10 min) and nothing rebuilds under an open menu (test_menu_cache red on the old code)
To: next night

The AX poll landed (hammerspoon@b4a4941, @75d60db), busy days still 100 CPU-min/day. 10-20 sample: timers 4.7% of a core, 40% styledtext.new, 25% json.decode. `refreshStateChanged` (automation_menu.lua) rebuilds all sections per limits notify: 9 in 100 s, 0.23 s CPU each (tracking 133 ms, instruction-watch 70). Lever: a notify rebuilds the limits section only; the rest keeps the 60 s clock.
