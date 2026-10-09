-- Pure Lua, no hs: test harnesses load menu modules in sandboxes with a stubbed hs, and this
-- module is shared through the real require.
local M = {}

M.RED = { red = 0.9, green = 0.25, blue = 0.2 }
M.DIM_RED = { red = 0.9, green = 0.25, blue = 0.2, alpha = 0.55 }
M.GREEN = { red = 0.2, green = 0.9, blue = 0.2, alpha = 0.55 }
M.DIM = { list = "System", name = "tertiaryLabelColor" }
M.MONO = { name = "Menlo", size = 13 }

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

function M.mono(items, style)
  for _, item in ipairs(items or {}) do
    if type(item.title) == "string" and item.title ~= "-" then item.title = style(item.title) end
    if type(item.menu) == "table" then M.mono(item.menu, style) end
  end
  return items
end

return M
