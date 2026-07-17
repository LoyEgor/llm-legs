local M = {
  cachePath = os.getenv("HOME") .. "/.llm-limits.json",
  collectorPath = "/Volumes/Work/Projects/llm-legs/llm-limits.sh",
  claudebCmd = "claudeb",
  wallsLog = nil,
  onRefreshStart = function() end,
  onRefreshDone = function() end,
}

local grayColor = { red = 0.55, green = 0.55, blue = 0.55 }
local redColor = { red = 0.9, green = 0.25, blue = 0.2 }
local dimRedColor = { red = 0.9, green = 0.25, blue = 0.2, alpha = 0.55 }

local function infoTitle(text, warning, gray, walled)
  local attributes = { font = { name = "Menlo", size = 13 } }
  if walled then
    attributes.color = gray and dimRedColor or redColor
  elseif gray then
    attributes.color = grayColor
  elseif warning then
    attributes.color = redColor
  end
  return hs.styledtext.new(text, attributes)
end

local function loginNeededTitle(account)
  return infoTitle(account) .. infoTitle("  login needed", false, true)
end

local function truncateText(text, maxLength)
  if #text <= maxLength then
    return text
  end
  return text:sub(1, maxLength - 3):gsub("%s+$", "") .. "..."
end

local function parseIsoTime(value)
  if type(value) ~= "string" then
    return nil
  end

  local year, month, day, hour, minute, second =
    value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
  local zone = value:match("Z$")
  local offsetHour, offsetMinute
  local sign, oh, om = value:match("([+-])(%d%d):?(%d%d)$")
  if sign then
    offsetHour = (sign == "-" and -1 or 1) * tonumber(oh)
    offsetMinute = (sign == "-" and -1 or 1) * tonumber(om)
  end

  if not year then
    return nil
  end

  local localEpoch = os.time({
    year = tonumber(year), month = tonumber(month), day = tonumber(day),
    hour = tonumber(hour), min = tonumber(minute), sec = tonumber(second),
    isdst = nil,
  })

  if not localEpoch then
    return nil
  end

  if zone == "Z" or offsetHour ~= nil then
    -- os.date("!*t") drops the DST flag; without copying it back os.time()
    -- interprets the UTC table as standard time and the offset loses an hour.
    local localTable = os.date("*t", localEpoch)
    local utcTable = os.date("!*t", localEpoch)
    utcTable.isdst = localTable.isdst
    local localOffset = os.difftime(os.time(localTable), os.time(utcTable))
    local sourceOffset = (offsetHour or 0) * 3600 + (offsetMinute or 0) * 60
    return localEpoch + localOffset - sourceOffset
  end

  return localEpoch
end

local function parseTime(value)
  if type(value) == "number" then
    return value
  end
  return parseIsoTime(value)
end

local function formatAccountAge(value)
  local timestamp = parseTime(value)
  if not timestamp then
    return nil
  end

  local seconds = math.max(0, os.time() - timestamp)
  if seconds <= 300 then
    return nil
  end
  local minutes = math.floor(seconds / 60)
  if minutes < 60 then
    return string.format("%dm", minutes)
  end
  local hours = math.floor(minutes / 60)
  if hours < 24 then
    return string.format("%dh", hours)
  end
  return string.format("%dd", math.floor(hours / 24))
end

local function accountTitle(text, age, walled)
  local title = infoTitle(text, false, false, walled)
  if age then
    title = title .. infoTitle("  " .. age, false, true)
  end
  return title
end

local function isStale(bucket)
  return type(bucket) == "table" and bucket.stale == true
end

local function formatResetTime(value)
  if value == nil then
    return "–"
  end
  local timestamp = parseTime(value)
  if not timestamp then
    return "unknown"
  end

  local delta = timestamp - os.time()
  if delta < 86400 then
    return os.date("%H:%M", timestamp)
  end
  if delta < 604800 then
    local weekdays = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
    return weekdays[tonumber(os.date("%w", timestamp)) + 1] .. os.date(" %H:%M", timestamp)
  end
  return os.date("%b %d", timestamp)
end

local function resetIsPast(resetsAt)
  local timestamp = parseTime(resetsAt)
  if not timestamp then
    return false
  end
  return timestamp < os.time() - 60
