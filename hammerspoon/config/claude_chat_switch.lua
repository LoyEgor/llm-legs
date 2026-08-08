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
--
-- Keyboard, screen, focus and dictation belong to chat_gate (canonical home
-- claude-setup/hammerspoon, reached through ~/.hammerspoon like every other module
-- here). Holding its lock for the whole switch is deliberate: from /exit until the
-- resume lands, this tab is mid-handover and nothing else may type into it.

local ClaudeChatSwitch = {}

local ChatGate = require("chat_gate")
local logLine, trimLog = ChatGate.logger("claude_chat_switch")

local terminalAppName = "Terminal"

local pollInterval = 1        -- seconds between pid-alive checks
local maxWaitSeconds = 120    -- passive mode: give up if the chat is still alive after this
local exitGraceSeconds = 15   -- auto mode: /exit was typed; assume it did not take after this
local maxWaitIdle = 300       -- give up if the chat never goes idle
local pasteDelay = 0.25       -- let cmd+V land before Return
local restoreClipboardDelay = 0.35

-- Single in-flight switch. A new switchChat replaces whatever was pending.
local active = nil

local function pidAlive(pid)
    local out = hs.execute("/bin/ps -p " .. tostring(pid) .. " -o pid= 2>/dev/null")
    return out ~= nil and out:match("%d") ~= nil
end

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

-- Auto mode: exit the chat for the user — clear any draft with Ctrl+U, type
-- /exit + Return. The pid watcher then delivers the resume.
--
-- The chat being switched away from may be the one that ARMED the switch (a model
-- handing its own tab to another session), so /exit must not be typed until that
-- turn ends — mid-turn it lands in the composer as queued text and the chat never
-- quits. openWindow owns that wait, including the "shell" rule and the re-read
-- immediately before the first keystroke.
local function typeExit(handle)
    handle:openWindow({
        label = "/exit",
        maxWait = maxWaitIdle,
        tabAlert = "Chat switch failed: Terminal tab for " .. tostring(active.tty) .. " not found",
        focusAlert = "Chat switch failed: target tab did not come frontmost",
        idleAlert = "Chat switch cancelled — chat stayed busy",
        voiceAlert = "Chat switch cancelled — dictation running, /exit not typed",
    }, function()
        handle:runBurst("/exit", {
            { kind = "key", modifiers = {"ctrl"}, key = "u", detail = "Ctrl+U" },
            { kind = "type", value = "/exit", detail = "/exit", delayAfter = 0.25 },
            { kind = "key", modifiers = {}, key = "return", detail = "return" },
        }, "Chat switch failed: focus moved while typing /exit", function()
            active.exitTypedAt = hs.timer.secondsSinceEpoch()
            logLine("exit-typed", "/exit sent to " .. tostring(active.tty))
        end)
    end)
end

-- Deliver once the chat process is gone. The target chat no longer exists, so
-- there is no session status left to wait on - but a live dictation would still
-- eat the Return, which is what skipRegistry keeps.
local function deliverResume(handle)
    local cmd = resumeCommand()
    handle:waitForIdle({
        label = "resume",
        skipRegistry = true,
        -- The chat this tab held is already gone. Giving up on a long dictation
        -- would strand the tab at a bare shell prompt with nothing to resume it,
        -- so a dictation that outlasts the wait is typed through, not cancelled.
        voiceDeadline = "proceed",
    }, function()
        -- With a known tty focusTarget selects the tab itself; without one the
        -- main Terminal window is the only target there is.
        if not handle.ttyPath then
            local app = hs.application.find(terminalAppName)
            local win = app and app:mainWindow()
            if not win then
                handle:fail("give-up", "no Terminal window", "Chat switch failed: no Terminal window")
                return
            end
            app:activate(true)
            win:focus()
        end
        handle:focusTarget({
            label = "resume",
            tabAlert = "Chat switch failed: Terminal tab for " .. tostring(active.tty) .. " not found",
            focusAlert = "Chat switch failed: target tab not focused",
            legacyAlert = "Chat switch failed: Terminal did not come frontmost",
        }, function()
            handle:runBurst("resume", {
                { kind = "key", modifiers = {"ctrl"}, key = "u", detail = "Ctrl+U" },
                { kind = "paste", value = cmd, detail = cmd, delayAfter = pasteDelay },
                { kind = "key", modifiers = {}, key = "return", detail = "return" },
            }, "Chat switch failed: focus moved while pasting resume", function()
                logLine("typed", cmd)
                hs.alert.show("Chat switch → " .. active.profile .. ": resume typed")
                -- release puts the clipboard back; the delay is what keeps the
                -- restore from racing the paste that is still landing.
                handle:after(restoreClipboardDelay, function() handle:release("delivered") end)
            end)
        end)
    end)
