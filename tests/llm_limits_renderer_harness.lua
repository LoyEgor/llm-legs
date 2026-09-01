local source = debug.getinfo(1, "S").source
local root = source:match("^@(.+)/tests/[^/]+$")
assert(root, "renderer harness path is unavailable")

-- What the fake io.open hands back for the doctor snapshot, so the fake decoder knows which of
-- the two documents it is being asked for.
local DOCTOR_CONTENTS = "<doctor-snapshot>"

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

local function loadModule(fixture, taskFactory, nowOverride, alertFn, osascriptFn,
    workerModel, fsAttributes, interfaceStyle, doctorSnapshot)
  local mock = {
    alert = { show = alertFn or function() end },
    execute = function() return true end,
    fs = { attributes = fsAttributes or function() return nil end },
    host = { interfaceStyle = function() return interfaceStyle end },
    -- The doctor snapshot is a second document read through the same decoder, so the fixture is
    -- chosen by what the fake io.open handed back rather than by call order.
    json = { decode = function(text)
      if text == DOCTOR_CONTENTS then return doctorSnapshot end
      return type(fixture) == "function" and fixture() or fixture
    end },
    osascript = { applescript = osascriptFn or function() return true, true, {} end },
    styledtext = { new = styled },
    task = { new = taskFactory or function() return nil end },
  }
  -- Writes stay in the harness: the module appends to its action log through this, and a test
  -- reading the real ~/.hammerspoon log would both miss the lines and dirty a live file.
  local writes = {}
  local fakeIo = setmetatable({
    open = function(path, mode)
      if type(mode) == "string" and (mode:find("a", 1, true) or mode:find("w", 1, true)) then
        writes[path] = writes[path] or {}
        return {
          write = function(_, text) table.insert(writes[path], text); return true end,
          close = function() end,
        }
      end
      if path:match("/%.config/opencode%-go/profiles$")
          or path:match("/worker%-stats/walls%.jsonl$") then
        return nil
      end
      local contents = "fixture"
      if path:match("/doctor%-snapshot%.json$") then
        if doctorSnapshot == nil then return nil end
        contents = DOCTOR_CONTENTS
      end
      if path:match("/%.claude/worker%-model$") then
        if workerModel == nil then return nil end
        contents = workerModel
      end
      return {
        read = function() return contents end,
        lines = function() return tostring(contents):gmatch("[^\r\n]+") end,
        close = function() end,
      }
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
  local module = chunk()
  module.__writes = writes
  return module
end

local function bucket(pct, stale)
  return { effective_pct = pct, resets_at = os.time() + 3600, stale = stale == true }
end

local function titleText(item)
  return type(item.title) == "table" and item.title.text or item.title
end

-- Every account row now trails an age (`never` when the snapshot carries no instant), so the row
-- is found by its name field, not by the whole title.
local function accountIndex(menu, account)
  for index, item in ipairs(menu) do
    local text = titleText(item)
    if text:sub(1, #account) == account
        and (text:len() == #account or text:sub(#account + 1, #account + 1):match("%s")) then
      return index
    end
  end
  error("account row missing: " .. account)
end

local function accountHasMarker(menu, account)
  for _, item in ipairs(menu) do
    local text = titleText(item)
    if text:sub(1, #account) == account
        and (text:len() == #account or text:sub(#account + 1, #account + 1):match("%s")) then
      return text:find("●", 1, true) ~= nil
    end
  end
  error("account row missing: " .. account)
end

local function accountItem(menu, account)
  for _, item in ipairs(menu) do
    local text = titleText(item)
    if text:sub(1, #account) == account
        and (text:len() == #account or text:sub(#account + 1, #account + 1):match("%s")) then
      return item
    end
  end
  error("account row missing: " .. account)
end

local function submenuItem(row, title)
  for _, item in ipairs(row.menu or {}) do
    if titleText(item) == title then return item end
  end
  return nil
end

local function routingItem(menu)
  for _, item in ipairs(menu) do
    if titleText(item) == "Routing" then return item end
  end
  error("Routing row missing")
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

-- The dim tone is the menu's own text colour at 55%, so it flips with the appearance; anything
-- pinned to one appearance would be invisible in the other. Nothing in this menu is a fixed gray,
-- and tests/test_llm_limits.sh fails if one comes back.
local function isDimmed(attributes, level)
  local color = attributes and attributes.color
  if type(color) ~= "table" or color.alpha ~= 0.55 then return false end
  if level and color.red ~= level then return false end
  return color.red == color.green and color.green == color.blue
end

-- The pin keeps the full label colour in every state, honoured or not: an ignored pin is already
-- visible in the row itself, and a mark nobody can see is worse than a mark that overstates.
local function accountMarkerRun(menu, account)
  local item = accountItem(menu, account)
  for index, run in ipairs(item.title.runs or {}) do
    if run.text:find("●", 1, true) then return run, index end
  end
  error("account marker missing: " .. account)
end

-- No colour of its own: the pin inherits the row's, which is the only way it reads as strong as
-- everything else in both appearances.
local function accountMarkerIsLabel(menu, account)
  local run = accountMarkerRun(menu, account)
  return run.attributes ~= nil and run.attributes.color == nil
end

-- Straight after the name, ahead of the age and the warnings.
local function accountMarkerIsFirst(menu, account)
  local _, index = accountMarkerRun(menu, account)
  return index == 2
end

local function assertNoRed(item, message)
  assert(#redRuns(item.title) == 0, message)
end

local fixture = { schema = 1, vendors = {
  claude = {
    available = true,
    source = "claudeb-store",
    accounts = {
      {
        account = "full",
        five_hour = bucket(100, true), weekly = bucket(40), fable = bucket(30),
        rotation = {
          usable = { general = true, fable = true },
        },
      },
      {
        account = "weekly-full",
        five_hour = bucket(20), weekly = bucket(100), fable = bucket(30),
        rotation = { usable = { general = true, fable = true } },
      },
      {
        account = "fable-full",
        five_hour = bucket(20), weekly = bucket(30), fable = bucket(100),
        rotation = { usable = { general = true, fable = true } },
      },
      {
        account = "fable85",
        five_hour = bucket(20), weekly = bucket(30), fable = bucket(85),
        rotation = { usable = { general = true, fable = true } },
      },
      {
        account = "fresh",
        five_hour = bucket(10), weekly = bucket(20), fable = bucket(30),
        rotation = { usable = { general = true, fable = true } },
      },
      {
        account = "no-stale",
        five_hour = { effective_pct = 10, resets_at = os.time() + 3600 },
        rotation = { usable = { general = true, fable = true } },
      },
      {
        account = "no-reset",
        five_hour = { effective_pct = 10, resets_at = nil, stale = false },
        rotation = { usable = { general = true, fable = true } },
      },
      {
        account = "past-reset",
        five_hour = { effective_pct = 0, resets_at = os.time() - 1800, stale = false, expired = true },
        rotation = { usable = { general = true, fable = true } },
      },
      {
        account = "past-reset-unflagged",
        five_hour = { effective_pct = 0, resets_at = os.time() - 1800, stale = false, expired = false },
        rotation = { usable = { general = true, fable = true } },
      },
      {
        account = "skew-reset",
        five_hour = { effective_pct = 0, resets_at = os.time() - 30, stale = false, expired = false },
        rotation = { usable = { general = true, fable = true } },
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
assert(hasDimRed(menu[full + 1].title), "stale at-limit five-hour row was not dimmed")
assertNoRed(menu[full + 2], "under-limit weekly row rendered red")
assertNoRed(menu[full + 3], "under-limit fable row rendered red")

local warning = accountIndex(menu, "fable85")
assertNoRed(menu[warning], "fable warning colored the account title")
assertNoRed(menu[warning + 1], "fable warning colored the five-hour row")
assertNoRed(menu[warning + 2], "fable warning colored the weekly row")
local warningRuns = redRuns(menu[warning + 3].title)
assert(#warningRuns == 1 and warningRuns[1] == "▓▓▓▓░", "fable warning did not color only its usage bar")

local weeklyFull = accountIndex(menu, "weekly-full")
assert(#redRuns(menu[weeklyFull].title) > 0, "weekly exhaustion did not color the account title")
assertNoRed(menu[weeklyFull + 1], "under-limit five-hour row rendered red")
assert(#redRuns(menu[weeklyFull + 2].title) > 0, "at-limit weekly row is not red")
assertNoRed(menu[weeklyFull + 3], "under-limit fable row rendered red")

local fableFull = accountIndex(menu, "fable-full")
assertNoRed(menu[fableFull], "fable-only exhaustion colored the account title")
assertNoRed(menu[fableFull + 1], "under-limit five-hour row rendered red")
assertNoRed(menu[fableFull + 2], "under-limit weekly row rendered red")
assert(#redRuns(menu[fableFull + 3].title) > 0, "at-limit fable row is not red")

local fresh = accountIndex(menu, "fresh")
for offset = 0, 3 do
  assertNoRed(menu[fresh + offset], "fresh under-limit account rendered red")
end

local noStale = accountIndex(menu, "no-stale")
assert(not isDimmed(menu[noStale + 1].title.attributes), "missing stale flag fabricated dim styling")

local noReset = accountIndex(menu, "no-reset")
assert(titleText(menu[noReset + 1]):find("–", 1, true), "null reset did not render a dash")

local pastReset = accountIndex(menu, "past-reset")
local expectedPast = os.date("%H:%M", os.time() - 1800)
assert(titleText(menu[pastReset + 1]):find(expectedPast, 1, true),
  "real past reset did not render its clock time")

local pastUnflagged = accountIndex(menu, "past-reset-unflagged")
assert(isDimmed(menu[pastUnflagged + 1].title.attributes),
  "past resets_at without expired flag did not render dim")
assert(titleText(menu[pastUnflagged + 1]):find(expectedPast, 1, true),
  "render-time-expired row lost its real clock time")

local skewReset = accountIndex(menu, "skew-reset")
assert(not isDimmed(menu[skewReset + 1].title.attributes),
  "clock skew within tolerance was fabricated as expired")

local fresh5h = accountIndex(menu, "fresh")
assert(not isDimmed(menu[fresh5h + 1].title.attributes),
  "future resets_at was rendered dim")

local pinFixture = { schema = 1, vendors = {
  claude = { available = true, source = "claudeb-store", accounts = {
    { account = "claude-current", is_current = true, five_hour = bucket(10) },
    { account = "claude-pin", is_current = false, five_hour = bucket(20) },
  } },
  codex = {
    available = true,
    accounts = {
      { account = "codex-current", is_current = true, five_hour = bucket(10) },
      { account = "codex-pin", is_current = false, five_hour = bucket(20) },
    },
  },
  gemini = { available = true, accounts = {
    { account = "gemini-current", is_current = true, five_hour = bucket(10) },
    { account = "gemini-pin", is_current = false, five_hour = bucket(20) },
  } },
}}
local pinConfig = table.concat({
  "claudeb_profile=claude-pin",
  "codex_profile=codex-pin",
  "gemini_profile=gemini-pin",
}, "\n")
local pinMenu = loadModule(pinFixture, nil, nil, nil, nil, pinConfig).menuItems()
for _, vendor in ipairs({ "claude", "codex", "gemini" }) do
  assert(accountHasMarker(pinMenu, vendor .. "-pin"), vendor .. " pin did not render ●")
  assert(not accountHasMarker(pinMenu, vendor .. "-current"),
    vendor .. " is_current rendered ● without a pin")
  local pinnedToggle = submenuItem(accountItem(pinMenu, vendor .. "-pin"), "Pin for workers")
  local unpinnedToggle = submenuItem(accountItem(pinMenu, vendor .. "-current"), "Pin for workers")
  assert(pinnedToggle and pinnedToggle.checked == true,
    vendor .. " pinned account did not render a checked pin toggle")
  assert(unpinnedToggle and unpinnedToggle.checked == false,
    vendor .. " unpinned account did not render an unchecked pin toggle")
end

local function claudePinMenu(block)
  return loadModule({ schema = 1, vendors = {
    claude = { available = true, source = "claudeb-store", accounts = { block } },
    codex = { available = false },
    gemini = { available = false },
  } }, nil, nil, nil, nil, "claudeb_profile=pinned").menuItems()
end

local authLapsedMenu = claudePinMenu({
  account = "pinned", auth_needed = true,
})
assert(accountHasMarker(authLapsedMenu, "pinned"), "auth-needed pin hid ●")
assert(accountMarkerIsLabel(authLapsedMenu, "pinned"), "auth-needed pin marker was dimmed")
local removedLapsedMenu = claudePinMenu({
  account = "pinned", removed = true, five_hour = bucket(10),
})
assert(accountHasMarker(removedLapsedMenu, "pinned"), "removed pin hid ●")
assert(accountMarkerIsLabel(removedLapsedMenu, "pinned"), "removed pin marker was dimmed")
local limitLapsedMenu = claudePinMenu({
  account = "pinned", five_hour = bucket(100),
})
assert(accountHasMarker(limitLapsedMenu, "pinned"), "at-limit pin hid ●")
assert(accountMarkerIsLabel(limitLapsedMenu, "pinned"), "at-limit pin marker was dimmed")
local blockedLapsedMenu = claudePinMenu({
  account = "pinned", blocked = true, five_hour = bucket(10),
})
assert(accountHasMarker(blockedLapsedMenu, "pinned"), "blocked pin hid ●")
assert(accountMarkerIsLabel(blockedLapsedMenu, "pinned"), "blocked pin marker was dimmed")
local honouredMenu = claudePinMenu({
  account = "pinned", five_hour = bucket(10),
})
assert(accountHasMarker(honouredMenu, "pinned"), "honoured pin lost ●")
assert(accountMarkerIsLabel(honouredMenu, "pinned"), "honoured pin marker was dimmed")
assert(accountMarkerIsFirst(honouredMenu, "pinned"), "pin did not sit right after the name")
local excludedHonouredMenu = claudePinMenu({
  account = "pinned", enabled = false, five_hour = bucket(10),
})
assert(accountHasMarker(excludedHonouredMenu, "pinned"), "pool-excluded pin lost ●")
assert(accountMarkerIsLabel(excludedHonouredMenu, "pinned"),
  "pool-excluded honoured pin marker was dimmed")

local routingNow = 200000
local routingText = table.concat({
  "NEXT: claudeb alpha · opus · high  |  codex beta · high — FRESH PINNED  |  gemini gamma · pro · high",
  "codex: beta  · exact spacing | main 5h 10%",
  "gemini: gamma | main",
  "claude: alpha | session*   (* = this session account, excluded from worker routing)",
  "POLICY: preserve this text verbatim",
  "DATA: 4 min old",
  "SESSION: main — fb 12%, wk 34%",
  "",
  "# Worker routing policy",
  "This must never render.",
}, "\n")
local routingFixture = { schema = 1, vendors = {
  claude = { available = false },
  codex = { available = false },
  gemini = { available = false },
}}
local freshRouting = loadModule(routingFixture, nil, routingNow)
freshRouting.routingCache = { text = routingText, at = routingNow }
local freshRoutingMenu = routingItem(freshRouting.menuItems()).menu
local expectedRouting = {
  "NEXT:",
  "  claudeb alpha · opus · high",
  "  codex beta · high — FRESH PINNED",
  "  gemini gamma · pro · high",
  "codex:",
  "  beta  · exact spacing",
  "  main 5h 10%",
  "gemini:",
  "  gamma",
  "  main",
  "claude:",
  "  alpha",
  "  session*",
  "  (* = this session account, excluded from worker routing)",
  "POLICY: preserve this text verbatim",
  "DATA: 4 min old",
  "SESSION: main — fb 12%, wk 34%",
}
assert(titleText(freshRoutingMenu[1]) == "as of " .. os.date("%H:%M", routingNow),
  "routing cache caption changed")
assert(#freshRoutingMenu == #expectedRouting + 1,
  "routing policy heading or trailing lines were not truncated")
for index, expected in ipairs(expectedRouting) do
  assert(titleText(freshRoutingMenu[index + 1]) == expected,
    "routing line was not rendered verbatim: " .. expected)
  assert(freshRoutingMenu[index + 1].disabled == true, "routing line is clickable")
end

local staleRouting = loadModule(routingFixture, nil, routingNow, nil, nil, nil,
  function(path)
    if path:match("%.llm%-limits%.json$") then return { modification = routingNow } end
    return nil
  end)
staleRouting.routingCache = { text = routingText, at = routingNow - 1 }
for _, item in ipairs(routingItem(staleRouting.menuItems()).menu) do
  assert(isDimmed(item.title.attributes), "stale routing cache line was not dimmed")
end

local unavailableRouting = loadModule(routingFixture, nil, routingNow)
local unavailableMenu = routingItem(unavailableRouting.menuItems()).menu
assert(#unavailableMenu == 1 and titleText(unavailableMenu[1]) == "routing unavailable",
  "missing routing cache did not render the unavailable row")
assert(isDimmed(unavailableMenu[1].title.attributes), "routing unavailable row was not dimmed")

-- Pool membership is one control with one meaning for every vendor, so the toggle has to exist
-- on the Codex and Gemini rows too; without it the state is only reachable from a terminal.
local poolFixture = { schema = 1, vendors = {
  claude = { available = false },
  codex = { available = true, accounts = {
    { account = "main", is_current = true, enabled = true, five_hour = bucket(10) },
    { account = "spare", is_current = false, enabled = false, five_hour = bucket(20) },
  } },
  gemini = { available = true, accounts = {
    { account = "main", is_current = true, enabled = true, five_hour = bucket(10) },
    { account = "work", is_current = false, enabled = false, five_hour = bucket(20) },
  } },
}}
local function isPoolItem(item)
  local text = item and (type(item.title) == "string" and item.title or titleText(item)) or ""
  return text == "In worker pool"
end

local poolRows = {}
for _, item in ipairs(loadModule(poolFixture).menuItems()) do
  local text = titleText(item)
  for _, name in ipairs({ "main", "spare", "work" }) do
    if text:find(name, 1, true) and item.menu then
      for _, sub in ipairs(item.menu) do
        if isPoolItem(sub) then
          poolRows[#poolRows + 1] = { name = name, checked = sub.checked, rowChecked = item.checked,
            title = sub.title }
        end
      end
    end
  end
end
assert(#poolRows == 4, "worker-pool toggle missing from Codex/Gemini account rows")
for _, row in ipairs(poolRows) do
  local expected = row.name == "main"
  assert(row.checked == expected and row.rowChecked == expected,
    "worker-pool toggle disagreed with enabled for " .. row.name)
end

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
    assert(isDimmed(item.title.attributes), "vendor refresh error was not dim")
  end
end
assert(deadErrorSeen, "structured vendor refresh error did not render")
assert(errorModule.refreshState().prefix == "⚠ ", "vendor error did not warn in the title state")

local entryCause = "alona: not refreshed (needs-relogin)"
local entryFixture = { schema = 1, vendors = {
  claude = {
    available = true,
    source = "claudeb-store",
    refresh_error = { cause = entryCause, at = os.time() - 600, needs_user_entry = true },
    accounts = {{
      account = "alona",
      enabled = true,
      as_of = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 600),
      needs_user_entry = true,
      five_hour = bucket(10, true),
    }},
  },
  codex = { available = false },
  gemini = { available = false },
}}
local entryModule = loadModule(entryFixture)
assert(entryModule.refreshState().prefix == "",
  "entry-only vendor error lit the global warning title")
local entryMenu = entryModule.menuItems()
local entryRow = accountItem(entryMenu, "alona")
assert(titleText(entryRow):find("10m", 1, true) and titleText(entryRow):find("!", 1, true),
  "entry-only account row lacks its age-adjacent ! marker")
-- The age and the marks beside it follow the menu's own secondary label colour: the fixed gray
-- they used to carry washed out against the menu instead of reading as the rest of the row.
for _, run in ipairs(entryRow.title.runs or {}) do
  if run.text:find("10m", 1, true) or run.text:find("!", 1, true) then
    assert(isDimmed(run.attributes, 0), "age or ! marker was not dim black in the light appearance")
  end
end
local darkEntryRow = accountItem(
  loadModule(entryFixture, nil, nil, nil, nil, nil, nil, "Dark").menuItems(), "alona")
for _, run in ipairs(darkEntryRow.title.runs or {}) do
  if run.text:find("10m", 1, true) or run.text:find("!", 1, true) then
    assert(isDimmed(run.attributes, 1), "age or ! marker stayed black in the dark appearance")
  end
end
local entryErrorSeen = false
for _, item in ipairs(entryMenu) do
  if titleText(item):find("refresh failed", 1, true)
      and titleText(item):find("needs-relogin", 1, true) then
    entryErrorSeen = true
  end
end
assert(entryErrorSeen, "entry-only error text disappeared from the vendor section")

local mixedFixture = { schema = 1, vendors = {
  claude = {
    available = true,
    source = "claudeb-store",
    refresh_error = {
      cause = entryCause .. "; bree: not refreshed (network weather)",
      at = os.time() - 600,
    },
    accounts = entryFixture.vendors.claude.accounts,
  },
  codex = { available = false },
  gemini = { available = false },
}}
assert(loadModule(mixedFixture).refreshState().prefix == "⚠ ",
  "mixed entry/fault vendor error did not light the global warning title")

local clearModule = loadModule(fixture)
assert(clearModule.refreshState().prefix == "", "successful cache retained a warning title")
for _, item in ipairs(clearModule.menuItems()) do
  assert(not titleText(item):find("refresh failed", 1, true),
    "successful cache retained a vendor error row")
end

local multiCause = "olx: not refreshed (usage weather); notcom: not refreshed (token endpoint 429)"
local multiFixture = { schema = 1, vendors = {
  claude = { available = false, refresh_error = { cause = multiCause, at = os.time() - 120 } },
  codex = { available = false },
  gemini = { available = false },
}}
local multiMenu = loadModule(multiFixture).menuItems()
local multiRows = {}
for _, item in ipairs(multiMenu) do
  local text = titleText(item)
  if text:find("not refreshed", 1, true) then
    table.insert(multiRows, text)
    assert(not text:find("; ", 1, true), "per-account refresh error row still joined by \"; \"")
  end
end
assert(#multiRows == 2, "multi-account cause did not render one row per entry")
assert(multiRows[1]:find("olx", 1, true), "first per-account row missing its account name")
assert(multiRows[2]:find("notcom", 1, true), "second per-account row missing its account name")

local singleFixture = { schema = 1, vendors = {
  claude = { available = false,
    refresh_error = { cause = "olx: not refreshed (usage weather)", at = os.time() - 120 } },
  codex = { available = false },
  gemini = { available = false },
}}
local singleRows = 0
for _, item in ipairs(loadModule(singleFixture).menuItems()) do
  if titleText(item):find("not refreshed", 1, true) then singleRows = singleRows + 1 end
end
assert(singleRows == 1, "single per-account cause did not render exactly one row")

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

local function rowContaining(menu, needle)
  for _, item in ipairs(menu) do
    if titleText(item):find(needle, 1, true) and type(item.menu) == "table" then
      return item
    end
  end
  error("no submenu row containing: " .. needle)
end

-- Named for the login action it drives, not for a fixed index: the pool toggle now sits above it.
local function runFirstItem(item, capture)
  local login
  for _, sub in ipairs(item.menu) do
    if titleText(sub) == "Log in…" then login = sub end
  end
  assert(login, "login row has no Log in… item")
  local last
  login.fn()
  last = capture[#capture]
  assert(last, "Log in… fn did not invoke osascript")
  return last
end

-- Captures every hs.task.new launch so the Remove… confirm item can be proven to
-- fire the right vendor command (claudeb/codexb subcommand or the collector marker).
-- Keeps the completion callback, so a test can finish a task and watch what the module does with
-- the result: the optimistic pool state and the log both live on that path.
local function driveTasks(sink)
  return function(path, callback, args)
    local record = { path = path, args = args or {}, env = {}, callback = callback, running = false }
    table.insert(sink, record)
    local task = {}
    function task:setEnvironment(env) record.env = env or {}; return self end
    function task:start() record.running = true; return true end
    function task:isRunning() return record.running end
    return task
  end
end

local function captureTasks(sink)
  return function(path, _, args)
    local record = { path = path, args = args or {}, env = {} }
    table.insert(sink, record)
    local task = {}
    function task:setEnvironment(env) record.env = env or {}; return self end
    function task:start() return true end
    function task:isRunning() return false end
    return task
  end
end

-- A toggle that succeeded has to show in the very next menu, not only after the collect lands:
-- the stale checkmark is what made a second click look necessary, and that second click was then
-- swallowed by the in-flight guard without a word. Live cost: an account was added to the pool by
-- the click meant to take it out, twice in one evening.
do
  local tasks = {}
  local alerts = {}
  local mod = loadModule(poolFixture, driveTasks(tasks), nil,
    function(text) table.insert(alerts, text) end)
  local function poolItemFor(module, account)
    for _, item in ipairs(module.menuItems()) do
      if titleText(item):find(account, 1, true) then
        for _, sub in ipairs(item.menu or {}) do
          if isPoolItem(sub) then return sub end
        end
      end
    end
  end
  local before = poolItemFor(mod, "spare")
  assert(before and before.checked == false, "codex spare did not start out of the pool")
  -- Building the menu already launched a passive collect; the toggle is what the sink must hold.
  while #tasks > 0 do table.remove(tasks) end
  before.fn()
  local launched = tasks[1]
  assert(launched and launched.path:find("codexb", 1, true)
      and launched.args[1] == "enable" and launched.args[2] == "spare",
    "pool toggle launched the wrong command")
  before.fn()
  assert(#tasks == 1, "a second click while the first was in flight launched a duplicate command")
  assert(#alerts == 1 and alerts[1]:find("still running", 1, true),
    "a click swallowed by the in-flight guard stayed silent")
  launched.callback(0, "", "")
  local after = poolItemFor(mod, "spare")
  assert(after and after.checked == true,
    "a successful toggle did not show in the next menu build")
  local collect = tasks[2]
  assert(collect and collect.path:find("llm%-limits", 1, false),
    "a successful vendor command did not start the follow-up collect")
  collect.callback(0, "", "")
  local logPath = os.getenv("HOME") .. "/.hammerspoon/llm_limits_actions.log"
  local logged = table.concat(mod.__writes[logPath] or {}, "")
  assert(logged:find("codexb enable spare", 1, true), "the launched action was not logged")
  assert(logged:find("already-running", 1, true), "the swallowed click was not logged")
  assert(logged:find("collect", 1, true), "the follow-up collect was not logged")
end

do
  local tasks = {}
  local mod = loadModule(pinFixture, captureTasks(tasks), nil, nil, nil, pinConfig)
  local menu = mod.menuItems()
  local cases = {
    { account = "claude-pin", command = "claudeb", arg = "--clear" },
    { account = "claude-current", command = "claudeb", arg = "claude-current" },
    { account = "codex-pin", command = "codexb", arg = "--clear" },
    { account = "codex-current", command = "codexb", arg = "codex-current" },
    { account = "gemini-pin", command = "geminib", arg = "--clear" },
    { account = "gemini-current", command = "geminib", arg = "gemini-current" },
  }
  for _, case in ipairs(cases) do
    while #tasks > 0 do table.remove(tasks) end
    submenuItem(accountItem(menu, case.account), "Pin for workers").fn()
    local launched = tasks[1]
    assert(launched and launched.path:find(case.command, 1, true),
      case.account .. " pin toggle launched the wrong command")
    assert(launched.args[1] == "use" and launched.args[2] == case.arg,
      case.account .. " pin toggle launched the wrong use action")
  end
end

do
  local fixture = { schema = 1, vendors = {
    claude = { available = false },
    codex = { available = false },
    gemini = { available = true, five_hour = bucket(10), weekly = bucket(20) },
  }}
  local tasks = {}
  local pinnedMenu = loadModule(fixture, captureTasks(tasks), nil, nil, nil,
    "gemini_profile=main").menuItems()
  local pinnedRow = accountItem(pinnedMenu, "Gemini")
  local pinnedToggle = submenuItem(pinnedRow, "Pin for workers")
  assert(pinnedToggle and pinnedToggle.checked == true,
    "single-account Gemini pin toggle was not checked")
  -- Every account row carries the pool checkbox, the sole one included: an empty pool says no
  -- worker may run, which is a state the user is allowed to reach.
  local solePool = submenuItem(pinnedRow, "In worker pool")
  assert(solePool and solePool.checked == true,
    "single-account Gemini row lost its worker-pool toggle")
  while #tasks > 0 do table.remove(tasks) end
  solePool.fn()
  assert(tasks[1] and tasks[1].path:find("geminib", 1, true)
      and tasks[1].args[1] == "disable" and tasks[1].args[2] == "main",
    "single-account Gemini pool toggle launched the wrong action")
  assert(accountHasMarker(pinnedMenu, "Gemini"), "single-account Gemini pin hid ●")
  while #tasks > 0 do table.remove(tasks) end
  pinnedToggle.fn()
  assert(tasks[1] and tasks[1].path:find("geminib", 1, true)
      and tasks[1].args[1] == "use" and tasks[1].args[2] == "--clear",
    "single-account Gemini pin clear launched the wrong action")

  tasks = {}
  local unpinnedMenu = loadModule(fixture, captureTasks(tasks), nil, nil, nil, "").menuItems()
  local unpinnedToggle = submenuItem(accountItem(unpinnedMenu, "Gemini"), "Pin for workers")
  assert(unpinnedToggle and unpinnedToggle.checked == false,
    "single-account Gemini unpinned toggle was not clear")
  while #tasks > 0 do table.remove(tasks) end
  unpinnedToggle.fn()
  assert(tasks[1] and tasks[1].path:find("geminib", 1, true)
      and tasks[1].args[1] == "use" and tasks[1].args[2] == "main",
    "single-account Gemini pin launched the wrong action")
end

do
  local fixture = { schema = 1, vendors = {
    claude = { available = true, source = "claudeb-store", accounts = {
      { account = "claude-live", five_hour = bucket(10) },
    }},
    codex = { available = true, accounts = {
      { account = "codex-live", five_hour = bucket(10) },
    }},
    gemini = { available = true, accounts = {
      { account = "main", five_hour = bucket(10), weekly = bucket(20) },
      { account = "gemini-orphan", removed = true },
    }},
  }}
  local config = table.concat({
    "claudeb_profile=claude-orphan",
    "codex_profile=codex-orphan",
    "gemini_profile=gemini-orphan",
  }, "\n")
  local tasks = {}
  local menu = loadModule(fixture, captureTasks(tasks), nil, nil, nil, config).menuItems()
  local cases = {
    { account = "claude-orphan", command = "claudeb" },
    { account = "codex-orphan", command = "codexb" },
    { account = "gemini-orphan", command = "geminib" },
  }
  for _, case in ipairs(cases) do
    local row = accountItem(menu, case.account)
    assert(accountMarkerIsLabel(menu, case.account),
      case.account .. " orphaned pin marker was dimmed")
    assert(#row.menu == 1, case.account .. " orphaned pin row offered extra actions")
    local pin = submenuItem(row, "Pin for workers")
    assert(pin and pin.checked == true,
      case.account .. " orphaned pin did not offer a checked clear action")
    while #tasks > 0 do table.remove(tasks) end
    pin.fn()
    assert(tasks[1] and tasks[1].path:find(case.command, 1, true)
        and tasks[1].args[1] == "use" and tasks[1].args[2] == "--clear",
      case.account .. " orphaned pin clear launched the wrong action")
  end
end

local claudeLoginFixture = { schema = 1, vendors = {
  claude = {
    available = true, source = "claudeb-store",
    accounts = {
      { account = "loggedout", auth_needed = true },
      { account = "healthy", five_hour = bucket(10),
        rotation = { usable = { general = true, fable = true } } },
    },
  },
  codex = { available = false },
  gemini = { available = false },
}}
local codexLoginFixture = { schema = 1, vendors = {
  claude = { available = false },
  codex = { available = true, accounts = {
    { account = "codexout", auth_needed = true },
  }},
  gemini = { available = false },
}}
local geminiMultiFixture = { schema = 1, vendors = {
  claude = { available = false },
  codex = { available = false },
  gemini = { available = true, current_account = "main", accounts = {
    { account = "main", is_current = true, five_hour = bucket(10), weekly = bucket(20) },
    { account = "work", auth_needed = true,
      refresh_error = { cause = "login needed (not signed in)", at = os.time() - 60 } },
    { account = "removed", removed = true },
  }},
}}
local geminiAllAuthFixture = { schema = 1, vendors = {
  claude = { available = false },
  codex = { available = false },
  gemini = { available = false, auth_needed = true, accounts = {
    { account = "main", is_current = true, auth_needed = true },
    { account = "work", auth_needed = true },
  }},
}}
local grokLoginFixture = { schema = 1, vendors = {
  claude = { available = false },
  codex = { available = false },
  gemini = { available = false },
  grok = { available = true, accounts = {
    { account = "grokout", auth_needed = true, auth = { status = "needs_login" } },
  }},
}}

do
  local cases = {
    {
      vendor = "claude", fixture = claudeLoginFixture, account = "loggedout",
      config = "claudeb_profile=loggedout", command = "claudeb",
    },
    {
      vendor = "codex", fixture = codexLoginFixture, account = "codexout",
      config = "codex_profile=codexout", command = "codexb",
    },
    {
      vendor = "gemini", fixture = geminiMultiFixture, account = "work",
      config = "gemini_profile=work", command = "geminib",
    },
    {
      vendor = "grok", fixture = grokLoginFixture, account = "grokout",
      config = "grok_profile=grokout", command = "grokb",
    },
  }
  for _, case in ipairs(cases) do
    local tasks = {}
    local pinnedMenu = loadModule(case.fixture, captureTasks(tasks), nil, nil, nil,
      case.config).menuItems()
    local pinnedRow = accountItem(pinnedMenu, case.account)
    local pin = submenuItem(pinnedRow, "Pin for workers")
    assert(pin and pin.checked == true,
      case.vendor .. " logged-out pin did not render a checked clear action")
    assert(accountMarkerIsLabel(pinnedMenu, case.account),
      case.vendor .. " logged-out pin marker was dimmed")
    assert(accountMarkerIsFirst(pinnedMenu, case.account),
      case.vendor .. " logged-out pin did not sit right after the name")
    while #tasks > 0 do table.remove(tasks) end
    pin.fn()
    local launched = tasks[1]
    assert(launched and launched.path:find(case.command, 1, true),
      case.vendor .. " logged-out pin clear launched the wrong command")
    assert(launched.args[1] == "use" and launched.args[2] == "--clear",
      case.vendor .. " logged-out pin action was not clear-only")
    local unpinnedMenu = loadModule(case.fixture, nil, nil, nil, nil, "").menuItems()
    assert(submenuItem(accountItem(unpinnedMenu, case.account), "Pin for workers") == nil,
      case.vendor .. " logged-out unpinned row offered pinning")
  end
end

-- Anti-divergence guard: every vendor's unpinned logged-out row is forced through the SAME
-- shape here. Adding a 4th vendor to this table automatically subjects it to the
-- identical structural assertions (title, {Log in…, Hard refresh, Remove <label>} in order,
-- and — where the vendor has no section header — the vendor's role switches after them) while
-- still proving its own Log in… fires the right login mechanism and Remove the right remove
-- command. A future change that splits one vendor's row away from the shared shape fails this loop.
local loginCases = {
  { vendor = "claude", fixture = claudeLoginFixture, needle = "loggedout", label = "loggedout",
    scriptContains = { "claudeb profile", "loggedout" },
    removePath = "claudeb", removeArgs = { "remove", "loggedout", "--force" } },
  { vendor = "codex", fixture = codexLoginFixture, needle = "codexout", label = "codexout",
    scriptContains = { "codexb run", "codexout", "login" },
    removePath = "codexb", removeArgs = { "remove", "codexout", "--force" } },
  { vendor = "gemini", fixture = geminiAuthFixture, needle = "Gemini", label = "Gemini",
    scriptContains = { "geminib profile", "main" },
    refreshArgs = { "--refresh-account", "gemini/main" },
    removePath = "llm-limits.sh", removeArgs = { "--gemini-remove" },
    -- The sole-account vendor row IS the vendor's section, so it carries the role switches.
    roleSwitches = true },
  { vendor = "gemini profile", fixture = geminiMultiFixture, needle = "work", label = "work",
    scriptContains = { "geminib profile", "work" },
    refreshArgs = { "--refresh-account", "gemini/work" },
    removePath = "geminib", removeArgs = { "remove", "work" } },
  { vendor = "gemini all-auth", fixture = geminiAllAuthFixture, needle = "work", label = "work",
    scriptContains = { "geminib profile", "work" },
    refreshArgs = { "--refresh-account", "gemini/work" },
    removePath = "geminib", removeArgs = { "remove", "work" } },
  { vendor = "grok", fixture = grokLoginFixture, needle = "grokout", label = "grokout",
    scriptContains = { "grokb profile", "grokout", "login" },
    refreshArgs = { "--refresh-account", "grok/grokout" },
    removePath = "grokb", removeArgs = { "remove", "grokout", "--force" } },
}
for _, case in ipairs(loginCases) do
  local capture = {}
  local tasks = {}
  local menu = loadModule(case.fixture, captureTasks(tasks), nil, nil,
    function(script) table.insert(capture, script); return true, true, {} end).menuItems()
  local row = rowContaining(menu, case.needle)
  assert(titleText(row):find("login needed", 1, true),
    "logged-out " .. case.vendor .. " row did not render a login-needed row")
  assert(#row.menu == (case.roleSwitches and 5 or 3),
    case.vendor .. " login row is not exactly {Log in…, Hard refresh, Remove <label>}"
      .. (case.roleSwitches and " plus the two role switches" or ""))
  if case.roleSwitches then
    assert(titleText(row.menu[4]) == "For workers" and titleText(row.menu[5]) == "For reviewers",
      case.vendor .. " login row lost the vendor's role switches")
  end
  assert(titleText(row.menu[1]) == "Log in…", case.vendor .. " first submenu item is not Log in…")
  assert(titleText(row.menu[2]) == "Hard refresh", case.vendor .. " second submenu item is not Hard refresh")
  -- One click, no nested confirm: the item names the account so the destination is unambiguous.
  assert(titleText(row.menu[3]) == "Remove " .. case.label,
    case.vendor .. " third submenu item is not \"Remove " .. case.label .. "\"")
  assert(row.menu[3].menu == nil, case.vendor .. " Remove regrew a confirm submenu")
  -- Offering the worker pool here would claim an availability a logged-out account does not
  -- have; the stored exclusion is still there and shows up again once it is logged back in.
  for _, sub in ipairs(row.menu) do
    assert(not isPoolItem(sub), case.vendor .. " login row offered the worker-pool toggle")
  end
  local script = runFirstItem(row, capture)
  for _, needle in ipairs(case.scriptContains) do
    assert(script:find(needle, 1, true),
      case.vendor .. " Log in… lacks the vendor mechanism: " .. needle)
  end
  if case.refreshArgs then
    while #tasks > 0 do table.remove(tasks) end
    row.menu[2].fn()
    local launched = tasks[1]
    assert(launched and launched.path:find("llm-limits.sh", 1, true),
      case.vendor .. " Hard refresh did not launch the collector")
    for index, expected in ipairs(case.refreshArgs) do
      assert(launched.args[index] == expected,
        case.vendor .. " Hard refresh arg " .. index .. " is "
          .. tostring(launched.args[index]) .. " not " .. expected)
    end
  end
  while #tasks > 0 do table.remove(tasks) end
  row.menu[3].fn()
  local launched = tasks[1]
  assert(launched, case.vendor .. " Remove did not launch a command")
  assert(launched.path:find(case.removePath, 1, true),
    case.vendor .. " Remove launched the wrong command: " .. tostring(launched.path))
  assert(#launched.args == #case.removeArgs,
    case.vendor .. " Remove passed " .. #launched.args .. " args, not " .. #case.removeArgs)
  for index, expected in ipairs(case.removeArgs) do
    assert(launched.args[index] == expected,
      case.vendor .. " Remove arg " .. index .. " is " .. tostring(launched.args[index])
        .. " not " .. expected)
  end
end

-- grokb refuses `remove main` (the real ~/.grok), so its logged-out row must omit Remove
-- the same way Codex does.
local grokMainLoginFixture = { schema = 1, vendors = {
  claude = { available = false },
  codex = { available = false },
  gemini = { available = false },
  grok = { available = true, accounts = {
    { account = "main", is_current = true, auth_needed = true, auth = { status = "needs_login" } },
  }},
}}
do
  local menu = loadModule(grokMainLoginFixture).menuItems()
  local row = rowContaining(menu, "main")
  assert(row and titleText(row):find("login needed", 1, true),
    "grok main did not render a login-needed row")
  for _, sub in ipairs(row.menu or {}) do
    assert(not titleText(sub):find("Remove", 1, true), "grok main offered a dead Remove action")
  end
end

-- A store that never grew vendors.grok omits the section; "no live data" is for a
-- present-but-unmeasured vendor, not an absent key. Same skip for every vendor.
do
  local menu = loadModule({ schema = 1, vendors = {
    claude = { available = false },
    codex = { available = false },
    gemini = { available = false },
  }}).menuItems()
  for _, item in ipairs(menu) do
    assert(not titleText(item):find("Grok", 1, true),
      "a store without vendors.grok still rendered a Grok section")
  end
end

-- codex `main` is not removable (codexb refuses it), so its logged-out row must omit
-- the Remove… item — a login-needed row of exactly {Log in…, Hard refresh}, no dead action.
local codexMainLoginFixture = { schema = 1, vendors = {
  claude = { available = false },
  codex = { available = true, accounts = {
    { account = "main", is_current = true, auth_needed = true },
  }},
  gemini = { available = false },
}}
do
  local menu = loadModule(codexMainLoginFixture).menuItems()
  local row = rowContaining(menu, "main")
  assert(row and titleText(row):find("login needed", 1, true),
    "codex main did not render a login-needed row")
  assert(#row.menu == 2,
    "codex main login row must omit Remove… (expected exactly {Log in…, Hard refresh})")
  for _, sub in ipairs(row.menu) do
    assert(titleText(sub) ~= "Remove…", "codex main offered a dead Remove… action")
  end
end

do
  local tasks = {}
  local mod = loadModule(function() return fixture end, captureTasks(tasks))
  mod.hardRefreshClaude("acct")
  assert(tasks[1] and tasks[1].env.CLAUDEB_WARM_USER_EXPLICIT == "true",
    "menu Hard refresh did not inject CLAUDEB_WARM_USER_EXPLICIT=true")
  while #tasks > 0 do table.remove(tasks) end
  local menu = mod.menuItems()
  assert(tasks[1] and tasks[1].env.CLAUDEB_WARM_USER_EXPLICIT == nil,
    "passive menu collect inherited the manual-warm freeze exemption")
  for _, item in ipairs(menu) do
    if titleText(item) == "Refresh" or titleText(item) == "Refresh + Start Windows" then
      item.fn()
    end
  end
  assert(#tasks == 3, "global menu refresh actions did not start two collector tasks")
  for index = 2, 3 do
    assert(tasks[index].env.CLAUDEB_WARM_USER_EXPLICIT == "true",
      "global menu refresh did not inject CLAUDEB_WARM_USER_EXPLICIT=true")
  end
end

-- Healthy accounts never get Log in… or Remove…; the shared row only fires on auth_needed.
local claudeLoginMenu = loadModule(claudeLoginFixture).menuItems()
for _, item in ipairs(claudeLoginMenu) do
  if titleText(item):find("healthy", 1, true) and type(item.menu) == "table" then
    for _, sub in ipairs(item.menu) do
      assert(titleText(sub) ~= "Log in…", "healthy account offered Log in…")
      assert(titleText(sub) ~= "Remove…", "healthy account offered Remove…")
    end
  end
end
local geminiMultiMenu = loadModule(geminiMultiFixture).menuItems()
local geminiLoginNeededRows = 0
for _, item in ipairs(geminiMultiMenu) do
  local text = titleText(item)
  assert(not text:find("removed", 1, true), "removed Gemini profile still rendered a row")
  if text:find("login needed", 1, true) then
    geminiLoginNeededRows = geminiLoginNeededRows + 1
  end
  assert(not text:find("not signed in", 1, true),
    "logged-out Gemini profile duplicated its login-needed cause")
  if text:find("main", 1, true) and type(item.menu) == "table" then
    for _, sub in ipairs(item.menu) do
      assert(titleText(sub) ~= "Log in…", "healthy Gemini profile offered Log in…")
      assert(titleText(sub) ~= "Remove…", "healthy Gemini profile offered Remove…")
    end
  end
end
assert(geminiLoginNeededRows == 1,
  "logged-out Gemini profile did not render its login-needed cause exactly once")

-- A removed single-account vendor is skipped entirely: no row, no login/hard-refresh
-- controls, no refresh-error line — the same hook a future vendor would supply.
local geminiRemovedFixture = { schema = 1, vendors = {
  claude = { available = false },
  codex = { available = false },
  gemini = { available = false, removed = true, status = "removed" },
}}
for _, item in ipairs(loadModule(geminiRemovedFixture).menuItems()) do
  assert(not titleText(item):find("Gemini", 1, true), "removed Gemini still rendered a row")
end

-- And the hide is REMOVAL's alone: a roster whose accounts have never been refreshed is empty and
-- unavailable in exactly the same way, and it is a vendor to set up rather than one to hide.
local geminiFirstRunFixture = { schema = 1, vendors = {
  claude = { available = false },
  codex = { available = false },
  gemini = { available = false, status = "no quota snapshot" },
}}
local geminiFirstRunRow = false
for _, item in ipairs(loadModule(geminiFirstRunFixture).menuItems()) do
  if titleText(item):find("Gemini", 1, true) then geminiFirstRunRow = true end
end
assert(geminiFirstRunRow, "a never-refreshed Gemini was hidden like a removed one")

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
local hsRoot = assert(_G.HS_ROOT, "HS_ROOT unset: test_llm_limits.sh injects the Hammerspoon root")
local automationChunk, automationError = loadfile(
  hsRoot .. "/automation_menu.lua", "t", automationEnv)
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
    accounts = {
      { account = "sameday", five_hour = { effective_pct = 10, resets_at = sameDay },
        rotation = { usable = { general = true, fable = true } } },
      { account = "crossmid", five_hour = { effective_pct = 20, resets_at = crossMid },
        rotation = { usable = { general = true, fable = true } } },
      { account = "farweek", five_hour = { effective_pct = 30, resets_at = farWeek },
        rotation = { usable = { general = true, fable = true } } },
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

-- token_upkeep pre-warm: the module parses, arms a wake watcher and a cold-boot
-- schedule, and its throttle guard suppresses runs within 10 minutes of the last.
local upkeepClock = { now = 100000 }
local upkeepScheduled = {}
local upkeepPeriodic = {}
local upkeepTasks = {}
local upkeepWatcherStarted = false
local upkeepHs = {
  caffeinate = { watcher = {
    systemDidWake = "systemDidWake",
    new = function(fn)
      return { start = function() upkeepWatcherStarted = true end, _fn = fn }
    end,
  } },
  timer = {
    doAfter = function(_, fn) table.insert(upkeepScheduled, fn); return {} end,
    doEvery = function(interval, fn) table.insert(upkeepPeriodic, { interval = interval, fn = fn }); return {} end,
  },
  task = { new = function(path, _, args)
    table.insert(upkeepTasks, { path = path, args = args })
    return { setEnvironment = function() end, start = function() return true end }
  end },
}
local upkeepEnv = setmetatable({
  hs = upkeepHs,
  os = setmetatable({ time = function() return upkeepClock.now end }, { __index = os }),
}, { __index = _G })
upkeepEnv._G = upkeepEnv
local upkeepChunk, upkeepError = loadfile(
  root .. "/hammerspoon/config/token_upkeep.lua", "t", upkeepEnv)
assert(upkeepChunk, upkeepError)
local upkeep = upkeepChunk()
assert(upkeepWatcherStarted, "wake watcher was not started")
assert(#upkeepScheduled == 1, "cold-boot pre-warm was not scheduled on load")
assert(upkeep.shouldRun(1000, 0) == true, "first run should not be throttled")
assert(upkeep.shouldRun(1000, 600) == false, "run 400s after last must be throttled")
assert(upkeep.shouldRun(1000, 400) == true, "run exactly 600s after last must fire")
assert(upkeep.shouldRun(1000, 401) == false, "run 599s after last must be throttled")
assert(upkeep.shouldRun("x", 0) == false, "non-numeric clock must not fire a run")
upkeepScheduled[1]()
assert(#upkeepTasks == 1, "cold-boot schedule did not launch token-upkeep")
assert(upkeepTasks[1].args[1] == "token-upkeep", "wrong claudeb subcommand launched")
upkeepScheduled[1]()
assert(#upkeepTasks == 1, "second run within the throttle window was not suppressed")
upkeepClock.now = upkeepClock.now + 601
upkeepScheduled[1]()
assert(#upkeepTasks == 2, "run past the throttle window did not fire")

assert(#upkeepPeriodic == 1, "periodic upkeep timer was not armed on load")
assert(upkeepPeriodic[1].interval == 1800, "periodic upkeep interval changed")
assert(upkeep.periodicTimer ~= nil, "periodic timer must be module-scoped so it is not GC'd")
upkeepPeriodic[1].fn()
assert(#upkeepTasks == 2, "periodic run within the throttle window was not suppressed")
upkeepClock.now = upkeepClock.now + 601
upkeepPeriodic[1].fn()
assert(#upkeepTasks == 3, "periodic run past the throttle window did not fire")

-- store pathwatcher: a module-scoped watcher on the store re-renders the title
-- (never a collector — that writes the store and would loop), throttled so a
-- burst of atomic rewrites collapses to few re-renders.
local watchClock = { now = 1000 }
local watchStarts = 0
local watchTasks = {}
local watchCallbacks = {}
local watcherStarted = {}
local watchHs = {
  pathwatcher = {
    new = function(path, fn)
      watchCallbacks[path] = fn
      return { start = function() watcherStarted[path] = true end }
    end,
  },
  task = { new = function(path, callback, args)
    local record = { path = path, callback = callback, args = args }
    table.insert(watchTasks, record)
    return {
      setEnvironment = function(_, env) record.env = env end,
      start = function() watchStarts = watchStarts + 1 return true end,
      isRunning = function() return false end,
    }
  end },
}
local watchEnv = setmetatable({
  hs = watchHs,
  os = setmetatable({ time = function() return watchClock.now end }, { __index = os }),
}, { __index = _G })
watchEnv._G = watchEnv
local watchChunk, watchError = loadfile(root .. "/hammerspoon/llm-limits.lua", "t", watchEnv)
assert(watchChunk, watchError)
local watchModule = watchChunk()

assert(watchModule.shouldRerenderOnStoreChange(10, 0) == true, "first store change must re-render")
assert(watchModule.shouldRerenderOnStoreChange(11, 10) == false, "sub-throttle store change must be suppressed")
assert(watchModule.shouldRerenderOnStoreChange(12, 10) == true, "throttle-boundary store change must re-render")
assert(watchModule.shouldRerenderOnStoreChange("x", 0) == false, "non-numeric clock must not re-render")

assert(watchCallbacks[watchModule.cachePath], "watcher did not watch the store path")
assert(watcherStarted[watchModule.cachePath], "store watcher was not started")
assert(watchModule.storeWatcher ~= nil, "store watcher must be module-scoped so it is not GC'd")
assert(watchCallbacks[watchModule.workerModelPath], "watcher did not watch worker-model")
assert(watcherStarted[watchModule.workerModelPath], "worker-model watcher was not started")
assert(watchModule.workerModelWatcher ~= nil,
  "worker-model watcher must be module-scoped so it is not GC'd")
assert(#watchTasks == 1 and watchStarts == 1, "startup did not refresh routing exactly once")
assert(watchTasks[1].path == watchModule.workerPickPath, "startup launched the wrong routing command")
assert(watchTasks[1].env.WORKER_PICK_CACHE_DIR == "/dev/null",
  "routing refresh did not suppress worker-pick cache writes")

local watchNotifies = 0
watchModule.onRefreshStateChanged = function() watchNotifies = watchNotifies + 1 end
watchClock.now = 2000; watchCallbacks[watchModule.cachePath]()
watchClock.now = 2001; watchCallbacks[watchModule.cachePath]()
watchClock.now = 2002; watchCallbacks[watchModule.cachePath]()
assert(watchNotifies == 2, "store watcher throttle did not collapse a burst to two re-renders")
assert(#watchTasks == 1 and watchStarts == 1,
  "store watcher did not coalesce refreshes behind the startup task")
watchTasks[1].callback(0, routingText)
assert(watchNotifies == 3, "routing completion did not re-render the menu")
assert(#watchTasks == 2 and watchStarts == 2,
  "store watcher lost the routing refresh queued behind the startup task")
for _, task in ipairs(watchTasks) do
  assert(task.path == watchModule.workerPickPath, "watcher constructed a collector task")
end
watchTasks[2].callback(0, routingText)
watchCallbacks[watchModule.workerModelPath]()
assert(watchNotifies == 5, "worker-model watcher did not re-render the menu")
assert(#watchTasks == 3 and watchStarts == 3, "worker-model watcher did not refresh routing")

-- The vendor section header is a control, not a caption: it carries the vendor's role switches and
-- a free vendor-scoped refresh, and it names the vendor like every other surface. Pool membership
-- is per account only — a whole-vendor switch was one click from emptying the pool by accident.
local function headerRow(menu, label)
  for _, item in ipairs(menu) do
    if titleText(item) == label then return item end
  end
  error("vendor section header missing: " .. label)
end
do
  local headerFixture = { schema = 1, vendors = {
    claude = { available = true, source = "claudeb-store", accounts = {
      { account = "cl-one", is_current = true, enabled = true, five_hour = bucket(10) },
      { account = "cl-two", is_current = false, enabled = false, five_hour = bucket(20) },
    } },
    codex = { available = true, accounts = {
      { account = "cx-one", is_current = true, enabled = true, five_hour = bucket(10) },
      { account = "cx-two", is_current = false, enabled = false, five_hour = bucket(20) },
    } },
    gemini = { available = true, accounts = {
      { account = "gm-one", is_current = true, enabled = true, five_hour = bucket(10) },
      { account = "gm-two", is_current = false, enabled = false, five_hour = bucket(20) },
    } },
    grok = { available = true, accounts = {
      { account = "gk-one", is_current = true, enabled = true, weekly = bucket(10) },
    } },
  }}
  local tasks = {}
  local mod = loadModule(headerFixture, driveTasks(tasks))
  for _, item in ipairs(mod.menuItems()) do
    assert(titleText(item) ~= "Claude B", "the Claude section header still says Claude B")
  end
  local cases = {
    { label = "Claude", key = "claude" },
    { label = "Codex", key = "codex" },
    { label = "Grok", key = "grok" },
    { label = "Gemini", key = "gemini" },
  }
  -- Section order is Egor's own reading order and nothing else pins it: the harness finds every
  -- other row by name, so a reshuffled vendors table would pass the whole suite unnoticed.
  local seen = {}
  for _, item in ipairs(mod.menuItems()) do
    for _, case in ipairs(cases) do
      if titleText(item) == case.label then table.insert(seen, case.label) end
    end
  end
  assert(table.concat(seen, ",") == "Claude,Codex,Grok,Gemini",
    "vendor sections are out of order: " .. table.concat(seen, ","))
  for _, case in ipairs(cases) do
    local header = headerRow(mod.menuItems(), case.label)
    assert(header.disabled ~= true, case.label .. " header stayed disabled with a submenu")
    -- A whole-vendor pool switch is gone for good: an accidental Disable all emptied the pool,
    -- and nothing else in the menu can do that in one click.
    for _, title in ipairs({ "Enable all", "Disable all" }) do
      assert(not submenuItem(header, title), case.label .. " header regrew " .. title)
    end
    while #tasks > 0 do table.remove(tasks) end
    submenuItem(header, "Refresh").fn()
    local refresh = tasks[1]
    assert(refresh and refresh.path:find("llm%-limits", 1, false)
        and refresh.args[1] == "--refresh-account" and refresh.args[2] == case.key
        and #refresh.args == 2,
      case.label .. " header Refresh did not run a free vendor-scoped collect")
    assert(refresh.env.CLAUDEB_WARM_USER_EXPLICIT == "true",
      case.label .. " header Refresh lost the user-explicit warm signal")
    refresh.callback(0, "", "")
  end
end

do
  local now = os.time()
  local grokFixture = { schema = 1, vendors = {
    claude = { available = false },
    codex = { available = false },
    gemini = { available = false },
    grok = {
      available = true,
      current_account = "supergrok",
      refresh_error = { cause = "relogin: not refreshed (needs login)", at = now - 600,
        needs_user_entry = true },
      accounts = {
        { account = "supergrok", is_current = true, enabled = true, plan_type = "SuperGrok",
          email = "fixture@example.com", period = "weekly", build_pct = 47,
          as_of = now - 600, auth = { status = "ok" },
          weekly = { used_pct = 61.2, effective_pct = 61.2, resets_at = now + 86400,
            as_of = now - 600, stale = false, expired = false } },
        { account = "relogin", enabled = true, auth_needed = true,
          as_of = now - 900, auth = { status = "needs_login" } },
        { account = "expired", enabled = true, auth_needed = true, age_alarm = true,
          as_of = now - 1200, auth = { status = "expired" },
          weekly = { used_pct = 33, effective_pct = 33, resets_at = now - 120,
            as_of = now - 1200, stale = false, expired = true } },
        { account = "parked", enabled = false, auth = { status = "ok" },
          as_of = now - 600, period = "USAGE_PERIOD_TYPE_MONTHLY",
          weekly = { used_pct = 12, effective_pct = 12, resets_at = now + 86400,
            as_of = now - 600, stale = false, expired = false } },
      },
    },
  }}
  local tasks, scripts = {}, {}
  local mod = loadModule(grokFixture, captureTasks(tasks), now, nil,
    function(script) table.insert(scripts, script); return true, true, {} end,
    "grok_profile=supergrok\ngrok_workers=off\ngrok_reviewers=on")
  local menu = mod.menuItems()
  assert(mod.refreshState().prefix == "", "Grok entry-only refresh error lit the global warning")
  local grokEntryError = false
  for _, item in ipairs(menu) do
    if titleText(item):find("refresh failed relogin: not refreshed (needs login)", 1, true) then
      grokEntryError = true
    end
  end
  assert(grokEntryError, "Grok entry-only refresh error did not use the shared error row")
  local header = headerRow(menu, "Grok")
  assert(header, "Grok section title did not render")
  local workers = submenuItem(header, "For workers")
  local reviewers = submenuItem(header, "For reviewers")
  assert(workers and workers.checked == false and reviewers and reviewers.checked == true,
    "Grok role checkboxes did not come from the shared vendor loop")
  assert(submenuItem(header, "Refresh"), "Grok vendor Refresh is missing")

  local superRow = accountItem(menu, "supergrok")
  assert(superRow.checked == true, "enabled Grok account row is not checked")
  assert(accountHasMarker(menu, "supergrok"), "pinned Grok account lost its marker")
  assert(submenuItem(superRow, "In worker pool").checked == true,
    "enabled Grok pool checkbox is not checked")
  assert(submenuItem(superRow, "Pin for workers").checked == true,
    "pinned Grok checkbox is not checked")
  assert(submenuItem(superRow, "Hard refresh"), "Grok account Hard refresh is missing")
  assert(not submenuItem(superRow, "Remove supergrok"),
    "healthy Grok account offered Remove, bypassing grokb's logged-in guard")
  local superWeekly = titleText(menu[accountIndex(menu, "supergrok") + 1])
  assert(superWeekly:find("wk", 1, true) and superWeekly:find("61%", 1, true),
    "Grok weekly usage did not use the shared bucket formatter")
  assert(superWeekly:find("build 47%", 1, true), "distinct Grok build usage did not render")
  local buildAt = superWeekly:find("  build 47%", 1, true)
  local expiredWeeklyText = titleText(menu[accountIndex(menu, "expired") + 1])
  assert(buildAt == #expiredWeeklyText + 1,
    "the Grok build detail moved the fixed columns a sibling row keeps")

  local loginRow = accountItem(menu, "relogin")
  assert(titleText(loginRow):find("login needed", 1, true),
    "Grok needs_login account did not use the shared login row")
  assert(not submenuItem(loginRow, "In worker pool"),
    "Grok needs_login row offered worker-pool membership")
  assert(submenuItem(loginRow, "Log in…") and submenuItem(loginRow, "Hard refresh")
      and submenuItem(loginRow, "Remove relogin"),
    "Grok needs_login row lost a shared account action")
  submenuItem(loginRow, "Log in…").fn()
  assert(scripts[#scripts]:find("grokb profile 'relogin' login %-%-device%-auth"),
    "existing Grok profile login did not go through grokb")
  mod.loginGrok("new-profile")
  assert(scripts[#scripts]:find("grokb profile 'new%-profile' login %-%-device%-auth"),
    "new Grok profile login did not go through grokb")

  local expiredRow = accountItem(menu, "expired")
  assert(not titleText(expiredRow):find("login needed", 1, true),
    "expired Grok auth rendered as login needed")
  assert(submenuItem(expiredRow, "Hard refresh"), "expired Grok row is not refreshable")
  local expiredAgeDim = false
  for _, run in ipairs(expiredRow.title.runs or {}) do
    if run.text:find("20m", 1, true) and isDimmed(run.attributes) then expiredAgeDim = true end
  end
  assert(expiredAgeDim, "expired Grok auth did not keep a dim age marker")
  local expiredWeekly = menu[accountIndex(menu, "expired") + 1]
  assert(isDimmed(expiredWeekly.title.attributes), "expired Grok weekly row was not dimmed")
  local parkedRow = accountItem(menu, "parked")
  assert(parkedRow.checked == false
      and submenuItem(parkedRow, "In worker pool").checked == false,
    "disabled Grok account checkboxes are not clear")
  local parkedWeekly = titleText(menu[accountIndex(menu, "parked") + 1])
  assert(parkedWeekly:find("mo", 1, true)
      and not parkedWeekly:find("USAGE_PERIOD", 1, true),
    "non-weekly Grok period rendered the raw enum")

  local grokAt = accountIndex(menu, "supergrok") - 1
  local grokText = {}
  for index = grokAt, #menu do
    local text = titleText(menu[index])
    if index > grokAt and text == "-" then break end
    table.insert(grokText, text)
  end
  grokText = table.concat(grokText, "\n")
  assert(not grokText:find("5h", 1, true), "Grok rendered a phantom five-hour row")
  assert(not grokText:find("?", 1, true) and not grokText:find("nil", 1, true),
    "Grok section leaked a placeholder for its absent five-hour bucket")

  while #tasks > 0 do table.remove(tasks) end
  submenuItem(header, "Refresh").fn()
  assert(tasks[1] and tasks[1].args[1] == "--refresh-account" and tasks[1].args[2] == "grok",
    "Grok vendor Refresh did not target the vendor")
  while #tasks > 0 do table.remove(tasks) end
  submenuItem(superRow, "Hard refresh").fn()
  assert(tasks[1] and tasks[1].args[2] == "grok/supergrok",
    "Grok account Hard refresh did not target the account")
  while #tasks > 0 do table.remove(tasks) end
  submenuItem(parkedRow, "In worker pool").fn()
  assert(tasks[1] and tasks[1].path:find("grokb", 1, true)
      and tasks[1].args[1] == "enable" and tasks[1].args[2] == "parked",
    "Grok pool checkbox did not use grokb enable")
  while #tasks > 0 do table.remove(tasks) end
  submenuItem(superRow, "Pin for workers").fn()
  assert(tasks[1] and tasks[1].path:find("grokb", 1, true)
      and tasks[1].args[1] == "use" and tasks[1].args[2] == "--clear",
    "Grok pin checkbox did not use the shared pin path")
  local fault = { schema = 1, vendors = {
    claude = { available = false }, codex = { available = false },
    gemini = { available = false },
    grok = { available = false,
      refresh_error = { cause = "billing endpoint unavailable", at = now - 60 } },
  }}
  local faultModule = loadModule(fault, nil, now)
  assert(faultModule.refreshState().prefix == "⚠ ",
    "Grok refresh fault did not use the shared warning state")
  assert(submenuItem(rowContaining(faultModule.menuItems(), "Grok"), "Refresh"),
    "unavailable Grok vendor lost its Refresh")
end

-- A Claude vendor object that is not the claudeb store has no per-account pool controls; the free
-- refresh and the role switches are offered regardless — a role is not a pool.
do
  local mod = loadModule({ schema = 1, vendors = {
    claude = { available = true, source = "statusline-cache", accounts = {
      { account = "cl-one", is_current = true, five_hour = bucket(10) },
      { account = "cl-two", is_current = false, five_hour = bucket(20) },
    } },
    codex = { available = false },
    gemini = { available = false },
  }})
  local header = headerRow(mod.menuItems(), "Claude")
  assert(submenuItem(header, "Refresh"), "a Claude section without account controls lost Refresh")
  assert(submenuItem(header, "For workers") and submenuItem(header, "For reviewers"),
    "a Claude section without account controls lost the vendor's role switches")
end

local experimentFixture = {
  schema = 1,
  experiments = { "EXPERIMENT token-freeze until 2026-08-03 — temporary, see EXPERIMENTS.json" },
  vendors = { claude = { available = false }, codex = { available = false }, gemini = { available = false } },
}
local experimentMenu = loadModule(experimentFixture).menuItems()
local announcedRow
for _, item in ipairs(experimentMenu) do
  if titleText(item):match("EXPERIMENT token%-freeze until 2026%-08%-03") then announcedRow = item end
end
assert(announcedRow, "an active experiment is not announced in the menu")
assert(announcedRow.disabled == true, "the experiment announcement must not be clickable")

local quietFixture = {
  schema = 1,
  vendors = { claude = { available = false }, codex = { available = false }, gemini = { available = false } },
}
for _, item in ipairs(loadModule(quietFixture).menuItems()) do
  assert(not titleText(item):match("EXPERIMENT"), "no experiment reported, yet the menu announced one")
end

-- The review doctor's own line. Its counts come from the collector's snapshot; this renderer
-- never scans a store itself, and a missing snapshot means the collector was never installed —
-- one more line to read past in a menu about limits.
local function doctorRow(menu)
  for _, item in ipairs(menu) do
    if titleText(item):find("review doctor", 1, true) then return item end
  end
  return nil
end

local doctorFixture = {
  schema = 1,
  vendors = { claude = { available = false }, codex = { available = false }, gemini = { available = false } },
}
assert(not doctorRow(loadModule(doctorFixture).menuItems()),
  "the menu announced a review doctor with no snapshot on disk")

do
  local clean = { as_of = os.time(), total = 0, anomalies = {
    untriaged = 0, undelivered = 0, stuck_fixes = 0,
    orphan_debt = 0, kill_asymmetry = 0,
  }}
  local row = doctorRow(loadModule(doctorFixture, nil, nil, nil, nil, nil, nil, nil,
    clean).menuItems())
  assert(row, "a clean doctor snapshot rendered no line")
  assert(titleText(row) == "review doctor: OK", titleText(row))
  assert(row.disabled == true, "the clean doctor line is clickable")
  assert(row.menu == nil, "the clean doctor line carries a submenu of nothing")
  assert(isDimmed(row.title.runs[1].attributes, 0), "the clean doctor line is not dimmed")
end

do
  local dirty = { as_of = os.time(), total = 4, anomalies = {
    untriaged = 1, undelivered = 0, stuck_fixes = 3,
    orphan_debt = 0, kill_asymmetry = 0,
  }}
  local row = doctorRow(loadModule(doctorFixture, nil, nil, nil, nil, nil, nil, nil,
    dirty).menuItems())
  assert(titleText(row) == "review doctor: 4 issues", titleText(row))
  assert(row.disabled == nil, "the doctor line with findings cannot be opened")
  -- Only the classes that fired, in the order the snapshot spells them: a submenu listing every
  -- class with a zero beside it is a wall of nothing to read past.
  assert(#row.menu == 2, "the doctor submenu named " .. #row.menu .. " classes")
  assert(titleText(row.menu[1]) == "untriaged: 1", titleText(row.menu[1]))
  assert(titleText(row.menu[2]) == "stuck_fixes: 3", titleText(row.menu[2]))
  assert(row.menu[1].disabled == true, "a doctor class row is clickable")
end

do
  local single = { as_of = os.time(), total = 1, anomalies = { orphan_debt = 1 }}
  local row = doctorRow(loadModule(doctorFixture, nil, nil, nil, nil, nil, nil, nil,
    single).menuItems())
  assert(titleText(row) == "review doctor: 1 issue", titleText(row))
end

-- A collector that stopped running is the finding: the counts read clean off a document nothing
-- has rewritten, and only the age says so.
do
  local now = 1800000000
  local stale = { as_of = now - 3 * 86400, total = 0, anomalies = { untriaged = 0 }}
  local row = doctorRow(loadModule(doctorFixture, nil, now, nil, nil, nil, nil, nil,
    stale).menuItems())
  assert(titleText(row) == "review doctor: OK · snapshot 3d old", titleText(row))
  local fresh = { as_of = now - 3600, total = 0, anomalies = { untriaged = 0 }}
  local freshRow = doctorRow(loadModule(doctorFixture, nil, now, nil, nil, nil, nil, nil,
    fresh).menuItems())
  assert(titleText(freshRow) == "review doctor: OK", titleText(freshRow))
  -- The instant is parsed rather than type-checked: an as_of the decoder hands over as text is
  -- still an instant, and rejected for its type it hides exactly the silence this line exists for.
  local text = { as_of = tostring(now - 3 * 86400), total = 0, anomalies = { untriaged = 0 }}
  local textRow = doctorRow(loadModule(doctorFixture, nil, now, nil, nil, nil, nil, nil,
    text).menuItems())
  assert(titleText(textRow) == "review doctor: OK · snapshot 3d old", titleText(textRow))
  -- And one that is no instant at all says nothing rather than dating the snapshot to 1970.
  local junk = { as_of = "whenever", total = 0, anomalies = { untriaged = 0 }}
  local junkRow = doctorRow(loadModule(doctorFixture, nil, now, nil, nil, nil, nil, nil,
    junk).menuItems())
  assert(titleText(junkRow) == "review doctor: OK", titleText(junkRow))
end

-- A document that is not the one review-bench writes says nothing at all, rather than rendering a
-- line off keys it guessed.
assert(not doctorRow(loadModule(doctorFixture, nil, nil, nil, nil, nil, nil, nil,
  { total = 3 }).menuItems()), "the menu rendered a doctor line off a schema-less document")

-- Which roles may use a vendor at all is a per-vendor switch, so it belongs on the vendor header
-- beside the pool switches; the file spells it as a veto, and only the literal "off" is one.
local function submenuIndex(row, title)
  for index, item in ipairs(row.menu or {}) do
    if titleText(item) == title then return index end
  end
  error("submenu item missing: " .. title)
end

local roleFixture = { schema = 1, vendors = {
  claude = { available = true, source = "claudeb-store", accounts = {
    { account = "cl-one", enabled = true, five_hour = bucket(10) },
    { account = "cl-out", auth_needed = true },
  } },
  codex = { available = true, accounts = {
    { account = "cx-one", enabled = true, five_hour = bucket(10) },
  } },
  gemini = { available = true, accounts = {
    { account = "gm-one", enabled = true, five_hour = bucket(10) },
    { account = "gm-two", enabled = true, five_hour = bucket(20) },
  } },
}}

do
  local config = table.concat({
    "worker=auto",
    "claudeb_workers=off",
    "codex_workers=yes",
    "gemini_reviewers=off",
  }, "\n")
  local menu = loadModule(roleFixture, nil, nil, nil, nil, config).menuItems()
  local cases = {
    { label = "Claude", workers = false, reviewers = true },
    { label = "Codex", workers = true, reviewers = true },
    { label = "Gemini", workers = true, reviewers = false },
  }
  for _, case in ipairs(cases) do
    local header = headerRow(menu, case.label)
    local workers = submenuItem(header, "For workers")
    local reviewers = submenuItem(header, "For reviewers")
    assert(workers and workers.checked == case.workers,
      case.label .. " For workers did not read the role flag")
    assert(reviewers and reviewers.checked == case.reviewers,
      case.label .. " For reviewers did not read the role flag")
    assert(submenuIndex(header, "For workers") < submenuIndex(header, "For reviewers")
        and submenuIndex(header, "For reviewers") < submenuIndex(header, "Refresh"),
      case.label .. " role switches did not sit above Refresh")
  end

  for _, label in ipairs({ "Claude", "Codex", "Gemini" }) do
    local header = headerRow(loadModule(roleFixture).menuItems(), label)
    for _, title in ipairs({ "For workers", "For reviewers" }) do
      local item = submenuItem(header, title)
      assert(item and item.checked == true,
        label .. " " .. title .. " defaulted to off with no worker-model file")
    end
  end
end

do
  local mod = loadModule(roleFixture, nil, nil, nil, nil, "claudeb_workers=off")
  local calls = {}
  mod.setWorkerRole = function(vendor, role, enable)
    table.insert(calls, { vendor = vendor, role = role, enable = enable })
  end
  local header = headerRow(mod.menuItems(), "Claude")
  submenuItem(header, "For workers").fn()
  submenuItem(header, "For reviewers").fn()
  assert(calls[1] and calls[1].vendor == "claude" and calls[1].role == "workers"
      and calls[1].enable == true, "clicking an off role did not ask to enable it")
  assert(calls[2] and calls[2].vendor == "claude" and calls[2].role == "reviewers"
      and calls[2].enable == false, "clicking an on role did not ask to disable it")
end

-- The sole-account Gemini row carries the vendor's controls, so it carries these too.
do
  local soleFixture = { schema = 1, vendors = {
    claude = { available = false },
    codex = { available = false },
    gemini = { available = true, five_hour = bucket(10), weekly = bucket(20) },
  }}
  local mod = loadModule(soleFixture, nil, nil, nil, nil, "gemini_workers=off")
  local calls = {}
  mod.setWorkerRole = function(vendor, role, enable)
    table.insert(calls, { vendor = vendor, role = role, enable = enable })
  end
  local row = accountItem(mod.menuItems(), "Gemini")
  local workers = submenuItem(row, "For workers")
  local reviewers = submenuItem(row, "For reviewers")
  assert(workers and workers.checked == false and reviewers and reviewers.checked == true,
    "single-account Gemini row did not render its role switches")
  assert(submenuIndex(row, "Hard refresh") < submenuIndex(row, "For workers")
      and submenuIndex(row, "For workers") < submenuIndex(row, "For reviewers"),
    "single-account Gemini role switches did not close the row's own controls")
  workers.fn()
  assert(calls[1] and calls[1].vendor == "gemini" and calls[1].role == "workers"
      and calls[1].enable == true, "single-account Gemini role click wrote the wrong toggle")

  -- Logged out or dark is exactly when parking the vendor is the point, so the switches survive
  -- both states of the row — the login-needed row too, which has no header behind it either.
  for _, state in ipairs({ geminiAuthFixture, { schema = 1, vendors = {
    claude = { available = false }, codex = { available = false },
    gemini = { available = false },
  }} }) do
    local darkRow = accountItem(loadModule(state, nil, nil, nil, nil,
      "gemini_reviewers=off").menuItems(), "Gemini")
    local darkWorkers = submenuItem(darkRow, "For workers")
    local darkReviewers = submenuItem(darkRow, "For reviewers")
    assert(darkWorkers and darkWorkers.checked == true,
      "a dark single-account Gemini row lost its For workers switch")
    assert(darkReviewers and darkReviewers.checked == false,
      "a dark single-account Gemini row lost the reviewers veto it was given")
  end
end

-- A vendor no role may use keeps every control it had; only its account titles stop competing
-- for attention with the vendors the routers actually pick from.
do
  local menu = loadModule(roleFixture, nil, nil, nil, nil,
    "claudeb_workers=off\nclaudeb_reviewers=off").menuItems()
  for _, account in ipairs({ "cl-one", "cl-out" }) do
    local row = accountItem(menu, account)
    assert(isDimmed(row.title.runs[1].attributes),
      account .. " title stayed full-strength for a vendor no role may use")
    assert(type(row.menu) == "table" and row.disabled ~= true,
      account .. " lost its actions when the vendor went unused")
  end
  assert(accountItem(menu, "cl-one").checked == true,
    "an unused vendor's account lost its pool checkmark")
  for _, account in ipairs({ "cx-one", "gm-one" }) do
    assert(not isDimmed(accountItem(menu, account).title.runs[1].attributes),
      account .. " was dimmed by another vendor's role switches")
  end
  local halfMenu = loadModule(roleFixture, nil, nil, nil, nil, "claudeb_workers=off").menuItems()
  assert(not isDimmed(accountItem(halfMenu, "cl-one").title.runs[1].attributes),
    "a vendor still open to reviewers was dimmed")
  -- Dimmed is the menu's own label colour at 55%, so the tone follows the appearance the row is
  -- drawn in; a fixed gray would be the unreadable one in whichever appearance it was not picked for.
  local light = accountItem(menu, "cl-one").title.runs[1].attributes
  local dark = accountItem(loadModule(roleFixture, nil, nil, nil, nil,
    "claudeb_workers=off\nclaudeb_reviewers=off", nil, "Dark").menuItems(),
    "cl-one").title.runs[1].attributes
  assert(isDimmed(light, 0), "an unused vendor's title was not dim black in the light appearance")
  assert(isDimmed(dark, 1), "an unused vendor's title stayed black in the dark appearance")
end

-- A duplicated key is read the way every shell reader reads it — first line wins (conf() pipes
-- through head -n1) — or a hand-edited file points the menu at one value and the routers at another.
do
  local config = table.concat({
    "claudeb_workers=off",
    "claudeb_workers=on",
    "gemini_reviewers=keep",
    "gemini_reviewers=off",
  }, "\n")
  local menu = loadModule(roleFixture, nil, nil, nil, nil, config).menuItems()
  local claude = submenuItem(headerRow(menu, "Claude"), "For workers")
  local gemini = submenuItem(headerRow(menu, "Gemini"), "For reviewers")
  assert(claude and claude.checked == false, "a duplicated role key was read last-wins, not first")
  assert(gemini and gemini.checked == true,
    "a later off= overrode the first line the shell readers stop at")
end

-- An unavailable vendor has neither account rows nor a section header, so its own row carries the
-- role switches — parking a vendor is exactly what a dark row invites.
do
  local darkFixture = { schema = 1, vendors = {
    claude = { available = false },
    codex = { available = false, auth_needed = true },
    gemini = { available = false },
  }}
  local mod = loadModule(darkFixture, nil, nil, nil, nil, "codex_workers=off")
  local calls = {}
  mod.setWorkerRole = function(vendor, role, enable)
    table.insert(calls, { vendor = vendor, role = role, enable = enable })
  end
  local menu = mod.menuItems()
  for _, case in ipairs({ { label = "Claude", workers = true }, { label = "Codex", workers = false } }) do
    local row = rowContaining(menu, case.label)
    assert(row.disabled ~= true, case.label .. " unavailable row stayed disabled with a submenu")
    local workers = submenuItem(row, "For workers")
    local reviewers = submenuItem(row, "For reviewers")
    assert(workers and workers.checked == case.workers,
      case.label .. " unavailable row lost its For workers switch")
    assert(reviewers and reviewers.checked == true,
      case.label .. " unavailable row lost its For reviewers switch")
  end
  submenuItem(rowContaining(menu, "Codex"), "For workers").fn()
  assert(calls[1] and calls[1].vendor == "codex" and calls[1].role == "workers"
      and calls[1].enable == true, "a dark Codex row's role click asked for the wrong toggle")
end

-- The write itself is not Lua's: every writer of this file holds the lock inside
-- share/worker-model.sh, and an unlocked rewrite from here would resurrect a pin worker-pick had
-- just cleared. The file content the helper produces is guarded by tests/test_worker_model_roles.sh.
do
  local tasks = {}
  local mod = loadModule(roleFixture, captureTasks(tasks), nil, nil, nil, "claudeb_workers=off")
  local header = headerRow(mod.menuItems(), "Claude")
  local cases = {
    { title = "For workers", role = "workers", state = "on" },
    { title = "For reviewers", role = "reviewers", state = "off" },
  }
  for _, case in ipairs(cases) do
    while #tasks > 0 do table.remove(tasks) end
    submenuItem(header, case.title).fn()
    local launched = tasks[1]
    assert(launched and launched.path == "/bin/bash",
      case.title .. " did not shell out for the write")
    assert(launched.args[1] == "-c"
        and launched.args[2]:find("worker_model_set_role", 1, true),
      case.title .. " did not call the shared locked writer")
    assert(launched.env.WM_VENDOR == "claudeb" and launched.env.WM_ROLE == case.role
        and launched.env.WM_STATE == case.state,
      case.title .. " asked the writer for the wrong vendor, role or state")
    assert(tostring(launched.env.WORKER_MODEL_SH):find("share/worker%-model%.sh$"),
      case.title .. " sourced something other than the repo's worker-model.sh")
    assert(launched.env.WORKER_PICK_CONFIG_FILE == mod.workerModelPath,
      case.title .. " wrote a file other than the one the menu reads")
    -- Values travel as environment: nothing the menu holds is ever parsed as shell.
    assert(not launched.args[2]:find("claudeb", 1, true)
        and not launched.args[2]:find(mod.workerModelPath, 1, true),
      case.title .. " interpolated its arguments into the shell script")
  end
end

-- Saying nothing about a click already in flight is what makes a menu look dead and earns the
-- second click that changes the state back.
do
  local tasks, alerts = {}, {}
  local mod = loadModule(roleFixture, driveTasks(tasks), nil,
    function(text) table.insert(alerts, text) end, nil, "claudeb_workers=off")
  local header = headerRow(mod.menuItems(), "Claude")
  while #tasks > 0 do table.remove(tasks) end
  submenuItem(header, "For workers").fn()
  submenuItem(header, "For workers").fn()
  assert(#tasks == 1, "a second role click while the first was in flight launched a duplicate write")
  assert(#alerts == 1 and alerts[1]:find("still running", 1, true),
    "a role click swallowed by the in-flight guard stayed silent")
  tasks[1].callback(1, "", "worker-model: failed to lock")
  assert(alerts[2] and alerts[2]:find("failed", 1, true),
    "a failed role write said nothing")
end

-- The age is the collector's verdict, never a clock this file reads: an account whose newest
-- window is a day old and one that carried no window at all are the same red.
do
  local alarmFixture = { schema = 1, vendors = {
    claude = {
      available = true,
      source = "claudeb-store",
      accounts = {
        { account = "ancient", enabled = true, age_alarm = true,
          as_of = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 2 * 86400),
          five_hour = bucket(10) },
        { account = "undated", enabled = true, age_alarm = true, five_hour = bucket(10) },
        { account = "current", enabled = true, age_alarm = false,
          as_of = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 600),
          five_hour = bucket(10) },
      },
    },
    codex = { available = false },
    gemini = { available = false },
  }}
  local alarmMenu = loadModule(alarmFixture).menuItems()
  local ancient = accountItem(alarmMenu, "ancient")
  assert(redRuns(ancient.title)[1] == "  2d", "a day-old age did not render red")
  local undated = accountItem(alarmMenu, "undated")
  assert(redRuns(undated.title)[1] == "  never",
    "an account with no instant showed no age, or showed it as an ordinary one")
  local current = accountItem(alarmMenu, "current")
  assert(#redRuns(current.title) == 0, "a fresh age rendered red")
  assert(titleText(current):find("10m", 1, true), "a fresh age lost its span")
end

-- Gemini without its base profile: one account left is still an account row with its own pool,
-- pin and refresh controls, and nothing addresses the name that is gone.
do
  local soleGemini = { schema = 1, vendors = {
    claude = { available = false },
    codex = { available = false },
    gemini = { available = true, current_account = "com", accounts = {
      { account = "com", is_current = true, enabled = true, five_hour = bucket(10),
        weekly = bucket(20) },
    } },
  }}
  local soleMenu = loadModule(soleGemini).menuItems()
  local comRow = accountItem(soleMenu, "com")
  assert(comRow, "the last Gemini account did not render an account row")
  assert(submenuItem(comRow, "In worker pool"), "the last Gemini account lost its pool toggle")
  assert(submenuItem(comRow, "Pin for workers"), "the last Gemini account lost its pin toggle")
  assert(submenuItem(comRow, "Hard refresh"), "the last Gemini account lost its hard refresh")
  for _, item in ipairs(soleMenu) do
    assert(not titleText(item):find("main", 1, true),
      "a Gemini menu without main still addressed main")
  end

  -- A pin naming an account this vendor no longer has is still clearable from the menu.
  local orphanMenu = loadModule(soleGemini, nil, nil, nil, nil,
    "gemini_profile=main").menuItems()
  local orphanRow = accountItem(orphanMenu, "main")
  assert(orphanRow and submenuItem(orphanRow, "Pin for workers"),
    "a Gemini pin on a departed account left no way to clear it")
end

return "PASS: Hammerspoon projection contract"
