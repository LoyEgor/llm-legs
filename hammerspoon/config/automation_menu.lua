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

    if menuMode ~= "menu" then
        menuBar:setClickCallback()
        menuBar:setMenu(buildMenu)
        menuMode = "menu"
    end

    local refreshOk, refreshState = pcall(function()
        return llmLimits and llmLimits.refreshState and llmLimits.refreshState()
    end)
    local refreshPrefix = ""
    local refreshTooltip = nil
    if refreshOk and refreshState and refreshState.busy then
        refreshPrefix = "⟳ "
        refreshTooltip = "LLM limits refresh in progress"
    elseif refreshOk and refreshState and refreshState.warning then
        refreshPrefix = "⚠ "
        refreshTooltip = "LLM limits refresh needs attention"
    end

    if not claude then
        menuBar:setTitle(refreshPrefix .. "Auto")
        menuBar:setTooltip(refreshTooltip or "Automations")
        return
    end

    local status = claude.getStatus()

    local armed = {}
    for _, slot in ipairs({
        { id = "app", label = "A" },
        { id = "terminal", label = "T" },
        { id = "kimi", label = "K" },
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

    menuBar:setTitle(refreshPrefix .. title)
    if refreshTooltip then menuBar:setTooltip(refreshTooltip) end
end

buildMenu = function()
    local claude = _G.ClaudeContinue
    local ipadMode = _G.IpadMode
    local ipadOverlay = _G.IpadOverlay
    local ipadAutomation = _G.IpadAutomation
    local ipadManualAvailable = ipadMode and type(ipadMode.setManual) == "function"
    local enforceAvailable = ipadAutomation
        and type(ipadAutomation.enforceEnabled) == "function"
        and type(ipadAutomation.setEnforce) == "function"

    if not claude then
        return {
            { title = "Claude is not loaded", disabled = true },
        }
    end

    local status = claude.getStatus()
    local hasEnabledDestination = false
    for _, destination in ipairs(status.destinations or {}) do
        if destination.enabled then
            hasEnabledDestination = true
            break
        end
    end
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
        { title = "-" },
        llmLimitsItem,
        { title = "-" },
        {
            title = "iPad Connected",
            disabled = not ipadManualAvailable,
            fn = ipadManualAvailable and function()
                ipadMode.setManual(true)
            end or nil,
        },
        {
            title = "iPad Disconnected",
            disabled = not ipadManualAvailable,
            fn = ipadManualAvailable and function()
                ipadMode.setManual(false)
            end or nil,
        },
        {
            title = "iPad Overlay",
            checked = ipadOverlay ~= nil and ipadOverlay.isShown(),
            disabled = not ipadOverlay,
            fn = function()
                if ipadOverlay then
                    ipadOverlay.toggle()
                    refreshTitle()
                end
            end,
        },
        {
            title = "Enforce iPad mode",
            checked = enforceAvailable and ipadAutomation.enforceEnabled(),
            disabled = not enforceAvailable,
            fn = function()
                if enforceAvailable then
                    ipadAutomation.setEnforce(not ipadAutomation.enforceEnabled())
                    refreshTitle()
                end
            end,
        },
        { title = "-" },
    }

    if hasEnabledDestination then
        table.insert(menu, 2, firstRunItem)
        table.insert(menu, 3, repeatItem)
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
    local shortLabels = {
        app = "App",
        terminal = "Terminal",
        kimi = "Kimi",
    }
    for _, destination in ipairs(status.destinations or {}) do
        local timerStatus = destination.timer or {}
        if timerStatus.armed then
            table.insert(armedIds, destination.id)
            local shortLabel = shortLabels[destination.id] or destination.label
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

    if #armedIds >= 2 then
        table.insert(timersItem.menu, {
            title = "Stop All",
            fn = function()
                claude.stopTimer()
                refreshTitle()
            end,
        })
    end

    if #timersItem.menu > 0 then
        table.insert(menu, hasEnabledDestination and 4 or 2, timersItem)
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

    return menu
end

AutomationMenu.menuBar = menuBar
AutomationMenu.buildMenu = function()
    return buildMenu()
end
AutomationMenu.refresh = refreshTitle
AutomationMenu.show = showMenu
AutomationMenu.hide = hideMenu
AutomationMenu.isVisible = function()
    return menuVisible
end

refreshTitle()
showMenu()
titleTimer = hs.timer.doEvery(30, refreshTitle)
AutomationMenu.titleTimer = titleTimer

if llmLimits then
    llmLimits.onRefreshStateChanged = function()
        refreshTitle()
    end
end

_G.AutomationMenu = AutomationMenu

return AutomationMenu
