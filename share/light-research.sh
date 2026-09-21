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

# `--cwd` is the whole of grok's directory grant (worker-run refuses --add-dir there), so a
# question over several repositories becomes one run per repository instead of one run over all.
research_fans_out_per_repo() { [ "$1" = grok ]; }

LIGHT_RESEARCH_CONTRACT='ANSWER CONTRACT (appended by light-research; the answer is checked mechanically):
Write every factual claim as ONE line of its own, in this shape:
  <path>:<line> | "exact quoted text" | <the claim>
<path> is absolute or relative to a repository root this run was given, <line> is the line the quote
starts on, and the quoted text must appear verbatim within three lines of it. A citation line whose
quote is not there is moved into an UNVERIFIED block and counts against the answer. Prose that
carries no claim needs no citation line, and a closed yes/no answer may carry none at all.'

research_citation_normalise() {
  local text
  text=$(tr '\n' ' ' <<<"$1" | tr -s '[:space:]' ' ')
  text=${text# }
  printf '%s' "${text% }"
}

research_citation_verify() { # path line quote repo-root...
  local path=$1 number=$2 quote=$3 root from to window
  local -a files=()
  shift 3
  for root in "$@"; do
    root=$(resolve_path "$root") || continue
    if [[ "$path" = /* ]]; then from=$path; else from="$root/$path"; fi
    [ -f "$from" ] || continue
    from=$(resolve_path "$from") || continue
    case "$from" in "$root"/*) files+=("$from") ;; esac
  done
  [ "${#files[@]}" -gt 0 ] || return 1
  from=$((10#$number - 3))
  [ "$from" -ge 1 ] || from=1
  to=$((10#$number + 3))
  quote=$(research_citation_normalise "$quote")
  [ -n "$quote" ] || return 1
  for root in "${files[@]}"; do
    window=$(sed -n "${from},${to}p" "$root") || continue
    case "$(research_citation_normalise "$window")" in
      *"$quote"*) return 0 ;;
    esac
  done
  return 1
}

research_citation_check() { # answer-file out-file repo-root... ; prints `<verified> <total>`
  local answer=$1 destination=$2 line path number quote ok=0 total=0
  local citation='^[[:space:]]*[-*]?[[:space:]]*([^|]+):([0-9]+)[[:space:]]*\|[[:space:]]*"(.*)"[[:space:]]*\|(.*)$'
  local -a kept=() failed=()
  shift 2
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ $citation ]]; then
      path=${BASH_REMATCH[1]}
      path=${path#"${path%%[![:space:]]*}"}
      path=${path%"${path##*[![:space:]]}"}
      number=${BASH_REMATCH[2]}
      quote=${BASH_REMATCH[3]}
      total=$((total + 1))
      if research_citation_verify "$path" "$number" "$quote" "$@"; then
        ok=$((ok + 1))
        kept+=("$line")
      else
        failed+=("$line")
      fi
    else
      kept+=("$line")
    fi
  done <"$answer"
  {
    printf 'CITATIONS: %s/%s\n' "$ok" "$total"
    [ "${#kept[@]}" -eq 0 ] || printf '%s\n' "${kept[@]}"
    if [ "${#failed[@]}" -gt 0 ]; then
      printf '\nUNVERIFIED:\n'
      printf '%s\n' "${failed[@]}"
    fi
  } >"$destination" || return 1
  printf '%s %s\n' "$ok" "$total"
}

research_sandbox_profile() {
  local path resolved escaped profile_home mode=${1:-research}
  local -a writable
  writable=()
  if [ "$mode" = light ]; then
    shift
    writable=("$@")
  else
    if [ "$account" != main ]; then
      profile_home=$(readlink -f "$(gemini_account_home "$account")") || return 1
      writable+=("$profile_home")
    fi
    mkdir -p "${GEMINIB_CACHE_DIR:-$HOME/.cache/geminib}" 2>/dev/null || :
    writable+=("$HOME/.gemini" "${GEMINIB_CACHE_DIR:-$HOME/.cache/geminib}" "${TMPDIR:-/tmp}" /private/tmp
      "$(getconf DARWIN_USER_TEMP_DIR)" "$(getconf DARWIN_USER_CACHE_DIR)" "$directory")
  fi
  printf '(version 1)\n(allow default)\n(deny file-write*)\n'
  for path in "${writable[@]}"; do
    [ -n "$path" ] || return 1
    resolved=$(resolve_path "$path") || return 1
    escaped=${resolved//\\/\\\\}; escaped=${escaped//\"/\\\"}
    escaped=${escaped//$'\n'/\\n}; escaped=${escaped//$'\r'/\\r}
    printf '(allow file-write* (subpath "%s"))\n' "$escaped"
  done
  printf '(allow file-write* (literal "/dev/null") (literal "/dev/tty") (literal "/dev/stdin") (literal "/dev/stdout") (literal "/dev/stderr"))\n'
  [ "$mode" != light ] || return 0
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
    printf 'light-research: could not resolve sandbox write paths\n' >"$directory/err"
    research_failure "$directory" GEMINI_UNAVAILABLE 4; return $?
  }
  printf '%s\n' "$profile" >"$directory/sandbox.sb"
  if [ ! -x "$sandbox_exec" ] || ! "$sandbox_exec" -p "$profile" /usr/bin/true 2>"$directory/err"; then
    printf 'light-research: sandbox-exec unavailable or refused profile\n' >>"$directory/err"
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
    research_failure "$directory" READ_ONLY_VIOLATION 5; return $?
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
