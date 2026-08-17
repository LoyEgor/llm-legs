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
-- here). The handover is one gate JOB: it claims this tab from /exit until the resume
-- lands, so nothing else may start an operation on a chat that is quitting. The waits
-- in between hold nothing - every keystroke goes out inside its own burst, and the
-- keyboard goes back the moment that burst is over.

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
local dialogMarker = "Background work is running"
local dialogSettleSeconds = 2 -- let /exit render its answer before reading the screen
local confirmRetrySeconds = 5 -- a pressed Return needs this long to visibly take
local confirmMaxPresses = 2
local confirmPressDeadline = 5 -- a press still pending after this is deferred, not slow
-- The whole handover on the wall clock: the idle wait before /exit, the graces the
-- exit wall spends after it, and the resume behind them.
local switchHorizon = maxWaitIdle + 600

-- Single in-flight switch. A new switchChat replaces whatever was pending.
local active = nil

local function pidAlive(pid)
    local out = hs.execute("/bin/ps -p " .. tostring(pid) .. " -o pid= 2>/dev/null")
    return out ~= nil and out:match("%d") ~= nil
end

local function shellQuote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function resumeCommand(entry)
    local cmd = "claudeb profile " .. entry.profile
    if entry.sessionId ~= "" then
        cmd = cmd .. " --resume " .. entry.sessionId
    end
    if entry.cwd then
        cmd = "cd " .. shellQuote(entry.cwd) .. " && " .. cmd
    end
    return cmd
end

local function tabContents(tty)
    local quoted = '"' .. tty:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
    local callOk, ok, result = pcall(hs.osascript.applescript, [[
tell application "Terminal"
    repeat with w from 1 to count of windows
        repeat with t from 1 to count of tabs of window w
            if (tty of tab t of window w as text) is ]] .. quoted .. [[ then
                return contents of tab t of window w
            end if
        end repeat
    end repeat
    return ""
end tell
]])
    if not callOk or not ok or type(result) ~= "string" then
        -- Once per switch, not per tick: a Terminal without Automation consent
        -- fails identically every second for the whole grace.
        if active and not active.contentsErrorLogged then
            active.contentsErrorLogged = true
            local detail = not callOk and ok or result
            logLine("applescript-error", "tabContents: "
                .. (type(detail) == "table" and hs.inspect(detail) or tostring(detail)))
        end
        return nil
    end
    return result
end

-- One Enter, typed inside its own burst, with the dictation gate the burst brings.
-- The burst is remembered because asking for the keyboard is not getting it: a request
-- still in line when the chat exits on its own would otherwise be granted afterwards
-- and press Return into the resume it was queued ahead of.
local function pressEnter(job, label, alertText, onSent)
    local mine = active
    local token = {}
    mine.enterToken = token
    local sent = false
    local queued = job:burst({
        label = label,
        check = function(burst)
            if active ~= mine or mine.enterToken ~= token then
                burst:done(label .. " is no longer wanted")
                return false
            end
            return true
        end,
    }, function(burst)
        job:pressOnce(label, {}, "return", alertText, function()
            sent = true
            if mine.enterToken == token then
                mine.enterToken, mine.enterBurst = nil, nil
            end
            burst:done(label .. " sent")
            onSent()
        end)
    end)
    if not sent then mine.enterBurst = queued end
end

-- Everything this switch has asked the keyboard for and no longer wants. A request still
-- in line is dropped out of it: granted afterwards it would type into whatever the tab
-- holds by then - a bare shell, or the resume this switch has just delivered.
local function dropPendingKeys(mine, reason)
    local enter, exit = mine.enterBurst, mine.exitBurst
    mine.enterToken, mine.enterBurst, mine.exitBurst = nil, nil, nil
    if enter then enter:done(reason) end
    if exit then exit:done(reason) end
end

