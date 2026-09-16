local source = debug.getinfo(1, "S").source
local root = source:match("^@(.+)/tests/[^/]+$")
assert(root, "harness path is unavailable")

local fixture = _G.INSTRUCTION_WATCH_FIXTURE
assert(type(fixture) == "string" and fixture ~= "", "no fixture state directory was passed")

local savedPath = package.path
local existing = package.loaded["instruction-watch"]
local savedGlobal = _G.InstructionWatch
package.path = root .. "/hammerspoon/?.lua;" .. package.path
-- `require` caches, and this harness runs inside a Hammerspoon that may have loaded the module
-- hours ago: without dropping the cache first, every run after the first one checks the version
-- that was on disk THEN, and an edit to the module could never fail it. The live instance is
-- stopped rather than abandoned, or its watcher and timer outlive it.
do
    if type(existing) == "table" and type(existing.stop) == "function" then
        pcall(existing.stop)
    end
    package.loaded["instruction-watch"] = nil
end
local savedWatcher = hs.pathwatcher
-- nil would trigger Hammerspoon's extension autoloader and start the module against live state.
hs.pathwatcher = false
local loaded, M = pcall(require, "instruction-watch")
hs.pathwatcher = savedWatcher
if not loaded then
    package.path = savedPath
    package.loaded["instruction-watch"] = existing
    _G.InstructionWatch = savedGlobal
    if type(existing) == "table" and type(existing.start) == "function" then pcall(existing.start) end
    error(M)
end

