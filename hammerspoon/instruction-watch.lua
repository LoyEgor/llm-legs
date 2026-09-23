-- Egor's end of the instruction-file tripwire.
--
-- `bin/instruction-watch.sh` detects a change to a file an LLM re-reads across sessions and writes
-- one JSON record per change into `events.jsonl`. It does NOT render anything: a hook that runs
-- after every Bash call cannot wait on a wedged Hammerspoon, and the six-second `hs.alert` it used
-- to fire straight from there was gone the moment it faded and lost outright whenever Hammerspoon
-- happened not to be running. This module owns the rendering half — the alert, the menu history
-- under Automations, and the receipt that says which of the two actually happened.
--
-- Three states, and the difference between them is the whole point:
--   sent=attempted  the hook MADE the delivery call. It is not a claim that anything ran.
--   receipt         this module read the record and decided what to do with it. Proof the other
--                   end woke up, nothing more.
--   receipt.alerted an alert was put on screen. Still not a claim that Egor SAW it — no marker in
--                   this design can say that, and none of them may be read as saying it.
-- Delivery does not depend on the hook's `hs` call landing: a watcher on the journal's directory,
-- a catch-up pump at load and a slow fallback timer all reach the same idempotent pump, so a
-- change written while Hammerspoon was down is delivered when it comes back rather than lost.

local M = {}
local CHARS_PER_TOKEN = 3.2
local FILE_WIDTH = 32
local TOP_FILES = 10
local MODES = { always_on = "always", on_demand = "demand", agent_brief = "brief" }
local ROOT = debug.getinfo(1, "S").source:match("^@(.+)/hammerspoon/instruction%-watch%.lua$")
local DEFAULT_RATES = (os.getenv("HOME") or "") .. "/.local/share/tokenmap/read-rates.json"
local ratesPath, ratesStamp, ratesCache = DEFAULT_RATES, nil, nil
local menuFont = { name = "Menlo", size = 13 }
local dimColorName = { list = "System", name = "tertiaryLabelColor" }
local pasteboardFn = function(text) hs.pasteboard.setContents(text) end
local function runOpenCommand(sid, onDone)
    if not ROOT then
        onDone(1, "", "instruction-watch: repository root unresolved")
        return
    end
    local task
    -- Break the callback/task cycle so completed tasks can be collected.
    task = hs.task.new(ROOT .. "/bin/chats", function(code, stdout, stderr)
        task = nil
        onDone(code, stdout, stderr)
    end, { "--open-command", sid, "--timeout", "1" })
    if not task or not task:start() then
        task = nil
        onDone(1, "", "could not start chats")
    end
end
local openCommandFn = runOpenCommand

local DEFAULT_STATE = os.getenv("INSTRUCTION_WATCH_STATE")
    or ((os.getenv("HOME") or "") .. "/.cache/claude-instruction-watch")
local JOURNAL_TAIL = 200    -- records kept in memory; the writer trims the file to the same order
local MENU_ROWS = 12
local ALERT_BURST = 3       -- alerts one pump may put on screen before it collapses the rest
local ALERT_MAX_AGE = 6 * 3600

local stateDir = DEFAULT_STATE
local watcher = nil
local timer = nil
local lastSeen = nil        -- journal size+mtime, so a write anywhere else in the dir costs a stat
local ensureWatcher, onChange, resolveChatNames, watchStart, watchTick

local alertFn = function(text, duration)
    hs.alert.show(text, duration or 6)
end

local function journalPath() return stateDir .. "/events.jsonl" end
local function receiptPath(id) return stateDir .. "/receipts/" .. id end
local function rankedPath() return stateDir .. "/ranked.txt" end

local function readFile(path)
    local handle = io.open(path, "r")
    if not handle then return nil end
    local body = handle:read("*a")
    handle:close()
    return body
end

local function writeFile(path, body)
    local handle = io.open(path, "w")
    if not handle then return false end
    handle:write(body)
    handle:close()
    return true
end

-- The stamps in the journal are UTC and `os.time` reads its table as local, so the correction is
-- the distance between what this machine calls that wall clock and the same instant in UTC.
local function parseIso(value)
    local y, mo, d, h, mi, s = tostring(value or "")
        :match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
    if not y then return nil end
    local stamp = os.time({
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(s), isdst = false,
    })
    if not stamp then return nil end
    return stamp + os.difftime(stamp, os.time(os.date("!*t", stamp)))
end

