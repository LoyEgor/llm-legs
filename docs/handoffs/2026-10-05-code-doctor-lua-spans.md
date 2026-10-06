# Code doctor: Lua spans run to the module end

Status: settled 20261006T032009Z-f253: block_end strips Lua literals (LITERAL_RE) and `--` comments before counting keywords; test_code_doctor Lua span assert red on the old code

To: the next night's code run (owner `share/code-ledger.json` `owner`). From night 20261005T060033Z-052f run
code-code-20261005T061358Z-74be.

`block_end` in `bin/code-doctor` counts `function|do|then` in Lua string literals and comments as block
openers, so `if type(f) == "function" then f() end` leaves depth +1 and the symbol runs to the module end.
Measured on hammerspoon: `claude_continue.lua` runTerminal 718→2091 (really 920), runDestination 944→2091
(really 1069); module-end spans also in automation_menu, display_mirror, ipad_overlay, chat_gate.

Backed out on 052f because `check` reparses the base with the current parser, so a moved span re-sends a
judged Lua unit to the judge. Landed on f253: its code run's only Lua unit (send_actions.lua
clipboardHasText L231-234) keeps its span and digest under the fix.
