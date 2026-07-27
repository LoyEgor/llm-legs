#!/usr/bin/env bash
set -u

log_file=
prompt=
profile=
model=
effort=
while [ "$#" -gt 0 ]; do
  case "$1" in
    profile)
      profile=$2
      printf '%s' "$profile" >>"$GEMINIB_CAPTURE_PROFILE"
      shift 2
      ;;
    --model)
      model=$2
      shift 2
      ;;
    --effort)
      effort=$2
      shift 2
      ;;
    --log-file)
      log_file=$2
      shift 2
      ;;
    --print)
      prompt=$2
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [ -n "${GEMINIB_EXHAUSTED_PROFILE:-}" ] && [ "$profile" = "$GEMINIB_EXHAUSTED_PROFILE" ]; then
  printf 'Individual quota reached for this account\n' >&2
  exit 1
fi
printf '%s' "$prompt" >"$AGY_CAPTURE_PROMPT"
pwd >"$AGY_CAPTURE_CWD"
git rev-parse HEAD >"$AGY_CAPTURE_HEAD"
if git rev-parse --verify refs/remotes/origin/HEAD >/dev/null 2>&1; then
  git rev-parse refs/remotes/origin/HEAD >"$AGY_CAPTURE_ORIGIN_HEAD"
fi
cp "$AGY_FIXTURE_LOG" "$log_file"
# Real agy logs the model the backend was actually given, so the fixture has to answer for the
# model it was asked for; AGY_FIXTURE_LABEL forces the substitution the runner must fail closed on.
if [ -n "${AGY_FIXTURE_LABEL:-}" ]; then
  label=$AGY_FIXTURE_LABEL
else
  case "$model" in
    "Gemini "*) label=$model ;;
    gemini-3.5-flash-*) label="Gemini 3.5 Flash ($(printf '%s' "${model##*-}" | awk '{print toupper(substr($0,1,1)) substr($0,2)}'))" ;;
    gemini-3.6-flash) label="Gemini 3.6 Flash ($(printf '%s' "$effort" | awk '{print toupper(substr($0,1,1)) substr($0,2)}'))" ;;
    *) label=$model ;;
  esac
fi
if [ -n "$label" ] && [ -n "$log_file" ]; then
  grep -v 'Propagating selected model override' "$log_file" >"$log_file.tmp"
  mv "$log_file.tmp" "$log_file"
  printf 'I0724 01:11:41.000000 model_config_manager.go:272] Propagating selected model override to backend: label="%s"\n' \
    "$label" >>"$log_file"
fi
cat "$AGY_FIXTURE_STDOUT"
if [ -n "${AGY_FIXTURE_STDERR:-}" ]; then
  cat "$AGY_FIXTURE_STDERR" >&2
fi
exit "${AGY_FIXTURE_RC:-0}"
