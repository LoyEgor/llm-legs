local source = debug.getinfo(1, "S").source
local root = source:match("^@(.+)/tests/[^/]+$")
assert(root, "harness path is unavailable")

local SELF = "org.hammerspoon.Hammerspoon"

local env = setmetatable({}, { __index = _G })
env._G = env
env.hs = {
    processInfo = { bundleID = SELF },
    application = {
        frontmostApplication = function() return nil end,
        watcher = {
            activated = "activated",
            new = function(_) return { start = function() end } end,
        },
    },
}

local chunk, err = loadfile(root .. "/hammerspoon/config/send_actions.lua", "t", env)
assert(chunk, err)
local module = chunk()

assert(module.sendCopy and module.sendPaste and module.sendKeys
    and module.targetIsTerminal and module.clipboardHasText and module.classifyClipboard
    and module.choosePastePath and env._G.SendActions == module
    and module.pasteTargetWatcher, "public API surface is missing")
print("✓ public API surface intact")

local function summaryOf(types, containsImage)
    local _, summary = module.classifyClipboard(types, containsImage)
    return summary
end
assert(summaryOf({ "public.utf8-plain-text" }) == "text", "plain text misclassified")
assert(summaryOf({ "NSStringPboardType" }) == "text", "NSString text misclassified")
assert(summaryOf({ "public.file-url" }) == "file-url", "file-url misclassified")
assert(summaryOf({}) == "none", "empty clipboard misclassified")
assert(summaryOf(nil) == "none", "nil clipboard misclassified")
local pngImage = function(types)
    for _, t in ipairs(types) do if t == "public.png" then return true end end
    return false
end
assert(summaryOf({ "public.png" }, pngImage) == "image", "image misclassified")
assert(summaryOf({ "public.utf8-plain-text", "public.file-url", "public.png" }, pngImage)
    == "text+image+file-url", "combined clipboard misclassified")
local flags = module.classifyClipboard({ "public.file-url" })
assert(flags.text == false and flags["file-url"] == true, "file-url set the text flag")
print("✓ clipboard classification")

-- menuPaste succeeds only for an image / readable image-file clipboard.
local pasteMatrix = {
    { term = true,  class = "text",     avail = true,  expect = "cmd-v" },
    { term = true,  class = "text",     avail = false, expect = "cmd-v" },
    { term = true,  class = "image",    avail = true,  expect = "menuPaste" },
    { term = true,  class = "image",    avail = false, expect = "ctrl-v" },
    { term = true,  class = "file-url", avail = true,  expect = "menuPaste" },
    { term = true,  class = "file-url", avail = false, expect = "cmd-v" },
    { term = true,  class = "none",     avail = true,  expect = "cmd-v" },
    { term = true,  class = "none",     avail = false, expect = "ctrl-v" },
    { term = false, class = "text",     avail = true,  expect = "cmd-v" },
    { term = false, class = "image",    avail = true,  expect = "cmd-v" },
    { term = false, class = "none",     avail = false, expect = "cmd-v" },
}
for _, row in ipairs(pasteMatrix) do
    local hasText = row.class == "text" or row.class == "file-url"
    local succeeds = row.avail and (row.class == "image" or row.class == "file-url") or nil
    local path = module.choosePastePath(row.term, row.avail, hasText, succeeds)
    assert(path == row.expect, string.format(
        "paste path %s/%s/avail=%s expected %s got %s",
        tostring(row.term), row.class, tostring(row.avail), row.expect, path))
end
print("✓ paste-path decision matrix")

local function fakeApp(bundleID, kind, running, pid)
    return {
        _bid = bundleID,
        _kind = kind == nil and 1 or kind,
        _running = running ~= false,
        _pid = pid or 0,
        bundleID = function(self) return self._bid end,
        kind = function(self) return self._kind end,
        isRunning = function(self) return self._running end,
        pid = function(self) return self._pid end,
        activate = function(self) end,
    }
end
assert(module.shouldRemember(fakeApp("com.apple.Terminal", 1)) == true,
    "regular app was not remembered")
assert(module.shouldRemember(fakeApp("com.overlay.panel", 2)) == false,
    "accessory app (kind 2) was remembered")
assert(module.shouldRemember(fakeApp(SELF, 1)) == false,
    "Hammerspoon itself was remembered")
assert(module.shouldRemember(nil) == false, "nil app was remembered")
print("✓ rememberFront kind()==1 filter")