end

local function usageBar(value)
  local pct = math.max(0, math.min(100, tonumber(value) or 0))
  local filled = math.floor(pct / 20 + 0.5)
  return string.rep("▓", filled) .. string.rep("░", 5 - filled)
end

local function rowTitle(account, label, bucket, gray, walled, barWarning)
  bucket = type(bucket) == "table" and bucket or {}
  gray = gray or bucket.expired == true or resetIsPast(bucket.resets_at)
  local pct = tonumber(bucket.effective_pct)
  local pctText = pct and string.format("%d%%", math.floor(pct + 0.5)) or "-"
  local reset = formatResetTime(bucket.resets_at)
  local prefix = string.format("%-6s  %-2s  ", account or "", label)
  local bar = usageBar(pct)
  local suffix = string.format("  %4s  %9s", pctText, reset)
  if barWarning and not walled then
    return infoTitle(prefix, false, gray, false)
      .. infoTitle(bar, true, false, false)
      .. infoTitle(suffix, false, gray, false)
  end
  return infoTitle(prefix .. bar .. suffix, false, gray, walled)
end

local function readLlmLimits()
  local ok, result, reason = pcall(function()
    local file = io.open(M.cachePath, "r")
    if not file then
      return nil, "cache file not found: " .. M.cachePath
    end

    local contents = file:read("*a")
    file:close()
    local decoded = hs.json.decode(contents)
    if type(decoded) ~= "table" then
      return nil, "cache file is not valid JSON: " .. M.cachePath
    end
    if decoded.schema ~= 1 then
      return nil, "unexpected cache schema " .. tostring(decoded.schema) .. ": " .. M.cachePath
    end

    return decoded, nil
  end)

  if ok then
    return result, reason
  end

  return nil, "error reading cache: " .. tostring(result)
end

local function baseEnvironment()
  return {
    HOME = os.getenv("HOME"),
    PATH = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:" .. os.getenv("HOME") .. "/.local/bin:/usr/sbin",
  }
end

local function newCollectorTask(callback, args)
  local task = hs.task.new(M.collectorPath, callback, args or {})
  if task then
    local environment = baseEnvironment()
    if M.wallsLog then
      environment.LLM_LIMITS_WALLS_LOG = M.wallsLog
    end
    task:setEnvironment(environment)
  end
  return task
end

local lastCollectEpoch = 0
local collectOnOpenTask = nil

local function vendorRefreshFailures(limits)
  local failures = {}
  local vendors = limits and limits.vendors
  if type(vendors) == "table" then
    for _, name in ipairs({ "claude", "codex", "gemini" }) do
      local vendor = vendors[name]
      if type(vendor) == "table" and type(vendor.refresh_error) == "string"
          and vendor.refresh_error ~= "" then
        local detail = vendor.refresh_error:match("^%s*(.-)%s*$")
        table.insert(failures, name .. " — " .. detail)
      end
    end
  end
  return failures
end

local function recordRefreshOutcome(exitCode)
  local failures = vendorRefreshFailures(readLlmLimits())
  if exitCode ~= 0 and #failures == 0 then
    table.insert(failures, "exit " .. tostring(exitCode))
  end
  return failures
end

local function collectTaskRunning()
  if not collectOnOpenTask then
    return false
  end
  local ok, running = pcall(collectOnOpenTask.isRunning, collectOnOpenTask)
  if not ok then
    collectOnOpenTask = nil
    return false
  end
  return running == true
end

local function collectOnOpen()
  local now = os.time()
  if collectTaskRunning() then
    return
  end
  if now - lastCollectEpoch < 5 then
    return
  end
  lastCollectEpoch = now
  local task = newCollectorTask(function()
    readLlmLimits()
    pcall(M.onRefreshDone, true)
  end, {})
  collectOnOpenTask = task
  if not task or not task:start() then
    collectOnOpenTask = nil
  end
end

-- hs.task.new needs a launch path, not a PATH-resolved name; a bare command is taken from ~/.local/bin
-- (where claudeb lives). The env PATH below still covers claudeb's own child processes.
local function resolveClaudeb()
  local cmd = M.claudebCmd or "claudeb"
  if cmd:sub(1, 1) == "/" then
    return cmd
  end
  return os.getenv("HOME") .. "/.local/bin/" .. cmd
