local TypeWhisper = {}

local active = false
local pasteReady = false
local RESTORE_POLL_INTERVAL = 0.1
local RESTORE_WAIT_TIMEOUT = 45
local RESTORE_AFTER_CHANGE_DELAY = 0.65

local sessionStartChangeCount = nil
local restoreGeneration = 0
local restorePollTimer = nil

local function notifyStatusChanged()
    if _G.AutomationMenu and _G.AutomationMenu.refresh then
        _G.AutomationMenu.refresh()
    end
end

local function triggerHotkey()
    hs.eventtap.keyStroke({}, "pageup")
end

local function readChangeCount()
    local ok, count = pcall(hs.pasteboard.changeCount)

    if ok then
        return count
    end

    return nil
end

local function readClipboardSnapshot()
    local ok, snapshot = pcall(hs.pasteboard.readAllData)

    if ok and type(snapshot) == "table" and next(snapshot) ~= nil then
        return snapshot
    end

    return nil
end

local function restoreClipboard(snapshot)
    if not snapshot then
        return
    end

    local ok = pcall(hs.pasteboard.writeAllData, snapshot)

    if not ok then
        print("ERROR: Type Whisper clipboard restore failed")
    end
end

local function cancelPendingRestore()
    restoreGeneration = restoreGeneration + 1

    if restorePollTimer then
        restorePollTimer:stop()
        restorePollTimer = nil
    end

end

local function restoreAfterTypeWhisperWrite(snapshot, baselineChangeCount)
    if not snapshot or not baselineChangeCount then
        return
    end

    cancelPendingRestore()
    restoreGeneration = restoreGeneration + 1
    local generation = restoreGeneration
    local startedAt = hs.timer.secondsSinceEpoch()
    local observedChangeCount = baselineChangeCount
    local lastChangedAt = nil

    local function finish()
        if restorePollTimer then
            restorePollTimer:stop()
            restorePollTimer = nil
        end
    end

    restorePollTimer = hs.timer.doEvery(RESTORE_POLL_INTERVAL, function()
        if generation ~= restoreGeneration then
            finish()
            return
        end

        local now = hs.timer.secondsSinceEpoch()
        local currentChangeCount = readChangeCount()

        if currentChangeCount and currentChangeCount ~= observedChangeCount then
            observedChangeCount = currentChangeCount

            if currentChangeCount ~= baselineChangeCount then
                lastChangedAt = now
            end
        end

        if lastChangedAt and now - lastChangedAt >= RESTORE_AFTER_CHANGE_DELAY then
            finish()
            restoreClipboard(snapshot)
            return
        end

        if now - startedAt >= RESTORE_WAIT_TIMEOUT then
            finish()
        end
    end)
end

local function clipboardChangedSinceSessionStart()
    local currentChangeCount = readChangeCount()

    if not currentChangeCount or not sessionStartChangeCount then
        return false, currentChangeCount
    end

    return currentChangeCount ~= sessionStartChangeCount, currentChangeCount
end

local function captureCurrentClipboardIfUserChangedIt()
    local changed, currentChangeCount = clipboardChangedSinceSessionStart()

    if not changed then
        return nil, currentChangeCount
    end

    return readClipboardSnapshot(), currentChangeCount
end

local function restoreAfterTypeWhisperWriteIfNeeded(snapshot, baselineChangeCount)
    if snapshot then
        restoreAfterTypeWhisperWrite(snapshot, baselineChangeCount)
    end
end

function TypeWhisper.start()
    if active then
        return
    end

    cancelPendingRestore()
    triggerHotkey()
    active = true
    pasteReady = false
    sessionStartChangeCount = readChangeCount()
    notifyStatusChanged()
end

function TypeWhisper.stop()
    if not active then
        return
    end

    local snapshotToRestore, baselineChangeCount = captureCurrentClipboardIfUserChangedIt()

    active = false
    pasteReady = false
    sessionStartChangeCount = nil

    restoreAfterTypeWhisperWriteIfNeeded(snapshotToRestore, baselineChangeCount)
    triggerHotkey()

    notifyStatusChanged()
end

function TypeWhisper.toggle()
    if active then
        TypeWhisper.stop()
    else
        TypeWhisper.start()
    end
end

function TypeWhisper.isActive()
    return active
end

function TypeWhisper.isPasteReady()
    return pasteReady
end

function TypeWhisper.copy()
    hs.eventtap.keyStroke({"cmd"}, "c")
    pasteReady = true
    notifyStatusChanged()
end

function TypeWhisper.paste()
    hs.eventtap.keyStroke({"cmd"}, "v")
end

function TypeWhisper.pasteAndReset()
    TypeWhisper.paste()
    pasteReady = false
    notifyStatusChanged()
end

function TypeWhisper.clearPasteReady()
    pasteReady = false
    notifyStatusChanged()
end

_G.TypeWhisper = TypeWhisper

return TypeWhisper
