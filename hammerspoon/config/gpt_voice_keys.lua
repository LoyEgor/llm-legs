-- transcriptions-gpt runs an always-on event tap that swallows a bare Enter
-- (stop/interject the live take) and a bare Esc (cancel) while a dictation or a
-- transform is running. Any automation of ours that types into the frontmost
-- window loses those keys to whatever take happens to be live - and gets that
-- take's transcript pasted into the window instead of its own input landing.
-- The daemon's documented opt-out is this marker in the event's source-user-data
-- field, honored for Enter and Esc only (that project's CONTROL.md).
local GptVoiceKeys = {}

local marker = 0x54475A45

function GptVoiceKeys.postKey(key)
    local field = hs.eventtap.event.properties.eventSourceUserData
    for _, isDown in ipairs({ true, false }) do
        local event = hs.eventtap.event.newKeyEvent({}, key, isDown)
        event:setProperty(field, marker)
        event:post()
    end
end

function GptVoiceKeys.returnKey()
    GptVoiceKeys.postKey("return")
end

return GptVoiceKeys
