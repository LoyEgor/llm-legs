#!/usr/bin/env bash
set -euo pipefail

: "${FAKE_GROKB_CALLS:?}"
: "${FAKE_GROKB_PROMPT:?}"
: "${FAKE_GROKB_SESSION_ROOT:?}"

printf 'GROK_MEMORY=%s\n' "${GROK_MEMORY-<unset>}" >>"$FAKE_GROKB_CALLS"
# The launching chat's stamp, which an image relay only ever passes THROUGH: whatever it writes
# is journaled by the agent that ran it, and a scrubbed environment there is an edit no chat owns.
printf 'CLAUDE_LAUNCHER_SESSION=%s\n' "${CLAUDE_LAUNCHER_SESSION-<unset>}" >>"$FAKE_GROKB_CALLS"
previous=''
for argument in "$@"; do
  printf 'ARG=%s\n' "$argument" >>"$FAKE_GROKB_CALLS"
  if [ "$previous" = -p ]; then
    printf '%s' "$argument" >"$FAKE_GROKB_PROMPT"
  fi
  previous=$argument
done

case "${FAKE_GROKB_MODE:-image}" in
  limit)
    printf 'Error: hit the rate limit for your plan\n' >&2
    exit 1
    ;;
  generic-limit)
    printf 'Error: temporary rate limit\n' >&2
    exit 1
    ;;
  pool)
    printf 'grok: fixture is out of the worker pool, so no headless run may use it.\n' >&2
    exit 2
    ;;
  no-image)
    printf '%s\n' '{"type":"max_turns_reached"}'
    printf 'Error: max turns reached\n' >&2
    exit 1
    ;;
esac

image_format=${FAKE_GROKB_IMAGE_FORMAT:-jpg}
case "$image_format" in jpg|png) ;; *) exit 2 ;; esac
image_dir="$FAKE_GROKB_SESSION_ROOT/fake-session/images"
mkdir -p "$image_dir"
if [ "$image_format" = jpg ]; then
  image_path="$image_dir/1.jpg"
printf '%s' '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAAQABADAREAAhEBAxEB/8QAFgABAQEAAAAAAAAAAAAAAAAAAAcI/8QAGBAAAgMAAAAAAAAAAAAAAAAAABUBUmL/xAAWAQEBAQAAAAAAAAAAAAAAAAAACAT/xAAWEQADAAAAAAAAAAAAAAAAAAAAFmL/2gAMAwEAAhEDEQA/AMsPYsZkuS+G6g9iwS5DdRPHui80uSLG6g90EuQ3Uf/Z' | base64 -D -o "$image_path"

fi
if [ "$image_format" = png ]; then
  image_path="$image_dir/1.png"
  printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAEAQMAAACTPww9AAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGUExURQAA/////3vcmSwAAAABdFJOU4CtXltGAAAAAWJLR0QB/wIt3gAAAAd0SU1FB+oIHw8eLkDK62EAAAAldEVYdGRhdGU6Y3JlYXRlADIwMjYtMDgtMzFUMTU6MzA6NDYrMDA6MDB0ZuRGAAAAJXRFWHRkYXRlOm1vZGlmeQAyMDI2LTA4LTMxVDE1OjMwOjQ2KzAwOjAwBTtc+gAAACh0RVh0ZGF0ZTp0aW1lc3RhbXAAMjAyNi0wOC0zMVQxNTozMDo0NiswMDowMFIufSUAAAALSURBVAjXY2CAAAAACAABLyDdMQAAAABJRU5ErkJggg==' | base64 -D -o "$image_path"
fi
image_name=${image_path##*/}

printf '%s\n' '{"type":"tool_call","toolCallId":"call-895c6af1-3625-4f14-9c9c-69ed9576ca08-2","title":"image_gen","kind":"image_gen","status":"pending","toolName":"image_gen","rawInput":{"prompt":"A perfectly centered flat solid red circle on a pure white background. Simple geometric shape, no shading, no gradients, no outlines, no texture, no shadows. The circle is a uniform bright red (#FF0000) filled disk, occupying most of the square canvas with a small white margin around it. Clean vector-like flat design, minimal, exact geometry.","aspect_ratio":"1:1"},"content":[],"locations":[]}'
printf '%s\n' '{"type":"tool_call_update","toolCallId":"call-895c6af1-3625-4f14-9c9c-69ed9576ca08-2","status":null,"content":[],"rawOutput":null,"locations":[]}'
content_text=$(jq -cn --arg path "$image_path" --arg filename "$image_name" '{path:$path,filename:$filename,session_folder:"images",message:("Image generated and saved to " + $path + ". Do not read or re-display it, and do not describe how it appears to the user.")}')
jq -cn --arg path "$image_path" --arg filename "$image_name" --arg text "$content_text" '{type:"tool_call_update",toolCallId:"call-895c6af1-3625-4f14-9c9c-69ed9576ca08-2",status:"completed",content:[{type:"content",content:{type:"text",text:$text}}],rawOutput:{type:"ImageGen",path:$path,filename:$filename,session_folder:"images"},locations:[]}'
printf '%s\n' '{"type":"max_turns_reached"}'
printf '%s\n' '{"type":"end","stopReason":"cancelled","sessionId":"fixture-session","requestId":"fixture-request","usage":{"input_tokens":11662,"cache_read_input_tokens":34688,"cache_creation_input_tokens":0,"output_tokens":2388,"reasoning_tokens":1996,"total_tokens":48738},"num_turns":4}'
printf 'Error: max turns reached\n' >&2
exit 1
