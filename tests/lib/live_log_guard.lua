-- dofile(this)(run): runs a harness inside the live Hammerspoon and turns its result into a FAIL when
-- the live llm-limits action log moved meanwhile, or when any live package.loaded entry changed
-- identity, vanished or appeared (bar hs.* extensions the autoloader adds on first touch): a harness
-- that swaps a live module and dies before putting it back leaves the menubar broken with no sign.
-- The harness runs synchronously on the main thread, so nothing live can change either between the
-- reads; both are only ever read here. A harness that throws is checked too, then rethrown.
return function(run)
  local live = os.getenv("HOME") .. "/.hammerspoon/llm_limits_actions.log"
  local before = hs.fs.attributes(live) or {}
  local modules = {}
  for name, value in pairs(package.loaded) do modules[name] = value end
  local ok, result = pcall(run)
  local after = hs.fs.attributes(live) or {}
  local fails = {}
  if before.size ~= after.size or before.modification ~= after.modification then
    fails[#fails + 1] = "the harness wrote the live " .. live .. " (size " .. tostring(before.size) .. " -> "
      .. tostring(after.size) .. "); point the module at a fixture through LLM_LIMITS_ACTION_LOG"
  end
  local moved = {}
  for name, value in pairs(modules) do
    if not rawequal(package.loaded[name], value) then moved[#moved + 1] = name end
  end
  for name in pairs(package.loaded) do
    if modules[name] == nil and not name:match("^hs%.") then moved[#moved + 1] = name end
  end
  if #moved > 0 then
    table.sort(moved)
    fails[#fails + 1] = "the harness changed live package.loaded[" .. table.concat(moved, ", ")
      .. "]; load a private copy with loadfile instead"
  end
  if #fails > 0 then
    return "FAIL: " .. table.concat(fails, " | ") .. (ok and "" or " (and it threw: " .. tostring(result) .. ")")
  end
  if not ok then error(result, 0) end
  return result
end