-- /exit does not always exit: with background work running (shells, tasks,
-- agents) Claude keeps the chat alive and shows a "Background work is running"
-- picker instead. Asking for the switch already answered it - nothing in the
-- old chat is worth keeping - and "Exit anyway" is the picker's first, default
-- option, so one Return chooses it. Terminal's `contents of tab` is the visible
-- screen, not the scrollback (`history` is that), so a marker match means the
-- picker is up NOW - and a stray Return costs an empty line, while a missed
-- dialog costs the whole switch. Answers whether a confirm is in flight this tick.
local function maybeConfirmExitDialog(job)
    local mine = active
    if mine.confirmInFlight then
        -- A press normally lands within the tick it was asked in; one still
        -- pending after this long sits behind a locked screen or another burst.
        -- Handing the tick back lets the grace give the switch up on schedule -
        -- the pending Return then dies with the job instead of firing into
        -- whatever is on screen once it comes free.
        return hs.timer.secondsSinceEpoch() - mine.confirmStartedAt < confirmPressDeadline
    end
    if (mine.confirmPresses or 0) >= confirmMaxPresses then return false end
    local sinceExit = hs.timer.secondsSinceEpoch() - mine.exitTypedAt
    if sinceExit < dialogSettleSeconds then return false end
    if mine.confirmedAt
        and hs.timer.secondsSinceEpoch() - mine.confirmedAt < confirmRetrySeconds then
        return false
    end
    local contents = tabContents(mine.tty)
    if not contents then return false end
    if not contents:find(dialogMarker, 1, true) then return false end
    mine.confirmInFlight = true
    mine.confirmStartedAt = hs.timer.secondsSinceEpoch()
    pressEnter(job, "exit-confirm",
        "Chat switch failed: focus moved while confirming exit", function()
            mine.confirmInFlight = false
            mine.confirmPresses = (mine.confirmPresses or 0) + 1
            mine.confirmedAt = hs.timer.secondsSinceEpoch()
            -- The chat only STARTS exiting now; it deserves the full grace again.
            mine.exitTypedAt = mine.confirmedAt
            logLine("exit-confirmed", "chose 'Exit anyway' on the background-work dialog")
        end)
    return true
end

-- Auto mode: exit the chat for the user — clear any draft with Ctrl+U, type
-- /exit + Return. The pid watcher then delivers the resume.
--
-- The chat being switched away from may be the one that ARMED the switch (a model
-- handing its own tab to another session), so /exit must not be typed until that
-- turn ends — mid-turn it lands in the composer as queued text and the chat never
-- quits. waitForIdle owns that wait, including the "shell" rule and the re-read
-- immediately before it lets go; the burst re-establishes the rest.
local function typeExit(job)
    local mine = active
    job:waitForIdle({
        label = "/exit",
        maxWait = maxWaitIdle,
        idleAlert = "Chat switch cancelled — chat stayed busy",
    }, function()
        local typed = false
        local queued = job:burst({
            label = "/exit",
            tabAlert = "Chat switch failed: Terminal tab for " .. tostring(mine.tty) .. " not found",
            focusAlert = "Chat switch failed: target tab did not come frontmost",
            voiceAlert = "Chat switch cancelled — dictation running, /exit not typed",
            -- The chat can quit on its own (Ctrl+C, a crash) while this request is still
            -- standing in line. Granted after that, it would clear the line of a bare
            -- shell and run /exit as a command - over the resume this switch has by then
            -- already typed into the tab.
            check = function(burst)
                if active == mine and pidAlive(mine.pid) then return true end
                logLine("exit-dropped", "the chat was already gone when the keyboard came free")
                burst:done("the chat is already gone")
                return false
            end,
        }, function(burst)
            job:runBurst("/exit", {
                { kind = "key", modifiers = {"ctrl"}, key = "u", detail = "Ctrl+U" },
                { kind = "type", value = "/exit", detail = "/exit", delayAfter = 0.25 },
                { kind = "key", modifiers = {}, key = "return", detail = "return" },
            }, "Chat switch failed: focus moved while typing /exit", function()
                typed = true
                mine.exitBurst = nil
                mine.exitTypedAt = hs.timer.secondsSinceEpoch()
                logLine("exit-typed", "/exit sent to " .. tostring(mine.tty))
                -- The keyboard goes back with the Enter: what is left is watching the
                -- chat quit, and every answer to the picker asks for it again itself.
                burst:done("/exit typed")
            end)
        end)
        if not typed then mine.exitBurst = queued end
    end)
end

-- Deliver once the chat process is gone. The target chat no longer exists, so
-- there is no session status left to wait on - but a live dictation would still
-- eat the Return, which is what skipRegistry keeps.
local function deliverResume(job)
    local cmd = resumeCommand(active)
    job:waitForIdle({
        label = "resume",
        skipRegistry = true,
    }, function()
        job:burst({
            label = "resume",
            -- The chat this tab held is already gone. Giving up on a long dictation
            -- would strand the tab at a bare shell prompt with nothing to resume it,
            -- so a dictation that outlasts the wait is typed through, not cancelled.
            voiceDeadline = "proceed",
            tabAlert = "Chat switch failed: Terminal tab for " .. tostring(active.tty) .. " not found",
            focusAlert = "Chat switch failed: target tab not focused",
            legacyAlert = "Chat switch failed: Terminal did not come frontmost",
            -- With a known tty the burst selects the tab itself; without one the main
            -- Terminal window is the only target there is, and raising it is a focus
            -- move, so it happens here - inside the slot, one step before the guard
            -- that judges what is frontmost.
            check = function()
                if job.ttyPath then return true end
                local app = hs.application.find(terminalAppName)
                local win = app and app:mainWindow()
                if not win then
                    job:fail("give-up", "no Terminal window", "Chat switch failed: no Terminal window")
                    return false
                end
                app:activate(true)
                win:focus()
                return true
            end,
        }, function(burst)
            job:runBurst("resume", {
                { kind = "key", modifiers = {"ctrl"}, key = "u", detail = "Ctrl+U" },
                { kind = "paste", value = cmd, detail = cmd, delayAfter = pasteDelay },
                { kind = "key", modifiers = {}, key = "return", detail = "return" },
            }, "Chat switch failed: focus moved while pasting resume", function()
                logLine("typed", cmd)
                hs.alert.show("Chat switch → " .. active.profile .. ": resume typed")
                -- The keyboard goes back with the Return; what is left is the clipboard,
                -- and the delay before putting it back is what keeps that restore from
                -- racing the paste still landing - a wait, and nothing waits holding the
                -- keyboard.
                burst:done("resume typed")
                job:after(restoreClipboardDelay, function() job:finish("delivered") end)
            end)
        end)
    end)
