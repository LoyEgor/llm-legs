-- Pure Lua but for one guarded read of the theme: test harnesses load menu modules in sandboxes
-- with a stubbed hs, and this module is shared through the real require.
local M = {}

M.RED = { red = 0.9, green = 0.25, blue = 0.2 }
M.DIM_RED = { red = 0.9, green = 0.25, blue = 0.2, alpha = 0.55 }
M.GREEN = { red = 0.13, green = 0.55, blue = 0.25 }
-- Unused by any menu on purpose, never dead code (Egor, 2026-10-09): every colour has its dim twin
-- ready before a menu needs it. A cleanup deleted it on 2026-10-14; it came back the same day.
M.DIM_GREEN = { red = 0.13, green = 0.55, blue = 0.25, alpha = 0.55 }
M.DIM = { list = "System", name = "tertiaryLabelColor" }
M.MONO = { name = "Menlo", size = 13 }

-- DIM_RED and DIM_GREEN are tokens a builder paints with; no menu draws their alpha. Over the
-- Liquid-Glass menu an alpha blends with whatever lies under it, while a disabled NSMenu row re-tints
-- any opaque colour to one fixed look whatever the backdrop (and takes black to its own grey). So each
-- dim is one opaque look per theme: an enabled row draws DIM_ as given, a disabled row gets the
-- INACTIVE_ input that macOS renders as that same look (measured 2026-10-14, dE under 1 both ways).
-- A disabled row cannot draw saturated colour, so it also takes full RED and GREEN to the dim look.
-- DIM needs none: a system colour AppKit resolves per draw, the same in either row.
local LOOK = {
  light = {
    DIM_RED = { red = 0.918, green = 0.553, blue = 0.506 },
    INACTIVE_RED = { red = 0.92, green = 0.17, blue = 0.08 },
    DIM_GREEN = { red = 0.459, green = 0.733, blue = 0.549 },
    INACTIVE_GREEN = { red = 0.17, green = 0.73, blue = 0.36 },
  },
  dark = {
    DIM_RED = { red = 0.557, green = 0.278, blue = 0.275 },
    INACTIVE_RED = { red = 0.55, green = 0, blue = 0 },
    DIM_GREEN = { red = 0.204, green = 0.404, blue = 0.243 },
    INACTIVE_GREEN = { red = 0, green = 0.40, blue = 0.08 },
  },
}

-- The system preference, not the main thread's drawing appearance: that one keeps the theme
-- Hammerspoon launched in (see dimColor() in llm-limits.lua).
local function theme()
  local ok, name = pcall(function() return hs.host.interfaceStyle() end)
  return ok and name == "Dark" and "dark" or "light"
end

local function toneIn(look, color, inactive)
  if inactive then
    if color == M.GREEN or color == M.DIM_GREEN then return look.INACTIVE_GREEN end
    if color == M.RED or color == M.DIM_RED then return look.INACTIVE_RED end
  elseif color == M.DIM_RED then
    return look.DIM_RED
  elseif color == M.DIM_GREEN then
    return look.DIM_GREEN
  end
  return color
end

function M.tone(color, inactive)
  return toneIn(LOOK[theme()], color, inactive)
end

local function same(shown, color)
  for _, key in ipairs({ "red", "green", "blue", "alpha" }) do
    if math.abs((shown[key] or 1) - (color[key] or 1)) > 1e-4 then return false end
  end
  return true
end

-- Every colour a red or green run can carry, back to its token: the tokens and each theme's looks,
-- so a title painted under the other theme retones too.
local SOURCES = {}
for _, name in ipairs({ "RED", "DIM_RED", "GREEN", "DIM_GREEN" }) do SOURCES[#SOURCES + 1] = { M[name], M[name] } end
for _, look in pairs(LOOK) do
  for _, hue in ipairs({ "RED", "GREEN" }) do
    SOURCES[#SOURCES + 1] = { look["DIM_" .. hue], M["DIM_" .. hue] }
    SOURCES[#SOURCES + 1] = { look["INACTIVE_" .. hue], M["DIM_" .. hue] }
  end
end

-- Per theme and row state, keyed by title object: Doctors hands back the same cached titles every
-- build, so a repeat costs a lookup instead of an asTable round trip per row.
local settled = {}

local function cache(name, inactive)
  local key = name .. (inactive and ".inactive" or ".active")
  settled[key] = settled[key] or setmetatable({}, { __mode = "k" })
  return settled[key]
end

-- A title whose tones were already chosen for its row's final enabled state skips the retone walk.
function M.toned(title)
  if type(title) ~= "string" then
    local name = theme()
    cache(name, true)[title], cache(name, false)[title] = title, title
  end
  return title
end

local function retoned(title, inactive, name)
  local seen = cache(name, inactive)
  if seen[title] then return seen[title] end
  local look, out = LOOK[name], title
  for _, run in ipairs(title:asTable()) do
    local shown = type(run) == "table" and run.attributes and run.attributes.color
    if type(shown) == "table" then
      for _, source in ipairs(SOURCES) do
        if same(shown, source[1]) then
          local color = toneIn(look, source[2], inactive)
          if not same(shown, color) then out = out:setStyle({ color = color }, run.starts, run.ends) end
          break
        end
      end
    end
  end
  seen[title], seen[out] = out, out
  return out
end

function M.age(seconds)
  seconds = math.max(0, tonumber(seconds) or 0)
  if seconds < 3600 then return math.max(1, math.floor(seconds / 60)) .. "m" end
  if seconds < 48 * 3600 then return math.floor(seconds / 3600) .. "h" end
  return math.floor(seconds / 86400) .. "d"
end

function M.ago(seconds) return M.age(seconds) .. " ago" end

function M.clock(epoch, now)
  epoch = tonumber(epoch)
  if not epoch then return "?" end
  epoch, now = math.floor(epoch), math.floor(now or os.time())
  if os.date("%Y-%m-%d", epoch) == os.date("%Y-%m-%d", now) then return os.date("%H:%M", epoch) end
  return os.date("%b ", epoch) .. tonumber(os.date("%d", epoch)) .. os.date(" %H:%M", epoch)
end

-- The Automations title wears BUSY while any menu's source says a refresh runs: each module answers
-- from its own task state, so a rebuild keeps the marker and a finished or failed task drops it.
M.BUSY = "⟳ "
M.onBusyChanged = function() end
local busySources = {}

function M.busySource(name, running) busySources[name] = running end

function M.busyChanged() pcall(M.onBusyChanged) end

function M.refreshing()
  local names = {}
  for name, running in pairs(busySources) do
    local ok, busy = pcall(running)
    if ok and busy then names[#names + 1] = name end
  end
  table.sort(names)
  return names
end

function M.day(epoch)
  if not epoch then return "?" end
  return os.date("%b ", epoch) .. tonumber(os.date("%d", epoch))
end

-- Every menu tree passes through here, so a row's palette colours get their tone(…, inactive) for
-- the current theme whichever builder painted them. Menus build on open, so a theme switch shows on
-- the next open.
local function walk(items, style, name)
  for _, item in ipairs(items or {}) do
    if type(item.title) == "string" and item.title ~= "-" then
      item.title = style(item.title)
    elseif item.title ~= nil and type(item.title) ~= "string" then
      item.title = retoned(item.title, item.disabled == true, name)
    end
    if type(item.menu) == "table" then walk(item.menu, style, name) end
  end
  return items
end

function M.mono(items, style)
  return walk(items, style, theme())
end

return M
