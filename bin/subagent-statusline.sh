#!/usr/bin/env bash
# subagentStatusLine renderer. Contract (docs/statusline, "Subagent status
# lines"): stdin = {session_id, columns, tasks:[{id, description, label, ...}]},
# stdout = one {"id","content"} JSON line per row; content replaces the row
# body after the agent-type label; rows without an emitted id keep default
# rendering. For codex-/claudeb-worker rows we prepend the account·model·effort
# tag (worker-spawn-hook/worker-tag-hook cache, else the tag already embedded
# in the hook-rewritten description) — the harness renders the raw pre-hook
# `label`, so this is the only deterministic way to show who spends the quota.
set -u

input=$(cat) || exit 0

parsed=$(printf '%s' "$input" | jq -r '
  ((.session_id // "") | tostring | gsub("[^A-Za-z0-9_-]"; "")) as $sid |
  (.tasks // [])[] |
  [$sid,
   ((.id // "") | tostring | gsub("[^A-Za-z0-9_-]"; "")),
   ((.description // "") | tostring | gsub("[\n\r]"; " ")),
   ((.label // "") | tostring | gsub("[\n\r]"; " ")),
   ((.startTime // "") | tostring),
   ((.tokenCount // "") | tostring),
   ((.status // "") | tostring)]
  | join("")
' 2>/dev/null) || exit 0
[ -n "$parsed" ] || exit 0

MAGENTA=$'\033[35m'; DIM=$'\033[2m'; RESET=$'\033[0m'
cache_root="$HOME/.cache/claude-worker-tags"
tag_re='^[A-Za-z0-9_.?-]+( · [A-Za-z0-9_.-]+){1,2}'
now_ms=$(( $(date +%s) * 1000 ))

elapsed_str() {
  local secs=$1
  if [ "$secs" -lt 60 ]; then printf '%ss' "$secs"
  elif [ "$secs" -lt 3600 ]; then printf '%sm %ss' "$((secs / 60))" "$((secs % 60))"
  else printf '%sh %sm' "$((secs / 3600))" "$(((secs % 3600) / 60))"
  fi
}

while IFS=$'\x1f' read -r sid id description label start_ms tokens status; do
  [ -n "$id" ] || continue

  tag=""
  if [ -n "$sid" ] && [ -f "$cache_root/$sid/$id" ]; then
    IFS= read -r tag < "$cache_root/$sid/$id"
  fi
  if [ -z "$tag" ] && printf '%s' "$description" | grep -qE "$tag_re: "; then
    tag=$(printf '%s' "$description" | grep -oE "$tag_re" | head -n1)
  fi
  [ -n "$tag" ] || continue

  # The label may already carry the tag: hook-prefixed Bash descriptions use
  # "tag — ", and for idle/queued rows the harness falls back to the rewritten
  # agent description, "tag: ". Strip both so the tag never doubles.
  body=$(printf '%s' "$label" | sed -E "s/^[A-Za-z0-9_.?-]+( · [A-Za-z0-9_.-]+){1,2}( — |: )//")

  # Replacing the row body hides the default right-side metrics, so re-add
  # elapsed time (hang detector) and token spend ourselves.
  meta=""
  start_int=${start_ms%.*}
  if [[ "$start_int" =~ ^[0-9]+$ ]] && [ "$now_ms" -gt "$start_int" ]; then
    meta="$(elapsed_str "$(( (now_ms - start_int) / 1000 ))")"
  fi
  tok_int=${tokens%.*}
  if [[ "$tok_int" =~ ^[0-9]+$ ]] && [ "$tok_int" -gt 0 ]; then
    if [ "$tok_int" -ge 1000 ]; then tok_str="$((tok_int / 1000)).$(((tok_int % 1000) / 100))k"; else tok_str=$tok_int; fi
    meta="${meta:+$meta · }↓ ${tok_str} tok"
  fi
  case "$status" in
    running|"") ;;
    *) meta="${meta:+$meta · }${status}" ;;
  esac

  if [ -n "$body" ]; then
    content="${MAGENTA}${tag}${RESET} ${DIM}—${RESET} ${body}"
  else
    content="${MAGENTA}${tag}${RESET}"
  fi
  [ -n "$meta" ] && content="${content} ${DIM}· ${meta}${RESET}"
  jq -cn --arg id "$id" --arg content "$content" '{id: $id, content: $content}' 2>/dev/null
done <<EOF
$parsed
EOF

exit 0