end

local function runClaudeb(args, failMessage)
  local ok = pcall(function()
    pcall(M.onRefreshStart)
    local task = hs.task.new(resolveClaudeb(), function(exitCode)
      if exitCode == 0 then
        -- Token-free re-read (no --refresh): recompute current/enabled state from the changed store.
        local reread = newCollectorTask(function()
          pcall(M.onRefreshDone, true)
        end, {})
        if not reread or not reread:start() then
          pcall(M.onRefreshDone, true)
        end
      else
        pcall(M.onRefreshDone, false, failMessage)
      end
    end, args)
    if task then
      task:setEnvironment(baseEnvironment())
    end
    if not task or not task:start() then
      error("could not start claudeb")
    end
  end)
  if not ok then
    pcall(M.onRefreshDone, false, failMessage)
  end
end

function M.switchAccount(name)
  runClaudeb({ "use", name }, "switch failed")
end

-- Arms a Hammerspoon one-shot for the chat in the frontmost Terminal tab; the
-- arm itself is silent — claude_chat_switch.lua alerts on the outcome later.
function M.switchChatTo(name)
  local ok = pcall(function()
    local task = hs.task.new(os.getenv("HOME") .. "/.local/bin/claude-chat-switch",
      function(exitCode, stdOut, stdErr)
        if exitCode ~= 0 then
          local line = tostring(stdErr or ""):match("[^\r\n]+")
            or tostring(stdOut or ""):match("[^\r\n]+")
            or ("exit " .. tostring(exitCode))
          hs.alert.show("Chat switch failed: " .. line)
        end
      end, { "--front", name })
    if task then
      task:setEnvironment(baseEnvironment())
    end
    if not task or not task:start() then
      error("could not start claude-chat-switch")
    end
  end)
  if not ok then
    hs.alert.show("Chat switch failed: could not start claude-chat-switch")
  end
end

function M.cancelPendingSwitch()
  if _G.ClaudeChatSwitch and _G.ClaudeChatSwitch.cancel
      and _G.ClaudeChatSwitch.cancel() then
    hs.alert.show("Chat switch cancelled")
  end
end

function M.toggleAccount(name, currentlyEnabled)
  runClaudeb({ currentlyEnabled and "disable" or "enable", name }, "toggle failed")
end

local function taskCause(stdOut, stdErr, exitCode)
  local text = tostring(stdErr or "")
  if text:match("^%s*$") then text = tostring(stdOut or "") end
  local cause
  for line in text:gmatch("[^\r\n]+") do
    if not line:match("^%s*$") then cause = line:match("^%s*(.-)%s*$") end
  end
  return truncateText(cause or ("exit " .. tostring(exitCode)), 160)
end

local hardRefreshInFlight = {}

local function hardRefresh(name, command, args)
  local key = command .. "\0" .. table.concat(args, "\0")
  if hardRefreshInFlight[key] then
    hs.alert.show("Already refreshing: " .. name)
    return
  end
  hardRefreshInFlight[key] = true

  local function finish(success, cause)
    hardRefreshInFlight[key] = nil
    pcall(M.onRefreshDone, success, cause)
  end

  local ok = pcall(function()
    pcall(M.onRefreshStart)
    local task = hs.task.new(command, function(exitCode, stdOut, stdErr)
      if exitCode ~= 0 then
        local cause = taskCause(stdOut, stdErr, exitCode)
        hs.alert.show("Hard refresh failed: " .. name .. " — " .. cause)
        finish(false, cause)
        return
      end
      local reread = newCollectorTask(function(collectExit, collectOut, collectErr)
        if collectExit == 0 then
          finish(true)
        else
          local cause = taskCause(collectOut, collectErr, collectExit)
          hs.alert.show("Hard refresh failed: " .. name .. " — " .. cause)
          finish(false, cause)
        end
      end, {})
      if not reread or not reread:start() then
        hs.alert.show("Hard refresh failed: " .. name .. " — collect could not start")
        finish(false, "collect could not start")
      end
    end, args)
    if task then task:setEnvironment(baseEnvironment()) end
    if not task or not task:start() then error("task could not start") end
  end)
  if not ok then
    hs.alert.show("Hard refresh failed: " .. name .. " — task could not start")
    finish(false, "task could not start")
  end
