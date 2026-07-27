#!/usr/bin/env bash
set -u

printf '%s\n' "$@" >"$OPENCODE_CAPTURE_ARGS"
[[ ${1:-} == run && $# -ge 4 ]] || exit 64
model=$2
shift 2
prompt_file=
max_tokens=
while [[ $# -gt 0 ]]; do
  case $1 in
    --prompt-file)
      prompt_file=$2
      shift 2
      ;;
    --max-tokens)
      max_tokens=$2
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

cat "$prompt_file" >"$OPENCODE_CAPTURE_PROMPT"
if [[ -n ${OPENCODE_CAPTURE_OVERLAP:-} ]]; then
  printf '%s\n' enter >>"$OPENCODE_CAPTURE_OVERLAP"
  sleep 0.4
  printf '%s\n' leave >>"$OPENCODE_CAPTURE_OVERLAP"
fi
if [[ -n ${OPENCODE_CAPTURE_ENV:-} ]]; then
  printf '%s\n' "${OPENCODE_GO_MAX_WAIT_S:-unset}" >"$OPENCODE_CAPTURE_ENV"
fi
if [[ -n ${OPENCODE_CAPTURE_PROFILE:-} ]]; then
  printf '%s\n' "${OPENCODE_GO_PROFILE:-unset}" >>"$OPENCODE_CAPTURE_PROFILE"
fi
if [[ -n ${OPENCODE_CAPTURE_MAX_TOKENS:-} ]]; then
  printf '%s\n' "$max_tokens" >>"$OPENCODE_CAPTURE_MAX_TOKENS"
fi
if [[ ${OPENCODE_REJECT_MODEL:-} == "$model" ]]; then
  printf 'Model %s is not in the OpenCode Go plan\n' "$model" >&2
  exit 2
fi
if [[ -n ${OPENCODE_MAX_CEILING:-} && $max_tokens -gt $OPENCODE_MAX_CEILING ]]; then
  printf 'HTTP 400: max_tokens must be less than or equal to %s\n' \
    "$OPENCODE_MAX_CEILING" >&2
  exit 1
fi
if [[ -n ${OPENCODE_WALL_DEFAULT:-} && -z ${OPENCODE_GO_PROFILE:-} ]]; then
  printf 'HTTP 429\n{"error":"usage limit reached"}\n' >&2
  exit 1
fi
if [[ -n ${OPENCODE_FIXTURE_STDERR:-} ]]; then
  printf '%s\n' "$OPENCODE_FIXTURE_STDERR" >&2
fi
cat "$OPENCODE_FIXTURE_STDOUT"
exit "${OPENCODE_FIXTURE_RC:-0}"
