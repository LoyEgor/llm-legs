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
    groups = { harness = "Harness price — its cost per unit of use", vendors = "Other vendors — each its own pool" },
    rows = {
        { key = "harness_index", label = "Harness index", group = "harness", cells = { "1.14", "1.00", "+14%", "4.3%" },
          tone = "worse", note = "Per unit of use.", weeks = {}, weeks_unit = "index",
          sections = { { title = "By part", columns = { "7 days", "prev 7", "Δ" },
                         rows = { { label = "hooks", cells = { "1.20", "1.00", "+20%" }, tone = "worse" } } } } },
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
local SPEND_COLUMNS = { "7 days", "prev 7", "Δ", "share", "price" }
local function level(title, rows) return { { title = title, columns = SPEND_COLUMNS, rows = rows } } end
local projects = {}
for i = 1, 15 do
    projects[i] = { label = "proj" .. i, cells = { "0.0" .. (100 - i) .. "M", "0.1M", "-9%", "1.0%", "×1.00" }, tone = "better" }
end
projects[16] = { label = "2 more", cells = { "0.2M", "0.2M", "-9%", "2.0%", "×0.96" }, tone = "", dim = true }
local spendFixture = {
    version = 3, generated_at = "2026-09-25T13:54:45+03:00", data_through = "2026-09-25T13:53:01+03:00",
    stale_after_hours = 26, unit_label = "tokens", columns = SPEND_COLUMNS,
    range = { key = "7d", title = "7 days vs the 7 before", cur_label = "7 days", prev_label = "prev 7" },
    groups = { codex = "Codex — its own units, never summed with Claude" },
    index = { key = "harness_index", label = "Harness index", group = "harness", cells = { "1.14", "1.00", "+14%", "4.3%", "" },
              tone = "worse", weeks = {}, weeks_unit = "index",
              sections = { { title = "By part", columns = { "7 days", "prev 7", "Δ" },
                             rows = { { label = "hooks", cells = { "1.20", "1.00", "+20%" }, tone = "worse" } } } } },
    rows = {
        { label = "Claude", group = "claude", cells = { "218.0M", "210.0M", "+4%", "", "×0.98" }, tone = "" },
        { label = "  Chat", group = "claude", cells = { "120.0M", "100.0M", "+18%", "55.0%", "×1.00" }, tone = "worse",
          sections = level("Chat", {
            { label = "Work", cells = { "100.0M", "80.0M", "+23%", "45.9%", "×1.00" }, tone = "worse",
              child = { sections = level("Work", projects) } },
            { label = "Unknown", cells = { "0.1M", "0.2M", "-50%", "0.1%", "×1.00" }, tone = "better" },
        }) },
        { label = "  Workers", group = "claude", cells = { "98.0M", "110.0M", "-13%", "45.0%", "×0.96" }, tone = "better",
          sections = level("Workers", {
            { label = "Work", cells = { "98.0M", "110.0M", "-13%", "45.0%", "×0.96" }, tone = "better" },
        }) },
        { label = "Codex", group = "codex", cells = { "30.0M", "10.0M", "×3", "", "" }, tone = "worse" },
        { label = "  Workers", group = "codex", cells = { "30.0M", "10.0M", "0%", "100.0%", "" }, tone = "",
          sections = level("Workers", { { label = "gpt-5", cells = { "30.0M", "10.0M", "0%", "100.0%", "" }, tone = "" } }) },
    },
    days = { columns = { "Chat", "Workers", "Reviewers", "Doctors", "Other", "System" },
             rows = { { label = "Fri Sep 25 (today)", cells = { "55.0%", "45.0%", "0.0%", "0.0%", "0.0%", "0.0%" } },
                      { label = "Thu Sep 24", cells = { "40.0%", "50.0%", "5.0%", "5.0%", "0.0%", "0.0%" } } } },
}
local function writeSpend(key, body)
    local handle = assert(io.open(dir .. "/spend.tmp", "w"))
    handle:write(hs.json.encode(body))
    handle:close()
    assert(os.rename(dir .. "/spend.tmp", dir .. "/spend-" .. key .. ".json"))
end
writeSpend("7d", spendFixture)
write(hs.json.encode(fixture))
M.setPath(path)
M.setSettings({ get = function() end, set = function() end })
local copied, alerts = nil, {}
M.setPasteboard(function(value) copied = value end)
M.setAlert(function(value) alerts[#alerts + 1] = value end)

local logItem = { title = "Instruction file changes", menu = { { title = "log row" } } }
local items = M.menuItems(logItem)
check(text(items[1].title):find("^data to [^·]*13:53$") ~= nil,
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
local function category(list) return (find(list, "By category") or {}).menu or {} end

local function isRed(item)
    for _, run in ipairs(item.title:asTable()) do
        if type(run) == "table" and run.attributes and run.attributes.color then
            return (run.attributes.color.red or 0) > 0.8 and (run.attributes.color.green or 0) < 0.5
        end
    end
    return false
end
local function colorAt(item, cell)
    local line = text(item.title)
    local start = line:find(cell, 1, true)
    if not start then return nil end
    for _, run in ipairs(item.title:asTable()) do
        if type(run) == "table" and run.starts <= start and start <= run.ends then
            return hs.inspect(run.attributes.color)
        end
    end
end

local pie = items
local indexRow, spendCompare = items[2], items[3]
check(indexRow and text(indexRow.title):find("^Harness index") and indexRow.menu and find(indexRow.menu, "hooks"),
    "the harness index row is not second, or does not open its drill")
check(spendCompare and text(spendCompare.title) == "Compare: 7 days vs 7 before" and #spendCompare.menu == 3
    and text(spendCompare.menu[1].title) == "24h vs 24h before" and spendCompare.menu[3].checked,
    "the one range selector is not third with 24h · 3d · 7d")
local pieHead, chat, workers = find(pie, "tokens"), find(pie, "Chat"), find(pie, "Workers")
check(pieHead and pieHead.disabled and chat and chat.menu and workers and workers.menu
    and cellEnd(pieHead, "prev 7") == cellEnd(chat, "100.0M") and cellEnd(chat, "100.0M") == cellEnd(workers, "110.0M")
    and cellEnd(pieHead, "Δ") == cellEnd(chat, "+18%") and cellEnd(chat, "+18%") == cellEnd(workers, "-13%")
    and cellEnd(pieHead, "share") == cellEnd(chat, "55.0%") and cellEnd(pieHead, "price") == cellEnd(chat, "×1.00")
    and cellEnd(indexRow, "+14%") == cellEnd(chat, "+18%")
    and utf8.len(text(pieHead.title)) == utf8.len(text(chat.title)),
    "the vendor-tree rows and the harness index row are missing or not aligned as one table")
check(find(pie, "plain") == nil, "a plain column is still shown")
local claudeRow, codexRow, codexCaption = find(pie, "Claude "), find(pie, "×3 "), find(pie, "Codex — its own units")
check(claudeRow and claudeRow.disabled and not claudeRow.menu and cellEnd(claudeRow, "×0.98") == cellEnd(chat, "×1.00")
    and codexRow and codexRow.disabled
    and codexCaption and codexCaption.disabled and select(2, find(pie, "Codex — ")) < select(2, find(pie, "×3 "))
    and cellEnd(codexRow, "×3") == cellEnd(chat, "+18%"),
    "the Claude total row or the Codex tree is not its own group")
check(colorAt(claudeRow, "×0.98") == colorAt(chat, "×1.00") and colorAt(chat, "×1.00") == colorAt(chat, "55.0%"),
    "the price column took a tone")
local byDay, byDayAt = find(pie, "By day")
local _, categoryAt = find(pie, "By category")
local dayRows = byDay and byDay.menu or {}
check(byDay and #dayRows == 3 and dayRows[1].disabled and text(dayRows[1].title):find("Chat", 1, true)
    and utf8.len(text(dayRows[1].title)) == utf8.len(text(dayRows[2].title))
    and cellEnd(dayRows[1], "Chat") == cellEnd(dayRows[3], "40.0%") and categoryAt and byDayAt < categoryAt,
    "the top level lacks an aligned By day view above By category")
local chatWork = chat and find(chat.menu, "Work")
local leaves = chatWork and chatWork.menu or {}
check(chatWork and chat.menu[1].disabled and find(chat.menu, "Unknown").disabled, "a level-2 row does not open its leaves")
local folded = find(leaves, "2 more")
check(#leaves == 17 and find(leaves, "proj15") and folded and folded.disabled
    and cellEnd(folded, "2.0%") == cellEnd(find(leaves, "proj1 "), "1.0%"),
    "the leaves are not the top 15 plus an aligned more row")

local cat = category(items)
check(text(find(items, "By category").title) == "By category" and cat[1] and cat[1].disabled
    and text(cat[1].title):find("^data to [^·]*13:53$"), "By category does not open on its own status line")
local header = find(cat, "limit tokens")
local spend, startup = find(cat, "Claude spend"), find(cat, "Startup")
local codex, codexAt = find(cat, "Codex")
check(header and text(header.title):find("share", 1, true), "no unit header with a share column")
check(find(items, "Harness index") and not find(cat, "Harness index"),
    "the harness index is not on the top level only")
check(header and spend and startup and codex
    and cellEnd(header, "Δ") == cellEnd(spend, "-21%") and cellEnd(spend, "-21%") == cellEnd(startup, "+37%")
    and cellEnd(startup, "+37%") == cellEnd(codex, "-49%"),
    "the By category Δ column is not aligned")

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
check(colorAt(chat, "+18%") == colorAt(startup, "+37%") and colorAt(workers, "-13%") == colorAt(spend, "-21%")
    and colorAt(chat, "55.0%") == colorAt(startup, "2.1%") and colorAt(chat, "+18%") ~= colorAt(workers, "-13%"),
    "the vendor trees' cells are not coloured as By category's")

check(codexAt and cat[codexAt - 1].title ~= "-" and text(cat[codexAt - 1].title) == "Other vendors — each its own pool"
    and cat[codexAt - 2].title == "-", "the vendor group has no separator and caption")

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

local byWeek = find(cat, "By week")
local matrix = byWeek and byWeek.menu or {}
local weekHead, weekSpend, weekCodex = find(matrix, "Sep 22 (4d)"), find(matrix, "Claude spend"), find(matrix, "Codex")
check(weekHead and weekHead.disabled and weekSpend and weekCodex
    and cellEnd(weekHead, "Sep 15") == cellEnd(weekSpend, "301.0M") and cellEnd(weekSpend, "301.0M") == cellEnd(weekCodex, "44.0M"),
    "the By week matrix is missing or its week columns are not aligned")
check(find(matrix, "Startup") == nil, "a row without weeks is in the By week matrix")
local _, codexLine = find(matrix, "Codex")
check(codexLine and matrix[codexLine - 1].title == "-", "the By week matrix does not separate the vendor group")

local counts = find(cat, "Counts")
check(counts and counts.menu and find(counts.menu, "hook blocks"), "the Counts row has no drill")

check(codex and codex.menu and #codex.menu > 0 and codex.menu[1].title ~= "-"
    and text(codex.menu[1].title) == "Calendar weeks", "a drill with weeks but no sections opens on a separator")
local catCompare = cat[2]
local catChoices = {}
for _, choice in ipairs(catCompare and catCompare.menu or {}) do catChoices[#catChoices + 1] = text(choice.title) end
check(catCompare and text(catCompare.title) == "Compare: 7 days vs 7 before"
    and table.concat(catChoices, "|") == "24h vs 24h before|3 days vs 3 before|7 days vs 7 before|Today vs yesterday, same hours|Since…"
    and catCompare.menu[3].checked, "By category lacks its own range under its status line: " .. table.concat(catChoices, "|"))
check(text(cat[#cat].title) == "Refresh" and cat[#cat].fn and cat[#cat - 1].title == "-",
    "By category lacks its own Refresh at its bottom")

local _, logAt = find(items, "Instruction file changes")
local _, refreshAt = find(items, "Refresh")
check(logAt and items[logAt] == logItem and refreshAt and logAt < refreshAt and items[logAt - 1].title == "-"
    and categoryAt < logAt, "the change-log item is not placed verbatim between By category and Refresh")
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
local stale = category(M.menuItems(nil, nil))
check(text(stale[1].title):find("^data to ") ~= nil and isRed(stale[1]), "a 30h-old export is not stale: " .. text(stale[1].title))
check(text(M.title("down")) == "Token tracking: stale · watcher down", "alarm title: " .. text(M.title("down")))

local rangePath = dir .. "/tracking-range-24h.json"
local stored, launched, spendRuns, answer, spendHook = {}, {}, {}, nil, false
local store = { get = function(key) return stored[key] end, set = function(key, value) stored[key] = value end }
local function fakeTask(launch, callback, args)
    local task = { launch = launch, callback = callback, args = args }
    function task:setEnvironment(env) self.env = env end
    function task:start() return true end
    function task:terminate() self.terminated = true end
    if args[1] == "spend" or args[3] == "--no-tracking" and spendHook then spendRuns[#spendRuns + 1] = task
    else launched[#launched + 1] = task end
    return task
end
local function argLine(task) return task and (task.launch:match("[^/]+$") .. " " .. table.concat(task.args, " ")) or "none" end
local function selector(list) return find(list, "Compare: ") end
local function catCompare(list) return find(category(list), "Compare: ") end
local function checked(menu)
    local out = {}
    for _, choice in ipairs(menu or {}) do
        if choice.checked then out[#out + 1] = text(choice.title) end
    end
    return table.concat(out, ",")
end
local function marked(list) return checked(catCompare(list).menu) end
local function pickTop(list, label) return find(selector(list).menu, label) end
local function pick(list, label) return find(catCompare(list).menu, label) end
local function catTitle(list) return text(catCompare(list).title) end
local function catStatus(list) return category(list)[1] end
local function catRefresh(list) return find(category(list), "Refresh") or find(category(list), "refreshing…") end
M.setPath(path)
M.setSettings(store)
M.setTask(fakeTask)
M.setPrompt(function() return answer end)
hs.fs.touch(path, os.time() - 60)

local ranged = M.menuItems(nil)
check(ranged[3] == selector(ranged) and text(ranged[2].title):find("^Harness index") and checked(selector(ranged).menu) == "7 days vs 7 before"
    and marked(ranged) == "7 days vs 7 before", "the two ranges do not both start at 7 days")
alerts = {}
pickTop(ranged, "24h vs 24h before").fn()
check(#launched == 0 and #spendRuns == 1 and argLine(spendRuns[1]) == "tokenmap spend --range 24h --write"
    and spendRuns[1].env.HOME == os.getenv("HOME") and marked(M.menuItems(nil)) == "7 days vs 7 before"
    and stored["tokenTracking.spendRange"].key == "24h" and #alerts == 0,
    "a Spend range switch started a category job or moved By category: " .. argLine(launched[1]))
local spendComputing = M.menuItems(nil)
check(text(spendComputing[1].title) == "no data yet · refreshing…" and text(selector(spendComputing).title) == "Compare: 24h vs 24h before — computing…"
    and #launched == 0, "the top level does not show its own spend run, or a menu open started a category job")
local daySpend = hs.json.decode(hs.json.encode(spendFixture))
daySpend.data_through, daySpend.columns = "2026-09-25T12:41:00+03:00", { "24h", "prev 24h", "Δ", "share", "price" }
daySpend.range = { key = "24h", title = "24h vs the 24h before", cur_label = "24h", prev_label = "prev 24h" }
daySpend.index.cells = { "1.31", "1.00", "+31%", "4.3%", "" }
writeSpend("24h", daySpend)
spendRuns[1].callback(0, "", "")
ranged = M.menuItems(nil)
check(text(ranged[1].title):find("^data to [^·]*12:41$") and find(ranged, "prev 24h") and text(ranged[2].title):find("+31%", 1, true)
    and #alerts == 0 and #launched == 0, "the top level does not read its range's spend file and harness index: " .. text(ranged[1].title))
pickTop(ranged, "7 days vs 7 before").fn()
check(#launched == 0 and #spendRuns == 2, "switching Spend back started a category job")
spendRuns[2].callback(0, "", "")

pick(M.menuItems(nil), "24h vs 24h before").fn()
check(#launched == 1 and argLine(launched[1]) == "tokenmap tracking --range 24h --write"
    and launched[1].env.PATH:find("/usr/bin", 1, true) and #spendRuns == 2
    and checked(selector(M.menuItems(nil)).menu) == "7 days vs 7 before",
    "a By category range change did not start only its own run: " .. argLine(launched[1]))
check(text(catStatus(M.menuItems(nil)).title):find("^data to .* · refreshing…$") ~= nil
    and text(M.menuItems(nil)[1].title):find("refreshing", 1, true) == nil, "the refreshing state is not By category's own")
pick(M.menuItems(nil), "3 days vs 3 before").fn()
check(#launched == 2 and launched[1].terminated and argLine(launched[2]) == "tokenmap tracking --range 3d --write"
    and M.rescan() == false and #alerts == 0, "a newer choice did not supersede the running range: " .. argLine(launched[2]))
pick(M.menuItems(nil), "24h vs 24h before").fn()
check(#launched == 3 and launched[2].terminated and not launched[3].terminated
    and argLine(launched[3]) == "tokenmap tracking --range 24h --write", "two quick choices left more than the last running")
launched[1].callback(15, "", "terminated")
launched[2].callback(15, "", "terminated")
local computing = M.menuItems(nil)
check(marked(computing) == "7 days vs 7 before" and text(catStatus(computing).title):find("^data to ") ~= nil
    and find(category(computing), "prev 24h") == nil and catTitle(computing) == "Compare: 24h vs 24h before — computing…"
    and find(catCompare(computing).menu, "24h vs 24h before — computing…")
    and text(find(computing, "By category").title) == "By category — computing…"
    and stored["tokenTracking.range"] == nil and #alerts == 0,
    "the asked range read as current while it computes, or a cut run alerted: " .. catTitle(computing))

local rangeFixture = hs.json.decode(hs.json.encode(fixture))
rangeFixture.version = 3
rangeFixture.range = { key = "24h", title = "24h vs the 24h before", cur_label = "24h", prev_label = "prev 24h" }
rangeFixture.columns = { "24h", "prev 24h", "Δ", "share" }
local handle = assert(io.open(rangePath, "w"))
handle:write(hs.json.encode(rangeFixture))
handle:close()
launched[3].callback(0, "", "")
ranged = M.menuItems(nil)
check(text(catStatus(ranged).title):find("^data to [^·]*13:53$") ~= nil, "the range status line: " .. text(catStatus(ranged).title))
check(find(category(ranged), "prev 24h") and marked(ranged) == "24h vs 24h before"
    and stored["tokenTracking.range"].key == "24h", "the finished range is not shown, checked and remembered")
check(alerts[#alerts] == "Token tracking 24h vs 24h before ready", "no success alert: " .. tostring(alerts[#alerts]))

hs.fs.touch(rangePath, os.time() - 7 * 3600)
hs.fs.touch(path, os.time() - 30 * 3600)
local snapshot = catStatus(M.menuItems(nil))
check(text(snapshot.title):find("^data to [^·]*13:53$") ~= nil and not isRed(snapshot), "an old range snapshot reads as stale")
check(text(M.title(nil)) == "Token tracking: stale", "the title alarm does not follow tracking.json")
hs.fs.touch(path, os.time() - 40 * 60)
check(text(M.title(nil)) == "Token tracking", "a 40m-old tracking.json raised the title alarm")
launched = {}
pick(M.menuItems(nil), "Today vs yesterday, same hours").fn()
check(#launched == 1 and argLine(launched[1]) == "tokenmap scan --quiet --no-tracking", "a 40m-old export did not scan first")
local function asking(list)
    return marked(list) == "24h vs 24h before" and text(catStatus(list).title):find("^data to .* · refreshing…$") ~= nil
        and find(category(list), "prev 24h") ~= nil and catTitle(list) == "Compare: Today vs yesterday, same hours — computing…"
end
local scanning = M.menuItems(nil)
check(asking(scanning), "the scan phase shows the asked range or its old view as current: " .. catTitle(scanning))
check(text(find(scanning, "refreshing…").title) == "refreshing…" and not catRefresh(scanning).fn,
    "a category scan left a Refresh to start a second scan")
launched[1].callback(0, "", "")
check(#launched == 2 and argLine(launched[2]) == "tokenmap tracking --range today --write",
    "the range did not follow the scan: " .. argLine(launched[2]))
check(asking(M.menuItems(nil)), "the compute phase shows the asked range as current")
local todayFixture = hs.json.decode(hs.json.encode(rangeFixture))
todayFixture.range.key, todayFixture.range.title = "today", "Today vs yesterday, same hours"
handle = assert(io.open(dir .. "/tracking-range-today.json", "w"))
handle:write(hs.json.encode(todayFixture))
handle:close()
local alertsBefore = #alerts
launched[2].callback(0, "", "")
local ready = M.menuItems(nil)
check(#alerts == alertsBefore + 1 and text(catStatus(ready).title):find("^data to ") ~= nil
    and catTitle(ready) == "Compare: Today vs yesterday, same hours", "the ready alert and the menu disagree: " .. catTitle(ready))
check(alerts[#alerts] == "Token tracking Today vs yesterday, same hours ready"
    and #launched == 3 and argLine(launched[3]) == "nice -n 19 " .. os.getenv("HOME") .. "/.local/bin/tokenmap tracking --write",
    "the 7-day export did not follow the range at nice 19: " .. argLine(launched[3]))
local afterRange = M.menuItems(nil)
check(marked(afterRange) == "Today vs yesterday, same hours" and text(catStatus(afterRange).title):find("· refreshing…$") ~= nil,
    "today is not checked, or the 7-day export is not shown computing")

launched, answer = {}, "  yesterday 18:00 "
pick(M.menuItems(nil), "Since…").fn()
launched[1].callback(1, "", "db locked\nscan: boom\n")
check(#launched == 1 and alerts[#alerts] == "Token tracking from yesterday 18:00 failed: scan: boom",
    "a failed scan still ran the range: " .. tostring(alerts[#alerts]))
launched = {}
pick(M.menuItems(nil), "Since…").fn()
launched[1].callback(0, "", "")
check(argLine(launched[2]):find("tracking --since yesterday 18:00 --write", 1, true) ~= nil, "Since… ran " .. argLine(launched[2]))
launched[2].callback(2, "", "tokenmap tracking: unreadable moment 'x'\n")
ranged = M.menuItems(nil)
check(marked(ranged) == "Today vs yesterday, same hours"
    and text(category(ranged)[2].title) == "last refresh failed: tokenmap tracking: unreadable moment 'x'",
    "a failed range moved the selection or lost its error")
launched = {}
pick(M.menuItems(nil), "Since…").fn()
launched[1].callback(0, "", "")
launched[2].callback(0, "", "")
check(marked(M.menuItems(nil)) == "Since yesterday 18:00", "the custom range is not checked")

local reloaded = assert(loadfile(root .. "/hammerspoon/token-tracking.lua"))()
reloaded.setPath(path)
reloaded.setSettings(store)
check(marked(reloaded.menuItems(nil)) == "Since yesterday 18:00" and checked(selector(reloaded.menuItems(nil)).menu) == "7 days vs 7 before",
    "the selections did not survive a reload")

launched = {}
catRefresh(M.menuItems(nil)).fn()
check(#launched == 1 and argLine(launched[1]) == "tokenmap scan --quiet --no-tracking", "By category's Refresh did not scan first")
launched[1].callback(0, "", "")
check(#launched == 2 and argLine(launched[2]):find("tracking --since yesterday 18:00 --write", 1, true) ~= nil,
    "By category's Refresh did not re-run its range")
launched[2].callback(0, "", "")

launched = {}
pick(M.menuItems(nil), "7 days vs 7 before").fn()
local back = M.menuItems(nil)
check(#launched == 0 and marked(back) == "7 days vs 7 before"
    and text(catStatus(back).title):find("^data to ") ~= nil and find(category(back), "prev 7") and stored["tokenTracking.range"].key == "7d",
    "the default did not switch straight back to tracking.json: " .. text(catStatus(back).title))
catRefresh(M.menuItems(nil)).fn()
check(#launched == 1 and argLine(launched[1]) == "tokenmap scan --quiet", "the default category Refresh is not a bare scan")
launched[1].callback(0, "", "")
check(#launched == 1 and alerts[#alerts] == "Token tracking updated", "the default category Refresh chained a range run")
os.remove(rangePath)

local genPath = dir .. "/generation"
local generationNow
local function setGeneration(token)
    local file = assert(io.open(genPath, "w"))
    file:write(token .. "\n")
    file:close()
    generationNow, spendFixture.db_generation = token, token
    writeSpend("7d", spendFixture)
end
local current = hs.json.decode(hs.json.encode(fixture))
current.db_generation = "aaaa000000000001"
write(hs.json.encode(current))
setGeneration("aaaa000000000001")
hs.fs.touch(path, os.time() - 30 * 3600)
launched, spendRuns = {}, {}
local fresh = M.menuItems(nil)
check(#launched == 0 and #spendRuns == 0 and text(catStatus(fresh).title):find("^data to [^·]*$") ~= nil and not isRed(catStatus(fresh))
    and text(M.title(nil)) == "Token tracking", "an export a later scan confirmed is not current: " .. text(catStatus(fresh).title))
setGeneration("bbbb000000000002")
local moved = M.menuItems(nil)
check(#launched == 0 and #spendRuns == 0 and text(catStatus(moved).title):find("^data to [^·]*$") ~= nil and isRed(catStatus(moved))
    and not isRed(moved[1]), "a menu open after a new generation started a category job, or showed its export as current")
pick(moved, "7 days vs 7 before").fn()
check(#launched == 1 and argLine(launched[1]) == "tokenmap tracking --write",
    "choosing an outdated 7-day category range did not recompute it: " .. argLine(launched[1]))
launched[1].callback(0, "", "")
current.db_generation = "bbbb000000000002"
write(hs.json.encode(current))
check(not isRed(catStatus(M.menuItems(nil))) and #launched == 1, "a recomputed 7-day export is not current")
local function writeRange(key, token)
    local body = hs.json.decode(hs.json.encode(rangeFixture))
    body.db_generation, body.range.key = token or "bbbb000000000002", key
    local file = assert(io.open(dir .. "/tracking-range-" .. key .. ".json", "w"))
    file:write(hs.json.encode(body))
    file:close()
end
hs.fs.touch(genPath, os.time() - 40 * 60)
pick(M.menuItems(nil), "24h vs 24h before").fn()
launched[2].callback(0, "", "")
hs.fs.touch(genPath)
writeRange("24h")
launched[3].callback(0, "", "")
local soft = launched[4]
check(argLine(soft):find("nice -n 19", 1, true) ~= nil and catRefresh(M.menuItems(nil)).fn ~= nil,
    "the 7-day export after a range is not soft or blocks Refresh")
pick(M.menuItems(nil), "3 days vs 3 before").fn()
check(soft.terminated and argLine(launched[5]) == "tokenmap tracking --range 3d --write"
    and argLine(launched[6] or launched[5]):find("nice -n 19", 1, true) == nil,
    "a click did not cut the soft 7-day export short: " .. argLine(launched[5]))
soft.callback(15, "", "terminated")
writeRange("3d")
launched[5].callback(0, "", "")
check(argLine(launched[6]):find("nice -n 19", 1, true) ~= nil and text(catStatus(M.menuItems(nil)).title):find("· refreshing…$") ~= nil,
    "the cut 7-day export is not owed to the next run, or its kill showed as a failure")
launched[6].callback(0, "", "")
pick(M.menuItems(nil), "7 days vs 7 before").fn()

launched, alerts = {}, {}
setGeneration("cccc000000000003")
M.menuItems(nil)
check(#launched == 0, "an outdated 7-day category export was recomputed on menu open")

catRefresh(M.menuItems(nil)).fn()
check(argLine(launched[1]) == "tokenmap scan --quiet", "the default category Refresh is not a bare scan")
pick(M.menuItems(nil), "3 days vs 3 before").fn()
local queued = M.menuItems(nil)
check(#launched == 1 and not launched[1].terminated and marked(queued) == "7 days vs 7 before"
    and text(catStatus(queued).title):find("· refreshing…$") ~= nil
    and catTitle(queued) == "Compare: 3 days vs 3 before — computing…"
    and alerts[#alerts] == "Token tracking: computing 3 days vs 3 before after the scan…",
    "a click during a scan did not queue behind it: " .. marked(queued))
pick(M.menuItems(nil), "Today vs yesterday, same hours").fn()
launched[1].callback(0, "", "")
check(#launched == 2 and argLine(launched[2]) == "tokenmap tracking --range today --write",
    "the last choice did not run right after the scan: " .. argLine(launched[2]))
launched[2].callback(0, "", "")

alerts = {}
writeRange("3d", "cccc000000000003")
hs.fs.touch(dir .. "/tracking-range-3d.json", os.time() - 3)
pick(M.menuItems(nil), "3 days vs 3 before").fn()
local hit, hitRun = M.menuItems(nil), launched[#launched]
check(argLine(hitRun) == "tokenmap tracking --range 3d --write" and #alerts == 0
    and marked(hit) == "3 days vs 3 before — computing…"
    and text(catStatus(hit).title):find("^data to ") ~= nil and find(category(hit), "prev 24h"),
    "a current cached export was not shown at once: " .. marked(hit))
hitRun.callback(0, "", "")
check(alerts[1] == "Token tracking 3 days vs 3 before ready" and catTitle(M.menuItems(nil)) == "Compare: 3 days vs 3 before",
    "a current cached export did not alert as its run returned: " .. tostring(alerts[1]))
pick(M.menuItems(nil), "7 days vs 7 before").fn()
launched[#launched].callback(0, "", "")

launched, alerts, spendRuns = {}, {}, {}
spendHook = true
find(M.menuItems(nil), "Refresh").fn()
check(#spendRuns == 1 and argLine(spendRuns[1]) == "tokenmap scan --quiet --no-tracking" and #launched == 0,
    "the top Refresh is not a scan that skips the category export: " .. argLine(spendRuns[1]))
local topScanning = M.menuItems(nil)
check(find(topScanning, "refreshing…") and not catRefresh(topScanning).fn and text(topScanning[1].title):find("· refreshing…$"),
    "a Spend scan left a Refresh to start a second scan")
pickTop(topScanning, "24h vs 24h before").fn()
check(#spendRuns == 1 and not spendRuns[1].terminated and #launched == 0, "a Spend switch cut the scan or started a job")
spendRuns[1].callback(0, "", "")
check(#spendRuns == 2 and argLine(spendRuns[2]) == "tokenmap spend --range 24h --write" and #launched == 0 and #alerts == 0,
    "the scan was not followed by the chosen range's spend export: " .. argLine(spendRuns[2]))
daySpend.db_generation = generationNow
writeSpend("24h", daySpend)
spendRuns[2].callback(0, "", "")
check(not isRed(M.menuItems(nil)[1]) and #alerts == 0, "a finished spend run is not current, or it alerted")
local spendBefore = #spendRuns
pickTop(M.menuItems(nil), "7 days vs 7 before").fn()
pickTop(M.menuItems(nil), "24h vs 24h before").fn()
check(#spendRuns == spendBefore, "a spend range already computed for this database ran again")
setGeneration(generationNow:sub(1, -2) .. "f")
M.menuItems(nil)
local spendRun = spendRuns[#spendRuns]
check(argLine(spendRun) == "tokenmap spend --range 24h --write" and #spendRuns == spendBefore + 1 and #launched == 0,
    "an outdated spend export was not recomputed alone on open: " .. argLine(spendRun))
spendRun.callback(0, "", "")
check(#alerts == 0, "a quiet spend recompute alerted")
spendHook = false
pickTop(M.menuItems(nil), "7 days vs 7 before").fn()
os.remove(dir .. "/spend-24h.json")
os.remove(dir .. "/spend-7d.json")
os.remove(dir .. "/tracking-range-today.json")
os.remove(genPath)
os.remove(rangePath)
os.remove(dir .. "/tracking-range-3d.json")

write('{"rows": [{"label": null, "cells": ["1"], "weeks": [{"label": "Sep 22–28", "cell": "1"}],'
    .. ' "weeks_unit": "per context", "sections": []}], "unit_label": "limit tokens"}')
local nullOk, nullItems = pcall(M.menuItems, nil)
check(nullOk and find(category(nullItems), "By week"), "a null row label broke the menu: " .. tostring(nullItems))

write("{not json")
check(text(category(M.menuItems(nil, nil))[1].title):find("unreadable", 1, true) ~= nil, "garbage is not called unreadable")
os.remove(path)
check(text(category(M.menuItems(nil, nil))[1].title):find("^no data yet") ~= nil, "a missing export is not named")
hs.fs.rmdir(dir)

if #failures > 0 then return "FAIL:\n" .. table.concat(failures, "\n") end
return "PASS: token-tracking menu contract"
