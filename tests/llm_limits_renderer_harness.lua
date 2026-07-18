local source = debug.getinfo(1, "S").source
local root = source:match("^@(.+)/tests/[^/]+$")
assert(root, "renderer harness path is unavailable")

local Styled = {}
Styled.__index = Styled

local function styled(text, attributes)
  return setmetatable({
    text = text,
    attributes = attributes,
    runs = {{ text = text, attributes = attributes }},
  }, Styled)
end

function Styled.__concat(left, right)
  local result = styled("", {})
  result.text = left.text .. right.text
  result.runs = {}
  for _, run in ipairs(left.runs) do table.insert(result.runs, run) end
  for _, run in ipairs(right.runs) do table.insert(result.runs, run) end
  result.attributes = left.attributes
  return result
end

local function loadModule(fixture, taskFactory, nowOverride, alertFn)
  local mock = {
    alert = { show = alertFn or function() end },
    execute = function() return true end,
    fs = { attributes = function() return nil end },
    json = { decode = function()
      return type(fixture) == "function" and fixture() or fixture
    end },
    styledtext = { new = styled },
    task = { new = taskFactory or function() return nil end },
  }
  local fakeIo = setmetatable({
    open = function()
      return { read = function() return "fixture" end, close = function() end }
    end,
  }, { __index = io })
  local env = setmetatable({ hs = mock, io = fakeIo }, { __index = _G })
  if nowOverride then
    local timeFn = type(nowOverride) == "function" and nowOverride
      or function() return nowOverride end
    env.os = setmetatable({ time = timeFn }, { __index = os })
  end
  env._G = env
  local chunk, err = loadfile(root .. "/hammerspoon/llm-limits.lua", "t", env)
  assert(chunk, err)
  return chunk()
end

local function bucket(pct, stale)
  return { effective_pct = pct, resets_at = os.time() + 3600, stale = stale == true }
end

local function titleText(item)
  return type(item.title) == "table" and item.title.text or item.title
end

local function accountIndex(menu, account)
  for index, item in ipairs(menu) do
    if titleText(item) == account then return index end
  end
  error("account row missing: " .. account)
end

local function isRed(attributes)
  local color = attributes and attributes.color
  return color and color.red == 0.9 and color.green == 0.25 and color.blue == 0.2
end

local function redRuns(title)
  local result = {}
  for _, run in ipairs(title.runs or {}) do
    if isRed(run.attributes) then table.insert(result, run.text) end
  end
  return result
end

local function hasDimRed(title)
  for _, run in ipairs(title.runs or {}) do
    if isRed(run.attributes) and run.attributes.color.alpha == 0.55 then return true end
  end
  return false
end

local function isGray(attributes)
  local color = attributes and attributes.color
  return color and color.red == 0.55 and color.green == 0.55 and color.blue == 0.55
end

