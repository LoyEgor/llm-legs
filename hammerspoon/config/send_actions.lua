local SendActions = {}

local pasteTarget = nil

-- The overlay's Copy/Paste/Enter send keystrokes, but clicking menu items or
-- tapping buttons can drop the terminal's key focus, so a plain keyStroke lands
-- nowhere and the paste silently fails. Post the event straight to the app the
-- user was last working in (keyStroke's app arg). frontmostApplication() at
-- click time is unreliable - it can already read as Hammerspoon, or go stale
-- when the user switches apps without reopening the menu — so track app
-- activations continuously and remember the last real (non-Hammerspoon) app
-- instead.
local function rememberFront(app)
    if not app then return end
    local ok, bid = pcall(function() return app:bundleID() end)
    if ok and bid and bid ~= hs.processInfo.bundleID then
        pasteTarget = app
    end
end

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

function SendActions.sendKeys(mods, key)
    if pasteTarget and pasteTarget:isRunning() then
        hs.eventtap.keyStroke(mods, key, pasteTarget)
    else
        hs.eventtap.keyStroke(mods, key)
    end
end

function SendActions.targetIsTerminal()
    if not pasteTarget then return false end
    local ok, bid = pcall(function() return pasteTarget:bundleID() end)
    return ok and bid ~= nil and SendActions.terminalBundles[bid] == true
end

function SendActions.sendCopy()
    if not SendActions.targetIsTerminal() then
        SendActions.sendKeys({"cmd"}, "c")
        return
    end
    -- In a terminal running Claude Code the visible selection belongs to the TUI,
    -- not the terminal, so Cmd+C copies nothing (the TUI owns mouse reporting).
    -- Claude Code exposes its copy as the ctrl+x ctrl+y chord (selection:copy in
    -- ~/.claude/keybindings.json) - send that instead. A real terminal-native
    -- selection is still copied with Cmd+C: it shows up as AXSelectedText, the
    -- TUI's drawn selection does not.
    local nativeSelection = false
    pcall(function()
        local axApp = hs.axuielement.applicationElement(pasteTarget)
        -- AX calls into a busy app block indefinitely by default and would
        -- hang the overlay; cap them so copy degrades to the chord instead.
        if axApp.setTimeout then axApp:setTimeout(0.3) end
        local focused = axApp and axApp:attributeValue("AXFocusedUIElement")
        local sel = focused and focused:attributeValue("AXSelectedText")
        nativeSelection = type(sel) == "string" and #sel > 0
    end)
    if nativeSelection then
        SendActions.sendKeys({"cmd"}, "c")
    elseif _G.ClaudeCmdKeys and _G.ClaudeCmdKeys.menuCopy then
        _G.ClaudeCmdKeys.menuCopy(pasteTarget)
    else
        hs.eventtap.keyStroke({"ctrl"}, "x", 20000, pasteTarget)
        hs.eventtap.keyStroke({"ctrl"}, "y", 20000, pasteTarget)
    end
end

function SendActions.clipboardHasText()
    local types = hs.pasteboard.contentTypes() or {}
    for _, t in ipairs(types) do
        -- file-url counts as text: Terminal's Cmd+V pastes a copied file as
        -- its path, which ctrl+v would lose.
        if t == "public.utf8-plain-text" or t == "public.plain-text"
            or t == "NSStringPboardType" or t == "public.file-url" then
            return true
        end
    end
    return false
end

function SendActions.sendPaste()
    -- A terminal's Cmd+V pastes text through the TTY and cannot deliver an image;
    -- Claude Code reads the pasteboard itself on ctrl+v (its image paste).
    -- ClaudeCmdKeys.menuPaste owns the image and image-file cases (same raw-byte
    -- plans as the physical Cmd+V remap); a textual clipboard falls through to a
    -- native Cmd+V, which works in Claude Code and plain shells alike.
    if SendActions.targetIsTerminal() then
        local ck = _G.ClaudeCmdKeys
        if ck and ck.menuPaste and ck.menuPaste(pasteTarget) then
            return
        end
        if not (ck and ck.menuPaste) and not SendActions.clipboardHasText() then
            SendActions.sendKeys({"ctrl"}, "v")
            return
        end
    end
    SendActions.sendKeys({"cmd"}, "v")
end

_G.SendActions = SendActions
-- Anchor long-lived objects globally: local-only references can be GC'd and silently die.
SendActions.pasteTargetWatcher = pasteTargetWatcher

return SendActions
