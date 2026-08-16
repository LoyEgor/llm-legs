#!/usr/bin/env bash
# Hermetic tests for bin/claude-chat-switch: fixture HOME/profiles/projects, a
# stub `hs` that captures the exact invocation payload, and a stub `ps` so the
# claude-ancestor walk resolves deterministically. Nothing touches the real
# profiles or transcripts.
#
# The exit-wall section at the bottom is the other half of the same handover: it
# runs the Lua module in the real Hammerspoon, but under a sandbox env of its own
# (see there), so no live singleton and no real keystroke is ever reached.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/claude-chat-switch"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# Resolved before the stub `hs` goes on PATH; the wall harness needs the real one.
REAL_HS="$(command -v hs || true)"

asserts=0
fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }

HOME="$WORK/home"
FAKE_BIN="$WORK/bin"
HS_CAPTURE="$WORK/hs_payload.txt"
export HOME HS_CAPTURE
mkdir -p "$HOME/.claude-profiles/com" "$HOME/.claude-profiles/olx" \
         "$HOME/.claude/projects" "$FAKE_BIN"

# Stub hs: record the raw args (script always calls `hs -c "<lua>"`) and answer the
# way a real arm does — a module console line first, the sentinel last.
cat >"$FAKE_BIN/hs" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$HS_CAPTURE"
printf '[claude-chat-switch]\tarmed\tprofile=x\narmed\n'
exit 0
EOF
# Stub ps so find_claude_pid returns immediately: any comm query answers "claude".
# The tty query is --self's, and it lands on the resolved claude pid — the only point
# where the fixture learns that pid, so the sessions-registry entry a live chat would
# have is written there, with the procStart lstart= reports back.
STUB_LSTART="Sat Aug  1 11:11:04 2026"
export STUB_LSTART
cat >"$FAKE_BIN/ps" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do pid=$arg; done
case "$*" in
  *comm=*) echo "claude" ;;
  *ppid=*) echo "1" ;;
  *tty=*)
    if [ -z "${STUB_NO_REGISTRY:-}" ]; then
      reg="$HOME/.claude/sessions/$pid.json"
      mkdir -p "${reg%/*}"
      printf '{"pid":%s,"sessionId":"stub-session-0001","cwd":"/tmp","procStart":"%s","status":"idle"}\n' \
        "$pid" "$STUB_LSTART" > "$reg"
    fi
    echo "ttys009"
    ;;
  *lstart=*) echo "$STUB_LSTART" ;;
esac
EOF
chmod +x "$FAKE_BIN/hs" "$FAKE_BIN/ps"
PATH="$FAKE_BIN:$PATH"
export PATH

# run_switch <extra-env...> -- <args...> : sets stdout/stderr/rc globals and clears
# the hs payload capture first. Env before `--`, script args after.
run_switch() {
  local env_args=() ; while [ "$1" != "--" ]; do env_args+=("$1"); shift; done; shift
  : > "$HS_CAPTURE"
  OUT=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID "${env_args[@]}" \
        "$SCRIPT" "$@" 2>&1); RC=$?
  PAYLOAD=$(cat "$HS_CAPTURE" 2>/dev/null)
}

slug_of() { local r; r=$(cd "$1" && pwd -P); printf '%s' "$r" | sed 's/[^A-Za-z0-9]/-/g'; }

# --- profile validation ---------------------------------------------------
run_switch -- nope
assert test "$RC" -eq 1
assert grep -q "no profile 'nope'" <<<"$OUT"
assert grep -q "existing profiles:" <<<"$OUT"

run_switch -- main abc12345
assert test "$RC" -eq 1
assert grep -qi "not a valid profile name" <<<"$OUT"

run_switch -- status abc12345
assert test "$RC" -eq 1
assert grep -qi "not a valid profile name" <<<"$OUT"

