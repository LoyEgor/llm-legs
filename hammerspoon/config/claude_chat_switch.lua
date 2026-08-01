-- claude_chat_switch.lua — relaunch a Claude Code chat under a different claudeb
-- profile, or hand a Terminal tab over to another chat entirely, once the chat
-- currently in that tab exits.
--
-- A claude process cannot re-exec itself onto another account or another session, so
-- bin/claude-chat-switch resolves the target and hands (profile, sessionId, pid) here.
-- This module is the outside actor: it WAITS for that pid to die (the user exiting the
-- chat), then types `[cd <cwd> && ]claudeb profile <profile> --resume <sessionId>` +
-- Return into Terminal. It never kills anything and never touches ClaudeContinue's
-- timers — all state below is private.

local ClaudeChatSwitch = {}

local gptVoiceKeys = require("gpt_voice_keys")

local terminalAppName = "Terminal"
local logPath = os.getenv("HOME") .. "/.hammerspoon/claude_chat_switch.log"

local pollInterval = 1        -- seconds between pid-alive checks
local maxWaitSeconds = 120    -- passive mode: give up if the chat is still alive after this
local exitGraceSeconds = 15   -- auto mode: /exit was typed; assume it did not take after this
local idlePollInterval = 0.5  -- seconds between sessions-registry status reads
local idleShellSettle = 5     -- a "shell" status this stable counts as deliverable
local maxWaitIdle = 300       -- give up if the chat never goes idle
local focusDelay = 0.35       -- let Terminal come frontmost before typing
local pasteDelay = 0.25       -- let cmd+V land before Return
local restoreClipboardDelay = 0.35
local relockRetry = 300       -- re-check every 5 min while the screen stays locked

-- Single in-flight switch. A new switchChat cancels whatever was pending.
local active = nil            -- { profile, sessionId, cwd, registry, pid, waited, pollTimer, lockWatcher, retryTimer }

local function logLine(event, detail)
    local stamp = os.date("%Y-%m-%d %H:%M:%S")
    local line = string.format("%s  %-16s %s", stamp, event, tostring(detail or ""))
    print("[claude-chat-switch]", event, detail or "")
    local f = io.open(logPath, "a")
    if f then
        f:write(line, "\n")
        f:close()
    end
end

