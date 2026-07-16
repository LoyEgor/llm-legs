local AutomationMenu = {}

package.path = package.path .. ";/Volumes/Work/Projects/llm-legs/hammerspoon/?.lua"
local llmLimits = nil
do
    local ok, loaded = pcall(require, "llm-limits")
    if ok then
        llmLimits = loaded
        llmLimits.wallsLog = "/Volumes/Work/Projects/find-truth/data/served-models.jsonl"
    end
end

local menuBar = hs.menubar.new()
local titleTimer = nil
local menuMode = nil
local menuVisible = true
local llmRefreshing = false

local startOptions = {
    { title = "Now", minutes = 0 },
    { title = "In 30 min", minutes = 30 },
    { title = "In 1 h", minutes = 60 },
    { title = "In 1 h 30 min", minutes = 90 },
    { title = "In 2 h", minutes = 120 },
    { title = "In 2 h 30 min", minutes = 150 },
    { title = "In 3 h", minutes = 180 },
    { title = "In 3 h 30 min", minutes = 210 },
    { title = "In 4 h", minutes = 240 },
    { title = "In 4 h 30 min", minutes = 270 },
    { title = "In 5 h", minutes = 300 },
}

local intervalOptions = {
    { title = "Do not repeat", minutes = nil },
    { title = "15 min", minutes = 15 },
    { title = "30 min", minutes = 30 },
    { title = "60 min", minutes = 60 },
    { title = "90 min", minutes = 90 },
}

local function getClaude()
    return _G.ClaudeContinue
end

local function getGptVoice()
    return _G.GptVoice
end

local function getHandoffGuard()
    return _G.HandoffGuard
end

local function getMonitorAutomation()
    return _G.MonitorAutomation
end

-- Blocking (AppleScript to System Events) — menu code must use dockAutoHideCache.
local function dockAutoHideEnabled()
    local ok, result = hs.osascript.applescript('tell application "System Events" to get autohide of dock preferences')

    if ok then
        return result == true
    end

    return nil
end

local dockAutoHideCache = nil
local dockReadTask = nil
local dockSetTask = nil

local function refreshDockCache()
    if dockReadTask and dockReadTask:isRunning() then
        return
    end
    dockReadTask = hs.task.new("/usr/bin/defaults", function(exitCode, stdOut)
        if exitCode == 0 then
            dockAutoHideCache = tostring(stdOut or ""):match("^%s*(.-)%s*$") == "1"
        else
            -- Missing key = macOS default (auto-hide off).
            dockAutoHideCache = false
        end
    end, { "read", "com.apple.dock", "autohide" })
    dockReadTask:start()
end

local dockSetPending = nil

local function setDockAutoHide(enabled)
    if enabled == dockAutoHideCache then
        return
    end
    -- Serialize: concurrent policy triggers (screen watcher, Jump watcher) must not
    -- race two osascript tasks whose completion order is undefined.
    if dockSetTask and dockSetTask:isRunning() then
        dockSetPending = enabled
        return
    end
    dockAutoHideCache = enabled
    local script = 'tell application "System Events" to set autohide of dock preferences to '
        .. (enabled and "true" or "false")
    dockSetTask = hs.task.new("/usr/bin/osascript", function(exitCode)
        if exitCode ~= 0 then
            hs.alert.show("Dock auto-hide: error")
        end
        refreshDockCache()
        local pendingValue = dockSetPending
        dockSetPending = nil
        if pendingValue ~= nil then
            setDockAutoHide(pendingValue)
        end
    end, { "-e", script })
    dockSetTask:start()
end

local function toggleDockAutoHide()
    if dockAutoHideCache == nil then
        hs.alert.show("Dock auto-hide: could not read state")
        refreshDockCache()
        return
    end

    setDockAutoHide(not dockAutoHideCache)
end

refreshDockCache()
local dockCacheTimer = hs.timer.doEvery(60, refreshDockCache)

_G.DockAutomation = {
    autoHideEnabled = dockAutoHideEnabled,
    setAutoHide = setDockAutoHide,
    toggleAutoHide = toggleDockAutoHide,
}

local buildMenu
local refreshTitle

local function showMenu()
    if menuVisible then
        if refreshTitle then
            refreshTitle()
        end
        return
    end

    local ok, err = pcall(function()
        menuBar:returnToMenuBar()
    end)

    if not ok then
        print("ERROR: Automation menu show failed:", err)
        return
    end

    menuVisible = true

    if refreshTitle then
        refreshTitle()
    end
end

local function hideMenu()
    if not menuVisible then
        return
    end

    local ok, err = pcall(function()
        menuBar:removeFromMenuBar()
    end)

    if not ok then
        print("ERROR: Automation menu hide failed:", err)
        return
    end

    menuVisible = false
