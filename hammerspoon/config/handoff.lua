local HandoffGuard = {}

local cachedEnabled = nil

-- Every live hs.task is held here until its completion callback fires. A single shared slot
-- orphans a task the moment a second one starts (its callback then never runs, and any state
-- machine waiting on it hangs forever) — the exact bug that wedged healCycle behind a
-- concurrent forceEnable.
local activeTasks = {}

local function trackedTask(path, args, onComplete)
    local t
    t = hs.task.new(path, function(exitCode, stdOut, stdErr)
        activeTasks[t] = nil
        if onComplete then
            onComplete(exitCode, stdOut, stdErr)
        end
    end, args)
    if not t then
        return nil
    end
    activeTasks[t] = true
    if not t:start() then
        activeTasks[t] = nil
        return nil
    end
    return t
end

local function readEnabledAsync(callback)
    local script = [[
a=$(defaults -currentHost read com.apple.coreservices.useractivityd ActivityAdvertisingAllowed 2>/dev/null)
b=$(defaults -currentHost read com.apple.coreservices.useractivityd ActivityReceivingAllowed 2>/dev/null)
echo "$a $b"
]]
    local t = trackedTask("/bin/sh", { "-c", script }, function(exitCode, stdOut)
        local a, b = tostring(stdOut or ""):match("(%S+)%s+(%S+)")
        callback(exitCode == 0 and a == "1" and b == "1")
    end)
    if not t then
        callback(false)
    end
end

-- Async, non-blocking refresh of the cached Handoff state — menu code must read
-- isEnabledCached() instead of calling this synchronously.
function HandoffGuard.refresh(callback)
    readEnabledAsync(function(enabled)
        cachedEnabled = enabled
        if callback then
            callback(enabled)
        end
    end)
end

function HandoffGuard.isEnabledCached()
    return cachedEnabled
end

local function runShellAsync(script, onDone)
    local t = trackedTask("/bin/sh", { "-c", script }, function(exitCode)
        if onDone then
            onDone(exitCode == 0)
        end
    end)
    if not t and onDone then
        onDone(false)
    end
end

local onScript = [[
defaults -currentHost write com.apple.coreservices.useractivityd ActivityAdvertisingAllowed -bool true
defaults -currentHost write com.apple.coreservices.useractivityd ActivityReceivingAllowed -bool true
killall useractivityd
]]

local offThenOnScript = [[
defaults -currentHost write com.apple.coreservices.useractivityd ActivityAdvertisingAllowed -bool false
defaults -currentHost write com.apple.coreservices.useractivityd ActivityReceivingAllowed -bool false
killall useractivityd
sleep 1
]] .. onScript

-- Async force-enable (no off phase) — used by the watchdog auto-heal and by reconnect()
-- when Handoff is already off.
function HandoffGuard.forceEnable(onDone)
    runShellAsync(onScript, function(ok)
        HandoffGuard.refresh(function(enabled)
            if _G.Notify and _G.Notify.log then
                _G.Notify.log("Handoff force-enabled (useractivityd restarted)")
            end
            if onDone then
                onDone(ok and enabled == true)
            end
        end)
    end)
end

local sidecarBin = "/Users/egorloy/.local/bin/sidecar"

-- `sidecar refresh` can hang after killall sharingd/rapportd, so cap it: kill at 15s and
-- report not-found. finishOnce guards the terminate path against a late real callback.
local function refreshShowsDevice(cb)
    local done = false
    local t, watchdog
    local function finishOnce(found)
        if done then return end
        done = true
        if watchdog then
            watchdog:stop()
            watchdog = nil
        end
        cb(found)
    end
    t = trackedTask(sidecarBin, { "refresh" }, function(_, out)
        local s = tostring(out or ""):lower()
        finishOnce(s:find("ipad", 1, true) ~= nil or s:find("iphone", 1, true) ~= nil)
    end)
    if not t then
        finishOnce(false)
        return
    end
    watchdog = hs.timer.doAfter(15, function()
        pcall(function() t:terminate() end)
        finishOnce(false)
    end)
end

local function pollForDevice(budgetSeconds, intervalSeconds, done)
    local startedAt = os.time()
    local function tick()
        refreshShowsDevice(function(found)
            if found then
                done(true)
            elseif os.difftime(os.time(), startedAt) >= budgetSeconds then
                done(false)
            else
                hs.timer.doAfter(intervalSeconds, tick)
            end
        end)
    end
    tick()
end

-- Escalating heal that reproduces the manual System Settings Handoff toggle — the only
-- action observed to re-arm Continuity/Sidecar advertising here. Forensics: the manual
-- toggle makes useractivityd re-declare Handoff scan types and sharingd re-arm NearbyInfo
-- advertising, WITHOUT restarting any daemon; a plain defaults write or killall does not
-- reproduce it. So the native step is only a cheap invisible first try; the UI toggle is
-- the proven fallback. Success = a device reappears in `sidecar refresh` (needs a reachable
-- peer, which is exactly what a connect needs anyway).
local uiHelpers = [[
using terms from application "System Events"
    on findCbDesc(el, needle, dleft)
        if dleft < 0 then return missing value
        try
            if role of el is "AXCheckBox" then
                set dsc to description of el
                if dsc is not missing value and dsc contains needle then return el
            end if
        end try
        try
            repeat with k in (UI elements of el)
                set f to my findCbDesc(k, needle, dleft - 1)
                if f is not missing value then return f
            end repeat
        end try
        return missing value
    end findCbDesc
    on findByDesc(el, needle, dleft)
        if dleft < 0 then return missing value
        try
            set dsc to description of el
            if dsc is not missing value and dsc contains needle then return el
        end try
        try
            repeat with k in (UI elements of el)
                set f to my findByDesc(k, needle, dleft - 1)
                if f is not missing value then return f
            end repeat
        end try
        return missing value
    end findByDesc
end using terms from
]]

