local M = {
  cachePath = os.getenv("HOME") .. "/.llm-limits.json",
  collectorPath = "/Volumes/Work/Projects/llm-legs/llm-limits.sh",
  claudebCmd = "claudeb",
  wallsLog = nil,
  onRefreshStateChanged = function() end,
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

-- The one shared shape for a logged-out row: every vendor (claude/codex accounts,
-- gemini vendor row, any future vendor) is forced through this so the two actions
-- and their order can never silently diverge. Rotation/current/chat-switch all
-- need live credentials, so a logged-out row offers exactly {Log in…, Hard refresh}.
local function loginNeededRow(label, loginFn, hardRefreshFn)
  return {
    title = loginNeededTitle(label),
    menu = {
      { title = "Log in…", fn = loginFn },
      { title = "Hard refresh", fn = hardRefreshFn },
    },
  }
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

  local now = os.time()
  local delta = timestamp - now
  if delta < 604800 then
    if os.date("%Y-%m-%d", timestamp) ~= os.date("%Y-%m-%d", now) then
      local weekdays = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
      return weekdays[tonumber(os.date("%w", timestamp)) + 1] .. os.date(" %H:%M", timestamp)
    end
    return os.date("%H:%M", timestamp)
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

local taskRegistry = {}
local nextTaskId = 0
local lastCollectEpoch = 0
local runtimeGlobalError = nil

local function errorState(value)
  if type(value) == "table" and type(value.cause) == "string" then
    return { cause = value.cause, at = tonumber(value.at) }
  end
  if type(value) == "string" and value ~= "" then
    return { cause = value }
  end
  return nil
end

local function taskCause(stdOut, stdErr, exitCode, fallback)
  local text = tostring(stdErr or "")
  if text:match("^%s*$") then text = tostring(stdOut or "") end
  local cause
  for line in text:gmatch("[^\r\n]+") do
    if not line:match("^%s*$") then cause = line:match("^%s*(.-)%s*$") end
  end
  return truncateText(cause or fallback or ("exit " .. tostring(exitCode)), 160)
end

local function taskLiveness(task)
  if not task then return true, false end
  local ok, running = pcall(task.isRunning, task)
  return ok, ok and running == true
end

local function taskAlive(task)
  local verified, running = taskLiveness(task)
  return verified and running
end

local function purgeTasks()
  local now = os.time()
  for id, entry in pairs(taskRegistry) do
    if now - entry.started > entry.budget then
      local verified, running = taskLiveness(entry.task)
      if verified and not running then taskRegistry[id] = nil end
    end
  end
end

local function notifyRefreshState()
  pcall(M.onRefreshStateChanged)
end

local function reserveTask(kind, budget, key)
  nextTaskId = nextTaskId + 1
  taskRegistry[nextTaskId] = {
    kind = kind, started = os.time(), budget = budget, key = key,
  }
  return nextTaskId
end

local function finishTask(id, exitCode, stdOut, stdErr, fallback)
  local entry = taskRegistry[id]
  taskRegistry[id] = nil
  local limits = readLlmLimits()
  local cacheGlobalError = errorState(limits and limits.refresh_error)
  if cacheGlobalError or (exitCode == 0 and limits) then
    runtimeGlobalError = nil
  elseif entry and entry.kind ~= "passive" and exitCode ~= 0 then
    runtimeGlobalError = {
      cause = taskCause(stdOut, stdErr, exitCode, fallback),
      at = os.time(),
    }
  end
  notifyRefreshState()
end

local function registryEntryForKey(key)
  for id, entry in pairs(taskRegistry) do
    if entry.key == key then
      local verified, running = taskLiveness(entry.task)
      if running or not verified then return entry end
      taskRegistry[id] = nil
    end
  end
  return nil
end

local function startTask(id, task, fallback)
  local entry = taskRegistry[id]
  if not entry or not task then
    finishTask(id, 1, nil, nil, fallback or "task could not start")
    return false
  end
  entry.task = task
  local ok, started = pcall(task.start, task)
  if not ok or not started then
    finishTask(id, 1, nil, nil, fallback or "task could not start")
    return false
  end
  notifyRefreshState()
  return true
end

local function taskForKey(key)
  purgeTasks()
  return registryEntryForKey(key)
end

function M.refreshState()
  purgeTasks()
  local busy = false
  for _, entry in pairs(taskRegistry) do
    if entry.kind ~= "passive" and taskAlive(entry.task) then
      busy = true
      break
    end
  end
  local limits, readError = readLlmLimits()
  local globalError = errorState(limits and limits.refresh_error) or runtimeGlobalError
  if not globalError and not limits and readError then
    globalError = { cause = readError, at = os.time() }
  end
  local vendorErrors = {}
  if limits and type(limits.vendors) == "table" then
    for _, name in ipairs({ "claude", "codex", "gemini" }) do
      local vendor = limits.vendors[name]
      local err = errorState(type(vendor) == "table" and vendor.refresh_error or nil)
      if err then vendorErrors[name] = err end
    end
  end
  local warning = globalError ~= nil or next(vendorErrors) ~= nil
  return {
    busy = busy,
    warning = warning,
    prefix = busy and "⟳ " or (warning and "⚠ " or ""),
    globalError = globalError,
    vendorErrors = vendorErrors,
  }
end

local function collectOnOpen()
  local now = os.time()
  if taskForKey("passive") or now - lastCollectEpoch < 5 then return end
  lastCollectEpoch = now
  local id = reserveTask("passive", 360, "passive")
  local task = newCollectorTask(function(exitCode, stdOut, stdErr)
    finishTask(id, exitCode, stdOut, stdErr)
  end, {})
  startTask(id, task)
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
  local key = "account-action:" .. table.concat(args, "\0")
  if taskForKey(key) then return end
  local id = reserveTask("account-action", 360, key)
  local task = hs.task.new(resolveClaudeb(), function(exitCode, stdOut, stdErr)
    if exitCode ~= 0 then
      finishTask(id, exitCode, stdOut, stdErr, failMessage)
      return
    end
    local reread = newCollectorTask(function(collectExit, collectOut, collectErr)
      finishTask(id, collectExit, collectOut, collectErr, "collect failed")
    end, {})
    startTask(id, reread, "collect could not start")
  end, args)
  if task then task:setEnvironment(baseEnvironment()) end
  startTask(id, task, failMessage)
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

local function refreshData(args, kind, budget, key)
  if taskForKey(key) then return end
  local id = reserveTask(kind, budget, key)
  local task = newCollectorTask(function(exitCode, stdOut, stdErr)
    finishTask(id, exitCode, stdOut, stdErr)
  end, args)
  startTask(id, task, "collector could not start")
end

local function hardRefresh(target, startWindows)
  local args = { "--refresh-account", target }
  if startWindows then table.insert(args, "--start-windows") end
  refreshData(args, "hard-refresh", 360, "hard:" .. target)
end

-- Hard = full truth at any cost: opens the account's expired 5h window (tiny paid ping).
function M.hardRefreshClaude(name) hardRefresh("claude/" .. name, true) end
function M.hardRefreshCodex(name) hardRefresh("codex/" .. name) end
function M.hardRefreshGemini() hardRefresh("gemini") end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", [['\'']]) .. "'"
end

-- Two quoting layers: the account name is shell-quoted inside the command, then
-- the whole command becomes an AppleScript string literal for `do script`.
local function openLoginTerminal(command)
  local literal = '"' .. command:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
  local script = 'tell application "Terminal"\ndo script ' .. literal
    .. '\nactivate\nend tell'
  local ok = pcall(function() return hs.osascript.applescript(script) end)
  if not ok then
    hs.alert.show("Login could not open Terminal")
  end
end

function M.loginClaude(name)
  openLoginTerminal((M.claudebCmd or "claudeb") .. " profile " .. shellQuote(name))
end
function M.loginCodex(name)
  openLoginTerminal("codexb run " .. shellQuote(name) .. " login")
end
function M.loginGemini() openLoginTerminal("agy") end

local function refreshItems(menu)
  table.insert(menu, {
    title = "Refresh",
    disabled = M.refreshState().busy,
    fn = function() refreshData({ "--refresh" }, "refresh", 360, "refresh") end,
  })
  table.insert(menu, {
    title = "Refresh + Start Windows",
    disabled = M.refreshState().busy,
    fn = function()
      refreshData({ "--refresh", "--start-windows" }, "start-windows", 1200, "start-windows")
    end,
  })
end

local function reportItem(menu)
  local project = "/Volumes/Work/Projects/usage-ai-report"
  local item
  local lock = hs.fs.attributes(project .. "/.run-report.lock")
  if hs.fs.attributes(project, "mode") ~= "directory" then
    item = { title = "Report: volume not mounted", disabled = true }
  -- 10800s matches run_report.sh's stale-lock rule; a crashed run must not pin this item forever
  elseif lock and os.time() - (lock.modification or 0) <= 10800 then
    item = { title = "Report: running…", disabled = true }
  else
    local report = project .. "/repo/LoyEgor/" .. os.date("%Y-%m-%d") .. ".md"
    item = {
      title = hs.fs.attributes(report) and "Update today's report" or "Create today's report",
      fn = function()
        hs.task.new("/bin/bash", nil, { "-c", "REPORT_INTERACTIVE=1 exec bash '" .. project .. "/run_report.sh' --today" }):start()
        hs.alert.show("Report started")
      end,
    }
  end
  table.insert(menu, { title = "-" })
  table.insert(menu, item)
end

local function refreshErrorAge(at)
  if type(at) ~= "number" then return "unknown" end
  local seconds = math.max(0, os.time() - at)
  if seconds < 60 then return "now" end
  if seconds < 3600 then return string.format("%dm", math.floor(seconds / 60)) end
  if seconds < 86400 then return string.format("%dh", math.floor(seconds / 3600)) end
  return string.format("%dd", math.floor(seconds / 86400))
end

local function refreshErrorTitle(err)
  return truncateText("refresh failed " .. err.cause .. " · " .. refreshErrorAge(err.at), 88)
end

local function splitCauseEntries(cause)
  local parts, start, sep = {}, 1, "; "
  while true do
    local s, e = cause:find(sep, start, true)
    if not s then parts[#parts + 1] = cause:sub(start); break end
    parts[#parts + 1] = cause:sub(start, s - 1)
    start = e + 1
  end
  return parts
end

function M.menuItems()
  collectOnOpen()

  local menu = {}
  local state = M.refreshState()
  if state.globalError then
    table.insert(menu, {
      title = infoTitle(refreshErrorTitle(state.globalError), true),
      disabled = true,
    })
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
        local authNeeded = type(vendor) == "table" and vendor.auth_needed == true
        local unavailableRow
        if entry.key == "gemini" and authNeeded then
          unavailableRow = loginNeededRow(entry.label, M.loginGemini, M.hardRefreshGemini)
        else
          unavailableRow = {
            title = authNeeded and loginNeededTitle(entry.label)
              or infoTitle(string.format("%-6s  no live data", entry.label)),
            disabled = true,
          }
          if entry.key == "gemini" then
            unavailableRow.disabled = nil
            unavailableRow.menu = {{ title = "Hard refresh", fn = M.hardRefreshGemini }}
          end
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
            local accountRow
            if authNeeded then
              accountRow = loginNeededRow(acct,
                entry.key == "claude" and function() M.loginClaude(acct) end
                  or function() M.loginCodex(acct) end,
                entry.key == "claude" and function() M.hardRefreshClaude(acct) end
                  or function() M.hardRefreshCodex(acct) end)
            else
              accountRow = {
                title = accountTitle(acct .. resetSuffix .. (isCurrent and "  ●" or ""),
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
      local refreshError = errorState(type(vendor) == "table" and vendor.refresh_error or nil)
      if refreshError then
        local entries = splitCauseEntries(refreshError.cause or "")
        if #entries > 1 then
          for _, entry in ipairs(entries) do
            table.insert(menu, {
              title = infoTitle(refreshErrorTitle({ cause = entry, at = refreshError.at }), false, true),
              disabled = true,
            })
          end
        else
          table.insert(menu, {
            title = infoTitle(refreshErrorTitle(refreshError), false, true),
            disabled = true,
          })
        end
      end
    end

    table.insert(menu, { title = "-" })
    refreshItems(menu)
    reportItem(menu)
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
    reportItem(menu)
  end

  return menu
end

-- The store is written by the collector, llm-limitsd, and now every session's
-- statusline merge-kick; watch it so the menubar reflects fresh data without a
-- menu open. Bursty atomic rewrites are collapsed by the throttle below.
local STORE_RERENDER_THROTTLE = 2
local lastStoreRenderEpoch = 0

-- Pure epoch guard so the throttle is testable without hs or a live clock.
function M.shouldRerenderOnStoreChange(now, last)
  return type(now) == "number" and (now - (last or 0)) >= STORE_RERENDER_THROTTLE
end

-- Re-render ONLY (title via onRefreshStateChanged; the menu itself rebuilds on
-- open). It must never start a collector: the collector writes the store, which
-- would re-fire this watcher forever.
local function onStoreChanged()
  local now = os.time()
  if not M.shouldRerenderOnStoreChange(now, lastStoreRenderEpoch) then return end
  lastStoreRenderEpoch = now
  notifyRefreshState()
end

-- A local pathwatcher is garbage-collected and silently stops firing; hold the
-- reference at module scope (same trap as token_upkeep's wakeWatcher). Guarded
-- so the headless renderer harness (no hs.pathwatcher) still loads.
if hs.pathwatcher then
  M.storeWatcher = hs.pathwatcher.new(M.cachePath, onStoreChanged)
  if M.storeWatcher then M.storeWatcher:start() end
end

return M
