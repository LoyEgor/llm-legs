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
    version = 1, generated_at = "2026-09-25T13:54:45+03:00", data_through = "2026-09-25T13:53:01+03:00",
    stale_after_hours = 26, columns = { "7 days", "prev 7", "Δ" },
    rows = {
        { key = "spend", label = "Claude spend", cells = { "229M", "290M", "-21%" }, tone = "",
          extra = "251 ctx", note = "Limit tokens.", weeks = { { label = "Sep 22–28 (4d)", cell = "120M" } },
          sections = {} },
        { key = "skills", label = "  skill listing", cells = { "7.9k", "4.9k", "+62%" }, tone = "worse",
          extra = "", note = "Per context.", weeks = {},
          sections = { { title = "Top files", columns = { "7 days", "prev 7", "Δ" },
                         rows = { { label = "SKILL.md (3×)", cells = { "41k", "14k", "×2.9" }, tone = "worse",
                                    copy = "/abs/SKILL.md" } } } } },
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

local rows = {}
for _, item in ipairs(items) do
    local line = text(item.title)
    if line:find("spend", 1, true) or line:find("skill listing", 1, true) or line:find("prev 7", 1, true) then
        rows[#rows + 1] = { item = item, line = line }
    end
end
check(#rows == 3, "expected the header and two rows, got " .. #rows)
local function deltaEnd(line, cell)
    local stop = select(2, line:find(cell, 1, true))
    return stop and utf8.len(line:sub(1, stop)) or -1
end
check(deltaEnd(rows[2].line, "-21%") == deltaEnd(rows[3].line, "+62%")
    and deltaEnd(rows[1].line, "Δ") == deltaEnd(rows[2].line, "-21%"),
    "the Δ column is not aligned:\n" .. rows[1].line .. "\n" .. rows[2].line .. "\n" .. rows[3].line)

local red = false
for _, run in ipairs(rows[3].item.title:asTable()) do
    if type(run) == "table" and run.attributes and run.attributes.color then
        local piece = rows[3].line:sub(run.starts, run.ends)
        if piece:find("+62%", 1, true) and (run.attributes.color.red or 0) > 0.8 then red = true end
    end
end
check(red, "a worse Δ is not red")

local drill = rows[3].item.menu
local leaf = nil
for _, item in ipairs(drill) do
    if text(item.title):find("SKILL.md", 1, true) then leaf = item end
end
check(leaf and leaf.fn, "the copyable leaf has no action")
if leaf and leaf.fn then leaf.fn() end
check(copied == "/abs/SKILL.md", "the leaf copied " .. tostring(copied))
check(text(drill[#drill].title) == "Calendar weeks" and drill[#drill].menu, "no calendar weeks submenu")

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
