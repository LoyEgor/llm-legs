local home = os.getenv("HOME")
local repoRoot = (debug.getinfo(1, "S").source or ""):match("^@(.*)/[^/]+/[^/]+$")
local limits = require("llm-limits")
local style = require("menu-style")
local infoTitle = limits.infoTitle

local M = { cacheSeconds = 2 }

local FIX_BUSY_S = 12 * 3600
local NIGHT_REFRESH_S = 60
local UPDATER_STALE_S = 2 * 86400
local ROW_CELLS = 64
local VERDICTS = { "fixed", "ruled-out", "weather", "blind-spot", "handoff" }
local LOUD = { new = true, open = true, regressed = true }
local DOCTORS = {
  { key = "llm", fix = "Fix — open a fixer chat", env = "LLM_DOCTOR", ledger = "doctor-ledger.json" },
  { key = "harness", fix = "Fix — open a fixer chat", env = "HARNESS_DOCTOR", ledgerEnv = "HARNESS_LEDGER",
    ledger = "harness-ledger.json" },
  { key = "updater", fix = "Fix — update and integrate all vendors", env = "UPDATER_DOCTOR", ledger = "updater-ledger.json" },
}

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

local function readJson(path)
  local attrs = hs.fs.attributes(path)
  if not attrs then jsonCache[path] = nil return nil end
  local key = string.format("%s:%s:%s", attrs.ino or "", attrs.modification or "", attrs.size or "")
  local hit = jsonCache[path]
  if hit and hit.key == key then return hit.value end
  local ok, value = pcall(hs.json.read, path)
  value = ok and type(value) == "table" and value or nil
  jsonCache[path] = { key = key, value = value }
  return value
end

-- Run ids are <doctor>-<area>-<stamp>-<hex>, so a name sort orders areas, not time.
local function latestRun(doctor)
  local runs = dirFor("doctorsDir", "DOCTORS_DIR", "/.cache/doctors") .. "/runs"
  local ok, iter, state = pcall(hs.fs.dir, runs)
  if not ok or not iter then return nil end
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
    local verdict = type(decision) == "table" and (decision.verdict or decision.decision)
      or type(decision) == "string" and (decision:match("^[^\t]*\t([^\t]+)") or decision)
    if type(verdict) == "string" and verdict ~= "judge-changed" then counts[verdict] = (counts[verdict] or 0) + 1 end
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

