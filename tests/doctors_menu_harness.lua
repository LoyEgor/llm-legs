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
for _, sub in ipairs({ "", "/llm-doctor", "/harness-doctor", "/harness-doctor/menu", "/updater-doctor", "/doctors",
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
local fakeHs = setmetatable({
  pathwatcher = false,
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

local function loadDoctors()
  local env = setmetatable({ hs = fakeHs, require = function(name)
    if name == "llm-limits" then return limits end
    return require(name)
  end }, { __index = _G })
  local doctors = assert(loadfile(root .. "/hammerspoon/doctors.lua", "t", env))()
  doctors.doctorsDir = dir .. "/doctors"
  doctors.updaterDoctorDir = dir .. "/updater-doctor"
  doctors.doctorFixCmd = "/fixture/bin/doctor-fix"
  doctors.updaterDoctorCmd = "/fixture/bin/updater-doctor"
  doctors.nightRunCmd = "/fixture/bin/night-run"
  doctors.llmDoctorDir = dir .. "/llm-doctor"
  doctors.harnessDoctorDir = dir .. "/harness-doctor"
  doctors.llmLedger = dir .. "/llm-ledger.json"
  doctors.harnessLedger = dir .. "/harness-ledger.json"
  doctors.updaterLedger = dir .. "/updater-ledger.json"
  doctors.cacheSeconds = 0
  return doctors
end

local now = os.time()
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
  },
}
write("/snapshot.json", { as_of = now, total = 0, anomalies = {} })

-- All quiet: the plain title the neighbouring entries use.
write("/llm-doctor/latest.json", llmDocument("ok", 0))
write("/harness-doctor/menu.txt", harnessMenu(0, "Harness doctor: OK"))
write("/updater-doctor/latest.json", { contract = 1, doctor = "updater", as_of_s = now, status = "ok",
  problem_count = 0, problems = {}, blind_spots = {}, vendors = {} })
local doctors = loadDoctors()
check(doctors.title() == "Doctors", "all ok: " .. text(doctors.title()))
local items = doctors.menuItems()
check(#items == 6 and text(items[1].title):match("^LLM doctor") and text(items[2].title):match("^Harness doctor")
  and text(items[3].title):match("^Updater doctor"), "the three doctors in order")
check(text(items[3].title) == "Updater doctor: ok" and dimmed(items[3].title), "a clean Updater doctor: " .. text(items[3].title))
local pendingRow = { id = "cli-behind:codex", rule = "cli-behind", state = "watch",
  fact = "codex 0.159.0 → 0.159.2 waiting: busy since 00:14" }
write("/updater-doctor/latest.json", { contract = 1, doctor = "updater", as_of_s = now, status = "ok",
  problem_count = 0, problems = { pendingRow }, blind_spots = {}, vendors = {} })
local pending = doctors.menuItems()[3]
check(text(pending.title) == "Updater doctor: 1 update pending" and not dimmed(pending.title) and not red(pending.title),
  "a pending update is never a plain ok: " .. text(pending.title))
check(text(pending.menu[1].title) == pendingRow.fact and dimmed(pending.menu[1].title), "the pending update is a watch row")
pendingRow.state, pendingRow.fact = "new", pendingRow.fact .. " · 26h"
write("/updater-doctor/latest.json", { contract = 1, doctor = "updater", as_of_s = now, status = "problems",
  problem_count = 1, problems = { pendingRow }, blind_spots = {}, vendors = {} })
pending = doctors.menuItems()[3]
check(text(pending.title) == "Updater doctor: 1 problem" and red(pending.title) and red(pending.menu[1].title),
  "a pending update stuck past a day is red: " .. text(pending.title))
write("/updater-doctor/latest.json", { contract = 1, doctor = "updater", as_of_s = now, status = "ok",
  problem_count = 0, problems = {}, blind_spots = {}, vendors = {} })
check(text(fix(items[1].menu).title) == "Fix — open a fixer chat" and fix(items[1].menu).fn ~= nil, "LLM Fix button")
check(text(fix(items[2].menu).title) == "Fix — open a fixer chat", "Harness Fix button")
check(text(fix(items[3].menu).title) == "Fix — update and integrate all vendors", "Updater Fix button")
for index = 1, 3 do
  local item = items[index]
  check(text(fixer(item.menu).title) == "fixer: never ran" and fixer(item.menu).disabled and dimmed(fixer(item.menu).title),
    "no run record: " .. text(fixer(item.menu).title))
  check(text(refreshRow(item.menu).title) == "Refresh" and (item.menu[#item.menu - 3] or {}).title == "-",
    text(item.title) .. ": a separator, then Refresh, above Fix")
end
check(allMenlo(items), "every row under Doctors is Menlo 13")
check(text(items[2].menu[1].title) == "Waits  ok", "the Harness doctor's own rows come first")
local journal = io.open(dir .. "/harness-doctor/menu/" .. os.date("%Y-%m-%d") .. ".tsv")
local journalText = journal and journal:read("*a") or ""
if journal then journal:close() end
check(journalText:find("\tdoctors\n", 1, true) ~= nil, "the build is not timed into the menu journal")

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
check(text(broken.title) == "Harness doctor: failed to render" and red(broken.title)
  and broken.menu[2].title == "-" and text(fix(broken.menu).title) == "Fix — open a fixer chat",
  "a throwing builder keeps its Fix row")
limits.harnessDoctorEntry = harnessEntry

-- The Updater doctor's rows.
items = doctors.menuItems()
local up = items[3]
check(text(up.title) == "Updater doctor: 1 problem" and red(up.title), "Updater title: " .. text(up.title))
check(text(up.menu[1].title) == "codex 0.160.0 is out and not integrated" and red(up.menu[1].title), "a new problem is red")
check(text(up.menu[2].title) == "claude lists a model no leg uses" and dimmed(up.menu[2].title), "a watch problem is dim")
local codex = find(up.menu, "codex 0.159.0")
check(codex and text(codex.title) == "codex 0.159.0 · checked 3h ago · latest 0.160.0", "vendor row: "
  .. (codex and text(codex.title) or "missing"))
local claude = find(up.menu, "claude 2.4.1")
check(claude and text(claude.title) == "claude 2.4.1 · checked 3h ago", "an up-to-date vendor names no latest")
local sub = {}
for _, item in ipairs(codex and codex.menu or {}) do sub[#sub + 1] = item.title == "-" and "-" or text(item.title) end
check(table.concat(sub, "|") == "gpt-6-astra|gpt-6-mini|-|codex-0.159.0 · open · 0.158.0 → 0.159.0 · 2d ago"
  .. "|codex-0.158.0 · closed · 0.157.0 → 0.158.0 · 4d ago", "vendor submenu: " .. table.concat(sub, "|"))
check(codex and codex.menu[5].menu and text(codex.menu[5].menu[1].title) == "worker-pick table", "an event lists what it changed")
local spots = find(up.menu, "not measured: 1 blind spot")
check(spots and dimmed(spots.title) and #spots.menu == 1 and text(spots.menu[1].title) == "grok has no changelog to read"
  and text(spots.menu[1].menu[1].title) == "why: xAI publishes release notes only on X, which the doctor"
  and text(spots.menu[1].menu[#spots.menu[1].menu].title) == "would catch it: a feed",
  "blind spots sit one level down, each with its why")
local long = find(up.menu, "codex: 3 other")
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
check(widest(up.menu) <= 64 and widest(long and long.menu) <= 64, "an Updater row is wider than 64: " .. widest(up.menu))
local refresh = refreshRow(up.menu)
check(text(refresh.title) == "Refresh" and refresh.fn and (up.menu[#up.menu - 3] or {}).title == "-",
  "the Updater doctor has Refresh after a separator")
tasks = {}
refresh.fn()
check(#tasks == 1 and tasks[1].path == "/fixture/bin/updater-doctor" and #tasks[1].args == 0, "Refresh runs bin/updater-doctor")
check(text(refreshRow(doctors.menuItems()[3].menu).title) == "refreshing…", "a running Refresh")
tasks[1]:finish(0)
updater.as_of_s = now - 3 * 86400
write("/updater-doctor/latest.json", updater)
check(text(doctors.menuItems()[3].title) == "Updater doctor: 1 problem · stale 3d", "stale: " .. text(doctors.menuItems()[3].title))
updater.status, updater.problem_count, updater.as_of_s = "error", 0, now
updater.self = { collector_s = 1, error = "vendor-fingerprint: no such file" }
write("/updater-doctor/latest.json", updater)
up = doctors.menuItems()[3]
check(text(up.title) == "Updater doctor: collector failed" and text(up.menu[1].title) == "vendor-fingerprint: no such file"
  and red(up.menu[1].title), "a failed collector names its error")

-- A missing document.
remove("/updater-doctor/latest.json")
up = doctors.menuItems()[3]
check(text(up.title) == "Updater doctor: no data yet" and text(up.menu[1].title) == "no data yet"
  and up.menu[2].title == "-" and text(up.menu[3].title) == "Refresh" and #up.menu == 5, "missing file: " .. text(up.title))

-- The LLM and Harness blocks keep the same width: a long row is clipped, its text one level down.
local llmWide = llmDocument("ok", 0)
llmWide.not_measurable = { "worker false-green reports", "weakened tests", "the code revision a leg ran",
  "false-clean reviews" }
write("/llm-doctor/latest.json", llmWide)
write("/harness-doctor/menu.txt", "T\t1\t" .. now .. "\tHarness doctor: 1 problem\n"
  .. "0\td\t\tStop hooks: problem · end-of-turn checks held back over 2 h while a background task ran\n"
  .. "1\td\t\tstarted before 09-28 22:16 · cause unknown\n")
items = doctors.menuItems()
local measurable = find(items[1].menu, "not measurable yet")
check(measurable and text(measurable.title) == "not measurable yet: worker false-green reports, weakened…"
  and measurable.menu and not measurable.disabled, "a long LLM row: " .. (measurable and text(measurable.title) or "missing"))
local stop = items[2].menu[1]
local stopRows = {}
for _, item in ipairs(stop.menu or {}) do stopRows[#stopRows + 1] = item.title == "-" and "-" or text(item.title) end
check(text(stop.title) == "Stop hooks: problem · end-of-turn checks held back over 2 h…"
  and table.concat(stopRows, "|") == "Stop hooks: problem · end-of-turn checks held back over 2 h|"
  .. "while a background task ran|-|started before 09-28 22:16 · cause unknown", "a long Harness row keeps its own rows: "
  .. table.concat(stopRows, "|"))
for index = 1, 3 do check(widest(items[index].menu) <= 64, text(items[index].title) .. " has a row over 64") end
write("/llm-doctor/latest.json", llmDocument("ok", 0))

-- Fixer rows off the newest run record.
write("/doctors/runs/llm-20260101T000000Z.json", { doctor = "llm", launched_at = iso(now - 90 * 86400) })
write("/doctors/runs/llm-20260201T000000Z.json", { doctor = "llm", launched_at = iso(now - 3 * 86400),
  closed_at = iso(now - 2 * 86400), problems = { "a", "b", "c", "d" },
  decisions = { { id = "a", verdict = "fixed" }, { id = "b", verdict = "fixed" }, { id = "c", verdict = "handoff" },
    { id = "d", verdict = "fixed" }, { id = "judge", verdict = "judge-changed" } } })
write("/doctors/runs/harness-20260201T000000Z.json", { doctor = "harness", launched_at = iso(now - 2 * 3600 - 60) })
write("/doctors/runs/updater-20260201T000000Z.json", { doctor = "updater", launched_at = iso(now - 3 * 86400),
  abandoned_at = iso(now - 86400 - 60) })
items = doctors.menuItems()
check(text(fixer(items[1].menu).title) == "fixer: ran 2d ago · closed · 3 fixed · 1 handoff", "closed: " .. text(fixer(items[1].menu).title))
check(text(fix(items[1].menu).title) == "Fix — open a fixer chat" and fix(items[1].menu).fn, "a closed run leaves Fix on")
check(text(fixer(items[2].menu).title) == "fixer: running for 2h", "open: " .. text(fixer(items[2].menu).title))
check(text(fix(items[2].menu).title) == "Fix — fixer running for 2h" and fix(items[2].menu).disabled
  and not fix(items[2].menu).fn and dimmed(fix(items[2].menu).title), "Fix is off while a young run is open")
check(text(fixer(items[3].menu).title) == "fixer: abandoned 24h ago", "abandoned: " .. text(fixer(items[3].menu).title))
write("/doctors/runs/harness-20260201T000000Z.json", { doctor = "harness", launched_at = iso(now - 14 * 3600) })
items = doctors.menuItems()
check(text(fix(items[2].menu).title) == "Fix — open a fixer chat" and fix(items[2].menu).fn, "a run open 14 h no longer holds Fix")
check(text(fixer(items[2].menu).title) == "fixer: running for 14h", "old open run: " .. text(fixer(items[2].menu).title))

-- The Fix button's command line, its opening row and its alerts.
tasks, alerts = {}, {}
fix(items[3].menu).fn()
check(#tasks == 1 and tasks[1].path == "/fixture/bin/doctor-fix" and table.concat(tasks[1].args, " ") == "launch updater",
  "Fix runs bin/doctor-fix launch updater")
check(tasks[1] and tasks[1].env and tasks[1].env.HOME == os.getenv("HOME"), "the fix task lost HOME")
local opening = fix(doctors.menuItems()[3].menu)
check(text(opening.title) == "Fix — opening…" and opening.disabled, "a running launch reads opening")
fix(items[3].menu).fn()
check(#tasks == 1, "a second click launched a second fixer")
tasks[1]:finish(0, "starting\nopened fixer chat «Updater fix»\n")
check(alerts[1] == "opened fixer chat «Updater fix»", "the last output line: " .. tostring(alerts[1]))
check(text(fix(doctors.menuItems()[3].menu).title) == "Fix — update and integrate all vendors", "Fix is back after exit")
fix(doctors.menuItems()[1].menu).fn()
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
local failedRow = fixer(items[1].menu)
check(text(failedRow.title) == "fixer: failed 3h ago" and red(failedRow.title) and failedRow.menu
  and text(failedRow.menu[1].title) == "no account left to launch on", "failed run: " .. text(failedRow.title))
check(fix(items[1].menu).fn ~= nil, "a failed run leaves Fix on")

-- Night: bin/night-run latest --menu, a row under the doctors with a job per line, hidden while it
-- prints nothing; Run everything under it.
tasks = {}
doctors = loadDoctors()
items = doctors.menuItems()
local nightTask = tasks[1]
check(#items == 6 and nightTask and nightTask.path == "/fixture/bin/night-run"
  and table.concat(nightTask.args, " ") == "latest --menu", "the Night row reads bin/night-run latest --menu")
doctors.menuItems()
check(#tasks == 1, "a second build started a second night-run")
local quietTitle = text(doctors.title())
local reason = "deadline, branch night/x/codex (llm-legs 083450f): round 20260930T032123Z-43d191b confirmed 7 findings, unfixed"
nightTask:finish(0, "Last night 30 Sep: 1 of 3 done and pushed · 1 unfinished · 1 need you\t1\t0\n"
  .. "LLM fixer: health · done and pushed\t0\t\n"
  .. "codex update · unfinished · deadline\t0\t" .. reason .. "\n"
  .. "cleanup p1 · needs you · step 10 needs his word\t1\tstep 10 needs his word\n")
items = doctors.menuItems()
local nightRow = items[4]
check(#items == 7 and text(nightRow.title) == "Last night 30 Sep: 1 of 3 done and pushed · 1 unfinished · 1 need you"
  and red(nightRow.title) and not nightRow.disabled and allMenlo({ nightRow }),
  "a red night: " .. (nightRow and text(nightRow.title) or "missing"))
local jobs = nightRow.menu or {}
check(#jobs == 3 and text(jobs[1].title) == "LLM fixer: health · done and pushed" and dimmed(jobs[1].title) and jobs[1].disabled
  and text(jobs[2].title) == "codex update · unfinished · deadline" and dimmed(jobs[2].title) and jobs[2].menu
  and text(jobs[3].title) == "cleanup p1 · needs you · step 10 needs his word" and red(jobs[3].title),
  "a job per row, red only where Egor is needed")
local reasonRows = {}
for _, item in ipairs(jobs[2] and jobs[2].menu or {}) do reasonRows[#reasonRows + 1] = text(item.title) end
check(table.concat(reasonRows, " ") == reason and widest(jobs[2].menu) <= 64, "a job's whole reason one level down")
check(text(doctors.title()) == quietTitle, "the Night row changed the Doctors title")
doctors.refreshNight()
tasks[#tasks]:finish(0, "Last night 30 Sep: 4 of 4 done and pushed\t0\t0\n")
nightRow = doctors.menuItems()[4]
check(nightRow and text(nightRow.title) == "Last night 30 Sep: 4 of 4 done and pushed" and dimmed(nightRow.title)
  and nightRow.disabled, "a clean night with no job rows is dim")

-- Run everything: bin/night-run start behind a confirmation; off while a night runs.
items = doctors.menuItems()
local run = items[#items]
check(items[#items - 2].title == "-" and text(run.title) == "Run everything now (fixers · updates · cleanup)" and run.fn,
  "Run everything is the last Doctors item")
check(text(items[#items - 1].title) == "Cleanup now (land night branches · debt round)" and items[#items - 1].fn,
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
check(#doctors.menuItems() == 6, "an empty night-run hides the row")

-- Cleanup now: bin/night-run start --cleanup behind the same Cancel-first confirmation; off while a night runs.
doctors.refreshNight()
tasks[#tasks]:finish(0, "Last night 30 Sep: 4 of 4 done and pushed\t0\t0\tn-1\n")
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
tasks[#tasks]:finish(0, "Last night 30 Sep: 1 of 3 done and pushed · 2 unfinished\t0\t0\tn-1\n"
  .. "LLM fixer · done and pushed\t0\t\tllm-x\tfixer\t0\n"
  .. "codex update · unfinished · deadline\t0\t" .. reason .. "\tcodex-e1\tvendor\t1\n"
  .. "cleanup · unfinished · deadline\t0\t\tdebt\tdebt\t1\n")
tasks, dialogs, answer = {}, {}, "Continue"
jobs = doctors.menuItems()[4].menu
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
jobs = doctors.menuItems()[4].menu
jobs[#jobs].fn()
check(#tasks == 1 and table.concat(tasks[1].args, " ") == "start --resume n-1", "Continue unfinished resumes the whole night")
tasks[1]:finish(0, "night n-1 resumed\n")
doctors.menuItems()
tasks[#tasks]:finish(0, "Night run since 12:00: 1 in progress\t0\t1\tn-1\ncodex update · in progress\t0\t\tcodex-e1\tvendor\t0\n")
jobs = doctors.menuItems()[4].menu
check(#jobs == 1 and jobs[1].disabled, "a running night offers no Continue")

-- Known, quiet: an open ledger row no problem names is one dim row per doctor, the ids one level down.
local quietDoc = llmDocument("problems", 1)
quietDoc.problems = { { id = "M1", ledger = "M1", state = "open" }, { id = "ledger:M2", state = "new" } }
write("/llm-doctor/latest.json", quietDoc)
write("/llm-ledger.json", { rows = {
  { id = "M1", status = "open", title = "seen" }, { id = "M2", status = "open", title = "a faulty row" },
  { id = "V14", status = "open", title = "the judge ruled on fewer claims than it was given" },
  { id = "W1", status = "open", title = "a worker row" }, { id = "R3", status = "fixed", title = "done" } } })
write("/harness-doctor/latest.json", { contract = 1, doctor = "harness", as_of_s = now, status = "problems", problems = {} })
write("/harness-ledger.json", { rows = { { id = "suites-llm-legs-concurrent-load", status = "open" } } })
items = doctors.menuItems()
local quietLlm = items[1].menu[#items[1].menu - 2]
check(text(quietLlm.title) == "2 known, quiet" and dimmed(quietLlm.title) and #quietLlm.menu == 2
  and text(quietLlm.menu[1].title) == "V14 · the judge ruled on fewer claims than it was given"
  and text(quietLlm.menu[2].title) == "W1 · a worker row", "the LLM doctor's quiet rows: " .. text(quietLlm.title))
local quietHarness = items[2].menu[#items[2].menu - 2]
check(text(quietHarness.title) == "1 known, quiet" and text(quietHarness.menu[1].title) == "suites-llm-legs-concurrent-load",
  "the Harness doctor's quiet row: " .. text(quietHarness.title))
check(text(items[3].menu[#items[3].menu - 2].title) == "Refresh", "no ledger rows, no quiet row")
quietDoc.status = "error"
write("/llm-doctor/latest.json", quietDoc)
items = doctors.menuItems()
check(not text(items[1].menu[#items[1].menu - 2].title):find("known, quiet", 1, true), "a failed collector hides nothing as quiet")

os.execute("rm -rf '" .. dir .. "'")
if #failures > 0 then return "FAIL: " .. table.concat(failures, "; ") end
return "PASS: " .. checks .. " doctors menu checks"
