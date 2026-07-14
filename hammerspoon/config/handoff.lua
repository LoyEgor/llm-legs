local HandoffGuard = {}

local cachedEnabled = nil
local activeTask = nil

local function readEnabledAsync(callback)
    local script = [[
a=$(defaults -currentHost read com.apple.coreservices.useractivityd ActivityAdvertisingAllowed 2>/dev/null)
b=$(defaults -currentHost read com.apple.coreservices.useractivityd ActivityReceivingAllowed 2>/dev/null)
echo "$a $b"
]]
    local task = hs.task.new("/bin/sh", function(exitCode, stdOut)
        local a, b = tostring(stdOut or ""):match("(%S+)%s+(%S+)")
        callback(exitCode == 0 and a == "1" and b == "1")
    end, { "-c", script })
    task:start()
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
    activeTask = hs.task.new("/bin/sh", function(exitCode)
        if onDone then
            onDone(exitCode == 0)
        end
    end, { "-c", script })
    activeTask:start()
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

-- Bug-fix action: cycle Handoff off then on so a stuck session re-establishes. If it's
-- already off, skip straight to the on phase (nothing to cycle).
function HandoffGuard.reconnect()
    HandoffGuard.refresh(function(enabled)
        local script = enabled == false and onScript or offThenOnScript

        runShellAsync(script, function(ok)
            HandoffGuard.refresh(function(finalEnabled)
                if ok and finalEnabled == true then
                    hs.alert.show("Handoff reconnected")
                else
                    hs.alert.show("Handoff: reconnect failed")
                end
            end)
        end)
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