end

refreshTitle = function()
    local claude = getClaude()
    local gptVoice = getGptVoice()

    if gptVoice and gptVoice.state == "recording" then
        if menuMode ~= "rec" then
            menuBar:setMenu(nil)
            menuBar:setClickCallback(function()
                gptVoice.stop()
            end)
            menuMode = "rec"
        end

        menuBar:setTitle("Rec")
        menuBar:setTooltip("GPT Voice recording. Click to stop.")
        return
    end

    if gptVoice and (gptVoice.state == "processing" or gptVoice.state == "transforming") then
        if menuMode ~= "processing" then
            menuBar:setMenu(nil)
            menuBar:setClickCallback(function()
                gptVoice.cancel()
            end)
            menuMode = "processing"
        end

        menuBar:setTitle("…")
        menuBar:setTooltip("GPT Voice processing. Click to cancel.")
        return
    end

    if llmRefreshing then
        -- A live llm-limits refresh can run for minutes (start-windows); the 30s
        -- titleTimer must not stomp the busy indicator set by onRefreshStart.
        return
    end

    if menuMode ~= "menu" then
        menuBar:setClickCallback()
        menuBar:setMenu(buildMenu)
        menuMode = "menu"
    end

    if not claude then
        menuBar:setTitle("Auto")
        menuBar:setTooltip("Automations")
        return
    end

    local status = claude.getStatus()

    local armed = {}
    for _, slot in ipairs({
        { id = "app", label = "A" },
        { id = "terminal", label = "T" },
    }) do
        local timerStatus = status.timers and status.timers[slot.id]
        if timerStatus and timerStatus.armed then
            table.insert(armed, {
                label = slot.label,
                firesAt = timerStatus.firesAt,
                text = timerStatus.overdue and "overdue" or (timerStatus.firesAtText or "?"),
            })
        end
    end

    local title

    if #armed == 0 then
        title = "Auto"
        menuBar:setTooltip("Automations")
    else
        if #armed == 2 and armed[1].firesAt == armed[2].firesAt then
            title = armed[1].text
        else
            local parts = {}
            for _, slot in ipairs(armed) do
                table.insert(parts, slot.label .. " " .. slot.text)
            end
            title = table.concat(parts, " · ")
        end
        menuBar:setTooltip((status.destinationText or "Claude App") .. " timer active.")
    end

    menuBar:setTitle(title)
end