local failures = {}
local function check(ok, message)
    if not ok then failures[#failures + 1] = message end
end

local alerts = {}
local savedDir = M.stateDir()
local savedWatcherNew = hs.pathwatcher.new
check(debug.getinfo(M.pump, "S").source:sub(1, #root + 1) == "@" .. root,
    "the harness loaded instruction-watch outside its root")

local function restore()
    hs.pathwatcher.new = savedWatcherNew
    M.stop()
    M.setAlert(nil)
    M.setPasteboard(nil)
    M.setOpenCommand(nil)
    M.setChatResolver(nil)
    M.setRatesPath(nil)
    M.setStateDir(nil)
    package.path = savedPath
    package.loaded["instruction-watch"] = existing
    _G.InstructionWatch = savedGlobal
    if type(existing) == "table" and type(existing.start) == "function" then pcall(existing.start) end
end

local function readFile(path)
    local handle = io.open(path, "r")
    if not handle then return nil end
    local body = handle:read("*a")
    handle:close()
    return body
end

local function appendEvent(id, isoStamp, summary, files, bytes, chat, sid)
    local handle = io.open(fixture .. "/events.jsonl", "a")
    if not handle then return false end
    handle:write(hs.json.encode({
        id = id, at = isoStamp, sid = sid or "harness", summary = summary,
        sent = "attempted", files = files or { "/tmp/" .. id .. ".md" },
        restores = {}, reverted = {}, bytes = bytes, chat = chat,
    }) .. "\n")
    handle:close()
    return true
end

-- Not `hs.inspect`: this message is built whether the check fails or not, and touching that
-- extension makes a cold Hammerspoon print a load line into the output the suite compares.
local function describe(result)
    return string.format("delivered=%s alerted=%s stale=%s",
        tostring(result.delivered), tostring(result.alerted), tostring(result.stale))
end

local function plain(title)
    return type(title) == "userdata" and title:getString() or tostring(title or "")
end

local function findRow(items, needle)
    for _, item in ipairs(items or {}) do
        local title = plain(item.title)
        if title:find(needle, 1, true) then return item end
    end
    return nil
end

local ok, err = pcall(function()
    M.stop()
    M.setStateDir(fixture)
    M.setAlert(function(text) alerts[#alerts + 1] = text end)
    local namedSid, silentSid, chatSid = "aaaa1111-0000-4000-8000-000000000001",
        "bbbb2222-0000-4000-8000-000000000002", "cccc3333-0000-4000-8000-000000000003"
    local resolverLine = "Named by resolver (aaaa1111)"
    local askedSids = {}
    M.setChatResolver(function(sids, onDone)
        local lines = {}
        for _, sid in ipairs(sids) do
            askedSids[sid] = (askedSids[sid] or 0) + 1
            if sid == namedSid then lines[#lines + 1] = resolverLine end
        end
        onDone(table.concat(lines, "\n"))
    end)

    local body = readFile(fixture .. "/events.jsonl")
    check(body ~= nil and body ~= "", "the collector left no journal to read")
    local seeded = hs.json.decode(body:match("^([^\n]+)"))
    check(type(seeded) == "table" and type(seeded.id) == "string",
        "the collector's record does not decode")

    local first = M.pump()
    check(first.delivered >= 1, "the pump delivered nothing: " .. describe(first))
    check(first.alerted >= 1, "the pump wrote a receipt without showing anything")
    check(#alerts >= 1, "no alert reached the recorder")
    check(tostring(alerts[1]):find("Instruction file changed", 1, true) ~= nil,
        "the alert does not name what happened: " .. tostring(alerts[1]))

    local receipt = hs.json.decode(readFile(fixture .. "/receipts/" .. seeded.id) or "{}")
    check(receipt.alerted == true, "the receipt does not record that an alert was shown")
    check(type(receipt.at) == "string" and receipt.at ~= "", "the receipt carries no timestamp")

    local alertsBefore = #alerts
    local second = M.pump()
    check(second.delivered == 0, "a receipted change was delivered twice")
    check(#alerts == alertsBefore, "a receipted change was alerted twice")

    local items = M.menuItems()
    local row = findRow(items, "●")
    check(row ~= nil, "no delivered row in the menu")
    if row then
        check(type(row.menu) == "table", "the row has no detail submenu")
        check(findRow(row.menu, "Copy command to open this chat") ~= nil, "the row offers no chat command")
        check(findRow(row.menu, "Copy restore command") == nil, "the row still offers a restore command")
        check(findRow(row.menu, "Run ") == nil, "the menu offers to RUN a restore")
    end
    check(findRow(items, "Coverage") ~= nil, "the menu does not show what is covered")
    local coverage = findRow(items, "Coverage")
    if coverage then
        check(findRow(coverage.menu, "CLAUDE.md") ~= nil,
            "the coverage submenu does not list the ranked project file")
        check(findRow(coverage.menu, "#") == nil,
            "the cache's version stamp was shown as a watched file")
    end

    local stale = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 3 * 24 * 3600)
    appendEvent("stale0001", stale, "CHANGED /tmp/old.md (+1 bytes)")
    alertsBefore = #alerts
    local third = M.pump()
    check(third.delivered == 1, "the stale record was not receipted")
    check(third.stale == 1, "the stale record was not counted as stale")
    check(#alerts == alertsBefore, "a three-day-old change was put on screen")
    local staleReceipt = hs.json.decode(readFile(fixture .. "/receipts/stale0001") or "{}")
    check(staleReceipt.alerted == false, "the stale receipt claims an alert was shown")
    check(staleReceipt.reason == "stale", "the stale receipt does not say why")

    -- Stale records must not consume the burst cap: 4 stale then 1 fresh shows the fresh one.
    alertsBefore = #alerts
    for i = 1, 4 do
        appendEvent(string.format("staleq%04d", i), stale, "CHANGED /tmp/old.md (+1 bytes)")
    end
    appendEvent("freshbehind", os.date("!%Y-%m-%dT%H:%M:%SZ"),
        "CHANGED /tmp/fresh-behind.md (+1 bytes)")
    local behind = M.pump()
    check(behind.stale == 4, "four stale records were not counted as stale: " .. describe(behind))
    check(behind.alerted >= 1, "a fresh change behind stale records was not shown")
    check(behind.delivered == 5, "stale-then-fresh was not fully receipted: " .. describe(behind))
    local named = false
    for i = alertsBefore + 1, #alerts do
        if tostring(alerts[i]):find("fresh-behind", 1, true) then named = true end
    end
    check(named, "the fresh change behind stale records was not named on screen")
    local freshReceipt = hs.json.decode(readFile(fixture .. "/receipts/freshbehind") or "{}")
    check(freshReceipt.alerted == true, "the fresh-behind receipt does not record an alert")
    check(freshReceipt.reason ~= "collapsed", "the fresh-behind record was receipted collapsed")

    local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
    for i = 1, 6 do appendEvent(string.format("burst%04d", i), now, "CHANGED /tmp/b.md (+1 bytes)") end
    alertsBefore = #alerts
    local fourth = M.pump()
    check(fourth.delivered == 6, "the burst was not fully receipted: " .. describe(fourth))
    check(#alerts - alertsBefore <= 4, "a burst of six changes put more than four lines on screen")
    check(#alerts - alertsBefore >= 2, "a burst of six changes put nothing on screen")
    check(tostring(alerts[#alerts]):find("more instruction changes", 1, true) ~= nil,
        "the collapsed line does not point at the menu: " .. tostring(alerts[#alerts]))

    local spacePath = "/Users/me/My repo/CLAUDE.md"
    appendEvent("spacepath", os.date("!%Y-%m-%dT%H:%M:%SZ"),
        "CHANGED " .. spacePath .. " (+1 bytes)", { spacePath })
    M.pump()
    local spaceItems = M.menuItems()
    local spaceRow = findRow(spaceItems, "My repo/CLAUDE.md")
    check(spaceRow ~= nil, "a path with spaces was not shortened to parent/base")
    if spaceRow then
        check(plain(spaceRow.title):find("Users/me/My ", 1, true) == nil,
            "a path with spaces was split: " .. plain(spaceRow.title))
    end

    local ratesPath = fixture .. "/read-rates.json"
    local indexed = "/tmp/project/CLAUDE.md"
    local other = "/tmp/x/a.md"
    local unknown = "/tmp/unlisted/missing.md"
    local zero = "/tmp/zero/CLAUDE.md"
    local handle = assert(io.open(ratesPath, "w"))
    handle:write(hs.json.encode({ paths = { entries = {
        [indexed] = { mode = "always_on", weekly = { loads = 100, reads = 900 } },
        [other] = { mode = "on_demand", weekly = { loads = 50, reads = 100 } },
        [zero] = { mode = "always_on", weekly = { loads = 100, reads = 50 } },
    } } }))
    handle:close()
    M.setRatesPath(ratesPath)
    appendEvent("columns1", now, "unused; summary", { indexed, other, unknown },
        { -320, 0, 0 }, "Named chat (1234abcd)")
    appendEvent("columns2", now, "unused", { other }, { -640 })
    appendEvent("unknownprice", now, "unused", { unknown }, { 184 })
    appendEvent("zerodelta", now, "REVERTED " .. zero .. " (+20 bytes)", { zero }, { 0 })
    local menus = M.menuItems()
    local multiple, single, absent = findRow(menus, " +2 more"), findRow(menus, "x/a.md"),
        findRow(menus, "unlisted/missing.md")
    check(multiple ~= nil, "a three-file event has no +2 more row")
    check(single ~= nil and absent ~= nil, "fixture rows are missing")
    if multiple and single and absent then
        local multiText, singleText = plain(multiple.title), plain(single.title)
        check(type(multiple.title) == "userdata", "top row is not styled text")
        check(multiText:find("project/CLAUDE.md", 1, true) ~= nil
            and not multiText:find(";", 1, true), "multi-file row is not one shortened path")
        local function offset(text, needle)
            local start = text:find(needle, 1, true)
            return start and utf8.len(text:sub(1, start - 1))
        end
        check(offset(multiText, "-320") == offset(singleText, "-640"), "byte columns are misaligned")
        check(offset(multiText, "-10000") == nil, "large price did not use k formatting")
        check(offset(multiText, "-10.0k tok/wk") == offset(singleText, "-10.0k tok/wk"),
            "price columns are misaligned")
        local header = plain(multiple.menu[1].title)
        check(header:find("Named chat (1234abcd)", 1, true) ~= nil
            and not header:find("harness", 1, true), "resolved chat header exposes the sid or omits the name")
        check(plain(single.menu[1].title):find("harness", 1, true) ~= nil,
            "unresolved chat header omits the sid")
        local detail = plain(multiple.menu[2].title)
        check(detail:find("-10.0k tok/wk", 1, true) ~= nil, "negative delta has no negative price")
        check(detail:find("#1", 1, true) ~= nil, "highest weekly reads entry is not rank #1")
        check(detail:find("always", 1, true) ~= nil, "indexed file mode is missing")
        check(not plain(absent.title):find("tok/wk", 1, true), "unindexed path has a top-row price")
        local absentDetail = plain(absent.menu[2].title)
        check(not absentDetail:find("tok/wk", 1, true) and not absentDetail:find("#", 1, true),
            "unindexed path has a price or rank")
        local zeroRow = findRow(menus, "zero/CLAUDE.md")
        check(zeroRow ~= nil, "zero-delta row is missing")
        if zeroRow then
            local zeroTop, zeroDetail = plain(zeroRow.title), plain(zeroRow.menu[2].title)
            check((zeroTop:match("zero/CLAUDE%.md%s+(%S+)%s*$")) == "reverted",
                "a reverted zero delta does not show the verb in the top row: " .. zeroTop)
            check(zeroDetail:find("  0", 1, true) ~= nil and not zeroDetail:find("+0", 1, true),
                "zero delta is not rendered as 0 in the file row")
            check(not zeroTop:find("tok/wk", 1, true) and not zeroDetail:find("tok/wk", 1, true),
                "zero delta has a price")
        end
        check(findRow(multiple.menu, "sent:") == nil, "pending row still shows sent status")
        check(findRow(multiple.menu, "Copy summary") == nil, "submenu still offers Copy summary")
        local copied = {}
        M.setPasteboard(function(text) copied[#copied + 1] = text end)
        local action = findRow(multiple.menu, "Copy command to open this chat")
        check(action ~= nil, "chat copy action is missing")
        if action then
            M.setOpenCommand(function(sid, done)
                check(sid == "harness", "chat runner received the wrong sid")
                done(0, "claudeb profile fixture --resume harness\naccount=fixture source=pick\n", "")
            end)
            action.fn()
            check(copied[1] == "claudeb profile fixture --resume harness", "copy action did not copy only line one")
            check(alerts[#alerts] == "copied", "pick copy did not report copied")
            M.setOpenCommand(function(_, done)
                done(0, "fallback command\naccount=fixture source=fallback\n", "")
            end)
            action.fn()
            check(alerts[#alerts] == "copied · account fixture = last launched, pick unreachable",
                "fallback alert does not name the last-launched account")
            M.setOpenCommand(function(_, done) done(1, "do not copy", "fixture error\nmore detail") end)
            action.fn()
            check(#copied == 2, "failed command wrote to the pasteboard")
            check(alerts[#alerts] == "no command: fixture error", "command error did not use first stderr line")
        end
    end
    appendEvent("badbytes", now, "unused", { indexed }, { 1, 2 })
    local bad = M.menuItems()[1]
    check(not plain(bad.title):find("tok/wk", 1, true), "mismatched bytes produced a price")
    check(not plain(bad.menu[2].title):find("tok/wk", 1, true), "mismatched bytes produced a file price")

    for _, item in ipairs(menus) do
        if type(item.menu) == "table" then
            check(findRow(item.menu, "alert shown") == nil and findRow(item.menu, "recorded ") == nil,
                "a submenu still carries the receipt line")
        end
    end
    if row then
        check(findRow(row.menu, "alert shown") == nil and findRow(row.menu, "recorded ") == nil,
            "a delivered submenu still carries the receipt line")
    end
    if multiple and single then
        check(plain(multiple.menu[1].title) == "Named chat (1234abcd)",
            "resolved chat header is not exactly the chat name: " .. plain(multiple.menu[1].title))
        check(plain(single.menu[1].title) == "unnamed chat (harness)",
            "unresolved chat header is not the unnamed label: " .. plain(single.menu[1].title))
    end

    appendEvent("resolvednamed", now, "CHANGED /tmp/resolver/named.md (+1 bytes)",
        { "/tmp/resolver/named.md" }, { 1 }, nil, namedSid)
    appendEvent("resolvedsilent", now, "CHANGED /tmp/resolver/silent.md (+1 bytes)",
        { "/tmp/resolver/silent.md" }, { 1 }, nil, silentSid)
    appendEvent("resolvedchat", now, "CHANGED /tmp/resolver/chat.md (+1 bytes)",
        { "/tmp/resolver/chat.md" }, { 1 }, "Recorded chat (cccc3333)", chatSid)
    M.pump()
    M.pump()
    local resolvedMenu = M.menuItems()
    local namedRow, silentRow, chatRow = findRow(resolvedMenu, "resolver/named.md"),
        findRow(resolvedMenu, "resolver/silent.md"), findRow(resolvedMenu, "resolver/chat.md")
    check(namedRow ~= nil and silentRow ~= nil and chatRow ~= nil, "resolver rows are missing")
    if namedRow and silentRow and chatRow then
        check(plain(namedRow.menu[1].title) == resolverLine,
            "resolver line is not the header: " .. plain(namedRow.menu[1].title))
        check(plain(silentRow.menu[1].title) == "unnamed chat (bbbb2222)",
            "unanswered sid header is not the unnamed label: " .. plain(silentRow.menu[1].title))
        check(plain(chatRow.menu[1].title) == "Recorded chat (cccc3333)", "recorded chat header was replaced")
    end
    check(askedSids[namedSid] == 1 and askedSids[silentSid] == 1, "unnamed sids were not asked exactly once")
    check(askedSids[chatSid] == nil, "an event with a recorded chat reached the resolver")
    for sid, count in pairs(askedSids) do
        check(count == 1, "the resolver was asked " .. count .. " times for " .. sid)
    end
    local namesOk, names = pcall(hs.json.decode, readFile(fixture .. "/chat-names.json") or "")
    check(namesOk and type(names) == "table" and type(names[namedSid]) == "table"
        and names[namedSid].name == resolverLine, "chat-names.json does not hold the answered sid")

    appendEvent("legacychanged", now, "CHANGED /tmp/legacy/changed.md (-42 bytes)", { "/tmp/legacy/changed.md" })
    appendEvent("legacyreverted", now, "REVERTED /tmp/legacy/reverted.md (+9 bytes)", { "/tmp/legacy/reverted.md" })
    appendEvent("legacyadded", now, "ADDED /tmp/legacy/added.md", { "/tmp/legacy/added.md" })
    local legacy = M.menuItems()
    local changedRow, revertedRow, addedRow = findRow(legacy, "legacy/changed.md"),
        findRow(legacy, "legacy/reverted.md"), findRow(legacy, "legacy/added.md")
    check(changedRow ~= nil and revertedRow ~= nil and addedRow ~= nil, "legacy rows are missing")
    if changedRow and revertedRow and addedRow then
        local function after(text, needle)
            local _, finish = text:find(needle, 1, true)
            return finish and text:sub(finish + 1) or ""
        end
        check(after(plain(changedRow.title), "changed.md"):find("-42", 1, true) ~= nil,
            "legacy CHANGED summary delta is missing from the top row")
        check(after(plain(changedRow.menu[2].title), "changed.md"):find("-42", 1, true) ~= nil,
            "legacy CHANGED summary delta is missing from the file line")
        local revertedTop = after(plain(revertedRow.title), "reverted.md")
        check(revertedTop:match("^%s*reverted%s*$") ~= nil,
            "legacy REVERTED top row does not show the verb: " .. revertedTop)
        check(after(plain(revertedRow.menu[2].title), "reverted.md"):match("^%s*reverted  0%s*$") ~= nil,
            "legacy REVERTED file line is not reverted  0")
        check(not after(plain(addedRow.title), "added.md"):find("%d"), "legacy ADDED row shows a delta")
        check(not after(plain(addedRow.menu[2].title), "added.md"):find("%d"), "legacy ADDED file line shows a delta")
        check(type(addedRow.title) == "userdata" and after(addedRow.title:getString(), "added.md"):find("added", 1, true),
            "legacy ADDED top row does not show the verb")
        check(after(plain(addedRow.menu[2].title), "added.md"):find("added", 1, true) ~= nil,
            "legacy ADDED file line does not show the verb")
    end

    local linkDir = fixture .. "/linked"
    local target, link = linkDir .. "/target.md", linkDir .. "/CLAUDE.md"
    local linkRates = fixture .. "/linked-rates.json"
    hs.fs.mkdir(linkDir)
    local targetHandle = assert(io.open(target, "w"))
    targetHandle:write("linked\n")
    targetHandle:close()
    check(hs.fs.link(target, link, true), "the fixture symlink was not created")
    local resolved = hs.fs.pathToAbsolute(target)
    check(type(resolved) == "string" and resolved ~= link, "the fixture target does not resolve")
    local linkHandle = assert(io.open(linkRates, "w"))
    linkHandle:write(hs.json.encode({ paths = { entries = {
        [resolved or target] = { mode = "agent_brief", weekly = { loads = 10, reads = 10 } },
    } } }))
    linkHandle:close()
    M.setRatesPath(linkRates)
    appendEvent("symlinked", now, "unused", { link }, { 32 })
    local linkedRow = findRow(M.menuItems(), "linked/CLAUDE.md")
    check(linkedRow ~= nil, "symlinked row is missing")
    if linkedRow then
        check(plain(linkedRow.title):find("tok/wk", 1, true) ~= nil, "symlinked path has no top-row price")
        local linkedDetail = plain(linkedRow.menu[2].title)
        check(linkedDetail:find("tok/wk", 1, true) ~= nil, "symlinked path has no file price")
        check(linkedDetail:find("#%d") ~= nil, "symlinked path has no rank")
        check(linkedDetail:find("brief", 1, true) ~= nil, "symlinked path has no mode")
    end
    os.remove(link)
    os.remove(target)
    os.remove(linkRates)
    hs.fs.rmdir(linkDir)

    local blankDir = fixture .. "-blank-render"
    hs.fs.mkdir(blankDir)
    local blankHandle = assert(io.open(blankDir .. "/events.jsonl", "w"))
    for i, file in ipairs({ "/tmp/blank/one.md", "/tmp/blank/two.md" }) do
        blankHandle:write(hs.json.encode({
            id = "blank" .. i, at = now, sid = "harness", summary = "unused", files = { file },
        }) .. "\n")
    end
    blankHandle:close()
    M.setStateDir(blankDir)
    local blank = M.menuItems()
    M.setStateDir(fixture)
    os.remove(blankDir .. "/events.jsonl")
    hs.fs.rmdir(blankDir)
    check(#blank >= 2 and findRow(blank, "blank/one.md") ~= nil, "blank render rows are missing")
    for _, item in ipairs(blank) do
        if plain(item.title):find("blank/", 1, true) then
            check(type(item.title) == "userdata" and item.title:getString():match("%s+$") == nil,
                "a render without byte data left trailing spaces: [" .. plain(item.title) .. "]")
        end
    end

    local created = 0
    local savedNew = hs.pathwatcher.new
    hs.pathwatcher.new = function(dir, cb)
        created = created + 1
        if type(savedNew) == "function" then
            local w = savedNew(dir, cb)
            if w then return w end
        end
        return { start = function() end, stop = function() end }
    end
    local missing = fixture .. "-absent-state"
    M.stop()
    M.setStateDir(missing)
    created = 0
    M.start()
    check(created == 0, "a watcher was created for a missing stateDir")
    os.execute('mkdir -p "' .. missing .. '"')
    M.pump()
    check(created >= 1, "pump did not create a watcher once stateDir appeared")
    hs.pathwatcher.new = savedNew
    M.stop()
    M.setStateDir(fixture)
    os.execute('rmdir "' .. missing .. '"')
end)

restore()

if not ok then return "THREW: " .. tostring(err) end
check(M.stateDir() == savedDir, "the harness left the module pointed at the fixture")
if #failures > 0 then return "FAIL: " .. table.concat(failures, " | ") end
return "PASS: instruction-watch menu contract"