end

local function watchForExit(handle)
    active.waited = 0
    active.pollTimer = handle:every(pollInterval, function()
        if not pidAlive(active.pid) then
            logLine("exited", "chat pid " .. active.pid .. " gone after " .. active.waited .. "s")
            handle:stopTimer(active.pollTimer)
            active.pollTimer = nil
            -- The chat can die on its own (Ctrl+C, a crash) while the /exit phase is
            -- still waiting somewhere. Left running, that phase would either sit out
            -- its deadline and cancel a switch already delivered, or wake up and type
            -- /exit over the resume command.
            handle:cancelWaits()
            deliverResume(handle)
            return
        end
        active.waited = active.waited + pollInterval
        if active.tty then
            local exitWaited = active.exitTypedAt
                and hs.timer.secondsSinceEpoch() - active.exitTypedAt or 0
            if active.exitTypedAt and exitWaited >= exitGraceSeconds then
                handle:fail("give-up", "/exit didn't take; chat pid " .. active.pid
                    .. " still alive after " .. exitGraceSeconds .. "s",
                    "Chat switch: /exit didn't take — chat still running")
            end
        elseif active.waited >= maxWaitSeconds then
            handle:fail("give-up", "chat pid " .. active.pid .. " still alive after "
                .. maxWaitSeconds .. "s; user kept working",
                "Chat switch cancelled — chat kept running")
        end
    end)
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

    logLine("armed", string.format("profile=%s session=%s pid=%d cwd=%s %s%s",
        profileName, sessionId == "" and "(fresh)" or sessionId, pid, cwd or "(caller's)",
        tty and ("(auto-exit via " .. tty .. ", grace " .. exitGraceSeconds .. "s)")
            or ("(waiting up to " .. maxWaitSeconds .. "s for chat to exit)"),
        registry and " idle-gated" or ""))
    trimLog()

    -- Cancelled before arming, not replaced by arriving: two switches for
    -- different tabs are different gate keys, so the gate would queue both and
    -- type two resume commands. Only one handover can be pending at a time.
    if active then ClaudeChatSwitch.cancel() end

    -- Built here rather than in onGranted: a switch queued behind a compact or a
    -- trash /resume is armed and WILL run, so pending() must see it and cancel()
    -- must be able to call it off before the lock ever reaches it.
    local mine = {
        profile = profileName,
        sessionId = sessionId,
        cwd = cwd,
        registry = registry,
        pid = pid,
        tty = tty,
    }
    active = mine

    local outcome = ChatGate.acquire({
        owner = "switch",
        key = tostring(tty or pid),
        log = logLine,
        -- The handover owns this tab until the resume lands; anything else typing
        -- into it mid-flight would land in a chat that is quitting.
        keepFocus = true,
        target = {
            registryPath = registry,
            ttyPath = tty,
            termProgram = "Apple_Terminal",
        },
        onDropped = function(reason)
            logLine("dropped", "the queued switch was dropped: " .. tostring(reason))
            if active == mine then active = nil end
        end,
        onGranted = function(handle)
            mine.handle = handle
            active = mine
            if not pidAlive(pid) then
                logLine("already-exited", "chat pid already gone; delivering now")
                deliverResume(handle)
                return
            end
            watchForExit(handle)
            if tty then typeExit(handle) end
        end,
    })
    logLine("gate", "acquire returned " .. outcome)
    return true
end

function ClaudeChatSwitch.cancel()
    if not active then return false end
    local mine = active
    logLine("cancelled", "manual cancel")
    -- Clear first: cancelling the HOLDER releases the lock, which hands it
    -- straight to whatever is queued next - possibly another switch, whose
    -- onGranted sets active. Clearing afterwards would wipe that one instead.
    active = nil
    local cancelled = ChatGate.cancel("switch", tostring(mine.tty or mine.pid))
    return cancelled
end

function ClaudeChatSwitch.pending()
    -- No handle yet = still queued, which is pending in every sense that matters.
    if not active then return nil end
    if active.handle and not active.handle:alive() then return nil end
    return {
        profile = active.profile,
        mode = active.tty and "auto" or "passive",
    }
end

_G.ClaudeChatSwitch = ClaudeChatSwitch

return ClaudeChatSwitch
