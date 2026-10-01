local root = debug.getinfo(1, "S").source:match("^@(.+)/tests/[^/]+$")
assert(root, "harness path is unavailable")
local M = assert(loadfile(root .. "/hammerspoon/token-tracking.lua"))()

local failures = {}
local function check(ok, message)
    if not ok then failures[#failures + 1] = message end
end
local function text(title) return type(title) == "string" and title or title:getString() end

local dir = os.tmpname()
os.remove(dir)
assert(hs.fs.mkdir(dir))
local path = dir .. "/tracking.json"
local function write(body)
    local handle = assert(io.open(path, "w"))
    handle:write(body)
    handle:close()
end

local fixture = {
    version = 2, generated_at = "2026-09-25T13:54:45+03:00", data_through = "2026-09-25T13:53:01+03:00",
    stale_after_hours = 26, columns = { "7 days", "prev 7", "Δ", "share" }, unit_label = "limit tokens",
    groups = { vendors = "Other vendors — each its own pool" },
    rows = {
        { key = "spend", label = "Claude spend", group = "claude", cells = { "229.0M", "291.0M", "-21%", "100.0%" },
          tone = "better", note = "Limit tokens.",
          weeks = { { label = "Sep 22–28 (4d)", short = "Sep 22 (4d)", cell = "120.0M" },
                    { label = "Sep 15–21", short = "Sep 15", cell = "301.0M" } },
          weeks_unit = "limit tokens",
          sections = {
              { title = "By zone", columns = { "7 days", "prev 7", "Δ" },
                rows = { { label = "review-bench", cells = { "172.0M", "257.0M", "-33%" }, tone = "better" } } },
              { title = "Top projects", columns = { "7 days", "prev 7", "Δ" },
                rows = { { label = "arbostar-frs-frontend-long-name", cells = { "36.0M", "15.0M", "+139%" },
                           tone = "worse" } } },
          } },
        { key = "startup", label = "Startup", group = "claude", cells = { "4.8M", "3.5M", "+37%", "2.1%" },
          tone = "worse", note = "Per context.", weeks = {}, weeks_unit = "limit tokens",
          sections = {
              { title = "Per context (avg)", columns = { "7 days", "prev 7", "Δ" },
                rows = { { label = "skill listing", cells = { "7.9k", "4.9k", "+62%" }, tone = "worse",
                           child = { key = "skills", label = "Skill listing", weeks_unit = "per context",
                                     weeks = { { label = "Sep 22–28 (4d)", cell = "7.9k" } },
                                     sections = { { title = "Local skills and commands",
                                                    columns = { "7 days", "prev 7", "Δ" },
                                                    rows = { { label = "dataviz", cells = { "569", "585", "-3%" },
                                                               tone = "" } } } } } } } },
              { title = "Top files (click copies)", columns = { "7 days", "prev 7", "Δ" },
                rows = { { label = "SKILL.md", cells = { "41.0k", "14.0k", "+193%" }, tone = "worse",
                           copy = "/abs/SKILL.md" } } },
          } },
        { key = "vendor:codex", label = "Codex", group = "vendors", cells = { "28.0M", "54.0M", "-49%" },
          tone = "better", note = "Own pool.", weeks_unit = "limit tokens",
          weeks = { { label = "Sep 22–28 (4d)", short = "Sep 22 (4d)", cell = "9.0M" },
                    { label = "Sep 15–21", short = "Sep 15", cell = "44.0M" } }, sections = {} },
        { key = "counts", label = "Counts", group = "counts", cells = {}, tone = "", note = "Counts.",
          weeks = {}, sections = { { title = "Events", columns = { "7 days", "prev 7", "Δ" },
                                     rows = { { label = "hook blocks", cells = { "2,567", "1,571", "+63%" },
                                                tone = "" } } } } },
    },
}
write(hs.json.encode(fixture))
M.setPath(path)
M.setSettings({ get = function() end, set = function() end })
local copied, alerts = nil, {}
M.setPasteboard(function(value) copied = value end)
M.setAlert(function(value) alerts[#alerts + 1] = value end)

local logItem = { title = "Instruction file changes", menu = { { title = "log row" } } }
local items = M.menuItems(logItem)
check(text(items[1].title):find("^7 days to 13:53 vs the 7 before") ~= nil
    or text(items[1].title):find("^7 days to Sep 25 13:53") ~= nil,
    "status line: " .. text(items[1].title))

local function find(list, needle)
    for index, item in ipairs(list or {}) do
        if item.title ~= "-" and text(item.title):find(needle, 1, true) then return item, index end
    end
end
local function cellEnd(item, cell)
    local line = text(item.title)
    local stop = select(2, line:find(cell, 1, true))
    return stop and utf8.len(line:sub(1, stop)) or -1
end

local header = find(items, "limit tokens")
local spend, startup = find(items, "Claude spend"), find(items, "Startup")
local codex, codexAt = find(items, "Codex")
check(header and text(header.title):find("share", 1, true), "no unit header with a share column")
check(header and spend and startup and codex
    and cellEnd(header, "Δ") == cellEnd(spend, "-21%") and cellEnd(spend, "-21%") == cellEnd(startup, "+37%")
    and cellEnd(startup, "+37%") == cellEnd(codex, "-49%"),
    "the top-level Δ column is not aligned")

local red, shareRed = false, false
for _, run in ipairs(startup.title:asTable()) do
    if type(run) == "table" and run.attributes and run.attributes.color then
        local piece = text(startup.title):sub(run.starts, run.ends)
        local isRed = (run.attributes.color.red or 0) > 0.8
        if piece:find("+37%", 1, true) and isRed then red = true end
        if piece:find("2.1%", 1, true) and isRed then shareRed = true end
    end
end
check(red, "a worse Δ is not red")
check(not shareRed, "the share column took the Δ tone")

check(codexAt and items[codexAt - 1].title ~= "-" and text(items[codexAt - 1].title) == "Other vendors — each its own pool"
    and items[codexAt - 2].title == "-", "the vendor group has no separator and caption")

local drill = spend.menu
check(text(drill[1].title):find("^By zone") ~= nil, "the drill does not open on its first section: " .. text(drill[1].title))
local zoneHead, topHead = find(drill, "By zone"), find(drill, "Top projects")
check(zoneHead and topHead and cellEnd(zoneHead, "Δ") == cellEnd(topHead, "Δ")
    and cellEnd(find(drill, "review-bench"), "-33%") == cellEnd(find(drill, "arbostar"), "+139%"),
    "the sections of one drill are not aligned with each other")
check(text(drill[#drill].title) == "Calendar weeks" and drill[#drill].menu, "no calendar weeks submenu")

local listing = find(startup.menu, "skill listing")
check(listing and listing.menu and find(listing.menu, "dataviz"), "the skill listing row does not open its catalog")
local weeks = listing and listing.menu and listing.menu[#listing.menu]
check(weeks and weeks.menu and text(weeks.menu[1].title):find("per context", 1, true),
    "the child's weeks do not name their unit")
check(#startup.menu > 0 and text(startup.menu[#startup.menu].title) ~= "Calendar weeks",
    "a row with no weeks still offers Calendar weeks")

local leaf = find(startup.menu, "SKILL.md")
check(leaf and leaf.fn, "the copyable leaf has no action")
if leaf and leaf.fn then leaf.fn() end
check(copied == "/abs/SKILL.md", "the leaf copied " .. tostring(copied))
local zoneLeaf = find(drill, "review-bench")
check(zoneLeaf and zoneLeaf.disabled and not zoneLeaf.fn and not zoneLeaf.menu,
    "an informational leaf is not disabled")
local function inertRow(menu)
    for _, item in ipairs(menu or {}) do
        if item.title ~= "-" and item ~= logItem and not (item.menu or item.fn or item.disabled) then
            return text(item.title)
        end
        local nested = item ~= logItem and inertRow(item.menu)
        if nested then return nested end
    end
end
local inert = inertRow(items)
check(inert == nil, "a row that neither acts nor is disabled: " .. tostring(inert))

local byWeek = find(items, "By week")
local matrix = byWeek and byWeek.menu or {}
local weekHead, weekSpend, weekCodex = find(matrix, "Sep 22 (4d)"), find(matrix, "Claude spend"), find(matrix, "Codex")
check(weekHead and weekHead.disabled and weekSpend and weekCodex
    and cellEnd(weekHead, "Sep 15") == cellEnd(weekSpend, "301.0M") and cellEnd(weekSpend, "301.0M") == cellEnd(weekCodex, "44.0M"),
    "the By week matrix is missing or its week columns are not aligned")
check(find(matrix, "Startup") == nil, "a row without weeks is in the By week matrix")
local _, codexLine = find(matrix, "Codex")
check(codexLine and matrix[codexLine - 1].title == "-", "the By week matrix does not separate the vendor group")

local counts = find(items, "Counts")
check(counts and counts.menu and find(counts.menu, "hook blocks"), "the Counts row has no drill")

check(codex and codex.menu and #codex.menu > 0 and codex.menu[1].title ~= "-"
    and text(codex.menu[1].title) == "Calendar weeks", "a drill with weeks but no sections opens on a separator")

local _, logAt = find(items, "Instruction file changes")
local _, refreshAt = find(items, "Refresh")
check(logAt and items[logAt] == logItem and refreshAt and logAt < refreshAt and items[logAt - 1].title == "-",
    "the change-log item is not placed verbatim above Refresh")
check(refreshAt == #items and items[refreshAt - 1].title == "-" and items[refreshAt].fn,
    "Refresh is not the bottom row after a separator")
local function allMenlo(menu)
    for _, item in ipairs(menu or {}) do
        if item.title ~= "-" then
            if type(item.title) == "string" then return false end
            local font = item.title:asTable()[2].attributes.font
            if not font or not font.name:find("^Menlo") then return false end
        end
        if item.menu and not allMenlo(item.menu) then return false end
    end
    return true
end
check(allMenlo(items), "a row under Token tracking is not Menlo 13")
check(find(M.menuItems(nil), "Instruction file changes") == nil, "no change-log item still rendered one")

check(text(M.title(nil)) == "Token tracking", "fresh title: " .. text(M.title(nil)))
hs.fs.touch(path, os.time() - 30 * 3600)
local stale = M.menuItems(nil, nil)
check(text(stale[1].title):find("^stale: 7 days to ") ~= nil, "a 30h-old export is not stale: " .. text(stale[1].title))
check(text(M.title("down")) == "Token tracking: stale · watcher down", "alarm title: " .. text(M.title("down")))

local rangePath = dir .. "/tracking-range.json"
local stored, launched, answer = {}, {}, nil
local store = { get = function(key) return stored[key] end, set = function(key, value) stored[key] = value end }
local function fakeTask(launch, callback, args)
    local task = { launch = launch, callback = callback, args = args }
    function task:setEnvironment(env) self.env = env end
    function task:start() return true end
    launched[#launched + 1] = task
    return task
end
local function argLine(task) return task and (task.launch:match("[^/]+$") .. " " .. table.concat(task.args, " ")) or "none" end
local function compare(list)
    local item = find(list, "Compare: ")
    local marked = {}
    for _, choice in ipairs(item and item.menu or {}) do
        if choice.checked then marked[#marked + 1] = text(choice.title) end
    end
    return item, table.concat(marked, ",")
end
M.setPath(path, rangePath)
M.setSettings(store)
M.setTask(fakeTask)
M.setPrompt(function() return answer end)
hs.fs.touch(path, os.time() - 60)

local ranged = M.menuItems(nil)
local compareItem, marked = compare(ranged)
check(compareItem and ranged[2] == compareItem and marked == "7 days vs 7 before",
    "the Compare submenu is not under the status line with 7 days checked: " .. marked)
alerts = {}
find(compareItem.menu, "24h vs 24h before").fn()
check(#launched == 1 and argLine(launched[1]) == "nice -n 10 " .. os.getenv("HOME") .. "/.local/bin/tokenmap tracking --range 24h --write"
    and launched[1].env.HOME == os.getenv("HOME") and launched[1].env.PATH:find("/usr/bin", 1, true),
    "a fresh export did not go straight to the nice'd range run: " .. argLine(launched[1]))
check(text(M.menuItems(nil)[2].title):find("^computing 24h vs 24h before since ") ~= nil, "no computing status while the range runs")
find(compare(M.menuItems(nil)).menu, "3 days vs 3 before").fn()
check(#launched == 1 and M.rescan() == false and alerts[1] and alerts[1]:find("busy", 1, true),
    "a second job started while one ran")
check(select(2, compare(M.menuItems(nil))) == "7 days vs 7 before", "the checkmark moved before the range finished")

local rangeFixture = hs.json.decode(hs.json.encode(fixture))
rangeFixture.version = 3
rangeFixture.range = { key = "24h", title = "24h vs the 24h before", cur_label = "24h", prev_label = "prev 24h" }
rangeFixture.columns = { "24h", "prev 24h", "Δ", "share" }
local handle = assert(io.open(rangePath, "w"))
handle:write(hs.json.encode(rangeFixture))
handle:close()
launched[1].callback(0, "", "")
ranged = M.menuItems(nil)
check(text(ranged[1].title):find("^24h vs the 24h before · data to 13:53 · scanned ") ~= nil
    or text(ranged[1].title):find("^24h vs the 24h before · data to Sep 25 13:53 · scanned ") ~= nil,
    "the range status line: " .. text(ranged[1].title))
check(find(ranged, "prev 24h") and select(2, compare(ranged)) == "24h vs 24h before"
    and stored["tokenTracking.range"].key == "24h", "the finished range is not shown, checked and remembered")
check(alerts[#alerts] == "Token tracking 24h vs 24h before ready", "no success alert: " .. tostring(alerts[#alerts]))

hs.fs.touch(rangePath, os.time() - 7 * 3600)
hs.fs.touch(path, os.time() - 30 * 3600)
check(text(M.menuItems(nil)[1].title):find("· computed 7h ago$") ~= nil, "an old range snapshot does not say computed")
check(text(M.title(nil)) == "Token tracking: stale", "the title alarm does not follow tracking.json")
hs.fs.touch(path, os.time() - 40 * 60)
check(text(M.title(nil)) == "Token tracking", "a 40m-old tracking.json raised the title alarm")
launched = {}
find(compare(M.menuItems(nil)).menu, "Today vs yesterday, same hours").fn()
check(#launched == 1 and argLine(launched[1]) == "tokenmap scan --quiet", "a 40m-old export did not scan first")
launched[1].callback(0, "", "")
check(#launched == 2 and argLine(launched[2]):find("tracking --range today --write", 1, true) ~= nil,
    "the range did not follow the scan: " .. argLine(launched[2]))
launched[2].callback(0, "", "")
check(select(2, compare(M.menuItems(nil))) == "Today vs yesterday, same hours", "today is not checked")

launched, answer = {}, "  yesterday 18:00 "
find(compare(M.menuItems(nil)).menu, "Since…").fn()
launched[1].callback(1, "", "db locked\nscan: boom\n")
check(#launched == 1 and alerts[#alerts] == "Token tracking from yesterday 18:00 failed: scan: boom",
    "a failed scan still ran the range: " .. tostring(alerts[#alerts]))
launched = {}
find(compare(M.menuItems(nil)).menu, "Since…").fn()
launched[1].callback(0, "", "")
check(argLine(launched[2]):find("tracking --since yesterday 18:00 --write", 1, true) ~= nil, "Since… ran " .. argLine(launched[2]))
launched[2].callback(2, "", "tokenmap tracking: unreadable moment 'x'\n")
ranged = M.menuItems(nil)
check(select(2, compare(ranged)) == "Today vs yesterday, same hours"
    and text(ranged[2].title) == "last refresh failed: tokenmap tracking: unreadable moment 'x'",
    "a failed range moved the selection or lost its error")
launched = {}
find(compare(M.menuItems(nil)).menu, "Since…").fn()
launched[1].callback(0, "", "")
launched[2].callback(0, "", "")
check(select(2, compare(M.menuItems(nil))) == "Since yesterday 18:00", "the custom range is not checked")

local reloaded = assert(loadfile(root .. "/hammerspoon/token-tracking.lua"))()
reloaded.setPath(path, rangePath)
reloaded.setSettings(store)
check(select(2, compare(reloaded.menuItems(nil))) == "Since yesterday 18:00", "the selection did not survive a reload")

launched = {}
find(M.menuItems(nil), "Refresh").fn()
check(#launched == 1 and argLine(launched[1]) == "tokenmap scan --quiet", "Refresh did not scan first")
launched[1].callback(0, "", "")
check(#launched == 2 and argLine(launched[2]):find("tracking --since yesterday 18:00 --write", 1, true) ~= nil,
    "Refresh did not re-run the active range")
launched[2].callback(0, "", "")

launched = {}
find(compare(M.menuItems(nil)).menu, "7 days vs 7 before").fn()
local back = M.menuItems(nil)
check(#launched == 0 and select(2, compare(back)) == "7 days vs 7 before"
    and text(back[1].title):find("^7 days to ") ~= nil and stored["tokenTracking.range"].key == "7d",
    "the default did not switch straight back to tracking.json: " .. text(back[1].title))
find(M.menuItems(nil), "Refresh").fn()
check(#launched == 1 and argLine(launched[1]) == "tokenmap scan --quiet", "the default Refresh is not a bare scan")
launched[1].callback(0, "", "")
check(#launched == 1 and alerts[#alerts] == "Token tracking updated", "the default Refresh chained a range run")
os.remove(rangePath)

write('{"rows": [{"label": null, "cells": ["1"], "weeks": [{"label": "Sep 22–28", "cell": "1"}],'
    .. ' "weeks_unit": "per context", "sections": []}], "unit_label": "limit tokens"}')
local nullOk, nullItems = pcall(M.menuItems, nil)
check(nullOk and find(nullItems, "By week"), "a null row label broke the menu: " .. tostring(nullItems))

write("{not json")
check(text(M.menuItems(nil, nil)[1].title):find("unreadable", 1, true) ~= nil, "garbage is not called unreadable")
os.remove(path)
check(text(M.menuItems(nil, nil)[1].title) == "no data yet", "a missing export is not named")
hs.fs.rmdir(dir)

if #failures > 0 then return "FAIL:\n" .. table.concat(failures, "\n") end
return "PASS: token-tracking menu contract"
