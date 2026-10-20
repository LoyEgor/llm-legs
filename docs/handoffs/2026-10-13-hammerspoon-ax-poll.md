# Hammerspoon: menu rebuild on every limits notify

Status: open
To: next night

The AX poll landed (hammerspoon@b4a4941, @75d60db), busy days still 100 CPU-min/day. 10-20 sample: timers 4.7% of a core, 40% styledtext.new, 25% json.decode. `refreshStateChanged` (automation_menu.lua) rebuilds all sections per limits notify: 9 in 100 s, 0.23 s CPU each (tracking 133 ms, instruction-watch 70). Lever: a notify rebuilds the limits section only; the rest keeps the 60 s clock.
