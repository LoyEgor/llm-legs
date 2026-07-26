local Notify = {}

local entries = {}
local config = nil
local logPath = hs.configdir .. "/notify.log"

pcall(function()
    local file = io.open(logPath, "r")
    if not file then
        return
    end
    local size = file:seek("end") or 0
    file:close()
    if size <= 1024 * 1024 then
        return
    end

    local lines = {}
    for line in io.lines(logPath) do
        lines[#lines + 1] = line
    end

    file = io.open(logPath, "w")
    if file then
        local first = math.max(1, #lines - 1999)
        for i = first, #lines do
            file:write(lines[i], "\n")
        end
        file:close()
    end
end)

local ok, loaded = pcall(hs.json.read, hs.configdir .. "/notify_config.json")
if ok and type(loaded) == "table" then
    config = loaded
else
    print("ERROR: Notification config unavailable:", tostring(loaded))
end

local function append(line)
    local timestamp = os.time()
    line = tostring(line)
    entries[#entries + 1] = { ts = timestamp, line = line }
    if #entries > 100 then
        table.remove(entries, 1)
    end
    pcall(function()
        local file = io.open(logPath, "a")
        if file then
            pcall(file.write, file, os.date("%Y-%m-%d %H:%M:%S", timestamp), " ", line, "\n")
            file:close()
        end
    end)
end

function Notify.log(line)
    append(line)
end

function Notify.recent()
    local lines = {}
    for _, entry in ipairs(entries) do
        lines[#lines + 1] = os.date("%H:%M:%S", entry.ts) .. " " .. entry.line
    end
    return table.concat(lines, "\n")
end

function Notify.send(title, message, opts)
    opts = opts or {}
    title = tostring(title or "Hammerspoon")
    message = tostring(message or "")
    append(title .. ": " .. message:gsub("\n", " / "))

    if not config or type(config.ntfy_topic) ~= "string" or config.ntfy_topic == "" then
        print("NOTIFY:", title, message)
        return
    end

    local priority = opts.priority or "default"
    if priority ~= "high" and priority ~= "default" and priority ~= "low" then
        priority = "default"
    end

    -- ntfy header values must remain ASCII; UTF-8 owner text belongs in the body.
    local asciiTitle = title:gsub("[^\32-\126]", "?")
    local headers = {
        ["Title"] = asciiTitle,
        ["Priority"] = priority,
        ["Content-Type"] = "text/plain; charset=utf-8",
    }
    if type(opts.tags) == "string" and opts.tags ~= "" then
        headers["Tags"] = opts.tags:gsub("[^\32-\126]", "")
    end

    hs.http.asyncPost("https://ntfy.sh/" .. config.ntfy_topic, message, headers, function(status)
        if status ~= 200 then
            local line = "ntfy delivery failed: HTTP " .. tostring(status)
            print("ERROR:", line)
            append(line)
        end
    end)

    local telegram = config.telegram
    if type(telegram) == "table" and type(telegram.token) == "string" and telegram.token ~= ""
        and type(telegram.chat_id) == "string" and telegram.chat_id ~= "" then
        local telegramBody = hs.json.encode({
            chat_id = telegram.chat_id,
            text = title .. "\n" .. message,
        })
        hs.http.asyncPost(
            "https://api.telegram.org/bot" .. telegram.token .. "/sendMessage",
            telegramBody,
            { ["Content-Type"] = "application/json" },
            function(status)
                if status ~= 200 then
                    local line = "Telegram delivery failed: HTTP " .. tostring(status)
                    print("ERROR:", line)
                    append(line)
                end
            end
        )
    end
end

_G.Notify = Notify

return Notify