local updaterTask = nil

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
  if pending > 0 then parts[#parts + 1] = plural(pending, "update") .. " pending" end
  if document.status == "blind" then parts[#parts + 1] = "blind" end
  if document.status == "error" then parts[#parts + 1] = "collector failed" end
  local title = "Updater doctor: " .. (#parts > 0 and table.concat(parts, " · ") or "ok")
  local asOf = tonumber(document.as_of_s)
  if asOf and os.time() - asOf >= UPDATER_STALE_S then
    title = title .. " · stale " .. style.age(os.time() - asOf)
  end
  return title
end

function M.refreshUpdater()
  if running(updaterTask) then return end
  local path = M.updaterDoctorCmd or (repoRoot and repoRoot .. "/bin/updater-doctor")
  local ok, task = pcall(hs.task.new, path, function(code, stdout, stderr)
    updaterTask, built = nil, nil
    if code ~= 0 then
      hs.alert.show("Updater doctor failed: " .. (lastLine(stderr) or lastLine(stdout) or ("exit " .. tostring(code))), 5)
    else
      hs.alert.show(updaterTitle(readJson(updaterPath())), 2.5)
    end
  end, {})
  if not ok or not task then
    hs.alert.show("Updater doctor: could not start " .. tostring(path), 5)
    return
  end
  task:setEnvironment(limits.diagnosticsEnvironment())
  updaterTask, built = task, nil
  if not task:start() then
    updaterTask = nil
    hs.alert.show("Updater doctor: could not start " .. tostring(path), 5)
  end
end

local function nightEntry()
  local jobs, resumable, others = {}, 0, 0
  local idle = not night.running and not running(fixTasks.night)
  for index, job in ipairs(night.jobs) do
    if index > 1 and night.jobs[index - 1].kind == "doctor" and job.kind ~= "doctor" then jobs[#jobs + 1] = { title = "-" } end
    local item = { title = infoTitle(job.text, job.red, not job.red) }
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
  return { title = infoTitle(night.text, night.red, not night.red), menu = #jobs > 0 and jobs or nil,
    disabled = #jobs == 0 or nil, problems = 0 }
end

function M.refreshNight()
  if running(nightTask) then return end
  local path = nightRunPath()
  local ok, task = pcall(hs.task.new, path, function(code, stdout)
    nightTask, built = nil, nil
    local lines = {}
    for line in (code == 0 and stdout or ""):gmatch("[^\n]+") do lines[#lines + 1] = line end
    local text, red, busy, id = (lines[1] or ""):match("^([^\t]*)\t([01])\t?([01]?)\t?([^\t]*)")
    local jobs = {}
    for index = 2, #lines do
      local fields = {}
      for field in (lines[index] .. "\t"):gmatch("([^\t]*)\t") do fields[#fields + 1] = field end
      if fields[2] == "0" or fields[2] == "1" then
        jobs[#jobs + 1] = { text = fields[1], red = fields[2] == "1", detail = fields[3] or "", ref = fields[4],
          kind = fields[5], resumable = fields[6] == "1" and fields[4] ~= nil and fields[4] ~= "" }
      end
    end
    night = { at = os.time(), text = text ~= "" and text or nil, red = red == "1", running = busy == "1", jobs = jobs,
      id = id ~= "" and id or nil }
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
        local behind = vendor.latest ~= nil and vendor.latest ~= vendor.installed
        if behind then text = text .. " · latest " .. tostring(vendor.latest) end
        items[#items + 1] = { title = infoTitle(text, false, not behind), menu = vendorMenu(vendor, now) }
      end
    end
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
    if #spots > 0 then
      items[#items + 1] = { title = infoTitle("not measured: " .. plural(#spots, "blind spot"), false, true), menu = spots }
    end
  end
  items[#items + 1] = { title = "-" }
  items[#items + 1] = running(updaterTask) and dim("refreshing…") or { title = infoTitle("Refresh"), fn = M.refreshUpdater }
  local count = document and tonumber(document.problem_count) or 0
  local status = not document and "nodata" or ({ ok = true, problems = true, blind = true, error = true })[document.status]
    and document.status or count > 0 and "problems" or "ok"
  local loud = count > 0 or status == "error"
  local quiet = not loud and status ~= "blind" and not (document and updatesPending(document) > 0)
  return { title = infoTitle(updaterTitle(document), loud, quiet), menu = items,
    problems = count, status = status }
end

local function ledgerPath(doctor)
  local override = M[doctor.key .. "Ledger"] or os.getenv(doctor.ledgerEnv or doctor.env .. "_LEDGER")
  if override and override ~= "" then return override end
  return repoRoot and repoRoot .. "/share/" .. doctor.ledger
end

-- The same set bin/doctor-fix snapshots as quiet: open ledger rows no problem of the document names.
local function quietRow(doctor)
  local document = readJson(dirFor(doctor.key .. "DoctorDir", doctor.env .. "_DIR", "/.cache/" .. doctor.key .. "-doctor")
    .. "/latest.json")
  local path = ledgerPath(doctor)
  local ledger = path and readJson(path)
  if not document or document.status == "error" or not ledger then return nil end
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
  return { title = infoTitle(#rows .. " known, quiet", false, true), menu = rows }
end

local BUILDERS = {
  llm = function() return limits.llmDoctorEntry() end,
  harness = function() return limits.harnessDoctorEntry() end,
  updater = updaterEntry,
}
local NAMES = { llm = "LLM doctor", harness = "Harness doctor", updater = "Updater doctor" }

local function compute()
  local now = os.time()
  local entries = {}
  for _, doctor in ipairs(DOCTORS) do
    local ok, entry = pcall(BUILDERS[doctor.key], now)
    if not ok or type(entry) ~= "table" then
      entry = { title = infoTitle(NAMES[doctor.key] .. ": failed to render", true),
        menu = { { title = infoTitle(tostring(entry), true), disabled = true }, { title = "-" } }, problems = 0,
        status = "error" }
    end
    local run = latestRun(doctor.key)
    local menu = {}
    for _, item in ipairs(entry.menu or {}) do menu[#menu + 1] = fitRow(item) end
    local ok, quiet = pcall(quietRow, doctor)
    if ok and quiet then menu[#menu + 1] = quiet end
    menu[#menu + 1] = fixItem(doctor.key, doctor.fix, run, now)
    menu[#menu + 1] = fixerRow(run, now)
    entries[#entries + 1] = { title = entry.title, menu = menu, problems = tonumber(entry.problems) or 0,
      status = entry.status }
  end
  if now - night.at >= NIGHT_REFRESH_S then M.refreshNight() end
  if night.text then entries[#entries + 1] = nightEntry() end
  entries[#entries + 1] = { title = "-", problems = 0 }
  for _, item in ipairs({ nightItem("Cleanup now (land night branches · debt round)", M.cleanupNow),
      nightItem("Run everything now (fixers · updates · cleanup)", M.runEverything) }) do
    item.problems = 0
    entries[#entries + 1] = item
  end
  return style.mono(entries, infoTitle)
end

local function entries()
  local now = clock()
  if built and now - built.at < M.cacheSeconds then return built.entries end
  local list = limits.timedMenu("doctors", compute)
  built = { at = now, entries = list }
  return list
end

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
