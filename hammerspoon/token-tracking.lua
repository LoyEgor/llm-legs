-- Automations ▸ Token tracking: tokenmap's week-over-week spend rows.
--
-- The whole Automations menu is rebuilt on every click, so this module reads one small JSON
-- tokenmap writes (tracking.json, or tracking-range.json for a chosen Compare range), decoded
-- once per size+mtime — never a query or a subprocess on the click path. Every number, label
-- and Δ tone is decided by tokenmap (tokenmap/tracking.py); this side only aligns the columns
-- and colours the tone.

local M = {}
local menuStyle = require("menu-style")
local HOME = os.getenv("HOME") or ""
local DEFAULT_PATH = HOME .. "/.local/share/tokenmap/tracking.json"
local DEFAULT_RANGE_PATH = HOME .. "/.local/share/tokenmap/tracking-range.json"
local PAGE = HOME .. "/.local/share/tokenmap/tokenmap.html"
local TOKENMAP = HOME .. "/.local/bin/tokenmap"
local TASK_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
local STALE_HOURS = 26
local SCAN_FIRST_SECONDS = 30 * 60
local SNAPSHOT_HOURS = 6
local SETTINGS_KEY = "tokenTracking.range"
local SINCE_HINT = "Forms: 2026-09-29 18:00 · 18:00 · yesterday 18:00 · 6h · 90m"
local RANGES = {
    { key = "7d", label = "7 days vs 7 before" },
    { key = "24h", label = "24h vs 24h before" },
    { key = "3d", label = "3 days vs 3 before" },
    { key = "today", label = "Today vs yesterday, same hours" },
}
local DELTA_COLUMN = 3

local RED = menuStyle.RED
local TONES = { worse = RED, better = menuStyle.GREEN }

local path, rangePath = DEFAULT_PATH, DEFAULT_RANGE_PATH
local caches = {}
local pasteboardFn = function(text) hs.pasteboard.setContents(text) end
local alertFn = function(text) hs.alert.show(text, 4) end
local taskFn = function(...) return hs.task.new(...) end
local settingsStore = hs.settings
local function askSince(default)
    hs.focus()
    local button, text = hs.dialog.textPrompt("Compare since…", SINCE_HINT, default or "",
        "Compute", "Cancel")
    return button == "Compute" and text or nil
end
local promptFn = askSince
local scanTask, scanStarted, scanError, jobLabel = nil, nil, nil, nil
local active, wanted = nil, nil

local function readFile(file)
    local handle = io.open(file, "r")
    if not handle then return nil end
    local body = handle:read("*a")
    handle:close()
    return body
end

local function load(file)
    local attrs = hs.fs.attributes(file)
    local stamp = attrs and (tostring(attrs.size) .. "/" .. tostring(attrs.modification)) or "missing"
    local entry = caches[file]
    if entry and entry.stamp == stamp then return entry.data, entry.problem, attrs end
    local data, problem = nil, "missing"
    if attrs then
        local ok, decoded = pcall(hs.json.decode, readFile(file) or "")
        if ok and type(decoded) == "table" and type(decoded.rows) == "table" then
            data, problem = decoded, nil
        else
            problem = "unreadable"
        end
    end
    caches[file] = { stamp = stamp, data = data, problem = problem }
    return data, problem, attrs
end

local function dimColor()
    local palette = type(hs.drawing) == "table" and hs.drawing.color
    local asRGB = type(palette) == "table" and palette.asRGB
    if type(asRGB) ~= "function" then return menuStyle.DIM end
    local ok, resolved = pcall(asRGB, menuStyle.DIM)
    return (ok and type(resolved) == "table") and resolved or menuStyle.DIM
end