end

local function watchForExit(job)
    active.waited = 0
    active.pollTimer = job:every(pollInterval, function()
        if not pidAlive(active.pid) then
            if active.wallEnterPressed then
                logLine("exit-wall-passed", "chat exited after the exit wall; Enter "
                    .. (active.wallEnterSent and "went out" or "never went out"))
            end
            logLine("exited", "chat pid " .. active.pid .. " gone after " .. active.waited .. "s")
            job:stopTimer(active.pollTimer)
            active.pollTimer = nil
            -- The chat can die on its own (Ctrl+C, a crash) while the /exit phase is
            -- still waiting somewhere. Left running, that phase would either sit out
            -- its deadline and cancel a switch already delivered, or wake up and type
            -- /exit over the resume command.
            job:cancelWaits()
            dropPendingKeys(active, "the chat exited")
            deliverResume(job)
            return
        end
        active.waited = active.waited + pollInterval
        if active.tty then
            if active.exitTypedAt then
                -- One Enter in flight at a time, whichever queued it: a second one
                -- answers nothing and lands in whatever the tab shows after the picker.
                if not active.wallEnterPressed and maybeConfirmExitDialog(job) then return end
                local exitWaited = hs.timer.secondsSinceEpoch() - active.exitTypedAt
                if exitWaited >= exitGraceSeconds then
                    if active.confirmInFlight then
                        -- A confirm press still pending this far past its deadline is
                        -- waiting on something that is not coming; giving up on schedule
                        -- is what lets it die with the job instead of firing once that
                        -- clears, so the wall must not answer over it.
                        job:fail("give-up", "chat pid " .. active.pid .. " still alive "
                            .. active.waited .. "s total; the exit-confirm Enter never landed",
                            "Chat switch: chat did not exit — the exit dialog was never answered")
                    elseif not active.wallEnterPressed then
                        -- maybeConfirmExitDialog only answers a picker it can read and
                        -- recognise; a grace running out is the second, blind signal
                        -- that one is up, so answer it once and judge the chat on a
                        -- fresh grace. That grace restarts HERE, not just in the press
                        -- callback: the poll keeps ticking while the burst waits for the
                        -- keyboard and would give up before the Enter ever went out.
                        active.wallEnterPressed = true
                        active.exitTypedAt = hs.timer.secondsSinceEpoch()
                        logLine("exit-wall", "pid still alive " .. math.floor(exitWaited)
                            .. "s after /exit; answering the background-work dialog blind")
                        pressEnter(job, "exit-wall",
                            "Chat switch failed: focus moved while answering the exit dialog",
                            function()
                                active.wallEnterSent = true
                                active.exitTypedAt = hs.timer.secondsSinceEpoch()
                            end)
                    else
                        logLine("exit-wall-unpassed", "pid " .. active.pid .. " still alive "
                            .. active.waited .. "s total; Enter "
                            .. (active.wallEnterSent and "went out" or "never went out"))
                        job:fail("give-up", "chat pid " .. active.pid
                            .. " still alive after the exit-wall Enter",
                            "Chat switch: chat did not exit — background work still running")
                    end
                end
            end
        elseif active.waited >= maxWaitSeconds then
            job:fail("give-up", "chat pid " .. active.pid .. " still alive after "
                .. maxWaitSeconds .. "s; user kept working",
                "Chat switch cancelled — chat kept running")
        end
    end)
end

