#!/usr/bin/env bash
# Stands in for worker-pick's machine mode, and rejects what the real one rejects so a test
# cannot pass on argv the production tool would refuse.
[ "${1:-}" = --account ] || exit 2
vendor=${2:-}
case "$vendor" in claudeb|codex|gemini) ;; *) exit 2 ;; esac
shift 2
excluded=""
role=workers
fable=false
while [ "$#" -gt 0 ]; do
  case $1 in
    --exclude) [ "$#" -ge 2 ] || exit 2; excluded=$2; shift 2 ;;
    --role)
      [ "$#" -ge 2 ] || exit 2
      case $2 in workers|reviewers) ;; *) exit 2 ;; esac
      role=$2
      shift 2
      ;;
    --fable) fable=true; shift ;;
    *) exit 2 ;;
  esac
done
[ "$fable" = true ] && [ "$vendor" != claudeb ] && exit 2
if [ -n "${WORKER_PICK_CONFIG_FILE:-}" ] &&
   grep -qx "${vendor}_${role}=off" "$WORKER_PICK_CONFIG_FILE" 2>/dev/null; then
  printf 'worker-pick: %s is switched off for %s\n' "$vendor" "$role" >&2
  exit 3
fi
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
