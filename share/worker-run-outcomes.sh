# worker-run, outcome codes and their lines; sourced by bin/worker-run in place, so an edit here runs its own
# suites rather than every suite of worker-run (Egor 2026-10-23, 2026-10-28).

# llm-doctor reads the outcome back: beside the run when there is one, else from prelaunch.jsonl.
outcome_record() { # outcome [directory]
  local log="${WORKER_RUN_DIR:-$HOME/.cache/claude-worker-runs}/prelaunch.jsonl"
  if [ -n "${2:-}" ]; then
    [ ! -d "$2" ] || printf '%s\n' "$1" 2>/dev/null >"$2/outcome" || :
    return 0
  fi
  mkdir -p "${log%/*}" 2>/dev/null || return 0
  jq -cn --arg outcome "$1" --arg vendor "${vendor:-}" --arg account "${account:-${explicit_account:-}}" \
    --arg model "${model:-${effective:-}}" --arg role "${role:-}" --arg light "${light:-}" \
    '{ts: (now | floor), outcome: $outcome, vendor: $vendor, account: $account, model: $model,
      role: $role, light: $light}' 2>/dev/null >>"$log" || :
}

outcome_line() (
  local outcome="$1" report_directory="${2:-}" place_session
  printf 'OUTCOME: %s\n' "$outcome"
  outcome_record "$outcome" "$report_directory"
  if [ -n "$report_directory" ] && mkdir "$report_directory/.place-end" 2>/dev/null; then
    place_session=$(cat "$report_directory/launcher" 2>/dev/null)
    case "$place_session" in
      ''|_orphan|.|..|*[!A-Za-z0-9._-]*) ;;
      *)
        "$SCRIPT_DIRECTORY/statusline-place" add --session "$place_session" --kind worker-end \
          --path "$(jq -r '.workdir // empty' "$report_directory/meta.json" 2>/dev/null)" >/dev/null 2>&1 || : ;;
    esac
  fi
  return 0
)

failure_outcome() {
  case "$1" in
    claudeb) printf 'CLAUDEB_FAILED' ;;
    codex) printf 'CODEX_UNAVAILABLE' ;;
    gemini) printf 'GEMINI_UNAVAILABLE' ;;
    grok) printf 'GROK_UNAVAILABLE' ;;
  esac
}

has_limit_signature() {
  local directory="$1" vendor="$2" bytes="${3:-}" pattern tail_lines=0 path
  local -a scan
  if [ "$vendor" = codex ] && codex_unsupported_model "$directory" "$bytes"; then return 1; fi
  [ "$vendor" = grok ] || [ -s "$directory/err" ] || [ -s "$directory/out" ] || return 1
  if tail -c 4096 "$directory/err" 2>/dev/null |
     grep -Eq 'worker-pick: no selectable [a-z]+ account \([^)]*WALLED'; then return 0; fi
  # out holds the worker's ANSWER, which in this repo routinely discusses quotas
  # and 429s; vendor limit errors arrive on stderr (live-verified for agy and
  # codex). claudeb print mode can emit its limit error on stdout, so it keeps
  # both. The agy log mentions quota even on healthy runs — never scan it.
  case "$vendor" in
    # codex streams the whole session to stderr: the echoed brief plus every file
    # the worker reads. In this repo that text routinely carries "quota",
    # "usage_limit" and "CODEX_USAGE_LIMIT" (live-caught misverdicts), so bare
    # tokens cannot count and the scan sees only the tail, where the CLI's own
    # fatal error is.
    codex) pattern='hit your usage limit|usage limit (reached|exceeded)|usage_limit_reached|quota (exhausted|exceeded|reached)|rate limit (exceeded|reached)|too many requests|out of credits|402 Payment Required|deactivated_workspace'; scan=("$directory/err"); tail_lines=40
      # In-run a quiet tail is also a file just read followed by a long silent command, and that kill
      # takes a healthy run; the CLI states every wall as its own `ERROR: ` line (all live ones).
      [ -z "$bytes" ] || pattern="^ERROR: .*($pattern)" ;;
    claudeb) pattern='hit your session limit|hit your usage limit|usage limit|(^|[^0-9])429([^0-9]|$)'; scan=("$directory/out" "$directory/err") ;;
    gemini) pattern='RESOURCE_EXHAUSTED|Individual quota reached|credits balance is too low|usage limit|quota|rate.?limit|(^|[^0-9])429([^0-9]|$)'; scan=("$directory/err") ;;
    # grok states a failure in two places — stderr and the stream's own error events — so its text
    # is assembled rather than read from a file list.
    grok) grok_error_text "$directory" "$bytes" | grep -Eiq "$GROK_LIMIT_RE"; return ;;
  esac
  if [ -n "$bytes" ]; then
    for path in "${scan[@]}"; do
      if [ "$tail_lines" -gt 0 ]; then
        tail -c "$bytes" "$path" 2>/dev/null | tail -n "$tail_lines"
      else
        tail -c "$bytes" "$path" 2>/dev/null
      fi
    done | grep -Eiq "$pattern"
  elif [ "$tail_lines" -gt 0 ]; then
    tail -n "$tail_lines" "${scan[0]}" 2>/dev/null | grep -Eiq "$pattern"
  else
    grep -Eiq "$pattern" "${scan[@]}" 2>/dev/null
  fi
}