-- ttyDev present = auto mode (menu path, and a chat handing over its own tab):
-- this module types /exit itself and only waits exitGraceSeconds. Absent = legacy
-- passive mode (the user exits the chat).
-- opts.cwd         — directory to cd into before resuming (the target's own cwd)
-- opts.registry    — ~/.claude/sessions/<pid>.json of the chat being replaced; when
--                    given, /exit waits for that chat to go idle first.
-- opts.freshReason — why an empty sessionId is empty; said out loud, because losing
--                    a conversation to a fresh chat is the failure worth hearing.
-- opts.note        — what the resolution had to guess at (an ambiguous session id, a
--                    transcript that records a directory outside its own project).
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
    if type(opts.note) == "string" and opts.note ~= "" then
        logLine("note", opts.note)
    end
    local freshWhy
    if sessionId == "" then
        freshWhy = (type(opts.freshReason) == "string" and opts.freshReason ~= "")
            and opts.freshReason or "the chat could not be resumed"
        logLine("fresh", "resuming nothing: " .. freshWhy)
    end
    trimLog()

    -- Cancelled before arming, not replaced by arriving: two switches for
    -- different tabs are different gate keys, so the gate would run both and
    -- type two resume commands. Only one handover can be pending at a time.
    if active then ClaudeChatSwitch.cancel() end

    local mine = {
        profile = profileName,
        sessionId = sessionId,
        cwd = cwd,
        registry = registry,
        pid = pid,
        tty = tty,
    }

    local job, why = ChatGate.startJob({
        kind = "switch",
        key = tostring(tty or pid),
        log = logLine,
        horizon = switchHorizon,
        detail = "handing the tab to " .. profileName,
        -- The handover owns this tab until the resume lands; anything else typing
        -- into it mid-flight would land in a chat that is quitting.
        keepFocus = true,
        target = {
            registryPath = registry,
            ttyPath = tty,
            termProgram = "Apple_Terminal",
        },
        -- A switch that dies after /exit went out (or after the chat did) leaves
        -- the tab stranded: no chat, no resume typed, and the session id gone
        -- from the screen. The resume command on the clipboard makes getting
        -- back one Cmd+V. A passive-mode chat that simply kept running keeps
        -- its clipboard - overwriting it would cost real contents for nothing.
        onEnd = function(state, reason, detail, alertText)
            local ours = active == mine
            if ours then active = nil end
            if state == "done" then return end
            logLine(reason or "gate", detail or "the chat gate ended this switch")
            -- Not ours means this switch was already called off or replaced: the tab
            -- belongs to whatever took it, and a resume command for the chat it is no
            -- longer switching to has no business on the clipboard.
            if not ours then return end
            if not (mine.exitTypedAt or not pidAlive(mine.pid)) then
                if not alertText then hs.alert.show("Chat switch failed") end
                return
            end
            -- Copy first, drop the restore only on a verified write: the
            -- other order trades the user's real clipboard for nothing when
            -- the write fails - and the alert must not claim a copy it
            -- cannot vouch for, so the fallback names the session instead.
            local recovery
            local setOk, setResult = pcall(hs.pasteboard.setContents, resumeCommand(mine))
            if setOk and setResult ~= false then
                mine.job:dropPasteboardRestore()
                recovery = "Resume command copied — paste it into the tab"
            else
                logLine("pasteboard-fail", "could not copy the resume command")
                recovery = "Could not copy the resume command — session "
                    .. (mine.sessionId == "" and "(fresh)" or mine.sessionId)
            end
            -- The gate has already said what went wrong when it named an alert of its
            -- own; this one only ever adds what to do about it.
            if alertText then
                hs.alert.show(recovery)
            else
                hs.alert.show("Chat switch failed\n" .. recovery)
            end
        end,
    })
    if job == nil then
        logLine("gate-busy", "another automation has this tab: " .. tostring(why))
        hs.alert.show("Chat switch: another automation has this tab")
        return false
    end
    mine.job = job
    active = mine

    -- The switch goes ahead either way - the tab is being handed over regardless -
    -- but a chat replaced by an empty one has to be seen, not read off a log later.
    -- Only once the tab is actually claimed: a refused switch that announced this
    -- would have him believe a conversation was dropped when nothing happened.
    if freshWhy then
        hs.alert.show("Chat switch → " .. profileName .. ": FRESH chat\n" .. freshWhy)
    end

    if not pidAlive(pid) then
        logLine("already-exited", "chat pid already gone; delivering now")
        deliverResume(job)
        return true
    end
    watchForExit(job)
    if tty then typeExit(job) end
    return true
end

function ClaudeChatSwitch.cancel()
    if not active then return false end
    local mine = active
    logLine("cancelled", "manual cancel")
    -- Clear first: cancelling ends the job, and its onEnd runs before this function
    -- gets the answer back - including the stranded-tab recovery, which belongs to a
    -- switch that failed on its own and not to one called off on purpose.
    active = nil
    local cancelled = ChatGate.cancel(tostring(mine.tty or mine.pid), "cancelled")
    return cancelled
end

function ClaudeChatSwitch.pending()
    if not active then return nil end
    if active.job and not active.job:alive() then return nil end
    return {
        profile = active.profile,
        mode = active.tty and "auto" or "passive",
    }
end

_G.ClaudeChatSwitch = ClaudeChatSwitch

return ClaudeChatSwitch
