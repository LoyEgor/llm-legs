#!/usr/bin/env bash
set -euo pipefail

: "${FAKE_GEMINIB_CALLS:?}"
: "${FAKE_GEMINIB_PROMPT:?}"

printf 'ARG=%s\n' "$@" >>"$FAKE_GEMINIB_CALLS"
printf 'PWD=%s\n' "$PWD" >>"$FAKE_GEMINIB_CALLS"
[ "$1" = profile ]
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
case "$mode" in
  quota-stderr) printf 'AGY_ERROR: {"short_error":"RESOURCE_EXHAUSTED (code 429): Individual quota reached"}\n' >&2; exit 3 ;;
  quota-credits) printf 'AGY_ERROR: {"short_error":"Your AI credits balance is too low to continue."}\n' >&2; exit 3 ;;
  pool) printf 'gemini: fixture is out of the worker pool, so no headless run may use it.\n' >&2; exit 2 ;;
  error) printf 'transport failed\n' >&2; exit 1 ;;
esac
jq -cn --arg model "$model" '{event:"init",conversation_id:"listen-session",init:{model:$model,cwd:env.PWD}}'
paths=()
while IFS= read -r path; do paths+=("$path"); done < <(sed -n 's/^File [0-9]*: \(\/[^ ]*\) (.*/\1/p' "$FAKE_GEMINIB_PROMPT")
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
case "$mode" in
  quota) response='QUOTA' ;;
  cannot-open) response='CANNOT_OPEN 1 file size (25 MB) exceeds 20MB display limit' ;;
  empty) response='' ;;
  *) response=$(printf 'Heard a tone in [file1](file://%s).\nThe pitch steps up at 3 s.' "${paths[0]}") ;;
esac
jq -cn --arg response "$response" '{event:"result",result:{conversation_id:"listen-session",status:"SUCCESS",response:$response}}'
