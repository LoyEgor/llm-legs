local SendActions = {}

local pasteTarget = nil

-- Environment primitives, indirected so the test harness can drive the async
-- activate-then-send flow and capture the log without a live Hammerspoon.
local hooks

local function selfBundleID()
    if hooks and hooks.selfBundleID then return hooks.selfBundleID() end
    return hs.processInfo.bundleID
end

local function bundleIDOf(app)
    if not app then return nil end
    local ok, bid = pcall(function() return app:bundleID() end)
    return ok and bid or nil
end

local function pidOf(app)
    if not app then return nil end
    local ok, pid = pcall(function() return app:pid() end)
    return ok and pid or nil
end

local function appIsRunning(app)
    if not app then return false end
    local ok, running = pcall(function() return app:isRunning() end)
    return ok and running == true
end

local function frontmostBundleID()
    if hooks and hooks.frontmostBundleID then return hooks.frontmostBundleID() end
    return bundleIDOf(hs.application.frontmostApplication())
end

-- Identity is by pid, not bundle ID: two instances (or a relaunch) of the same
-- bundle share an ID, so a bundle match would falsely confirm the wrong process
-- is frontmost and fire the keystroke into it.
local function frontmostPid()
    if hooks and hooks.frontmostPid then return hooks.frontmostPid() end
    return pidOf(hs.application.frontmostApplication())
end

local function contentTypes()
    local getter = hooks and hooks.contentTypes or hs.pasteboard.contentTypes
    local ok, types = pcall(getter)
    return ok and types or {}
end

local function nowSeconds()
    if hooks and hooks.now then return hooks.now() end
    return hs.timer.secondsSinceEpoch()
end

local function afterDelay(delay, fn)
    if hooks and hooks.after then return hooks.after(delay, fn) end
    return hs.timer.doAfter(delay, fn)
end

-- hs.timer.doAfter userdata that nothing references is GC'd before it fires;
-- a collected delivery-poll timer once froze the FIFO queue forever (24 pastes
-- queued behind a job whose finish() never ran). Anchor every one-shot timer
-- until it fires.
local timerAnchors = {}
local function afterDelayRetained(delay, fn)
    local t
    t = afterDelay(delay, function()
        if t then timerAnchors[t] = nil end
        fn()
    end)
    if t then timerAnchors[t] = true end
    return t
end

local function activateApp(app)
    if hooks and hooks.activate then return hooks.activate(app) end
    app:activate()
end

local function keyStroke(mods, key, app, delay)
    if hooks and hooks.keyStroke then return hooks.keyStroke(mods, key, app, delay) end
    if delay then
        hs.eventtap.keyStroke(mods, key, delay, app)
    elseif app then
        hs.eventtap.keyStroke(mods, key, app)
    else
        hs.eventtap.keyStroke(mods, key)
    end
end

-- app:kind() == 1 is a regular (Dock-visible) app; the overlay's own NSPanel,
-- accessory panels and background agents report other kinds and must never
-- become the paste target, or a paste lands in the overlay itself.
function SendActions.shouldRemember(app)
    if not app then return false end
    local ok, kind = pcall(function() return app:kind() end)
    if not ok or kind ~= 1 then return false end
    local bid = bundleIDOf(app)
    return bid ~= nil and bid ~= selfBundleID()
end