end

function M.hardRefreshClaude(name)
  hardRefresh(name, resolveClaudeb(), { "warm", name })
end

function M.hardRefreshCodex(name)
  hardRefresh(name, M.collectorPath, { "--refresh-account", "codex/" .. name })
end

function M.hardRefreshGemini()
  hardRefresh("Gemini", M.collectorPath, { "--refresh-account", "gemini" })
end

local function refreshData(args)
  local ok, err = pcall(function()
    local task = newCollectorTask(function(exitCode, _, stdErr)
      local failures = recordRefreshOutcome(exitCode)
      local message = stdErr and stdErr:match("^%s*(.-)%s*$") or ""
      pcall(M.onRefreshDone, exitCode == 0 and #failures == 0,
        message ~= "" and message or nil, failures)
    end, args)

    pcall(M.onRefreshStart)
    if not task or not task:start() then
      error("could not start collector")
    end
  end)

  if not ok then
    local failures = recordRefreshOutcome(1)
    pcall(M.onRefreshDone, false, tostring(err), failures)
  end
end

local function refreshItems(menu)
  table.insert(menu, {
    title = "Refresh",
    fn = function() refreshData({ "--refresh" }) end,
  })
  table.insert(menu, {
    title = "Refresh + Start Windows",
    fn = function() refreshData({ "--refresh", "--start-windows" }) end,
  })
end

local function isInFlight()
  if collectTaskRunning() then
    return true
  end
  for _ in pairs(hardRefreshInFlight) do
    return true
  end
  return false
end