buildMenu = function()
    local claude = _G.ClaudeContinue
    local gptVoice = getGptVoice()
    local handoff = getHandoffGuard()
    local monitor = getMonitorAutomation()
    local ipadMode = _G.IpadMode
    local dockAutoHide = dockAutoHideCache
    local handoffEnabled = handoff and handoff.isEnabledCached and handoff.isEnabledCached()

    if not claude then
        return {
            { title = "Claude is not loaded", disabled = true },
        }
    end

    local status = claude.getStatus()
    local destinationItem = {
        title = "Send To: " .. (status.destinationText or "Claude App"),
        menu = {},
    }
    local firstRunItem = {
        title = "First Run",
        menu = {},
    }
    local repeatItem = {
        title = "Repeat",
        menu = {},
    }
    local timersItem = {
        title = "Timers",
        menu = {},
    }
    local monitorItem = {
        title = "Monitor",
        disabled = not monitor,
        menu = {},
    }
    local llmLimitsMenu = {
        { title = "module not found", disabled = true },
    }
    if llmLimits and type(llmLimits.menuItems) == "function" then
        local ok, items = pcall(llmLimits.menuItems)
        if ok and type(items) == "table" then
            llmLimitsMenu = items
        end
    end
    local llmLimitsItem = { title = "LLM Limits", menu = llmLimitsMenu }

    local menu = {
        destinationItem,
        firstRunItem,
        repeatItem,
        { title = "-" },
        monitorItem,
        {
            title = "Handoff",
            checked = handoffEnabled == true,
            disabled = not handoff,
            fn = function()
                if handoff then
                    handoff.reconnect()
                end
            end,
        },
        {
            title = "Dock auto-hide",
            checked = dockAutoHide == true,
            fn = function()
                toggleDockAutoHide()
                refreshTitle()
            end,
        },
        {
            title = "For iPad",
            checked = ipadMode ~= nil and ipadMode.isOn(),
            disabled = not ipadMode,
            fn = function()
                if ipadMode then
                    ipadMode.toggle()
                    refreshTitle()
                end
            end,
        },
        { title = "-" },
        llmLimitsItem,
        { title = "-" },
    }

    if ipadMode and ipadMode.isOn() then
        table.insert(menu, {
            title = "Copy",
            fn = function()
                hs.eventtap.keyStroke({"cmd"}, "c")
            end,
        })
        table.insert(menu, {
            title = "Paste",
            fn = function()
                hs.eventtap.keyStroke({"cmd"}, "v")
            end,
        })
        table.insert(menu, {
            title = "Enter",
            fn = function()
                hs.eventtap.keyStroke({}, "return")
            end,
        })
        table.insert(menu, {
            title = "GPT Voice",
            disabled = not gptVoice or gptVoice.state == "offline",
            fn = function()
                if gptVoice then
                    gptVoice.start()
                end
            end,
        })
        table.insert(menu, {
            title = "GPT Transform",
            disabled = not gptVoice or gptVoice.state == "offline",
            fn = function()
                if gptVoice then
                    gptVoice.transform()
                end
            end,
        })
    end

    table.insert(menu, {
        title = "Hide Menu",
        fn = hideMenu,
    })

    for _, destination in ipairs(status.destinations or {}) do
        table.insert(destinationItem.menu, {
            title = destination.label,
            checked = destination.enabled,
            fn = function()
                claude.toggleDestination(destination.id)
                refreshTitle()
            end,
        })
    end

    local armedIds = {}
    for _, destination in ipairs(status.destinations or {}) do
        local timerStatus = destination.timer or {}
        if timerStatus.armed then
            table.insert(armedIds, destination.id)
            local shortLabel = destination.id == "app" and "App" or destination.label
            local timeText = timerStatus.overdue and "overdue" or (timerStatus.firesAtText or "?")

            table.insert(timersItem.menu, {
                title = "Stop " .. shortLabel .. " (" .. timeText .. ")",
                fn = function()
                    claude.stopTimerFor(destination.id)
                    refreshTitle()
                end,
            })
        end
    end

    if #armedIds == 2 then
        table.insert(timersItem.menu, {
            title = "Stop Both",
            fn = function()
                claude.stopTimer()
                refreshTitle()
            end,
        })
    end

    if #timersItem.menu > 0 then
        table.insert(menu, 4, timersItem)
    end

    for _, option in ipairs(startOptions) do
        local title = option.title
        local minutes = option.minutes

        table.insert(firstRunItem.menu, {
            title = title,
            checked = status.firstRunPending and status.selectedStartDelayMinutes == minutes,
            fn = function()
                claude.startTimerAfterMinutes(minutes)
                refreshTitle()
            end,
        })
    end

    for _, option in ipairs(intervalOptions) do
        local title = option.title
        local minutes = option.minutes

        table.insert(repeatItem.menu, {
            title = title,
            checked = (minutes == nil and not status.repeatEnabled)
                or (minutes ~= nil and status.timerIntervalSeconds == minutes * 60),
            fn = function()
                if minutes == nil then
                    claude.setIntervalMinutes(nil)
                else
                    claude.setIntervalMinutes(minutes)
                end
                refreshTitle()
            end,
        })
    end

    if monitor then
        table.insert(monitorItem.menu, {
            title = "Run Monitor-Off Action",
            fn = monitor.runMonitorOffAction,
        })
        table.insert(monitorItem.menu, {
            title = "Run Monitor-On Action",
            fn = monitor.runMonitorOnAction,
        })
        table.insert(monitorItem.menu, {
            title = "Recheck Displays",
            fn = monitor.checkNow,
        })
    end

    return menu
end

AutomationMenu.menuBar = menuBar
AutomationMenu.dockCacheTimer = dockCacheTimer
AutomationMenu.buildMenu = function()
    return buildMenu()
end
AutomationMenu.refresh = refreshTitle
AutomationMenu.show = showMenu
AutomationMenu.hide = hideMenu
AutomationMenu.onMonitorOff = showMenu
AutomationMenu.onMonitorOn = function() end
AutomationMenu.isVisible = function()
    return menuVisible
end

refreshTitle()
showMenu()
titleTimer = hs.timer.doEvery(30, refreshTitle)
AutomationMenu.titleTimer = titleTimer

if llmLimits then
    llmLimits.onRefreshStart = function()
        llmRefreshing = true
        menuBar:setTitle("…")
    end
    llmLimits.onRefreshDone = function(ok, _, failures)
        llmRefreshing = false
        if ok then
            refreshTitle()
        else
            menuBar:setTitle("err")
            if type(failures) == "table" and #failures > 0 then
                hs.alert.show("LLM refresh failed: " .. table.concat(failures, ", "))
            end
            hs.timer.doAfter(2, refreshTitle)
        end
    end
end

_G.AutomationMenu = AutomationMenu

return AutomationMenu
