#!/usr/bin/env bash
set -euo pipefail

: "${FAKE_GEMINIB_CALLS:?}"
: "${FAKE_GEMINIB_PROMPT:?}"
: "${GEMINIB_PROFILES_DIR:?}"

printf 'ARG=%s\n' "$@" >>"$FAKE_GEMINIB_CALLS"
printf 'CLAUDE_LAUNCHER_SESSION=%s\n' "${CLAUDE_LAUNCHER_SESSION-}" >>"$FAKE_GEMINIB_CALLS"
[ "$1" = profile ]
account=$2
shift 2
session='fixture-session'
log_file=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --print) printf '%s\n' "$2" >"$FAKE_GEMINIB_PROMPT"; shift 2 ;;
    --conversation) session=$2; shift 2 ;;
    --log-file) log_file=$2; shift 2 ;;
    *) shift ;;
  esac
done
: >"$log_file"
mode=${FAKE_GEMINIB_MODE:-image}
case "$mode" in
  quota-plain) printf 'QUOTA\n'; exit 0 ;;
  quota-stderr) printf 'RESOURCE_EXHAUSTED\n' >&2; exit 1 ;;
  quota-log) printf 'image generation quota exceeded\n' >"$log_file"; exit 1 ;;
  quota-exit) printf 'AGY_ERROR: {"short_error":"RESOURCE_EXHAUSTED (code 429): Individual quota reached"}
' >&2; exit 3 ;;
  api-error) printf 'AGY_ERROR: {"short_error":"INTERNAL (code 500): backend error"}
' >&2; exit 3 ;;
  error) printf 'transport failed\n' >&2; exit 1 ;;
  pool) printf 'gemini: fixture is out of the worker pool, so no headless run may use it.\n' >&2; exit 2 ;;
esac
if [ "$mode" != no-session ]; then
  jq -cn --arg session "$session" '{event:"init",conversation_id:$session,init:{model:"gemini-3.6-flash-low",tools:["generate_image"]}}'
fi
if [ "$mode" = quota ]; then
  jq -cn --arg session "$session" '{event:"result",result:{conversation_id:$session,status:"SUCCESS",response:"QUOTA\n"}}'
  exit 0
fi
if [ "$mode" = quota-tool ]; then
  printf '%s\n' '{"event":"step_update","step_update":{"state":"DONE","tool_name":"generate_image","tool_info":{"error":{"message":"RESOURCE_EXHAUSTED"}}}}'
  exit 0
fi
profile_home="$GEMINIB_PROFILES_DIR/$account"
[ "$account" != main ] || profile_home=$HOME
image_name=$(sed -n 's/^ImageName: //p' "$FAKE_GEMINIB_PROMPT")
image_dir="$profile_home/.gemini/antigravity-cli/brain/$session"
mkdir -p "$image_dir"
image_path="$image_dir/${image_name}_123.jpg"
if [ "$mode" != no-image ]; then
  "$REAL_MAGICK" -size 16x12 xc:'#00FF00' -fill blue -draw 'rectangle 5,4 10,8' "$image_path"
fi
if [ "$mode" = stale ]; then
  touch -t 202001010000 "$image_path"
fi
if [ "$mode" != no-model ]; then
  python3 - "$profile_home" "$session" "$image_path" "${FAKE_IMAGE_MODEL:-gemini-3.1-flash-image}" <<'PY'
import pathlib
import sqlite3
import sys

def varint(number):
    result = bytearray()
    while number > 127:
        result.append((number & 127) | 128)
        number >>= 7
    return bytes(result + bytes([number]))

def field(number, value):
    return varint(number * 8 + 2) + varint(len(value)) + value

uri = ('file://' + sys.argv[3]).encode()
image = field(5, sys.argv[4].encode()) + field(6, field(5, uri))
payload = field(140, field(2, field(6, field(2, field(104, image)))))
path = pathlib.Path(sys.argv[1]) / '.gemini/antigravity-cli/conversations' / (sys.argv[2] + '.db')
path.parent.mkdir(parents=True, exist_ok=True)
with sqlite3.connect(path) as db:
    db.execute('CREATE TABLE IF NOT EXISTS steps (idx INTEGER PRIMARY KEY, step_payload BLOB)')
    db.execute('INSERT INTO steps (step_payload) VALUES (?)', (payload,))
PY
fi
response="$image_path"
case "$mode" in
  rescue|init-only|no-image) response='The image is ready.' ;;
  stream) response='Image generated.' ;;
esac
if [ "$mode" = stream ] || [ "$mode" = saved-then-error ] || [ "$mode" = saved-then-quota ]; then
  jq -cn --arg session "$session" --arg path "$image_path" '{event:"step_update",step_update:{conversation_id:$session,step_index:3,state:"DONE",step_type:"tool",tool_name:"generate_image",tool_info:{name:"generate_image",parameters:{Prompt:"A poster reading rate limit",ImageName:"fixture"},output:("Using prompt: A poster reading rate limit\n\nGenerated image is saved at " + $path + ".\n\n Do not output the path of this image to show to the user since the user can already see it.")}}}'
fi
if [ "$mode" = saved-then-error ]; then
  printf 'AGY_ERROR: {"short_error":"INTERNAL (code 500): backend error"}\n' >&2
  exit 3
fi
if [ "$mode" = saved-then-quota ]; then
  printf 'AGY_ERROR: {"short_error":"RESOURCE_EXHAUSTED (code 429): Individual quota reached"}\n' >&2
  exit 3
fi
if [ "$mode" != init-only ]; then
  [ "$mode" != no-session ] || session=''
  jq -cn --arg session "$session" --arg response "$response" '{event:"result",result:({status:"SUCCESS",response:$response} + if $session == "" then {} else {conversation_id:$session} end)}'
fi
