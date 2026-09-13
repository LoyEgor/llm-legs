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

local alertFn = function(text)
    hs.alert.show(text, 6)
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

local function copyItem(title, text)
    return {
        title = title,
        fn = function()
            hs.pasteboard.setContents(text)
            hs.alert.show("copied", 1)
        end,
    }
end

local function eventMenu(event, receipt)
    local items = {}
    items[#items + 1] = { title = tostring(event.at or "?") .. " · " .. tostring(event.sid or "?"),
                          disabled = true }
    for _, file in ipairs(event.files or {}) do
        items[#items + 1] = { title = file, disabled = true }
    end
    for _, line in ipairs(event.reverted or {}) do
        items[#items + 1] = { title = "put back: " .. line, disabled = true }
    end
    items[#items + 1] = { title = "-" }
    if receipt then
        items[#items + 1] = {
            title = (receipt.alerted and "alert shown " or "recorded ") .. tostring(receipt.at or "?"),
            disabled = true,
        }
    else
        items[#items + 1] = { title = "sent: " .. tostring(event.sent or "?") .. ", not yet shown",
                              disabled = true }
    end
    items[#items + 1] = { title = "-" }
    items[#items + 1] = copyItem("Copy summary", tostring(event.summary or ""))
    local restores = event.restores or {}
    if #restores > 0 then
        -- COPIED, never run. The writer is as often another chat or a worker as this machine's
        -- owner, and a rollback nobody asked for eats somebody's live work; the command is Egor's
        -- to paste when he has decided that is what he wants.
        items[#items + 1] = copyItem("Copy restore command", table.concat(restores, "\n"))
    end
    return items
end

function M.menuItems()
    local events = readJournal()
    local items = {}
    for index = #events, math.max(1, #events - MENU_ROWS + 1), -1 do
        local event = events[index]
        local receipt = receiptFor(event.id)
        local mark = "○"
        if receipt then mark = receipt.alerted and "●" or "◦" end
        local stamp = parseIso(event.at)
        local when = stamp and os.date("%d %b %H:%M", stamp) or tostring(event.at or "?")
        items[#items + 1] = {
            title = mark .. " " .. when .. "  " .. shortSummary(event),
            menu = eventMenu(event, receipt),
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
    alertFn = fn or function(text) hs.alert.show(text, 6) end
end

function M.stateDir() return stateDir end

_G.InstructionWatch = M

-- Started on require rather than by a caller: the hook's poke is `require("instruction-watch")`
-- and nothing else, so the first change of a Hammerspoon session is what installs the watcher.
if _G.hs and _G.hs.pathwatcher then
    pcall(M.start)
end

return M