# --- explicit session id wins ---------------------------------------------
run_switch -- olx 11111111-2222-3333-4444-555555555555
assert test "$RC" -eq 0
assert grep -q 'ClaudeChatSwitch.switchChat("olx", "11111111-2222-3333-4444-555555555555", ' <<<"$PAYLOAD"
# third arg is the resolved claude pid — a bare integer; passive mode has no tty
assert grep -Eq ', [0-9]+, nil, \{cwd="' <<<"$PAYLOAD"
# the arm is confirmed by the returned sentinel, not by scanning the console output
assert grep -q "and 'armed' or 'refused'" <<<"$PAYLOAD"
assert grep -q 'armed' <<<"$OUT"
assert grep -q 'claudeb profile olx --resume 11111111-2222-3333-4444-555555555555' <<<"$OUT"

# --- $CLAUDE_CODE_SESSION_ID fallback -------------------------------------
run_switch CLAUDE_CODE_SESSION_ID=env-sid-0001 -- com
assert test "$RC" -eq 0
assert grep -q 'ClaudeChatSwitch.switchChat("com", "env-sid-0001", ' <<<"$PAYLOAD"

# --- newest-transcript fallback (no env, no arg) --------------------------
SCRATCH="$WORK/proj"; mkdir -p "$SCRATCH"
SLUG=$(slug_of "$SCRATCH")
PROJ="$HOME/.claude/projects/$SLUG"; mkdir -p "$PROJ"
touch -t 202601010900 "$PROJ/old-session-aaaa.jsonl"
touch -t 202601010905 "$PROJ/new-session-bbbb.jsonl"
( cd "$SCRATCH" && env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
    HS_CAPTURE="$WORK/hs2.txt" "$SCRIPT" olx >/dev/null 2>&1 )
assert grep -q '"new-session-bbbb"' "$WORK/hs2.txt"

# --- missing session id -> error ------------------------------------------
EMPTY="$WORK/empty"; mkdir -p "$EMPTY"
( cd "$EMPTY" && OUT=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
    "$SCRIPT" olx 2>&1); rc=$?
  [ "$rc" -eq 1 ] || { echo "expected rc1 got $rc"; exit 3; }
  grep -q "could not determine a session id" <<<"$OUT" || { echo "missing msg: $OUT"; exit 3; } )
assert test $? -eq 0

# --- bad chars in explicit session id -> error ----------------------------
run_switch -- olx 'bad/../id'
assert test "$RC" -eq 1
assert grep -qi "unexpected characters" <<<"$OUT"

# --- --self: own tab, own tty, cwd + registry opts -------------------------
# The tab handover path: the target session lives in another project, so the resume
# has to carry its cwd or claude would look for the transcript under the wrong slug.
FOREIGN="$WORK/foreign"; mkdir -p "$FOREIGN"
# the script normalizes --cwd through `pwd -P`, and $TMPDIR is a /var symlink
FOREIGN_REAL=$(cd "$FOREIGN" && pwd -P)
FSLUG=$(slug_of "$FOREIGN")
mkdir -p "$HOME/.claude/projects/$FSLUG"
FSID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
touch "$HOME/.claude/projects/$FSLUG/$FSID.jsonl"

run_switch -- --self --cwd "$FOREIGN" olx "$FSID"
assert test "$RC" -eq 0
assert grep -q "ClaudeChatSwitch.switchChat(\"olx\", \"$FSID\", " <<<"$PAYLOAD"
assert grep -q '"/dev/ttys009", {cwd="' <<<"$PAYLOAD"
assert grep -q "cwd=\"$FOREIGN_REAL\", registry=\"$HOME/.claude/sessions/" <<<"$PAYLOAD"
assert grep -q "cd '$FOREIGN_REAL' && claudeb profile olx --resume $FSID" <<<"$OUT"

