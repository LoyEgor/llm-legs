-- Automations ▸ Token tracking: tokenmap's spend by vendor and consumer, with the week-over-week
-- category rows under By category.
--
-- The whole Automations menu is rebuilt on every click, so this module reads small JSONs
-- tokenmap writes (spend-<key>.json for the vendor trees and the harness index row, tracking.json
-- or tracking-range-<key>.json for By category, which has its own range and refresh),
-- decoded once per size+mtime — never a query or a subprocess on the click path. Every number,
-- label and Δ tone is decided by tokenmap (tokenmap/tracking.py); this side only aligns the
-- columns and colours the tone. An export is current while its db_generation is the one in the
-- `generation` file every tokenmap commit replaces and its `code` the digest in the `code` file
-- beside it, written after every export run. An outdated spend export is recomputed on open;
-- an outdated category export shows red until its own range or Refresh recomputes it.

local M = {}
local menuStyle = require("menu-style")
local HOME = os.getenv("HOME") or ""
local DEFAULT_PATH = HOME .. "/.local/share/tokenmap/tracking.json"
local PAGE = HOME .. "/.local/share/tokenmap/tokenmap.html"
local TOKENMAP = HOME .. "/.local/bin/tokenmap"
local TASK_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
local STALE_HOURS = 26
local SCAN_FIRST_SECONDS = 30 * 60
local SETTINGS_KEY = "tokenTracking.range"
local SPEND_KEY = "tokenTracking.spendRange"
local SINCE_HINT = "Forms: 2026-09-29 18:00 · 18:00 · yesterday 18:00 · 6h · 90m"
local RANGES = {
    { key = "7d", label = "7 days vs 7 before" },
    { key = "24h", label = "24h vs 24h before" },
    { key = "3d", label = "3 days vs 3 before" },
    { key = "today", label = "Today vs yesterday, same hours" },
}
local SPEND_RANGES = { RANGES[2], RANGES[3], RANGES[1] }
local CATEGORY_RANGES = { RANGES[2], RANGES[3], RANGES[1], RANGES[4] }
local DELTA_COLUMN = 3

local function toneColor(tone, inactive)
    if tone == "worse" then return menuStyle.tone(menuStyle.RED, inactive) end
    if tone == "better" then return menuStyle.tone(menuStyle.GREEN, inactive) end
end

local path = DEFAULT_PATH
local sources = nil
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
local scanTask, scanError = nil, nil
local jobSoft, jobSerial, sevenOwed = false, 0, false
local jobScan, jobRange, pending = false, nil, nil
local active, asked = nil, nil
local spendTask, spendError, spendAsked, spendActive, spendSerial = nil, nil, nil, nil, 0
local spendScanning = false
local tried = {}
menuStyle.busySource("Token tracking", function() return scanTask ~= nil or spendTask ~= nil end)

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

local function sourceDir()
    if sources == nil then
        local real = hs.fs.pathToAbsolute(TOKENMAP)
        local root = real and real:match("^(.*)/bin/[^/]+$")
        sources = root and (root .. "/tokenmap") or false
    end
    return sources or nil
end

-- The digest tokenmap's last run wrote beside `generation`; false once a module is as new as it, so a
-- code change outdates every export before tokenmap next runs. nil: no tokenmap run has written one.
local function codeDigest()
    local file = besideExports("code")
    local attrs = hs.fs.attributes(file)
    if not attrs then return nil end
    local dir = sourceDir()
    if dir and hs.fs.attributes(dir, "mode") == "directory" then
        for name in hs.fs.dir(dir) do
            local module = name:match("%.py$") and hs.fs.attributes(dir .. "/" .. name)
            if module and module.modification >= attrs.modification then return false end
        end
    end
    return (readFile(file) or ""):match("^%s*(%x+)%s*$") or false
end

local function outdated(data)
    local current = generation()
    if current == nil then return false end
    if type(data) ~= "table" or data.db_generation ~= current then return true end
    local code = codeDigest()
    return code == false or (code ~= nil and data.code ~= code)
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
            if c == DELTA_COLUMN and row.tone then color = toneColor(row.tone, not row.active) or rowColor end
            title = title .. style("  " .. pad(nums[c] or "", numWidths[c], true), color)
        end
        titles[index] = menuStyle.toned(title)
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
                rows[#rows + 1] = { label = item.label, nums = item.cells, tone = item.tone, dim = item.dim,
                    active = item.child ~= nil or item.copy ~= nil }
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
    return os.time() - freshAt(data, attrs) > hours * 3600
