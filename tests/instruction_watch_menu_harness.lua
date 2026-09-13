-- Runs INSIDE the real Hammerspoon (`hs -c "dofile(...)"`), which is the only place `hs.pathwatcher`,
-- `hs.json` and the menu builder exist. Everything it touches is the fixture directory the shell
-- suite prepared with the real hook, and the screen is swapped for a recorder: proving the
-- transport may not put a line on Egor's display or a receipt in his cache.
local source = debug.getinfo(1, "S").source
local root = source:match("^@(.+)/tests/[^/]+$")
assert(root, "harness path is unavailable")

local fixture = _G.INSTRUCTION_WATCH_FIXTURE
assert(type(fixture) == "string" and fixture ~= "", "no fixture state directory was passed")

package.path = package.path .. ";" .. root .. "/hammerspoon/?.lua"
-- `require` caches, and this harness runs inside a Hammerspoon that may have loaded the module
-- hours ago: without dropping the cache first, every run after the first one checks the version
-- that was on disk THEN, and an edit to the module could never fail it. The live instance is
-- stopped rather than abandoned, or its watcher and timer outlive it.
do
    local existing = package.loaded["instruction-watch"]
    if type(existing) == "table" and type(existing.stop) == "function" then
        pcall(existing.stop)
    end
    package.loaded["instruction-watch"] = nil
end
local M = require("instruction-watch")

local failures = {}
local function check(ok, message)
    if not ok then failures[#failures + 1] = message end
end

local alerts = {}
local savedDir = M.stateDir()

local function restore()
    M.setAlert(nil)
    M.setStateDir(nil)
    pcall(M.start)
end

local function readFile(path)
    local handle = io.open(path, "r")
    if not handle then return nil end
    local body = handle:read("*a")
    handle:close()
    return body
end

local function appendEvent(id, isoStamp, summary, files)
    local handle = io.open(fixture .. "/events.jsonl", "a")
    if not handle then return false end
    handle:write(hs.json.encode({
        id = id, at = isoStamp, sid = "harness", summary = summary,
        sent = "attempted", files = files or { "/tmp/" .. id .. ".md" },
        restores = {}, reverted = {},
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

local function findRow(items, needle)
    for _, item in ipairs(items or {}) do
        local title = tostring(item.title or "")
        if title:find(needle, 1, true) then return item end
    end
    return nil
end

local ok, err = pcall(function()
    M.stop()
    M.setStateDir(fixture)
    M.setAlert(function(text) alerts[#alerts + 1] = text end)

    -- 1. What the collector actually wrote. The shell suite ran the real hook against a real file
    --    change to produce this, so what is being read here is the hook's own record, not a mock.
    local body = readFile(fixture .. "/events.jsonl")
    check(body ~= nil and body ~= "", "the collector left no journal to read")
    -- The FIRST record, not the last: the burst bound below the third collapses later ones into
    -- one line, and a record that was deliberately not alerted is the wrong one to ask about here.
    local seeded = hs.json.decode(body:match("^([^\n]+)"))
    check(type(seeded) == "table" and type(seeded.id) == "string",
        "the collector's record does not decode")

    -- 2. One pump delivers it, and says so.
    local first = M.pump()
    check(first.delivered >= 1, "the pump delivered nothing: " .. describe(first))
    check(first.alerted >= 1, "the pump wrote a receipt without showing anything")
    check(#alerts >= 1, "no alert reached the recorder")
    check(tostring(alerts[1]):find("Instruction file changed", 1, true) ~= nil,
        "the alert does not name what happened: " .. tostring(alerts[1]))

    -- 3. The receipt is the proof the other end woke up — and it claims that and nothing more.
    local receipt = hs.json.decode(readFile(fixture .. "/receipts/" .. seeded.id) or "{}")
    check(receipt.alerted == true, "the receipt does not record that an alert was shown")
    check(type(receipt.at) == "string" and receipt.at ~= "", "the receipt carries no timestamp")

    -- 4. Idempotent: the watcher, the timer, the hook's poke and a menu click all reach this.
    local alertsBefore = #alerts
    local second = M.pump()
    check(second.delivered == 0, "a receipted change was delivered twice")
    check(#alerts == alertsBefore, "a receipted change was alerted twice")

    -- 5. The menu is the durable half. The row for the collector's change is there, marked as
    --    shown, and it offers the restore command to COPY — never to run.
    local items = M.menuItems()
    local row = findRow(items, "●")
    check(row ~= nil, "no delivered row in the menu")
    if row then
        check(type(row.menu) == "table", "the row has no detail submenu")
        local restoreRow = findRow(row.menu, "Copy restore command")
        check(restoreRow ~= nil, "the row offers no restore command to copy")
        check(findRow(row.menu, "Run ") == nil, "the menu offers to RUN a restore")
    end
    check(findRow(items, "Coverage") ~= nil, "the menu does not show what is covered")
    local coverage = findRow(items, "Coverage")
    if coverage then
        check(findRow(coverage.menu, "CLAUDE.md") ~= nil,
            "the coverage submenu does not list the ranked project file")
        -- The cache's first line is a format stamp, not a path somebody is watching.
        check(findRow(coverage.menu, "#") == nil,
            "the cache's version stamp was shown as a watched file")
    end

    -- 6. A Hammerspoon that was off for a day must not open with a wall of alerts: old records
    --    land in the menu unannounced, and a burst past the third collapses into one line.
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
        check(tostring(spaceRow.title):find("Users/me/My ", 1, true) == nil,
            "a path with spaces was split: " .. tostring(spaceRow.title))
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
