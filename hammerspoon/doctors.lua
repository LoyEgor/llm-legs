local home = os.getenv("HOME")
local repoRoot = (debug.getinfo(1, "S").source or ""):match("^@(.*)/[^/]+/[^/]+$")
local limits = require("llm-limits")
local style = require("menu-style")
local infoTitle = limits.infoTitle

local M = { cacheSeconds = 2 }

local FIX_BUSY_S = 12 * 3600
local NIGHT_REFRESH_S = 60
local UPDATER_STALE_S = 2 * 86400
local SYSTEM_STALE_S = 3600
local ROW_CELLS = 64
local LAG_EVERY_S, LAG_MIN_S = 1, 0.05
local VERDICTS = { "fixed", "ruled-out", "weather", "blind-spot", "handoff" }
local LOUD = { new = true, open = true, regressed = true }
local DOCTORS = {
  { key = "llm", fix = "Fix — open a fixer chat", env = "LLM_DOCTOR", ledger = "doctor-ledger.json" },
  { key = "harness", fix = "Fix — open a fixer chat", env = "HARNESS_DOCTOR", ledgerEnv = "HARNESS_LEDGER",
    ledger = "harness-ledger.json" },
  { key = "updater", fix = "Fix — update and integrate all vendors", env = "UPDATER_DOCTOR", ledger = "updater-ledger.json" },
  { key = "code", fix = "Fix — open a fixer chat", env = "CODE_DOCTOR", ledger = "code-ledger.json" },
  { key = "system", fix = "Fix — open a fixer chat", env = "SYSTEM_DOCTOR", ledger = "system-ledger.json" },
}
local CODE_GROUPS = { { key = "dead", name = "Dead" }, { key = "heavy", name = "Heavy" },
  { key = "duplicate", name = "Duplicate" }, { key = "promise", name = "Promise" }, { key = "ledger", name = "Ledger" } }

local fixTasks, jsonCache, built = {}, {}, nil
local night, nightTask = { at = 0 }, nil

local function clock()
  local timer = hs.timer
  return timer and timer.secondsSinceEpoch and timer.secondsSinceEpoch() or os.time()
end

local function dirFor(field, env, default)
  if M[field] then return M[field] end
  local override = os.getenv(env)
  if override and override ~= "" then return override end
  return home .. default
end

local function running(task)
  if not task then return false end
  local ok, alive = pcall(task.isRunning, task)
  return ok and alive == true
end

local function plural(count, word)
  return string.format("%d %s%s", count, word, count == 1 and "" or "s")
end

local function dim(text) return { title = infoTitle(text, false, true), disabled = true } end

local function plainText(title) return type(title) == "string" and title or title:getString() end
local function cells(text) return utf8.len(text) or #text end

