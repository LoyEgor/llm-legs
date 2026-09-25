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
local copied, alerts = nil, {}
M.setPasteboard(function(value) copied = value end)
M.setAlert(function(value) alerts[#alerts + 1] = value end)

local items = M.menuItems(function() return { { title = "log row" } } end, nil)
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

local failing = M.menuItems(function() error("boom") end, "watcher: DOWN")
local sawFailure, sawAlarm = false, false
for _, item in ipairs(failing) do
    local line = text(item.title)
    if line:find("Instruction file changes · watcher DOWN", 1, true) then sawAlarm = true end
    if item.menu and item.menu[1] and text(item.menu[1].title) == "change log failed to render" then sawFailure = true end
end
check(sawFailure, "a throwing change log was not contained")
check(sawAlarm, "the watcher alarm is not on the change-log row")

check(text(M.title(nil)) == "Token tracking", "fresh title: " .. text(M.title(nil)))
hs.fs.touch(path, os.time() - 30 * 3600)
local stale = M.menuItems(nil, nil)
check(text(stale[1].title):find("^STALE") ~= nil, "a 30h-old export is not STALE: " .. text(stale[1].title))
check(text(M.title("down")) == "Token tracking · stale · watcher down", "alarm title: " .. text(M.title("down")))

write("{not json")
check(text(M.menuItems(nil, nil)[1].title):find("unreadable", 1, true) ~= nil, "garbage is not called unreadable")
os.remove(path)
check(text(M.menuItems(nil, nil)[1].title):find("no tracking.json yet", 1, true) ~= nil, "a missing export is not named")
hs.fs.rmdir(dir)

if #failures > 0 then return "FAIL:\n" .. table.concat(failures, "\n") end
return "PASS: token-tracking menu contract"