-- The overlay's Copy/Paste/Enter send keystrokes, but clicking menu items or
-- tapping buttons can drop the terminal's key focus, so a plain keyStroke lands
-- nowhere and the paste silently fails. Post the event straight to the app the
-- user was last working in (keyStroke's app arg). frontmostApplication() at
-- click time is unreliable - it can already read as Hammerspoon, or go stale
-- when the user switches apps without reopening the menu — so track app
-- activations continuously and remember the last real app instead.
local function rememberFront(app)
    if SendActions.shouldRemember(app) then
        pasteTarget = app
    end
end
SendActions.rememberFront = rememberFront

rememberFront(hs.application.frontmostApplication())

local pasteTargetWatcher = hs.application.watcher.new(function(_, event, app)
    if event == hs.application.watcher.activated then
        rememberFront(app)
    end
end)
pasteTargetWatcher:start()

SendActions.terminalBundles = {
    ["com.apple.Terminal"] = true,
    ["com.googlecode.iterm2"] = true,
    ["com.mitchellh.ghostty"] = true,
    ["com.cmuxterm.app"] = true,
}

local function isTerminalApp(app)
    local bid = bundleIDOf(app)
    return bid ~= nil and SendActions.terminalBundles[bid] == true
end

local logPath = (os.getenv("HOME") or "") .. "/Library/Logs/send-actions.log"
local logMaxBytes = 256 * 1024

local function isoTimestamp()
    if hooks and hooks.timestamp then return hooks.timestamp() end
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function formatLine(record)
    local line = string.format(
        "%s action=%s path=%s target=%s front=%s terminal=%s clipboard=%s activation=%s",
        isoTimestamp(),
        record.action or "?",
        record.path or "?",
        record.target or "none",
        record.front or "none",
        tostring(record.terminal == true),
        record.clipboard or "none",
        record.activation or "-")
    if record.sentFront then
        line = line .. " sentFront=" .. record.sentFront
    end
    return line
end

-- One structured line per public call; must never throw. The synchronous
-- console print is the record of truth; the file append (with a single
-- rename-to-.1 rotation once it exceeds the cap) is deferred off the hot path.
local function writeLog(record)
    local ok, line = pcall(formatLine, record)
    if not ok then return end
    if hooks and hooks.log then
        hooks.log(line)
        return
    end
    print("[SendActions] " .. line)
    afterDelayRetained(0, function()
        pcall(function()
            local attrs = hs.fs.attributes(logPath)
            if attrs and attrs.size and attrs.size > logMaxBytes then
                os.rename(logPath, logPath .. ".1")
            end
            local f = io.open(logPath, "a")
            if f then
                f:write(line, "\n")
                f:close()
            end
        end)
    end)
end

-- file-url counts as text: Terminal's Cmd+V pastes a copied file as its path,
-- which ctrl+v would lose. The image flag needs the full UTI table owned by
-- ClaudeCmdKeys, so borrow its classifier when present.
function SendActions.classifyClipboard(types, containsImage)
    types = type(types) == "table" and types or {}
    local flags = { text = false, image = false, ["file-url"] = false }
    for _, t in ipairs(types) do
        if t == "public.utf8-plain-text" or t == "public.plain-text"
            or t == "NSStringPboardType" then
            flags.text = true
        elseif t == "public.file-url" then
            flags["file-url"] = true
        end
    end
    if containsImage and containsImage(types) then flags.image = true end
    local parts = {}
    for _, name in ipairs({ "text", "image", "file-url" }) do
        if flags[name] then parts[#parts + 1] = name end
    end
    return flags, (#parts > 0 and table.concat(parts, "+") or "none")
end

function SendActions.clipboardHasText()
    local flags = SendActions.classifyClipboard(contentTypes())
    return flags.text or flags["file-url"]
end

-- Menu-equivalent keystrokes (any "cmd" chord) only land on the FRONTMOST app;
-- posted to a background target they silently drop, which is the paste bug.
-- Activate the target, poll by pid until it is frontmost (≤ ~1.5s), then send;
-- on timeout send once anyway and log it. Deliveries run one at a time through a
-- FIFO queue: a call arriving mid-flight waits its turn so a queued copy is
-- never cancelled by a later paste, and two activate-polls never overlap.
-- Raw-byte paths through ClaudeCmdKeys stay off this path — they deliver
-- reliably to a non-frontmost app already.
local activateTimeout = 1.5
local activatePoll = 0.05

local deliveryQueue = {}
local deliveryActive = false
local deliveryStartedAt = 0
local deliverySeq = 0
local runDelivery
-- A delivery with live timers always finishes within activateTimeout; one
-- alive longer than this lost its poll chain and will never finish on its own.
local deliveryStallAfter = activateTimeout + 2.0

local function processNext()
    local job = table.remove(deliveryQueue, 1)
    if job then
        runDelivery(job)
    else
        deliveryActive = false
    end
end

runDelivery = function(job)
    local mods, key, app, record = job.mods, job.key, job.app, job.record

    deliverySeq = deliverySeq + 1
    deliveryStartedAt = nowSeconds()
    local mySeq = deliverySeq

    -- A stale finish (queue recovery already invalidated this job) must not
    -- advance the queue a second time.
    local function finish(activation, sentFront)
        if deliverySeq ~= mySeq then return end
        record.activation = activation
        record.sentFront = sentFront
        writeLog(record)
        processNext()
    end

    -- Re-check liveness immediately before every send: the target can quit
    -- during the poll, and a global cmd keystroke into whatever replaced it
    -- could act on the wrong app, so a dead target sends nothing. The seq
    -- check must come before the keystroke, not just in finish: a stale poll
    -- from a recovered-away delivery would otherwise still fire its send.
    local function sendTargeted(activation)
        if deliverySeq ~= mySeq then return end
        if not appIsRunning(app) then
            finish("target-quit")
            return
        end
        local ok = pcall(keyStroke, mods, key, app)
        if not ok then
            finish("error")
            return
        end
        finish(activation, frontmostBundleID())
    end

    local targetPid = pidOf(app)
    if not app or not targetPid then
        local ok = pcall(keyStroke, mods, key, nil)
        finish(ok and "no-target" or "error")
        return
    end

    if frontmostPid() == targetPid then
        sendTargeted("already-front")
        return
    end

    local okActivate = pcall(activateApp, app)
    if not okActivate then
        finish("error")
        return
    end
    local deadline = nowSeconds() + activateTimeout
    local poll
    poll = function()
        if deliverySeq ~= mySeq then return end
        if frontmostPid() == targetPid then
            sendTargeted("activated")
            return
        end
        if nowSeconds() >= deadline then
            sendTargeted("timeout")
            return
        end
        afterDelayRetained(activatePoll, poll)
    end
    afterDelayRetained(activatePoll, poll)
end

local function deliverCmd(mods, key, app, record)
    local job = { mods = mods, key = key, app = app, record = record }
    if deliveryActive then
        if nowSeconds() - deliveryStartedAt > deliveryStallAfter then
            -- The stalled job and everything queued behind it are stale user
            -- intents; replaying them now would burst-fire keystrokes into
            -- the target. Drop them all and serve the live tap instead.
            deliverySeq = deliverySeq + 1
            local dropped = 1 + #deliveryQueue
            deliveryQueue = {}
            writeLog({ action = "queue-recovery",
                       path = "dropped:" .. dropped, clipboard = "-" })
            runDelivery(job)
            return
        end
        deliveryQueue[#deliveryQueue + 1] = job
        return
    end
    deliveryActive = true
    runDelivery(job)
end

local function modsHaveCmd(mods)
    for _, m in ipairs(mods or {}) do
        if tostring(m):lower() == "cmd" then return true end
    end
    return false
end

local function currentTarget()
    if pasteTarget and appIsRunning(pasteTarget) then return pasteTarget end
    return nil
end

local function lightRecord(action, target)
    return {
        action = action,
        target = bundleIDOf(target) or "none",
        front = frontmostBundleID() or "none",
        terminal = isTerminalApp(target),
        clipboard = "-",
    }
end

local function beginRecord(action, target)
    local record = lightRecord(action, target)
    local containsImage = _G.ClaudeCmdKeys and _G.ClaudeCmdKeys.containsImageType
    local flags, summary = SendActions.classifyClipboard(contentTypes(), containsImage)
    record.clipboard = summary
    record._flags = flags
    return record
end

function SendActions.sendKeys(mods, key)
    local target = currentTarget()
    local record = lightRecord("sendKeys", target)
    record.path = table.concat(mods or {}, "+") .. "+" .. tostring(key)
    if modsHaveCmd(mods) and target then
        deliverCmd(mods, key, target, record)
        return
    end
    local ok = pcall(keyStroke, mods, key, target)
    record.activation = (not ok and "error") or (target and "targeted" or "global")
    writeLog(record)
end

function SendActions.targetIsTerminal()
    return isTerminalApp(pasteTarget)
end

-- Only com.apple.Terminal has both a Cmd+C -> chord rewrite and a
-- Claude-vs-shell detector in ClaudeCmdKeys; other terminals keep the
-- unconditional chord (there is no second detector to gate them on).
local chordDetectBundle = "com.apple.Terminal"
-- Cold-cache grace mirrors ClaudeCmdKeys' own pending-resolve window, so a
-- just-focused tab has time to resolve before we give up and copy natively.
local chordVerdictDeferral = 0.28

local function fireChord(target, record)
    local ck = _G.ClaudeCmdKeys
    if ck and ck.menuCopy then
        record.path = "menuCopy"
        local ok = pcall(ck.menuCopy, target)
        record.activation = ok and "-" or "error"
        writeLog(record)
        return
    end
    record.path = "chord-fallback"
    local ok = pcall(function()
        keyStroke({ "ctrl" }, "x", target, 20000)
        keyStroke({ "ctrl" }, "y", target, 20000)
    end)
    record.activation = ok and "-" or "error"
    writeLog(record)
end

local function nativeCopy(target, record)
    record.path = "native-cmd"
    deliverCmd({ "cmd" }, "c", target, record)
end

-- No terminal-native selection means the copy must come from a TUI. In a plain
-- shell ctrl+x ctrl+y are readline edits that mutate the command line, so the
-- Claude Code copy chord may fire only when ClaudeCmdKeys confirms Claude owns
-- the terminal's foreground. Unknown (cold cache, even after its resolve
-- window) copies natively - a no-op in a TUI but never destructive.
local function copyFromTui(target, record)
    local ck = _G.ClaudeCmdKeys
    if bundleIDOf(target) ~= chordDetectBundle or not (ck and ck.foregroundVerdict) then
        fireChord(target, record)
        return
    end
    local verdict = ck.foregroundVerdict()
    if verdict == "claude" then
        fireChord(target, record)
        return
    end
    if verdict ~= "uncertain" then
        nativeCopy(target, record)
        return
    end
    afterDelayRetained(chordVerdictDeferral, function()
        if ck.foregroundVerdict() == "claude" then
            fireChord(target, record)
        else
            nativeCopy(target, record)
        end
    end)
end

function SendActions.sendCopy()
    local target = currentTarget()
    local record = beginRecord("sendCopy", target)
    if not record.terminal then
        nativeCopy(target, record)
        return
    end
    -- In a terminal running Claude Code the visible selection belongs to the TUI,
    -- not the terminal, so Cmd+C copies nothing (the TUI owns mouse reporting).
    -- A real terminal-native selection is still copied with Cmd+C: it shows up
    -- as AXSelectedText, the TUI's drawn selection does not.
    local nativeSelection = false
    pcall(function()
        local axApp = hs.axuielement.applicationElement(target)
        -- AX calls into a busy app block indefinitely by default and would
        -- hang the overlay; cap them so copy degrades to the chord instead.
        if axApp.setTimeout then axApp:setTimeout(0.3) end
        local focused = axApp and axApp:attributeValue("AXFocusedUIElement")
        local sel = focused and focused:attributeValue("AXSelectedText")
        nativeSelection = type(sel) == "string" and #sel > 0
    end)
    if nativeSelection then
        nativeCopy(target, record)
        return
    end
    copyFromTui(target, record)
end

-- Given the situation, choose the paste path. Pure: menuPasteSucceeded is the
-- result of calling ClaudeCmdKeys.menuPaste (nil when it was not called), which
-- succeeds only for an image or a readable image-file clipboard.
function SendActions.choosePastePath(isTerminal, menuPasteAvailable, hasText, menuPasteSucceeded)
    if isTerminal then
        if menuPasteAvailable then
            if menuPasteSucceeded then return "menuPaste" end
            return "cmd-v"
        end
        if not hasText then return "ctrl-v" end
    end
    return "cmd-v"
end

function SendActions.sendPaste()
    -- A terminal's Cmd+V pastes text through the TTY and cannot deliver an image;
    -- Claude Code reads the pasteboard itself on ctrl+v (its image paste).
    -- ClaudeCmdKeys.menuPaste owns the image and image-file cases (same raw-byte
    -- plans as the physical Cmd+V remap); a textual clipboard falls through to a
    -- native Cmd+V, which works in Claude Code and plain shells alike.
    local target = currentTarget()
    local record = beginRecord("sendPaste", target)
    local isTerminal = record.terminal
    local ck = _G.ClaudeCmdKeys
    local menuPasteAvailable = ck ~= nil and ck.menuPaste ~= nil
    local menuPasteSucceeded = nil
    if isTerminal and menuPasteAvailable then
        local ok, res = pcall(ck.menuPaste, target)
        menuPasteSucceeded = ok and res == true
    end
    local hasText = record._flags.text or record._flags["file-url"]
    local path = SendActions.choosePastePath(
        isTerminal, menuPasteAvailable, hasText, menuPasteSucceeded)
    record.path = path
    if path == "menuPaste" then
        writeLog(record)
        return
    end
    if path == "ctrl-v" then
        local ok = pcall(keyStroke, { "ctrl" }, "v", target)
        record.activation = (not ok and "error") or (target and "targeted" or "global")
        writeLog(record)
        return
    end
    deliverCmd({ "cmd" }, "v", target, record)
end

function SendActions.setTestHooks(newHooks)
    hooks = newHooks
    pasteTarget = nil
    deliveryQueue = {}
    deliveryActive = false
    deliveryStartedAt = 0
    timerAnchors = {}
end

_G.SendActions = SendActions
-- Anchor long-lived objects globally: local-only references can be GC'd and silently die.
SendActions.pasteTargetWatcher = pasteTargetWatcher

return SendActions
