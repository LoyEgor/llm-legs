# Row `dk` of docs/shared-invariants.md; share/run-suites.sh sources it with --lib.
# A test may run under macOS bash 3.2 and pays this on every start: bash 3.2 and builtins only.

suite_journal_str() { # var value -> a JSON string, or null when empty
  local s=$2
  [ -n "$s" ] || { printf -v "$1" null; return 0; }
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/\\t}; s=${s//$'\n'/\\n}
  printf -v "$1" '"%s"' "$s"
}

suite_journal_ms() { # var [epoch-seconds] -> milliseconds now, or of the given whole seconds
  local t=${2:-${EPOCHREALTIME:-}}
  t=${t/,/.}
  case $t in
    '') printf -v "$1" '' ;;
    *.*) t=${t%"${t#*.???}"}; printf -v "$1" '%s' "$(( ${t%.*} * 1000 + 10#${t#*.} ))" ;;
    *) printf -v "$1" '%s' "$(( t * 1000 ))" ;;
  esac
}

suite_journal_secs() { printf -v "$1" '%d.%03d' "$(( $2 / 1000 ))" "$(( $2 % 1000 ))"; }

suite_journal_cpu_ms() { # var scratch-file [children] -> CPU ms of this shell and its children, or children only;
  # empty when unmeasured, and always under bash < 5.3 with no scratch file
  local shell_user shell_sys user sys t s ms=0
  printf -v "$1" ''
  # bash 5.3 captures without a fork; eval keeps the syntax from older parsers.
  if (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 3) )); then
    eval 't=${ times; }'
    read -r shell_user shell_sys user sys <<<"${t//$'\n'/ }"
  else
    [ -n "$2" ] || return 0
    times >"$2" 2>/dev/null || return 0
    { read -r shell_user shell_sys; read -r user sys; } <"$2"
    rm -f "$2"
  fi
  [ -z "${3:-}" ] || shell_user='' shell_sys=''
  for t in $shell_user $shell_sys $user $sys; do
    t=${t/,/.} t=${t%s} s=${t#*m}
    [[ $t =~ ^[0-9]+m[0-9]+\.[0-9]{3}$ ]] || return 0
    ms=$(( ms + 10#${t%m*} * 60000 + 10#${s%.*} * 1000 + 10#${s#*.} ))
  done
  printf -v "$1" '%s' "$ms"
}

suite_journal_cpu() { # var scratch-file [children] -> CPU seconds of this shell and its children, or children only
  local journal_ms
  suite_journal_cpu_ms journal_ms "$2" "${3:-}"
  printf -v "$1" ''
  [ -z "${journal_ms:-}" ] || suite_journal_secs "$1" "$journal_ms"
}

suite_journal_git() { # checkout -> suite_journal_head, and suite_journal_root: the main checkout
  local git=$1/.git common line sha name
  suite_journal_head='' suite_journal_root=$1
  if [ -f "$git" ]; then
    read -r line <"$git" || return 0
    git=${line#gitdir: }
    case $git in /*) ;; *) git=$1/$git ;; esac
  fi
  [ -r "$git/HEAD" ] && read -r line <"$git/HEAD" || return 0
  common=$git
  case $git in */.git/worktrees/*) common=${git%/worktrees/*} ;; esac
  case $common in */.git) suite_journal_root=${common%/.git} ;; esac
  sha=$line
  case $line in
    'ref: '*)
      line=${line#ref: } sha=''
      if [ -r "$git/$line" ]; then read -r sha <"$git/$line"
      elif [ -r "$common/$line" ]; then read -r sha <"$common/$line"
      elif [ -r "$common/packed-refs" ]; then
        while read -r sha name; do [ "$name" = "$line" ] && break; sha=''; done <"$common/packed-refs"
      fi ;;
  esac
  [[ $sha =~ ^[0-9a-f]{40}$ ]] && suite_journal_head=$sha
  return 0
}

suite_journal_digest() { # suite-name... in sorted order -> suite_journal_set
  local h=5381 s i c
  for s in "$@"; do
    for ((i = 0; i < ${#s}; i++)); do printf -v c '%d' "'${s:i:1}"; h=$(( (h * 33 + c) & 4294967295 )); done
    h=$(( (h * 33 + 10) & 4294967295 ))
  done
  printf -v suite_journal_set '%08x' "$h"
}

suite_journal_suite() { # name rc secs cpu-secs [wall-bound] -> appended to suite_journal_suites
  local name
  suite_journal_str name "$1"
  suite_journal_suites="${suite_journal_suites:+$suite_journal_suites,}$name:{\"rc\":$2,\"secs\":$3,\"cpu_s\":${4:-null},\"forks\":null${5:+,\"bound\":$5}}"
}

# kind pid queued started ended repo repo-root head scope worker-run session j slot signal complete [skipped-slow names [reason]]
suite_journal_row() {
  local repo root head scope run session slot reason skipped='' name
  suite_journal_str repo "$6"; suite_journal_str root "$7"; suite_journal_str head "$8"
  suite_journal_str scope "$9"; suite_journal_str run "${10}"; suite_journal_str session "${11}"
  suite_journal_str slot "${13}"; suite_journal_str reason "${17:-}"
  for name in ${16:-}; do suite_journal_str name "$name"; skipped="${skipped:+$skipped,}$name"; done
  printf -v suite_journal_line '{"kind":"%s","pid":%s,"queued_at":%s,"started_at":%s,"ended_at":%s,"repo":%s,"repo_root":%s,"head":%s,"scope":%s,"suite_set":"%s","worker_run":%s,"session":%s,"j":%s,"slot":%s,"signal":%s,"complete":%s%s%s,"suites":{%s}}' \
    "$1" "$2" "$3" "$4" "$5" "$repo" "$root" "$head" "$scope" "$suite_journal_set" "$run" "$session" \
    "${12}" "$slot" "${14:-null}" "${15}" "${16:+,\"skipped_slow\":[$skipped]}" "${17:+,\"reason\":$reason}" "${suite_journal_suites:-}"
}

suite_journal_append() { # journal -> appends suite_journal_line
  local LC_ALL=C
  [ -d "${1%/*}" ] || mkdir -p "${1%/*}" 2>/dev/null || return 0
  # bash's printf writes in 1 KiB pieces, which a concurrent append splits; dd writes the row in one.
  # LC_ALL=C makes the length count bytes, not characters.
  if [ "${#suite_journal_line}" -lt 1000 ]; then
    printf '%s\n' "$suite_journal_line" >>"$1" 2>/dev/null
  elif printf '%s\n' "$suite_journal_line" >"$1.$$.row" 2>/dev/null; then
    dd if="$1.$$.row" bs=1048576 2>/dev/null >>"$1"
    rm -f "$1.$$.row"
  fi
  return 0
}

[ "${1:-}" != --lib ] || return 0
[ -z "${SUITE_JOURNAL_PID:-}" ] || return 0
export SUITE_JOURNAL_PID=$$
suite_journal_file=${SUITE_JOURNAL:-${RUN_SUITES_JOURNAL:-${XDG_CACHE_HOME:-$HOME/.cache}/run-suites/runs.jsonl}}
suite_journal_ms suite_journal_began
suite_journal_test=${BASH_SOURCE[1]:-$0}
case $suite_journal_test in /*) ;; *) suite_journal_test=$PWD/${suite_journal_test#./} ;; esac
suite_journal_repo=${suite_journal_test%/*}
suite_journal_repo=${suite_journal_repo%/tests}
suite_journal_old=${OLDPWD-} suite_journal_here=$PWD
if cd -P -- "$suite_journal_repo" 2>/dev/null; then suite_journal_repo=$PWD; cd -- "$suite_journal_here"; fi
OLDPWD=$suite_journal_old
suite_journal_level=${BASH_SUBSHELL:-0}
suite_journal_session=${CLAUDE_CODE_SESSION_ID:-${CLAUDE_LAUNCHER_SESSION:-}}
suite_journal_run=${WORKER_RUN_ID:-}
suite_journal_signal='' suite_journal_exit=''

suite_journal_end() { # exit-code -> returns it
  [ -z "${suite_journal_done:-}" ] && [ "${BASHPID:-$$}" = "$$" ] || return "$1"
  suite_journal_done=1
  local rc=$1 flags=$- name=${suite_journal_test##*/} ended secs cpu began complete=true
  set +eu
  [ -d "${suite_journal_file%/*}" ] || mkdir -p "${suite_journal_file%/*}" 2>/dev/null
  suite_journal_ms ended
  [ -n "$ended" ] || suite_journal_ms ended "$(date +%s)"
  [ -n "$suite_journal_began" ] || suite_journal_began=$(( ended - SECONDS * 1000 ))
  suite_journal_cpu cpu "$suite_journal_file.$$.times"
  [ -z "$suite_journal_signal" ] || { rc=$(( 128 + suite_journal_signal )); complete=false; }
  suite_journal_git "$suite_journal_repo"
  suite_journal_digest "$name"
  suite_journal_secs secs "$(( ended - suite_journal_began ))"
  suite_journal_suites=''
  suite_journal_suite "$name" "$rc" "$secs" "$cpu"
  suite_journal_secs began "$suite_journal_began"
  suite_journal_secs ended "$ended"
  suite_journal_row direct "$$" "$began" "$began" "$ended" "$suite_journal_repo" "$suite_journal_root" \
    "$suite_journal_head" direct "$suite_journal_run" "$suite_journal_session" 1 '' "$suite_journal_signal" "$complete"
  suite_journal_append "$suite_journal_file"
  case $flags in *e*) set -e ;; esac
  case $flags in *u*) set -u ;; esac
  return "$1"
}

suite_journal_die() { # signal-number: journal, run the test's EXIT action, then die of the signal
  suite_journal_signal=$1
  builtin trap - EXIT
  suite_journal_end "$(( 128 + $1 ))" && :
  eval "$suite_journal_exit"
  builtin trap - "$1"
  kill -"$1" "$$"
}

trap() {
  if [ "$#" -lt 2 ] || [ "${BASH_SUBSHELL:-0}" != "$suite_journal_level" ] || [ "${BASHPID:-$$}" != "$$" ]; then
    builtin trap "$@"
    return
  fi
  case $1 in -p|-l) builtin trap "$@"; return ;; --) shift ;; esac
  local action=$1 sig number
  shift
  for sig in "$@"; do
    case $sig in
      EXIT|SIGEXIT|0)
        suite_journal_exit=$action
        [ "$action" != - ] || suite_journal_exit=''
        [ -n "$suite_journal_exit" ] || { builtin trap 'suite_journal_end $?' EXIT; continue; }
        # `&& :` keeps set -e from ending the trap before the test's own cleanup when the run failed.
        builtin trap -- "suite_journal_end \$? && :; $action" EXIT; continue ;;
      HUP|SIGHUP|1) number=1 ;;
      INT|SIGINT|2) number=2 ;;
      TERM|SIGTERM|15) number=15 ;;
      *) number='' ;;
    esac
    if [ -n "$number" ] && [ "$action" = - ]; then builtin trap -- "suite_journal_die $number" "$sig"
    elif [ -z "$number" ] || [ -z "$action" ]; then builtin trap -- "$action" "$sig"
    else builtin trap -- "suite_journal_mark $number \$?; $action" "$sig"
    fi
  done
}
suite_journal_mark() { # signal-number status -> returns status, so the test's own action still reads its $?
  suite_journal_signal=$1
  return "$2"
}
builtin trap 'suite_journal_end $?' EXIT
builtin trap 'suite_journal_die 1' HUP
builtin trap 'suite_journal_die 2' INT
builtin trap 'suite_journal_die 15' TERM
