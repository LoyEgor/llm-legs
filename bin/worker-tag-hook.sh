#!/usr/bin/env bash
# PreToolUse(Bash) inside a fork: prefixes the fork's `fork · <model> · <account>` tag, seeded by
# worker-spawn-hook.sh, onto every Bash description so the UI activity line names who is spending
# quota. Tag files are session-scoped so the subagent rows can surface the tag. Fail-open everywhere.
{
[ -r ~/.claude/hooks/lib/hook-time.sh ] && . ~/.claude/hooks/lib/hook-time.sh
set -u

IFS= read -r -d '' input || :
case $input in *'"agent_type"'*) ;; *) exit 0 ;; esac

fields=()
eval "fields=($(jq -rn '[inputs] | select(length == 1) | .[0]
  | [.hook_event_name, .agent_type, .agent_id, .session_id, .tool_input.description, .transcript_path]
  | select(all(.[]; type != "object" and type != "array"))
  | map(if . == null or . == false then "" elif type == "string" then . else tojson end) | @sh' <<<"$input" 2>/dev/null))"
[ "${#fields[@]}" = 6 ] || exit 0
[ "${fields[0]}" = PreToolUse ] && [ "${fields[1]}" = fork ] || exit 0
agent_type=fork
agent_id=$(printf '%s' "${fields[2]}" | tr -cd 'A-Za-z0-9_-')
[ -n "$agent_id" ] || exit 0
session_id=$(printf '%s' "${fields[3]}" | tr -cd 'A-Za-z0-9_-')
[ -n "$session_id" ] || session_id=_
description=${fields[4]}
transcript_path=${fields[5]}

cache_root="$HOME/.cache/claude-worker-tags"
cache_dir="$cache_root/$session_id"
tag_file="$cache_dir/$agent_id"

emit() { # description
  [ -n "$1" ] || exit 0
  printf '%s' "$input" | jq -c --arg description "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: (.tool_input | .description = $description)}}' 2>/dev/null
  exit 0
}

