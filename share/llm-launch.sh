# shellcheck shell=bash
# The one rule for every launcher of LLM chats: it starts only on Egor's own act, his click in the Doctors menu,
# his terminal, launchd (none sets an LLM's env), or his word recorded for the calling chat. A worker never
# launches. Incident 2026-10-20: a chat told to "fix through the doctor-fix flow" opened ~35 fixer sessions.
# Every call appends one row to the launched-by journal, ${LLM_LAUNCH_JOURNAL:-~/.cache/doctors/launches.jsonl}.

llm_launch_guard() { # sweep|update what -> 0 allowed; 1 refused, LLM_LAUNCH_REFUSED on stderr
  local family=$1 what=$2 sid=${CLAUDE_CODE_SESSION_ID:-} by=egor allowed=false word journal
  journal=${LLM_LAUNCH_JOURNAL:-$HOME/.cache/doctors/launches.jsonl}
  if [ -n "${WORKER_RUN_ID:-}" ]; then
    by=worker:$WORKER_RUN_ID
  elif [ -z "$sid" ] && [ -z "${CLAUDE_LAUNCHER_SESSION:-}" ]; then
    allowed=true
  else
    by=${sid:-$CLAUDE_LAUNCHER_SESSION}
    # His word is read only through words.sh (tests/test_word_door_single.sh); an empty sid matches nothing there.
    case $family in
      sweep) (. "${WORDS_LIB:-$HOME/.claude/hooks/lib/words.sh}" 2>/dev/null && words_span_on "$sid" >/dev/null &&
        [ "$(words_span_sweep "$sid")" = sweep ]) ;;
      update) (. "${WORDS_LIB:-$HOME/.claude/hooks/lib/words.sh}" 2>/dev/null &&
        words_grant_fresh "$sid" update >/dev/null) ;;
      *) false ;;
    esac && allowed=true
  fi
  mkdir -p "${journal%/*}" 2>/dev/null
  jq -nc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg what "$what" --arg by "$by" --argjson allowed "$allowed" \
    '{at: $at, what: $what, by: $by, allowed: $allowed}' >>"$journal" 2>/dev/null
  $allowed && return 0
  case $family in sweep) word=чистку ;; *) word=апдейт ;; esac
  printf "LLM_LAUNCH_REFUSED: %s starts only on Egor's own act: his click in the Doctors menu or his word «сделай %s» in this chat. Tell him so in one line; never start it another way.\n" \
    "$what" "$word" >&2
  return 1
}
