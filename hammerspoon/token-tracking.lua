-- Automations ▸ Token tracking: tokenmap's week-over-week spend rows.
--
-- The whole Automations menu is rebuilt on every click, so this module reads one small JSON
-- that `tokenmap scan` writes (tracking.json), decoded once per size+mtime — never a query or
-- a subprocess on the click path. Every number, label and Δ tone is decided by tokenmap
-- (tokenmap/tracking.py); this side only aligns the columns and colours the tone.

local M = {}
local HOME = os.getenv("HOME") or ""
local DEFAULT_PATH = HOME .. "/.local/share/tokenmap/tracking.json"
local PAGE = HOME .. "/.local/share/tokenmap/tokenmap.html"
local TOKENMAP = HOME .. "/.local/bin/tokenmap"
local TASK_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
local STALE_HOURS = 26
local DELTA_COLUMN = 3

local menuFont = { name = "Menlo", size = 13 }
local RED = { red = 0.86, green = 0.16, blue = 0.14, alpha = 1 }
local GREEN = { red = 0.13, green = 0.55, blue = 0.25, alpha = 1 }
local DIM = { list = "System", name = "tertiaryLabelColor" }
local TONES = { worse = RED, better = GREEN }

local path = DEFAULT_PATH
local cache, cacheStamp, cacheProblem = nil, nil, nil
local pasteboardFn = function(text) hs.pasteboard.setContents(text) end
local alertFn = function(text) hs.alert.show(text, 4) end
local scanTask, scanStarted, scanError = nil, nil, nil

local function readFile(file)
    local handle = io.open(file, "r")
    if not handle then return nil end
    local body = handle:read("*a")
    handle:close()
    return body
end

local function load()
    local attrs = hs.fs.attributes(path)
    local stamp = attrs and (tostring(attrs.size) .. "/" .. tostring(attrs.modification)) or "missing"
    if stamp == cacheStamp then return cache, cacheProblem, attrs end
    local data, problem = nil, "missing"
    if attrs then
        local ok, decoded = pcall(hs.json.decode, readFile(path) or "")
        if ok and type(decoded) == "table" and type(decoded.rows) == "table" then
            data, problem = decoded, nil
        else
            problem = "unreadable"
        end
    end
    cache, cacheStamp, cacheProblem = data, stamp, problem
    return data, problem, attrs
end

local function dimColor()
    local palette = type(hs.drawing) == "table" and hs.drawing.color
    local asRGB = type(palette) == "table" and palette.asRGB
    if type(asRGB) ~= "function" then return DIM end
    local ok, resolved = pcall(asRGB, DIM)
    return (ok and type(resolved) == "table") and resolved or DIM
end

local function style(text, color)
    return hs.styledtext.new(text, { font = menuFont, color = color })
end

local function width(text) return utf8.len(text) or #text end
local function pad(text, size, right)
    local spaces = string.rep(" ", math.max(0, size - width(text)))
    return right and (spaces .. text) or (text .. spaces)
end

-- Each row: { label, nums = {...}, tone, dim }. The label column is left-aligned, every number
-- right-aligned to its column's widest cell, the Δ column coloured by the row's tone.
local function aligned(rows)
    local labelWidth, numWidths = 0, {}
    for _, row in ipairs(rows) do
        labelWidth = math.max(labelWidth, width(row.label or ""))
        for c, cell in ipairs(row.nums or {}) do
            numWidths[c] = math.max(numWidths[c] or 0, width(cell or ""))
        end
    end
    local dim = dimColor()
    local titles = {}
    for index, row in ipairs(rows) do
        local nums = row.nums or {}
        local rowColor = row.dim and dim or row.color
        local title = style(pad(row.label or "", labelWidth), rowColor)
        for c = 1, #numWidths do
            local color = rowColor
            if c == DELTA_COLUMN and row.tone then color = TONES[row.tone] or rowColor end
            title = title .. style("  " .. pad(nums[c] or "", numWidths[c], true), color)
        end
        titles[index] = title
    end
    return titles
end

local function copyFn(text)
    return function()
        pasteboardFn(text)
        alertFn("Copied")
    end
