-- Egor's end of the instruction-file tripwire.
--
-- `bin/instruction-watch.sh` detects a change to a file an LLM re-reads across sessions and writes
-- one JSON record per change into `events.jsonl`. It does NOT render anything: a hook that runs
-- after every Bash call cannot wait on a wedged Hammerspoon, and the six-second `hs.alert` it used
-- to fire straight from there was gone the moment it faded and lost outright whenever Hammerspoon
-- happened not to be running. This module owns the rendering half — the alert, the menu history
-- under Automations, and the receipt that says which of the two actually happened.
--
-- Three states, and the difference between them is the whole point:
--   sent=attempted  the hook MADE the delivery call. It is not a claim that anything ran.
--   receipt         this module read the record and decided what to do with it. Proof the other
--                   end woke up, nothing more.
--   receipt.alerted an alert was put on screen. Still not a claim that Egor SAW it — no marker in
--                   this design can say that, and none of them may be read as saying it.
-- Delivery does not depend on the hook's `hs` call landing: a watcher on the journal's directory,
-- a catch-up pump at load and a slow fallback timer all reach the same idempotent pump, so a
-- change written while Hammerspoon was down is delivered when it comes back rather than lost.

local M = {}
local CHARS_PER_TOKEN = 3.2
local FILE_WIDTH, BYTE_WIDTH, PRICE_WIDTH = 28, 8, 16
local ROOT = debug.getinfo(1, "S").source:match("^@(.+)/hammerspoon/instruction%-watch%.lua$")
local DEFAULT_RATES = (os.getenv("HOME") or "") .. "/.local/share/tokenmap/read-rates.json"
local ratesPath, ratesStamp, ratesCache = DEFAULT_RATES, nil, nil
local menuFont = { name = "Menlo", size = 13 }
local dimColorName = { list = "System", name = "tertiaryLabelColor" }
local pasteboardFn = function(text) hs.pasteboard.setContents(text) end
local function runOpenCommand(sid, onDone)
    if not ROOT then
        onDone(1, "", "instruction-watch: repository root unresolved")
        return
    end
    local task
    -- Break the callback/task cycle so completed tasks can be collected.
    task = hs.task.new(ROOT .. "/bin/chats", function(code, stdout, stderr)
        task = nil
        onDone(code, stdout, stderr)
    end, { "--open-command", sid, "--timeout", "1" })
    if not task or not task:start() then
        task = nil
        onDone(1, "", "could not start chats")
    end
end
local openCommandFn = runOpenCommand

local DEFAULT_STATE = (os.getenv("HOME") or "") .. "/.cache/claude-instruction-watch"
local JOURNAL_TAIL = 200    -- records kept in memory; the writer trims the file to the same order
local MENU_ROWS = 12
local ALERT_BURST = 3       -- alerts one pump may put on screen before it collapses the rest
local ALERT_MAX_AGE = 6 * 3600

local stateDir = DEFAULT_STATE
local watcher = nil
local timer = nil
local lastSeen = nil        -- journal size+mtime, so a write anywhere else in the dir costs a stat
local ensureWatcher, onChange

local alertFn = function(text, duration)
    hs.alert.show(text, duration or 6)
end

local function journalPath() return stateDir .. "/events.jsonl" end
local function receiptPath(id) return stateDir .. "/receipts/" .. id end
local function rankedPath() return stateDir .. "/ranked.txt" end

local function readFile(path)
    local handle = io.open(path, "r")
    if not handle then return nil end
    local body = handle:read("*a")
    handle:close()
    return body
end

local function writeFile(path, body)
    local handle = io.open(path, "w")
    if not handle then return false end
    handle:write(body)
    handle:close()
    return true
end

-- The stamps in the journal are UTC and `os.time` reads its table as local, so the correction is
-- the distance between what this machine calls that wall clock and the same instant in UTC.
local function parseIso(value)
    local y, mo, d, h, mi, s = tostring(value or "")
        :match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
    if not y then return nil end
    local stamp = os.time({
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(s), isdst = false,
    })
    if not stamp then return nil end
    return stamp + os.difftime(stamp, os.time(os.date("!*t", stamp)))
