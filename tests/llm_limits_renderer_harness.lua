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

local function loadModule(fixture, taskFactory)
  local mock = {
    alert = { show = function() end },
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

local pendingTask = {
  isRunning = function() return false end,
  start = function() return true end,
  setEnvironment = function() end,
}
local hardRefreshModule = loadModule(fixture, function() return pendingTask end)
hardRefreshModule.hardRefreshClaude("full")
local hardRefreshMenu = hardRefreshModule.menuItems()
assert(titleText(hardRefreshMenu[1]):find("updating", 1, true),
  "in-flight hard refresh did not render the updating indicator")

return "PASS: Hammerspoon projection contract"