end

local function rangeLabel(range)
    return range.label or ("from " .. range.since)
end

local function spendRange()
    if spendActive then return spendActive end
    local saved = settingsStore.get(SPEND_KEY)
    spendActive = RANGES[1]
    for _, range in ipairs(SPEND_RANGES) do
        if type(saved) == "table" and saved.key == range.key then spendActive = range end
    end
    return spendActive
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

local function trackingJob()
    return { running = scanTask ~= nil, error = scanError }
end

-- One line: when the data runs to, red once it is stale or older than the database, and whether a
-- refresh runs; the range lives in the column headers.
local function statusItems(data, problem, attrs, snapshot, job)
    job = job or trackingJob()
    local text, red = "no data yet", true
    if problem == "unreadable" then
        text = "data unreadable"
    elseif problem ~= "missing" then
        text = "data to " .. clock(data.data_through or data.generated_at)
        red = outdated(data) or (not snapshot and isStale(data, attrs))
    end
    if job.running then text = text .. " · refreshing…" end
    local items = { { title = style(text, red and menuStyle.tone(menuStyle.RED, true) or dimColor()), disabled = true } }
    if not job.running and job.error then
        items[2] = { title = style("last refresh failed: " .. job.error, menuStyle.tone(menuStyle.RED, true)), disabled = true }
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
    local function finished(code, err)
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
    end
    local task = taskFn(step.launch, function(code, _, err)
        if serial ~= jobSerial then return end
        finished(code, err)
        if not scanTask then menuStyle.busyChanged() end
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
    scanTask, jobSoft, jobScan = task, step.soft or false, step.scan or false
    menuStyle.busyChanged()
    return true
end

-- The view asked for runs at normal priority; the 7-day export a range run leaves behind its
-- scan follows at nice 19, and the next click may cut it short: it is owed until a run writes it.
function startJob(range, scanFirst)
    if scanTask then return false end
    scanError = nil
    jobSerial = jobSerial + 1
    jobRange = range
    local ranged = range ~= RANGES[1]
    local label = rangeLabel(range)
    local steps = {}
    if scanFirst and ranged then
        steps[1] = { launch = TOKENMAP, args = { "scan", "--quiet", "--no-tracking" }, scan = true }
        sevenOwed = true
    elseif scanFirst then
        steps[1] = { launch = TOKENMAP, args = { "scan", "--quiet" }, view = true, seven = true,
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
        steps[#steps + 1] = { launch = TOKENMAP, args = args, view = true }
        if sevenOwed then
            steps[#steps + 1] = { launch = "/usr/bin/nice", soft = true, seven = true,
                                  args = { "-n", "19", TOKENMAP, "tracking", "--write" } }
        end
    elseif not scanFirst then
        steps[1] = { launch = TOKENMAP, args = { "tracking", "--write" }, view = true, seven = true }
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
        if ok then
            alertFn(ranged and (what .. " ready") or "Token tracking updated")
        else
            alertFn(what .. " failed: " .. scanError)
        end
    end)
    if not started then alertFn(what .. " failed: " .. scanError) end
    return started
end

local function cancelJob()
    if not scanTask then return end
    jobSerial = jobSerial + 1
    scanTask:terminate()
    scanTask, jobSoft = nil, false
    menuStyle.busyChanged()
end

local function lastScan()
    local _, genAttrs = generation()
    local attrs = genAttrs or hs.fs.attributes(path)
    return attrs and attrs.modification
end

local function scanning() return spendScanning or (scanTask ~= nil and jobScan) end

function M.rescan()
    if spendScanning or scanTask and not jobSoft then return false end
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
        if not scanTask and generation() and outdated((load(path))) then return startJob(range, false) end
        return true
    end
    cancelJob()
    asked = range
    local scanned = lastScan()
    local scanFirst = not spendScanning and (not scanned or os.time() - scanned > SCAN_FIRST_SECONDS)
    if not scanFirst and generation() and not outdated((load(rangeFile(range)))) then active = range end
    return startJob(range, scanFirst)
end

local function rangeChoices(ranges, current, busy, choose)
    local choices = {}
    for _, range in ipairs(ranges) do
        choices[#choices + 1] = { title = sameRange(busy, range) and (range.label .. " — computing…") or range.label,
                                  checked = current == range, fn = function() choose(range) end }
    end
    return choices
end

local function compareItem()
    local current = activeRange()
    local function title(text, range)
        return sameRange(asked, range) and (text .. " — computing…") or text
    end
    local choices = rangeChoices(CATEGORY_RANGES, current, asked, M.choose)
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

-- `lead` is one more row aligned with the table but placed by the caller; its title comes second.
local function tableItems(data, lead)
    local rows = { { label = data.unit_label or "", nums = data.columns or { "7 days", "prev 7", "Δ" }, dim = true } }
    local menus = {}
    for index, row in ipairs(data.rows) do
        menus[index] = rowMenu(row)
        rows[#rows + 1] = { label = row.label, nums = row.cells, tone = row.tone, active = #menus[index] > 0 }
    end
    if lead then rows[#rows + 1] = lead end
    local titles = aligned(rows)
    local items = { { title = titles[1], disabled = true } }
    local group = nil
    for index, row in ipairs(data.rows) do
        if group ~= nil and row.group ~= group then
            items[#items + 1] = { title = "-" }
            local caption = type(data.groups) == "table" and data.groups[row.group]
            if caption then items[#items + 1] = { title = style(caption, dimColor()), disabled = true } end
        end
        group = row.group
        local menu = menus[index]
        items[#items + 1] = #menu > 0 and { title = titles[index + 1], menu = menu }
            or { title = titles[index + 1], disabled = true }
    end
    return items, lead and titles[#titles]
end

local function byDayMenu(days)
    local rows = { { label = "day", nums = days.columns or {}, dim = true } }
    for _, day in ipairs(days.rows or {}) do rows[#rows + 1] = { label = day.label, nums = day.cells } end
    local items = {}
    for _, title in ipairs(aligned(rows)) do items[#items + 1] = { title = title, disabled = true } end
    return items
end

local function spendFile(range)
    return besideExports("spend-" .. range.key .. ".json")
end

local function cancelSpend()
    if not spendTask or spendScanning then return end
    spendSerial = spendSerial + 1
    spendTask:terminate()
    spendTask, spendAsked = nil, nil
    menuStyle.busyChanged()
end

-- The vendor trees' fast export (`tokenmap spend`), after a scan that skips the category export
-- when `scanFirst`. It never alerts: a failure shows on the status line.
local function startSpend(range, scanFirst)
    cancelSpend()
    spendError = nil
    local serial = spendSerial
    local args = scanFirst and { "scan", "--quiet", "--no-tracking" } or { "spend", "--range", range.key, "--write" }
    local task = taskFn(TOKENMAP, function(code, _, err)
        if serial ~= spendSerial then return end
        spendTask, spendAsked, spendScanning = nil, nil, false
        if code ~= 0 then
            spendError = lastLine(err) or ("exit " .. tostring(code))
        elseif scanFirst then
            startSpend(spendRange())
        end
        if not spendTask then menuStyle.busyChanged() end
    end, args)
    if task then task:setEnvironment({ PATH = TASK_PATH, HOME = HOME }) end
    if not (task and task:start()) then
        spendError = "could not start " .. TOKENMAP
        return false
    end
    spendTask, spendAsked, spendScanning = task, range, scanFirst or false
    menuStyle.busyChanged()
    return true
end

function M.refresh()
    if scanning() then return false end
    return startSpend(spendRange(), true)
end

-- By category computes only when its own range or its own Refresh asks.
local function categoryItem()
    local range = activeRange()
    local file = rangeFile(range)
    local data, problem, attrs = load(file)
    local items = statusItems(data, problem, attrs, file ~= path)
    items[#items + 1] = compareItem()
    if data then
        items[#items + 1] = { title = "-" }
        local rest = {}
        for key, value in pairs(data) do rest[key] = value end
        rest.rows = {}
        for _, row in ipairs(data.rows or {}) do
            if row.key ~= "harness_index" then rest.rows[#rest.rows + 1] = row end
        end
        for _, item in ipairs(tableItems(rest)) do items[#items + 1] = item end
        items[#items + 1] = { title = "-" }
        items[#items + 1] = { title = "By week", menu = byWeekMenu(data) }
    end
    items[#items + 1] = { title = "-" }
    items[#items + 1] = (spendScanning or scanTask and not jobSoft) and { title = "refreshing…", disabled = true }
        or { title = "Refresh", fn = function() M.rescan() end }
    return { title = asked and "By category — computing…" or "By category", menu = items }
end

function M.chooseRange(range)
    spendActive = range
    settingsStore.set(SPEND_KEY, { key = range.key })
    if spendScanning then
        spendAsked = range
    elseif generation() and not outdated((load(spendFile(range)))) then
        if spendAsked and spendAsked ~= range then cancelSpend() end
    elseif not sameRange(spendAsked, range) then
        startSpend(range)
    end
    return true
end

local function indexLead(data)
    local row = data and data.index
    if type(row) == "table" then
        return { label = row.label, nums = row.cells, tone = row.tone, dim = outdated(data) }, row
    end
    return { label = "Harness index", nums = { "…" }, dim = true }, nil
end

-- The Automations row itself: red when the export is stale or the instruction watcher is down,
-- so neither alarm needs the submenu opened to be seen.
function M.title(watcherAlarm)
    local data, _, attrs = load(path)
    local alarms = {}
    if isStale(data, attrs) then alarms[#alarms + 1] = "stale" end
    if watcherAlarm then alarms[#alarms + 1] = "watcher down" end
    if #alarms == 0 then return "Token tracking" end
    return hs.styledtext.new("Token tracking: " .. table.concat(alarms, " · "), { color = menuStyle.tone(menuStyle.RED, false), font = (hs.styledtext.defaultFonts or {}).menu })
end

function M.menuItems(changeLogItem)
    local range = spendRange()
    local file = spendFile(range)
    local data, problem, attrs = load(file)
    local current = generation()
    local attempt = current and (current .. "/" .. tostring(codeDigest()))
    if current and not spendTask and tried[file] ~= attempt and outdated(data) then
        tried[file] = attempt
        startSpend(range)
    end
    local items = statusItems(data, problem, attrs, false, { running = spendTask ~= nil, error = spendError })
    local lead, indexRow = indexLead(data)
    local indexMenu = indexRow and rowMenu(indexRow) or {}
    lead.active = #indexMenu > 0
    local rows, leadTitle
    if data then rows, leadTitle = tableItems(data, lead) else leadTitle = aligned({ lead })[1] end
    items[#items + 1] = #indexMenu > 0 and { title = leadTitle, menu = indexMenu } or { title = leadTitle, disabled = true }
    local title = "Compare: " .. range.label
    if sameRange(spendAsked, range) then title = title .. " — computing…" end
    items[#items + 1] = { title = title, menu = rangeChoices(SPEND_RANGES, range, spendAsked, M.chooseRange) }
    if data then
        items[#items + 1] = { title = "-" }
        for _, item in ipairs(rows) do items[#items + 1] = item end
        if type(data.days) == "table" and #(data.days.rows or {}) > 0 then
            items[#items + 1] = { title = "-" }
            items[#items + 1] = { title = "By day", menu = byDayMenu(data.days) }
        end
    end
    items[#items + 1] = { title = "-" }
    items[#items + 1] = categoryItem()
    items[#items + 1] = { title = "-" }
    if changeLogItem then items[#items + 1] = changeLogItem end
    if hs.fs.attributes(PAGE) then
        items[#items + 1] = { title = "Open token map page", fn = function()
            hs.task.new("/usr/bin/open", nil, { PAGE }):start()
        end }
    end
    items[#items + 1] = { title = "-" }
    items[#items + 1] = scanning() and { title = "refreshing…", disabled = true }
        or { title = "Refresh", fn = function() M.refresh() end }
    return menuStyle.mono(items, style)
end

function M.setPath(value)
    path = value or DEFAULT_PATH
    caches, tried = {}, {}
end
function M.setSources(dir) sources = dir end
function M.setPasteboard(fn) pasteboardFn = fn or function(text) hs.pasteboard.setContents(text) end end
function M.setAlert(fn) alertFn = fn or function(text) hs.alert.show(text, 4) end end
function M.setTask(fn) taskFn = fn or function(...) return hs.task.new(...) end end
function M.setSettings(store)
    settingsStore = store or hs.settings
    active, spendActive = nil, nil
end
function M.setPrompt(fn) promptFn = fn or askSince end

return M