local function wrap(text, width)
  local lines, line = {}, ""
  for word in text:gmatch("%S+") do
    while cells(word) > width do
      if line ~= "" then lines[#lines + 1], line = line, "" end
      local cut = utf8.offset(word, width + 1) or #word + 1
      lines[#lines + 1], word = word:sub(1, cut - 1), word:sub(cut)
    end
    if line == "" then
      line = word
    elseif cells(line) + 1 + cells(word) <= width then
      line = line .. " " .. word
    else
      lines[#lines + 1], line = line, word
    end
  end
  if line ~= "" then lines[#lines + 1] = line end
  return lines
end

local function clipEnd(plain, width)
  local head = plain:sub(1, utf8.offset(plain, width) - 1)
  for _, mark in ipairs({ " · ", ": ", " " }) do
    local at, from = nil, 1
    while true do
      local found = head:find(mark, from, true)
      if not found then break end
      at, from = found, found + 1
    end
    if at and at > #head / 2 then return at - 1 end
  end
  return #head
end

local function detailRows(text)
  local rows = {}
  for _, line in ipairs(wrap(text, ROW_CELLS)) do rows[#rows + 1] = dim(line) end
  return rows
end

-- A macOS submenu is as wide as its widest row: one long row stretches every row beside it.
local function fitRowUnsafe(item)
  local plain = item.title and item.title ~= "-" and plainText(item.title)
  if not plain or cells(plain) <= ROW_CELLS then return item end
  local cut = clipEnd(plain, ROW_CELLS)
  local fitted = {}
  for key, value in pairs(item) do fitted[key] = value end
  if type(item.title) == "string" then
    fitted.title = plain:sub(1, cut) .. "…"
  else
    local last = utf8.offset(plain, utf8.len(plain:sub(1, cut)))
    fitted.title = item.title:sub(1, cut) .. item.title:sub(last, cut):setString("…")
  end
  if item.fn then return fitted end
  local menu = detailRows(plain)
  if type(item.menu) == "table" then
    menu[#menu + 1] = { title = "-" }
    for _, sub in ipairs(item.menu) do menu[#menu + 1] = sub end
  end
  fitted.menu, fitted.disabled = menu, nil
  return fitted
end

local function fitRow(item)
  local ok, fitted = pcall(fitRowUnsafe, item)
  return ok and fitted or item
end

local function readJson(path, format)
  local attrs = hs.fs.attributes(path)
  if not attrs then jsonCache[path] = nil return nil end
  local key = string.format("%s:%s:%s", attrs.ino or "", attrs.modification or "", attrs.size or "")
  local hit = jsonCache[path]
  if hit and hit.key == key then return hit.value end
  local ok, value = pcall(function()
    if not format then return hs.json.read(path) end
    local handle = io.open(path)
    if not handle then return nil end
    local rows = {}
    for line in handle:lines() do
      if format == "header" and not line:match("^[TH]\t") then break end
      local payload = format == "header" and line:match("^H\t(.*)") or format == "days" and line
      if payload then
        local valid, row = pcall(hs.json.decode, payload)
        if valid and type(row) == "table" then
          if format == "header" then handle:close() return row end
          rows[#rows + 1] = row
        end
      end
    end
    handle:close()
    return format == "days" and rows or nil
  end)
  value = ok and type(value) == "table" and value or nil
  jsonCache[path] = { key = key, value = value }
  return value
end

-- Run ids are <doctor>-<area>-<stamp>-<hex>, so a name sort orders areas, not time. A new record moves
-- the directory's size; a record rewritten by rename does not, so the hit re-reads the newest file by name.
local RUNS_RESCAN_S = 60
local runsCache = {}
local function latestRun(doctor)
  local runs = dirFor("doctorsDir", "DOCTORS_DIR", "/.cache/doctors") .. "/runs"
  local attrs = hs.fs.attributes(runs)
  local key = attrs and string.format("%s:%s:%s:%s", runs, attrs.ino or "", attrs.modification or "", attrs.size or "")
  local hit = runsCache[doctor]
  if hit and key and hit.key == key and clock() - hit.at < RUNS_RESCAN_S then
    return hit.name and readJson(runs .. "/" .. hit.name)
  end
  local ok, iter, state = pcall(hs.fs.dir, runs)
  if not ok or not iter then runsCache[doctor] = nil return nil end
  local prefix, newest, newestAt, newestName = doctor .. "-", nil, nil, nil
  for name in iter, state do
    if name:sub(1, #prefix) == prefix and name:match("%.json$") then
      local run = readJson(runs .. "/" .. name)
      local at = run and (limits.parseTime(run.created_at) or limits.parseTime(run.launched_at)) or 0
      if run and (not newest or at > newestAt or at == newestAt and name > newestName) then
        newest, newestAt, newestName = run, at, name
      end
    end
  end
  runsCache[doctor] = key and { key = key, at = clock(), name = newestName } or nil
  return newest
end

local function runState(run)
  if type(run) ~= "table" then return nil end
  local closed, abandoned = limits.parseTime(run.closed_at), limits.parseTime(run.abandoned_at)
  local failed = limits.parseTime(run.failed_at)
  if closed then return "closed", closed end
  if failed then return "failed", failed end
  if abandoned then return "abandoned", abandoned end
  return "open", limits.parseTime(run.launched_at) or limits.parseTime(run.created_at)
end

local function verdictCounts(decisions)
  local counts = {}
  for _, decision in pairs(type(decisions) == "table" and decisions or {}) do
    local id = type(decision) == "table" and decision.id or type(decision) == "string" and decision:match("^([^\t]*)\t")
    local verdict = type(decision) == "table" and (decision.verdict or decision.decision)
      or type(decision) == "string" and (decision:match("^[^\t]*\t([^\t]+)") or decision)
    if type(verdict) == "string" and id ~= "judge" then counts[verdict] = (counts[verdict] or 0) + 1 end
  end
  local parts, known = {}, {}
  for _, verdict in ipairs(VERDICTS) do
    known[verdict] = true
    if counts[verdict] then parts[#parts + 1] = counts[verdict] .. " " .. verdict end
  end
  local rest = {}
  for verdict in pairs(counts) do
    if not known[verdict] then rest[#rest + 1] = verdict end
  end
  table.sort(rest)
  for _, verdict in ipairs(rest) do parts[#parts + 1] = counts[verdict] .. " " .. verdict end
  return parts
end

local function fixerRow(run, now)
  local state, at = runState(run)
  if not state then return dim("fixer: never ran") end
  if state == "open" then return dim(at and "fixer: running for " .. style.age(now - at) or "fixer: running") end
  if state == "abandoned" then return dim("fixer: abandoned " .. style.ago(now - at)) end
  if state == "failed" then
    local note = type(run.note) == "string" and run.note ~= "" and run.note or nil
    return { title = infoTitle("fixer: failed " .. style.ago(now - at), true), menu = note and { dim(note) },
      disabled = not note or nil }
  end
  local parts = { "fixer: ran " .. style.ago(now - at), "closed" }
  for _, part in ipairs(verdictCounts(run.decisions)) do parts[#parts + 1] = part end
  return dim(table.concat(parts, " · "))
end

local function lastLine(text)
  local last
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    if line:match("%S") then last = line end
  end
  return last
end

local function launch(key, path, args, label, launched, after)
  if running(fixTasks[key]) then return end
  local ok, task = pcall(hs.task.new, path, function(code, stdout, stderr)
    fixTasks[key], built = nil, nil
    if after then after() end
    local line = code == 0 and (lastLine(stdout) or lastLine(stderr))
      or (lastLine(stderr) or lastLine(stdout))
    if code == 0 then
      hs.alert.show(line or launched, 3)
    else
      hs.alert.show(label .. " failed (exit " .. tostring(code) .. "): " .. (line or "no output"), 5)
    end
  end, args)
  if not ok or not task then
    hs.alert.show(label .. " failed: could not start " .. tostring(path), 5)
    return
  end
  task:setEnvironment(limits.diagnosticsEnvironment())
  fixTasks[key], built = task, nil
  if not task:start() then
    fixTasks[key] = nil
    hs.alert.show(label .. " failed: could not start " .. tostring(path), 5)
  end
end

function M.fix(doctor)
  launch(doctor, M.doctorFixCmd or (repoRoot and repoRoot .. "/bin/doctor-fix"), { "launch", doctor }, "Fix",
    "doctor-fix launched the " .. doctor .. " fixer")
end

local function nightRunPath() return M.nightRunCmd or (repoRoot and repoRoot .. "/bin/night-run") end

local function startNight(label, question, text, button, args)
  if running(fixTasks.night) or night.running then return end
  if hs.dialog.blockAlert(question, text, "Cancel", button) ~= button then return end
  local argv = { "start" }
  for _, arg in ipairs(args) do argv[#argv + 1] = arg end
  launch("night", nightRunPath(), argv, label, label .. " started", function() night.at = 0 end)
end

function M.runEverything()
  startNight("Run everything", "Run everything now?",
    "Every doctor fixer, every vendor update and the cleanup, in one orchestrator chat that works for hours.", "Run", {})
end

function M.cleanupNow()
  startNight("Cleanup", "Cleanup now?",
    "Lands the finished night branches, then one debt round, in one orchestrator chat. No fixers, no updates.", "Run",
    { "--cleanup" })
end

function M.resumeNight(ref)
  if not night.id then return end
  startNight("Continue", ref and "Continue this job?" or "Continue the unfinished night work?",
    (ref and "Job " .. ref or "Every unfinished job, then the cleanup,") .. " of night " .. night.id
      .. ", in its own worktree and branch, in one orchestrator chat.", "Continue",
    ref and { "--resume", night.id, "--job", ref } or { "--resume", night.id })
end

local function nightItem(title, fn)
  if running(fixTasks.night) then return dim(title:match("^(.-) now") .. " — opening…") end
  if night.running then return dim(title:match("^(.-) now") .. " — a night run is going") end
  return { title = infoTitle(title), fn = fn }
end

local function fixItem(doctor, label, run, now)
  if running(fixTasks[doctor]) then return dim("Fix — opening…") end
  local state, at = runState(run)
  if state == "open" and at and now - at < FIX_BUSY_S then return dim("Fix — fixer running for " .. style.age(now - at)) end
  return { title = infoTitle(label), fn = function() M.fix(doctor) end }
end

local refreshTasks = {}

local function refreshDoctor(key, args, title, documentPath)
  if running(refreshTasks[key]) then return end
  local name = key:sub(1, 1):upper() .. key:sub(2) .. " doctor"
  local path = M[key .. "DoctorCmd"] or (repoRoot and repoRoot .. "/bin/" .. key .. "-doctor")
  local ok, task = pcall(hs.task.new, path, function(code, stdout, stderr)
    refreshTasks[key], built = nil, nil
    if code ~= 0 then
      hs.alert.show(name .. " failed: " .. (lastLine(stderr) or lastLine(stdout) or ("exit " .. tostring(code))), 5)
    else
      hs.alert.show(title(readJson(documentPath())), 2.5)
    end
  end, args)
  if not ok or not task then
    hs.alert.show(name .. ": could not start " .. tostring(path), 5)
    return
  end
  local environment = limits.diagnosticsEnvironment()
  environment.DOCTOR_TRIGGER = "menu"
  task:setEnvironment(environment)
  refreshTasks[key], built = task, nil
  if not task:start() then
    refreshTasks[key] = nil
    hs.alert.show(name .. ": could not start " .. tostring(path), 5)
  end
end

local function refreshRows(items, key, refresh)
  items[#items + 1] = { title = "-" }
  items[#items + 1] = running(refreshTasks[key]) and dim("refreshing…") or { title = infoTitle("Refresh"), fn = refresh }
end

local function blindSpotsRow(document)
  local spots = {}
  for _, spot in ipairs(type(document.blind_spots) == "table" and document.blind_spots or {}) do
    if type(spot) == "table" then
      local detail = {}
      if type(spot.reason) == "string" then detail = detailRows("why: " .. spot.reason) end
      if type(spot.would_catch_if) == "string" then
        for _, row in ipairs(detailRows("would catch it: " .. spot.would_catch_if)) do detail[#detail + 1] = row end
      end
      spots[#spots + 1] = fitRow({ title = infoTitle(tostring(spot.what or spot.id or "?"), false, true),
        menu = #detail > 0 and detail or nil, disabled = #detail == 0 or nil })
    end
  end
  return #spots > 0 and { title = infoTitle("not measured", false, true), menu = spots } or nil
end

local function documentStatus(document)
  local count = document and tonumber(document.problem_count) or 0
  local status = not document and "nodata" or ({ ok = true, problems = true, blind = true, error = true })[document.status]
    and document.status or count > 0 and "problems" or "ok"
  return count, status, count > 0 or status == "error"
end

local function updaterPath()
  return dirFor("updaterDoctorDir", "UPDATER_DOCTOR_DIR", "/.cache/updater-doctor") .. "/latest.json"
end

local function updatesPending(document)
  local pending = 0
  for _, problem in ipairs(type(document.problems) == "table" and document.problems or {}) do
    if type(problem) == "table" and problem.rule == "cli-behind" and not LOUD[problem.state] then pending = pending + 1 end
  end
  return pending
end

local function updaterTitle(document)
  if not document then return "Updater doctor: no data yet" end
  local count = tonumber(document.problem_count) or 0
  local parts = {}
  if count > 0 then parts[#parts + 1] = plural(count, "problem") end
  local pending = updatesPending(document)
  if pending > 0 then parts[#parts + 1] = (pending == 1 and "update" or "updates") .. " pending" end
  if document.status == "blind" then parts[#parts + 1] = "blind" end
  if document.status == "error" then parts[#parts + 1] = "collector failed" end
  local title = "Updater doctor: " .. (#parts > 0 and table.concat(parts, " · ") or "ok")
  local asOf = tonumber(document.as_of_s)
  if asOf and os.time() - asOf >= UPDATER_STALE_S then
    title = title .. " · stale " .. style.age(os.time() - asOf)
  end
  return title
end

function M.refreshUpdater() refreshDoctor("updater", {}, updaterTitle, updaterPath) end

local function nightEntry()
  local jobs, resumable, others = {}, 0, 0
  local idle = not night.running and not running(fixTasks.night)
  for index, job in ipairs(night.jobs) do
    local item = { title = infoTitle(job.text, job.red, job.quiet) }
    if job.detail ~= "" then item.menu = detailRows(job.detail) end
    if job.resumable and idle then
      resumable, others = resumable + 1, others + (job.kind == "debt" and 0 or 1)
      item.menu = item.menu or {}
      if #item.menu > 0 then item.menu[#item.menu + 1] = { title = "-" } end
      item.menu[#item.menu + 1] = { title = infoTitle("Continue this job"), fn = function() M.resumeNight(job.ref) end }
    end
    item.disabled = not item.menu or nil
    jobs[#jobs + 1] = fitRow(item)
  end
  if resumable > 0 then
    jobs[#jobs + 1] = { title = "-" }
    jobs[#jobs + 1] = { title = infoTitle(others > 0 and "Continue unfinished (" .. plural(others, "job") .. ") + cleanup"
      or "Continue the unfinished cleanup"), fn = function() M.resumeNight(nil) end }
  end
  return { title = infoTitle(night.text, night.red, night.quiet), menu = #jobs > 0 and jobs or nil,
    disabled = #jobs == 0 or nil, problems = 0 }
end

function M.refreshNight()
  if running(nightTask) then return end
  local path = nightRunPath()
  local ok, task = pcall(hs.task.new, path, function(code, stdout)
    nightTask, built = nil, nil
    local lines = {}
    for line in (code == 0 and stdout or ""):gmatch("[^\n]+") do lines[#lines + 1] = line end
    local text, tone, busy, id = (lines[1] or ""):match("^([^\t]*)\t([012])\t?([01]?)\t?([^\t]*)")
    local jobs = {}
    for index = 2, #lines do
      local fields = {}
      for field in (lines[index] .. "\t"):gmatch("([^\t]*)\t") do fields[#fields + 1] = field end
      if fields[2] == "0" or fields[2] == "1" or fields[2] == "2" then
        jobs[#jobs + 1] = { text = fields[1], red = fields[2] == "1", quiet = fields[2] == "0", detail = fields[3] or "",
          ref = fields[4], kind = fields[5], resumable = fields[6] == "1" and fields[4] ~= nil and fields[4] ~= "" }
      end
    end
    night = { at = os.time(), text = text ~= "" and text or nil, red = tone == "1", quiet = tone == "0",
      running = busy == "1", jobs = jobs, id = id ~= "" and id or nil }
  end, { "latest", "--menu" })
  if not ok or not task then night.at = os.time() return end
  task:setEnvironment(limits.diagnosticsEnvironment())
  nightTask = task
  if not task:start() then nightTask, night.at = nil, os.time() end
end

local function vendorMenu(vendor, now)
  local items = {}
  for _, model in ipairs(type(vendor.models) == "table" and vendor.models or {}) do
    local name = type(model) == "table" and (model.id or model.name or model.slug) or model
    items[#items + 1] = dim(tostring(name))
  end
  if #items == 0 then items[1] = dim("no models listed") end
  local events = {}
  for _, event in ipairs(type(vendor.events) == "table" and vendor.events or {}) do
    if type(event) == "table" then
      events[#events + 1] = { event = event, at = limits.parseTime(event.closed_at) or limits.parseTime(event.launched_at)
        or limits.parseTime(event.created_at) or 0 }
    end
  end
  table.sort(events, function(a, b) return a.at > b.at end)
  if #events > 0 then items[#items + 1] = { title = "-" } end
  for index = 1, math.min(#events, 5) do
    local event, at = events[index].event, events[index].at
    local parts = { tostring(event.id or "event"), tostring(event.status or "?") }
    if event.from or event.to then parts[#parts + 1] = tostring(event.from or "?") .. " → " .. tostring(event.to or "?") end
    if at > 0 then parts[#parts + 1] = style.ago(now - at) end
    local item = { title = infoTitle(table.concat(parts, " · "), false, not LOUD[event.status]) }
    local changed = {}
    for _, change in ipairs(type(event.changed) == "table" and event.changed or {}) do changed[#changed + 1] = dim(tostring(change)) end
    if #changed > 0 then item.menu = changed else item.disabled = true end
    items[#items + 1] = item
  end
  return items
end

local function updaterEntry(now)
  local document = readJson(updaterPath())
  local items = {}
  if not document then
    items[1] = dim("no data yet")
  else
    local failure = type(document.self) == "table" and document.self.error
    if document.status == "error" and type(failure) == "string" then
      items[#items + 1] = { title = infoTitle(failure, true), disabled = true }
    end
    for _, problem in ipairs(type(document.problems) == "table" and document.problems or {}) do
      if type(problem) == "table" then
        local loud = LOUD[problem.state] == true
        items[#items + 1] = { title = infoTitle(tostring(problem.fact or problem.id or "?"), loud, not loud), disabled = true }
      end
    end
    for _, vendor in ipairs(type(document.vendors) == "table" and document.vendors or {}) do
      if type(vendor) == "table" then
        local checked = limits.parseTime(vendor.checked_at)
        local text = string.format("%s %s · %s", tostring(vendor.vendor or "?"), tostring(vendor.installed or "?"),
          checked and ("checked " .. style.ago(now - checked)) or "never checked")
        local behind = type(vendor.latest) == "string" and vendor.latest ~= "" and vendor.latest ~= vendor.installed
        if behind then text = text .. " · latest " .. tostring(vendor.latest) end
        items[#items + 1] = { title = infoTitle(text, false, not behind), menu = vendorMenu(vendor, now) }
      end
    end
    items[#items + 1] = blindSpotsRow(document)
  end
  refreshRows(items, "updater", M.refreshUpdater)
  local count, status, loud = documentStatus(document)
  local quiet = not loud and status ~= "blind" and not (document and updatesPending(document) > 0)
  return { title = infoTitle(updaterTitle(document), loud, quiet), menu = items,
    problems = count, status = status }
end

local function codePath()
  return dirFor("codeDoctorDir", "CODE_DOCTOR_DIR", "/.cache/code-doctor") .. "/latest.json"
end

local function codeTitle(document)
  if not document then return "Code doctor: no data yet" end
  local count = tonumber(document.problem_count) or 0
  local title = "Code doctor: " .. (count > 0 and plural(count, "problem") or "ok")
  if document.status == "blind" then title = title .. " · blind" end
  if document.status == "error" then title = title .. " · collector failed" end
  return title
end

function M.refreshCode() refreshDoctor("code", { "refresh", "--quiet" }, codeTitle, codePath) end

local function codeEntry()
  local document = readJson(codePath())
  local items = {}
  if not document then
    items[1] = dim("no data yet")
  else
    local failure = type(document.self) == "table" and document.self.error
    if document.status == "error" and type(failure) == "string" then
      items[#items + 1] = { title = infoTitle(failure, true), disabled = true }
    end
    local groups = type(document.groups) == "table" and document.groups or {}
    local listed = {}
    for _, problem in ipairs(type(document.problems) == "table" and document.problems or {}) do
      if type(problem) == "table" then
        local group = tostring(problem.group or "dead")
        listed[group] = listed[group] or {}
        local loud = LOUD[problem.state] == true
        local rows = type(problem.plan) == "string" and detailRows("plan: " .. problem.plan) or {}
        listed[group][#listed[group] + 1] = fitRow({ title = infoTitle(tostring(problem.fact or problem.id or "?"), loud,
          not loud), menu = #rows > 0 and rows or nil, disabled = #rows == 0 or nil })
      end
    end
    for _, group in ipairs(CODE_GROUPS) do
      local count = tonumber(groups[group.key]) or 0
      if group.key ~= "ledger" or count > 0 then
        items[#items + 1] = { title = infoTitle(group.name .. ": " .. plural(count, "problem"), count > 0, count == 0),
          menu = listed[group.key], disabled = not listed[group.key] or nil }
      end
    end
    local candidates = type(document.candidates) == "table" and document.candidates or {}
    local waiting = {}
    for _, candidate in ipairs(type(candidates.top) == "table" and candidates.top or {}) do
      if type(candidate) == "table" then
        waiting[#waiting + 1] = fitRow({ title = infoTitle(tostring(candidate.group or "?") .. " · " ..
          tostring(candidate.detail or candidate.id or "?"), false, true), disabled = true })
      end
    end
    items[#items + 1] = { title = infoTitle("candidates waiting: " .. tostring(tonumber(candidates.waiting) or 0), false, true),
      menu = #waiting > 0 and waiting or nil, disabled = #waiting == 0 or nil }
    local cost = type(document.cost) == "table" and document.cost or {}
    local gained = type(document.yield) == "table" and document.yield or {}
    items[#items + 1] = dim(string.format("cost %dk tokens · %d min · yield %d lines, %d causes closed",
      math.floor((tonumber(cost.tokens) or 0) / 1000), math.floor((tonumber(cost.wall_s) or 0) / 60),
      tonumber(gained.lines_removed) or 0, tonumber(gained.causes_closed) or 0))
    items[#items + 1] = blindSpotsRow(document)
  end
  refreshRows(items, "code", M.refreshCode)
  local count, status, loud = documentStatus(document)
  return { title = infoTitle(codeTitle(document), loud, not loud and status ~= "blind"), menu = items,
    problems = count, status = status }
end

local function systemPath()
  return dirFor("systemDoctorDir", "SYSTEM_DOCTOR_DIR", "/.cache/system-doctor") .. "/latest.json"
end

local function systemTitle(document)
  if not document then return "System doctor: no data yet" end
  local count = tonumber(document.problem_count) or 0
  local title = "System doctor: " .. (count > 0 and plural(count, "problem") or "ok")
  if document.status == "blind" then title = title .. " · blind" end
  if document.status == "error" then title = title .. " · collector failed" end
  local asOf = tonumber(document.as_of_s)
  if asOf and os.time() - asOf >= SYSTEM_STALE_S then title = title .. " · stale " .. style.age(os.time() - asOf) end
  return title
end

function M.refreshSystem() refreshDoctor("system", {}, systemTitle, systemPath) end

local function share(value) return value and string.format("%d %%", math.floor(value * 100 + 0.5)) or "–" end
local function number(value, format) return value and string.format(format, value) or "–" end

local function systemEntry(now)
  local document = readJson(systemPath())
  local items = {}
  if not document then
    items[1] = dim("no data yet")
  else
    local failure = type(document.self) == "table" and document.self.error
    if document.status == "error" and type(failure) == "string" then
      items[#items + 1] = { title = infoTitle(failure, true), disabled = true }
    end
    for _, problem in ipairs(type(document.problems) == "table" and document.problems or {}) do
      if type(problem) == "table" then
        local loud = LOUD[problem.state] == true
        local rows = {}
        for _, item in ipairs(type(problem.evidence) == "table" and problem.evidence or {}) do
          if type(item) == "table" and type(item.excerpt) == "string" then rows[#rows + 1] = dim(item.excerpt) end
        end
        items[#items + 1] = fitRow({ title = infoTitle(tostring(problem.fact or problem.id or "?"), loud, not loud),
          menu = #rows > 0 and rows or nil, disabled = #rows == 0 or nil })
      end
    end
    local m = type(document.measures) == "table" and document.measures or {}
    items[#items + 1] = dim(string.format("new processes %s/s · kernel %s of CPU · busy %s",
      number(m.births_s, "%.0f"), share(m.kernel), share(m.busy)))
    items[#items + 1] = dim(string.format("compressed %s of RAM · swap %s used · %s page-ins/s",
      share(m.comp_share), share(m.swap_share), number(m.pagein_s, "%.0f")))
    items[#items + 1] = dim(string.format("SSD writes %s GB/day · reads %s GB/day (%s days) · swap writes %s GiB/day",
      number(m.ssd_gb_day_7d, "%.0f"), number(m.ssd_read_gb_day_7d, "%.0f"), number(m.days_measured, "%.0f"),
      number(m.swap_gib_day, "%.1f")))
    local volumes = {}
    for name, gib in pairs(type(m.free_gib) == "table" and m.free_gib or {}) do
      volumes[#volumes + 1] = string.format("%s %.0f GiB", name, tonumber(gib) or 0)
    end
    table.sort(volumes)
    if #volumes > 0 then items[#items + 1] = dim("free " .. table.concat(volumes, " · ")) end
    local causes = type(document.causes) == "table" and document.causes or {}
    local born, cpu = {}, {}
    for _, row in ipairs(type(causes.births) == "table" and causes.births or {}) do
      born[#born + 1] = dim(string.format("%s %s · %s", tostring(row[1]), share(tonumber(row[2])), tostring(row[3])))
    end
    for _, row in ipairs(type(causes.cpu) == "table" and causes.cpu or {}) do
      cpu[#cpu + 1] = dim(string.format("%s %.2f cores · reaped %.2f · %s", tostring(row[1]), tonumber(row[2]) or 0,
        tonumber(row[3]) or 0, tostring(row[4])))
    end
    items[#items + 1] = { title = infoTitle("births by cause", false, true), menu = #born > 0 and born or nil,
      disabled = #born == 0 or nil }
    items[#items + 1] = { title = infoTitle("CPU by cause", false, true), menu = #cpu > 0 and cpu or nil,
      disabled = #cpu == 0 or nil }
    local night = type(document.nightly) == "table" and document.nightly or nil
    if night then
      local reports, parts = {}, {}
      for kind, count in pairs(type(night.reports) == "table" and night.reports or {}) do
        parts[#parts + 1] = kind .. " " .. tostring(count)
      end
      table.sort(parts)
      for _, row in ipairs(type(night.processes) == "table" and night.processes or {}) do
        reports[#reports + 1] = dim(string.format("%s %s ×%s · %s", tostring(row[1]), tostring(row[2]), tostring(row[3]),
          tostring(row[4])))
      end
      for _, row in ipairs(type(night.caches) == "table" and night.caches or {}) do
        reports[#reports + 1] = dim(string.format("cache %s %.1f GiB", tostring(row[1]), tonumber(row[2]) or 0))
      end
      local at = tonumber(night.as_of_s)
      items[#items + 1] = fitRow({ title = infoTitle("nightly " .. (at and style.ago(now - at) or "?") .. " · "
        .. (#parts > 0 and table.concat(parts, " · ") or "no reports"), false, true),
        menu = #reports > 0 and reports or nil, disabled = #reports == 0 or nil })
    end
    items[#items + 1] = blindSpotsRow(document)
  end
  refreshRows(items, "system", M.refreshSystem)
  local count, status, loud = documentStatus(document)
  return { title = infoTitle(systemTitle(document), loud, not loud and status ~= "blind"), menu = items,
    problems = count, status = status }
end

local function speedDir() return dirFor("speedDoctorDir", "SPEED_DOCTOR_DIR", "/.cache/speed-doctor") end

local function ledgerPath(doctor)
  local override = M[doctor.key .. "Ledger"] or os.getenv(doctor.ledgerEnv or doctor.env .. "_LEDGER")
  if override and override ~= "" then return override end
  return repoRoot and repoRoot .. "/share/" .. doctor.ledger
end

local function doctorDocument(doctor)
  local folder = dirFor(doctor.key .. "DoctorDir", doctor.env .. "_DIR", "/.cache/" .. doctor.key .. "-doctor")
  return readJson(folder .. (doctor.key == "harness" and "/menu.txt" or "/latest.json"),
    doctor.key == "harness" and "header" or nil)
end

-- The same set bin/doctor-fix snapshots as quiet: open ledger rows no problem of the document names.
local function quietRow(doctor)
  local document = doctorDocument(doctor)
  local path = ledgerPath(doctor)
  local ledger = path and readJson(path)
  local unclassified = not document and doctor.key == "harness"
  if not ledger or not document and not unclassified or document and document.status == "error" then return nil end
  document = document or {}
  local seen = {}
  for _, problem in ipairs(type(document.problems) == "table" and document.problems or {}) do
    if type(problem) == "table" then
      if problem.ledger ~= nil then seen[tostring(problem.ledger)] = true end
      local id = tostring(problem.id or "")
      if id:sub(1, 7) == "ledger:" then seen[id:sub(8)] = true end
    end
  end
  local rows = {}
  for _, row in ipairs(type(ledger.rows) == "table" and ledger.rows or {}) do
    if type(row) == "table" and row.status == "open" and row.id ~= nil and not seen[tostring(row.id)] then
      rows[#rows + 1] = fitRow({ title = infoTitle(tostring(row.id) .. (type(row.title) == "string" and " · " .. row.title or ""),
        false, true), disabled = true })
    end
  end
  if #rows == 0 then return nil end
  return { title = infoTitle(unclassified and "known, awaiting snapshot" or "known, quiet", false, true), menu = rows }
end

local BUILDERS = {
  llm = function() return limits.llmDoctorEntry() end,
  harness = function() return limits.harnessDoctorEntry() end,
  updater = updaterEntry,
  code = codeEntry,
  system = systemEntry,
}
local NAMES = { llm = "LLM doctor", harness = "Harness doctor", updater = "Updater doctor", code = "Code doctor",
  system = "System doctor" }

local BARS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
local MISSING = "–"

local TONES = { [style.RED] = "r", [style.DIM_RED] = "d", [style.DIM] = "m", [style.GREEN] = "g" }
local styledCache, styledCount = {}, 0

local function styled(segments)
  local key = {}
  for index, segment in ipairs(segments) do key[index] = (TONES[segment[2]] or "-") .. segment[1] end
  key = table.concat(key, "\0")
  if styledCache[key] then return styledCache[key] end
  local title
  for _, segment in ipairs(segments) do
    local text, tone = segment[1], segment[2]
    local piece = tone == style.GREEN and hs.styledtext.new(text, { font = style.MONO, color = tone })
      or infoTitle(text, tone == style.RED, tone == style.DIM or tone == style.DIM_RED, tone == style.DIM_RED)
    title = title and title .. piece or piece
  end
  if styledCount >= 256 then styledCache, styledCount = {}, 0 end
  styledCache[key], styledCount = title, styledCount + 1
  return title
end

local function rounded(value) return string.format("%d", math.floor(value + 0.5)) end
local function padded(text, width) return string.rep(" ", width - cells(text)) .. text end

local function summaryTitle(name, value, unit, status, history, now, stale)
  local days, prior, high = {}, {}, 0
  local date = os.date("*t", now)
  for index = 1, 7 do
    local day = os.date("%Y-%m-%d", os.time({ year = date.year, month = date.month, day = date.day - 7 + index,
      hour = 12 }))
    local amount = tonumber(history[day])
    if amount and amount >= 0 then
      days[index], high = amount, math.max(high, amount)
      if index < 7 then prior[#prior + 1] = amount end
    end
  end
  table.sort(prior)
  local median = #prior > 0 and (prior[math.floor((#prior + 1) / 2)] + prior[math.ceil((#prior + 1) / 2)]) / 2 or nil
  local tone = (stale or status == "nodata") and style.DIM
    or (status == "error" or status == "problems") and style.RED
    or (status == "blind" or status == "watch") and style.DIM_RED or style.GREEN
  local segments = { { string.format("%-7s", name), tone }, { " " },
    value and { padded(rounded(value), 4) } or { padded(MISSING, 4), style.DIM }, { string.format(" %-7s  ", unit or "") } }
  for index = 1, 7 do
    local amount = days[index]
    segments[#segments + 1] = amount == nil and { " " }
      or { BARS[high == 0 and 1 or math.max(1, math.ceil(amount / high * 8))], style.DIM }
  end
  segments[#segments + 1] = { " " .. padded(median and rounded(median) or MISSING, 4), style.DIM }
  return styled(segments)
end

local function issueRow(amount, unit, what)
  return fitRow({ title = styled({ { padded(rounded(amount), 4), style.RED },
    { (unit and " " .. unit or "") .. "  " .. what } }), disabled = true })
end

local function issueRows(doctor, document)
  local issues = {}
  if not document then return issues end
  local function add(count, what)
    if count > 0 then issues[#issues + 1] = { count = count, what = what } end
  end
  if doctor.key == "harness" then
    for _, issue in ipairs(document.issues or {}) do add(tonumber(issue[1]) or 0, tostring(issue[2])) end
  elseif doctor.key == "llm" then
    for _, block in ipairs(document.blocks or {}) do
      for _, problem in ipairs(block.problems or {}) do
        if problem.kind == "bug" then add(tonumber(problem.count) or 1, block.block .. " " .. (problem.label or problem.id)) end
      end
      for _, issue in ipairs((block.machinery or {}).classes or {}) do
        if LOUD[issue.status] then add(tonumber(issue.count) or 0, "review " .. (tostring(issue.class):gsub("_", " "))) end
      end
    end
    for _, health in ipairs(document.health or {}) do
      if health.status == "problem" then add(tonumber(health.count) or 1, tostring(health.name)) end
    end
  elseif doctor.key == "code" then
    for _, group in ipairs(CODE_GROUPS) do add(tonumber((document.groups or {})[group.key]) or 0, group.name) end
  elseif doctor.key == "system" then
    for _, problem in ipairs(document.problems or {}) do
      if LOUD[problem.state] then add(1, tostring(problem.label or problem.rule or problem.id)) end
    end
  end
  if #issues == 0 then
    for _, problem in ipairs(document.problems or {}) do
      if LOUD[problem.state] then add(1, tostring(problem.fact or problem.id)) end
    end
  end
  table.sort(issues, function(a, b) return a.count > b.count or a.count == b.count and a.what < b.what end)
  local rows = {}
  for index = 1, math.min(3, #issues) do rows[index] = issueRow(issues[index].count, nil, issues[index].what) end
  return rows
end

local function egorLayer(rows, menu, details)
  rows[#rows + 1], rows[#rows + 2] = menu[#menu - 1], menu[#menu]
  rows[#rows + 1] = { title = "-" }
  rows[#rows + 1] = { title = infoTitle("LLM details"), menu = details }
  return rows
end

local function compute()
  local now = os.time()
  local entries, histories, speed, machine = {}, {}, nil, nil
  local rows = readJson(dirFor("doctorsDir", "DOCTORS_DIR", "/.cache/doctors") .. "/problem-days.jsonl", "days") or {}
  for _, row in ipairs(rows) do
    if type(row.doctor) == "string" and type(row.day) == "string" and tonumber(row.max) then
      histories[row.doctor] = histories[row.doctor] or {}
      histories[row.doctor][row.day] = math.max(histories[row.doctor][row.day] or 0, tonumber(row.max))
    end
  end
  for _, doctor in ipairs(DOCTORS) do
    local ok, entry = pcall(BUILDERS[doctor.key], now)
    if not ok or type(entry) ~= "table" then
      entry = { title = infoTitle(NAMES[doctor.key] .. ": failed to render", true),
        menu = { { title = infoTitle(tostring(entry), true), disabled = true }, { title = "-" } }, problems = 0,
        status = "error" }
    end
    local run = latestRun(doctor.key)
    local menu = {}
    local oldTitle = plainText(entry.title)
    local count = tonumber(entry.problems) or 0
    if oldTitle ~= NAMES[doctor.key] .. ": " .. (count > 0 and plural(count, "problem") or "ok")
      and entry.status ~= "nodata" then
      menu[#menu + 1] = dim(oldTitle)
    end
    for _, item in ipairs(entry.menu or {}) do menu[#menu + 1] = fitRow(item) end
    local ok, quiet = pcall(quietRow, doctor)
    if ok and quiet then menu[#menu + 1] = quiet end
    menu[#menu + 1] = fixItem(doctor.key, doctor.fix, run, now)
    menu[#menu + 1] = fixerRow(run, now)
    local document = doctorDocument(doctor)
    local stale = oldTitle:find("stale", 1, true) ~= nil
    local status = entry.status
    if status == "ok" and doctor.key == "updater" and document and updatesPending(document) > 0 then status = "watch" end
    local summary = { title = summaryTitle((NAMES[doctor.key]:gsub(" doctor$", "")),
      entry.status ~= "nodata" and entry.status ~= "error" and count or nil, nil, status, histories[doctor.key] or {}, now, stale),
      menu = egorLayer(issueRows(doctor, document), menu, menu), problems = count, status = entry.status }
    if doctor.key == "system" then machine = summary else entries[#entries + 1] = summary end
    if doctor.key == "harness" then
      local metrics = document and type(document.speed) == "table" and document.speed or {}
      local byDay = type(metrics.lost_min_day_by_day) == "table" and metrics.lost_min_day_by_day or {}
      local speedMenu, speedRows = {}, {}
      for _, item in ipairs(entry.menu or {}) do
        if item.title ~= "-" and plainText(item.title):match("^Speed:") then speedMenu = item.menu or {} break end
      end
      for _, issue in ipairs(type(metrics.issues) == "table" and metrics.issues or {}) do
        if tonumber(issue[1]) then speedRows[#speedRows + 1] = issueRow(tonumber(issue[1]), "min/day", tostring(issue[2])) end
      end
      for _, item in ipairs(speedMenu) do
        local text = item.title ~= "-" and plainText(item.title) or ""
        if text:match("^Needs Egor") and text ~= "Needs Egor: nothing" then speedRows[#speedRows + 1] = item end
      end
      local lost = tonumber(metrics.lost_min_day)
      speed = { title = summaryTitle("Speed", lost, "min/day", lost and metrics.status or "nodata", byDay, now,
        stale or not byDay[os.date("%Y-%m-%d", now)]), menu = egorLayer(speedRows, menu, speedMenu), problems = 0 }
    end
  end
  entries[#entries + 1] = speed
  entries[#entries + 1] = machine
  if now - night.at >= NIGHT_REFRESH_S then M.refreshNight() end
  if night.text then entries[#entries + 1] = nightEntry() end
  entries[#entries + 1] = { title = "-", problems = 0 }
  for _, item in ipairs({ nightItem("Cleanup now", M.cleanupNow),
      nightItem("Run everything now", M.runEverything) }) do
    item.problems = 0
    entries[#entries + 1] = item
  end
  return style.mono(entries, infoTitle)
end

-- Contract row `ea`: one `start_us<TAB>end_us<TAB>name` line per background build or main-thread lag;
-- bin/speed-doctor prunes the days.
local journalDay = nil
local function hsJournal(name, startedAt, endedAt)
  pcall(function()
    local base = speedDir()
    local folder = base .. "/hs"
    local day = os.date("%Y-%m-%d", math.floor(endedAt))
    if day ~= journalDay then
      journalDay = day
      hs.fs.mkdir(base)
      hs.fs.mkdir(folder)
    end
    limits.journalLine(folder, name, startedAt, endedAt)
  end)
end

local function entries()
  local now = clock()
  if built and now - built.at < M.cacheSeconds then return built.entries end
  local background = limits.inBackground()
  local list = limits.timedMenu("doctors", compute)
  if background then hsJournal("doctors:bg", now, clock()) end
  built = { at = now, entries = list }
  return list
end

-- The gap is measured on mach absolute time, which stops while the Mac sleeps: a wall-clock gap would
-- journal every night's sleep (or a clock jump) as main-thread lag.
local function uptime()
  local timer = hs.timer
  return timer and timer.absoluteTime and timer.absoluteTime() / 1e9 or nil
end

local lagLast, lagUp = nil, nil
function M.lagTick()
  local at, up = clock(), uptime()
  local gap = up and lagUp and up - lagUp or lagLast and at - lagLast
  if gap and gap - LAG_EVERY_S > LAG_MIN_S then hsJournal("hs-lag", at - gap + LAG_EVERY_S, at) end
  lagLast, lagUp = at, up
end
M.lagTimer = hs.timer.doEvery(LAG_EVERY_S, M.lagTick)

function M.title()
  local problems, blind, failed = 0, false, false
  for _, entry in ipairs(entries()) do
    problems = problems + entry.problems
    blind = blind or entry.status == "blind"
    failed = failed or entry.status == "error"
  end
  local parts = {}
  if problems > 0 then parts[#parts + 1] = plural(problems, "problem") end
  if blind then parts[#parts + 1] = "blind" end
  if failed then parts[#parts + 1] = "failed" end
  if #parts == 0 then return "Doctors" end
  return hs.styledtext.new("Doctors: " .. table.concat(parts, " · "), { color = style.RED, font = (hs.styledtext.defaultFonts or {}).menu })
end

function M.menuItems()
  local items = {}
  for index, entry in ipairs(entries()) do
    items[index] = { title = entry.title, menu = entry.menu, disabled = entry.disabled, fn = entry.fn }
  end
  return items
end

return M
