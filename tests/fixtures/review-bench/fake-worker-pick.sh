#!/usr/bin/env bash
# Stands in for worker-pick's machine mode, and rejects what the real one rejects so a test
# cannot pass on argv the production tool would refuse.
[ "${1:-}" = --account ] || exit 2
vendor=${2:-}
case "$vendor" in claudeb|codex|gemini) ;; *) exit 2 ;; esac
shift 2
excluded=""
fable=false
while [ "$#" -gt 0 ]; do
  case $1 in
    --exclude) [ "$#" -ge 2 ] || exit 2; excluded=$2; shift 2 ;;
    --fable) fable=true; shift ;;
    *) exit 2 ;;
  esac
done
[ "$fable" = true ] && [ "$vendor" != claudeb ] && exit 2
accounts=${WORKER_PICK_FAKE_ACCOUNTS:-work main}
[ "$fable" = true ] && accounts=${WORKER_PICK_FAKE_FABLE_ACCOUNTS-$accounts}
# Only claudeb has a session account, so only claudeb can answer with the reserve.
session=""
[ "$vendor" = claudeb ] && session=${WORKER_PICK_FAKE_SESSION:-}
for name in $accounts; do
  if [ -n "$session" ] && [ "$name" = "$session" ]; then continue; fi
  case ",$excluded," in *",$name,"*) continue ;; esac
  printf '%s\n' "$name"
  exit 0
done
if [ -n "$session" ]; then
  case ",$excluded," in
    *",$session,"*) ;;
    *)
      printf 'worker-pick: %s is the session account (SESSION RESERVE)\n' "$session" >&2
      printf '%s\n' "$session"
      exit 0
      ;;
  esac
fi
exit 3