local function assertNoRed(item, message)
  assert(#redRuns(item.title) == 0, message)
end

local fixture = { schema = 1, vendors = {
  claude = {
    available = true,
    source = "claudeb-store",
    daemon = { reachable = true },
    accounts = {
      {
        account = "full",
        five_hour = bucket(100, true), weekly = bucket(40), fable = bucket(30),
        rotation = {
          usable = { general = false, fable = false },
          blocked = { general = "limit-5h", fable = "limit-5h" },
        },
      },
      {
        account = "fable85",
        five_hour = bucket(20), weekly = bucket(30), fable = bucket(85),
        rotation = { usable = { general = true, fable = true }, blocked = {} },
      },
      {
        account = "fablewall",
        five_hour = bucket(20), weekly = bucket(30), fable = bucket(95),
        rotation = {
          usable = { general = true, fable = false },
          blocked = { fable = "wall" },
        },
      },
      {
        account = "fresh",
        five_hour = bucket(10), weekly = bucket(20), fable = bucket(30),
        rotation = { usable = { general = true, fable = true }, blocked = {} },
      },
      {
        account = "no-stale",
        five_hour = { effective_pct = 10, resets_at = os.time() + 3600 },
        rotation = { usable = { general = true, fable = true }, blocked = {} },
      },
      {
        account = "no-reset",
        five_hour = { effective_pct = 10, resets_at = nil, stale = false },
        rotation = { usable = { general = true, fable = true }, blocked = {} },
      },
      {
        account = "past-reset",
        five_hour = { effective_pct = 0, resets_at = os.time() - 1800, stale = false, expired = true },
        rotation = { usable = { general = true, fable = true }, blocked = {} },
      },
      {
        account = "past-reset-unflagged",
        five_hour = { effective_pct = 0, resets_at = os.time() - 1800, stale = false, expired = false },
        rotation = { usable = { general = true, fable = true }, blocked = {} },
      },
      {
        account = "skew-reset",
        five_hour = { effective_pct = 0, resets_at = os.time() - 30, stale = false, expired = false },
        rotation = { usable = { general = true, fable = true }, blocked = {} },
      },
    },
  },
  codex = { available = false },
  gemini = { available = false },
}}

local menu = loadModule(fixture).menuItems()
local full = accountIndex(menu, "full")
assert(#redRuns(menu[full].title) > 0, "at-limit account title is not red")
assert(#redRuns(menu[full + 1].title) > 0, "at-limit five-hour row is not red")
assert(hasDimRed(menu[full + 1].title), "blocked stale row did not retain dim-red styling")
assert(#redRuns(menu[full + 2].title) > 0, "at-limit weekly row is not red")
assert(#redRuns(menu[full + 3].title) > 0, "at-limit fable row is not red")

local warning = accountIndex(menu, "fable85")
assertNoRed(menu[warning], "fable warning colored the account title")
assertNoRed(menu[warning + 1], "fable warning colored the five-hour row")
assertNoRed(menu[warning + 2], "fable warning colored the weekly row")
local warningRuns = redRuns(menu[warning + 3].title)
assert(#warningRuns == 1 and warningRuns[1] == "▓▓▓▓░", "fable warning did not color only its usage bar")

local fableWall = accountIndex(menu, "fablewall")
assertNoRed(menu[fableWall], "fable-only blockage colored the account title")
assertNoRed(menu[fableWall + 1], "fable-only blockage colored the five-hour row")
assertNoRed(menu[fableWall + 2], "fable-only blockage colored the weekly row")
assert(#redRuns(menu[fableWall + 3].title) == 1, "fable-only blockage did not color the whole fable row")

local fresh = accountIndex(menu, "fresh")
for offset = 0, 3 do
  assertNoRed(menu[fresh + offset], "fresh under-limit account rendered red")
end

local noStale = accountIndex(menu, "no-stale")
assert(not isGray(menu[noStale + 1].title.attributes), "missing stale flag fabricated gray styling")

local noReset = accountIndex(menu, "no-reset")
assert(titleText(menu[noReset + 1]):find("–", 1, true), "null reset did not render a dash")

local pastReset = accountIndex(menu, "past-reset")
local expectedPast = os.date("%H:%M", os.time() - 1800)
assert(titleText(menu[pastReset + 1]):find(expectedPast, 1, true),
  "real past reset did not render its clock time")

local pastUnflagged = accountIndex(menu, "past-reset-unflagged")
assert(isGray(menu[pastUnflagged + 1].title.attributes),
  "past resets_at without expired flag did not render dim")
assert(titleText(menu[pastUnflagged + 1]):find(expectedPast, 1, true),
  "render-time-expired row lost its real clock time")

local skewReset = accountIndex(menu, "skew-reset")
assert(not isGray(menu[skewReset + 1].title.attributes),
  "clock skew within tolerance was fabricated as expired")

local fresh5h = accountIndex(menu, "fresh")
assert(not isGray(menu[fresh5h + 1].title.attributes),
  "future resets_at was rendered dim")

local downFixture = { schema = 1, vendors = {
  claude = {
    available = true,
    source = "claudeb-store",
    daemon = { reachable = false },
    accounts = {{
      account = "daemon-down", five_hour = bucket(100), weekly = bucket(30), fable = bucket(40),
    }},
  },
  codex = { available = false },
  gemini = { available = false },
}}
local downMenu = loadModule(downFixture).menuItems()
local down = accountIndex(downMenu, "daemon-down")
for offset = 0, 3 do
  assertNoRed(downMenu[down + offset], "daemon-unreachable cache fabricated rotation red")
end
for _, item in ipairs(downMenu) do
  local text = titleText(item)
  assert(not tostring(text):find("error", 1, true), "daemon-unreachable cache rendered an error")
end

local codexFixture = { schema = 1, vendors = {
  claude = { available = false },
  codex = {
    available = true,
    current_account = "wrong",
    accounts = {
      { account = "marked", is_current = true, five_hour = bucket(10) },
      { account = "wrong", is_current = false, five_hour = bucket(20) },
    },
  },
  gemini = { available = false },
}}
local codexMenu = loadModule(codexFixture).menuItems()
local markedSeen, wrongSeen = false, false
for _, item in ipairs(codexMenu) do
  local text = titleText(item)
  if text:find("marked", 1, true) then markedSeen = text:find("●", 1, true) ~= nil end
  if text:find("wrong", 1, true) then wrongSeen = text:find("●", 1, true) ~= nil end
end
assert(markedSeen and not wrongSeen, "Codex marker did not trust is_current alone")

local runningTask = {
  isRunning = function() return true end,
  start = function() return true end,
  setEnvironment = function() end,
}
local passiveModule = loadModule(fixture, function() return runningTask end)
local runningMenu = passiveModule.menuItems()
for _, item in ipairs(runningMenu) do
  assert(not titleText(item):find("updating", 1, true),
    "passive collect rendered an updating row")
end
assert(passiveModule.refreshState().prefix == "", "passive collect changed the title state")

local deadFixture = { schema = 1, vendors = {
  claude = { available = false, refresh_error = { cause = "fixture failure", at = os.time() - 120 } },
  codex = { available = false },
  gemini = { available = false },
}}
local errorModule = loadModule(deadFixture)
local deadMenu = errorModule.menuItems()
local deadErrorSeen = false
for _, item in ipairs(deadMenu) do
  if titleText(item):find("refresh failed fixture failure · 2m", 1, true) then
    deadErrorSeen = true
    assert(isGray(item.title.attributes), "vendor refresh error was not dim")
  end
end
assert(deadErrorSeen, "structured vendor refresh error did not render")
assert(errorModule.refreshState().prefix == "⚠ ", "vendor error did not warn in the title state")

local clearModule = loadModule(fixture)
assert(clearModule.refreshState().prefix == "", "successful cache retained a warning title")
for _, item in ipairs(clearModule.menuItems()) do
  assert(not titleText(item):find("refresh failed", 1, true),
    "successful cache retained a vendor error row")
end

local geminiAuthFixture = { schema = 1, vendors = {
  claude = { available = false },
  codex = { available = false },
  gemini = { available = false, auth_needed = true, status = "login needed" },
}}
local geminiAuthModule = loadModule(geminiAuthFixture)
local geminiAuthMenu = geminiAuthModule.menuItems()
local geminiLoginRow = false
for _, item in ipairs(geminiAuthMenu) do
  local text = titleText(item)
  if text:find("Gemini", 1, true) and text:find("login needed", 1, true) then
    geminiLoginRow = true
  end
  assert(not (text:find("Gemini", 1, true) and text:find("no live data", 1, true)),
    "logged-out Gemini rendered as no live data")
end
assert(geminiLoginRow, "logged-out Gemini did not render a login-needed row")
assert(geminiAuthModule.refreshState().prefix == "",
  "auth_needed lit the warning title prefix")

local geminiErrorFixture = { schema = 1, vendors = {
  claude = { available = false },
  codex = { available = false },
  gemini = { available = false, refresh_error = { cause = "agy startup timed out", at = os.time() - 60 } },
}}
assert(loadModule(geminiErrorFixture).refreshState().prefix == "⚠ ",
  "a real Gemini refresh error did not warn in the title")

local residueTasks = {}
local residueModule = loadModule(function() return fixture end,
  function(_, callback)
    local task = { running = false, callback = callback }
    function task:setEnvironment() return self end
    function task:start()
      self.running = true
      table.insert(residueTasks, self)
      return true
    end
    function task:isRunning() return self.running end
    return task
  end)
residueModule.hardRefreshClaude("full")
residueTasks[1].running = false
residueTasks[1].callback(5, "", "collector failed")
assert(residueModule.refreshState().prefix == "⚠ ", "explicit failure lacked runtime warning evidence")
residueModule.menuItems()
residueTasks[2].running = false
residueTasks[2].callback(0, "", "")
assert(residueModule.refreshState().prefix == "", "healthy passive collect left a runtime warning pinned")

local deadTask = {
  isRunning = function() return false end,
  start = function() return true end,
  setEnvironment = function() end,
}
local deadRefresh = loadModule(fixture, function() return deadTask end)
deadRefresh.hardRefreshClaude("full")
assert(deadRefresh.refreshState().prefix == "", "dead registry task lit the title")

local liveState = { running = true }
local liveTask = {
  isRunning = function() return liveState.running end,
  start = function() return true end,
  setEnvironment = function() end,
}
local clock = { now = 1000 }
local liveRefresh = loadModule(fixture, function() return liveTask end,
  function() return clock.now end)
liveRefresh.hardRefreshClaude("full")
assert(liveRefresh.refreshState().prefix == "⟳ ", "live hard refresh did not light the title")
liveState.running = false
assert(liveRefresh.refreshState().prefix == "", "ended task retained a busy title")

local agedStarts = 0
local agedWarm = {
  isRunning = function() return true end,
  start = function() agedStarts = agedStarts + 1 return true end,
  setEnvironment = function() end,
}
local deadCollect = {
  isRunning = function() return false end,
  start = function() return true end,
  setEnvironment = function() end,
}
local agedClock = { now = 5000 }
local agedRefresh = loadModule(fixture, function(_, _, args)
  if args and args[1] == "--refresh-account" then return agedWarm end
  return deadCollect
end, function() return agedClock.now end)
agedRefresh.hardRefreshClaude("full")
agedClock.now = 5031
assert(agedRefresh.refreshState().prefix == "⟳ ", "live refresh missing busy title")
agedClock.now = 5000 + 361
assert(agedRefresh.refreshState().prefix == "⟳ ", "live over-budget task lost its busy state")
agedRefresh.hardRefreshClaude("full")
assert(agedStarts == 1, "live over-budget task allowed a duplicate spawn")
agedWarm.isRunning = function() return false end
assert(agedRefresh.refreshState().prefix == "", "dead over-budget task retained its busy state")
agedRefresh.hardRefreshClaude("full")
assert(agedStarts == 2, "dead over-budget task blocked a replacement spawn")

local throwWarm = {
  isRunning = function() return true end,
  start = function() return true end,
  setEnvironment = function() end,
}
local throwCollect = {
  isRunning = function() return false end,
  start = function() return true end,
  setEnvironment = function() end,
}
local warmCallback
local throwRefresh = loadModule(fixture, function(_, callback, args)
  if args and args[1] == "--refresh-account" then
    warmCallback = callback
    return throwWarm
  end
  return throwCollect
end, nil, function() error("alert boom") end)
throwRefresh.hardRefreshClaude("full")
assert(throwRefresh.refreshState().prefix == "⟳ ", "live callback task missing busy title")
pcall(warmCallback, 0, "", "")
assert(throwRefresh.refreshState().prefix == "", "completion callback left the registry busy")

local pendingModule = loadModule(fixture, function()
  return { isRunning = function() return true end, start = function() return true end,
    setEnvironment = function() end }
end)
pendingModule.hardRefreshClaude("full")
assert(pendingModule.refreshState().prefix == "⟳ ", "verified live task did not light the title")

local startClock = { now = 7000 }
local startRunning = true
local startCount = 0
local startTask = { isRunning = function() return startRunning end,
  start = function() startCount = startCount + 1 return true end,
  setEnvironment = function() end }
local startModule = loadModule(fixture, function(_, _, args)
  if args and args[1] == "--refresh" then return startTask end
  return deadTask
end, function() return startClock.now end)
local startMenu = startModule.menuItems()
for _, item in ipairs(startMenu) do
  if titleText(item) == "Refresh + Start Windows" then item.fn() end
end
assert(startModule.refreshState().prefix == "⟳ ", "start-windows did not light the title")
startClock.now = 7361
assert(startModule.refreshState().prefix == "⟳ ", "360s watchdog truncated start-windows")
startClock.now = 8201
assert(startModule.refreshState().prefix == "⟳ ", "live over-budget start-windows task was dropped")
for _, item in ipairs(startModule.menuItems()) do
  if titleText(item) == "Refresh + Start Windows" then item.fn() end
end
assert(startCount == 1, "live over-budget start-windows task allowed a duplicate spawn")
startRunning = false
assert(startModule.refreshState().prefix == "", "dead over-budget start-windows task was retained")

local automationState = { busy = true, warning = false }
local automationTitles = {}
local automationMenuBar = {}
function automationMenuBar:setTitle(value) table.insert(automationTitles, value) end
function automationMenuBar:setTooltip() end
function automationMenuBar:setClickCallback() end
function automationMenuBar:setMenu() end
function automationMenuBar:returnToMenuBar() end
function automationMenuBar:removeFromMenuBar() end
local automationHs = {
  alert = { show = function() end },
  menubar = { new = function() return automationMenuBar end },
  osascript = { applescript = function() return true, false end },
  task = { new = function()
    return { start = function() return true end, isRunning = function() return false end }
  end },
  timer = { doEvery = function() return {} end },
}
local automationLimits = {
  refreshState = function() return automationState end,
}
local automationEnv = setmetatable({
  hs = automationHs,
  package = { path = package.path },
  require = function(name)
    if name == "llm-limits" then return automationLimits end
    return require(name)
  end,
}, { __index = _G })
automationEnv._G = automationEnv
automationEnv.ClaudeContinue = {
  getStatus = function()
    return {
      destinationText = "Claude App",
      timers = {
        app = { armed = true, firesAt = 1, firesAtText = "05:00" },
        terminal = { armed = false },
      },
    }
  end,
}
local automationChunk, automationError = loadfile(
  root .. "/hammerspoon/config/automation_menu.lua", "t", automationEnv)
assert(automationChunk, automationError)
local automationModule = automationChunk()
assert(automationTitles[#automationTitles] == "⟳ A 05:00", "busy prefix masked the resume timer title")
automationState = { busy = false, warning = true }
automationModule.refresh()
assert(automationTitles[#automationTitles] == "⚠ A 05:00", "warning prefix masked the resume timer title")
automationState = { busy = false, warning = false }
automationModule.refresh()
assert(automationTitles[#automationTitles] == "A 05:00", "plain resume timer title changed")

local xmidNow = os.time({ year = 2027, month = 1, day = 15, hour = 12, min = 0, sec = 0 })
local sameDay = xmidNow + 14400
local crossMid = xmidNow + 72000
local farWeek = xmidNow + 259200
local weekdayNames = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local function dayText(ts)
  return weekdayNames[tonumber(os.date("%w", ts)) + 1] .. os.date(" %H:%M", ts)
end
local xmidFixture = { schema = 1, vendors = {
  claude = {
    available = true,
    source = "claudeb-store",
    daemon = { reachable = true },
    accounts = {
      { account = "sameday", five_hour = { effective_pct = 10, resets_at = sameDay },
        rotation = { usable = { general = true, fable = true }, blocked = {} } },
      { account = "crossmid", five_hour = { effective_pct = 20, resets_at = crossMid },
        rotation = { usable = { general = true, fable = true }, blocked = {} } },
      { account = "farweek", five_hour = { effective_pct = 30, resets_at = farWeek },
        rotation = { usable = { general = true, fable = true }, blocked = {} } },
    },
  },
  codex = { available = false },
  gemini = { available = false },
}}
local xmidMenu = loadModule(xmidFixture, nil, xmidNow).menuItems()
local sameDayRow = titleText(xmidMenu[accountIndex(xmidMenu, "sameday") + 1])
assert(sameDayRow:find(os.date("%H:%M", sameDay), 1, true), "same-day reset lost its bare clock time")
assert(not sameDayRow:find(dayText(sameDay), 1, true), "same-day reset wrongly gained a day marker")
local crossMidRow = titleText(xmidMenu[accountIndex(xmidMenu, "crossmid") + 1])
assert(crossMidRow:find(dayText(crossMid), 1, true), "within-24h cross-midnight reset lacks the day marker")
local farWeekRow = titleText(xmidMenu[accountIndex(xmidMenu, "farweek") + 1])
assert(farWeekRow:find(dayText(farWeek), 1, true), ">24h reset tier changed")

return "PASS: Hammerspoon projection contract"