function M.menuItems()
  collectOnOpen()

  local menu = {}
  if isInFlight() then
    table.insert(menu, { title = infoTitle("⟳ updating…", false, true), disabled = true })
  end
  local pendingOk, pending = pcall(function()
    return _G.ClaudeChatSwitch and _G.ClaudeChatSwitch.pending
      and _G.ClaudeChatSwitch.pending()
  end)
  if pendingOk and pending then
    table.insert(menu, {
      title = "Cancel pending switch",
      fn = M.cancelPendingSwitch,
    })
    table.insert(menu, { title = "-" })
  end
  local limits, readErrorReason = readLlmLimits()
  if limits and type(limits.vendors) == "table" then
    local vendors = {
      { key = "claude", label = "Claude" },
      { key = "codex", label = "Codex" },
      { key = "gemini", label = "Gemini" },
    }

    for _, entry in ipairs(vendors) do
      local vendor = limits.vendors[entry.key]
      if type(vendor) ~= "table" or vendor.available ~= true then
        local unavailableRow = {
          title = infoTitle(string.format("%-6s  no live data", entry.label)),
          disabled = true,
        }
        if entry.key == "gemini" then
          unavailableRow.disabled = nil
          unavailableRow.menu = {
            { title = "Hard refresh", fn = M.hardRefreshGemini },
          }
        end
        table.insert(menu, unavailableRow)
      else
        local blocks = (entry.key == "claude" or entry.key == "codex") and vendor.accounts or nil
        local isClaudeAccounts = entry.key == "claude" and type(blocks) == "table" and #blocks > 0
        local isCodexAccounts = entry.key == "codex" and type(blocks) == "table" and #blocks > 0
        local isAccountRows = isClaudeAccounts or isCodexAccounts
        local hasAccountControls = isClaudeAccounts and vendor.source == "claudeb-store"
        if not isAccountRows then
          blocks = {{ account = entry.label, five_hour = vendor.five_hour,
            weekly = vendor.weekly, fable = vendor.fable, as_of = vendor.as_of,
            is_current = false }}
        end
        if isAccountRows then
          table.insert(menu, {
            title = infoTitle(isClaudeAccounts and "Claude B" or entry.label),
            disabled = true,
          })
        else
          local fallbackRow = {
            title = accountTitle(entry.label, formatAccountAge(vendor.as_of)),
            disabled = true,
          }
          local account = vendor.current_account or vendor.account
          local refresh
          if entry.key == "claude" and type(account) == "string" and account ~= "" then
            refresh = function() M.hardRefreshClaude(account) end
          elseif entry.key == "codex" and type(account) == "string" and account ~= "" then
            refresh = function() M.hardRefreshCodex(account) end
          elseif entry.key == "gemini" then
            refresh = M.hardRefreshGemini
          end
          if refresh then
            fallbackRow.disabled = nil
            fallbackRow.menu = {{ title = "Hard refresh", fn = refresh }}
          end
          table.insert(menu, fallbackRow)
        end
        for _, block in ipairs(blocks) do
          local fiveHour = block.five_hour or {}
          local weekly = block.weekly
          local acct = block.account or entry.label
          local isCurrent = block.is_current == true
          local enabled = block.enabled ~= false
          local authNeeded = block.auth_needed == true
          local accountAge = not authNeeded and formatAccountAge(block.as_of) or nil
          local rotation = type(block.rotation) == "table" and block.rotation or {}
          local blocked = type(rotation.blocked) == "table" and rotation.blocked or {}
          local generalWalled = blocked.general ~= nil
          local fableWalled = blocked.fable ~= nil
          if isAccountRows then
            local resetCredits = tonumber(block.reset_credits)
            local resetSuffix = resetCredits and resetCredits > 0
              and string.format("  ↻%d", math.floor(resetCredits)) or ""
            local accountRow = {
              title = authNeeded and loginNeededTitle(acct)
                or accountTitle(acct .. resetSuffix .. (isCurrent and "  ●" or ""),
                  accountAge, generalWalled),
              disabled = true,
            }
            if hasAccountControls then
              accountRow.disabled = nil
              accountRow.checked = enabled
              accountRow.menu = {
                { title = "In rotation", checked = enabled,
                  fn = function() M.toggleAccount(acct, enabled) end },
                { title = "Make current", disabled = block.is_current,
                  fn = function() M.switchAccount(acct) end },
                { title = "Hard refresh",
                  fn = function() M.hardRefreshClaude(acct) end },
              }
              -- "main" is ~/.claude itself, not a claudeb profile dir — no chat switch.
              if acct ~= "main" then
                table.insert(accountRow.menu, {
                  title = "Switch chat to this",
                  fn = function() M.switchChatTo(acct) end,
                })
              end
            elseif isCodexAccounts then
              accountRow.disabled = nil
              accountRow.menu = {
                { title = "Hard refresh",
                  fn = function() M.hardRefreshCodex(acct) end },
              }
            end
            table.insert(menu, accountRow)
          end
          if not authNeeded then
            local fiveGray = isStale(fiveHour)
            local fiveRow = {
              title = rowTitle("", "5h", fiveHour, fiveGray, generalWalled),
              disabled = true,
            }
            table.insert(menu, fiveRow)
            local function tailRow(label, bucket, walled, barWarning)
              if type(bucket) == "table" then
                local gray = isStale(bucket)
                return rowTitle("", label, bucket, gray, walled, barWarning)
              end
              return rowTitle("", label, nil, false, walled, barWarning)
            end
            table.insert(menu, { title = tailRow("wk", weekly, generalWalled), disabled = true })
            if type(block.fable) == "table" then
              local fableWarning = (tonumber(block.fable.effective_pct) or 0) >= 80
              table.insert(menu, { title = tailRow("fb", block.fable, fableWalled, fableWarning), disabled = true })
            end
          end
        end
        if isAccountRows then
          table.insert(menu, { title = "-" })
        end
      end
    end

    table.insert(menu, { title = "-" })
    local failures = vendorRefreshFailures(limits)
    if #failures > 0 then
      table.insert(menu, {
        title = infoTitle(truncateText("refresh failed: "
          .. table.concat(failures, ", "), 88), true),
        disabled = true,
      })
    end
    refreshItems(menu)
  else
    table.insert(menu, {
      title = infoTitle("no data — press Refresh"),
      disabled = true,
    })
    if readErrorReason then
      table.insert(menu, {
        title = infoTitle(readErrorReason, true),
        disabled = true,
      })
    end
    refreshItems(menu)
  end

  return menu
end

return M
