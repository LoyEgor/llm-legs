research_duration_seconds() {
  case "$1" in
    *[smh]) local n=${1%?} unit=${1: -1}; [[ "$n" =~ ^[0-9]+$ ]] || return 1
      case "$unit" in s) printf '%s\n' "$((10#$n))" ;; m) printf '%s\n' "$((10#$n * 60))" ;; h) printf '%s\n' "$((10#$n * 3600))" ;; esac ;;
    *) [[ "$1" =~ ^[0-9]+$ ]] || return 1; printf '%s\n' "$((10#$1))" ;;
  esac
}

resolve_path() {
  if [ -e "$1" ]; then readlink -f "$1"; else printf '%s\n' "$1"; fi
}

research_sandbox_profile() {
  local path resolved escaped profile_home
  local -a writable
  writable=()
  if [ "$account" != main ]; then
    profile_home=$(readlink -f "$(gemini_account_home "$account")") || return 1
    writable+=("$profile_home")
  fi
  mkdir -p "${GEMINIB_CACHE_DIR:-$HOME/.cache/geminib}" 2>/dev/null || :
  writable+=("$HOME/.gemini" "${GEMINIB_CACHE_DIR:-$HOME/.cache/geminib}" "${TMPDIR:-/tmp}" /private/tmp
    "$(getconf DARWIN_USER_TEMP_DIR)" "$(getconf DARWIN_USER_CACHE_DIR)" "$directory")
  printf '(version 1)\n(allow default)\n(deny file-write*)\n'
  for path in "${writable[@]}"; do
    [ -n "$path" ] || return 1
    resolved=$(resolve_path "$path") || return 1
    escaped=${resolved//\\/\\\\}; escaped=${escaped//\"/\\\"}
    escaped=${escaped//$'\n'/\\n}; escaped=${escaped//$'\r'/\\r}
    printf '(allow file-write* (subpath "%s"))\n' "$escaped"
  done
  printf '(allow file-write* (literal "/dev/null") (literal "/dev/tty") (literal "/dev/stdin") (literal "/dev/stdout") (literal "/dev/stderr"))\n'
  # A checkout inside an allowed temp root must still be read-only.
  for path in "${resolved_repos[@]}" "$HOME/.claude"; do
    resolved=$(resolve_path "$path") || return 1
    escaped=${resolved//\\/\\\\}; escaped=${escaped//\"/\\\"}
    escaped=${escaped//$'\n'/\\n}; escaped=${escaped//$'\r'/\\r}
    printf '(deny file-write* (subpath "%s"))\n' "$escaped"
  done
}

research_failure() {
  printf '%s\n' "$2" >"$1/research-outcome"
  return "$3"
}

supervise_gemini_research() {
  local directory="$1" meta="$1/meta.json" account cli profile sandbox_exec timeout_value rc=0
  local -a resolved_repos command
  account=$(jq -r .account "$meta")
  cli=$(jq -r .cli "$meta")
  timeout_value=$(jq -r .research_timeout "$meta")
  sandbox_exec=$(jq -r .sandbox_exec "$meta")
  REPLY_ARRAY=()
  read_json_array '.add_dirs[]' "$meta"
  resolved_repos=("$(jq -r .workdir "$meta")" "${REPLY_ARRAY[@]}")
  profile=$(research_sandbox_profile) || {
    printf 'gemini-research: could not resolve sandbox write paths\n' >"$directory/err"
    research_failure "$directory" GEMINI_UNAVAILABLE 4; return $?
  }
  printf '%s\n' "$profile" >"$directory/sandbox.sb"
  if [ ! -x "$sandbox_exec" ] || ! "$sandbox_exec" -p "$profile" /usr/bin/true 2>"$directory/err"; then
    printf 'gemini-research: sandbox-exec unavailable or refused profile\n' >>"$directory/err"
    research_failure "$directory" GEMINI_UNAVAILABLE 4; return $?
  fi
  mkdir -p "$directory/scratch" || return 4
  command=("$cli" profile "$account" --model "$(jq -r .agy_model "$meta")")
  for repo in "${resolved_repos[@]}"; do command+=(--add-dir "$repo"); done
  command+=(--print-timeout "$timeout_value" --dangerously-skip-permissions --log-file "$directory/log"
    --print "$(cat "$directory/brief.launch")")
  # Not a `( cd … && … )` subshell: run_with_deadline installs the supervisor's TERM/INT traps in
  # the shell that calls it, and inside a subshell a signal aimed at the run leaves the sandboxed
  # CLI orphaned.
  local previous_directory=$PWD
  cd "$directory/scratch" || { research_failure "$directory" GEMINI_UNAVAILABLE 4; return $?; }
  run_with_deadline "$sandbox_exec" -p "$profile" "${command[@]}" \
    >"$directory/out" 2>"$directory/err" || rc=$?
  cd "$previous_directory" || return 4
  if grep -Eq '^sandbox-exec:' "$directory/err"; then
    research_failure "$directory" GEMINI_UNAVAILABLE 4; return $?
  fi
  if grep -Eiq 'Operation not permitted|sandbox[^[:cntrl:]]*deny' "$directory/err"; then
    research_failure "$directory" GEMINI_RESEARCH_WRITE_DENIED 5; return $?
  fi
  if [ "$rc" -ne 0 ] || [ ! -s "$directory/out" ]; then
    if grep -Eiq 'RESOURCE_EXHAUSTED|Individual quota reached|usage limit|quota[[:space:]_-]*(exhausted|exceeded|reached)|rate.?limit|rateLimiter|HTTP[[:space:]]+429|(^|[^[:alnum:]_.])429([^[:alnum:]_.]|$)' \
        "$directory/err" "$directory/out" "$directory/log"; then
      research_failure "$directory" GEMINI_USAGE_LIMIT 3; return $?
    fi
    [ "$rc" -ne 0 ] || rc=4
    research_failure "$directory" GEMINI_UNAVAILABLE "$rc"; return $?
  fi
  return 0
}