local uiToggleOffScript = uiHelpers .. [[
tell application "System Settings" to activate
delay 0.5
tell application "System Events"
    tell process "System Settings"
        set frontmost to true
        set sf to my findByDesc(window 1, "search text field", 12)
        if sf is missing value then return "FAIL:no-search"
        set focused of sf to true
        set value of sf to ""
        delay 0.2
        keystroke "Handoff"
        delay 1.5
        key code 36
        delay 2.3
        set cb to my findCbDesc(window 1, "Handoff", 18)
        if cb is missing value then return "FAIL:no-handoff-checkbox"
        set startVal to (value of cb) as integer
        if startVal is 1 then
            click cb
            delay 0.8
            try
                repeat with b in (buttons of sheet 1 of window 1)
                    if (name of b) is not "Cancel" then
                        click b
                        exit repeat
                    end if
                end repeat
            end try
        end if
        return "OFF-OK:start=" & startVal
    end tell
end tell
]]

local uiToggleOnScript = uiHelpers .. [[
tell application "System Settings" to activate
delay 0.3
tell application "System Events"
    tell process "System Settings"
        set frontmost to true
        set cb to my findCbDesc(window 1, "Handoff", 18)
        if cb is missing value then return "FAIL:no-handoff-checkbox-on"
        if ((value of cb) as integer) is 0 then
            click cb
            delay 0.6
        end if
        return "ON-OK"
    end tell
end tell
]]

local nativeReregScript = offThenOnScript .. [[
killall rapportd 2>/dev/null
killall sharingd 2>/dev/null
]]

local healInFlight = false

-- Async so a hung System Settings can never freeze the whole HS main thread (a blocking
-- hs.osascript.applescript would also stall the healCycle watchdog itself, since timers run
-- on that thread). Terminates the osascript at timeoutSec and reports FAIL:timeout.
local function runUiScriptAsync(script, timeoutSec, onDone)
    local done = false
    local t, wd
    local function fin(res)
        if done then return end
        done = true
        if wd then
            wd:stop()
            wd = nil
        end
        onDone(res)
    end
    t = trackedTask("/usr/bin/osascript", { "-e", script }, function(_, out)
        fin((tostring(out or ""):gsub("%s+$", "")))
    end)
    if not t then
        fin("FAIL:task-start")
        return
    end
    wd = hs.timer.doAfter(timeoutSec, function()
        pcall(function() t:terminate() end)
        fin("FAIL:timeout")
    end)
end

-- Guarded so it never launches System Settings just to quit it.
local quitSettingsScript = [[
tell application "System Events"
    if exists (application process "System Settings") then
        tell application "System Settings" to quit
    end if
end tell
]]

local function quitSystemSettings()
    trackedTask("/usr/bin/osascript", { "-e", quitSettingsScript }, nil)
end

function HandoffGuard.healCycle(onDone)
    if healInFlight then
        if onDone then onDone(false, "already-running") end
        return
    end
    healInFlight = true

    local finished = false
    local watchdog

    local function finish(ok, variant)
        if finished then
            return
        end
        finished = true
        if watchdog then
            watchdog:stop()
            watchdog = nil
        end
        healInFlight = false
        quitSystemSettings()
        if _G.Notify and _G.Notify.log then
            _G.Notify.log("Handoff healCycle -> " .. tostring(variant) .. " ok=" .. tostring(ok))
        end
        HandoffGuard.refresh()
        if onDone then onDone(ok, variant) end
    end

    -- Hard stop: any stall in the chain below still resolves the caller and clears
    -- healInFlight, so a hung heal can never wedge a connect run.
    watchdog = hs.timer.doAfter(120, function()
        finish(false, "timeout")
    end)

    runShellAsync(nativeReregScript, function()
        if finished then return end
        pollForDevice(12, 4, function(found)
            if finished then return end
            if found then
                finish(true, "native")
                return
            end

            runUiScriptAsync(uiToggleOffScript, 30, function(offResult)
                if finished then return end
                hs.timer.doAfter(5, function()
                    if finished then return end
                    runUiScriptAsync(uiToggleOnScript, 20, function(onResult)
                        if finished then return end
                        if onResult:find("FAIL", 1, true) then
                            runShellAsync(onScript)
                        end
                        pollForDevice(40, 5, function(found2)
                            if found2 then
                                finish(true, "ui-toggle")
                            else
                                finish(false, "ui-attempted off=" .. offResult .. " on=" .. onResult)
                            end
                        end)
                    end)
                end)
            end)
        end)
    end)
end

-- Menu "Handoff" action: run the proven heal cycle. The old defaults+killall reconnect
-- could not re-arm advertising (see healCycle notes), which is why the button appeared to
-- do nothing / error.
function HandoffGuard.reconnect()
    hs.alert.show("Handoff: healing…")
    HandoffGuard.healCycle(function(ok)
        if ok then
            hs.alert.show("Sidecar discovery restored")
        else
            hs.alert.show("Handoff re-armed — iPad still not visible (asleep/away?)")
        end
    end)
end

HandoffGuard.initTimer = hs.timer.doAfter(0, function()
    HandoffGuard.refresh()
end)

HandoffGuard.watchdogTimer = hs.timer.doEvery(600, function()
    HandoffGuard.refresh(function(enabled)
        if enabled == false then
            HandoffGuard.forceEnable(function(ok)
                if ok then
                    hs.alert.show("Handoff was off — re-enabled")
                end
            end)
        end
    end)
end)

_G.HandoffGuard = HandoffGuard

return HandoffGuard
