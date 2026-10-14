-- dofile(this)(run): runs a harness inside the live Hammerspoon and turns its result into a FAIL when
-- the live llm-limits action log moved meanwhile. The harness runs synchronously on the main thread,
-- so nothing live can append between the two reads; the file itself is only ever read here.
return function(run)
  local live = os.getenv("HOME") .. "/.hammerspoon/llm_limits_actions.log"
  local before = hs.fs.attributes(live) or {}
  local result = run()
  local after = hs.fs.attributes(live) or {}
  if before.size ~= after.size or before.modification ~= after.modification then
    return "FAIL: the harness wrote the live " .. live .. " (size " .. tostring(before.size) .. " -> "
      .. tostring(after.size) .. "); point the module at a fixture through LLM_LIMITS_ACTION_LOG"
  end
  return result
end
