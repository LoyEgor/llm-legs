#!/usr/bin/env bash
set -u

log_file=
prompt=
profile=
while [ "$#" -gt 0 ]; do
  case "$1" in
    profile)
      profile=$2
      printf '%s' "$profile" >>"$GEMINIB_CAPTURE_PROFILE"
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
cat "$AGY_FIXTURE_STDOUT"
if [ -n "${AGY_FIXTURE_STDERR:-}" ]; then
  cat "$AGY_FIXTURE_STDERR" >&2
fi
exit "${AGY_FIXTURE_RC:-0}"