SEED_MAX_AGE_S=${WORKER_TAG_SEED_MAX_AGE_S:-600}
# The spawn's first prompt line is the one fact both the seed and the fork's own transcript carry; a
# hook payload names that transcript or its parent's plus agent_id.
agent_prompt_key() {
  local own first
  case "$transcript_path" in
    */subagents/*.jsonl) own=$transcript_path ;;
    *.jsonl) own="${transcript_path%.jsonl}/subagents/agent-$agent_id.jsonl" ;;
    *) return 0 ;;
  esac
  [ -r "$own" ] || return 0
  first=$(head -n 5 "$own" | jq -rR 'fromjson? | select(type == "object" and .type == "user") | .message.content
    | if type == "string" then . else ([.[]? | select(.type? == "text") | .text] | join("\n")) end' 2>/dev/null |
    sed -n '1s/^/k:/p')
  [ -z "$first" ] || printf '%s\n' "${first#k:}" | shasum -a 256 2>/dev/null | cut -c1-16
}
# An agent that knows its spawn key takes only the seed carrying that key, and a denied or cancelled
# spawn leaves its seed behind: an agent without a key takes only a fresh seed.
pick_seed() {
  local key seed seed_key mtime now
  key=$(agent_prompt_key)
  now=$(date +%s)
  while IFS= read -r seed; do
    [ -f "$seed" ] || continue
    seed_key=$(sed -n 's/^spawn=//p' "$seed" 2>/dev/null | head -n1)
    if [ -n "$key" ]; then
      [ "$key" = "$seed_key" ] && { printf '%s' "$seed"; return 0; }
      continue
    fi
    mtime=$(stat -f %m "$seed" 2>/dev/null || stat -c %Y "$seed" 2>/dev/null) || continue
    [ "$((now - mtime))" -le "$SEED_MAX_AGE_S" ] || continue
    printf '%s' "$seed"
    return 0
  done < <(ls -tr "$cache_dir/pending-$agent_type"-* 2>/dev/null)
}
tag_line() { local first; [ -f "$tag_file" ] && IFS= read -r first < "$tag_file" && printf '%s' "$first"; }
# Rewrites the tag file atomically: line one is the tag (kept when $1 is empty), every other line a
# key=value the renderer reads; each further argument sets one key, and `key=` drops it.
# One lock per session directory serializes every tag-file rewrite: this hook and the `edit=N` count in
# statusline-workdir-hook.sh both take `.claim.lock`.
tag_lock() {
  local tries=0 broke=0 max=${WORKER_TAG_LOCK_TRIES:-30}
  [[ $max =~ ^[0-9]+$ ]] || max=30
  until mkdir "$cache_dir/.claim.lock" 2>/dev/null; do
    if [ "$tries" -ge "$max" ]; then
      [ "$broke" = 0 ] && [ -n "$(find "$cache_dir/.claim.lock" -maxdepth 0 -mmin +1 2>/dev/null)" ] || return 1
      rmdir "$cache_dir/.claim.lock" 2>/dev/null
      broke=1 tries=0
      continue
    fi
    sleep 0.1
    tries=$((tries + 1))
  done
}
write_tag_file_locked() { # tag [key=value]...
  local tag="$1" tmp kv key want
  shift
  [ -n "$tag" ] || tag=$(tag_line)
  tmp="$tag_file.tmp.$$"
  {
    printf '%s\n' "$tag"
    [ -f "$tag_file" ] && tail -n +2 "$tag_file" | while IFS= read -r kv; do
      key=${kv%%=*}
      for want in "$@"; do [ "${want%%=*}" = "$key" ] && continue 2; done
      printf '%s\n' "$kv"
    done
    for kv in "$@"; do [ -z "${kv#*=}" ] || printf '%s\n' "$kv"; done
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$tag_file" 2>/dev/null && return 0
  rm -f "$tmp" 2>/dev/null
  return 1
}

umask 077
tag=$(tag_line)
if [ -n "$tag" ]; then
  touch "$tag_file" 2>/dev/null
else
  # The first call claims the oldest seed worker-spawn-hook left for this fork — one seed per
  # spawn, moved away so a sibling spawn claims its own.
  mkdir -p "$cache_dir" 2>/dev/null || exit 0
  tag_lock || exit 0
  seed=$(pick_seed)
  seed_lines=''
  [ -z "$seed" ] || seed_lines=$(cat "$seed" 2>/dev/null)
  tag=${seed_lines%%$'\n'*}
  written=1
  [ -z "$tag" ] || { write_tag_file_locked "$tag" && written=0; }
  [ "$written" != 0 ] || [ -z "$seed" ] || rm -f "$seed" 2>/dev/null
  rmdir "$cache_dir/.claim.lock" 2>/dev/null
  [ "$written" = 0 ] || exit 0
fi

prune() {
  marker="$cache_root/.tag-prune"
  now=$(date +%s 2>/dev/null)
  marker_mtime=$(stat -f %m "$marker" 2>/dev/null || stat -c %Y "$marker" 2>/dev/null || printf '0')
  if [[ "$now" =~ ^[0-9]+$ ]] && [[ "$marker_mtime" =~ ^[0-9]+$ ]] && [ "$((now - marker_mtime))" -gt 3600 ]; then
    find "$cache_root" -type f ! -name '.tag-prune' -mtime +7 -delete >/dev/null 2>&1
    find "$cache_root" -mindepth 1 -type d -empty ! \( -name .claim.lock -mmin -60 \) -delete >/dev/null 2>&1
    touch "$marker" 2>/dev/null
  fi
}

tag_prefix="$tag — "
if [ "${description:0:${#tag_prefix}}" = "$tag_prefix" ]; then
  prune; exit 0
fi
# Strip a stale tag-shaped prefix so prefixes never stack.
description=$(printf '%s' "$description" | sed -E 's/^[A-Za-z0-9_.?-]+( [a-z]+)?( · [A-Za-z0-9_.-]+){1,3} — //')
if [ -n "$description" ]; then
  updated_description="$tag — $description"
else
  updated_description=$tag
fi
prune
emit "$updated_description"
exit; }
