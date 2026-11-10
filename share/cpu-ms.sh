# CPU of this shell from bash `times`, in ms. Sourced by tests/lib/suite-journal.sh (its suite_journal_* family)
# and by bin/statusline.sh's replay pass, which may not pay for parsing the whole journal library on every render.

suite_journal_cpu_ms() { # var scratch-file [children] -> CPU ms of this shell and its children, or children only;
  # empty when unmeasured, and always under bash < 5.3 with no scratch file
  local shell_user shell_sys user sys t
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
  suite_journal_times_ms "$1" $shell_user $shell_sys $user $sys
}

suite_journal_times_ms() { # var <`times` field>... -> their sum in ms; empty when one does not parse
  local times_var=$1 times_t times_s times_ms=0
  shift
  printf -v "$times_var" ''
  for times_t; do
    times_t=${times_t/,/.} times_t=${times_t%s} times_s=${times_t#*m}
    [[ $times_t =~ ^[0-9]+m[0-9]+\.[0-9]{3}$ ]] || return 0
    times_ms=$(( times_ms + 10#${times_t%m*} * 60000 + 10#${times_s%.*} * 1000 + 10#${times_s#*.} ))
  done
  printf -v "$times_var" '%s' "$times_ms"
}
