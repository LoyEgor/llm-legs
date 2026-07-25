local SidecarConnect = {}

local logPath = hs.configdir .. "/sidecar_connect.log"
local doctorPath = "/Users/egorloy/.local/bin/sidecar-doctor"

local function timestamp()
    return os.date("%Y-%m-%d %H:%M:%S")
end

local function appendLog(line)
    local file = io.open(logPath, "a")
    if not file then
        return
    end
    file:write(line, "\n")
    file:close()
end

local function step(attempt, text)
    local line = timestamp() .. " " .. text
    attempt.lines[#attempt.lines + 1] = line
    appendLog(line)
end

-- The doctor shells out to `sidecar refresh`, which can hang; running it synchronously on
-- the main thread would freeze all Hammerspoon automation. Run it as a task with a hard
-- timeout and append its summary to the attempt trace/log when it lands. Held in a set so
-- the fire-and-forget task is not GC-orphaned before its callback fires.
local doctorTasks = {}

local function runDoctorSummaryAsync(attempt)
    local done = false
    local task, watchdog
    local function finishOnce(summary)
        if done then
            return
        end
        done = true
        if watchdog then
            watchdog:stop()
            watchdog = nil
        end
        if task then
            doctorTasks[task] = nil
            task = nil
        end
        step(attempt, summary)
    end
    task = hs.task.new(doctorPath, function(_, stdOut, stdErr)
        local out = tostring(stdOut or "")
        if out == "" then
            out = tostring(stdErr or "")
        end
        finishOnce("doctor summary:\n" .. out)
    end)
    if not task then
        finishOnce("doctor: failed to start")
        return
    end
    doctorTasks[task] = true
    if not task:start() then
        doctorTasks[task] = nil
        finishOnce("doctor: failed to start")
        return
    end
    watchdog = hs.timer.doAfter(20, function()
        pcall(function() task:terminate() end)
        finishOnce("doctor timed out (>20s)")
    end)
end

local function humanVerdict(message)
    local m = tostring(message or ""):lower()
    if m:find("did not appear", 1, true) then
        return "The Mac started the connection but the iPad screen never came up.",
            "Wake and unlock the iPad, keep it close to the Mac, then click Connect iPad again."
    elseif m:find("add button not found", 1, true) then
        return "macOS System Settings changed layout, so the automated 'Add display' step could not run.",
            "Open System Settings ▸ Displays and add the iPad from the '+' menu manually, and report this so the automation can be updated."
    elseif m:find("no ipad", 1, true) or m:find("no reachable", 1, true) or m:find("no device", 1, true) then
        return "No iPad is being advertised to this Mac right now.",
            "Unlock the iPad on the same Apple ID and Wi-Fi. If it still doesn't appear, use the menu ▸ Handoff item to re-arm advertising, then try again."
    elseif m:find("timeout", 1, true) then
        return "The connection attempt timed out.",
            "Make sure the iPad is awake and nearby, then click Connect iPad again."
    end
    return "Sidecar connection did not complete.",
        "Check that the iPad is unlocked and nearby, then click Connect iPad again. Details are below."
end

local function showFailureDialog(attempt)
    local verdict, suggestion = humanVerdict(attempt.message)
    local raw = table.concat(attempt.lines, "\n")

    if SidecarConnect.lastWebview then
        pcall(function() SidecarConnect.lastWebview:delete() end)
        SidecarConnect.lastWebview = nil
    end

    if hs.webview then
        local view = hs.webview.new({ x = 220, y = 200, w = 720, h = 520 })
        if view then
            local function esc(s)
                return tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
            end
            local html = table.concat({
                "<div style=\"font-family: -apple-system, system-ui; padding: 18px; color: #111;\">",
                "<div style=\"font-size: 18px; font-weight: 600; margin-bottom: 8px;\">Sidecar didn’t connect</div>",
                "<div style=\"font-size: 14px; margin-bottom: 12px;\">", esc(verdict), "</div>",
                "<div style=\"font-size: 14px; font-weight: 600;\">What to try</div>",
                "<div style=\"font-size: 14px; margin-bottom: 16px;\">", esc(suggestion), "</div>",
                "<div style=\"font-size: 12px; color: #666; margin-bottom: 8px;\">Press Esc or click the red button to close this window.</div>",
                "<details><summary style=\"font-size: 13px; cursor: pointer; color: #444;\">Raw diagnostics</summary>",
                "<pre style=\"font: 11px Menlo, monospace; white-space: pre-wrap; color: #333;\">", esc(raw), "</pre></details>",
                "</div>",
            }, "")
            view:windowTitle("Sidecar connect")
            view:windowStyle({ "titled", "closable", "resizable" })
            view:closeOnEscape(true)
            view:deleteOnClose(true)
            view:allowGestures(true)
            view:html(html)
            view:bringToFront(true)
            view:show()
            SidecarConnect.lastWebview = view
            return
        end
    end
    hs.alert.show(verdict)
end

local function finalizeAttempt(attempt, connected, message)
    if attempt.done then
        return
    end
    attempt.done = true
    attempt.connected = connected
    attempt.message = message

    step(attempt, "final verdict: " .. (connected and "CONNECTED" or "FAILED") .. " - " .. tostring(message))

    if attempt.unsubscribeLog then
        attempt.unsubscribeLog()
        attempt.unsubscribeLog = nil
    end
    if attempt.unsubscribeResult then
        attempt.unsubscribeResult()
        attempt.unsubscribeResult = nil
    end

    if connected then
        hs.alert.show("Sidecar: connected")
        return
    end

    local verdict = humanVerdict(message)
    hs.alert.show(verdict)
    showFailureDialog(attempt)
    runDoctorSummaryAsync(attempt)
end

function SidecarConnect.lastAttemptSlice()
    local attempt = SidecarConnect.lastAttempt
    if not attempt then
        return "no attempt recorded yet"
    end
    local verdict = attempt.done and (attempt.connected and "CONNECTED" or "FAILED") or "IN PROGRESS"
    return "verdict: " .. verdict .. "\n" .. table.concat(attempt.lines, "\n")
end

function SidecarConnect.connect()
    if not _G.IpadTrigger or not _G.IpadTrigger.triggerConnect then
        appendLog(timestamp() .. " ERROR: IpadTrigger module not loaded")
        hs.alert.show("Sidecar: IpadTrigger missing")
        return
    end

    local attempt = { lines = {}, done = false }
    SidecarConnect.lastAttempt = attempt

    step(attempt, "menu click: Connect iPad requested")

    attempt.unsubscribeLog = _G.IpadTrigger.onLogLine(function(event, detail)
        step(attempt, "ipad-trigger event: " .. tostring(event) .. " " .. tostring(detail))
    end)
    attempt.unsubscribeResult = _G.IpadTrigger.onResult(function(connected, message)
        finalizeAttempt(attempt, connected, message)
    end)

    local ok, outcome = pcall(_G.IpadTrigger.triggerConnect)

    if not ok then
        step(attempt, "ERROR calling IpadTrigger.triggerConnect: " .. tostring(outcome))
        finalizeAttempt(attempt, false, tostring(outcome))
        return
    end

    step(attempt, "triggerConnect outcome: " .. tostring(outcome))

    if outcome == "already-connected" then
        finalizeAttempt(attempt, true, "already connected")
    elseif outcome == "in-progress" then
        step(attempt, "another connect run is already in flight; this click observes its result")
    end
    -- "started": resultHandler above fires asynchronously once IpadTrigger's own
    -- run/retry/fallback state machine reaches finishSidecarRun().
end

_G.SidecarConnect = SidecarConnect

return SidecarConnect
