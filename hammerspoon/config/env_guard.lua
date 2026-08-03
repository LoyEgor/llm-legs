-- `open -a Hammerspoon` inherits the caller's env: a relaunch from a profile
-- shell (HOME=~/.gemini-profiles/*) silently poisons every $HOME-derived path
-- (limits cache, worker-pick) while the menu still looks alive. Relaunch clean
-- once; a fresh marker file means the relaunch didn't fix it — stop looping.
-- Every shell-out uses absolute binary paths: this code runs precisely when
-- the inherited environment (PATH included) is not to be trusted.
local realHome = hs.execute([[/usr/bin/dscl . -read "/Users/$(/usr/bin/id -un)" NFSHomeDirectory 2>/dev/null | /usr/bin/sed -n 's/^NFSHomeDirectory: //p']]):gsub("%s+$", "")
if realHome == "" then
    print("WARNING: HOME env guard disabled: dscl returned no home directory")
    return
end
local marker = realHome .. "/.hammerspoon-env-relaunch"
if os.getenv("HOME") == realHome then
    os.remove(marker)
    -- launchd's StandardOutPath is append-mode and never rotated; cap it here.
    local launchdLog = realHome .. "/Library/Logs/com.egor.hammerspoon.log"
    local logAttr = hs.fs.attributes(launchdLog)
    if logAttr and (logAttr.size or 0) > 5 * 1024 * 1024 then
        local logFile = io.open(launchdLog, "w")
        if logFile then logFile:close() end
    end
    return
end
local markerAttr = hs.fs.attributes(marker)
if markerAttr and (os.time() - markerAttr.modification) < 120 then
    print("ERROR: HOME poisoned (" .. tostring(os.getenv("HOME")) .. ") and clean relaunch already failed; running degraded")
    hs.alert.show("Hammerspoon HOME poisoned — relaunch failed", 10)
    return
end
local markerFile = io.open(marker, "w")
if not markerFile then
    print("ERROR: HOME poisoned (" .. tostring(os.getenv("HOME")) .. ") but marker " .. marker .. " is unwritable; running degraded to avoid a relaunch loop")
    hs.alert.show("Hammerspoon HOME poisoned — marker unwritable", 10)
    return
end
markerFile:close()
print("WARNING: HOME poisoned (" .. tostring(os.getenv("HOME")) .. "); relaunching with clean env")
local _, launchdOwns = hs.execute([[/bin/launchctl print "gui/$(/usr/bin/id -u)/com.egor.hammerspoon" >/dev/null 2>&1]])
if not launchdOwns then
    -- Standalone install only: under the launchd agent (KeepAlive) exiting
    -- is the whole relaunch, and a parallel `open -a` would race it.
    local inner = '/bin/sleep 3; /usr/bin/env -i HOME="' .. realHome:gsub('[\\"$`]', "\\%0") ..
        '" USER="$(/usr/bin/id -un)" LOGNAME="$(/usr/bin/id -un)" PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/open -a Hammerspoon'
    hs.execute("/usr/bin/nohup /bin/sh -c '" .. inner:gsub("'", "'\\''") .. "' >/dev/null 2>&1 &")
end
os.exit()
