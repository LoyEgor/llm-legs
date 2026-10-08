local vocab, source, onlyTrends, baseline = ...
local root = debug.getinfo(1, "S").source:match("^@(.+)/tests/[^/]+$")
assert(root, "harness path is unavailable")

local failures, checks = {}, 0
local function check(ok, message)
  checks = checks + 1
  if not ok then failures[#failures + 1] = message end
end
local function text(title) return type(title) == "string" and title or title:getString() end
local function color(title)
  if type(title) == "string" then return nil end
  local runs = title:asTable()
  return runs[2] and runs[2].attributes and runs[2].attributes.color
end
local function red(title)
  local c = color(title)
  return c ~= nil and (c.red or 0) > 0.8 and (c.green or 1) < 0.4
end
local function dimmed(title) return color(title) ~= nil and not red(title) end
local function details(menu)
  for _, item in ipairs(menu or {}) do
    if text(item.title) == "LLM details" then return item.menu end
  end
  return {}
end
local function row(name, value, unit, bars, usual)
  local function pad(cell, width) return string.rep(" ", width - utf8.len(cell)) .. cell end
  return string.format("%-9s", name) .. " " .. pad(value, 4) .. " " .. string.format("%-10s", unit or "") .. "  "
    .. bars .. " " .. pad(usual, 4)
end
local function summary(name, value) return row(name, value and tostring(value) or "–", nil, "       ", "–") end
local function fix(menu) return menu[#menu - 1] end
local function fixer(menu) return menu[#menu] end
local function refreshRow(menu) return menu[#menu - 2] end
local function allMenlo(menu)
  for _, item in ipairs(menu or {}) do
    if item.title ~= "-" then
      if type(item.title) == "string" then return false end
      local font = item.title:asTable()[2].attributes.font
      if not font or not font.name:find("^Menlo") then return false end
    end
    if item.menu and not allMenlo(item.menu) then return false end
  end
  return true
end
local function find(menu, prefix)
  for _, item in ipairs(menu or {}) do
    if item.title ~= "-" and text(item.title):sub(1, #prefix) == prefix then return item end
  end
end

local dir = os.tmpname()
os.remove(dir)
for _, sub in ipairs({ "", "/llm-doctor", "/harness-doctor", "/harness-doctor/menu", "/updater-doctor", "/code-doctor", "/system-doctor", "/doctors", "/speed-doctor",
    "/doctors/runs" }) do
  assert(hs.fs.mkdir(dir .. sub))
end
-- Replaced by rename, as the collectors and bin/doctor-fix write: the readers key their caches on
-- the inode.
local function write(path, body)
  local handle = assert(io.open(dir .. path .. ".tmp", "w"))
  handle:write(type(body) == "table" and hs.json.encode(body) or body)
  handle:close()
  assert(os.rename(dir .. path .. ".tmp", dir .. path))
end
local function remove(path) os.remove(dir .. path) end
local function iso(epoch) return os.date("!%Y-%m-%dT%H:%M:%SZ", epoch) end

-- Tasks and alerts never leave the harness; pathwatcher off keeps the loaded llm-limits copy from
-- watching or collecting anything.
local tasks, alerts, dialogs, answer = {}, {}, {}, "Cancel"
local lagTimers, fakeClock, fakeUp = {}, nil, nil
local fakeHs = setmetatable({
  pathwatcher = false,
  timer = setmetatable({
    doEvery = function(interval, fn)
      lagTimers[#lagTimers + 1] = { interval = interval, fn = fn }
      return { stop = function() end }
    end,
    secondsSinceEpoch = function() return fakeClock or hs.timer.secondsSinceEpoch() end,
    absoluteTime = function() return fakeUp and fakeUp * 1e9 or hs.timer.absoluteTime() end,
  }, { __index = hs.timer }),
  alert = { show = function(message) alerts[#alerts + 1] = message end },
  dialog = { blockAlert = function(...) dialogs[#dialogs + 1] = { ... }; return answer end },
  task = { new = function(path, callback, args)
    local task = { path = path, args = args, callback = callback, alive = false }
    function task:setEnvironment(env) self.env = env end
    function task:start() self.alive = true; return self end
    function task:isRunning() return self.alive end
    function task:finish(code, stdout, stderr) self.alive = false; self.callback(code, stdout or "", stderr or "") end
    tasks[#tasks + 1] = task
    return task
  end },
}, { __index = hs })

local limits = assert(loadfile(root .. "/hammerspoon/llm-limits.lua", "t",
  setmetatable({ hs = fakeHs }, { __index = _G })))()
limits.llmDoctorPath = dir .. "/llm-doctor/latest.json"
limits.harnessDoctorDir = dir .. "/harness-doctor"
limits.doctorSnapshotPath = dir .. "/snapshot.json"
limits.llmDoctorCmd = "/fixture/bin/llm-doctor"
limits.harnessDoctorCmd = "/fixture/bin/harness-doctor"

-- doctors.lua dates its week from os.time() on every build: pinned to the harness's start, a run that
-- crosses local midnight moves no bar. Its own env only: this Lua state is the live Hammerspoon.
local startedAt = os.time()
local pinnedOs = setmetatable({ time = function(date) return date and os.time(date) or startedAt end }, { __index = os })

local function loadDoctors(override)
  local env = setmetatable({ hs = fakeHs, os = pinnedOs, require = function(name)
    if name == "llm-limits" then return limits end
    return require(name)
  end }, { __index = _G })
  local doctors = assert(loadfile(override or source or root .. "/hammerspoon/doctors.lua", "t", env))()
  doctors.doctorsDir = dir .. "/doctors"
  doctors.updaterDoctorDir = dir .. "/updater-doctor"
  doctors.doctorFixCmd = "/fixture/bin/doctor-fix"
  doctors.updaterDoctorCmd = "/fixture/bin/updater-doctor"
  doctors.nightRunCmd = "/fixture/bin/night-run"
  doctors.llmDoctorDir = dir .. "/llm-doctor"
  doctors.harnessDoctorDir = dir .. "/harness-doctor"
  doctors.codeDoctorDir = dir .. "/code-doctor"
  doctors.codeDoctorCmd = "/fixture/bin/code-doctor"
  doctors.codeLedger = dir .. "/code-ledger.json"
  doctors.systemDoctorDir = dir .. "/system-doctor"
  doctors.systemDoctorCmd = "/fixture/bin/system-doctor"
  doctors.systemLedger = dir .. "/system-ledger.json"
  doctors.llmLedger = dir .. "/llm-ledger.json"
  doctors.harnessLedger = dir .. "/harness-ledger.json"
  doctors.updaterLedger = dir .. "/updater-ledger.json"
  doctors.cacheSeconds = 0
  doctors.speedDoctorDir = dir .. "/speed-doctor"
  return doctors
end

local now = startedAt
local function llmDocument(status, count)
  return { contract = 1, doctor = "llm", as_of_s = now, status = status, problem_count = count, window_h = 24,
    bugs = 0, summary = "", not_measurable = {},
    -- Judged off the snapshot below: a machinery verdict older than it would kick a re-judge.
    blocks = { { block = "reviewers", machinery = { as_of = now } } } }
end
local function harnessMenu(count, title)
  return "T\t" .. count .. "\t" .. now .. "\t" .. title .. "\n0\td\t\tWaits  ok\n"
end
local updater = {
  contract = 1, doctor = "updater", as_of_s = now, status = "problems", problem_count = 1,
  problems = {
    { id = "codex:integrate", state = "new", fact = "codex 0.160.0 is out and not integrated" },
    { id = "claude:models", state = "watch", fact = "claude lists a model no leg uses" },
    { id = "foreign-client:codex", state = "watch", fact = "codex: 3 other installs at another version: "
      .. "/Applications/ChatGPT.app/Contents/Resources/codex 0.155.0, "
      .. "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex 0.158.0" },
  },
  blind_spots = { { id = "grok-changelog", what = "grok has no changelog to read",
    reason = "xAI publishes release notes only on X, which the doctor cannot read", would_catch_if = "a feed" } },
  vendors = {
    { vendor = "codex", installed = "0.159.0", latest = "0.160.0", checked_at = iso(now - 3 * 3600), result = "ok",
      models = { "gpt-6-astra", "gpt-6-mini" },
      events = {
        { id = "codex-0.158.0", status = "closed", from = "0.157.0", to = "0.158.0",
          created_at = iso(now - 5 * 86400), closed_at = iso(now - 4 * 86400), changed = { "worker-pick table" } },
        { id = "codex-0.159.0", status = "open", from = "0.158.0", to = "0.159.0",
          created_at = iso(now - 2 * 86400), launched_at = iso(now - 2 * 86400), changed = {} },
      } },
    { vendor = "claude", installed = "2.4.1", latest = "2.4.1", checked_at = iso(now - 3 * 3600), models = {},
      events = {} },
    { vendor = "grok", installed = "1.0.40", latest = "", checked_at = iso(now - 3 * 3600), result = "check-failed",
      models = {}, events = {} },
  },
}
write("/snapshot.json", { as_of = now, total = 0, anomalies = {} })

local palette = require("menu-style")
local function sameColor(actual, expected)
  if not actual then return false end
  expected = color(hs.styledtext.new("x", { font = palette.MONO, color = expected }))
  for key, value in pairs(expected) do if actual[key] ~= value then return false end end
  return true
end
local function span(title, from, to)
  local plain = text(title)
  local first = utf8.offset(plain, from)
  return first and plain:sub(first, (utf8.offset(plain, to + 1) or #plain + 1) - 1) or ""
end
local function colorAt(title, at)
  local plain = text(title)
  local first = utf8.offset(plain, at)
  return first and color(title:sub(first, (utf8.offset(plain, at + 1) or #plain + 1) - 1))
end
local VALUE_AT, UNIT_AT, BAR_AT, USUAL_AT = 14, 16, 28, 39
local trendNow = os.date("*t", now)
local function trendDay(offset)
  return os.date("%Y-%m-%d", os.time({ year = trendNow.year, month = trendNow.month,
    day = trendNow.day + offset, hour = 12 }))
end
local function writeDays(values, scale)
  local rows, speedDays = {}, {}
  for index = 1, 7 do
    if values[index] then
      for _, doctor in ipairs({ "llm", "harness", "updater", "code", "system" }) do
        rows[#rows + 1] = hs.json.encode({ day = trendDay(index - 7), doctor = doctor, count = 0, max = values[index] })
      end
      speedDays[trendDay(index - 7)] = values[index] * (scale or 10)
    end
  end
  write("/doctors/problem-days.jsonl", table.concat(rows, "\n") .. "\nmalformed\n")
  return speedDays
end
local series = { 0, 1, 2, 3, 4, 6, 8 }
local function spendDays(values)
  local days = {}
  for index = 1, 7 do
    if values[index] then days[trendDay(index - 7)] = values[index] / 10 end
  end
  return days
end
local trendLlm = llmDocument("problems", 2)
trendLlm.blocks[1].problems = { { id = "crashed", label = "crashed", count = 8, kind = "bug" } }
trendLlm.blocks[1].bugs = 8
trendLlm.blocks[1].machinery.classes = { { class = "anchors", status = "open", count = 4 } }
write("/llm-doctor/latest.json", trendLlm)
write("/updater-doctor/latest.json", { contract = 1, doctor = "updater", as_of_s = now, status = "ok",
  problem_count = 0, problems = {}, blind_spots = {}, vendors = {} })
write("/code-doctor/latest.json", { contract = 1, doctor = "code", as_of_s = now, status = "problems",
  problem_count = 3, groups = { dead = 2, heavy = 0, duplicate = 1 }, problems = {} })
write("/system-doctor/latest.json", { contract = 1, doctor = "system", as_of_s = now, status = "problems",
  problem_count = 2, blind_spots = {}, problems = {
    { id = "swap:machine", rule = "swap", label = "swap full", state = "new", severity = "review",
      fact = "swap 3.2 of 4.0 GB in use (79%), limit 50%", evidence = { { excerpt = "vm.swapusage used 3240M total 4096M" } } },
    { id = "spawn:machine", rule = "spawn", label = "new processes", state = "new", severity = "heavy",
      fact = "2,600 new processes a second over the last hour, limit 1,000 · top cause statusline.sh 52%" },
    { id = "free-space:Data", rule = "free-space", label = "low disk space", state = "watch", fact = "Data 20 GiB" } },
  measures = { births_s = 2600, kernel = 0.41, busy = 0.8, comp_share = 0.08, swap_share = 0.79, pagein_s = 2500,
    ssd_gb_day_7d = 265, ssd_read_gb_day_7d = 900, days_measured = 3, swap_gib_day = 1.2, free_gib = { Data = 64.4 } },
  causes = { births = { { "statusline.sh", 0.52, "own" } }, cpu = { { "WindowServer", 0.3, 0, "apple" } } },
  nightly = { as_of_s = now - 3600, reports = { crash = 3 }, processes = { { "crash", "bash", 3, "own" } },
    caches = { { ".cache/uv", 22.1 } } } })
local metadata = { status = "problems", problems = {}, issues = { { 3, "Hooks" } },
  speed = { status = "ok", as_of_s = now, lost_min_day = 12, lost_min_day_by_day = writeDays(series),
    issues = { { 40, "suites running", "w-min/day" }, { 12, "hooks" } } },
  spend = { status = "watch", as_of_s = now, index = 0.46, tone = "better", index_by_day = spendDays(series),
    issues = { { 1.888, "compaction summaries" } } } }
local function trendHarness()
  write("/harness-doctor/menu.txt", "T\t3\t" .. now .. "\tHarness doctor: 3 problems\nH\t" .. hs.json.encode(metadata)
    .. "\n0\t\t\tLost time: ok · 179 OM/d\n1\td\t\t12 min/day over the floor\n"
    .. "1\td\t\tNeeds Egor: nothing\n0\t\t\tSpend: watch · index 0.46 (-54%) · 1 audit due\n"
    .. "1\t\t\t1.9 % · compaction summaries · Δ -6% · audit due: never audited\n"
    .. "0\t\t\tHooks: 3 problems\n1\td\t\tall hook details\n")
end
trendHarness()
write("/harness-doctor/latest.json", { status = "problems", problems = {} })
local trendDoctor = loadDoctors()
local trendItems = trendDoctor.menuItems()
local trendNight = tasks[#tasks]
local names, values = { "LLM", "Harness", "Updater", "Code", "Lost time", "Spend", "System" },
  { "2", "3", "0", "3", "12", "0.46", "2" }
local UNITS = { [5] = "min/day", [6] = "index" }
local USUAL = { [5] = "25", [6] = "0.25" }
local bars = "▁▁▂▃▄▆█"
for index, name in ipairs(names) do
  local title = trendItems[index] and trendItems[index].title
  local want = row(name, values[index], UNITS[index], bars, USUAL[index] or "3")
  check(title and text(title) == want, "trend summary " .. name .. ": " .. (title and text(title) or "missing"))
  for day = 1, 7 do
    check(title and sameColor(colorAt(title, BAR_AT + day - 1), palette.DIM), "every bar DIM, above usual too " .. name .. " day " .. day)
  end
  check(title and sameColor(colorAt(title, USUAL_AT), palette.DIM), "usual DIM " .. name)
end
local function aligned(rows)
  local width
  for _, item in ipairs(rows) do
    local plain = text(item.title)
    width = width or utf8.len(plain)
    if utf8.len(plain) ~= width or not span(item.title, 1, 1):match("%a") or text(item.title):find("●", 1, true) or not span(item.title, VALUE_AT, VALUE_AT):match("%S")
      or not span(item.title, USUAL_AT, USUAL_AT):match("%S") then return false end
    for _, at in ipairs({ 10, 15, 26, 27, 35 }) do
      if span(item.title, at, at) ~= " " then return false end
    end
    for at = BAR_AT, BAR_AT + 6 do
      if not ("▁▂▃▄▅▆▇█ "):find(span(item.title, at, at), 1, true) then return false end
    end
  end
  return width == USUAL_AT
end
check(aligned({ table.unpack(trendItems, 1, 7) }), "summary columns line up at the same cells in every doctor row")
for index = 1, 7 do
  local title = trendItems[index].title
  check(span(title, UNIT_AT, UNIT_AT + 9) == string.format("%-10s", UNITS[index] or "")
    and not span(title, VALUE_AT - 3, USUAL_AT):gsub("min/day", ""):gsub("index", ""):match("[%a%%]"),
    "min/day and index are the only units on the summary rows, counts bare: " .. text(title))
end
check(#trendItems == 10 and trendItems[8].title == "-" and text(trendItems[9].title) == "Cleanup now"
  and text(trendItems[10].title) == "Run everything now", "top level: seven summaries, System last, then the actions")
check(span(trendItems[5].title, 1, 9) == "Lost time" and span(trendItems[6].title, 1, 5) == "Spend"
  and sameColor(colorAt(trendItems[6].title, 1), palette.DIM_RED), "the time row reads Lost time; Spend beside it, DIM_RED while an audit is due")
check(sameColor(colorAt(trendItems[6].title, VALUE_AT), palette.GREEN), "Spend's index GREEN when tokenmap's tone is better")
check(span(trendItems[3].title, 1, 7) == "Updater" and sameColor(colorAt(trendItems[3].title, 1), palette.GREEN)
  and sameColor(colorAt(trendItems[3].title, 7), palette.GREEN), "ok name GREEN")
check(span(trendItems[1].title, 1, 3) == "LLM" and sameColor(colorAt(trendItems[1].title, 1), palette.RED), "problem name RED")
local function issue(menu, at, want)
  local item = menu and menu[at]
  return item and text(item.title) == want and sameColor(colorAt(item.title, 1), palette.RED) and item.disabled
end
check(issue(trendItems[1].menu, 1, "   8  reviewers crashed"), "LLM issue row")
check(issue(trendItems[1].menu, 2, "   4  review anchors"), "LLM review machinery issue row")
check(issue(trendItems[2].menu, 1, "   3  Hooks"), "Harness issue row")
check(issue(trendItems[4].menu, 1, "   2  Dead") and issue(trendItems[4].menu, 2, "   1  Duplicate"), "Code issue rows")
check(issue(trendItems[5].menu, 2, "  12 min/day  hooks"), "Speed floor issue row in min/day")
check(issue(trendItems[5].menu, 1, "  40 w-min/day  suites running"), "a workers' floor gap carries its own unit")
check(issue(trendItems[6].menu, 1, " 1.9 %  compaction summaries"), "Spend issue row: the due component by its share")
check(issue(trendItems[7].menu, 1, "   1  new processes") and issue(trendItems[7].menu, 2, "   1  swap full")
  and not find(trendItems[7].menu, "   1  low disk space"), "System issue rows: one per loud problem by its short name")
local systemFix = find(trendItems[7].menu, "Fix —")
check(systemFix and text(systemFix.title) == "Fix — open a fixer chat" and not systemFix.disabled and systemFix.fn,
  "System routes its own causes to a fixer: its Fix row opens a fixer chat")
local systemDetails = details(trendItems[7].menu)
check(text(systemDetails[1].title):find("^swap 3%.2 of 4%.0 GB") and red(systemDetails[1].title)
  and systemDetails[1].menu and text(systemDetails[1].menu[1].title) == "vm.swapusage used 3240M total 4096M"
  and dimmed(systemDetails[3].title) and find(systemDetails, "new processes 2600/s · kernel 41 % of CPU")
  and find(systemDetails, "births by cause") and find(systemDetails, "births by cause").menu
  and text(find(systemDetails, "births by cause").menu[1].title) == "statusline.sh 52 % · own"
  and find(systemDetails, "nightly 1h ago · crash 3") and text(refreshRow(systemDetails).title) == "Refresh",
  "System details: problems with their evidence, the measures, causes, the nightly pass, Refresh")
local function captionless(menu)
  for _, item in ipairs(menu or {}) do
    local plain = item.title == "-" and "-" or text(item.title)
    if not (plain:match("^ *[%d.]+ ") or plain:match("^Fix —") or plain:match("^fixer: ") or plain == "-"
      or plain == "LLM details") then return false, plain end
  end
  return true
end
for index = 1, 7 do
  local menu = trendItems[index].menu or {}
  local ok, caption = captionless(menu)
  check(ok and #menu > 0 and text(menu[#menu].title) == "LLM details",
    "Egor's layer of " .. names[index] .. " holds issue rows, Fix, fixer and LLM details only: " .. tostring(caption))
end
local function rowCount(menu)
  local n = 0
  for _, item in ipairs(menu or {}) do n = n + 1 + rowCount(item.menu) end
  return n
end
local function sameRows(left, right)
  if #left ~= #right then return false end
  for index, item in ipairs(left) do
    local other = right[index]
    if text(item.title) ~= text(other.title) or item.disabled ~= other.disabled
      or (item.fn ~= nil) ~= (other.fn ~= nil) or not sameRows(item.menu or {}, other.menu or {}) then return false end
  end
  return true
end
do
  local function action(title) return { title = title, fn = function() end } end
  local function quiet(title) return { title = title, disabled = true } end
  local old = { limits.llmDoctorEntry(), limits.harnessDoctorEntry(),
    { menu = { { title = "-" }, action("Refresh") } },
    { menu = { quiet("Dead: 2 problems"), quiet("Heavy: 0 problems"), quiet("Duplicate: 1 problem"), quiet("Promise: 0 problems"),
      quiet("candidates waiting: 0"), quiet("cost 0k tokens · 0 min · yield 0 lines, 0 causes closed"),
      { title = "-" }, action("Refresh") } } }
  for index, entry in ipairs(old) do
    entry.menu[#entry.menu + 1] = action(index == 3 and "Fix — update and integrate all vendors" or "Fix — open a fixer chat")
    entry.menu[#entry.menu + 1] = quiet("fixer: never ran")
  end
  for index = 1, 4 do
    check(rowCount(details(trendItems[index].menu)) == rowCount(old[index].menu), "LLM details row count " .. names[index])
    check(sameRows(details(trendItems[index].menu), old[index].menu), "LLM details unchanged tree " .. names[index])
    local topFix, topFixer = find(trendItems[index].menu, "Fix —"), find(trendItems[index].menu, "fixer:")
    check(topFix and topFixer and #details(trendItems[index].menu) > 0 and topFix.fn == fix(details(trendItems[index].menu)).fn
      and text(topFixer.title) == text(fixer(details(trendItems[index].menu)).title), "outer fixer controls " .. names[index])
  end
  local oldSpeed = find(old[2].menu, "Lost time:").menu
  check(rowCount(details(trendItems[5].menu)) == rowCount(oldSpeed), "LLM details row count Speed")
  check(sameRows(details(trendItems[5].menu), oldSpeed), "LLM details unchanged tree Speed")
  local oldSpend = find(old[2].menu, "Spend:").menu
  check(#oldSpend == 1 and sameRows(details(trendItems[6].menu), oldSpend), "Spend's details are Harness's Spend: subtree")
  if baseline then
    local original = loadDoctors(baseline).menuItems()
    for index = 1, 4 do
      check(rowCount(details(trendItems[index].menu)) == rowCount(original[index].menu)
        and sameRows(details(trendItems[index].menu), original[index].menu), "main tree retained " .. names[index])
    end
    if not source then
      for _, pair in ipairs({ { "before", loadDoctors(baseline) }, { "after", trendDoctor } }) do
        local samples = {}
        for i = 1, 51 do
          local at = hs.timer.secondsSinceEpoch()
          limits.backgroundMenu(pair[2].menuItems)
          if i > 1 then samples[#samples + 1] = (hs.timer.secondsSinceEpoch() - at) * 1000 end
        end
        table.sort(samples)
        print(string.format("BENCH %s p50=%.3f ms p95=%.3f ms n=%d", pair[1], samples[25], samples[48], #samples))
      end
      trendNight:finish(0, "Last night 5 Oct · stopped early: no jobs\t0\t0\n")
      local rendered = trendDoctor.menuItems()
      print("FIXTURE " .. text(trendDoctor.title()))
      for _, item in ipairs(rendered) do print("FIXTURE " .. text(item.title) .. (item.menu and " ▸" or "")) end
      for _, item in ipairs(rendered[1].menu) do print("SUBMENU " .. text(item.title) .. (item.menu and " ▸" or "")) end
    end
  end
end
local realRead, heavyReads = hs.json.read, 0
fakeHs.json = setmetatable({ read = function(path, ...)
  if path == dir .. "/harness-doctor/latest.json" then heavyReads = heavyReads + 1 end
  return realRead(path, ...)
end }, { __index = hs.json })
loadDoctors().menuItems()
check(heavyReads == 0, "no Harness latest.json decode")
fakeHs.json = nil
write("/harness-ledger.json", { rows = {
  { id = "H1", status = "open", title = "reported cause" }, { id = "H2", status = "open", title = "quiet cause" } } })
write("/harness-doctor/latest.json", { status = "problems", problems = { { ledger = "H1" } } })
write("/harness-doctor/menu.txt", harnessMenu(3, "Harness doctor: 3 problems"))
local legacy = find(details(loadDoctors().menuItems()[2].menu), "known, awaiting snapshot")
check(legacy and #legacy.menu == 2 and text(legacy.menu[1].title) == "H1 · reported cause"
  and text(legacy.menu[2].title) == "H2 · quiet cause", "legacy header retains all open ledger rows without classifying them")
remove("/harness-ledger.json")
write("/harness-doctor/latest.json", { status = "problems", problems = {} })
trendHarness()
local previous = text(trendItems[1].title)
writeDays({ 0, 1, 2, 6, 7, 8, 800 })
local changed = trendDoctor.menuItems()[1].title
check(text(changed) == row("LLM", "2", nil, "▁▁▁▁▁▁█", "4") and text(changed) ~= previous,
  "today stays out of the median; a renamed journal invalidates the cache: " .. text(changed))
writeDays({ 0, 1, 2, 3, 4, 0, 8 })
local falling = trendDoctor.menuItems()[1].title
check(text(falling) == row("LLM", "2", nil, "▁▁▂▃▄▁█", "2"), "no trend arrow, whichever way yesterday went: " .. text(falling))
writeDays({ 5, 5, 5, 5, 5, 5, 5 })
local flat = trendDoctor.menuItems()[1].title
local flatRed = false
for at = BAR_AT, BAR_AT + 6 do flatRed = flatRed or sameColor(colorAt(flat, at), palette.RED) end
check(text(flat) == row("LLM", "2", nil, "███████", "5") and not flatRed, "a flat week has no RED bar: " .. text(flat))
metadata.speed.lost_min_day_by_day = writeDays({ false, 1, 2, 3, 4, 6, 8 })
metadata.spend.index_by_day = spendDays({ false, 1, 2, 3, 4, 6, 8 })
trendHarness()
local cold = trendDoctor.menuItems()
for index, name in ipairs(names) do
  local title = cold[index].title
  check(text(title) == row(name, values[index], UNITS[index], " ▁▂▃▄▆█",
    index == 5 and "30" or index == 6 and "0.30" or "3"),
    "cold start: an unmeasured day is a blank cell, measured days keep their bars: " .. text(title))
end
check(aligned({ table.unpack(cold, 1, 7) }), "cold start rows stay aligned")
metadata.speed.lost_min_day_by_day[trendDay(0)] = nil
trendHarness()
local oldSpeed = trendDoctor.menuItems()[5]
check(sameColor(colorAt(oldSpeed.title, 1), palette.DIM)
  and text(oldSpeed.title) == row("Lost time", "12", "min/day", " ▂▃▄▆█ ", "30"),
  "Speed without a current-day observation is DIM even when Harness is fresh: " .. text(oldSpeed.title))
metadata.speed.lost_min_day_by_day[trendDay(0)] = 80
metadata.speed.lost_min_day = nil
trendHarness()
local unknownSpeed = trendDoctor.menuItems()[5]
check(text(unknownSpeed.title) == row("Lost time", "–", "min/day", " ▁▂▃▄▆█", "30")
  and sameColor(colorAt(unknownSpeed.title, 1), palette.DIM) and sameColor(colorAt(unknownSpeed.title, VALUE_AT), palette.DIM),
  "a missing Speed floor is a DIM – despite today's retained history: " .. text(unknownSpeed.title))
metadata.speed.lost_min_day = 12
metadata.spend.tone = "worse"
trendHarness()
check(sameColor(colorAt(trendDoctor.menuItems()[6].title, VALUE_AT), palette.RED), "Spend's index RED when tokenmap's tone is worse")
metadata.spend.status, metadata.spend.index = "nodata", nil
trendHarness()
local staleSpend = trendDoctor.menuItems()[6]
check(text(staleSpend.title) == row("Spend", "–", "index", " ▁▂▃▄▆█", "0.30")
  and sameColor(colorAt(staleSpend.title, 1), palette.DIM) and sameColor(colorAt(staleSpend.title, VALUE_AT), palette.DIM),
  "a stale tracking.json is a DIM – on Spend, never its old index: " .. text(staleSpend.title))
metadata.spend.status, metadata.spend.index, metadata.spend.tone = "watch", 0.46, "better"
trendHarness()
write("/doctors/problem-days.jsonl", "")
trendItems = trendDoctor.menuItems()
check(text(trendItems[1].title) == summary("LLM", 2) and aligned({ table.unpack(trendItems, 1, 7) }),
  "empty history: bars blank, usual a DIM –")
local function egorLayer(menu)
  for _, item in ipairs(menu or {}) do
    if utf8.len(text(item.title)) > 64 then return false end
    if text(item.title) ~= "LLM details" and item.menu and not egorLayer(item.menu) then return false end
  end
  return true
end
check(find(cold[1].menu, "LLM details") and egorLayer(cold) and allMenlo(cold), "Egor's layer fits 64 cells, all Menlo")
local realEntry = limits.llmDoctorEntry
local staleTitle = "LLM doctor: 2 problems · stale · scanned 12d ago · rescanning"
limits.llmDoctorEntry = function()
  return { title = hs.styledtext.new(staleTitle, { font = palette.MONO }), problems = 2, status = "problems",
    menu = { { title = "original detail", disabled = true } } }
end
local staleItem = loadDoctors().menuItems()[1]
local staleDetails = details(staleItem.menu)
check(text(staleItem.title) == summary("LLM", 2) and sameColor(colorAt(staleItem.title, 1), palette.DIM)
  and #staleDetails == 4 and text(staleDetails[1].title) == staleTitle
  and text(staleDetails[2].title) == "original detail" and egorLayer({ staleItem }),
  "a stale doctor is a DIM name with its count; the full status and original rows sit in details")
limits.llmDoctorEntry = realEntry
remove("/speed-doctor/hs/" .. os.date("%Y-%m-%d") .. ".tsv")
remove("/doctors/problem-days.jsonl")
remove("/code-doctor/latest.json")
remove("/harness-doctor/latest.json")
tasks, alerts = {}, {}
if onlyTrends then
  os.execute("rm -rf '" .. dir .. "'")
  return #failures > 0 and "FAIL: " .. table.concat(failures, "; ") or "PASS: " .. checks .. " trend checks"
end

-- All quiet: the plain title the neighbouring entries use.
write("/llm-doctor/latest.json", llmDocument("ok", 0))
write("/harness-doctor/menu.txt", harnessMenu(0, "Harness doctor: ok"))
write("/updater-doctor/latest.json", { contract = 1, doctor = "updater", as_of_s = now, status = "ok",
  problem_count = 0, problems = {}, blind_spots = {}, vendors = {} })
write("/system-doctor/latest.json", { contract = 1, doctor = "system", as_of_s = now, status = "ok",
  problem_count = 0, problems = {}, blind_spots = {} })
local doctors = loadDoctors()
check(doctors.title() == "Doctors", "all ok: " .. text(doctors.title()))
local items = doctors.menuItems()
check(#items == 10 and text(items[1].title) == summary("LLM", 0) and text(items[2].title) == summary("Harness", 0)
  and text(items[3].title) == summary("Updater", 0) and text(items[4].title) == summary("Code", nil)
  and sameColor(colorAt(items[4].title, 1), palette.DIM) and sameColor(colorAt(items[4].title, VALUE_AT), palette.DIM)
  and text(items[7].title) == summary("System", 0) and sameColor(colorAt(items[7].title, 1), palette.GREEN),
  "the five doctors in order, System after Lost time and Spend")
check(text(items[3].title) == summary("Updater", 0) and sameColor(colorAt(items[3].title, 1), palette.GREEN), "a clean Updater doctor: " .. text(items[3].title))
local pendingRow = { id = "cli-behind:codex", rule = "cli-behind", state = "watch",
  fact = "codex 0.159.0 → 0.159.2 waiting: busy since 00:14" }
write("/updater-doctor/latest.json", { contract = 1, doctor = "updater", as_of_s = now, status = "ok",
  problem_count = 0, problems = { pendingRow }, blind_spots = {}, vendors = {} })
local pending = doctors.menuItems()[3]
check(text(pending.title) == summary("Updater", 0) and red(pending.title) and color(pending.title).alpha == 0.55,
  "a pending update is never a plain ok: " .. text(pending.title))
check(text(details(pending.menu)[1].title) == "Updater doctor: update pending"
  and text(details(pending.menu)[2].title) == pendingRow.fact and dimmed(details(pending.menu)[2].title), "the pending update is a watch row")
pendingRow.state, pendingRow.fact = "new", pendingRow.fact .. " · 26h"
write("/updater-doctor/latest.json", { contract = 1, doctor = "updater", as_of_s = now, status = "problems",
  problem_count = 1, problems = { pendingRow }, blind_spots = {}, vendors = {} })
pending = doctors.menuItems()[3]
check(text(pending.title) == summary("Updater", 1) and red(pending.title) and red(details(pending.menu)[1].title),
  "a pending update stuck past a day is red: " .. text(pending.title))
write("/updater-doctor/latest.json", { contract = 1, doctor = "updater", as_of_s = now, status = "ok",
  problem_count = 0, problems = {}, blind_spots = {}, vendors = {} })
check(text(fix(details(items[1].menu)).title) == "Fix — open a fixer chat" and fix(details(items[1].menu)).fn ~= nil, "LLM Fix button")
check(text(fix(details(items[2].menu)).title) == "Fix — open a fixer chat", "Harness Fix button")
check(text(fix(details(items[3].menu)).title) == "Fix — update and integrate all vendors", "Updater Fix button")
check(text(fix(details(items[4].menu)).title) == "Fix — open a fixer chat", "Code Fix button")
for index = 1, 4 do
  local item = items[index]
  check(text(fixer(details(item.menu)).title) == "fixer: never ran" and fixer(details(item.menu)).disabled and dimmed(fixer(details(item.menu)).title),
    "no run record: " .. text(fixer(details(item.menu)).title))
  check(text(refreshRow(details(item.menu)).title) == "Refresh" and (details(item.menu)[#details(item.menu) - 3] or {}).title == "-",
    text(item.title) .. ": a separator, then Refresh, above Fix")
end
check(allMenlo(items), "every row under Doctors is Menlo 13")
check(text(details(items[2].menu)[1].title) == "Waits  ok", "the Harness doctor's own rows come first")
local journal = io.open(dir .. "/harness-doctor/menu/" .. os.date("%Y-%m-%d") .. ".tsv")
local journalText = journal and journal:read("*a") or ""
if journal then journal:close() end
check(journalText:find("\tdoctors\n", 1, true) ~= nil, "the build is not timed into the menu journal")

-- A background build journals `doctors:bg` into the speed journal and nothing into the click journal.
local function slurpAt(path)
  local handle = io.open(dir .. path)
  local body = handle and handle:read("*a") or ""
  if handle then handle:close() end
  return body
end
local function count(body, line) return select(2, body:gsub(line:gsub("%p", "%%%0"), "")) end
local hsDay = "/speed-doctor/hs/" .. os.date("%Y-%m-%d") .. ".tsv"
local clickDay = "/harness-doctor/menu/" .. os.date("%Y-%m-%d") .. ".tsv"
check(count(slurpAt(hsDay), "\tdoctors:bg\n") == 0, "a click build journaled as doctors:bg")
local clicks = count(slurpAt(clickDay), "\tdoctors\n")
limits.backgroundMenu(doctors.menuItems)
check(count(slurpAt(hsDay), "\tdoctors:bg\n") == 1, "a background build is not journaled once as doctors:bg: " .. slurpAt(hsDay))
check(slurpAt(hsDay):match("^%d+\t%d+\tdoctors:bg\n$") ~= nil, "doctors:bg line shape: " .. slurpAt(hsDay))
check(count(slurpAt(clickDay), "\tdoctors\n") == clicks, "a background build timed into the click journal")

-- The lag probe: a 1 s timer, a line only past 50 ms of lag, the oldest days pruned.
check(#lagTimers > 0 and lagTimers[#lagTimers].interval == 1, "no 1 s lag probe timer")
local lagBase = math.floor(os.time()) + 0.0
fakeClock, fakeUp = lagBase, 500
doctors.lagTick()
fakeClock, fakeUp = lagBase + 1.02, 501.02
doctors.lagTick()
fakeClock, fakeUp = lagBase + 2.12, 502.12
doctors.lagTick()
fakeClock, fakeUp = lagBase + 2.12 + 3600, 503.12
doctors.lagTick()
fakeClock, fakeUp = nil, nil
local lagStart, lagEnd = slurpAt(hsDay):match("(%d+)\t(%d+)\ths%-lag\n")
check(count(slurpAt(hsDay), "\ths-lag\n") == 1 and lagStart and math.abs(tonumber(lagEnd) - tonumber(lagStart) - 100000) < 1000,
  "one hs-lag line of 100 ms, none for an hour of sleep: " .. slurpAt(hsDay))
write("/speed-doctor/hs/2000-01-01.tsv", "1\t2\tdoctors:bg\n")
limits.backgroundMenu(loadDoctors().menuItems)
check(slurpAt("/speed-doctor/hs/2000-01-01.tsv") ~= "", "the hs writer pruned a day: bin/speed-doctor owns the prune")
os.remove(dir .. "/speed-doctor/hs/2000-01-01.tsv")

-- The latest run per doctor is cached until bin/doctor-fix writes a record into the runs directory.
local realDir, runScans = hs.fs.dir, 0
fakeHs.fs = setmetatable({ dir = function(path, ...)
  if path:match("/doctors/runs$") then runScans = runScans + 1 end
  return realDir(path, ...)
end }, { __index = hs.fs })
local pinRuns = "touch -mt 202601010000 " .. dir .. "/doctors/runs"
os.execute(pinRuns)
local cached = loadDoctors()
cached.menuItems()
local firstScans = runScans
cached.menuItems()
check(firstScans == 5 and runScans == firstScans, "a second menu build rescanned the runs directory: "
  .. firstScans .. " then " .. runScans)
write("/doctors/runs/llm-all-20261001T020000Z-c0de.json", { id = "llm-all-20261001T020000Z-c0de", doctor = "llm",
  area = "all", created_at = iso(now - 60), launched_at = iso(now - 60), problems = {} })
os.execute(pinRuns)
local fresh = cached.menuItems()
check(runScans == firstScans + 5 and text(fixer(details(fresh[1].menu)).title):match("^fixer: running"),
  "a new run record is read on the next build, inside the same directory mtime: " .. text(fixer(details(fresh[1].menu)).title))
remove("/doctors/runs/llm-all-20261001T020000Z-c0de.json")
fakeHs.fs = nil

-- N problems, blind, failed.
write("/llm-doctor/latest.json", llmDocument("problems", 2))
write("/harness-doctor/menu.txt", harnessMenu(3, "Harness doctor: 3 problems"))
write("/updater-doctor/latest.json", updater)
doctors = loadDoctors()
check(text(doctors.title()) == "Doctors: 6 problems" and red(doctors.title()), "N problems: " .. text(doctors.title()))
updater.status = "blind"
write("/updater-doctor/latest.json", updater)
check(text(doctors.title()) == "Doctors: 6 problems · blind", "blind: " .. text(doctors.title()))
write("/llm-doctor/latest.json", llmDocument("error", 0))
check(text(doctors.title()) == "Doctors: 4 problems · blind · failed", "failed: " .. text(doctors.title()))
updater.status = "problems"
write("/updater-doctor/latest.json", updater)
write("/llm-doctor/latest.json", llmDocument("ok", 0))
local harnessEntry = limits.harnessDoctorEntry
limits.harnessDoctorEntry = function() error("menu.txt exploded") end
check(text(doctors.title()) == "Doctors: 1 problem · failed", "a throwing builder: " .. text(doctors.title()))
local broken = doctors.menuItems()[2]
check(text(broken.title) == summary("Harness", nil) and red(broken.title)
  and text(details(broken.menu)[1].title) == "Harness doctor: failed to render"
  and details(broken.menu)[3].title == "-" and text(fix(details(broken.menu)).title) == "Fix — open a fixer chat",
  "a throwing builder keeps its Fix row")
limits.harnessDoctorEntry = harnessEntry

-- The Updater doctor's rows.
items = doctors.menuItems()
local up = items[3]
check(text(up.title) == summary("Updater", 1) and red(up.title), "Updater title: " .. text(up.title))
check(text(details(up.menu)[1].title) == "codex 0.160.0 is out and not integrated" and red(details(up.menu)[1].title), "a new problem is red")
check(text(details(up.menu)[2].title) == "claude lists a model no leg uses" and dimmed(details(up.menu)[2].title), "a watch problem is dim")
local codex = find(details(up.menu), "codex 0.159.0")
check(codex and text(codex.title) == "codex 0.159.0 · checked 3h ago · latest 0.160.0", "vendor row: "
  .. (codex and text(codex.title) or "missing"))
local claude = find(details(up.menu), "claude 2.4.1")
check(claude and text(claude.title) == "claude 2.4.1 · checked 3h ago", "an up-to-date vendor names no latest")
local grok = find(details(up.menu), "grok 1.0.40")
check(grok and text(grok.title) == "grok 1.0.40 · checked 3h ago" and dimmed(grok.title),
  "an empty latest is no update: " .. (grok and text(grok.title) or "missing"))
local sub = {}
for _, item in ipairs(codex and codex.menu or {}) do sub[#sub + 1] = item.title == "-" and "-" or text(item.title) end
check(table.concat(sub, "|") == "gpt-6-astra|gpt-6-mini|-|codex-0.159.0 · open · 0.158.0 → 0.159.0 · 2d ago"
  .. "|codex-0.158.0 · closed · 0.157.0 → 0.158.0 · 4d ago", "vendor submenu: " .. table.concat(sub, "|"))
check(codex and codex.menu[5].menu and text(codex.menu[5].menu[1].title) == "worker-pick table", "an event lists what it changed")
local spots = find(details(up.menu), "not measured")
check(spots and dimmed(spots.title) and #spots.menu == 1 and text(spots.menu[1].title) == "grok has no changelog to read"
  and text(spots.menu[1].menu[1].title) == "why: xAI publishes release notes only on X, which the doctor"
  and text(spots.menu[1].menu[#spots.menu[1].menu].title) == "would catch it: a feed",
  "blind spots sit one level down, each with its why")
local long = find(details(up.menu), "codex: 3 other")
local detail = {}
for _, item in ipairs(long and long.menu or {}) do detail[#detail + 1] = text(item.title) end
check(long and text(long.title) == "codex: 3 other installs at another version…" and dimmed(long.title)
  and not long.disabled and #detail == 4 and table.concat(detail):gsub(" ", "") == updater.problems[3].fact:gsub(" ", ""),
  "a long problem is one short row with its whole fact one level down: " .. (long and text(long.title) or "missing"))
local function widest(menu)
  local most = 0
  for _, item in ipairs(menu or {}) do
    if item.title ~= "-" then most = math.max(most, utf8.len(text(item.title))) end
  end
  return most
end
check(widest(details(up.menu)) <= 64 and widest(long and long.menu) <= 64, "an Updater row is wider than 64: " .. widest(details(up.menu)))
local refresh = refreshRow(details(up.menu))
check(text(refresh.title) == "Refresh" and refresh.fn and (details(up.menu)[#details(up.menu) - 3] or {}).title == "-",
  "the Updater doctor has Refresh after a separator")
tasks = {}
refresh.fn()
check(#tasks == 1 and tasks[1].path == "/fixture/bin/updater-doctor" and #tasks[1].args == 0, "Refresh runs bin/updater-doctor")
check((tasks[1].env or {}).DOCTOR_TRIGGER == "menu", "a menu Refresh does not tag its collector run as menu")
check(text(refreshRow(details(doctors.menuItems()[3].menu)).title) == "refreshing…", "a running Refresh")
tasks[1]:finish(0)
updater.as_of_s = now - 3 * 86400
write("/updater-doctor/latest.json", updater)
check(text(doctors.menuItems()[3].title) == summary("Updater", 1)
  and sameColor(colorAt(doctors.menuItems()[3].title, 1), palette.DIM)
  and text(details(doctors.menuItems()[3].menu)[1].title) == "Updater doctor: 1 problem · stale 3d",
  "stale: " .. text(doctors.menuItems()[3].title))
updater.status, updater.problem_count, updater.as_of_s = "error", 0, now
updater.self = { collector_s = 1, error = "vendor-fingerprint: no such file" }
write("/updater-doctor/latest.json", updater)
up = doctors.menuItems()[3]
check(text(up.title) == summary("Updater", nil) and red(up.title)
  and text(details(up.menu)[1].title) == "Updater doctor: collector failed"
  and text(details(up.menu)[2].title) == "vendor-fingerprint: no such file"
  and red(details(up.menu)[2].title), "a failed collector names its error")

-- A missing document.
remove("/updater-doctor/latest.json")
up = doctors.menuItems()[3]
check(text(up.title) == summary("Updater", nil) and text(details(up.menu)[1].title) == "no data yet"
  and details(up.menu)[2].title == "-" and text(details(up.menu)[3].title) == "Refresh" and #details(up.menu) == 5, "missing file: " .. text(up.title))

-- The LLM and Harness blocks keep the same width: a long row is clipped, its text one level down.
local llmWide = llmDocument("ok", 0)
llmWide.not_measurable = { "worker false-green reports", "weakened tests", "the code revision a leg ran",
  "false-clean reviews" }
write("/llm-doctor/latest.json", llmWide)
write("/harness-doctor/menu.txt", "T\t1\t" .. now .. "\tHarness doctor: 1 problem\n"
  .. "0\td\t\tStop hooks: problem · end-of-turn checks held back over 2 h while a background task ran\n"
  .. "1\td\t\tstarted before 09-28 22:16 · cause unknown\n")
items = doctors.menuItems()
local measurable = find(details(items[1].menu), "not measurable yet")
check(measurable and text(measurable.title) == "not measurable yet: worker false-green reports, weakened…"
  and measurable.menu and not measurable.disabled, "a long LLM row: " .. (measurable and text(measurable.title) or "missing"))
local stop = details(items[2].menu)[1]
local stopRows = {}
for _, item in ipairs(stop.menu or {}) do stopRows[#stopRows + 1] = item.title == "-" and "-" or text(item.title) end
check(text(stop.title) == "Stop hooks: problem · end-of-turn checks held back over 2 h…"
  and table.concat(stopRows, "|") == "Stop hooks: problem · end-of-turn checks held back over 2 h|"
  .. "while a background task ran|-|started before 09-28 22:16 · cause unknown", "a long Harness row keeps its own rows: "
  .. table.concat(stopRows, "|"))
for index = 1, 4 do check(widest(details(items[index].menu)) <= 64, text(items[index].title) .. " has a row over 64") end
write("/llm-doctor/latest.json", llmDocument("ok", 0))

-- Code doctor: group rows sum to the header, one unit; candidates and cost one level down, dim.
local codeDoc = { contract = 1, doctor = "code", as_of_s = now, status = "problems", problem_count = 3,
  groups = { dead = 2, heavy = 0, duplicate = 1, promise = 0 },
  problems = {
    { id = "cause:llm-legs/bin/old-sync", group = "dead", state = "new", fact = "bin/old-sync and its lib: no entry point",
      plan = "delete both and the test that only covers them" },
    { id = "cause:llm-legs/lib/x.sh#robot_refresh", group = "dead", state = "open", fact = "robot refresh is retired" },
    { id = "cause:llm-legs/lib/a.py#drive", group = "duplicate", state = "regressed", fact = "drive() twice" },
    { id = "R9", group = "heavy", state = "fixed-pending", fact = "a slow test, fixed" } },
  candidates = { waiting = 4, top = { { id = "cause:x", group = "heavy", detail = "tests/test_slow.sh takes 300s" } } },
  cost = { tokens = 123456, wall_s = 600 }, yield = { lines_removed = 40, causes_closed = 1 },
  blind_spots = { { id = "language:swift", what = "swift: 3 files no detector reads", reason = "only five languages" } } }
local before = tonumber(text(loadDoctors().title()):match("(%d+) problem") or 0)
write("/code-doctor/latest.json", codeDoc)
local codeItem = loadDoctors().menuItems()[4]
check(text(codeItem.title) == summary("Code", 3) and red(codeItem.title), "the Code header: " .. text(codeItem.title))
local groupSum, groupNames = 0, {}
for _, item in ipairs(details(codeItem.menu)) do
  local name, count = text(item.title):match("^(%a+): (%d+) problems?$")
  if name then groupSum, groupNames[#groupNames + 1] = groupSum + tonumber(count), name end
end
check(groupSum == 3 and table.concat(groupNames, " ") == "Dead Heavy Duplicate Promise", "the Code groups sum to the header: "
  .. groupSum .. " " .. table.concat(groupNames, " "))
check(red(details(codeItem.menu)[1].title) and #details(codeItem.menu)[1].menu == 2 and dimmed(details(codeItem.menu)[2].title)
  and #details(codeItem.menu)[2].menu == 1 and dimmed(details(codeItem.menu)[2].menu[1].title),
  "a group with problems is red and lists them; an empty group is dim, its fixed-pending rows dim under it")
check(text(details(codeItem.menu)[1].menu[1].title) == "bin/old-sync and its lib: no entry point" and details(codeItem.menu)[1].menu[1].menu,
  "a problem row carries its plan one level down")
local waitingRow, costRow = find(details(codeItem.menu), "candidates waiting"), find(details(codeItem.menu), "cost ")
check(waitingRow and text(waitingRow.title) == "candidates waiting: 4" and dimmed(waitingRow.title) and #waitingRow.menu == 1,
  "candidates waiting is dim with its top candidates one level down")
check(costRow and text(costRow.title) == "cost 123k tokens · 10 min · yield 40 lines, 1 causes closed" and dimmed(costRow.title),
  "cost and yield are one dim row")
check(find(details(codeItem.menu), "not measured") and refreshRow(details(codeItem.menu)) and text(refreshRow(details(codeItem.menu)).title) == "Refresh",
  "blind spots, then Refresh above Fix")
tasks = {}
refreshRow(details(codeItem.menu)).fn()
check(#tasks == 1 and tasks[1].path == "/fixture/bin/code-doctor" and table.concat(tasks[1].args, " ") == "refresh --quiet",
  "Refresh runs bin/code-doctor refresh --quiet")
tasks[1]:finish(0, "")
tasks = {}
fix(details(codeItem.menu)).fn()
check(#tasks == 1 and table.concat(tasks[1].args, " ") == "launch code", "Fix on the Code doctor launches code")
tasks[1]:finish(0, "")
check(text(loadDoctors().title()) == "Doctors: " .. (before + 3) .. " problems", "the Code doctor counts into Doctors: "
  .. text(loadDoctors().title()))
remove("/code-doctor/latest.json")
tasks, alerts = {}, {}

-- Fixer rows off the newest run record.
write("/doctors/runs/llm-20260101T000000Z.json", { doctor = "llm", launched_at = iso(now - 90 * 86400) })
write("/doctors/runs/llm-20260201T000000Z.json", { doctor = "llm", launched_at = iso(now - 3 * 86400),
  closed_at = iso(now - 2 * 86400), problems = { "a", "b", "c", "d" },
  decisions = { { id = "a", verdict = "fixed" }, { id = "b", verdict = "fixed" }, { id = "c", verdict = "handoff" },
    { id = "d", verdict = "fixed" }, { id = "judge", verdict = "changed" } } })
write("/doctors/runs/harness-20260201T000000Z.json", { doctor = "harness", launched_at = iso(now - 2 * 3600 - 60) })
write("/doctors/runs/updater-20260201T000000Z.json", { doctor = "updater", launched_at = iso(now - 3 * 86400),
  abandoned_at = iso(now - 86400 - 60) })
items = doctors.menuItems()
check(text(fixer(details(items[1].menu)).title) == "fixer: ran 2d ago · closed · 3 fixed · 1 handoff", "closed: " .. text(fixer(details(items[1].menu)).title))
check(text(fix(details(items[1].menu)).title) == "Fix — open a fixer chat" and fix(details(items[1].menu)).fn, "a closed run leaves Fix on")
check(text(fixer(details(items[2].menu)).title) == "fixer: running for 2h", "open: " .. text(fixer(details(items[2].menu)).title))
check(text(fix(details(items[2].menu)).title) == "Fix — fixer running for 2h" and fix(details(items[2].menu)).disabled
  and not fix(details(items[2].menu)).fn and dimmed(fix(details(items[2].menu)).title), "Fix is off while a young run is open")
check(text(fixer(details(items[3].menu)).title) == "fixer: abandoned 24h ago", "abandoned: " .. text(fixer(details(items[3].menu)).title))
write("/doctors/runs/harness-20260201T000000Z.json", { doctor = "harness", launched_at = iso(now - 14 * 3600) })
items = doctors.menuItems()
check(text(fix(details(items[2].menu)).title) == "Fix — open a fixer chat" and fix(details(items[2].menu)).fn, "a run open 14 h no longer holds Fix")
check(text(fixer(details(items[2].menu)).title) == "fixer: running for 14h", "old open run: " .. text(fixer(details(items[2].menu)).title))

-- The Fix button's command line, its opening row and its alerts.
tasks, alerts = {}, {}
fix(details(items[3].menu)).fn()
check(#tasks == 1 and tasks[1].path == "/fixture/bin/doctor-fix" and table.concat(tasks[1].args, " ") == "launch updater",
  "Fix runs bin/doctor-fix launch updater")
check(tasks[1] and tasks[1].env and tasks[1].env.HOME == os.getenv("HOME"), "the fix task lost HOME")
local opening = fix(details(doctors.menuItems()[3].menu))
check(text(opening.title) == "Fix — opening…" and opening.disabled, "a running launch reads opening")
fix(details(items[3].menu)).fn()
check(#tasks == 1, "a second click launched a second fixer")
tasks[1]:finish(0, "starting\nopened fixer chat «Updater fix»\n")
check(alerts[1] == "opened fixer chat «Updater fix»", "the last output line: " .. tostring(alerts[1]))
check(text(fix(details(doctors.menuItems()[3].menu)).title) == "Fix — update and integrate all vendors", "Fix is back after exit")
fix(details(doctors.menuItems()[1].menu)).fn()
check(table.concat(tasks[2].args, " ") == "launch llm", "Fix on the LLM doctor launches llm")
tasks[2]:finish(3, "", "checking\nrefused: a run is already open\n")
check(alerts[2] and alerts[2]:find("exit 3", 1, true) and alerts[2]:find("refused: a run is already open", 1, true),
  "a failed launch shows its line: " .. tostring(alerts[2]))

-- The newest run record by its own clock, whatever area its name sorts under; a failed launch is final.
write("/doctors/runs/llm-workers-20260301T000000Z-aaaa.json", { doctor = "llm", created_at = iso(now - 5 * 86400),
  launched_at = iso(now - 5 * 86400), closed_at = iso(now - 5 * 86400) })
write("/doctors/runs/llm-reviewers-20260101T000000Z-bbbb.json", { doctor = "llm", created_at = iso(now - 3 * 3600),
  failed_at = iso(now - 3 * 3600), note = "no account left to launch on" })
items = doctors.menuItems()
local failedRow = fixer(details(items[1].menu))
check(text(failedRow.title) == "fixer: failed 3h ago" and red(failedRow.title) and failedRow.menu
  and text(failedRow.menu[1].title) == "no account left to launch on", "failed run: " .. text(failedRow.title))
check(fix(details(items[1].menu)).fn ~= nil, "a failed run leaves Fix on")

-- Night: bin/night-run latest --menu, a row under the doctors with a job per line, hidden while it
-- prints nothing; Run everything under it.
tasks = {}
doctors = loadDoctors()
items = doctors.menuItems()
local nightTask = tasks[1]
check(#items == 10 and nightTask and nightTask.path == "/fixture/bin/night-run"
  and table.concat(nightTask.args, " ") == "latest --menu", "the Night row reads bin/night-run latest --menu")
doctors.menuItems()
check(#tasks == 1, "a second build started a second night-run")
local quietTitle = text(doctors.title())
local reason = "deadline, branch night/x/codex (llm-legs 083450f): round 20260930T032123Z-43d191b confirmed 7 findings, unfixed"
nightTask:finish(0, "Last night 30 Sep: 1 of 3 · 1 unfinished · 1 need you\t1\t0\n"
  .. "LLM fixer: debt\t0\t\n"
  .. "codex update · unfinished · deadline\t2\t" .. reason .. "\n"
  .. "cleanup p1 · needs you · step 10 needs his word\t1\tstep 10 needs his word\n")
items = doctors.menuItems()
local nightRow = items[8]
check(#items == 11 and text(nightRow.title) == "Last night 30 Sep: 1 of 3 · 1 unfinished · 1 need you"
  and red(nightRow.title) and not nightRow.disabled and allMenlo({ nightRow }),
  "a red night: " .. (nightRow and text(nightRow.title) or "missing"))
local jobs = nightRow.menu or {}
check(#jobs == 3 and text(jobs[1].title) == "LLM fixer: debt" and dimmed(jobs[1].title) and jobs[1].disabled
  and text(jobs[2].title) == "codex update · unfinished · deadline" and not dimmed(jobs[2].title)
  and not red(jobs[2].title) and jobs[2].menu
  and text(jobs[3].title) == "cleanup p1 · needs you · step 10 needs his word" and red(jobs[3].title),
  "a job per row: done dim and wordless, unfinished plain, red only where Egor is needed")
local reasonRows = {}
for _, item in ipairs(jobs[2] and jobs[2].menu or {}) do reasonRows[#reasonRows + 1] = text(item.title) end
check(table.concat(reasonRows, " ") == reason and widest(jobs[2].menu) <= 64, "a job's whole reason one level down")
check(text(doctors.title()) == quietTitle, "the Night row changed the Doctors title")
doctors.refreshNight()
tasks[#tasks]:finish(0, "Last night 30 Sep: 4 of 4\t0\t0\n")
nightRow = doctors.menuItems()[8]
check(nightRow and text(nightRow.title) == "Last night 30 Sep: 4 of 4" and dimmed(nightRow.title)
  and nightRow.disabled, "a clean night with no job rows is dim")

-- Run everything: bin/night-run start behind a confirmation; off while a night runs.
items = doctors.menuItems()
local run = items[#items]
check(items[#items - 2].title == "-" and text(run.title) == "Run everything now" and run.fn,
  "Run everything is the last Doctors item")
check(text(items[#items - 1].title) == "Cleanup now" and items[#items - 1].fn,
  "Cleanup now sits right above Run everything")
tasks, dialogs, answer = {}, {}, "Cancel"
run.fn()
check(#dialogs == 1 and #tasks == 0, "Cancel on the confirmation starts nothing")
check(dialogs[1] and dialogs[1][2]:find("hours", 1, true) and dialogs[1][3] == "Cancel" and dialogs[1][4] == "Run",
  "the confirmation says it works for hours, Cancel first")
answer = "Run"
run.fn()
check(#tasks == 1 and tasks[1].path == "/fixture/bin/night-run" and table.concat(tasks[1].args, " ") == "start"
  and tasks[1].env and tasks[1].env.HOME == os.getenv("HOME"), "Run launches bin/night-run start")
local opening = doctors.menuItems()
check(text(opening[#opening].title) == "Run everything — opening…" and opening[#opening].disabled
  and not opening[#opening].fn, "a launching night reads opening")
doctors.runEverything()
check(#tasks == 1 and #dialogs == 2, "a second click launched a second night")
tasks[1]:finish(0, "night 20260930T120000Z-abcd started: orchestrator on acct\n")
check(alerts[#alerts] == "night 20260930T120000Z-abcd started: orchestrator on acct", "the start line is the alert")
doctors.menuItems()
check(#tasks == 2 and table.concat(tasks[2].args, " ") == "latest --menu", "a started night is read back at once")
tasks[2]:finish(0, "Night run since 12:00: 0 of 1 done · 1 in progress\t0\t1\nLLM fixer · in progress\t0\t\n")
local busy = doctors.menuItems()
check(text(busy[#busy].title) == "Run everything — a night run is going" and busy[#busy].disabled and not busy[#busy].fn,
  "a running night holds Run everything")
local dialogCount = #dialogs
doctors.runEverything()
check(#dialogs == dialogCount and #tasks == 2, "a running night asked or started again")
doctors.refreshNight()
tasks[#tasks]:finish(4, "", "night-run: cannot read\n")
check(#doctors.menuItems() == 10, "an empty night-run hides the row")

-- Cleanup now: bin/night-run start --cleanup behind the same Cancel-first confirmation; off while a night runs.
doctors.refreshNight()
tasks[#tasks]:finish(0, "Last night 30 Sep: 4 of 4\t0\t0\tn-1\n")
tasks, dialogs, answer = {}, {}, "Cancel"
items = doctors.menuItems()
local cleanup = items[#items - 1]
cleanup.fn()
check(#dialogs == 1 and #tasks == 0 and dialogs[1][3] == "Cancel" and dialogs[1][4] == "Run"
  and dialogs[1][2]:find("No fixers, no updates", 1, true), "Cancel on the cleanup confirmation starts nothing")
answer = "Run"
cleanup.fn()
check(#tasks == 1 and table.concat(tasks[1].args, " ") == "start --cleanup", "Cleanup now runs bin/night-run start --cleanup")
tasks[1]:finish(0, "night n-2 started: orchestrator on acct\n")
doctors.menuItems()
tasks[#tasks]:finish(0, "Night run since 12:00: no jobs\t0\t1\tn-2\n")
items = doctors.menuItems()
check(text(items[#items - 1].title) == "Cleanup — a night run is going" and items[#items - 1].disabled
  and not items[#items - 1].fn, "a running night holds Cleanup now")

-- Continue: each unfinished job of a night that no longer runs, and all of them plus the cleanup.
doctors.refreshNight()
tasks[#tasks]:finish(0, "Last night 30 Sep: 1 of 3 · 2 unfinished\t2\t0\tn-1\n"
  .. "LLM fixer\t0\t\tllm-x\tfixer\t0\n"
  .. "codex update · unfinished · deadline\t2\t" .. reason .. "\tcodex-e1\tvendor\t1\n"
  .. "cleanup · unfinished · deadline\t2\t\tdebt\tdebt\t1\n")
tasks, dialogs, answer = {}, {}, "Continue"
jobs = doctors.menuItems()[8].menu
check(#jobs == 5 and jobs[1].disabled and jobs[4].title == "-", "three jobs, then a separator: " .. #jobs)
local codexMenu = jobs[2].menu or {}
local continueJob = codexMenu[#codexMenu]
check(continueJob and text(continueJob.title) == "Continue this job" and codexMenu[#codexMenu - 1].title == "-"
  and text(codexMenu[1].title) == reason:sub(1, #text(codexMenu[1].title)), "a job's reason, then Continue this job")
check(jobs[3].menu and #jobs[3].menu == 1 and not jobs[3].disabled, "a job with no reason still continues")
check(text(jobs[5].title) == "Continue unfinished (1 job) + cleanup" and jobs[5].fn, "Continue counts the jobs besides the cleanup")
continueJob.fn()
check(#tasks == 1 and table.concat(tasks[1].args, " ") == "start --resume n-1 --job codex-e1" and dialogs[1][3] == "Cancel",
  "Continue this job resumes night n-1 for codex-e1 alone")
tasks[1]:finish(0, "night n-1 resumed: orchestrator on acct\n")
doctors.menuItems()
tasks[#tasks]:finish(0, "Last night 30 Sep: 2 unfinished\t0\t0\tn-1\ncodex update · unfinished\t0\t\tcodex-e1\tvendor\t1\n")
tasks = {}
jobs = doctors.menuItems()[8].menu
jobs[#jobs].fn()
check(#tasks == 1 and table.concat(tasks[1].args, " ") == "start --resume n-1", "Continue unfinished resumes the whole night")
tasks[1]:finish(0, "night n-1 resumed\n")
doctors.menuItems()
tasks[#tasks]:finish(0, "Night run since 12:00: 1 in progress\t0\t1\tn-1\ncodex update · in progress\t0\t\tcodex-e1\tvendor\t0\n")
jobs = doctors.menuItems()[8].menu
check(#jobs == 1 and jobs[1].disabled, "a running night offers no Continue")

-- Known, quiet: an open ledger row no problem names is one dim row per doctor, the ids one level down.
local quietDoc = llmDocument("problems", 1)
quietDoc.problems = { { id = "M1", ledger = "M1", state = "open" }, { id = "ledger:M2", state = "new" } }
write("/llm-doctor/latest.json", quietDoc)
write("/llm-ledger.json", { rows = {
  { id = "M1", status = "open", title = "seen" }, { id = "M2", status = "open", title = "a faulty row" },
  { id = "V14", status = "open", title = "the judge ruled on fewer claims than it was given" },
  { id = "W1", status = "open", title = "a worker row" }, { id = "R3", status = "fixed", title = "done" } } })
write("/harness-doctor/menu.txt", "T\t3\t" .. now .. "\tHarness doctor: 3 problems\nH\t"
  .. hs.json.encode({ status = "problems", problems = {} }) .. "\n0\td\t\tWaits  ok\n")
write("/harness-ledger.json", { rows = { { id = "suites-llm-legs-concurrent-load", status = "open" } } })
items = doctors.menuItems()
local quietLlm = details(items[1].menu)[#details(items[1].menu) - 2]
check(text(quietLlm.title) == "known, quiet" and dimmed(quietLlm.title) and #quietLlm.menu == 2
  and text(quietLlm.menu[1].title) == "V14 · the judge ruled on fewer claims than it was given"
  and text(quietLlm.menu[2].title) == "W1 · a worker row", "the LLM doctor's quiet rows: " .. text(quietLlm.title))
local quietHarness = details(items[2].menu)[#details(items[2].menu) - 2]
check(text(quietHarness.title) == "known, quiet" and text(quietHarness.menu[1].title) == "suites-llm-legs-concurrent-load",
  "the Harness doctor's quiet row: " .. text(quietHarness.title))
check(text(details(items[3].menu)[#details(items[3].menu) - 2].title) == "Refresh", "no ledger rows, no quiet row")
write("/code-doctor/latest.json", { contract = 1, doctor = "code", as_of_s = now, status = "ok", problem_count = 0,
  problems = {} })
write("/code-ledger.json", { rows = { { id = "C1", status = "open", title = "a code row" } } })
items = doctors.menuItems()
local codeQuiet = false
for _, row in ipairs(details(items[4].menu)) do
  codeQuiet = codeQuiet or row.title ~= "-" and text(row.title) == "known, quiet"
end
check(not codeQuiet, "the Code fixer takes no quiet rows (doctor-fix snapshot), so its menu shows none")
remove("/code-doctor/latest.json")
remove("/code-ledger.json")
quietDoc.status = "error"
write("/llm-doctor/latest.json", quietDoc)
items = doctors.menuItems()
check(not text(details(items[1].menu)[#details(items[1].menu) - 2].title):find("known, quiet", 1, true), "a failed collector hides nothing as quiet")

-- One vocabulary: each night label tests/test_doctors_menu.sh made through bin/doctor-fix and
-- bin/night-run from these documents names a doctor and, after the colon, a row its menu shows.
if vocab then
  local function slurp(path)
    local handle = assert(io.open(vocab .. "/" .. path))
    local body = handle:read("*a")
    handle:close()
    return body
  end
  write("/llm-doctor/latest.json", slurp("llm.json"))
  write("/harness-doctor/menu.txt", slurp("menu.txt"))
  write("/updater-doctor/latest.json", slurp("updater.json"))
  write("/code-doctor/latest.json", slurp("code.json"))
  local menus = {}
  for _, item in ipairs(loadDoctors().menuItems()) do
    local name = text(item.title):match("^(%a+) ")
    if name then menus[name] = details(item.menu) end
  end
  local labels = 0
  for label in slurp("labels.txt"):gmatch("[^\n]+") do
    label, labels = label:match("^(.-) · ") or label, labels + 1
    local name, area = label:match("^(%a+) fixer:? ?(.*)$")
    local vendor = not name and label:match("^(%S+) update$")
    local menu = menus[name or vendor and "Updater"]
    local want = (area and area ~= "" and area .. ":" or vendor and vendor .. " " or ""):lower()
    local shown = menu ~= nil and want == ""
    for _, item in ipairs(menu or {}) do
      shown = shown or item.title ~= "-" and text(item.title):lower():sub(1, #want) == want
      for _, sub in ipairs(text(item.title):match("^Lost time: ") and item.menu or {}) do
        shown = shown or sub.title ~= "-" and text(sub.title):lower():sub(1, #want) == want
      end
    end
    check(shown, "night label «" .. label .. "» names no row of its doctor's menu")
  end
  check(labels == 16, "the vocabulary labels: " .. labels)
end

os.execute("rm -rf '" .. dir .. "'")
if #failures > 0 then return "FAIL: " .. table.concat(failures, "; ") end
return "PASS: " .. checks .. " doctors menu checks"
