local veil = {}

local sourceDirectory = (debug.getinfo(1, "S").source or ""):match("^@(.*/)") or ""
local source = sourceDirectory .. "cursor_veil.c"
local home = os.getenv("HOME") or ""
local localDirectory = home .. "/.local"
local binaryDirectory = localDirectory .. "/libexec"
local binary = binaryDirectory .. "/claude-cursor-veil"

local helper
local compiler
local requestedHidden = false
local complained = false
local builtFresh = false
local buildFailed = false

local function complain(reason)
  if not complained then
    complained = true
    print("claude-cursor-veil: " .. reason)
  end
  return false
end

local function safe(call, ...)
  local ok, result = pcall(call, ...)
  return ok and result or nil
end

local function modified(path)
  local attributes = safe(hs.fs.attributes, path)
  return attributes and attributes.modification or nil
end

local function ensureDirectory(path)
  if modified(path) then
    return true
  end
  local result = safe(hs.fs.mkdir, path)
  return result == true or modified(path) ~= nil
end

local function freshBinary()
  local builtAt, sourcedAt = modified(binary), modified(source)
  return builtAt ~= nil and sourcedAt ~= nil and builtAt >= sourcedAt
end

local function alive()
  return helper ~= nil and safe(helper.isRunning, helper) == true
end

local function speak(word)
  if not alive() then
    return false
  end
  if not safe(helper.setInput, helper, word .. "\n") then
    helper = nil
    return complain("the helper stopped reading")
  end
  return true
end

local function spawn()
  if alive() then
    return true
  end
  helper = nil
  local finished
  finished = safe(hs.task.new, binary, function()
    local self = finished
    finished = nil
    if helper == self then
      helper = nil
    end
  end, function()
    return true
  end, {})
  if not finished then
    return complain("hs.task refused " .. binary)
  end
  helper = finished
  if not safe(finished.start, finished) then
    helper = nil
    return complain("the helper did not start")
  end
  return true
end

local function finishBuild(exitCode, _, stdErr)
  compiler = nil
  if exitCode ~= 0 or not modified(binary) then
    buildFailed = true
    complain("clang refused the helper: " .. tostring(stdErr))
    return
  end
  builtFresh = true
  if requestedHidden and spawn() then
    speak("hide")
  end
end

local function build()
  if buildFailed then
    return false
  end
  if compiler and safe(compiler.isRunning, compiler) == true then
    return false
  end
  if not modified(source) then
    buildFailed = true
    return complain("no source at " .. source)
  end
  if not ensureDirectory(localDirectory) or not ensureDirectory(binaryDirectory) then
    buildFailed = true
    return complain("could not create " .. binaryDirectory)
  end
  compiler = safe(hs.task.new, "/usr/bin/clang", finishBuild, {
    "-O2", "-o", binary, source,
    "-framework", "AppKit", "-framework", "ApplicationServices",
    "-framework", "CoreFoundation",
  })
  if not compiler then
    buildFailed = true
    return complain("hs.task refused clang")
  end
  if not safe(compiler.start, compiler) then
    compiler = nil
    buildFailed = true
    return complain("clang did not start")
  end
  return false
end

local function ensureHelper()
  if alive() then
    return true
  end
  if buildFailed then
    return false
  end
  if not builtFresh and not freshBinary() then
    return build()
  end
  return spawn()
end

function veil.hide()
  requestedHidden = true
  if ensureHelper() then
    speak("hide")
  end
end

function veil.show()
  requestedHidden = false
  if alive() then
    speak("show")
  end
end

function veil.settle()
  requestedHidden = false
  if alive() then
    speak("settle")
  end
end

return veil