end

local function weeksMenu(row)
    local rows = { { label = "week (Mon–Sun)", nums = { row.weeks_unit or "" }, dim = true } }
    for _, week in ipairs(row.weeks or {}) do
        rows[#rows + 1] = { label = week.label, nums = { week.cell } }
    end
    local items = {}
    for index, title in ipairs(aligned(rows)) do
        items[#items + 1] = { title = title, disabled = index == 1 }
    end
    return items
end

local function byWeekMenu(data)
    local columns = {}
    for _, row in ipairs(data.rows) do
        if #(row.weeks or {}) > #columns then columns = row.weeks end
    end
    local rows, groups = { { label = "week (Mon–Sun)", nums = {}, dim = true } }, {}
    for c, week in ipairs(columns) do rows[1].nums[c] = week.short or week.label end
    for _, row in ipairs(data.rows) do
        if #(row.weeks or {}) > 0 then
            local label = row.label or ""
            if row.weeks_unit and row.weeks_unit ~= data.unit_label then label = label .. " · " .. row.weeks_unit end
            local nums = {}
            for c, week in ipairs(row.weeks) do nums[c] = week.cell end
            rows[#rows + 1] = { label = label, nums = nums }
            groups[#rows] = row.group
        end
    end
    local items = {}
    for index, title in ipairs(aligned(rows)) do
        if index > 2 and groups[index] ~= groups[index - 1] then items[#items + 1] = { title = "-" } end
        items[#items + 1] = { title = title, disabled = index == 1 }
    end
    return items
end

-- Every section of one drill menu is aligned as one table, so their columns line up.
local function rowMenu(row)
    local rows, owners = {}, {}
    for _, section in ipairs(row.sections or {}) do
        if #(section.rows or {}) > 0 then
            rows[#rows + 1] = { label = section.title or "", nums = section.columns or {}, dim = true }
            owners[#rows] = false
            for _, item in ipairs(section.rows) do
                rows[#rows + 1] = { label = item.label, nums = item.cells, tone = item.tone, dim = item.dim }
                owners[#rows] = item
            end
        end
    end
    local items = {}
    for index, title in ipairs(aligned(rows)) do
        local item = owners[index]
        if not item then
            if #items > 0 then items[#items + 1] = { title = "-" } end
            items[#items + 1] = { title = title, disabled = true }
        elseif item.child then
            items[#items + 1] = { title = title, menu = rowMenu(item.child) }
        elseif item.copy then
            items[#items + 1] = { title = title, fn = copyFn(item.copy) }
        else
            items[#items + 1] = { title = title }
        end
    end
    if #(row.weeks or {}) > 0 then
        if #items > 0 then items[#items + 1] = { title = "-" } end
        items[#items + 1] = { title = "Calendar weeks", menu = weeksMenu(row) }
    end
    return items
end

local function clock(iso)
    local date, time = tostring(iso or ""):match("^%d%d%d%d%-(%d%d%-%d%d)T(%d%d:%d%d)")
    if not date then return "?" end
    local today = os.date("%m-%d")
    if date == today then return time end
    local month, day = date:match("(%d%d)%-(%d%d)")
    return os.date("%b", os.time({ year = 2000, month = tonumber(month), day = 1 })) .. " "
        .. tonumber(day) .. " " .. time
end

local function ageText(seconds)
    if seconds < 3600 then return math.floor(seconds / 60) .. "m ago" end
    if seconds < 48 * 3600 then return math.floor(seconds / 3600) .. "h ago" end
    return math.floor(seconds / 86400) .. "d ago"
end

local function isStale(data, attrs)
    if not data or not attrs then return true end
    local hours = tonumber(data.stale_after_hours) or STALE_HOURS
    return os.time() - attrs.modification > hours * 3600
end

local function statusItems(data, problem, attrs)
    local items = {}
    local running = scanTask ~= nil
    if problem == "missing" then
        items[#items + 1] = { title = style("no tracking.json yet — run Rescan now", RED), disabled = true }
    elseif problem == "unreadable" then
        items[#items + 1] = { title = style("tracking.json is unreadable — run Rescan now", RED), disabled = true }
    else
        local age = os.time() - attrs.modification
        local text = string.format("7 days to %s vs the 7 before · scanned %s",
            clock(data.data_through or data.generated_at), ageText(age))
        local color = isStale(data, attrs) and RED or dimColor()
        if isStale(data, attrs) then text = "STALE — " .. text end
        items[#items + 1] = { title = style(text, color), disabled = true }
    end
    if running then
        items[#items + 1] = { title = style("rescanning since " .. os.date("%H:%M", scanStarted) .. "…", dimColor()),
                              disabled = true }
    elseif scanError then
        items[#items + 1] = { title = style("last rescan failed: " .. scanError, RED), disabled = true }
    end
    return items
end

local function lastLine(text)
    local last = nil
    for line in tostring(text or ""):gmatch("[^\n]+") do
        if line:match("%S") then last = line end
    end
    return last and last:sub(1, 120) or nil
end

function M.rescan()
    if scanTask then return false end
    scanError = nil
    local task = hs.task.new(TOKENMAP, function(code, _, err)
        scanTask = nil
        if code ~= 0 then scanError = lastLine(err) or ("exit " .. tostring(code)) end
        alertFn(code == 0 and "Token tracking updated" or ("Token tracking rescan failed: " .. scanError))
    end, { "scan", "--quiet" })
    if not task then
        scanError = "could not start " .. TOKENMAP
        return false
    end
    task:setEnvironment({ PATH = TASK_PATH, HOME = HOME })
    if not task:start() then
        scanError = "could not start " .. TOKENMAP
        return false
    end
    scanTask, scanStarted = task, os.time()
    return true
end

-- The Automations row itself: red when the export is stale or the instruction watcher is down,
-- so neither alarm needs the submenu opened to be seen.
function M.title(watcherAlarm)
    local data, _, attrs = load()
    local alarms = {}
    if isStale(data, attrs) then alarms[#alarms + 1] = "stale" end
    if watcherAlarm then alarms[#alarms + 1] = "watcher down" end
    if #alarms == 0 then return "Token tracking" end
    return hs.styledtext.new("Token tracking · " .. table.concat(alarms, " · "), { color = RED })
end

function M.menuItems(changeLogItem)
    local data, problem, attrs = load()
    local items = statusItems(data, problem, attrs)
    if data then
        local rows = { { label = data.unit_label or "", nums = data.columns or { "7 days", "prev 7", "Δ" },
                         dim = true } }
        for _, row in ipairs(data.rows) do
            rows[#rows + 1] = { label = row.label, nums = row.cells, tone = row.tone }
        end
        local titles = aligned(rows)
        items[#items + 1] = { title = "-" }
        items[#items + 1] = { title = titles[1], disabled = true }
        local group = nil
        for index, row in ipairs(data.rows) do
            if group ~= nil and row.group ~= group then
                items[#items + 1] = { title = "-" }
                local caption = type(data.groups) == "table" and data.groups[row.group]
                if caption then items[#items + 1] = { title = style(caption, dimColor()), disabled = true } end
            end
            group = row.group
            items[#items + 1] = { title = titles[index + 1], menu = rowMenu(row) }
        end
        items[#items + 1] = { title = "-" }
        items[#items + 1] = { title = "By week", menu = byWeekMenu(data) }
    end
    items[#items + 1] = { title = "-" }
    if changeLogItem then items[#items + 1] = changeLogItem end
    if hs.fs.attributes(PAGE) then
        items[#items + 1] = { title = "Open token map page", fn = function()
            hs.task.new("/usr/bin/open", nil, { PAGE }):start()
        end }
    end
    items[#items + 1] = scanTask and { title = "Rescanning…", disabled = true }
        or { title = "Rescan now", fn = function() M.rescan() end }
    return items
end

function M.setPath(value)
    path = value or DEFAULT_PATH
    cache, cacheStamp, cacheProblem = nil, nil, nil
end
function M.setPasteboard(fn) pasteboardFn = fn or function(text) hs.pasteboard.setContents(text) end end
function M.setAlert(fn) alertFn = fn or function(text) hs.alert.show(text, 4) end end

return M