reroute_lines() {
  jq -r '. as $meta | ($meta.walled_accounts // []) | range(0; length) as $hop
         | "REROUTE: walled on \(.[$hop]) → continued on \(.[$hop + 1] // $meta.account)"' \
    "$1/meta.json" 2>/dev/null
}

# Which watchdog ended a run, where one did: a bare exit 143 reads as a vendor failure, and the two
# answers differ — an idle kill means the worker stopped writing and whatever it finished is on
# disk, the ceiling means it was still being served when the clock ran out.
killed_line() { # directory
  local reason
  reason=$(head -n1 "$1/killed" 2>/dev/null) || return 0
  case "$reason" in
    'silent '*) printf 'KILLED: silent — no output in %ss\n' "${reason#silent }" ;;
    wall) printf 'KILLED: wall — vendor usage limit detected\n' ;;
    term) printf 'KILLED: signal TERM — the supervisor was signalled and stopped the vendor child with it\n' ;;
    'idle '*) printf 'KILLED: idle watchdog — nothing this run writes changed for %ss (WORKER_RUN_IDLE_S)\n' "${reason#idle }" ;;
    'deadline '*) printf 'KILLED: deadline — the %ss ceiling ended a run still being served (WORKER_RUN_DEADLINE)\n' "${reason#deadline }" ;;
    'signal '*) printf 'KILLED: signal %s — the supervisor was signalled and stopped the vendor child with it\n' "${reason#signal }" ;;
  esac
}

print_outcome() {
  local directory="$1" vendor="$2" code="$3" reset
  # Signature scan only on failure: results in this ecosystem routinely DISCUSS
  # quotas and 429s, so a clean exit whose text mentions them is not a limit.
  if [ "$vendor" = grok ] && grok_cancelled_start "$directory"; then
    outcome_line "GROK_CANCELLED ${directory##*/}" "$directory"
    printf 'REASON: cancelled — grok ended the session before its first turn; capacity weather, not a wall: pause and relaunch once\n'
    return 0
  fi
  if [ "$code" = 0 ]; then killed_line "$directory"; outcome_line DONE "$directory" >/dev/null; return 0; fi
  if [ "$(jq -r '.role // "workers"' "$directory/meta.json" 2>/dev/null)" = research ] && [ -s "$directory/research-outcome" ]; then
    outcome_line "$(cat "$directory/research-outcome")" "$directory"
    return 0
  fi
  killed_line "$directory"
  if has_limit_signature "$directory" "$vendor"; then
    outcome_line "$(vendor_name "$vendor")_USAGE_LIMIT" "$directory"
    # The chat reads these lines as they are, so the wall's SCOPE lives here, not in prose.
    if [ "$vendor" = claudeb ] && jq -e '.browser == true' "$directory/meta.json" >/dev/null; then
      printf 'WALL: browser device stays on %s\n' "$(jq -r '.account' "$directory/meta.json")"
    elif [ -n "$(jq -r '.resume // empty' "$directory/meta.json" 2>/dev/null)" ]; then
      printf 'WALL: resumed session stays on %s\n' \
        "$(jq -r '.account' "$directory/meta.json" 2>/dev/null)"
    elif jq -e '.role == "research" and .explicit_account != ""' "$directory/meta.json" >/dev/null 2>&1; then
      printf 'WALL: explicit account stays on %s\n' "$(jq -r '.account' "$directory/meta.json" 2>/dev/null)"
    elif jq -e '(.walled_accounts // []) | length > 0' "$directory/meta.json" >/dev/null 2>&1; then
      printf 'WALL: reroute cap reached (walled: %s) — the work done so far stays in the workdir\n' \
        "$(jq -r '((.walled_accounts // []) + [.account]) | join(", ")' "$directory/meta.json" 2>/dev/null)"
    else
      printf 'WALL: pool exhausted (walled: %s)\n' \
        "$(jq -r '((.walled_accounts // []) + [.account]) | join(", ")' "$directory/meta.json" 2>/dev/null)"
    fi
    reset=$(worker_walls_extract_reset "$directory/out" "$directory/err")
    [ -z "$reset" ] || printf 'RESET: %s\n' "$reset"
  elif [ "$vendor" = grok ] && grok_max_turns_hit "$directory"; then
    outcome_line GROK_MAX_TURNS "$directory"
    grok_reason_line "$directory"
  elif case "$code" in 143|137) true ;; *) false ;; esac &&
    head -n1 "$directory/killed" 2>/dev/null | grep -Eq '^(term|signal )'; then
    outcome_line STOPPED "$directory"
  else
    outcome_line "$(failure_outcome "$vendor")" "$directory"
    case "$vendor" in grok) grok_reason_line "$directory" ;; esac
  fi
}
