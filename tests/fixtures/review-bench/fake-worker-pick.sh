#!/usr/bin/env bash
# Stands in for worker-pick's machine mode, and rejects what the real one rejects so a test
# cannot pass on argv the production tool would refuse.
[ "${1:-}" = --account ] || exit 2
case "${2:-}" in claudeb|codex|gemini) ;; *) exit 2 ;; esac
excluded=""
if [ "$#" -gt 2 ]; then
  [ "$#" -eq 4 ] && [ "$3" = --exclude ] || exit 2
  excluded=$4
fi
for name in ${WORKER_PICK_FAKE_ACCOUNTS:-work main}; do
  case ",$excluded," in *",$name,"*) continue ;; esac
  printf '%s\n' "$name"
  exit 0
done
exit 3
