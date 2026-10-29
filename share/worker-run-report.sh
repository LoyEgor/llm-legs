# worker-run, run report; sourced by bin/worker-run in place, so an edit here runs its own suites rather than
# every suite of worker-run (Egor 2026-10-23, 2026-10-28).

# `wait` names the answer instead of quoting it: the chat reads `report` next in any case, and a tail
# here made every terminal wait hand the orchestrator the same result twice.
result_pointer() { # directory
  printf 'RESULT: run `worker-run report %s`\n' "${1##*/}"
}

# What memlogd's memory guard did to this run, off the record it left in the run dir. A worker whose
# children were SIGKILLed under memory pressure comes back with a torn transcript and a vendor error
# that names nothing, and the supervisor survived precisely so this line can be printed: without it
# the run reports a failure whose cause is only in a daemon log nobody reads. One line per kill,
# since a long run can be cut more than once.
# A result can promise a chain "still running" or "queued last" that end_run_orphans has already ended (live
# 2026-10-08, logo-vectorizer-bench: 31 traces of a done run never finished).
ended_orphans_line() { # directory
  jq -r '(.orphans_ended // []) | select(length > 0) | "ENDED: \(length) process\(if length == 1 then "" else "es" end) the run left running outside its tree, ended with it, so whatever they were still doing did not finish: \([.[].command] | unique | .[:3] | join(" · "))"' \
    "$1/meta.json" 2>/dev/null || :
}

memguard_lines() { # directory
  [ -s "$1/memguard" ] || return 0
  awk '$1 == "MEMGUARD" {
    avail = tree = pids = ""
    for (i = 2; i <= NF; i++) {
      if ($i ~ /^avail_mb=/) avail = substr($i, 10)
      else if ($i ~ /^tree_rss_mb=/) tree = substr($i, 13)
      else if ($i ~ /^killed=/) pids = substr($i, 8)
    }
    n = (pids == "" ? 0 : split(pids, list, ","))
    printf "MEMGUARD: %d descendant%s SIGKILLed under memory pressure (avail %s MB, tree %s MB); the run'"'"'s own root was spared\n", \
      n, (n == 1 ? "" : "s"), avail, tree
  }' "$1/memguard"
}

# A result written for Egor rather than for the model that has to read it. Stamped once, when the
# run's result lands, because the text is what is measured and `worker-run report` must say the same
# thing about it a week later; no re-ask follows — the vendors that cannot run a Stop hook are
# exactly the ones this flag is for.
stamp_result_language() { # directory
  local share
  [ -s "$1/result" ] || return 0
  [ ! -e "$1/lang" ] || return 0
  share=$(cyrillic_share <"$1/result") || return 0
  cyrillic_over "$share" || return 0
  printf 'cyrillic %s\n' "$share" >"$1/lang" 2>/dev/null || :
}

lang_line() { # directory
  local share
  share=$(sed -n 's/^cyrillic //p' "$1/lang" 2>/dev/null | head -n1)
  case "$share" in ''|*[!0-9]*) return 0 ;; esac
  printf 'LANG: cyrillic %s%%\n' "$share"
}

denied_tools_line() {
  local denied
  denied=$(jq -r '.denied_tools // empty' "$1/meta.json")
  [ -z "$denied" ] || printf 'DENIED-TOOLS: %s\n' "$denied"
}

# `done` is a run that finished its work, which exit 0 alone does not prove: a grok session the
# vendor cancelled before its first turn exits 0 with nothing in it. Both terminal reports read the
# status here so `wait` and `report` can never disagree about the same run.
terminal_status() { # directory vendor code
  [ "$3" = 0 ] || { printf 'failed\n'; return 0; }
  if [ "$2" = grok ] && grok_cancelled_start "$1"; then printf 'failed\n'; return 0; fi
  printf 'done\n'
}

# A cheap-model run that met a responsible decision ends with `ESCALATE: <reason>`; it cannot start a
# run itself, so its report hands the dispatcher the same brief, ready for the default model.
escalate_lines() { # directory vendor
  local reason brief="$1/escalate.brief.md"
  reason=$(run_result_text "$1" "$2" | sed -n 's/^ESCALATE:[[:space:]]*//p' | tail -n 1)
  [ -n "$reason" ] || return 0
  printf 'ESCALATE: %s\n' "$reason"
  [ -r "$1/brief" ] || return 0
  [ -s "$brief" ] || {
    awk '!cut && /^(MODEL|EFFORT):/ { next } !/^[A-Z][A-Z-]*:/ { cut = 1 } { print }' "$1/brief"
    printf '\nThe %s run on this brief escalated: %s. Its report: `%s report %s`; read it first.\n' \
      "$(jq -r '.model // "cheap-model"' "$1/meta.json" 2>/dev/null)" "$reason" "$SCRIPT_PATH" "$(basename "$1")"
  } >"$brief" 2>/dev/null
  printf 'ESCALATE-BRIEF: %s\n' "$brief"
}

