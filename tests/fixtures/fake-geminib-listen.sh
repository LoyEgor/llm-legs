#!/usr/bin/env bash
set -euo pipefail

: "${FAKE_GEMINIB_CALLS:?}"
: "${FAKE_GEMINIB_PROMPT:?}"

printf 'ARG=%s\n' "$@" >>"$FAKE_GEMINIB_CALLS"
printf 'PWD=%s\n' "$PWD" >>"$FAKE_GEMINIB_CALLS"
call=$(grep -c '^PWD=' "$FAKE_GEMINIB_CALLS")
[ "$1" = profile ]
account=$2
shift 2
model=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --print) printf '%s\n' "$2" >"$FAKE_GEMINIB_PROMPT"; shift 2 ;;
    --model) model=$2; shift 2 ;;
    *) shift ;;
  esac
done
mode=${FAKE_GEMINIB_MODE:-ok}
[ "$mode" != transcript-once ] || { [ "$call" -eq 1 ] && mode=transcript || mode=ok; }
[ "$mode" != text-once ] || { [ "$call" -eq 1 ] && mode=text || mode=ok; }
[ "$mode" != garbled-once ] || { [ "$call" -eq 1 ] && mode=garbled || mode=ok; }
case "$mode" in
  quota-stderr) printf 'AGY_ERROR: {"short_error":"RESOURCE_EXHAUSTED (code 429): Individual quota reached"}\n' >&2; exit 3 ;;
  quota-credits) printf 'AGY_ERROR: {"short_error":"Your AI credits balance is too low to continue."}\n' >&2; exit 3 ;;
  pool) printf 'gemini: fixture is out of the worker pool, so no headless run may use it.\n' >&2; exit 2 ;;
  error) printf 'transport failed\n' >&2; exit 1 ;;
esac
jq -cn --arg model "$model" '{event:"init",conversation_id:"listen-session",init:{model:$model,cwd:env.PWD}}'
paths=()
kinds=()
# Like the model, opens a path with any // collapsed.
while read -r path kind; do
  paths+=("$(printf '%s' "$path" | tr -s /)")
  kinds+=("$kind")
done < <(sed -n 's/^File [0-9]*: \(\/[^ ]*\) (\([a-z]*\),.*/\1 \2/p' "$FAKE_GEMINIB_PROMPT")
[ "$mode" != skip-view ] || paths=("${paths[0]}")
for path in "${paths[@]}"; do
  error=''
  [ "$mode" != view-error ] || [ "$path" != "${paths[0]}" ] || error='file size (25 MB) exceeds 20MB display limit'
  for state in ACTIVE DONE; do
    jq -cn --arg path "$path" --arg state "$state" --arg error "$error" \
      '{event:"step_update",step_update:{state:$state,tool_name:"view_file",
        tool_info:({name:"view_file",parameters:{AbsolutePath:$path}} + if $error == "" then {} else {error:$error} end)}}'
  done
done
# agy's own record: the view_file calls, then one result step each, the media part per the label's kind.
record="$GEMINIB_PROFILES_DIR/$account/.gemini/antigravity-cli/brain/listen-session/.system_generated/logs"
mkdir -p "$record"
record="$record/transcript_full.jsonl"
rm -f "$record"
if [ "$mode" != no-record ]; then
  printf '%s\n' "${paths[@]}" | jq -Rnc '{type: "PLANNER_RESPONSE", tool_calls: [inputs | {name: "view_file", args: {AbsolutePath: .}}]}' >"$record"
  for index in "${!paths[@]}"; do
    path=${paths[$index]} kind=${kinds[$index]}
    mime=$(case "$kind" in audio) printf audio/wav ;; video) printf video/mp4 ;; *) printf image/png ;; esac)
    { [ "$mode" = view-error ] && [ "$path" = "${paths[0]}" ]; } || { [ "$mode" = text ] && [ "$kind" = audio ]; } && mime=''
    jq -nc --arg mime "$mime" '{type: "GENERIC", status: "DONE", content: "The following is the entire, complete content of the requested file.",
      media: (if $mime == "" then [] else [{mime_type: $mime}] end)}' >>"$record"
  done
fi
# Hears the test beeps for real: every silence after the take but the trailing one ends a beep.
heard=''
while IFS=' ' read -r number path; do
  starts=$(ffmpeg -nostats -i "$path" -af silencedetect=n=-30dB:d=0.25 -f null - 2>&1 | grep -c silence_start || :)
  [ "$mode" != deaf-beeps ] || starts=$((starts + 1))
  heard+=" $number:$((starts - 1))"
done < <(grep -q 'must be BEEPS' "$FAKE_GEMINIB_PROMPT" && sed -n 's/^File \([0-9]*\): \(\/[^ ]*\) (audio, .*/\1 \2/p' "$FAKE_GEMINIB_PROMPT")
beeps=${heard:+"BEEPS$heard"$'\n\n'}
case "$mode" in
  quota) response='QUOTA' ;;
  transcript) response=$'I opened the audio file, but the tool provided a text transcription rather than playable audio.\n{"overall": 1}' ;;
  no-audio) response='NO_AUDIO 2' ;;
  cannot-open) response='CANNOT_OPEN 1 file size (25 MB) exceeds 20MB display limit' ;;
  empty) response='' ;;
  *) response=$(printf '%sHeard a tone in [file1](file://%s).\nThe pitch steps up at 3 s.' "$beeps" "${paths[0]}") ;;
esac
# Prefers the caller's file FAKE_GEMINIB_WINNER wherever it stands, else always the first one.
if grep -q 'WINNER: first' "$FAKE_GEMINIB_PROMPT"; then
  verdict=first
  [ -z "${FAKE_GEMINIB_WINNER:-}" ] || [ "$(grep -c "^File 1: .*the caller's file $FAKE_GEMINIB_WINNER)$" "$FAKE_GEMINIB_PROMPT")" -gt 0 ] ||
    verdict=second
  [ "$mode" != garbled ] || verdict='the first one'
  response+=$'\n\n'"**WINNER: $verdict**"
fi
jq -cn --arg response "$response" '{event:"result",result:{conversation_id:"listen-session",status:"SUCCESS",response:$response}}'