-- Oldest first, capped at the tail. A record this cannot decode is dropped rather than thrown:
-- the journal is appended to by a shell hook running in every live session, and one torn line may
-- not cost Egor the twelve good ones under it.
local function readJournal()
    local body = readFile(journalPath())
    if not body then return {}, {} end
    local events, count = {}, 0
    for line in body:gmatch("[^\n]+") do
        local ok, decoded = pcall(hs.json.decode, line)
        if ok and type(decoded) == "table" and type(decoded.id) == "string" then
            count = count + 1
            events[count] = decoded
        end
    end
    if count > JOURNAL_TAIL then
        local trimmed = {}
        for i = count - JOURNAL_TAIL + 1, count do
            trimmed[#trimmed + 1] = events[i]
        end
        return trimmed, events
    end
    return events, events
end

local function receiptFor(id)
    local body = readFile(receiptPath(id))
    if not body then return nil end
    local ok, decoded = pcall(hs.json.decode, body)
    if ok and type(decoded) == "table" then return decoded end
    return { at = "?" }
end

local function ensureReceiptDir()
    if hs.fs.attributes(stateDir, "mode") ~= "directory" then return false end
    local dir = stateDir .. "/receipts"
    if hs.fs.attributes(dir, "mode") == "directory" then return true end
    return hs.fs.mkdir(dir) and true or false
end

local function shortPath(path)
    local parent, base = tostring(path or ""):match("([^/]+)/([^/]+)$")
    if parent and base then return parent .. "/" .. base end
    return path
end

local function shortSummary(event)
    local summary = tostring(event.summary or "")
    if summary == "" and event.kind == "dropped" then
        summary = tostring(event.count or "?") .. " changes dropped"
    end
    if summary == "" then summary = "instruction file changed" end
    -- The absolute path is what the record holds and what the detail rows show; a menu row that
    -- spends forty characters on `/Users/egorloy/` says less, not more. The PARENT stays, though —
    -- half these files are called CLAUDE.md, and a row naming six of them said nothing at all.
    -- `[^%s]` split a path at a space and left a broken prefix; replace the recorded files first.
    local files = event.files
    if type(files) == "table" and #files > 0 then
        for _, file in ipairs(files) do
            if type(file) == "string" and file ~= "" then
                local plain = file:gsub("(%W)", "%%%1")
                summary = summary:gsub(plain, (shortPath(file):gsub("%%", "%%%%")), 1)
            end
        end
    else
        summary = summary:gsub("(/[^;(]+)", function(path)
            local rest = ""
            local arrow = path:find(" %->", 1, true)
            if arrow then
                rest = path:sub(arrow)
                path = path:sub(1, arrow - 1)
            end
            path = path:gsub(" +$", "")
            return shortPath(path) .. rest
        end)
    end
    summary = summary:gsub("%s+", " ")
    return summary
end

-- Idempotent, and safe to call from the watcher, the timer, the hook's poke and a menu click at
-- once: the receipt is what decides, and a record that has one is never delivered twice.
function M.pump()
    ensureWatcher()
    watchStart()
    watchTick()
    local result = { delivered = 0, alerted = 0, stale = 0 }
    local events = readJournal()
    if #events == 0 then return result end
    if not ensureReceiptDir() then return result end
    pcall(resolveChatNames, events)
    local now = os.time()
    local pending = {}
    for _, event in ipairs(events) do
        if not receiptFor(event.id) then pending[#pending + 1] = event end
    end
    local freshTotal = 0
    for _, event in ipairs(pending) do
        local stamp = parseIso(event.at)
        if (stamp == nil) or (now - stamp <= ALERT_MAX_AGE) then
            freshTotal = freshTotal + 1
        end
    end
    local freshIndex = 0
    for _, event in ipairs(pending) do
        local stamp = parseIso(event.at)
        -- Two bounds, both of them there so a Hammerspoon that was off for a day does not open
        -- with a wall of alerts: anything older than the window lands in the menu unannounced,
        -- and a burst past the third FRESH record collapses into one line pointing at the menu.
        -- Stale records used to consume the cap, so a fresh change behind three of them was
        -- receipted collapsed and never shown.
        local fresh = (stamp == nil) or (now - stamp <= ALERT_MAX_AGE)
        local alerted = false
        if fresh then
            freshIndex = freshIndex + 1
            if freshIndex <= ALERT_BURST then
                local ok = pcall(alertFn, "Instruction file changed: " .. shortSummary(event))
                alerted = ok
            elseif freshIndex == ALERT_BURST + 1 then
                local rest = freshTotal - ALERT_BURST
                pcall(alertFn, rest .. " more instruction changes — see Automations ▸ Instruction files")
            end
        end
        local reason = "delivered"
        if not fresh then
            reason = "stale"
            result.stale = result.stale + 1
        elseif not alerted then
            reason = "collapsed"
        end
        local receipt = hs.json.encode({
            at = os.date("!%Y-%m-%dT%H:%M:%SZ", now),
            alerted = alerted,
            reason = reason,
        })
        if writeFile(receiptPath(event.id), receipt) then
            result.delivered = result.delivered + 1
            if alerted then result.alerted = result.alerted + 1 end
        end
    end
    return result
end

-- What the watch set reaches beyond `~/.claude`, read from the cache the hook cuts at session
-- start. Shown because coverage nobody can look at is coverage nobody trusts.
function M.rankedPaths()
    local body = readFile(rankedPath())
    if not body then return {} end
    local paths = {}
    for line in body:gmatch("[^\n]+") do
        -- The cache's first line is the `#<version>` stamp that tells the writer when its own
        -- rules have moved. It is not a watched path and has no business in a coverage list.
        if line ~= "" and line:sub(1, 1) ~= "#" then paths[#paths + 1] = line end
    end
    return paths
end

local function rates()
    local attrs = hs.fs.attributes(ratesPath)
    local stamp = attrs and (tostring(attrs.size) .. "/" .. tostring(attrs.modification)) or "missing"
    if ratesCache and stamp == ratesStamp then return ratesCache end
    local ok, decoded = pcall(hs.json.decode, readFile(ratesPath) or "{}")
    local entries = ok and type(decoded) == "table" and type(decoded.paths) == "table"
        and type(decoded.paths.entries) == "table" and decoded.paths.entries or {}
    local paths, ranks = {}, {}
    for path, entry in pairs(entries) do
        if type(entry) == "table" then paths[#paths + 1] = path end
    end
    local function reads(path)
        local weekly = entries[path].weekly
        return type(weekly) == "table" and tonumber(weekly.reads) or 0
    end
    table.sort(paths, function(a, b)
        local ar, br = reads(a) or 0, reads(b) or 0
        if ar == br then return a < b end
        return ar > br
    end)
    for rank, path in ipairs(paths) do ranks[path] = rank end
    local top, measured = {}, false
    local function readTokens(path)
        local weekly = entries[path].weekly
        return type(weekly) == "table" and tonumber(weekly.read_tokens) or nil
    end
    for _, path in ipairs(paths) do
        local tokens = readTokens(path)
        if tokens then measured = true end
        local markdown = path:sub(-3) == ".md" or path:sub(-9) == ".markdown"
        if tokens and tokens > 0 and markdown then top[#top + 1] = path end
    end
    table.sort(top, function(a, b)
        local at, bt = readTokens(a), readTokens(b)
        if at == bt then return a < b end
        return at > bt
    end)
    for index = #top, TOP_FILES + 1, -1 do top[index] = nil end
    ratesCache, ratesStamp = { entries = entries, ranks = ranks, top = top, measured = measured }, stamp
    return ratesCache
end

-- Records written before `bytes` existed carry the delta only inside the summary text
-- (`CHANGED <path> (+184 bytes)`); a REVERTED report there names growth already put back.
-- Anchored on the verb: `/a/path/x.md` is a suffix of `/sub/a/path/x.md`, and only the verb
-- and its space in front say which record a delta belongs to.
local function segment(summary, file)
    local plain = file:gsub("(%W)", "%%%1")
    local verb, delta = summary:match("([%u%-]+) " .. plain .. " %(([%+%-]%d+) bytes%)")
    if not verb then verb = summary:match("([%u%-]+) " .. plain .. "%f[^%w/%.%-_]") or summary:match("([%u%-]+) " .. plain .. "$") end
    return verb, delta
end

local function verbs(event)
    local summary, out = tostring(event.summary or ""), {}
    for index, file in ipairs(event.files or {}) do
        if type(file) == "string" then
            local verb = segment(summary, file)
            if verb then out[index] = verb:lower() end
        end
    end
    return out
end

local function deltasFromSummary(event)
    local summary, out = tostring(event.summary or ""), {}
    for index, file in ipairs(event.files or {}) do
        if type(file) == "string" then
            local verb, delta = segment(summary, file)
            if verb == "REVERTED" then out[index] = 0
            elseif delta then out[index] = tonumber(delta) end
        end
    end
    return out
end

local function deltas(event)
    if type(event.bytes) ~= "table" or #event.bytes ~= #(event.files or {}) then
        return deltasFromSummary(event)
    end
    for key, value in pairs(event.bytes) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #event.bytes
            or type(value) ~= "number" or value % 1 ~= 0 then return deltasFromSummary(event) end
    end
    return event.bytes
end

-- Records written before the hook stored `chat` are named here through the same resolver,
-- `chat-name`, one call per pump for every unnamed sid on show; the answers persist beside the
-- receipts so a restart does not ask again. An id the resolver cannot name is retried hourly:
-- a chat gains its title after its first turn, which is often after its first edit.
local CHAT_RETRY = 3600
local chatNames, chatPending, chatRerun = nil, false, false
local function chatCachePath() return stateDir .. "/chat-names.json" end
local function loadChatNames()
    if chatNames then return chatNames end
    local ok, decoded = pcall(hs.json.decode, readFile(chatCachePath()) or "{}")
    chatNames = ok and type(decoded) == "table" and decoded or {}
    return chatNames
end
local function resolverPath()
    local own = ROOT and (ROOT .. "/bin/chat-name")
    if own and hs.fs.attributes(own, "mode") == "file" then return own end
    return (os.getenv("HOME") or "") .. "/.local/bin/chat-name"
end
local function runChatResolver(sids, onDone)
    local task
    task = hs.task.new(resolverPath(), function(_, stdout)
        task = nil
        onDone(stdout or "")
    end, sids)
    if not task or not task:start() then
        task = nil
        onDone("")
    end
end
local chatResolverFn = runChatResolver
resolveChatNames = function(events)
    if chatPending then chatRerun = true; return end
    local names, now, ask, asked = loadChatNames(), os.time(), {}, {}
    for index = #events, math.max(1, #events - MENU_ROWS + 1), -1 do
        local event = events[index]
        local sid = type(event.sid) == "string" and event.sid or ""
        local known = type(event.chat) == "string" and event.chat ~= ""
        local row = names[sid]
        local stale = type(row) ~= "table" or (row.name == "" and now - (tonumber(row.at) or 0) > CHAT_RETRY)
        if sid ~= "" and not known and stale and not asked[sid] then
            asked[sid] = true
            ask[#ask + 1] = sid
        end
    end
    if #ask == 0 then return end
    chatPending = true
    chatResolverFn(ask, function(stdout)
        chatPending = false
        local found = {}
        for line in stdout:gmatch("[^\r\n]+") do
            local name, short = line:match("^(.-) %((%x+)%)$")
            if name and short then found[short] = line end
        end
        -- The resolver answers by short id, so two asked ids sharing one are left unnamed rather
        -- than both handed whichever chat answered first.
        local shared = {}
        for _, sid in ipairs(ask) do shared[sid:sub(1, 8)] = (shared[sid:sub(1, 8)] or 0) + 1 end
        for _, sid in ipairs(ask) do
            local short = sid:sub(1, 8)
            names[sid] = { name = shared[short] == 1 and found[short] or "", at = now }
        end
        writeFile(chatCachePath(), hs.json.encode(names))
        if chatRerun then
            chatRerun = false
            resolveChatNames(readJournal())
        end
    end)
end
local function chatLabel(event)
    if event.source == "watcher" and (type(event.chat) ~= "string" or event.chat == "") then
        return "writer: " .. tostring(event.writer or "unknown")
    end
    if type(event.chat) == "string" and event.chat ~= "" then return event.chat end
    local sid = type(event.sid) == "string" and event.sid or ""
    local row = loadChatNames()[sid]
    if type(row) == "table" and row.name ~= "" then return row.name end
    return "unnamed chat (" .. (sid ~= "" and sid:sub(1, 8) or "?") .. ")"
end

-- The file watcher. `hash_of` and `watch_mark_key` are eval'ed out of bin/instruction-watch.sh on
-- every call, never re-spelled here: the tripwire and this watcher must derive the same marker for
-- one write, or both alert for it.
local WATCH_TICK = 120
-- The hooks run under a session's `env bash`; Hammerspoon's bare PATH would pick /bin/bash 3.2.
local WATCH_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin"
local WATCH_SCRIPT = [==[
set -u
root=$1 home=$2 state=$3 mode=$4
shift 4
. "$root/share/instruction-files.sh" 2>/dev/null || exit 2
command -v jq >/dev/null 2>&1 || exit 2
for f in hash_of shq snap_key keep_revert watch_mark_key clear_gone_marks release_marks; do
  eval "$(sed -n '/^'"$f"'() {/,/^}/p' "$root/bin/instruction-watch.sh")"
  declare -F "$f" >/dev/null || exit 3
done
SNAP_DIR=$state/snapshot REVERT_DIR=$state/reverts SNAP_MAX_BYTES=1048576 ALERT_DIR=$state/alerts
case $mode in
  list) instruction_visible_paths "$home" "$state/ranked.txt" '' ;;
  repo) for r; do instruction_repo_files "$r"; done ;;
  hash)
    [ $# -gt 0 ] || exit 0
    stat -L -f '%N%t%Fm%t%z%t%i' -- "$@" 2>/dev/null
    printf '\035\n'
    plain=()
    for p; do
      [ -f "$p" ] || continue
      case "$p" in
        */settings.json) printf '%s\t%s\n' "$(hash_of "$p" "$p")" "$p" ;;
        *) plain+=("$p") ;;
      esac
    done
    [ ${#plain[@]} -eq 0 ] ||
      shasum -a 256 -- "${plain[@]}" 2>/dev/null | awk '{ print substr($0, 1, 64) "\t" substr($0, 67) }' ;;
  claim)
    while [ $# -ge 3 ]; do
      [ "$3" = 1 ] && clear_gone_marks "$1"
      key=$(watch_mark_key "$1" "$2")
      if instruction_mark_once "$ALERT_DIR" "$key"; then printf '%s\n' "$key"; else printf -- '-\n'; fi
      shift 3
    done ;;
  release) release_marks "$@" ;;
  append) INSTRUCTION_WATCH_STATE=$state instruction_journal_append "$1" || exit 1 ;;
  restore)
    while [ $# -ge 6 ]; do
      vis=$1 real=$2 was=$3 now=$4 offer=$5 keep=$6
      shift 6
      line=''
      if [ "$offer" = 1 ] && [ -n "$was" ] && kept=$(keep_revert "$vis" "$real" "$was"); then
        line="cp $(shq "$kept") $(shq "$real")"
      fi
      dst=$SNAP_DIR/$(snap_key "$vis")-$now
      size=$(stat -f %z "$real" 2>/dev/null) || size=''
      if [ "$keep" = 1 ] && [ -n "$now" ] && [ -n "$size" ] && [ ! -e "$dst" ] &&
         [ "$size" -le "$SNAP_MAX_BYTES" ] && mkdir -p "$SNAP_DIR" && cp "$real" "$dst.$$" 2>/dev/null; then
        if [ "$(hash_of "$dst.$$" "$vis")" = "$now" ]; then mv "$dst.$$" "$dst"; else rm -f "$dst.$$"; fi
      fi
      printf '%s\n' "$line"
    done ;;
esac
exit 0
]==]

local W = nil
local watchWanted = false
local homeOverride = nil
local function homeDir() return homeOverride or os.getenv("HOME") or "" end
local function watchDir() return stateDir .. "/watcher" end
local function snapshotPath() return watchDir() .. "/snapshot.tsv" end
local function heartbeatPath() return watchDir() .. "/heartbeat" end
local function isoNow() return os.date("!%Y-%m-%dT%H:%M:%SZ") end

local function shellQuote(value)
    return "'" .. (tostring(value):gsub("'", "'\\''")) .. "'"
end

local function runScan(mode, args)
    if not ROOT then return nil, "repository root unresolved" end
    local parts = { "PATH=" .. WATCH_PATH .. ":$PATH; export PATH; exec bash -c", shellQuote(WATCH_SCRIPT),
        "instruction-watcher", shellQuote(ROOT), shellQuote(homeDir()), shellQuote(stateDir), mode }
    for _, arg in ipairs(args or {}) do parts[#parts + 1] = shellQuote(arg) end
    local handle = io.popen(table.concat(parts, " ") .. " 2>/dev/null")
    if not handle then return nil, "cannot start bash" end
    local out = handle:read("*a")
    local ok, _, code = handle:close()
    if not ok then return nil, "scan " .. mode .. " exited " .. tostring(code) end
    return out
end

local function outputLines(out)
    local lines = {}
    for line in (out or ""):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    return lines
end

local function realOf(path)
    local ok, resolved = pcall(hs.fs.pathToAbsolute, path)
    if ok and type(resolved) == "string" then return resolved end
    local dir, base = tostring(path):match("^(.*)/([^/]+)$")
    if dir then
        local okDir, parent = pcall(hs.fs.pathToAbsolute, dir ~= "" and dir or "/")
        if okDir and type(parent) == "string" then return parent .. "/" .. base end
    end
    return path
end

local function fingerprint(path)
    local attrs = hs.fs.attributes(path)
    if not attrs then return nil end
    return tostring(attrs.size) .. "/" .. tostring(attrs.modification) .. "/" .. tostring(attrs.ino)
end

local function hashPaths(paths)
    local result = {}
    if #paths == 0 then return result end
    local out, err = runScan("hash", paths)
    if not out then return nil, err end
    local stats, second = {}, false
    for _, line in ipairs(outputLines(out)) do
        if line == "\029" then
            second = true
        elseif not second then
            local path, mtime, size, ino = line:match("^(.-)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
            if path then stats[path] = { mtime = mtime, size = tonumber(size), ino = ino } end
        else
            local hash, path = line:match("^(%x+)\t(.+)$")
            if hash and stats[path] then stats[path].hash = hash end
        end
    end
    for _, path in ipairs(paths) do
        local row = stats[path]
        if row and row.hash and row.size then
            row.real, row.fp = realOf(path), fingerprint(path)
            result[path] = row
        end
    end
    return result
end

local function readSnapshot()
    local body = readFile(snapshotPath())
    if not body then return nil end
    local rows = {}
    for line in body:gmatch("[^\n]+") do
        local vis, hash, size, mtime, trust, real = line:match("^([^\t]+)\t(%x+)\t(%d+)\t([^\t]*)\t([01])\t?([^\t]*)$")
        if vis then
            rows[vis] = { hash = hash, size = tonumber(size), mtime = mtime, trust = trust == "1",
                          real = real ~= "" and real or nil }
        end
    end
    return rows
end

local function writeSnapshot()
    local paths = {}
    for path in pairs(W.prev) do paths[#paths + 1] = path end
    table.sort(paths)
    local lines = {}
    for _, path in ipairs(paths) do
        local row = W.prev[path]
        lines[#lines + 1] = table.concat({ path, row.hash, tostring(row.size), row.mtime or "",
            row.trust and "1" or "0", row.real or "" }, "\t")
    end
    hs.fs.mkdir(watchDir())
    local tmp = snapshotPath() .. ".tmp"
    if writeFile(tmp, table.concat(lines, "\n") .. "\n") then os.rename(tmp, snapshotPath()) end
    W.dirty = false
end

local function writeHeartbeat()
    local roots, files = 0, 0
    for _ in pairs(W.watchers) do roots = roots + 1 end
    for _ in pairs(W.prev) do files = files + 1 end
    hs.fs.mkdir(watchDir())
    writeFile(heartbeatPath(), string.format("since=%d roots=%d files=%d%s\n", W.since, roots, files,
        W.error and (" error=" .. W.error) or ""))
end

local function refreshInflight()
    local dir, present, now = stateDir .. "/inflight", {}, os.time()
    if hs.fs.attributes(dir, "mode") == "directory" then
        for name in hs.fs.dir(dir) do
            if name ~= "." and name ~= ".." then
                local epoch, callId = (readFile(dir .. "/" .. name) or ""):match("^(%d+%.?%d*)%s+(%S+)")
                if epoch then
                    local key = name .. "|" .. callId
                    present[key] = true
                    W.inflight[key] = W.inflight[key] or { sid = name:match("^(.-)@") or name, start = tonumber(epoch) }
                end
            end
        end
    end
    for key, row in pairs(W.inflight) do
        if not present[key] and not row.ended then row.ended = now end
        if row.ended and now - row.ended > 600 then W.inflight[key] = nil end
    end
end

-- A second of slack both ways: the write's mtime is floored to whole seconds here.
local function writersAt(stamps)
    local sids, seen, now = {}, {}, os.time()
    for _, row in pairs(W.inflight) do
        for _, stamp in ipairs(stamps) do
            if not seen[row.sid] and stamp >= row.start - 1 and stamp <= (row.ended or now) + 1 then
                seen[row.sid] = true
                sids[#sids + 1] = row.sid
            end
        end
    end
    table.sort(sids)
    return sids
end

local function journalAppend(line)
    return runScan("append", { line }) ~= nil
end

local function watchEmit(entries, kind)
    if #entries == 0 then return end
    local args = {}
    for _, entry in ipairs(entries) do
        for _, value in ipairs({ entry.vis, entry.content, entry.verb == "ADDED" and "1" or "0" }) do
            args[#args + 1] = value
        end
    end
    local keys, claimed = outputLines(runScan("claim", args)), {}
    for index, entry in ipairs(entries) do
        if (keys[index] or ""):match("^%x+$") then
            entry.key = keys[index]
            claimed[#claimed + 1] = entry
        end
    end
    local restoreArgs = {}
    for _, entry in ipairs(entries) do
        local old, cur = entry.old or {}, entry.cur or {}
        local offer = entry.key ~= nil and old.trust and entry.verb ~= "ADDED"
        for _, value in ipairs({ entry.vis, cur.real or old.real or realOf(entry.vis), old.hash or "",
            cur.hash or "", offer and "1" or "0", (cur.trust and cur.hash) and "1" or "0" }) do
            restoreArgs[#restoreArgs + 1] = value
        end
    end
    local restores = outputLines(runScan("restore", restoreArgs))
    if #claimed == 0 then return end
    local record = { id = string.format("%08x%08x", os.time() % 0x100000000, math.random(0, 0x7fffffff)),
        at = isoNow(), sid = "", kind = kind, sent = "attempted", source = "watcher", writer = "unknown",
        files = {}, bytes = {}, restores = {}, reverted = {} }
    local summaries, stamps = {}, {}
    for index, entry in ipairs(entries) do
        if entry.key then
            record.files[#record.files + 1] = entry.vis
            record.bytes[#record.bytes + 1] = entry.delta
            summaries[#summaries + 1] = entry.summary
            if (restores[index] or "") ~= "" then record.restores[#record.restores + 1] = restores[index] end
            stamps[#stamps + 1] = math.floor(tonumber(entry.cur and entry.cur.mtime or "") or os.time())
        end
    end
    record.summary = table.concat(summaries, "; ")
    local function finish()
        if not journalAppend(hs.json.encode(record)) then
            local keys = {}
            for _, entry in ipairs(claimed) do
                keys[#keys + 1] = entry.key
                if W then W.prev[entry.vis] = entry.old; W.dirty = true end
            end
            runScan("release", keys)
            return
        end
        M.pump()
    end
    local sids = kind == "change" and writersAt(stamps) or {}
    if #sids == 0 then return finish() end
    record.sid = sids[1]
    chatResolverFn(sids, function(stdout)
        local found = {}
        for line in (stdout or ""):gmatch("[^\r\n]+") do
            local short = line:match("^.- %((%x+)%)$")
            if short then found[short] = line end
        end
        local labels = {}
        for _, sid in ipairs(sids) do
            labels[#labels + 1] = found[sid:sub(1, 8)] or ("unnamed chat (" .. sid:sub(1, 8) .. ")")
        end
        record.writer = table.concat(labels, ", ")
        if found[sids[1]:sub(1, 8)] then record.chat = found[sids[1]:sub(1, 8)] end
        finish()
    end)
end

local function describeChange(verb, suffix, vis, delta)
    if verb == "CHANGED" then
        return string.format("CHANGED%s %s (%s%d bytes)", suffix, vis, delta >= 0 and "+" or "", delta)
    end
    return verb .. suffix .. " " .. vis
end

-- A path the set newly names was either created since the last listing (ADDED) or was always there
-- and only just ranked, which nobody wrote and nothing reports.
local function bornSince(path, stamp)
    local attrs = hs.fs.attributes(path)
    local born = attrs and (attrs.creation or attrs.modification)
    return born ~= nil and stamp ~= nil and born >= stamp - 1
end

local function watchCheck(paths, forceHash, suffix, kind, addedSince)
    local toHash, entries = {}, {}
    for _, path in ipairs(paths) do
        local old = W.prev[path]
        if not hs.fs.attributes(path) then
            if old then
                entries[#entries + 1] = { verb = "DELETED", vis = path, old = old, content = "absent",
                    delta = -(old.size or 0) }
            end
        elseif forceHash or not old or fingerprint(path) ~= old.fp then
            toHash[#toHash + 1] = path
        end
    end
    local fresh, err = hashPaths(toHash)
    if not fresh then W.error = err; return end
    W.error = nil
    for _, path in ipairs(toHash) do
        local old, cur = W.prev[path], fresh[path]
        if cur == nil then
            if old and not hs.fs.attributes(path) then
                entries[#entries + 1] = { verb = "DELETED", vis = path, old = old, content = "absent",
                    delta = -(old.size or 0) }
            end
        elseif old == nil then
            local added = bornSince(path, addedSince)
            cur.trust = not added
            W.prev[path], W.dirty = cur, true
            if added then
                entries[#entries + 1] = { verb = "ADDED", vis = path, cur = cur,
                    content = cur.hash .. "@" .. cur.mtime, delta = cur.size }
            end
        elseif cur.hash ~= old.hash then
            cur.trust = old.trust
            W.prev[path], W.dirty = cur, true
            entries[#entries + 1] = { verb = "CHANGED", vis = path, old = old, cur = cur,
                content = cur.hash .. "@" .. cur.mtime, delta = cur.size - (old.size or 0) }
        else
            cur.trust = old.trust
            W.prev[path], W.dirty = cur, true
        end
    end
    for _, entry in ipairs(entries) do
        if entry.verb == "DELETED" then W.prev[entry.vis], W.dirty = nil, true end
        entry.summary = describeChange(entry.verb, suffix, entry.vis, entry.delta)
    end
    watchEmit(entries, kind)
end

local function watchPaths()
    local paths, seen = {}, {}
    for _, path in ipairs(W.list) do seen[path] = true; paths[#paths + 1] = path end
    for path in pairs(W.prev) do
        if not seen[path] then seen[path] = true; paths[#paths + 1] = path end
    end
    return paths
end

local function under(path, dir) return path == dir or path:sub(1, #dir + 1) == dir .. "/" end

local function watchRefresh()
    local out, err = runScan("list")
    if not out then W.error = err; return false end
    local list, seen, seenReal = {}, {}, {}
    local function add(path)
        if path == "" or seen[path] then return end
        local real = realOf(path)
        if seenReal[real] then return end
        seen[path], seenReal[real] = true, true
        list[#list + 1] = path
    end
    for _, line in ipairs(outputLines(out)) do add(line) end
    local claudeDir = homeDir() .. "/.claude"
    local repoRoots, repos = {}, {}
    for _, path in ipairs(list) do
        if not under(path, claudeDir) then
            local root = path:match("^(.-)/%.claude/")
            local base = (path:match("[^/]+$") or ""):lower()
            if not root and (base == "claude.md" or base == "claude.local.md" or base == "skill.md") then
                root = path:match("^(.*)/[^/]+$")
            end
            if root and root ~= "" and not repoRoots[root] then
                repoRoots[root] = true
                repos[#repos + 1] = root
            end
        end
    end
    if #repos > 0 then
        for _, line in ipairs(outputLines(runScan("repo", repos))) do add(line) end
    end
    local candidates = { realOf(claudeDir) }
    for _, root in ipairs(repos) do candidates[#candidates + 1] = realOf(root) end
    -- ~/.claude's class directories are symlinks into another repository, and FSEvents reports a
    -- write at the target, so a file reached through a link is watched at the link's target.
    for _, path in ipairs(list) do
        local real, covered = realOf(path), false
        for _, root in ipairs(candidates) do if under(real, root) then covered = true; break end end
        if not covered then
            local top = under(path, claudeDir) and path:sub(#claudeDir + 2):match("^[^/]+")
            local linked = top and realOf(claudeDir .. "/" .. top)
            if linked and hs.fs.attributes(linked, "mode") == "directory" and under(real, linked) then
                candidates[#candidates + 1] = linked
            else
                candidates[#candidates + 1] = real:match("^(.*)/[^/]+$")
            end
        end
    end
    table.sort(candidates, function(a, b) return #a < #b end)
    local roots = {}
    for _, candidate in ipairs(candidates) do
        local nested = false
        for _, kept in ipairs(roots) do if under(candidate, kept) then nested = true; break end end
        if not nested and hs.fs.attributes(candidate, "mode") == "directory" then roots[#roots + 1] = candidate end
    end
    local wanted = {}
    for _, root in ipairs(roots) do
        wanted[root] = true
        if not W.watchers[root] then
            local ok, watcherObj = pcall(hs.pathwatcher.new, root, function(paths) M.watchEvent(paths) end)
            if ok and watcherObj then
                watcherObj:start()
                W.watchers[root] = watcherObj
            end
        end
    end
    for root, watcherObj in pairs(W.watchers) do
        if not wanted[root] then watcherObj:stop(); W.watchers[root] = nil end
    end
    W.list, W.listedBefore, W.listedAt = list, W.listedAt, os.time()
    W.byReal = {}
    for _, path in ipairs(watchPaths()) do
        W.byReal[path] = path
        W.byReal[realOf(path)] = path
        if W.prev[path] and W.prev[path].real then W.byReal[W.prev[path].real] = path end
    end
    return true
end

watchTick = function()
    if not W or W.busy then return end
    W.busy = true
    pcall(function()
        refreshInflight()
        if watchRefresh() then watchCheck(watchPaths(), false, "", "change", W.listedBefore) end
        if W.dirty then writeSnapshot() end
    end)
    if W then
        writeHeartbeat()
        W.busy = false
    end
end

watchStart = function()
    if W or not watchWanted then return end
    if not (hs.pathwatcher and hs.pathwatcher.new) then return end
    if hs.fs.attributes(stateDir, "mode") ~= "directory" then return end
    W = { prev = {}, watchers = {}, inflight = {}, list = {}, byReal = {}, since = os.time(), busy = true }
    hs.fs.mkdir(watchDir())
    local snapshotBorn = hs.fs.attributes(snapshotPath(), "modification")
    local snapshot = readSnapshot()
    local ok = pcall(function()
        refreshInflight()
        if not watchRefresh() then return end
        local paths, seen = {}, {}
        for _, path in ipairs(W.list) do seen[path] = true; paths[#paths + 1] = path end
        for path in pairs(snapshot or {}) do
            if not seen[path] then seen[path] = true; paths[#paths + 1] = path end
        end
        if snapshot == nil then
            local fresh, err = hashPaths(paths)
            if not fresh then W.error = err; return end
            local count = 0
            for path, row in pairs(fresh) do row.trust = true; W.prev[path] = row; count = count + 1 end
            watchEmit({ { verb = "SNAPSHOT-MISSING", vis = snapshotPath(), delta = 0,
                content = "missing@" .. os.time() .. "." .. math.random(0, 0x7fffffff),
                summary = "SNAPSHOT-MISSING " .. snapshotPath() .. " (" .. count
                    .. " files taken as found; anything changed before this went unseen)" } },
                "changed-while-watcher-off")
        else
            W.prev = snapshot
            watchCheck(paths, true, "-WHILE-WATCHER-OFF", "changed-while-watcher-off", snapshotBorn)
        end
        W.byReal = {}
        for _, path in ipairs(watchPaths()) do W.byReal[path] = path; W.byReal[realOf(path)] = path end
        writeSnapshot()
    end)
    if not ok and W then W.error = W.error or "start failed" end
    if W then
        writeHeartbeat()
        W.busy = false
    end
end

local function watchStop()
    if not W then return end
    for _, watcherObj in pairs(W.watchers) do pcall(function() watcherObj:stop() end) end
    W = nil
end

local function instructionLike(path)
    local lower = tostring(path):lower()
    if lower:find("/.claude/projects/", 1, true) then return false end
    return lower:match("%.md$") or lower:match("%.markdown$") or lower:match("/review%-debt%-ignore$")
        or lower:match("/settings%.json$")
end

-- An event always hashes: hs.fs mtimes are whole seconds, so a same-size rewrite inside that second
-- leaves the fingerprint the tick compares untouched.
function M.watchEvent(paths)
    if not W or W.busy then return end
    W.busy = true
    pcall(function()
        refreshInflight()
        local wanted, seen, unknown = {}, {}, false
        for _, path in ipairs(paths or {}) do
            local vis = W.byReal[path] or W.byReal[realOf(path)]
            if vis and not seen[vis] then
                seen[vis] = true
                wanted[#wanted + 1] = vis
            elseif not vis and instructionLike(path) then
                unknown = true
            end
        end
        if #wanted > 0 then watchCheck(wanted, true, "", "change", W.listedAt) end
        if W.dirty then writeSnapshot() end
        if unknown and not W.relist and hs.timer and hs.timer.doAfter then
            W.relist = hs.timer.doAfter(3, function()
                if W then W.relist = nil end
                watchTick()
            end)
        end
    end)
    if W then W.busy = false end
end

function M.watchTick() watchTick() end
function M.watchRoots()
    local roots = {}
    for root in pairs(W and W.watchers or {}) do roots[#roots + 1] = root end
    table.sort(roots)
    return roots
end

-- The watched `~/.claude/...` names are symlinks into claude-setup and tokenmap indexes what the
-- sessions actually read, so a miss on the recorded name is retried on the resolved one.
local function rateKey(cache, path)
    if cache.entries[path] then return path end
    local ok, resolved = pcall(hs.fs.pathToAbsolute, path)
    if ok and type(resolved) == "string" and cache.entries[resolved] then return resolved end
end

local function signed(value, price)
    if value == nil then return "" end
    if value == 0 then return "0" end
    local sign = value < 0 and "-" or "+"
    local magnitude = math.abs(value)
    if magnitude >= 10000 then
        return sign .. string.format(price and "%.1fk" or "%.0fk", magnitude / 1000)
    end
    return sign .. string.format("%.0f", magnitude)
end

local function priceText(value)
    return value ~= nil and (signed(value, true) .. " tok/wk") or ""
end

local function filePrice(cache, path, delta)
    local key = rateKey(cache, path)
    local entry = key and cache.entries[key]
    local loads = type(entry) == "table" and type(entry.weekly) == "table" and entry.weekly.loads
    if delta ~= nil and delta ~= 0 and type(loads) == "number" then
        return delta / CHARS_PER_TOKEN * loads
    end
end

local function cells(text) return utf8.len(text) or #text end
local function pad(text, width, right)
    local spaces = string.rep(" ", math.max(0, width - cells(text)))
    return right and (spaces .. text) or (text .. spaces)
end
local function clip(text, width)
    if cells(text) <= width then return text end
    return "…" .. text:sub(utf8.offset(text, -(width - 1)))
end
local function dimColor()
    local drawing = hs.drawing
    local palette = type(drawing) == "table" and drawing.color
    local asRGB = type(palette) == "table" and palette.asRGB
    if type(asRGB) ~= "function" then return dimColorName end
    local ok, resolved = pcall(asRGB, dimColorName)
    if ok and type(resolved) == "table" then return resolved end
    return dimColorName
end

local function alignedTitles(rows, columns, style)
    local widths = {}
    for c = 1, #columns do
        widths[c] = 0
        for _, row in ipairs(rows) do widths[c] = math.max(widths[c], cells(row[c] or "")) end
    end
    local titles = {}
    for index, row in ipairs(rows) do
        local last, segments = 0, {}
        for c = 1, #columns do if (row[c] or "") ~= "" then last = c end end
        local function add(text, dim)
            local tail = segments[#segments]
            if tail and tail.dim == dim then
                tail.text = tail.text .. text
            else
                segments[#segments + 1] = { text = text, dim = dim }
            end
        end
        for c = 1, last do
            if widths[c] > 0 then
                local cell, column = row[c] or "", columns[c]
                if #segments > 0 then add("  ", segments[#segments].dim) end
                local right = column.right == true
                add((c == last and not right) and cell or pad(cell, widths[c], right), column.dim == true)
            end
        end
        local title = style(segments[1] and segments[1].text or "", segments[1] and segments[1].dim)
        for s = 2, #segments do title = title .. style(segments[s].text, segments[s].dim) end
        titles[index] = title
    end
    return titles
end

local RED = { red = 0.86, green = 0.16, blue = 0.14, alpha = 1 }
local function renderStyle()
    local color = dimColor()
    return function(text, dim, red)
        return hs.styledtext.new(text, { font = menuFont, color = red and RED or (dim and color or nil) })
    end
end
local function eventTime(event)
    local stamp = parseIso(event.at)
    return stamp and os.date("%d %b %H:%M", stamp) or "?"
end

local function eventMenu(event, receipt, cache, style)
    local items = { { title = style(chatLabel(event)), disabled = true } }
    local bytes, verb, rows = deltas(event), verbs(event), {}
    for index, file in ipairs(event.files or {}) do
        local key = rateKey(cache, file)
        local entry = key and cache.entries[key]
        rows[#rows + 1] = {
            file,
            (verb[index] and verb[index] ~= "changed") and verb[index] or "",
            signed(bytes[index]),
            priceText(filePrice(cache, file, bytes[index])),
            (key and cache.ranks[key]) and ("#" .. cache.ranks[key]) or "",
            type(entry) == "table" and MODES[entry.mode] or "",
        }
    end
    local columns = { {}, {}, { right = true }, { right = true }, { right = true }, { dim = true } }
    for _, title in ipairs(alignedTitles(rows, columns, style)) do
        items[#items + 1] = { title = title, disabled = true }
    end
    if tostring(event.sid or "") == "" then return items end
    items[#items + 1] = { title = "-" }
    items[#items + 1] = {
        title = "Copy command to open this chat",
        fn = function()
            openCommandFn(tostring(event.sid or ""), function(code, stdout, stderr)
                if code ~= 0 then
                    alertFn("no command: " .. ((stderr or ""):match("[^\r\n]+") or "unknown error"), 3)
                    return
                end
                local command, metadata = (stdout or ""):match("^([^\r\n]+)\r?\n([^\r\n]*)")
                command = command or (stdout or ""):match("^[^\r\n]+")
                if not command then alertFn("no command: empty output", 3); return end
                pasteboardFn(command)
                local account = (metadata or ""):match("^account=(%S+) source=fallback$")
                if account then
                    alertFn("copied · account " .. account .. " = last launched, pick unreachable", 2)
                else
                    alertFn("copied", 1)
                end
            end)
        end,
    }
    return items
end

local function distinctShortPaths(paths)
    local depth, names = {}, {}
    for index in ipairs(paths) do depth[index] = 2 end
    for _ = 1, 8 do
        local seen, clash = {}, false
        for index, path in ipairs(paths) do
            local parts = {}
            for part in tostring(path):gmatch("[^/]+") do parts[#parts + 1] = part end
            names[index] = table.concat(parts, "/", math.max(1, #parts - depth[index] + 1))
            seen[names[index]] = (seen[names[index]] or 0) + 1
        end
        for index in ipairs(paths) do
            if seen[names[index]] > 1 then depth[index], clash = depth[index] + 1, true end
        end
        if not clash then break end
    end
    return names
end

local function tokenText(value)
    if value >= 999950 then return string.format("%.1fM tok", value / 1e6) end
    if value >= 1000 then return string.format("%.1fk tok", value / 1000) end
    return math.floor(value) .. " tok"
end

local function topMenu(cache, style)
    if not cache.measured then
        return { { title = style("read_tokens missing — regenerate read-rates.json", true), disabled = true } }
    end
    local items = { { title = style("tokens read this week · from Read/@ loads", true), disabled = true },
                    { title = "-" } }
    local rows, names = {}, distinctShortPaths(cache.top)
    for index, path in ipairs(cache.top) do
        local weekly = cache.entries[path].weekly
        local loads = tonumber(weekly.read_loads)
        rows[index] = { clip(names[index], FILE_WIDTH), tokenText(tonumber(weekly.read_tokens)),
                        loads and ("×" .. math.floor(loads)) or "", MODES[cache.entries[path].mode] or "" }
    end
    local columns = { {}, { right = true }, { right = true }, { dim = true } }
    for index, title in ipairs(alignedTitles(rows, columns, style)) do
        local path = cache.top[index]
        items[#items + 1] = { title = title, fn = function() pasteboardFn(path) end }
    end
    if #rows == 0 then
        items[#items + 1] = { title = style("no markdown read this week", true), disabled = true }
    end
    return items
end

local function livenessItem(style)
    local path = heartbeatPath()
    local born = hs.fs.attributes(path, "modification")
    local body = readFile(path) or ""
    local since = tonumber(body:match("since=(%d+)"))
    local roots, files = tonumber(body:match("roots=(%d+)")), tonumber(body:match("files=(%d+)"))
    local failure = body:match("error=([^\n]+)")
    local function stamp(value) return os.date("%d %b %H:%M", value) end
    local text
    if not born then
        text = "watcher: never started"
    elseif os.time() - born > 2 * WATCH_TICK then
        text = "watcher: DOWN since " .. stamp(born)
    elseif failure or (roots or 0) == 0 then
        text = "watcher: DOWN since " .. stamp(since or born) .. " · " .. (failure or "no root watched")
    else
        return { title = style(string.format("watcher: live since %s · %d roots · %d files",
            stamp(since or born), roots, files or 0)), disabled = true }
    end
    return { title = style(text, false, true), disabled = true }
end

function M.menuItems()
    local events, all = readJournal()
    local cache, style = rates(), renderStyle()
    local items = { livenessItem(style) }
    -- Widths follow this render's content: a column nobody fills takes no room and leaves no
    -- blank tail, while every row still lands on the same offsets.
    local rows, fileWidth, byteWidth, priceWidth = {}, 0, 0, 0
    for index = #events, math.max(1, #events - MENU_ROWS + 1), -1 do
        local event = events[index]
        local receipt = receiptFor(event.id)
        local files, bytes = event.files or {}, deltas(event)
        local more = #files > 1 and (" +" .. (#files - 1) .. " more") or ""
        local path = clip(shortPath(files[1] or "?"), FILE_WIDTH - cells(more))
        if event.kind == "dropped" or #files == 0 then path, more = shortSummary(event), "" end
        local totalBytes, totalPrice
        for i, file in ipairs(files) do
            if bytes[i] ~= nil then totalBytes = (totalBytes or 0) + bytes[i] end
            local price = filePrice(cache, file, bytes[i])
            if price ~= nil then totalPrice = (totalPrice or 0) + price end
        end
        -- A legacy ADDED/DELETED record carries no number; the verb says what the blank would not.
        local row = { event = event, receipt = receipt, path = path, more = more,
                      bytes = signed(totalBytes), price = priceText(totalPrice),
                      red = event.kind == "stamp-forged" }
        local verb = verbs(event)[1]
        for _, other in pairs(verbs(event)) do if other ~= verb then verb = nil end end
        if verb and verb ~= "changed" and (totalBytes == nil or totalBytes == 0) then
            row.bytes, row.verb = verb, true
        end
        fileWidth = math.max(fileWidth, cells(path) + cells(more))
        byteWidth = math.max(byteWidth, cells(row.bytes))
        priceWidth = math.max(priceWidth, cells(row.price))
        rows[#rows + 1] = row
    end
    for _, row in ipairs(rows) do
        local red = row.red
        local title = style(pad(eventTime(row.event), 12) .. "  " .. row.path, false, red)
            .. style(row.more, true, red)
        local tail = string.rep(" ", fileWidth - cells(row.path) - cells(row.more))
        if byteWidth > 0 and (row.bytes ~= "" or row.price ~= "") then
            title = title .. style(tail .. "  " .. string.rep(" ", byteWidth - cells(row.bytes)), false, red)
                .. style(row.bytes, row.verb, red)
            tail = ""
        end
        if priceWidth > 0 and row.price ~= "" then
            title = title .. style(tail .. "  " .. pad(row.price, priceWidth, true), false, red)
        end
        items[#items + 1] = { title = title, menu = eventMenu(row.event, row.receipt, cache, style) }
    end
    if #rows == 0 then
        items[#items + 1] = { title = "No changes recorded", disabled = true }
    end
    local older, now = 0, os.time()
    for index = 1, #all - #rows do
        local event = all[index]
        local stamp = parseIso(event.at)
        if (stamp ~= nil and now - stamp <= ALERT_MAX_AGE) or not receiptFor(event.id) then older = older + 1 end
    end
    if older > 0 then
        items[#items + 1] = { title = style("+" .. older .. " older in events.jsonl", true), disabled = true }
    end
    items[#items + 1] = { title = "-" }
    items[#items + 1] = { title = "Top MD files this week", menu = topMenu(cache, style) }
    local ranked = M.rankedPaths()
    local coverage = { { title = "~/.claude: settings.json and every guarded markdown",
                         disabled = true } }
    if #ranked > 0 then
        coverage[#coverage + 1] = { title = "-" }
        for _, path in ipairs(ranked) do
            coverage[#coverage + 1] = { title = path, disabled = true }
        end
    else
        coverage[#coverage + 1] = { title = "no ranked project files cached", disabled = true }
    end
    items[#items + 1] = { title = "Coverage", menu = coverage }
    items[#items + 1] = {
        title = "Reveal change log",
        fn = function()
            hs.task.new("/usr/bin/open",
                nil,
                { "-R", (os.getenv("HOME") or "") .. "/.claude/instruction-changes.log" }):start()
        end,
    }
    return items
end

local function journalStamp()
    local attrs = hs.fs.attributes(journalPath())
    if not attrs then return nil end
    return tostring(attrs.size) .. "/" .. tostring(attrs.modification)
end

-- FSEvents on the state directory, which also holds the snapshot and revert copies the hook writes
-- on every change it sees. Those fire this callback too, so the journal's own fingerprint is
-- checked first and an unrelated write costs one stat rather than a parse.
ensureWatcher = function()
    if watcher ~= nil then return end
    if not (hs.pathwatcher and hs.pathwatcher.new) then return end
    if hs.fs.attributes(stateDir, "mode") ~= "directory" then return end
    watcher = hs.pathwatcher.new(stateDir, onChange)
    if watcher then watcher:start() end
end

onChange = function()
    ensureWatcher()
    if W then pcall(refreshInflight) end
    local stamp = journalStamp()
    if stamp ~= nil and stamp == lastSeen then return end
    lastSeen = stamp
    M.pump()
end

function M.start()
    M.stop()
    lastSeen = journalStamp()
    ensureWatcher()
    watchWanted = true
    watchStart()
    -- The fallback, not the mechanism: FSEvents can coalesce or drop across a sleep, and a change
    -- Egor is never told about is the one failure this module exists to remove.
    timer = hs.timer.doEvery(WATCH_TICK, function()
        watchTick()
        onChange()
    end)
    M.pump()
    return M
end

function M.stop()
    if watcher then watcher:stop(); watcher = nil end
    if timer then timer:stop(); timer = nil end
    watchStop()
    watchWanted = false
end

-- Both exist for the test harness, which runs inside the real Hammerspoon: it points the module at
-- a fixture directory and swaps the screen for a recorder, so proving the transport never puts a
-- line on Egor's display or a receipt in his cache.
function M.setStateDir(dir)
    if watcher then watcher:stop(); watcher = nil end
    watchStop()
    stateDir = dir or DEFAULT_STATE
    lastSeen = nil
    chatNames, chatPending, chatRerun = nil, false, false
end

function M.setChatResolver(fn)
    chatResolverFn = fn or runChatResolver
    chatNames, chatPending, chatRerun = nil, false, false
end

function M.setAlert(fn)
    alertFn = fn or function(text, duration) hs.alert.show(text, duration or 6) end
end

function M.setPasteboard(fn)
    pasteboardFn = fn or function(text) hs.pasteboard.setContents(text) end
end

function M.setOpenCommand(fn)
    openCommandFn = fn or runOpenCommand
end

function M.setHome(dir)
    watchStop()
    homeOverride = dir
end

function M.setRatesPath(path)
    ratesPath, ratesStamp, ratesCache = path or DEFAULT_RATES, nil, nil
end

function M.stateDir() return stateDir end

_G.InstructionWatch = M

-- Started on require rather than by a caller: the hook's poke is `require("instruction-watch")`
-- and nothing else, so the first change of a Hammerspoon session is what installs the watcher.
if _G.hs and _G.hs.pathwatcher then
    pcall(M.start)
end

return M