# --- passive mode carries --cwd too ----------------------------------------
# He exits the chat himself, so nothing is typed until then — but the resume still
# has to land in the target's project or claude cannot find that transcript.
run_switch -- --cwd "$FOREIGN" olx "$FSID"
assert test "$RC" -eq 0
assert grep -q "cwd=\"$FOREIGN_REAL\"" <<<"$PAYLOAD"
assert grep -q "cd '$FOREIGN_REAL' && claudeb profile olx --resume $FSID" <<<"$OUT"

# --- --cwd picks the newest chat of the TARGET project ---------------------
touch -t 202601010900 "$HOME/.claude/projects/$FSLUG/older-one.jsonl"
touch -t 202601010905 "$HOME/.claude/projects/$FSLUG/$FSID.jsonl"
run_switch -- --cwd "$FOREIGN" olx
assert test "$RC" -eq 0
assert grep -q "\"$FSID\"" <<<"$PAYLOAD"

# --- --cwd without the target's transcript -> error ------------------------
run_switch -- --self --cwd "$WORK" olx "$FSID"
assert test "$RC" -eq 1
assert grep -q "no transcript under" <<<"$OUT"
assert test -z "$PAYLOAD"

# --- flag validation -------------------------------------------------------
run_switch -- --front --self olx "$FSID"
assert test "$RC" -eq 1
assert grep -q "mutually exclusive" <<<"$OUT"

run_switch -- --bogus olx "$FSID"
assert test "$RC" -eq 2
assert grep -q "usage: claude-chat-switch" <<<"$OUT"

run_switch -- --cwd
assert test "$RC" -eq 2

# --- --self refuses without a live registry --------------------------------
# It exits the chat that armed it, usually mid-turn: no registry, no idle signal.
run_switch STUB_NO_REGISTRY=1 -- --self --cwd "$FOREIGN" olx "$FSID"
assert test "$RC" -eq 1
assert grep -q "no live sessions-registry entry" <<<"$OUT"
assert test -z "$PAYLOAD"

# --- a path the error sentinel used to trip over ---------------------------
# The armed console line echoes the cwd back, so "error" in a directory name must
# not read as a failed arm.
TRAP="$WORK/error not found"; mkdir -p "$TRAP"
TRAP_REAL=$(cd "$TRAP" && pwd -P)
TSLUG=$(slug_of "$TRAP"); mkdir -p "$HOME/.claude/projects/$TSLUG"
touch "$HOME/.claude/projects/$TSLUG/$FSID.jsonl"
run_switch -- --cwd "$TRAP" olx "$FSID"
assert test "$RC" -eq 0
assert grep -q "cwd=\"$TRAP_REAL\"" <<<"$PAYLOAD"

# --- hs missing on PATH -> error ------------------------------------------
NOHS="$WORK/nohs"; mkdir -p "$NOHS"
cp "$FAKE_BIN/ps" "$NOHS/ps"; chmod +x "$NOHS/ps"
OUT=$(env -u CLAUDE_CODE_SESSION_ID PATH="$NOHS:/usr/bin:/bin" \
      "$SCRIPT" olx sid-1234 2>&1); RC=$?
assert test "$RC" -eq 1
assert grep -qi "Hammerspoon CLI" <<<"$OUT"

