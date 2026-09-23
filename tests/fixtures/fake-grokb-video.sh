#!/usr/bin/env bash
set -euo pipefail

: "${FAKE_GROKB_CALLS:?}"
: "${FAKE_GROKB_PROMPT:?}"
: "${FAKE_GROKB_SESSION_ROOT:?}"

printf 'GROK_MEMORY=%s\n' "${GROK_MEMORY-<unset>}" >>"$FAKE_GROKB_CALLS"
printf 'CLAUDE_LAUNCHER_SESSION=%s\n' "${CLAUDE_LAUNCHER_SESSION-<unset>}" >>"$FAKE_GROKB_CALLS"
previous=''
for argument in "$@"; do
  printf 'ARG=%s\n' "$argument" >>"$FAKE_GROKB_CALLS"
  if [ "$previous" = -p ]; then
    printf '%s' "$argument" >"$FAKE_GROKB_PROMPT"
  fi
  previous=$argument
done
video_tag=ImageToVideo
case " $* " in *reference_to_video*) video_tag=ReferenceToVideo ;; esac

case "${FAKE_GROKB_MODE:-video}" in
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
  zdr)
    printf '%s\n' '{"type":"text","data":"Video generation tools are unavailable under zero data retention (ZDR)."}'
    printf 'Error: zdr_output_storage_required\n' >&2
    exit 1
    ;;
  tier)
    printf '%s\n' '{"type":"text","data":"Video generation is a SuperGrok feature and is not available on the free or X Basic tier."}'
    exit 1
    ;;
  no-video)
    printf '%s\n' '{"type":"max_turns_reached"}'
    printf 'Error: max turns reached\n' >&2
    exit 1
    ;;
  image-only)
    # An image tag where a video tag belongs: the harvester must not accept it and call the run a
    # video, or a failed animation ships as whatever still frame the session happened to hold.
    video_dir="$FAKE_GROKB_SESSION_ROOT/fake-session/images"
    mkdir -p "$video_dir"
    printf 'still\n' >"$video_dir/1.jpg"
    jq -cn --arg path "$video_dir/1.jpg" '{type:"tool_call_update",toolCallId:"call-video-1",status:"completed",content:[],rawOutput:{type:"ImageGen",path:$path,filename:"1.jpg",session_folder:"images"},locations:[]}'
    printf '%s\n' '{"type":"end","stopReason":"EndTurn","sessionId":"01a05a11-0000-7000-8000-00000000beef","requestId":"fixture-request","num_turns":2}'
    exit 0
    ;;
esac

video_dir="$FAKE_GROKB_SESSION_ROOT/fake-session/videos"
mkdir -p "$video_dir"
video_path="$video_dir/1.mp4"
# A real 64x36, 1s H.264 clip: the wrapper measures whatever it delivers, so a fixture of dummy
# bytes would prove nothing about the size=/duration= lines.
printf '%s' 'AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAOCbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAA+gAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAq10cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAA+gAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAEAAAAAkAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAPoAAAQAAABAAAAAAIlbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAwAAAAMABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAAB0G1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAZBzdGJsAAAAwHN0c2QAAAAAAAAAAQAAALBhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAEAAJABIAAAASAAAAAAAAAABFUxhdmM2MS4xOS4xMDEgbGlieDI2NAAAAAAAAAAAAAAAGP//AAAANmF2Y0MBZAAK/+EAGWdkAAqs2UR/nwEQAAADABAAAAMAwPEiWWABAAZo6+PLIsD9+PgAAAAAEHBhc3AAAAABAAAAAQAAABRidHJ0AAAAAAAAGQAAAAAAAAAAGHN0dHMAAAAAAAAAAQAAAAYAAAgAAAAAFHN0c3MAAAAAAAAAAQAAAAEAAABAY3R0cwAAAAAAAAAGAAAAAQAAEAAAAAABAAAoAAAAAAEAABAAAAAAAQAAAAAAAAABAAAIAAAAAAEAABAAAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAGAAAAAQAAACxzdHN6AAAAAAAAAAAAAAAGAAAC2gAAAA4AAAAMAAAADAAAAAwAAAAUAAAAFHN0Y28AAAAAAAAAAQAAA7IAAABhdWR0YQAAAFltZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAACxpbHN0AAAAJKl0b28AAAAcZGF0YQAAAAEAAAAATGF2ZjYxLjcuMTAwAAAACGZyZWUAAAMobWRhdAAAAq0GBf//qdxF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjQgcjMxMDggMzFlMTlmOSAtIEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjMgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0Lmh0bWwgLSBvcHRpb25zOiBjYWJhYz0xIHJlZj0zIGRlYmxvY2s9MTowOjAgYW5hbHlzZT0weDM6MHgxMTMgbWU9aGV4IHN1Ym1lPTcgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MSBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTEgOHg4ZGN0PTEgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9LTIgdGhyZWFkcz0xIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MyBiX3B5cmFtaWQ9MiBiX2FkYXB0PTEgYl9iaWFzPTAgZGlyZWN0PTEgd2VpZ2h0Yj0xIG9wZW5fZ29wPTAgd2VpZ2h0cD0yIGtleWludD0yNTAga2V5aW50X21pbj02IHNjZW5lY3V0PTQwIGludHJhX3JlZnJlc2g9MCByY19sb29rYWhlYWQ9NDAgcmM9Y3JmIG1idHJlZT0xIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTE6MS4wMACAAAAAJWWIhAAS//7oyfzLLXnmdRqJlloPlaccwj0dI/65B2ZLyCHBYsEAAAAKQZokbEEP/qpysAAAAAhBnkJ4gh8F9QAAAAgBnmF0Q/8JWAAAAAgBnmNqQ/8JWQAAABBBmmVJqEFomUwIf//+qdOh' \
  | base64 -D -o "$video_path"

jq -cn --arg tool "${FAKE_GROKB_TOOL:-image_to_video}" '{type:"tool_call",toolCallId:"call-video-1",title:$tool,kind:"other",status:"pending",toolName:$tool,rawInput:{prompt:"gentle push-in",duration:6,resolution_name:"480p"},content:[],locations:[]}'
printf '%s\n' '{"type":"tool_call_update","toolCallId":"call-video-1","status":null,"content":[],"rawOutput":null,"locations":[]}'
content_text=$(jq -cn --arg path "$video_path" '{path:$path,filename:"1.mp4",session_folder:"videos",message:("Video generated and saved to " + $path + ". Do not read or re-display it, and do not describe how it appears to the user.")}')
jq -cn --arg path "$video_path" --arg text "$content_text" --arg tag "$video_tag" '{type:"tool_call_update",toolCallId:"call-video-1",status:"completed",content:[{type:"content",content:{type:"text",text:$text}}],rawOutput:{type:$tag,path:$path,filename:"1.mp4",session_folder:"videos"},locations:[]}'
jq -cn --arg session "${FAKE_GROKB_SESSION_ID:-01a05a11-0000-7000-8000-00000000beef}" '{type:"end",stopReason:"EndTurn",sessionId:$session,requestId:"fixture-request",usage:{input_tokens:900,output_tokens:120,total_tokens:1020},num_turns:2}'
