local out = {}
local function rgb(c)
  if type(c) ~= "table" then return nil end
  if c.red then return string.format("rgb(%.2f,%.2f,%.2f%s)", c.red or 0, c.green or 0, c.blue or 0, c.alpha and string.format(",a%.2f", c.alpha) or "") end
  if c.list then return c.list .. ":" .. tostring(c.name) end
  if c.white then return string.format("white(%.2f,a%.2f)", c.white, c.alpha or 1) end
  return "color?"
end
local function describe(t)
  if type(t) == "string" then return t, "plain" end
  if type(t) ~= "userdata" and type(t) ~= "table" then return tostring(t), "?" end
  local ok, tab = pcall(function() return t:asTable() end)
  if not ok then return tostring(t), "?" end
  local text, spans = tab[1], {}
  for i = 2, #tab do
    local a = tab[i].attributes or {}
    local f = a.font and (a.font.name .. " " .. a.font.size) or "NO-FONT"
    local c = rgb(a.color)
    spans[#spans + 1] = string.format("%d-%d %s%s", tab[i].starts, tab[i].ends, f, c and (" " .. c) or "")
  end
  return text, table.concat(spans, "; ")
end
local function walk(items, depth)
  for _, item in ipairs(items or {}) do
    local text, style = describe(item.title)
    if text == "-" then
      out[#out + 1] = string.rep("  ", depth) .. "────"
    else
      local flags = {}
      if item.disabled then flags[#flags + 1] = "disabled" end
      if item.checked then flags[#flags + 1] = "checked" end
      if item.fn then flags[#flags + 1] = "clickable" end
      out[#out + 1] = string.format("%s%s    ⟨%s%s⟩", string.rep("  ", depth), text, style, #flags > 0 and (" | " .. table.concat(flags, ",")) or "")
      if type(item.menu) == "table" and depth < 5 then walk(item.menu, depth + 1) end
    end
  end
end
walk(AutomationMenu.buildMenu(), 0)
return table.concat(out, "\n")
