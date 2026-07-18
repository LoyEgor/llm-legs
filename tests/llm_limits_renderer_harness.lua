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
    json = { decode = function() return fixture end },
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
local runningMenu = loadModule(fixture, function() return runningTask end).menuItems()
assert(titleText(runningMenu[1]):find("updating", 1, true),
  "in-flight collect did not render the updating indicator")
assert(isGray(runningMenu[1].title.attributes), "updating indicator was not dim")

local deadFixture = { schema = 1, vendors = {
  claude = { available = false, refresh_error = "fixture failure" },
  codex = { available = false },
  gemini = { available = false },
}}
local deadTask = {
  isRunning = function() error("dead task") end,
  start = function() return true end,
  setEnvironment = function() end,
}
local deadMenu = loadModule(deadFixture, function() return deadTask end).menuItems()
local deadErrorSeen = false
for _, item in ipairs(deadMenu) do
  if titleText(item):find("refresh failed: claude — fixture failure", 1, true) then
    deadErrorSeen = true
  end
end
assert(deadErrorSeen, "dead collect task masked the cached refresh error")

assert(not titleText(menu[1]):find("updating", 1, true),
  "updating indicator appeared with no in-flight collect or hard refresh")

local function updatingShown(module)
  for _, item in ipairs(module.menuItems()) do
    if type(titleText(item)) == "string" and titleText(item):find("updating", 1, true) then
      return true
    end
  end
  return false
end

-- A hardRefresh whose callback never fires and whose task reports isRunning()==false is
-- dead evidence, not an in-flight update: no updating row, no spinner.
local pendingTask = {
  isRunning = function() return false end,
  start = function() return true end,
  setEnvironment = function() end,
}
local deadRefresh = loadModule(fixture, function() return pendingTask end)
deadRefresh.hardRefreshClaude("full")
assert(not updatingShown(deadRefresh),
  "dead hard-refresh task rendered a phantom updating indicator")
assert(not deadRefresh.menubarSpinner(), "dead hard-refresh task lit the title spinner")

-- A verified-live task drives the updating row; past 30s it also drives the title
-- spinner; when the task ends both vanish on the spot.
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
assert(updatingShown(liveRefresh), "live hard refresh did not render the updating indicator")
assert(not liveRefresh.menubarSpinner(), "title spinner appeared before 30s of in-flight")
clock.now = 1031
assert(liveRefresh.menubarSpinner(), "title spinner missing after 30s of live in-flight")
assert(updatingShown(liveRefresh), "updating indicator vanished while task still live")
liveState.running = false
assert(not liveRefresh.menubarSpinner(), "title spinner persisted after task ended")
assert(not updatingShown(liveRefresh), "updating indicator persisted after task ended")

-- Watchdog: past the 360s budget even a still-"alive" handle is wedged and dropped
-- (dead-task drop is covered by deadRefresh above; here the warm task keeps claiming
-- alive). The collect re-read gets a dead task so it never masks the dropped entry.
local agedWarm = {
  isRunning = function() return true end,
  start = function() return true end,
  setEnvironment = function() end,
}
local deadCollect = {
  isRunning = function() return false end,
  start = function() return true end,
  setEnvironment = function() end,
}
local agedClock = { now = 5000 }
local agedRefresh = loadModule(fixture, function(_, _, args)
  if args and args[1] == "warm" then return agedWarm end
  return deadCollect
end, function() return agedClock.now end)
agedRefresh.hardRefreshClaude("full")
agedClock.now = 5031
assert(agedRefresh.menubarSpinner(), "live 31s refresh did not light the spinner")
assert(updatingShown(agedRefresh), "live refresh missing updating row")
agedClock.now = 5000 + 361
assert(not agedRefresh.menubarSpinner(), "watchdog kept a >360s wedged entry spinning")
assert(not updatingShown(agedRefresh), "watchdog left a >360s wedged entry in the updating row")

-- A callback whose alert decoration throws must still clear the flag (finish runs first).
-- The warm task keeps reporting alive, so a skipped finish() would leave the row pinned;
-- the collect re-read gets a dead task so only the hard-refresh entry drives the row.
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
  if args and args[1] == "warm" then
    warmCallback = callback
    return throwWarm
  end
  return throwCollect
end, nil, function() error("alert boom") end)
throwRefresh.hardRefreshClaude("full")
assert(updatingShown(throwRefresh), "live throwing-callback refresh missing updating row")
pcall(warmCallback, 1, "", "boom")
assert(not updatingShown(throwRefresh), "thrown alert skipped finish() and pinned the row")
assert(not throwRefresh.menubarSpinner(), "thrown alert skipped finish() and pinned the spinner")

local pendingModule = loadModule(fixture, function()
  return { isRunning = function() return true end, start = function() return true end,
    setEnvironment = function() end }
end)
pendingModule.hardRefreshClaude("full")
local hardRefreshMenu = pendingModule.menuItems()
assert(titleText(hardRefreshMenu[1]):find("updating", 1, true),
  "in-flight hard refresh did not render the updating indicator")

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
