#!/usr/bin/env bash
# subagentStatusLine renderer — docs/statusline-contract.md, "Task rows". stdin = {session_id,
# columns, tasks:[{id, type, status, description, startTime, tokenCount, model}]}, stdout =
# one {"id","content"} JSON line per row; content replaces the row body after the agent-type label.
# Every running local_agent task is painted: `<tag>[ — <title>][ · <state>] · <elapsed>[ · ↓ tok]`, the
# tag from the tag cache, else the tag embedded in the hook-rewritten description, else
# `agent · <model> · <account>` from the harness fields.
{
set -u
export LC_ALL=en_US.UTF-8

input=$(cat) || exit 0

# The harness paints its own row for any listed id this prints nothing for, and keeps finished
# agents listed for hours; an empty content is the one answer that removes the row.
printf '%s' "$input" | jq -c '(.tasks // [])[]
  | select((.type // "local_agent") == "local_agent" and ((.status // "") | IN("completed", "failed", "killed")))
  | ((.id // "") | tostring) | select(. != "") | {id: ., content: ""}' 2>/dev/null

parsed=$(printf '%s' "$input" | jq -r '
  ((.session_id // "") | tostring | gsub("[^A-Za-z0-9_-]"; "")) as $sid |
  ((.columns // 0) | tostring) as $cols |
  (.tasks // [])[] | select((.type // "local_agent") == "local_agent" and (.status // "running") == "running") |
  [$sid, $cols,
   ((.id // "") | tostring | gsub("[^A-Za-z0-9_-]"; "")),
   ((.description // "") | tostring | gsub("[\n\r\u001f]"; " ")),
   ((.startTime // "") | tostring),
   ((.tokenCount // "") | tostring),
   ((.status // "") | tostring),
   ((.model // "") | tostring | gsub("[^A-Za-z0-9_.-]"; ""))]
  | join("\u001f")
' 2>/dev/null) || exit 0
[ -n "$parsed" ] || exit 0

MAGENTA=$'\033[35m'; DIM=$'\033[2m'; RESET=$'\033[0m'
cache_root="$HOME/.cache/claude-worker-tags"
# The harness prints the tree glyph and the agent-type label before the content this script emits.
reserve=${SUBAGENT_ROW_RESERVE:-4}
[[ "$reserve" =~ ^[0-9]+$ ]] || reserve=4
TITLE_FLOOR=20
tag_re='^[A-Za-z0-9_.?-]+( [a-z]+)?( · [A-Za-z0-9_.?-]+){1,3}'
now_ms=$(( $(date +%s) * 1000 ))

elapsed_str() {
  local secs=$1
  if [ "$secs" -lt 60 ]; then printf '%ss' "$secs"
  elif [ "$secs" -lt 3600 ]; then printf '%sm %ss' "$((secs / 60))" "$((secs % 60))"
  else printf '%sh %sm' "$((secs / 3600))" "$(((secs % 3600) / 60))"
  fi
}

model_short() { # harness model id
  local m=${1#claude-}
  m=${m%%-*}
  printf '%s' "${m:-?}"
}

session_account() {
  local acct=${CLAUDE_LIMITS_ACCOUNT:-}
  if [ -z "$acct" ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "$CLAUDE_CONFIG_DIR" != "$HOME/.claude" ]; then
    acct=$(basename "$CLAUDE_CONFIG_DIR")
  fi
  printf '%s' "${acct:-main}"
}

while IFS=$'\x1f' read -r sid columns id description start_ms tokens status model; do
  [ -n "$id" ] || continue

  tag="" edits=""
  cache="$cache_root/$sid/$id"
  if [ -n "$sid" ] && [ -f "$cache" ]; then
    IFS= read -r tag < "$cache"
    while IFS= read -r cache_line || [ -n "$cache_line" ]; do
      case $cache_line in edit=*) edits=${cache_line#edit=} ;; esac
    done < "$cache"
    edits=${edits//[!0-9]/}
  fi
  if [ -z "$tag" ] && printf '%s' "$description" | grep -qE "$tag_re: "; then
    tag=$(printf '%s' "$description" | grep -oE "$tag_re" | head -n1)
  fi
  [ -n "$tag" ] || tag="agent · $(model_short "$model") · $(session_account)"
  # A native row shows the model doing the work: the harness model, never the one its tag was seeded with.
  case "$tag" in
    'fork · '* | 'agent · '*)
      rest=${tag#* · }
      [ -z "$model" ] || tag="${tag%% · *} · $(model_short "$model") · ${rest#* · }" ;;
  esac

  # The harness label is the agent's momentary activity; the row names the task, so concurrent agents stay apart.
  title=$(printf '%s' "$description" | sed -E "s/^[A-Za-z0-9_.?-]+( [a-z]+)?( · [A-Za-z0-9_.?-]+){1,3}(: | — )//")

  state=""
  if [ -n "$edits" ] && [ "$edits" -gt 0 ]; then state="edit $edits"
  elif [ "${tag%% · *}" = fork ]; then state=explore
  fi

  elapsed=""
  start_int=${start_ms%.*}
  if [[ "$start_int" =~ ^[0-9]+$ ]] && [ "$now_ms" -gt "$start_int" ]; then
    elapsed=$(elapsed_str "$(( (now_ms - start_int) / 1000 ))")
  fi
  tok=""
  tok_int=${tokens%.*}
  if [[ "$tok_int" =~ ^[0-9]+$ ]] && [ "$tok_int" -gt 0 ]; then
    if [ "$tok_int" -ge 1000 ]; then tok="↓ $((tok_int / 1000)).$(((tok_int % 1000) / 100))k tok"; else tok="↓ $tok_int tok"; fi
  fi

  # Fit, dropping in order: title tail down to TITLE_FLOOR, the rest of the title, tok, elapsed; never the tag or the state.
  budget=0
  [[ "$columns" =~ ^[0-9]+$ ]] && [ "$columns" -gt 0 ] && budget=$((columns - reserve))
  [ "$budget" -gt 0 ] || [ "${columns:-0}" = 0 ] || budget=1
  row_width() {
    local w=${#tag}
    [ -z "$title" ] || w=$((w + 3 + ${#title}))
    [ -z "$state" ] || w=$((w + 3 + ${#state}))
    [ -z "$elapsed" ] || w=$((w + 3 + ${#elapsed}))
    [ -z "$tok" ] || w=$((w + 3 + ${#tok}))
    printf '%s' "$w"
  }
  cut_title() { # floor
    local over keep
    over=$(( $(row_width) - budget ))
    [ "$over" -gt 0 ] && [ -n "$title" ] || return 0
    keep=$(( ${#title} - over - 1 ))
    [ "$keep" -ge "$1" ] || keep=$1
    if [ "$keep" -lt 1 ]; then title=""; return 0; fi
    [ "$((keep + 1))" -lt "${#title}" ] || return 0
    title="${title:0:keep}…"
  }
  if [ "$budget" -gt 0 ]; then
    cut_title "$TITLE_FLOOR"
    cut_title 0
    [ "$(row_width)" -le "$budget" ] || tok=""
    [ "$(row_width)" -le "$budget" ] || elapsed=""
  fi

  content="${MAGENTA}${tag}${RESET}"
  [ -z "$title" ] || content="${content} ${DIM}—${RESET} ${title}"
  [ -z "$state" ] || content="${content} ${DIM}· ${state}${RESET}"
  [ -z "$elapsed" ] || content="${content} ${DIM}· ${elapsed}${RESET}"
  [ -z "$tok" ] || content="${content} ${DIM}· ${tok}${RESET}"
  jq -cn --arg id "$id" --arg content "$content" '{id: $id, content: $content}' 2>/dev/null
done <<EOF
$parsed
EOF

exit 0
exit; }
