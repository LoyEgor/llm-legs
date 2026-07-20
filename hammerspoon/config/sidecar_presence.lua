local SidecarPresence = {}

local logPath = hs.configdir .. "/sidecar_presence.log"

-- Sampling runs from launchd (com.egor.sidecar-presence) via
-- ~/.local/libexec/sidecar-presence-sampler, which writes sidecar_presence.log directly.
-- Keeping it out of Hammerspoon avoids the hs.task accumulation that made hs.reload's GC
-- teardown spin at 100% CPU. This module only serves the log over HTTP.
local presencePort = 8766
local presenceServer = hs.httpserver.new(false, false)

function SidecarPresence.lastLines(n)
    n = n or 50
    local file = io.open(logPath, "r")
    if not file then
        return "no log yet"
    end
    local lines = {}
    for line in file:lines() do
        lines[#lines + 1] = line
    end
    file:close()

    local from = math.max(1, #lines - n + 1)
    local slice = {}
    for i = from, #lines do
        slice[#slice + 1] = lines[i]
    end
    return table.concat(slice, "\n")
end

presenceServer:setPort(presencePort)
presenceServer:setInterface(nil)
presenceServer:setCallback(function(_, path, _, _)
    if path == "/sidecar-presence" then
        return SidecarPresence.lastLines(50), 200, {
            ["Content-Type"] = "text/plain; charset=utf-8",
            ["Cache-Control"] = "no-store",
        }
    end
    return "not found\n", 404, { ["Content-Type"] = "text/plain; charset=utf-8" }
end)
presenceServer:start()

SidecarPresence.server = presenceServer

_G.SidecarPresence = SidecarPresence

return SidecarPresence