local function context(opts)
    opts = opts or {}
    local ctx = {
        clock = 100,
        front = opts.front or "com.other.app",
        frontPid = opts.frontPid or 999,
        types = opts.types or {},
        contentTypesCalls = 0,
        sent = {},
        logs = {},
        timers = {},
        activated = 0,
    }
    -- Shadow the live module (env falls through to the real _G otherwise); an
    -- empty table models "menuPaste unavailable".
    env._G.ClaudeCmdKeys = opts.claudeCmdKeys or {}
    module.setTestHooks({
        selfBundleID = function() return SELF end,
        timestamp = function() return "2026-01-01T00:00:00Z" end,
        contentTypes = function()
            ctx.contentTypesCalls = ctx.contentTypesCalls + 1
            return ctx.types
        end,
        frontmostBundleID = function() return ctx.front end,
        frontmostPid = function() return ctx.frontPid end,
        now = function() return ctx.clock end,
        after = function(_, fn) ctx.timers[#ctx.timers + 1] = fn; return { stop = function() end } end,
        activate = function(_) ctx.activated = ctx.activated + 1 end,
        keyStroke = function(mods, key, app, delay)
            ctx.sent[#ctx.sent + 1] = { mods = mods, key = key, app = app, delay = delay }
        end,
        log = function(line) ctx.logs[#ctx.logs + 1] = line end,
    })
    if opts.target then module.rememberFront(opts.target) end
    local function field(name)
        local line = ctx.logs[#ctx.logs] or ""
        return line:match(name .. "=(%S+)")
    end
    function ctx:lastPath() return field("path") end
    function ctx:lastActivation() return field("activation") end
    function ctx:lastSentFront() return field("sentFront") end
    function ctx:lastClipboard() return field("clipboard") end
    function ctx:runTimers()
        while #self.timers > 0 do
            local fn = table.remove(self.timers, 1)
            fn()
        end
    end
    return ctx
end

local terminal = fakeApp("com.apple.Terminal", 1, true, 200)
local regular = fakeApp("com.regular.app", 1, true, 100)

-- Paste: image clipboard + menuPaste available -> raw-byte path, no keystroke.
local ck = { containsImageType = pngImage, menuCopy = function() end,
    menuPaste = function() return true end }
local ctx = context({ target = terminal, front = "com.apple.Terminal", frontPid = 200,
    types = { "public.png" }, claudeCmdKeys = ck })
module.sendPaste()
assert(ctx:lastPath() == "menuPaste" and #ctx.sent == 0,
    "image paste did not take menuPaste with no fallback keystroke")

-- Paste: text clipboard, menuPaste declines -> native Cmd+V to frontmost.
ck = { containsImageType = pngImage, menuPaste = function() return false end }
ctx = context({ target = terminal, front = "com.apple.Terminal", frontPid = 200,
    types = { "public.utf8-plain-text" }, claudeCmdKeys = ck })
module.sendPaste()
assert(ctx:lastPath() == "cmd-v" and #ctx.sent == 1 and ctx.sent[1].key == "v",
    "text paste did not fall through to Cmd+V")

-- Paste: menuPaste unavailable, non-text clipboard -> ctrl+v.
ctx = context({ target = terminal, front = "com.apple.Terminal", frontPid = 200,
    types = {}, claudeCmdKeys = {} })
module.sendPaste()
assert(ctx:lastPath() == "ctrl-v" and #ctx.sent == 1
    and ctx.sent[1].mods[1] == "ctrl", "empty-clipboard paste did not use ctrl+v")
print("✓ sendPaste integration paths")

-- Activate-then-send: already frontmost.
ctx = context({ target = regular, front = "com.regular.app", frontPid = 100 })
module.sendCopy()
assert(ctx:lastActivation() == "already-front" and ctx.activated == 0
    and #ctx.sent == 1, "frontmost target activated or missed the send")

-- Activate-then-send: target reached after activation, sentFront recorded.
ctx = context({ target = regular, front = "com.other.app", frontPid = 999 })
module.sendCopy()
assert(ctx.activated == 1 and #ctx.sent == 0, "send fired before activation confirmed")
ctx.front = "com.regular.app"; ctx.frontPid = 100
ctx:runTimers()
assert(ctx:lastActivation() == "activated" and #ctx.sent == 1,
    "target did not send once it became frontmost")
assert(ctx:lastSentFront() == "com.regular.app",
    "activated send did not record the actual frontmost app")

-- Activate-then-send: activation never lands -> send once on timeout.
ctx = context({ target = regular, front = "com.other.app", frontPid = 999 })
module.sendCopy()
ctx.clock = ctx.clock + 5
ctx:runTimers()
assert(ctx:lastActivation() == "timeout" and #ctx.sent == 1,
    "stuck activation did not send once and log a timeout")
print("✓ activate-then-send flow")

-- Frontmost identity is by pid: a same-bundle process with a different pid must
-- not falsely confirm the target is already frontmost.
local instanceA = fakeApp("com.dup.app", 1, true, 111)
ctx = context({ target = instanceA, front = "com.dup.app", frontPid = 222 })
module.sendCopy()
assert(ctx.activated == 1 and #ctx.sent == 0,
    "same-bundle different-pid front falsely confirmed already-front")
ctx.frontPid = 111
ctx:runTimers()
assert(ctx:lastActivation() == "activated" and #ctx.sent == 1,
    "target did not send once its own pid became frontmost")
print("✓ pid-based frontmost confirmation")

-- Target quits mid-poll: the pending send is dropped, never fired globally.
local dying = fakeApp("com.dying.app", 1, true, 300)
ctx = context({ target = dying, front = "com.other.app", frontPid = 999 })
module.sendCopy()
dying._running = false
ctx.clock = ctx.clock + 5
ctx:runTimers()
assert(#ctx.sent == 0 and ctx:lastActivation() == "target-quit",
    "a target that quit mid-poll still received a keystroke")
print("✓ target-quit mid-poll drops the send")

-- Overlapping cmd deliveries run FIFO and never interleave or start a second
-- activation loop; a queued copy is not cancelled by a later paste.
ctx = context({ target = regular, front = "com.other.app", frontPid = 999 })
module.sendKeys({ "cmd" }, "1")
module.sendKeys({ "cmd" }, "2")
assert(#ctx.sent == 0, "a send fired before the first delivery confirmed")
assert(ctx.activated == 1, "the second overlapping call started its own activation")
ctx.front = "com.regular.app"; ctx.frontPid = 100
ctx:runTimers()
assert(#ctx.sent == 2 and ctx.sent[1].key == "1" and ctx.sent[2].key == "2",
    "overlapping deliveries lost FIFO order")
print("✓ deliverCmd serializes FIFO")

-- sendKeys: plain (non-cmd) key keeps direct delivery, no activation dance,
-- and does not classify the clipboard.
ctx = context({ target = regular, front = "com.other.app", frontPid = 999,
    types = { "public.png" } })
module.sendKeys({}, "return")
assert(ctx.activated == 0 and #ctx.sent == 1 and ctx.sent[1].key == "return"
    and ctx:lastActivation() == "targeted", "plain Return did not deliver directly")
assert(ctx.contentTypesCalls == 0 and ctx:lastClipboard() == "-",
    "sendKeys read/classified the clipboard on the hot path")
module.sendPaste()
assert(ctx.contentTypesCalls > 0, "sendPaste did not classify the clipboard")

-- sendKeys: a cmd chord goes through the activate-then-send path.
ctx = context({ target = regular, front = "com.other.app", frontPid = 999 })
module.sendKeys({ "cmd" }, "a")
assert(ctx.activated == 1, "cmd chord skipped the activation path")
print("✓ sendKeys cmd vs plain routing")

-- sendCopy chord gating: the TUI copy chord (ctrl+x ctrl+y) only fires when
-- ClaudeCmdKeys confirms Claude Code owns the foreground; a plain shell would
-- otherwise receive destructive readline edits, so copy falls back to Cmd+C.
local function verdictCK(verdict)
    return { menuCopy = function() end, foregroundVerdict = function() return verdict end }
end

ctx = context({ target = terminal, front = "com.apple.Terminal", frontPid = 200,
    claudeCmdKeys = verdictCK("claude") })
module.sendCopy()
assert(ctx:lastPath() == "menuCopy" and #ctx.sent == 0,
    "confirmed-Claude Terminal did not use the copy chord")

ctx = context({ target = terminal, front = "com.apple.Terminal", frontPid = 200,
    claudeCmdKeys = verdictCK("not-claude") })
module.sendCopy()
assert(ctx:lastPath() == "native-cmd" and #ctx.sent == 1 and ctx.sent[1].key == "c"
    and ctx.sent[1].mods[1] == "cmd", "non-Claude Terminal did not fall back to Cmd+C")

-- Cold cache still uncertain after the deferred re-check -> Cmd+C, never chord.
ctx = context({ target = terminal, front = "com.apple.Terminal", frontPid = 200,
    claudeCmdKeys = verdictCK("uncertain") })
module.sendCopy()
assert(#ctx.sent == 0 and ctx:lastPath() == nil,
    "uncertain verdict acted before its deferred re-check")
ctx:runTimers()
assert(ctx:lastPath() == "native-cmd" and #ctx.sent == 1 and ctx.sent[1].key == "c",
    "still-uncertain verdict did not fall back to Cmd+C")

-- Cold cache that resolves to Claude within the deferral -> chord.
local flip = { verdict = "uncertain" }
ctx = context({ target = terminal, front = "com.apple.Terminal", frontPid = 200,
    claudeCmdKeys = { menuCopy = function() end,
        foregroundVerdict = function() return flip.verdict end } })
module.sendCopy()
flip.verdict = "claude"
ctx:runTimers()
assert(ctx:lastPath() == "menuCopy" and #ctx.sent == 0,
    "verdict that resolved to Claude after the deferral did not use the chord")

-- A terminal ClaudeCmdKeys cannot detect keeps the unconditional chord.
local iterm = fakeApp("com.googlecode.iterm2", 1, true, 210)
ctx = context({ target = iterm, front = "com.googlecode.iterm2", frontPid = 210,
    claudeCmdKeys = verdictCK("not-claude") })
module.sendCopy()
assert(ctx:lastPath() == "menuCopy" and #ctx.sent == 0,
    "undetectable terminal lost its chord path")
print("✓ sendCopy chord gating")

print("All send actions tests passed")
