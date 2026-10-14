# Sourceable twin of share/limit_hit.py: one line per threshold hit in ${LIMIT_HITS_LOG:-~/.cache/limits/hits.jsonl}.
# limit_hit NAME VALUE UNIT ACTION LOST WHERE [OBSERVED [USUAL]]; WHERE as in limit_hit.py

limit_hit_str() { # var value -> a JSON string, or null when empty
  local s=$2
  [ -n "$s" ] || { printf -v "$1" null; return 0; }
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/\\t}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}
  s=${s//[$'\001'-$'\037']/}
  printf -v "$1" '"%s"' "$s"
}

limit_hit_num() { # var value -> the value when it is a plain number, else null
  local re='^-?[0-9]+(\.[0-9]+)?$'
  if [[ ${2:-} =~ $re ]]; then printf -v "$1" '%s' "$2"; else printf -v "$1" null; fi
}

limit_hit_bytes() { local LC_ALL=C; limit_hit_n=${#1}; }

limit_hit_where() { # where -> limit_hit_at: `file:ANCHOR` becomes `file:N`, N the first line of the repo file holding ANCHOR
  local file=${1%%:*} anchor=${1#*:} root n
  limit_hit_at=$1
  case $anchor in *[!0-9]*) ;; *) return 0 ;; esac
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)
  [ "$file" != "$1" ] && [ -f "$root/$file" ] || return 0
  n=$(grep -n -m1 -F -- "$anchor" "$root/$file" 2>/dev/null) && limit_hit_at=$file:${n%%:*}
  return 0
}

limit_hit() {
  local name=$1 lost=${5:-} log=${LIMIT_HITS_LOG:-$HOME/.cache/limits/hits.jsonl} ts value observed usual
  local j_limit j_unit j_action j_lost j_where j_run j_session row tmp
  [ "$#" -ge 6 ] || { printf 'limit_hit: %s not journaled: needs NAME VALUE UNIT ACTION LOST WHERE\n' "${1:-?}" >&2; return 0; }
  case $name in *:*) ;; *) name=llm-legs:$name ;; esac
  [ "${#lost}" -le 600 ] || lost="${lost:0:597}..."
  ts=${EPOCHREALTIME:-}
  ts=${ts/,/.}
  [ -n "$ts" ] || ts=$(date +%s)
  limit_hit_num value "$2"; limit_hit_num observed "${7:-}"; limit_hit_num usual "${8:-}"
  limit_hit_str j_limit "$name"; limit_hit_str j_unit "$3"; limit_hit_str j_action "$4"
  limit_hit_where "$6"
  limit_hit_str j_lost "$lost"; limit_hit_str j_where "$limit_hit_at"
  limit_hit_str j_run "${WORKER_RUN_ID:-}"; limit_hit_str j_session "${CLAUDE_SESSION_ID:-}"
  [ "$j_lost" != null ] || j_lost='""'
  printf -v row '{"ts":%s,"limit":%s,"value":%s,"unit":%s,"observed":%s,"usual":%s,"action":%s,"lost":%s,"where":%s,"run":%s,"session":%s}' \
    "$ts" "$j_limit" "$value" "$j_unit" "$observed" "$usual" "$j_action" "$j_lost" "$j_where" "$j_run" "$j_session"
  {
    [ -d "${log%/*}" ] || mkdir -p "${log%/*}" || return 0
    # bash's printf writes in 1 KiB pieces, which a concurrent append splits; dd writes the row in one.
    limit_hit_bytes "$row"
    if [ "$limit_hit_n" -lt 1000 ]; then
      printf '%s\n' "$row" >>"$log"
    elif tmp=$(mktemp "$log.XXXXXX") && printf '%s\n' "$row" >"$tmp"; then
      dd if="$tmp" bs=1048576 2>/dev/null >>"$log"
      rm -f "$tmp"
    fi
  } 2>/dev/null || printf 'limit_hit: %s not journaled to %s\n' "$name" "$log" >&2
  return 0
}
