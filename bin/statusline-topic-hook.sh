#!/usr/bin/env bash

cache_dir="$HOME/.cache/claude-statusline"

file_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

atomic_write() {
  local dest="$1" content="$2" tmp
  mkdir -p "$cache_dir" 2>/dev/null || return 1
  tmp="$dest.tmp.$$"
  if printf '%s\n' "$content" > "$tmp" 2>/dev/null && mv -f "$tmp" "$dest" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

is_headless() {
  local snapshot pid
  if [ -n "${TOPIC_PS_SNAPSHOT:-}" ]; then
    snapshot=$(cat "$TOPIC_PS_SNAPSHOT" 2>/dev/null)
  else
    snapshot=$(ps -axo pid=,ppid=,command= 2>/dev/null)
  fi
  [ -n "$snapshot" ] || return 1
  pid="${TOPIC_ANCESTOR_START:-$PPID}"
  printf '%s\n' "$snapshot" | awk -v start="$pid" '
    { ppid[$1]=$2; line=$0; sub(/^[0-9]+[ \t]+[0-9]+[ \t]+/,"",line); cmd[$1]=line }
    END {
      pid=start; depth=0
      while (pid != "" && pid+0 > 1 && depth < 30) {
        c=cmd[pid]
        n=split(c, a, /[ \t]/); m=split(a[1], b, "/"); base=b[m]
        if (base == "claude" && (c ~ / -p( |$)/ || c ~ / --print( |$)/)) { exit 0 }
        pid=ppid[pid]; depth++
      }
      exit 1
    }'
}

generate_topic() {
  local sid="$1"
  local topic_file="$cache_dir/topic-$sid"
  local buf_file="$cache_dir/topic-$sid.buf"
  local lock="$cache_dir/topic-$sid.genlock"
  trap 'rmdir "$lock" 2>/dev/null' EXIT
  local buffer prev instructions raw reply len
  buffer=$(cat "$buf_file" 2>/dev/null)
  [ -n "$buffer" ] || return 0
  prev=""
  [ -s "$topic_file" ] && IFS= read -r prev < "$topic_file"
  [ -n "$prev" ] || prev="(none yet)"
  instructions="You maintain a short label naming what a developer's terminal chat session is broadly about; it is shown in a status line.
Previous topic: \"$prev\".
Recent user messages, oldest first:
$buffer

Output ONLY the chat topic, in Russian, 4 to 7 words, at a middle level of abstraction — the general work area, not the current micro-detail (for example \"работа с таймером меню\", never \"чиним отступ 5px\"). If the theme has not meaningfully shifted from the previous topic, output the previous topic verbatim. One line, no quotes, no markdown, no trailing punctuation."
  raw=$(CLAUDE_STATUSLINE_TOPIC_GEN=1 timeout 90 "$HOME/.local/bin/claudeb" --model haiku --no-session-persistence -p "$instructions" 2>/dev/null) || return 0
  reply=$(printf '%s' "$raw" | head -n1)
  reply="${reply#"${reply%%[![:space:]]*}"}"
  reply="${reply%"${reply##*[![:space:]]}"}"
  [ -n "$reply" ] || return 0
  printf '%s' "$reply" | LC_ALL=C grep -q '[]"`*_#[]' && return 0
  printf '%s' "$reply" | grep -q "'" && return 0
  len=$(printf '%s' "$reply" | LC_ALL=en_US.UTF-8 wc -m 2>/dev/null | tr -d ' ')
  [[ "$len" =~ ^[0-9]+$ ]] || len=${#reply}
  [ "$len" -le 60 ] || return 0
  atomic_write "$topic_file" "$reply"
}

prune() {
  local marker="$cache_dir/.topic-prune" now m
  now=$(date +%s 2>/dev/null)
  [[ "$now" =~ ^[0-9]+$ ]] || return 0
  m=$(file_mtime "$marker" 2>/dev/null || printf '0')
  [[ "$m" =~ ^[0-9]+$ ]] || m=0
  if [ "$((now - m))" -gt 3600 ]; then
    find "$cache_dir" -type f -name 'topic-*' -mtime +7 -delete 2>/dev/null
    touch "$marker" 2>/dev/null
  fi
}

if [ "${1:-}" = "--generate" ]; then
  [ -n "${2:-}" ] || exit 0
  generate_topic "$2"
  exit 0
fi

# UserPromptSubmit stdout is injected into the model's context, so discard all output.
exec >/dev/null 2>&1
input=$(cat) || exit 0
[ "${CLAUDE_STATUSLINE_TOPIC_GEN:-}" = 1 ] && exit 0

parsed=$(printf '%s' "$input" | jq -r '
  def value: if . == null then "" else tostring end;
  [ (.hook_event_name | value),
    (.source | value),
    ((.session_id // "") | tostring | gsub("[^A-Za-z0-9_-]"; "")),
    ((.prompt // "") | tostring | gsub("[\n\t\r]"; " ")) ]
  | join("")' 2>/dev/null) || exit 0
IFS=$'\x1f' read -r event source sid prompt <<< "$parsed"

if [ "$event" = SessionStart ]; then
  # clear wipes the transcript, so the topic must not survive it; resume/compact keep it.
  if [ "$source" = clear ] && [ -n "$sid" ]; then
    rm -f "$cache_dir/topic-$sid" "$cache_dir/topic-$sid.meta" "$cache_dir/topic-$sid.buf"
  fi
  exit 0
fi

[ "$event" = UserPromptSubmit ] || exit 0
[ -n "$sid" ] || exit 0
is_headless && exit 0

prompt="${prompt:0:500}"
prompt="${prompt#"${prompt%%[![:space:]]*}"}"
prompt="${prompt%"${prompt##*[![:space:]]}"}"
# Trivial acks ("ок", "продолжай") carry no theme and don't count toward regeneration.
[ "${#prompt}" -ge 15 ] || exit 0

buf_file="$cache_dir/topic-$sid.buf"
meta_file="$cache_dir/topic-$sid.meta"
topic_file="$cache_dir/topic-$sid"
mkdir -p "$cache_dir" 2>/dev/null || exit 0

{ [ -f "$buf_file" ] && cat "$buf_file"; printf '%s\n' "$prompt"; } | tail -n 8 > "$buf_file.tmp.$$" \
  && mv -f "$buf_file.tmp.$$" "$buf_file" || rm -f "$buf_file.tmp.$$" 2>/dev/null

last_gen=0; count=0
if [ -f "$meta_file" ]; then
  IFS=' ' read -r last_gen count < "$meta_file" 2>/dev/null
fi
[[ "$last_gen" =~ ^[0-9]+$ ]] || last_gen=0
[[ "$count" =~ ^[0-9]+$ ]] || count=0
count=$((count + 1))
now=$(date +%s)
has_topic=0; [ -s "$topic_file" ] && has_topic=1

do_gen=0
if [ "$has_topic" = 0 ] && [ "$count" -ge 1 ]; then do_gen=1
elif [ "$count" -ge 5 ]; then do_gen=1
elif [ "$last_gen" -gt 0 ] && [ "$((now - last_gen))" -ge 600 ] && [ "$count" -ge 2 ]; then do_gen=1
fi

if [ "$do_gen" = 1 ]; then
  lock="$cache_dir/topic-$sid.genlock"
  if mkdir "$lock" 2>/dev/null; then
    # Reset debounce state before generation returns, so a failed run doesn't respawn every prompt.
    atomic_write "$meta_file" "$now 0"
    ( "$0" --generate "$sid" >/dev/null 2>&1 </dev/null & )
  else
    lock_mtime=$(file_mtime "$lock")
    if [[ "$lock_mtime" =~ ^[0-9]+$ ]] && [ "$((now - lock_mtime))" -gt 180 ]; then
      rmdir "$lock" 2>/dev/null
    fi
    atomic_write "$meta_file" "$last_gen $count"
  fi
else
  atomic_write "$meta_file" "$last_gen $count"
fi

prune
exit 0