terminal_report() {
  local directory="$1" code vendor status
  code=$(tr -d '[:space:]' <"$directory/exit_code")
  [[ "$code" =~ ^[0-9]+$ ]] || code=unknown
  vendor=$(jq -r '.vendor' "$directory/meta.json")
  status=$(terminal_status "$directory" "$vendor" "$code")
  printf 'STATUS: %s\nEXIT: %s\nSESSION: %s\n' "$status" "$code" "$(session_id "$directory")"
  reroute_lines "$directory"
  workdir_escape_line "$directory"
  memguard_lines "$directory"
  print_outcome "$directory" "$vendor" "$code"
  escalate_lines "$directory" "$vendor"
  denied_tools_line "$directory"
  lang_line "$directory"
  inbox_lines "$directory"
  unnamed_line "$directory"
  result_pointer "$directory"
  if [ "$code" != 0 ]; then
    printf 'ERR-TAIL:\n'
    tail -n 40 "$directory/err" 2>/dev/null
  fi
}

run_state_terminal() { # directory
  local code
  code=$(tr -d '[:space:]' <"$1/exit_code" 2>/dev/null)
  [[ "$code" =~ ^[0-9]+$ ]] || code=unknown
  write_run_state "$1" "$(terminal_status "$1" "$(jq -r '.vendor' "$1/meta.json" 2>/dev/null)" "$code")" "$code"
}

unknown_report() {
  local directory="$1" vendor
  vendor=$(jq -r '.vendor' "$directory/meta.json")
  printf 'STATUS: failed\nEXIT: unknown\nSESSION: %s\n' "$(session_id "$directory")"
  outcome_line "$(failure_outcome "$vendor")" "$directory"
  memguard_lines "$directory"
  denied_tools_line "$directory"
  result_pointer "$directory"
  printf 'ERR-TAIL:\n'
  tail -n 40 "$directory/err" 2>/dev/null
}

transcript_run() {
  [ "$#" -ge 1 ] || usage
  local directory run
  if [ "$#" -gt 1 ]; then
    for run; do printf '%s\n' "$( (transcript_run "$run") 2>/dev/null)"; done
    return 0
  fi
  directory=$(run_path "$1")
  [ -r "$directory/meta.json" ] || fail "unknown run: $1"
  session_transcript "$(jq -r '.vendor' "$directory/meta.json")" "$(jq -r '.account' "$directory/meta.json")" \
    "$(session_id "$directory")" "$(jq -r '.workdir // empty' "$directory/meta.json")" && printf '\n'
}

# Model, effort and thinking are Egor's alone; a chat may hold his word for a change, so this reports and never refuses.
outcome_with_knobs() { # directory command...
  local directory="$1" text knobs
  shift
  text=$("$@")
  knobs=$(python3 "$SCRIPT_DIRECTORY/../share/knobs.py" run "$directory" 2>/dev/null)
  if [ -n "$knobs" ] && [[ "$text" == *'OUTCOME: '* ]]; then
    AWK_KNOBS=$knobs awk '{ print } !done && /^OUTCOME: / { print ENVIRON["AWK_KNOBS"]; done = 1 }' <<<"$text"
    return 0
  fi
  [ -z "$text" ] || printf '%s\n' "$text"
  [ -z "$knobs" ] || printf '%s\n' "$knobs"
}

