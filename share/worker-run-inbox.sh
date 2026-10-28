# worker-run, `worker-run say` and the inbox carry; sourced by bin/worker-run in place, so an edit here runs
# its own suites rather than every suite of worker-run (Egor 2026-10-23, 2026-10-28).

say_run() {
  local directory vendor mode line end at waited=0 owner entry
  local -a live=()
  case "${@: -1}" in -*[[:space:]]*) ;; -*) usage ;; esac
  if [ "$#" -eq 1 ] && [ -n "$1" ]; then
    owner=${CLAUDE_LAUNCHER_SESSION:-${CLAUDE_CODE_SESSION_ID:-}}
    [ -z "$owner" ] || while IFS= read -r entry; do
      directory=${entry%/launcher}
      ! run_live "$directory" || live+=("$directory")
    done < <(refuse_live_matches "$owner" "${WORKER_RUN_DIR:-$HOME/.cache/claude-worker-runs}" launcher)
    [ "${#live[@]}" -gt 0 ] || fail 'no live worker run of this chat: nothing was sent.'
    if [ "${#live[@]}" -gt 1 ]; then
      for directory in "${live[@]}"; do
        printf '%s  %s  %s\n' "${directory##*/}" "$(head -c 80 "$directory/tag" 2>/dev/null | head -n1)" \
          "$(head -n1 "$directory/brief" 2>/dev/null | cut -c1-60)" >&2
      done
      fail "${#live[@]} live worker runs of this chat: name one, \`worker-run say <run-id> <text>\`. Nothing was sent."
    fi
    set -- "${live[0]##*/}" "$1"
  fi
  [ "$#" -eq 2 ] && [ -n "$2" ] || usage
  directory=$(run_path "$1")
  [ -r "$directory/meta.json" ] || fail "unknown run: $1"
  run_live "$directory" ||
    fail "run $1 has finished and nothing reads its inbox any more: put the message into the next brief, \`RESUME $(session_id "$directory"):\` for the same session. Nothing was sent."
  vendor=$(jq -r '.vendor' "$directory/meta.json")
  mode=$(inbox_mode "$directory")
  line=$(jq -cn --arg at "$(inbox_now)" --arg by "${CLAUDE_LAUNCHER_SESSION:-${CLAUDE_CODE_SESSION_ID:-${USER:-?}}}" \
    --arg text "$2" '{at: $at, by: $by, text: $text}') || fail 'could not encode the message. Nothing was sent.'
  with_lock "$directory" inbox_append "$directory" "$line" || fail "could not write $directory/inbox. Nothing was sent."
  end=$INBOX_APPENDED_END
  if [ "$mode" = hook ]; then
    while :; do
      at=$(inbox_delivered_at "$directory" "$end")
      [ -z "$at" ] || { printf 'delivered at %s\n' "$at"; return 0; }
      [ "$waited" -lt $((${WORKER_RUN_SAY_WAIT_S:-2} * 10)) ] || break
      sleep 0.1
      waited=$((waited + 1))
    done
  fi
  inbox_queued_text "$vendor" "$mode" true
}

inbox_lines() { # directory
  [ -s "$1/inbox" ] || return 0
  local vendor live=false
  vendor=$(jq -r '.vendor' "$1/meta.json")
  ! run_live "$1" || live=true
  inbox_states "$1" "$(inbox_queued_text "$vendor" "$(inbox_mode "$1")" "$live")"
}

inbox_carry_from() { # prior-directory directory
  inbox_pending "$1" || return 0
  { inbox_context "$INBOX_TAKEN" && printf '\n'; } >>"$2/inbox-carried" &&
    INBOX_CARRIES+=("$INBOX_END"$'\t'"$1")
}

# Only once the resumed run has a supervisor: a start failing earlier would leave the messages
# reported as delivered to a run that never launched, and the next RESUME with nothing to carry.
inbox_carry_commit() { # directory
  local entry
  for entry in ${INBOX_CARRIES[@]+"${INBOX_CARRIES[@]}"}; do
    with_lock "${entry#*$'\t'}" inbox_record "${entry#*$'\t'}" "${entry%%$'\t'*}" "resume:${1##*/}"
  done
  INBOX_CARRIES=()
}

inbox_carry_resume() { # directory session
  local entry prior
  while IFS= read -r entry; do
    prior=${entry%/worker-session}
    [ "$prior" != "$1" ] && [ -s "$prior/inbox" ] || continue
    with_lock "$prior" inbox_carry_from "$prior" "$1"
  done < <(refuse_live_matches "$2" "${1%/*}" worker-session)
}