local function style(text, color)
    return hs.styledtext.new(text, { font = menuStyle.MONO, color = color })
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
        items[#items + 1] = { title = title, disabled = true }
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
        items[#items + 1] = { title = title, disabled = true }
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
            items[#items + 1] = { title = title, disabled = true }
        end
    end
    if #(row.weeks or {}) > 0 then
        if #items > 0 then items[#items + 1] = { title = "-" } end
        items[#items + 1] = { title = "Calendar weeks", menu = weeksMenu(row) }
    end
    return items
end

-- The digits as written, offset ignored: tokenmap stamps local time.
local function clock(iso)
    local y, mo, d, h, mi = tostring(iso or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d)")
    if not y then return "?" end
    return menuStyle.clock(os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h),
        min = tonumber(mi) }))
end

local function isStale(data, attrs)
    if not data or not attrs then return true end
    local hours = tonumber(data.stale_after_hours) or STALE_HOURS
    return os.time() - attrs.modification > hours * 3600
end

local function rangeLabel(range)
    return range.label or ("from " .. range.since)
end

local function activeRange()
    if active then return active end
    local saved = settingsStore.get(SETTINGS_KEY)
    active = RANGES[1]
    if type(saved) == "table" and saved.key == "custom" and type(saved.since) == "string"
        and saved.since ~= "" then
        active = { key = "custom", since = saved.since }
    elseif type(saved) == "table" then
        for _, range in ipairs(RANGES) do
            if range.key == saved.key then active = range end
        end
    end
    return active
end

local function activePath()
    return activeRange() == RANGES[1] and path or rangePath
end

local function statusItems(data, problem, attrs, snapshot)
    local items = {}
    local running = scanTask ~= nil
    if problem == "missing" then
        items[#items + 1] = { title = style("no data yet", RED), disabled = true }
    elseif problem == "unreadable" then
        items[#items + 1] = { title = style("data unreadable", RED), disabled = true }
    else
        local age = os.time() - attrs.modification
        local through = clock(data.data_through or data.generated_at)
        local verb = (snapshot and age > SNAPSHOT_HOURS * 3600) and "computed" or "scanned"
        local text = string.format("7 days to %s vs the 7 before · %s %s", through, verb, menuStyle.ago(age))
        if type(data.range) == "table" and data.range.title then
            text = string.format("%s · data to %s · %s %s", data.range.title, through, verb,
                menuStyle.ago(age))
        end
        local stale = not snapshot and isStale(data, attrs)
        if stale then text = "stale: " .. text end
        items[#items + 1] = { title = style(text, stale and RED or dimColor()), disabled = true }
    end
    if running then
        local doing = jobLabel and ("computing " .. jobLabel) or "refreshing"
        items[#items + 1] = { title = style(doing .. " since " .. menuStyle.clock(scanStarted) .. "…", dimColor()),
                              disabled = true }
    elseif scanError then
        items[#items + 1] = { title = style("last refresh failed: " .. scanError, RED), disabled = true }
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

local function remember(range)
    active = range
    settingsStore.set(SETTINGS_KEY, { key = range.key, since = range.since })
end

local function startStep(steps, index, onDone)
    local step = steps[index]
    local task = taskFn(step.launch, function(code, _, err)
        scanTask = nil
        if code ~= 0 then
            scanError = lastLine(err) or ("exit " .. tostring(code))
            return onDone(false)
        end
        if index == #steps then return onDone(true) end
        if not startStep(steps, index + 1, onDone) then onDone(false) end
    end, step.args)
    if not task then
        scanError = "could not start " .. TOKENMAP
        return false
    end
    task:setEnvironment({ PATH = TASK_PATH, HOME = HOME })
    if not task:start() then
        scanError = "could not start " .. TOKENMAP
        return false
    end
    scanTask = task
    return true
end

local function startJob(range, scanFirst)
    if scanTask then return false end
    scanError = nil
    local steps = {}
    if scanFirst then steps[1] = { launch = TOKENMAP, args = { "scan", "--quiet" } } end
    local ranged = range ~= RANGES[1]
    if ranged then
        local args = { "-n", "10", TOKENMAP, "tracking" }
        if range.key == "custom" then
            args[#args + 1], args[#args + 2] = "--since", range.since
        else
            args[#args + 1], args[#args + 2] = "--range", range.key
        end
        args[#args + 1] = "--write"
        steps[#steps + 1] = { launch = "/usr/bin/nice", args = args }
    end
    jobLabel = ranged and rangeLabel(range) or nil
    wanted = ranged and range or nil
    scanStarted = os.time()
    local what = ranged and ("Token tracking " .. rangeLabel(range)) or "Token tracking refresh"
    local started = startStep(steps, 1, function(ok)
        if ok and ranged and wanted == range then remember(range) end
        if ok then
            alertFn(ranged and (what .. " ready") or "Token tracking updated")
        else
            alertFn(what .. " failed: " .. scanError)
        end
    end)
    if not started then alertFn(what .. " failed: " .. scanError) end
    return started
end

function M.rescan()
    return startJob(activeRange(), true)
end

function M.choose(range)
    if range == RANGES[1] then
        wanted = nil
        remember(range)
        return true
    end
    if scanTask then
        alertFn("Token tracking is busy; try again when it finishes")
        return false
    end
    local attrs = hs.fs.attributes(path)
    return startJob(range, not attrs or os.time() - attrs.modification > SCAN_FIRST_SECONDS)
end

local function compareItem()
    local current = activeRange()
    local choices = {}
    for _, range in ipairs(RANGES) do
        choices[#choices + 1] = { title = range.label, checked = current == range,
                                  fn = function() M.choose(range) end }
    end
    local custom = current.key == "custom"
    local sinceTitle = custom and ("Since " .. current.since) or "Since…"
    choices[#choices + 1] = { title = sinceTitle, checked = custom, fn = function()
        local text = promptFn(custom and current.since or "")
        text = text and text:match("^%s*(.-)%s*$")
        if text and text ~= "" then M.choose({ key = "custom", since = text }) end
    end }
    return { title = "Compare: " .. rangeLabel(current), menu = choices }
end

-- The Automations row itself: red when the export is stale or the instruction watcher is down,
-- so neither alarm needs the submenu opened to be seen.
function M.title(watcherAlarm)
    local data, _, attrs = load(path)
    local alarms = {}
    if isStale(data, attrs) then alarms[#alarms + 1] = "stale" end
    if watcherAlarm then alarms[#alarms + 1] = "watcher down" end
    if #alarms == 0 then return "Token tracking" end
    return hs.styledtext.new("Token tracking: " .. table.concat(alarms, " · "), { color = RED, font = (hs.styledtext.defaultFonts or {}).menu })
end

function M.menuItems(changeLogItem)
    local file = activePath()
    local data, problem, attrs = load(file)
    local items = statusItems(data, problem, attrs, file ~= path)
    items[#items + 1] = compareItem()
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
    items[#items + 1] = { title = "-" }
    items[#items + 1] = scanTask and { title = "refreshing…", disabled = true }
        or { title = "Refresh", fn = function() M.rescan() end }
    return menuStyle.mono(items, style)
end

function M.setPath(value, rangeValue)
    path, rangePath = value or DEFAULT_PATH, rangeValue or DEFAULT_RANGE_PATH
    caches = {}
end
function M.setPasteboard(fn) pasteboardFn = fn or function(text) hs.pasteboard.setContents(text) end end
function M.setAlert(fn) alertFn = fn or function(text) hs.alert.show(text, 4) end end
function M.setTask(fn) taskFn = fn or function(...) return hs.task.new(...) end end
function M.setSettings(store)
    settingsStore = store or hs.settings
    active = nil
end
function M.setPrompt(fn) promptFn = fn or askSince end

return M