end

-- Oldest first, capped at the tail. A record this cannot decode is dropped rather than thrown:
-- the journal is appended to by a shell hook running in every live session, and one torn line may
-- not cost Egor the twelve good ones under it.
local function readJournal()
    local body = readFile(journalPath())
    if not body then return {} end
    local events, count = {}, 0
    for line in body:gmatch("[^\n]+") do
        local ok, decoded = pcall(hs.json.decode, line)
        if ok and type(decoded) == "table" and type(decoded.id) == "string" then
            count = count + 1
            events[count] = decoded
        end
    end
    if count > JOURNAL_TAIL then
        local trimmed = {}
        for i = count - JOURNAL_TAIL + 1, count do
            trimmed[#trimmed + 1] = events[i]
        end
        return trimmed
    end
    return events
end

local function receiptFor(id)
    local body = readFile(receiptPath(id))
    if not body then return nil end
    local ok, decoded = pcall(hs.json.decode, body)
    if ok and type(decoded) == "table" then return decoded end
    return { at = "?" }
end

local function ensureReceiptDir()
    if hs.fs.attributes(stateDir, "mode") ~= "directory" then return false end
    local dir = stateDir .. "/receipts"
    if hs.fs.attributes(dir, "mode") == "directory" then return true end
    return hs.fs.mkdir(dir) and true or false
end

local function shortPath(path)
    local parent, base = tostring(path or ""):match("([^/]+)/([^/]+)$")
    if parent and base then return parent .. "/" .. base end
    return path
end

local function shortSummary(event)
    local summary = tostring(event.summary or "")
    if summary == "" then summary = "instruction file changed" end
    -- The absolute path is what the record holds and what the detail rows show; a menu row that
    -- spends forty characters on `/Users/egorloy/` says less, not more. The PARENT stays, though —
    -- half these files are called CLAUDE.md, and a row naming six of them said nothing at all.
    -- `[^%s]` split a path at a space and left a broken prefix; replace the recorded files first.
    local files = event.files
    if type(files) == "table" and #files > 0 then
        for _, file in ipairs(files) do
            if type(file) == "string" and file ~= "" then
                local plain = file:gsub("(%W)", "%%%1")
                summary = summary:gsub(plain, shortPath(file), 1)
            end
        end
    else
        summary = summary:gsub("(/[^;(]+)", function(path)
            local rest = ""
            local arrow = path:find(" %->", 1, true)
            if arrow then
                rest = path:sub(arrow)
                path = path:sub(1, arrow - 1)
            end
            path = path:gsub(" +$", "")
            return shortPath(path) .. rest
        end)
    end
    summary = summary:gsub("%s+", " ")
    return summary
end

-- Idempotent, and safe to call from the watcher, the timer, the hook's poke and a menu click at
-- once: the receipt is what decides, and a record that has one is never delivered twice.
function M.pump()
    ensureWatcher()
    local result = { delivered = 0, alerted = 0, stale = 0 }
    local events = readJournal()
    if #events == 0 then return result end
    if not ensureReceiptDir() then return result end
    local now = os.time()
    local pending = {}
    for _, event in ipairs(events) do
        if not receiptFor(event.id) then pending[#pending + 1] = event end
    end
    local freshTotal = 0
    for _, event in ipairs(pending) do
        local stamp = parseIso(event.at)
        if (stamp == nil) or (now - stamp <= ALERT_MAX_AGE) then
            freshTotal = freshTotal + 1
        end
    end
    local freshIndex = 0
    for _, event in ipairs(pending) do
        local stamp = parseIso(event.at)
        -- Two bounds, both of them there so a Hammerspoon that was off for a day does not open
        -- with a wall of alerts: anything older than the window lands in the menu unannounced,
        -- and a burst past the third FRESH record collapses into one line pointing at the menu.
        -- Stale records used to consume the cap, so a fresh change behind three of them was
        -- receipted collapsed and never shown.
        local fresh = (stamp == nil) or (now - stamp <= ALERT_MAX_AGE)
        local alerted = false
        if fresh then
            freshIndex = freshIndex + 1
            if freshIndex <= ALERT_BURST then
                local ok = pcall(alertFn, "Instruction file changed: " .. shortSummary(event))
                alerted = ok
            elseif freshIndex == ALERT_BURST + 1 then
                local rest = freshTotal - ALERT_BURST
                pcall(alertFn, rest .. " more instruction changes — see Automations ▸ Instruction files")
            end
        end
        local reason = "delivered"
        if not fresh then
            reason = "stale"
            result.stale = result.stale + 1
        elseif not alerted then
            reason = "collapsed"
        end
        local receipt = hs.json.encode({
            at = os.date("!%Y-%m-%dT%H:%M:%SZ", now),
            alerted = alerted,
            reason = reason,
        })
        if writeFile(receiptPath(event.id), receipt) then
            result.delivered = result.delivered + 1
            if alerted then result.alerted = result.alerted + 1 end
        end
    end
    return result
end

-- What the watch set reaches beyond `~/.claude`, read from the cache the hook cuts at session
-- start. Shown because coverage nobody can look at is coverage nobody trusts.
function M.rankedPaths()
    local body = readFile(rankedPath())
    if not body then return {} end
    local paths = {}
    for line in body:gmatch("[^\n]+") do
        -- The cache's first line is the `#<version>` stamp that tells the writer when its own
        -- rules have moved. It is not a watched path and has no business in a coverage list.
        if line ~= "" and line:sub(1, 1) ~= "#" then paths[#paths + 1] = line end
    end
    return paths
end

local function rates()
    local attrs = hs.fs.attributes(ratesPath)
    local stamp = attrs and (tostring(attrs.size) .. "/" .. tostring(attrs.modification)) or "missing"
    if ratesCache and stamp == ratesStamp then return ratesCache end
    local ok, decoded = pcall(hs.json.decode, readFile(ratesPath) or "{}")
    local entries = ok and type(decoded) == "table" and type(decoded.paths) == "table"
        and type(decoded.paths.entries) == "table" and decoded.paths.entries or {}
    local paths, ranks = {}, {}
    for path, entry in pairs(entries) do
        if type(entry) == "table" then paths[#paths + 1] = path end
    end
    local function reads(path)
        local weekly = entries[path].weekly
        return type(weekly) == "table" and tonumber(weekly.reads) or 0
    end
    table.sort(paths, function(a, b)
        local ar, br = reads(a) or 0, reads(b) or 0
        if ar == br then return a < b end
        return ar > br
    end)
    for rank, path in ipairs(paths) do ranks[path] = rank end
    ratesCache, ratesStamp = { entries = entries, ranks = ranks }, stamp
    return ratesCache
end

local function deltas(event)
    if type(event.bytes) ~= "table" or #event.bytes ~= #(event.files or {}) then return {} end
    for key, value in pairs(event.bytes) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #event.bytes
            or type(value) ~= "number" or value % 1 ~= 0 then return {} end
    end
    return event.bytes
end

local function signed(value, price)
    if value == nil then return "" end
    if value == 0 then return "0" end
    local sign = value < 0 and "-" or "+"
    local magnitude = math.abs(value)
    if magnitude >= 10000 then
        return sign .. string.format(price and "%.1fk" or "%.0fk", magnitude / 1000)
    end
    return sign .. string.format("%.0f", magnitude)
end

local function priceText(value)
    return value ~= nil and (signed(value, true) .. " tok/wk") or ""
end

local function filePrice(cache, path, delta)
    local entry = cache.entries[path]
    local loads = type(entry) == "table" and type(entry.weekly) == "table" and entry.weekly.loads
    if delta ~= nil and delta ~= 0 and type(loads) == "number" then
        return delta / CHARS_PER_TOKEN * loads
    end
end

local function cells(text) return utf8.len(text) or #text end
local function pad(text, width, right)
    local spaces = string.rep(" ", math.max(0, width - cells(text)))
    return right and (spaces .. text) or (text .. spaces)
end
local function clip(text, width)
    if cells(text) <= width then return text end
    return "…" .. text:sub(utf8.offset(text, -(width - 1)))
end
local function dimColor()
    local drawing = hs.drawing
    local palette = type(drawing) == "table" and drawing.color
    local asRGB = type(palette) == "table" and palette.asRGB
    if type(asRGB) ~= "function" then return dimColorName end
    local ok, resolved = pcall(asRGB, dimColorName)
    if ok and type(resolved) == "table" then return resolved end
    return dimColorName
end

local function renderStyle()
    local color = dimColor()
    return function(text, dim)
        return hs.styledtext.new(text, { font = menuFont, color = dim and color or nil })
    end
end
local function eventTime(event)
    local stamp = parseIso(event.at)
    return stamp and os.date("%d %b %H:%M", stamp) or "?"
end

local function eventMenu(event, receipt, cache, style)
    local identity = type(event.chat) == "string" and event.chat ~= "" and event.chat or event.sid or "?"
    local items = { { title = style(eventTime(event) .. " · " .. identity), disabled = true } }
    local bytes = deltas(event)
    local modes = { always_on = "always", on_demand = "demand", agent_brief = "brief" }
    for index, file in ipairs(event.files or {}) do
        local parts = { file }
        if bytes[index] ~= nil then parts[#parts + 1] = signed(bytes[index]) end
        local price = filePrice(cache, file, bytes[index])
        if price ~= nil then parts[#parts + 1] = priceText(price) end
        if cache.ranks[file] then parts[#parts + 1] = "#" .. cache.ranks[file] end
        local title = style(table.concat(parts, "  "))
        local entry = cache.entries[file]
        local mode = type(entry) == "table" and modes[entry.mode]
        if mode then title = title .. style("  " .. mode, true) end
        items[#items + 1] = { title = title, disabled = true }
    end
    if receipt then
        items[#items + 1] = { title = "-" }
        items[#items + 1] = {
            title = style((receipt.alerted and "alert shown " or "recorded ") .. tostring(receipt.at or "?")),
            disabled = true,
        }
    end
    items[#items + 1] = { title = "-" }
    items[#items + 1] = {
        title = "Copy command to open this chat",
        fn = function()
            openCommandFn(tostring(event.sid or ""), function(code, stdout, stderr)
                if code ~= 0 then
                    alertFn("no command: " .. ((stderr or ""):match("[^\r\n]+") or "unknown error"), 3)
                    return
                end
                local command, metadata = (stdout or ""):match("^([^\r\n]+)\r?\n([^\r\n]*)")
                command = command or (stdout or ""):match("^[^\r\n]+")
                if not command then alertFn("no command: empty output", 3); return end
                pasteboardFn(command)
                local account = (metadata or ""):match("^account=(%S+) source=fallback$")
                if account then
                    alertFn("copied · account " .. account .. " = last launched, pick unreachable", 2)
                else
                    alertFn("copied", 1)
                end
            end)
        end,
    }
    return items
end

function M.menuItems()
    local events = readJournal()
    local cache, style = rates(), renderStyle()
    local items = {}
    for index = #events, math.max(1, #events - MENU_ROWS + 1), -1 do
        local event = events[index]
        local receipt = receiptFor(event.id)
        local mark = "○"
        if receipt then mark = receipt.alerted and "●" or "◦" end
        local files, bytes = event.files or {}, deltas(event)
        local more = #files > 1 and (" +" .. (#files - 1) .. " more") or ""
        local path = clip(shortPath(files[1] or "?"), FILE_WIDTH - cells(more))
        local fileTitle = style(path) .. style(more, true)
            .. style(string.rep(" ", math.max(0, FILE_WIDTH - cells(path) - cells(more))))
        local totalBytes, totalPrice
        for i, file in ipairs(files) do
            if bytes[i] ~= nil then totalBytes = (totalBytes or 0) + bytes[i] end
            local price = filePrice(cache, file, bytes[i])
            if price ~= nil then totalPrice = (totalPrice or 0) + price end
        end
        items[#items + 1] = {
            title = style(mark .. " " .. pad(eventTime(event), 12) .. "  ") .. fileTitle
                .. style("  " .. pad(signed(totalBytes), BYTE_WIDTH, true)
                    .. "  " .. pad(priceText(totalPrice), PRICE_WIDTH, true)),
            menu = eventMenu(event, receipt, cache, style),
        }
    end
    if #items == 0 then
        items[#items + 1] = { title = "No changes recorded", disabled = true }
    end
    items[#items + 1] = { title = "-" }
    local ranked = M.rankedPaths()
    local coverage = { { title = "~/.claude: settings.json and every guarded markdown",
                         disabled = true } }
    if #ranked > 0 then
        coverage[#coverage + 1] = { title = "-" }
        for _, path in ipairs(ranked) do
            coverage[#coverage + 1] = { title = path, disabled = true }
        end
    else
        coverage[#coverage + 1] = { title = "no ranked project files cached", disabled = true }
    end
    items[#items + 1] = { title = "Coverage", menu = coverage }
    items[#items + 1] = {
        title = "Reveal change log",
        fn = function()
            hs.task.new("/usr/bin/open",
                nil,
                { "-R", (os.getenv("HOME") or "") .. "/.claude/instruction-changes.log" }):start()
        end,
    }
    return items
end

local function journalStamp()
    local attrs = hs.fs.attributes(journalPath())
    if not attrs then return nil end
    return tostring(attrs.size) .. "/" .. tostring(attrs.modification)
end

-- FSEvents on the state directory, which also holds the snapshot and revert copies the hook writes
-- on every change it sees. Those fire this callback too, so the journal's own fingerprint is
-- checked first and an unrelated write costs one stat rather than a parse.
ensureWatcher = function()
    if watcher ~= nil then return end
    if not (hs.pathwatcher and hs.pathwatcher.new) then return end
    if hs.fs.attributes(stateDir, "mode") ~= "directory" then return end
    watcher = hs.pathwatcher.new(stateDir, onChange)
    if watcher then watcher:start() end
end

onChange = function()
    ensureWatcher()
    local stamp = journalStamp()
    if stamp ~= nil and stamp == lastSeen then return end
    lastSeen = stamp
    M.pump()
end

function M.start()
    M.stop()
    lastSeen = journalStamp()
    ensureWatcher()
    -- The fallback, not the mechanism: FSEvents can coalesce or drop across a sleep, and a change
    -- Egor is never told about is the one failure this module exists to remove.
    timer = hs.timer.doEvery(120, onChange)
    M.pump()
    return M
end

function M.stop()
    if watcher then watcher:stop(); watcher = nil end
    if timer then timer:stop(); timer = nil end
end

-- Both exist for the test harness, which runs inside the real Hammerspoon: it points the module at
-- a fixture directory and swaps the screen for a recorder, so proving the transport never puts a
-- line on Egor's display or a receipt in his cache.
function M.setStateDir(dir)
    if watcher then watcher:stop(); watcher = nil end
    stateDir = dir or DEFAULT_STATE
    lastSeen = nil
end

function M.setAlert(fn)
    alertFn = fn or function(text, duration) hs.alert.show(text, duration or 6) end
end

function M.setPasteboard(fn)
    pasteboardFn = fn or function(text) hs.pasteboard.setContents(text) end
end

function M.setOpenCommand(fn)
    openCommandFn = fn or runOpenCommand
end

function M.setRatesPath(path)
    ratesPath, ratesStamp, ratesCache = path or DEFAULT_RATES, nil, nil
end

function M.stateDir() return stateDir end

_G.InstructionWatch = M

-- Started on require rather than by a caller: the hook's poke is `require("instruction-watch")`
-- and nothing else, so the first change of a Hammerspoon session is what installs the watcher.
if _G.hs and _G.hs.pathwatcher then
    pcall(M.start)
end

return M
