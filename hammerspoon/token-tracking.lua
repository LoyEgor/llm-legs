-- Automations ▸ Token tracking: tokenmap's week-over-week spend rows.
--
-- The whole Automations menu is rebuilt on every click, so this module reads one small JSON
-- tokenmap writes (tracking.json, or tracking-range-<key>.json for a chosen Compare range),
-- decoded once per size+mtime — never a query or a subprocess on the click path. Every number,
-- label and Δ tone is decided by tokenmap (tokenmap/tracking.py); this side only aligns the
-- columns and colours the tone. An export is current while its db_generation is the one in the
-- `generation` file every tokenmap commit replaces; an outdated one is recomputed, never shown
-- as current.

local M = {}
local menuStyle = require("menu-style")
local HOME = os.getenv("HOME") or ""
local DEFAULT_PATH = HOME .. "/.local/share/tokenmap/tracking.json"
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

local path = DEFAULT_PATH
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
local jobSoft, jobSerial, sevenOwed = false, 0, false
local jobScan, jobQuiet, jobFile, jobRange, pending = false, false, nil, nil, nil
local active, asked = nil, nil
local tried = {}

local function readFile(file)
    local handle = io.open(file, "r")
    if not handle then return nil end
    local body = handle:read("*a")
    handle:close()
    return body
end

local function load(file)
    local attrs = hs.fs.attributes(file)
    local stamp = attrs and table.concat({ attrs.ino or "", attrs.size, attrs.modification }, "/") or "missing"
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

local function besideExports(name)
    return (path:match("^(.*)/[^/]*$") or ".") .. "/" .. name
end

-- Read on every call: a token is always 17 bytes, so a size+mtime stamp misses two commits in
-- one second.
local function generation()
    local file = besideExports("generation")
    local attrs = hs.fs.attributes(file)
    if not attrs then return nil, nil end
    return (readFile(file) or ""):match("^%s*(%x+)%s*$"), attrs
end

local function outdated(data)
    local current = generation()
    return current ~= nil and (type(data) ~= "table" or data.db_generation ~= current)
end

-- When the export last matched the database: a later scan that changed nothing confirms it.
local function freshAt(data, attrs)
    local current, genAttrs = generation()
    local at = attrs.modification
    if current and genAttrs and type(data) == "table" and data.db_generation == current then
        at = math.max(at, genAttrs.modification)
    end
    return at
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

