-- Pure Lua, no hs: test harnesses load menu modules in sandboxes with a stubbed hs, and this
-- module is shared through the real require.
local M = {}

M.RED = { red = 0.9, green = 0.25, blue = 0.2 }
M.DIM_RED = { red = 0.9, green = 0.25, blue = 0.2, alpha = 0.55 }
M.GREEN = { red = 0.13, green = 0.55, blue = 0.25 }
M.DIM_GREEN = { red = 0.13, green = 0.55, blue = 0.25, alpha = 0.55 }
M.DIM = { list = "System", name = "tertiaryLabelColor" }
M.MONO = { name = "Menlo", size = 13 }

-- A disabled NSMenu row re-tints a custom text colour (dark green turns grey-green, red pales, a dim
-- red dims twice). Measured on the light theme: each input in a disabled row renders as its DIM_
-- colour in an enabled row. DIM needs none: a disabled row already draws it at its enabled look.
local INACTIVE_GREEN = { red = 0.17, green = 0.73, blue = 0.36 }
local INACTIVE_RED = { red = 0.92, green = 0.17, blue = 0.08 }

function M.tone(color, inactive)
  if not inactive then return color end
  if color == M.GREEN or color == M.DIM_GREEN then return INACTIVE_GREEN end
  if color == M.RED or color == M.DIM_RED then return INACTIVE_RED end
  return color
end

local function same(shown, color)
  for _, key in ipairs({ "red", "green", "blue", "alpha" }) do
    if math.abs((shown[key] or 1) - (color[key] or 1)) > 1e-4 then return false end
  end
  return true
end

-- Keyed by title object: Doctors hands back the same cached titles every build, so a repeat costs a
-- lookup instead of an asTable round trip per row.
local settled = setmetatable({}, { __mode = "k" })

-- A title whose tones were already chosen for its row's final enabled state skips the retone walk.
function M.toned(title)
  if type(title) ~= "string" then settled[title] = title end
  return title
end

local function inactiveTitle(title)
  if settled[title] then return settled[title] end
  local out = title
  for _, run in ipairs(title:asTable()) do
    local shown = type(run) == "table" and run.attributes and run.attributes.color
    if type(shown) == "table" then
      for _, color in ipairs({ M.RED, M.DIM_RED, M.GREEN, M.DIM_GREEN }) do
        if same(shown, color) then
          out = out:setStyle({ color = M.tone(color, true) }, run.starts, run.ends)
          break
        end
      end
    end
  end
  settled[title], settled[out] = out, out
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

function M.day(epoch)
  if not epoch then return "?" end
  return os.date("%b ", epoch) .. tonumber(os.date("%d", epoch))
end

-- Every menu tree passes through here, so a disabled row's palette colours get their tone(…, true)
-- whichever builder painted them.
function M.mono(items, style)
  for _, item in ipairs(items or {}) do
    if type(item.title) == "string" and item.title ~= "-" then
      item.title = style(item.title)
    elseif item.disabled and type(item.title) ~= "string" and item.title ~= nil then
      item.title = inactiveTitle(item.title)
    end
    if type(item.menu) == "table" then M.mono(item.menu, style) end
  end
  return items
end

return M