# --- exit wall: the module's own pid poll ----------------------------------
# The wall lives in the Lua module, so it is driven where Lua runs: loadfile with
# a private env gives the module its own `hs` (clock, `ps`, pasteboard, screen)
# and its own `require`, so the stubbed gate below is the only chat_gate it can
# see and the live one is never required, let alone acquired.
[ -n "$REAL_HS" ] || fail "Hammerspoon CLI is unavailable (the exit-wall harness needs it)"
HARNESS="$WORK/wall_harness.lua"
{ printf 'local MODULE = [[%s]]\n' "$ROOT/hammerspoon/config/claude_chat_switch.lua"
  cat <<'LUA'
-- The world the stubbed gate, clock and `ps` answer to; one per scenario, reached
-- through this single upvalue so the module is loaded once.
local W

local checks = 0
local function check(condition, message)
    checks = checks + 1
    if not condition then error(string.format("check %d: %s", checks, message), 2) end
end

local PICKER = "esc to interrupt\nBackground work is running\n  1. Exit anyway"

local ChatGateStub = {}

function ChatGateStub.logger(_)
    return function(event, detail)
        W.logs[#W.logs + 1] = { event = event, detail = tostring(detail or "") }
    end, function() end
end

function ChatGateStub.acquire(opts)
    W.onFail = opts.onFail
    W.granted = true
    opts.onGranted(W.handle)
    return "granted"
end

function ChatGateStub.cancel()
    if W and W.granted and not W.released then W.handle:release("cancelled") end
    return true
end

local env = setmetatable({}, { __index = _G })
env._G = env
env.require = function(name)
    assert(name == "chat_gate", "the module required something other than chat_gate")
    return ChatGateStub
end
env.hs = {
    execute = function(command)
        if command:find("/bin/ps", 1, true) then
            return W.pidAlive and (" " .. W.pid .. "\n") or ""
        end
        return ""
    end,
    timer = { secondsSinceEpoch = function() return W.clock end },
    osascript = { applescript = function(_) return true, W.screen end },
    alert = { show = function(text) W.alerts[#W.alerts + 1] = tostring(text) end },
    application = { find = function() return nil end },
    pasteboard = { setContents = function(value) W.pasteboard = value; return true end },
    inspect = tostring,
}

local function newWorld(opts)
    opts = opts or {}
    local w = {
        clock = 1000,
        pid = 4242,
        pidAlive = true,
        screen = opts.screen or "no picker here",
        holdVoice = opts.holdVoice == true,
        logs = {}, presses = {}, bursts = {}, voice = {}, timers = {}, afters = {},
        alerts = {}, cancelWaits = 0,
    }
    local handle = { ttyPath = "/dev/ttys009" }
    w.handle = handle

    function handle:alive() return w.granted == true and w.released == nil end
    function handle:every(interval, fn)
        local timer = { interval = interval, fn = fn }
        w.timers[#w.timers + 1] = timer
        return timer
    end
    function handle:stopTimer(timer) if timer then timer.stopped = true end end
    -- The real cancelWaits stops the voice poll, so a press it is still holding
    -- never fires; dropping the pending callbacks models exactly that.
    function handle:cancelWaits()
        w.cancelWaits = w.cancelWaits + 1
        w.voice = {}
    end
    function handle:after(_, fn) w.afters[#w.afters + 1] = fn; return {} end
    function handle:openWindow(_, onReady) onReady() end
    function handle:waitForIdle(_, onIdle) onIdle() end
    function handle:focusTarget(_, onReady) onReady() end
    -- The real runBurst refuses on a dead handle, which is the only thing between a
    -- callback that was already queued and a keystroke landing after the give-up.
    function handle:runBurst(label, actions, _, onDone)
        if not self:alive() then return end
        w.bursts[#w.bursts + 1] = { label = label, actions = actions }
        onDone()
    end
    function handle:pressOnce(label, modifiers, key, _, onDone)
        if not self:alive() then return end
        w.presses[#w.presses + 1] = { label = label, key = key, modifiers = modifiers }
        if onDone then onDone() end
    end
    function handle:waitForVoiceIdle(voiceOpts, onIdle)
        if w.holdVoice then
            w.voice[#w.voice + 1] = { label = voiceOpts.label, fn = onIdle }
        else
            onIdle()
        end
    end
    function handle:fail(event, detail, alertText)
        if not self:alive() then return end
        w.failed = { event = event, detail = detail }
        w.onFail(event, detail, alertText)
    end
    function handle:release(reason)
        if w.released then return end
        w.released = reason
        for _, timer in ipairs(w.timers) do timer.stopped = true end
    end
    function handle:dropPasteboardRestore() w.pasteboardKept = true; return true end

    function w:tick(times)
        for _ = 1, (times or 1) do
            self.clock = self.clock + 1
            local live = {}
            for index, timer in ipairs(self.timers) do live[index] = timer end
            for _, timer in ipairs(live) do
                if not timer.stopped and self.released == nil then timer.fn() end
            end
        end
    end
    function w:runAfters()
        while #self.afters > 0 do table.remove(self.afters, 1)() end
    end
    function w:releaseVoice()
        local pending = self.voice
        self.voice = {}
        for _, entry in ipairs(pending) do entry.fn() end
    end
    function w:events(name)
        local seen = 0
        for _, line in ipairs(self.logs) do
            if line.event == name then seen = seen + 1 end
        end
        return seen
    end
    function w:detail(name)
        for _, line in ipairs(self.logs) do
            if line.event == name then return line.detail end
        end
        return ""
    end
    function w:pressLabels()
        local labels = {}
        for index, press in ipairs(self.presses) do labels[index] = press.label end
        return table.concat(labels, ",")
    end
    return w
end

local chunk, err = loadfile(MODULE, "t", env)
assert(chunk, err)
local module = chunk()
check(env._G.ClaudeChatSwitch == module, "the module did not publish itself into the sandbox")

-- (a) the chat sits on the picker past the first grace: one blind Enter, a grace
-- that restarts before the press lands, then the normal resume once the pid dies.
W = newWorld({ holdVoice = true })
check(module.switchChat("olx", "sid-a", W.pid, "/dev/ttys009", { cwd = "/tmp" }) == true,
    "switchChat refused the auto-mode arm")
check(#W.bursts == 1 and W.bursts[1].label == "/exit" and W:events("exit-typed") == 1,
    "/exit was not typed on arm")
W:tick(14)
check(W:events("exit-wall") == 0, "the wall fired before the grace ran out")
W:tick(1)
check(W:events("exit-wall") == 1, "the wall did not fire when the grace ran out")
check(#W.presses == 0 and #W.voice == 1 and W.voice[1].label == "exit-wall",
    "the wall Enter skipped the dictation gate")
W:tick(10)
check(W:events("exit-wall-unpassed") == 0 and W.failed == nil,
    "the grace was not restarted before the held Enter went out")
W:releaseVoice()
check(#W.presses == 1 and W.presses[1].label == "exit-wall"
    and W.presses[1].key == "return" and #W.presses[1].modifiers == 0,
    "the wall Enter did not go out once through the stamped-key path")
W:tick(14)
check(W:events("exit-wall-unpassed") == 0, "the landed press did not restart the grace")
W.pidAlive = false
W:tick(1)
check(W:events("exit-wall-passed") == 1 and W:events("exited") == 1,
    "a chat that exited after the wall was not logged as passed")
check(W:detail("exit-wall-passed"):find("Enter went out", 1, true),
    "exit-wall-passed did not credit the Enter that actually went out")
check(#W.presses == 1, "a second wall Enter went out")
check(W.cancelWaits == 1, "the /exit phase was left running into the resume")
local resume = W.bursts[#W.bursts]
check(resume.label == "resume"
    and resume.actions[2].value == "cd '/tmp' && claudeb profile olx --resume sid-a",
    "the resume did not follow a passed wall")
W:runAfters()
check(W.released == "delivered", "the gate was not released after the resume")
module.cancel()
print("ok  wall: first grace -> one Enter, grace restarted, exit-wall-passed")

-- (b) the chat outlasts both graces: that one Enter only, then the fail path.
W = newWorld()
module.switchChat("olx", "sid-b", W.pid, "/dev/ttys009", { cwd = "/tmp" })
W:tick(15)
check(W:events("exit-wall") == 1 and #W.presses == 1, "the wall Enter did not go out")
W:tick(14)
check(W:events("exit-wall-unpassed") == 0, "the second grace was cut short")
W:tick(1)
check(W:events("exit-wall-unpassed") == 1,
    "a chat that outlasted both graces was not given up on")
check(W:detail("exit-wall-unpassed"):find("4242", 1, true)
    and W:detail("exit-wall-unpassed"):find("30s total", 1, true),
    "exit-wall-unpassed names neither the pid nor the total wait")
check(W.failed ~= nil and W.failed.event == "give-up", "the wall did not abort through fail")
check(#W.presses == 1, "a second Enter went out after the wall")
check(W.pasteboard == "cd '/tmp' && claudeb profile olx --resume sid-b"
    and W.pasteboardKept == true, "the resume command was not left on the clipboard")
check(W.released == "give-up", "the gate was not released on the failed wall")
check(module.pending() == nil, "the failed switch stayed pending")
check(W.alerts[1]:find("did not exit", 1, true), "the abort alert says nothing useful")
W:tick(20)
check(#W.presses == 1 and W:events("exit-wall") == 1, "the given-up poll kept running")
print("ok  wall: both graces -> exit-wall-unpassed, fail, no second Enter")

-- (c) a chat that exits inside the first grace never sees the wall.
W = newWorld()
module.switchChat("olx", "sid-c", W.pid, "/dev/ttys009", { cwd = "/tmp" })
W:tick(5)
W.pidAlive = false
W:tick(1)
check(W:events("exit-wall") == 0 and W:events("exit-wall-passed") == 0
    and W:events("exit-wall-unpassed") == 0,
    "a chat that exited inside the grace hit the wall anyway")
check(#W.presses == 0, "a blind Enter went out inside the first grace")
check(W.bursts[#W.bursts].label == "resume", "the resume did not run")
module.cancel()
print("ok  wall: exit inside the first grace logs no wall lines")

-- (d) the screen-read confirm owns the picker while it still has presses left;
-- the blind wall only takes over once it has given up, and each confirm press
-- restarts the grace, so the two never answer the same picker at once.
W = newWorld({ screen = PICKER })
module.switchChat("olx", "sid-d", W.pid, "/dev/ttys009", { cwd = "/tmp" })
W:tick(21)
check(W:pressLabels() == "exit-confirm,exit-confirm",
    "the screen-read confirm did not answer the picker twice")
check(W:events("exit-wall") == 0, "the wall fired while the confirm still had presses")
W:tick(1)
check(W:events("exit-wall") == 1 and W:pressLabels() == "exit-confirm,exit-confirm,exit-wall",
    "the wall did not take over after the confirm gave up")
W.pidAlive = false
W:tick(1)
check(W:events("exit-wall-passed") == 1, "the passed wall was not logged after the confirms")
module.cancel()
print("ok  wall: screen-read confirm runs first, wall answers only after it")

-- (e) a confirm press left deferred behind the dictation gate: the grace running out
-- gives the switch up on schedule, rather than queueing the wall's Enter behind the
-- stuck one for both to fire back to back once the gate opens.
W = newWorld({ holdVoice = true, screen = PICKER })
module.switchChat("olx", "sid-e", W.pid, "/dev/ttys009", { cwd = "/tmp" })
W:tick(14)
check(#W.voice == 1 and W.voice[1].label == "exit-confirm" and #W.presses == 0,
    "the confirm Enter did not end up held by the dictation gate")
check(W.failed == nil, "the stuck confirm was given up on before its grace ran out")
W:tick(1)
check(W.failed ~= nil and W.failed.event == "give-up",
    "a confirm press stuck past the grace did not fail the switch")
check(W.failed.detail:find("exit-confirm Enter never landed", 1, true),
    "the give-up does not name the confirm Enter that never landed")
check(W:events("exit-wall") == 0 and W:events("exit-wall-unpassed") == 0,
    "a stuck confirm was reported as a wall the chat outlasted")
check(#W.voice == 1, "a second Enter was queued behind the stuck confirm")
check(W.released == "give-up", "the gate was not released on the stuck confirm")
W:releaseVoice()
check(#W.presses == 0, "the deferred confirm Enter fired after the switch was given up")
print("ok  wall: stuck confirm -> give up on schedule, no wall, no second Enter")

-- (f) the picker becomes readable while the wall's Enter is still held: the confirm
-- path stays off from there on, so the wall's own grace ends the switch on one Enter.
W = newWorld({ holdVoice = true })
module.switchChat("olx", "sid-f", W.pid, "/dev/ttys009", { cwd = "/tmp" })
W:tick(15)
check(W:events("exit-wall") == 1 and #W.voice == 1 and W.voice[1].label == "exit-wall",
    "the wall did not queue its Enter")
W.screen = PICKER
W:tick(10)
check(#W.voice == 1 and W:events("exit-confirmed") == 0,
    "the confirm path queued a second Enter behind the wall's")
W:releaseVoice()
check(W:pressLabels() == "exit-wall", "more than one Enter went out")
W:tick(14)
check(W:events("exit-wall-unpassed") == 0, "the confirm path was restarting the wall's grace")
W:tick(1)
check(W:events("exit-wall-unpassed") == 1 and W:pressLabels() == "exit-wall",
    "the wall's grace did not end the switch on a single Enter")
print("ok  wall: a picker readable after the wall never adds a confirm Enter")

-- (g) the chat dies on its own while the wall's Enter is still held.
W = newWorld({ holdVoice = true })
module.switchChat("olx", "sid-g", W.pid, "/dev/ttys009", { cwd = "/tmp" })
W:tick(15)
check(W:events("exit-wall") == 1 and #W.presses == 0, "the wall Enter was not still held")
W.pidAlive = false
W:tick(1)
check(W:detail("exit-wall-passed"):find("never went out", 1, true),
    "a chat that died with the Enter still held was credited with sending it")
W:releaseVoice()
check(#W.presses == 0 and W.bursts[#W.bursts].label == "resume",
    "the held wall Enter landed on top of the resume")
module.cancel()
print("ok  wall: exit-wall-passed names an Enter that never went out")

print(string.format("PASS: claude-chat-switch exit wall (%d checks)", checks))
LUA
} > "$HARNESS"

WALL_OUT=$("$REAL_HS" -c "return dofile([[$HARNESS]])" 2>&1); WALL_RC=$?
[ "$WALL_RC" -eq 0 ] || printf '%s\n' "$WALL_OUT" >&2
assert test "$WALL_RC" -eq 0
assert grep -q 'wall: first grace -> one Enter, grace restarted, exit-wall-passed' <<<"$WALL_OUT"
assert grep -q 'wall: both graces -> exit-wall-unpassed, fail, no second Enter' <<<"$WALL_OUT"
assert grep -q 'wall: exit inside the first grace logs no wall lines' <<<"$WALL_OUT"
assert grep -q 'wall: screen-read confirm runs first, wall answers only after it' <<<"$WALL_OUT"
assert grep -q 'wall: stuck confirm -> give up on schedule, no wall, no second Enter' <<<"$WALL_OUT"
assert grep -q 'wall: a picker readable after the wall never adds a confirm Enter' <<<"$WALL_OUT"
assert grep -q 'wall: exit-wall-passed names an Enter that never went out' <<<"$WALL_OUT"
# Pinned, not a floor: the scenario greps above survive a gutted scenario body, so
# a check that quietly disappears has to show up as this number moving.
WALL_CHECKS=$(sed -n 's/^PASS: claude-chat-switch exit wall (\([0-9]*\) checks)$/\1/p' <<<"$WALL_OUT")
assert test "${WALL_CHECKS:-0}" -eq 49

echo "PASS: claude-chat-switch ($asserts assertions, $WALL_CHECKS wall checks)"