report_run() {
  [ "$#" -eq 1 ] || usage
  local directory vendor account code status cost s5_rate pid
  directory=$(run_path "$1")
  [ -d "$directory" ] && [ -r "$directory/meta.json" ] || fail "unknown run: $1"
  vendor=$(jq -r '.vendor' "$directory/meta.json")
  account=$(jq -r '.account' "$directory/meta.json")
  printf 'ACCOUNT: %s (%s)\n' "$account" "$vendor"
  jq -r '"MODEL: \(.model // "?")\(if (.effort // "") != "" then "·" + .effort else "" end)",
         (.served_model // empty | "SERVED: \(.)")' "$directory/meta.json" 2>/dev/null
  printf 'WEB: %s\n' "$(web_search_meta_state "$directory/meta.json")"
  reroute_lines "$directory"
  if [ -f "$directory/exit_code" ]; then
    code=$(tr -d '[:space:]' <"$directory/exit_code")
    [[ "$code" =~ ^[0-9]+$ ]] || code=unknown
    status=$(terminal_status "$directory" "$vendor" "$code")
    printf 'STATUS: %s\nEXIT: %s\nSESSION: %s\n' "$status" "$code" "$(session_id "$directory")"
    memguard_lines "$directory"
    outcome_with_knobs "$directory" print_outcome "$directory" "$vendor" "$code"
    ended_orphans_line "$directory"
    readonly_report_hint "$directory"
    escalate_lines "$directory" "$vendor"
    if [ "$code" != 0 ]; then
      printf 'ERR-TAIL:\n'
      tail -n 80 "$directory/err" 2>/dev/null
    fi
  else
    pid=$(jq -r '.pid' "$directory/meta.json")
    if supervisor_running "$directory" "$pid" && ! run_overdue "$directory"; then
      running_report "$directory"
    else
      printf 'STATUS: failed\nEXIT: unknown\nSESSION: %s\n' "$(session_id "$directory")"
      outcome_with_knobs "$directory" outcome_line "$(failure_outcome "$vendor")" "$directory"
      memguard_lines "$directory"
      printf 'ERR-TAIL:\n'
      tail -n 80 "$directory/err" 2>/dev/null
    fi
  fi
  denied_tools_line "$directory"
  lang_line "$directory"
  inbox_lines "$directory"
  if [ "$vendor" = claudeb ]; then
    cost=$(jq -r '.total_cost_usd // empty' "$directory/out" 2>/dev/null)
    # The $2/M base permanently defines one Sonnet-5-equivalent token; after the public rate
    # returns to $3/M, one Sonnet 5 token weighs 1.5 of these stable units.
    s5_rate=${WORKER_RUN_S5_USD_PER_M:-}
    LC_ALL=C awk -v n="$s5_rate" \
      'BEGIN { exit !(n ~ /^[+]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$/ && n > 0) }' \
      || s5_rate=2.0
    # LC_ALL=C: a comma-decimal locale reads 1.25 as 1 and understates the cost fivefold.
    # The k rung stops short of 999500 so that %.0f never rounds its way to "1000k".
    [ -z "$cost" ] || printf 'COST: %s\n' "$(LC_ALL=C awk -v c="$cost" -v r="$s5_rate" \
      'BEGIN { t = c * 1e6 / r
               if (t > 0 && t < 0.5) printf "<1 tok-eq"
               else if (t < 999.5) printf "%.0f tok-eq", t
               else if (t < 999500) printf "%.0fk tok-eq", t / 1e3
               else printf "%.1fM tok-eq", t / 1e6 }')"
  fi
  run_files "$directory"
  unnamed_line "$directory"
  printf 'RESULT:\n'
  if [ -n "$(run_result_text "$directory" "$vendor" | head -c 1)" ]; then
    run_result_text "$directory" "$vendor" | tail -n 400
  else
    last_messages "$directory"
  fi
}

# A run ended before its final answer (the deadline, a kill) still said where it stood: without its
# last messages the chat redoes hours that a RESUME of the session would continue.
last_messages() { # directory
  local directory="$1" vendor account workdir started transcript=''
  { IFS= read -r vendor; IFS= read -r account; IFS= read -r workdir; IFS= read -r started; } \
    < <(jq -r '.vendor, .account, .workdir, (.started_at // 0)' "$directory/meta.json" 2>/dev/null)
  [[ "$started" =~ ^[0-9]+$ ]] || started=0
  transcript=$(run_transcript "$directory" "$vendor" "$account" "$workdir" "$started") || return 0
  progress_rows "$vendor" "$transcript" "$started" 0 | sed -n 's/^» //p' | tail -n 3 |
    awk 'NR == 1 { print "(no final answer; the worker'"'"'s last messages:)" } { print }'
}

run_result_text() {
  if [ -f "$1/result" ]; then cat "$1/result"; return; fi
  case "$2" in
    claudeb)
      if [ "$(head -n1 "$1/killed" 2>/dev/null)" = finished ]; then claudeb_session_answer "$1"
      else jq -r '.result // empty' "$1/out" 2>/dev/null; fi ;;
    grok) grok_result_text "$1" ;;
    *) cat "$1/out" 2>/dev/null ;;
  esac
}

complete_run() {
  local directory="$1" code="$2" vendor run_status
  fold_run_anchors "$directory"
  vendor=$(jq -r .vendor "$directory/meta.json")
  if [ ! -f "$directory/result" ]; then
    if run_result_text "$directory" "$vendor" >"$directory/result.tmp.$$"; then
      mv -f "$directory/result.tmp.$$" "$directory/result"
    else
      rm -f "$directory/result.tmp.$$"
    fi
  fi
  browse_record "$directory" "$code" || :
  stamp_result_language "$directory"
  print_outcome "$directory" "$vendor" "$code"
  lang_line "$directory"
  run_status=$(terminal_status "$directory" "$vendor" "$code")
  write_run_state "$directory" "$run_status" "$code"
  journal_worker_run "$directory" "$run_status" "$code"
}
