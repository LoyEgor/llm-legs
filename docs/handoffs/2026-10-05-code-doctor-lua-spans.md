# Code doctor: Lua spans run to the module end

Status: open

To: the next night's code run (owner `share/code-ledger.json` `owner`). From night 20261005T060033Z-052f run
code-code-20261005T061358Z-74be.

`block_end` in `bin/code-doctor` counts `function|do|then` in Lua string literals and comments as block
openers, so `if type(f) == "function" then f() end` leaves depth +1 and the symbol runs to the module end.
Measured on hammerspoon: `claude_continue.lua` runTerminal 718→2091 (really 920), runDestination 944→2091
(really 1069); module-end spans also in automation_menu (buildMenu, changeLogItem, untimed, refreshAfterPick),
display_mirror (5 symbols), ipad_overlay, chat_gate; log_upkeep trimFile stopped early at `seek("end")`.
Inflated spans feed the complexity and clone rules wrong numbers.

Fix, proven tonight then backed out (it red on the old code, test_code_doctor green with it):

    LUA_NOISE_RE = re.compile(r"\"(?:[^\"\\\n]|\\.)*\"|'(?:[^'\\\n]|\\.)*'|--.*")
    # in block_end, first line of the lua branch:
    line = LUA_NOISE_RE.sub(" ", line)

and in tests/test_code_doctor.sh after the two.py assert:

    lua = 'local function a(f)\n    if type(f) == "function" then f() end -- then do\nend\n\nlocal function b()\nend\n'
    assert [(s["name"], s["end"]) for s in cd.symbols_of(lua, "lua")] == [("a", 3), ("b", 6)], "a keyword in a Lua string or comment moved a span end"

Why backed out: `check` revalidates a run's units by reparsing the base with the current parser, so the fix
changed the digests of this run's judged runTerminal/runDestination units and sent its problem back to the
judge. Land it in a run whose snapshot holds no Lua unit (or as the night's code job before the judge), and
expect every Lua verdict whose span moved to be re-judged once.