local function trimLog()
    local f = io.open(logPath, "r")
    if not f then return end
    local lines = {}
    for line in f:lines() do lines[#lines + 1] = line end
    f:close()
    if #lines <= 200 then return end
    local out = io.open(logPath, "w")
    if not out then return end
    for i = #lines - 199, #lines do out:write(lines[i], "\n") end
    out:close()
end

-- Unlocked screens omit CGSSessionScreenIsLocked; it is true only when locked, and
-- eventtap keystrokes sent to a locked screen are silently dropped.
local function screenIsLocked()
    local ok, props = pcall(hs.caffeinate.sessionProperties)
    if not ok or type(props) ~= "table" then return false end
    return props["CGSSessionScreenIsLocked"] == true
end

local function pidAlive(pid)
    local out = hs.execute("/bin/ps -p " .. tostring(pid) .. " -o pid= 2>/dev/null")
    return out ~= nil and out:match("%d") ~= nil
end

local function frontmostIsTerminal()
    local front = hs.application.frontmostApplication()
    return front ~= nil and front:name() == terminalAppName
end

local function cleanup()
    if not active then return end
    if active.pollTimer then active.pollTimer:stop() end
    if active.idleTimer then active.idleTimer:stop() end
    if active.retryTimer then active.retryTimer:stop() end
    if active.lockWatcher then active.lockWatcher:stop() end
    active = nil
end

local function registryStatus(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    local ok, value = pcall(hs.json.decode, content)
    if not ok or type(value) ~= "table" then return nil end
    return value.status
end

-- The chat being switched away from may be the one that ARMED the switch (a model
-- handing its own tab to another session), so /exit must not be typed until that
-- turn ends — mid-turn it lands in the composer as queued text and the chat never
-- quits. Same idle signal claude_compact.lua waits on, including the "shell"
-- rule: a live background shell masks "idle" indefinitely, so a stable "shell"
-- counts as deliverable too.
local function waitForIdle(onIdle)
    if not active.registry then onIdle(); return end
    local waited, shellSince = 0, nil
    active.idleTimer = hs.timer.doEvery(idlePollInterval, function()
        if not active then return end
        local status = registryStatus(active.registry)
        shellSince = (status == "shell") and (shellSince or waited) or nil
        if status == "idle" or (shellSince and waited - shellSince >= idleShellSettle) then
            active.idleTimer:stop()
            active.idleTimer = nil
            logLine("idle", "session " .. tostring(status) .. " after " .. waited .. "s")
            onIdle()
            return
        end
        waited = waited + idlePollInterval
        if waited >= maxWaitIdle then
            logLine("give-up", "chat never went idle within " .. maxWaitIdle .. "s (status "
                .. tostring(status) .. ")")
            hs.alert.show("Chat switch cancelled — chat stayed busy")
            cleanup()
        end
    end)
end

local function retryAfterUnlock()
    if not active or screenIsLocked() then return end
    local retry = active.lockRetry
    active.lockRetry = nil
    if active.retryTimer then active.retryTimer:stop(); active.retryTimer = nil end
    if active.lockWatcher then active.lockWatcher:stop(); active.lockWatcher = nil end
    if retry then retry() end
end

local function deferUntilUnlocked(detail, retry)
    logLine("locked-deferred", detail)
    active.lockRetry = retry
    if not active.lockWatcher then
        active.lockWatcher = hs.caffeinate.watcher.new(function(event)
            if event == hs.caffeinate.watcher.systemDidWake
                or event == hs.caffeinate.watcher.screensDidWake
                or event == hs.caffeinate.watcher.screensDidUnlock
                or event == hs.caffeinate.watcher.sessionDidBecomeActive then
                retryAfterUnlock()
            end
        end)
        active.lockWatcher:start()
    end
    if not active.retryTimer then
        active.retryTimer = hs.timer.doEvery(relockRetry, retryAfterUnlock)
    end
end

local function selectTabByTty(tty)
    local script = string.format([[
tell application "Terminal"
    activate
    repeat with terminalWindow in windows
        repeat with terminalTab in tabs of terminalWindow
            if (tty of terminalTab as text) is %q then
                set selected of terminalTab to true
                set index of terminalWindow to 1
                return true
            end if
        end repeat
    end repeat
    return false
end tell
]], tty)
    local callOk, ok, result = pcall(hs.osascript.applescript, script)
    return callOk and ok and result == true
end

-- A live user can steal focus between any two keystrokes; every keystroke below is
-- gated on the target tab still being the focused one, so a lost race aborts
-- cleanly instead of typing into whatever came frontmost.
local function focusedOnTarget()
    if not active or not active.tty then return false end
    if not frontmostIsTerminal() then return false end
    local callOk, ok, result = pcall(hs.osascript.applescript, [[
tell application "Terminal"
    if (count of windows) is 0 then return ""
    return tty of selected tab of front window as text
end tell
]])
    return callOk and ok and result == active.tty
end

-- Auto mode: exit the chat for the user — select the target tab by tty, clear any
-- draft with Ctrl+U, type /exit + Return. The pid watcher then delivers the resume.
local function typeExit()
    if screenIsLocked() then
        deferUntilUnlocked("screen locked; will retry /exit on unlock", typeExit)
        return
    end
    -- The idle this was granted can be minutes old: a locked screen defers the whole
    -- burst, and the chat is free to start another turn meanwhile. Re-read it here,
    -- immediately before the first keystroke. "shell" is left alone — waitForIdle
    -- already accepted it, and it can stay that way for as long as a dev server runs.
    if active.registry and registryStatus(active.registry) == "busy" then
        logLine("re-busy", "session busy again before /exit; back to waiting")
        waitForIdle(typeExit)
        return
    end
    if not selectTabByTty(active.tty) then
        logLine("give-up", "target tab not found for " .. active.tty)
        hs.alert.show("Chat switch failed: Terminal tab for " .. active.tty .. " not found")
        cleanup()
        return
    end
    hs.timer.doAfter(focusDelay, function()
        if not active then return end
        if not focusedOnTarget() then
            logLine("give-up", "target tab did not come frontmost for /exit")
            hs.alert.show("Chat switch failed: target tab did not come frontmost")
            cleanup()
            return
        end
        hs.eventtap.keyStroke({"ctrl"}, "u")
        hs.eventtap.keyStrokes("/exit")
        hs.timer.doAfter(0.25, function()
            if not active then return end
            if not focusedOnTarget() then
                logLine("give-up", "focus moved while typing /exit; Return not sent")
                hs.alert.show("Chat switch failed: focus moved while typing /exit")
                cleanup()
                return
            end
            gptVoiceKeys.returnKey()
            active.exitTypedAt = hs.timer.secondsSinceEpoch()
            logLine("exit-typed", "/exit sent to " .. active.tty)
        end)
    end)
end

-- Type the resume command into Terminal via clipboard paste (more reliable than raw
-- keystrokes), saving and restoring the user's clipboard around it.
local function shellQuote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function resumeCommand()
    local cmd = "claudeb profile " .. active.profile
    if active.sessionId ~= "" then
        cmd = cmd .. " --resume " .. active.sessionId
    end
    -- A session is resumable only from the directory it was started in: claude
    -- looks for the transcript under the project slug of the CURRENT cwd.
    if active.cwd then
        cmd = "cd " .. shellQuote(active.cwd) .. " && " .. cmd
    end
    return cmd
end

local function typeCommand()
    local cmd = resumeCommand()

    local app = hs.application.find(terminalAppName)
    if not app then
        logLine("give-up", "Terminal not found")
        hs.alert.show("Chat switch failed: Terminal not found")
        cleanup()
        return
    end
    local win = app:mainWindow()
    if not win then
        logLine("give-up", "no Terminal window")
        hs.alert.show("Chat switch failed: no Terminal window")
        cleanup()
        return
    end

    -- With a known tty prefer targeted tab selection; fall back to the main window.
    if not (active.tty and selectTabByTty(active.tty)) then
        app:activate(true)
        win:focus()
    end

    hs.timer.doAfter(focusDelay, function()
        if not active then return end
        if not frontmostIsTerminal() then
            logLine("give-up", "Terminal did not come frontmost")
            hs.alert.show("Chat switch failed: Terminal did not come frontmost")
            cleanup()
            return
        end
        if active.tty and not focusedOnTarget() then
            logLine("give-up", "target tab not focused for resume")
            hs.alert.show("Chat switch failed: target tab not focused")
            cleanup()
            return
        end

        hs.eventtap.keyStroke({"ctrl"}, "u")

        local snapshotOk, snapshot = pcall(hs.pasteboard.readAllData)
        local clip = snapshotOk and snapshot or nil

        hs.pasteboard.setContents(cmd)
        hs.eventtap.keyStroke({"cmd"}, "v")

        hs.timer.doAfter(pasteDelay, function()
            if not active then return end
            if active.tty and not focusedOnTarget() then
                logLine("give-up", "focus moved while pasting resume; Return not sent")
                hs.alert.show("Chat switch failed: focus moved while pasting resume")
                if clip then pcall(hs.pasteboard.writeAllData, clip) end
                cleanup()
                return
            end
            gptVoiceKeys.returnKey()
            logLine("typed", cmd)
            hs.alert.show("Chat switch → " .. active.profile .. ": resume typed")

            hs.timer.doAfter(restoreClipboardDelay, function()
                if clip then pcall(hs.pasteboard.writeAllData, clip) end
                cleanup()
            end)
        end)
    end)
end

-- Deliver once the chat process is gone. Lock-aware: if the screen is locked the
-- keystrokes would be dropped, so defer and retry on unlock (and every relockRetry).
local function deliver()
    if screenIsLocked() then
        deferUntilUnlocked("screen locked; will retry delivery on unlock", deliver)
        return
    end
    typeCommand()
end

-- ttyDev present = auto mode (menu path, and a chat handing over its own tab):
-- this module types /exit itself and only waits exitGraceSeconds. Absent = legacy
-- passive mode (the user exits the chat).
-- opts.cwd      — directory to cd into before resuming (a foreign session's own cwd)
-- opts.registry — ~/.claude/sessions/<pid>.json of the chat being replaced; when
--                 given, /exit waits for that chat to go idle first.
function ClaudeChatSwitch.switchChat(profileName, sessionId, terminalPid, ttyDev, opts)
    if type(profileName) ~= "string" or profileName == ""
        or type(sessionId) ~= "string" then
        logLine("error", "switchChat needs (profile, sessionId, pid)")
        return false
    end
    local pid = tonumber(terminalPid)
    if not pid then
        logLine("error", "switchChat: bad pid " .. tostring(terminalPid))
        return false
    end
    opts = type(opts) == "table" and opts or {}
    local cwd = (type(opts.cwd) == "string" and opts.cwd ~= "") and opts.cwd or nil
    local registry = (type(opts.registry) == "string" and opts.registry ~= "") and opts.registry or nil
    local tty = (type(ttyDev) == "string" and ttyDev ~= "") and ttyDev or nil
    -- Empty sessionId = relaunch as a fresh chat; only the auto (menu) path may ask
    -- for that — the legacy path always resumes.
    if sessionId == "" and not tty then
        logLine("error", "switchChat: empty sessionId requires auto mode")
        return false
    end

    if active then
        logLine("replaced", "cancelling prior pending switch for pid " .. tostring(active.pid))
        cleanup()
    end

    active = {
        profile = profileName,
        sessionId = sessionId,
        cwd = cwd,
        registry = registry,
        pid = pid,
        tty = tty,
        waited = 0,
    }
    logLine("armed", string.format("profile=%s session=%s pid=%d cwd=%s %s%s",
        profileName, sessionId == "" and "(fresh)" or sessionId, pid, cwd or "(caller's)",
        tty and ("(auto-exit via " .. tty .. ", grace " .. exitGraceSeconds .. "s)")
            or ("(waiting up to " .. maxWaitSeconds .. "s for chat to exit)"),
        registry and " idle-gated" or ""))
    trimLog()

    if not pidAlive(pid) then
        logLine("already-exited", "chat pid already gone; delivering now")
        deliver()
        return true
    end

    active.pollTimer = hs.timer.doEvery(pollInterval, function()
        if not active then return end
        if not pidAlive(active.pid) then
            logLine("exited", "chat pid " .. active.pid .. " gone after " .. active.waited .. "s")
            active.pollTimer:stop()
            active.pollTimer = nil
            -- The chat can die on its own (Ctrl+C, a crash) while the idle wait is
            -- still polling. Its registry then never reports idle again, so that
            -- timer would either sit out maxWaitIdle and cancel a switch already
            -- delivered, or win a race and type /exit over the resume command.
            if active.idleTimer then
                active.idleTimer:stop()
                active.idleTimer = nil
            end
            deliver()
            return
        end
        active.waited = active.waited + pollInterval
        if active.tty then
            local exitWaited = active.exitTypedAt
                and hs.timer.secondsSinceEpoch() - active.exitTypedAt or 0
            if active.exitTypedAt and exitWaited >= exitGraceSeconds then
                logLine("give-up", "/exit didn't take; chat pid " .. active.pid
                    .. " still alive after " .. exitGraceSeconds .. "s")
                hs.alert.show("Chat switch: /exit didn't take — chat still running")
                cleanup()
            end
        elseif active.waited >= maxWaitSeconds then
            logLine("give-up", "chat pid " .. active.pid .. " still alive after "
                .. maxWaitSeconds .. "s; user kept working")
            hs.alert.show("Chat switch cancelled — chat kept running")
            cleanup()
        end
    end)

    if tty then
        -- Identity, not existence: a switch armed in this gap replaces `active`, and
        -- starting an idle wait against THAT one would leave two timers polling with
        -- only the newer stored — the orphan then types /exit on its own schedule.
        local armed = active
        hs.timer.doAfter(0.05, function()
            if active == armed then waitForIdle(typeExit) end
        end)
    end
    return true
end

function ClaudeChatSwitch.cancel()
    if active then
        logLine("cancelled", "manual cancel")
        cleanup()
        return true
    end
    return false
end

function ClaudeChatSwitch.pending()
    if not active then return nil end
    return {
        profile = active.profile,
        mode = active.tty and "auto" or "passive",
    }
end

_G.ClaudeChatSwitch = ClaudeChatSwitch

return ClaudeChatSwitch