local function spendNums(node)
    local nums = {}
    for _, cell in ipairs(node.cells or {}) do nums[#nums + 1] = cell end
    for _, cell in ipairs(node.weeks or {}) do nums[#nums + 1] = cell end
    return nums
end

local function spendMenu(columns, nodes, more, open)
    local rows = { { label = "", nums = columns or {}, dim = true } }
    for _, node in ipairs(nodes) do rows[#rows + 1] = { label = node.label, nums = spendNums(node) } end
    if more then rows[#rows + 1] = { label = more.label, nums = spendNums(more), dim = true } end
    local items = {}
    for index, title in ipairs(aligned(rows)) do
        local node = nodes[index - 1]
        if node and open then
            items[#items + 1] = { title = title, menu = open(node) }
        else
            items[#items + 1] = { title = title, disabled = true }
        end
    end
    return items
end

local function spendItem(spend)
    local function leaves(columns)
        return function(node)
            local shown = {}
            for index, child in ipairs(node.children or {}) do
                if node.more and index > (tonumber(node.more.after) or 0) then break end
                shown[#shown + 1] = child
            end
            return spendMenu(columns, shown, node.more)
        end
    end
    local items = { { title = style(string.format("%d days to %s · %s", spend.days or 7, clock(spend.data_through),
        spend.unit_label or ""), dimColor()), disabled = true } }
    for _, item in ipairs(spendMenu(spend.columns, spend.tree or {}, nil, function(consumer)
        local columns = consumer.columns or spend.columns
        return spendMenu(columns, consumer.children or {}, nil, leaves(columns))
    end)) do
        items[#items + 1] = item
    end
    return { title = "Spend", menu = items }
end

local function isStale(data, attrs)
    if not data or not attrs then return true end
    local hours = tonumber(data.stale_after_hours) or STALE_HOURS
    return os.time() - freshAt(data, attrs) > hours * 3600
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

local function rangeFile(range)
    return range == RANGES[1] and path or besideExports("tracking-range-" .. range.key .. ".json")
end

local function sameRange(a, b)
    return a ~= nil and b ~= nil and a.key == b.key and a.since == b.since
end

local function statusItems(data, problem, attrs, snapshot)
    local items = {}
    local running = scanTask ~= nil
    if problem == "missing" then
        items[#items + 1] = { title = style("no data yet", RED), disabled = true }
    elseif problem == "unreadable" then
        items[#items + 1] = { title = style("data unreadable", RED), disabled = true }
    else
        local age = os.time() - (snapshot and attrs.modification or freshAt(data, attrs))
        local through = clock(data.data_through or data.generated_at)
        local verb = (snapshot and age > SNAPSHOT_HOURS * 3600) and "computed" or "scanned"
        local text = string.format("7 days to %s vs the 7 before · %s %s", through, verb, menuStyle.ago(age))
        if type(data.range) == "table" and data.range.title then
            text = string.format("%s · data to %s · %s %s", data.range.title, through, verb,
                menuStyle.ago(age))
        end
        local stale = not snapshot and isStale(data, attrs)
        if outdated(data) then
            stale, text = true, "outdated: " .. text
        elseif running and jobScan then
            text = "updating: " .. text
        elseif stale then
            text = "stale: " .. text
        end
        items[#items + 1] = { title = style(text, stale and RED or dimColor()), disabled = true }
    end
    if running then
        local doing = jobScan and "scanning new data" or ("computing " .. (jobLabel or rangeLabel(jobRange)))
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

local startJob

local function startStep(steps, index, serial, onStep)
    local step = steps[index]
    local task = taskFn(step.launch, function(code, _, err)
        if serial ~= jobSerial then return end
        scanTask = nil
        if code ~= 0 then scanError = lastLine(err) or ("exit " .. tostring(code)) end
        onStep(step, code == 0)
        if step.scan and pending then
            local range = pending
            pending = nil
            startJob(range, false)
            return
        end
        if code ~= 0 then return end
        if index < #steps and not startStep(steps, index + 1, serial, onStep) then
            onStep(steps[index + 1], false)
        end
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
    scanTask, jobSoft, jobLabel = task, step.soft or false, step.label
    jobScan, jobFile, scanStarted = step.scan or false, step.file, os.time()
    return true
end

-- The view asked for runs at normal priority; the 7-day export a range run leaves behind its
-- scan follows at nice 19, and the next click may cut it short: it is owed until a run writes it.
function startJob(range, scanFirst, quiet)
    if scanTask then return false end
    scanError = nil
    jobSerial = jobSerial + 1
    jobQuiet, jobRange = quiet or false, range
    local ranged = range ~= RANGES[1]
    local label = rangeLabel(range)
    local steps = {}
    if scanFirst and ranged then
        steps[1] = { launch = TOKENMAP, args = { "scan", "--quiet", "--no-tracking" }, label = label, scan = true }
        sevenOwed = true
    elseif scanFirst then
        steps[1] = { launch = TOKENMAP, args = { "scan", "--quiet" }, label = nil, view = true, seven = true,
                     scan = true }
    end
    if ranged then
        local args = { "tracking" }
        if range.key == "custom" then
            args[#args + 1], args[#args + 2] = "--since", range.since
        else
            args[#args + 1], args[#args + 2] = "--range", range.key
        end
        args[#args + 1] = "--write"
        steps[#steps + 1] = { launch = TOKENMAP, args = args, label = label, view = true, file = rangeFile(range) }
        if sevenOwed then
            steps[#steps + 1] = { launch = "/usr/bin/nice", label = RANGES[1].label, soft = true, seven = true,
                                  args = { "-n", "19", TOKENMAP, "tracking", "--write" }, file = path }
        end
    elseif not scanFirst then
        steps[1] = { launch = TOKENMAP, args = { "tracking", "--write" }, label = RANGES[1].label, view = true,
                     seven = true, file = path }
    end
    local what = ranged and ("Token tracking " .. label) or "Token tracking refresh"
    local started = startStep(steps, 1, jobSerial, function(step, ok)
        if ok and step.seven then sevenOwed = false end
        if step.soft then return end
        if not step.view and ok then return end
        if sameRange(asked, range) then
            asked = nil
            if ok then remember(range) else active = nil end
        end
        if quiet then return end
        if ok then
            alertFn(ranged and (what .. " ready") or "Token tracking updated")
        else
            alertFn(what .. " failed: " .. scanError)
        end
    end)
    if not started and not quiet then alertFn(what .. " failed: " .. scanError) end
    return started
end

local function cancelJob()
    if not scanTask or jobScan then return not scanTask end
    jobSerial = jobSerial + 1
    scanTask:terminate()
    if jobFile then tried[jobFile] = nil end
    scanTask, jobSoft, jobLabel, jobQuiet = nil, false, nil, false
    return true
end

local function lastScan()
    local _, genAttrs = generation()
    local attrs = genAttrs or hs.fs.attributes(path)
    return attrs and attrs.modification
end

function M.rescan()
    if scanTask and not (jobSoft or jobQuiet) then return false end
    cancelJob()
    return startJob(activeRange(), true)
end

function M.choose(range)
    local seven = range == RANGES[1]
    if scanTask and jobScan then
        pending = (not seven or jobRange ~= RANGES[1]) and range or nil
        if seven then asked = nil; remember(range) else asked = range end
        if pending then alertFn("Token tracking: computing " .. rangeLabel(range) .. " after the scan…") end
        return true
    end
    if seven then
        if jobSoft or jobRange ~= RANGES[1] then cancelJob() end
        asked = nil
        remember(range)
        return true
    end
    cancelJob()
    asked = range
    local scanned = lastScan()
    local scanFirst = not scanned or os.time() - scanned > SCAN_FIRST_SECONDS
    if not scanFirst and generation() and not outdated((load(rangeFile(range)))) then active = range end
    return startJob(range, scanFirst)
end

local function compareItem()
    local current = activeRange()
    local choices = {}
    local function title(text, range)
        return sameRange(asked, range) and (text .. " — computing…") or text
    end
    for _, range in ipairs(RANGES) do
        choices[#choices + 1] = { title = title(range.label, range), checked = current == range,
                                  fn = function() M.choose(range) end }
    end
    local custom = current.key == "custom"
    local sinceTitle = custom and ("Since " .. current.since) or "Since…"
    if asked and asked.key == "custom" then sinceTitle = title("Since " .. asked.since, asked) end
    choices[#choices + 1] = { title = sinceTitle, checked = custom, fn = function()
        local text = promptFn(custom and current.since or "")
        text = text and text:match("^%s*(.-)%s*$")
        if text and text ~= "" then M.choose({ key = "custom", since = text }) end
    end }
    return { title = asked and title("Compare: " .. rangeLabel(asked), asked) or ("Compare: " .. rangeLabel(current)),
             menu = choices }
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
    local range = activeRange()
    local file = rangeFile(range)
    local data, problem, attrs = load(file)
    local current = generation()
    if current and tried[file] ~= current and outdated(data) and (not scanTask or jobSoft and file ~= path) then
        tried[file] = current
        if cancelJob() then startJob(range, false, true) end
    end
    local items = statusItems(data, problem, attrs, file ~= path)
    local seven = file == path and data or load(path)
    if seven and type(seven.spend) == "table" then items[#items + 1] = spendItem(seven.spend) end
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
    items[#items + 1] = (scanTask and not (jobSoft or jobQuiet)) and { title = "refreshing…", disabled = true }
        or { title = "Refresh", fn = function() M.rescan() end }
    return menuStyle.mono(items, style)
end

function M.setPath(value)
    path = value or DEFAULT_PATH
    caches, tried = {}, {}
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
