#!/usr/bin/env bash
# subagentStatusLine renderer — docs/statusline-contract.md, "Task rows". stdin = {session_id,
# columns, tasks:[{id, type, status, description, startTime, tokenCount, model}]}, stdout =
# one {"id","content"} JSON line per row; content replaces the row body after the agent-type label.
# Every local_agent task is painted: `<tag> — <title> · <state> · <elapsed>[ · ↓ tok]`, the tag from
# the worker-spawn-hook/worker-tag-hook cache, else the tag embedded in the hook-rewritten
# description, else `agent · <model> · <account>` from the harness fields.
set -u
export LC_ALL=en_US.UTF-8

input=$(cat) || exit 0

parsed=$(printf '%s' "$input" | jq -r '
  ((.session_id // "") | tostring | gsub("[^A-Za-z0-9_-]"; "")) as $sid |
  ((.columns // 0) | tostring) as $cols |
  (.tasks // [])[] | select((.type // "local_agent") == "local_agent") |
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

MAGENTA=$'\033[35m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
cache_root="$HOME/.cache/claude-worker-tags"
runs_root="${WORKER_RUN_DIR:-$HOME/.cache/claude-worker-runs}"
image_root="${IMAGE_RUN_DIR:-$HOME/.cache/claude-image-runs}"
progress_dir="${WORKER_STATS_DIR:-${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}/worker-stats}/progress"
# The harness prints the tree glyph and the agent-type label before the content this script emits.
reserve=${SUBAGENT_ROW_RESERVE:-24}
[[ "$reserve" =~ ^[0-9]+$ ]] || reserve=24
TITLE_FLOOR=20
tag_re='^[A-Za-z0-9_.?-]+( [a-z]+)?( · [A-Za-z0-9_.?-]+){1,3}'
review_id_re='[0-9]{8}T[0-9]{6}Z-[0-9a-f]+(-[0-9]+)?'
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

gemini_label() {
  printf '%s' "$1" | sed -E 's/^flash([0-9])([0-9])$/\1.\2-flash/; s/^gemini-([0-9.]+)-(flash|pro)(-(high|medium|low))?$/\1-\2/'
}

review_doc() { # run-id
  cat "$progress_dir"/*.json 2>/dev/null | jq -c --arg run "$1" 'select(.run_id? == $run)' 2>/dev/null | tail -n1
}

# Sets state_plain/state_color (full) and state_short_plain/state_short_color (cell detail dropped).
set_state() { # plain color [short-plain short-color]
  state_plain=$1 state_color=$2
  state_short_plain=${3:-$1} state_short_color=${4:-$2}
}

glyph() { # done|failed|running|queued
  case "$1" in
    done) printf '%s✓%s' "$GREEN" "$RESET" ;;
    failed) printf '%s✗%s' "$RED" "$RESET" ;;
    queued) printf '○' ;;
    *) printf '●' ;;
  esac
}
glyph_plain() { case "$1" in done) printf '✓' ;; failed) printf '✗' ;; queued) printf '○' ;; *) printf '●' ;; esac; }

worker_state() { # run-id harness-status
  local dir="$runs_root/$1" phase round code alive=1
  [ -r "$dir/state.json" ] || return 1
  IFS=$'\x1f' read -r phase round code fix_round < <(jq -r '[.phase // "", (.round // 0 | tostring), (.exit_code // "" | tostring),
    (.round_id // "" | tostring | gsub("[^A-Za-z0-9_-]"; ""))] | join("\u001f")' "$dir/state.json" 2>/dev/null) || return 1
  if [ -f "$dir/exit_code" ]; then
    alive=0
    case "$phase" in
      done | failed) ;;
      *) code=$(tr -d '[:space:]' <"$dir/exit_code"); [ "$code" = 0 ] && phase=done || phase=failed ;;
    esac
  fi
  if [ "$alive" = 1 ] && [ "$2" != running ] && [ -n "$2" ]; then phase=checkpoint; fi
  case "$phase" in
    start) set_state start start ;;
    wait) set_state "wait $round" "wait $round" ;;
    done) set_state '✓ done' "${GREEN}✓${RESET}${DIM} done" ;;
    failed) set_state "✗ failed $code" "${RED}✗${RESET}${DIM} failed $code" ;;
    checkpoint) set_state '⏸ checkpoint' '⏸ checkpoint' ;;
    *) return 1 ;;
  esac
}

cell_label() { # cell
  local cell=${1%%#*}
  case "$cell" in
    claude-* | codex-* | oc-* | opencode-* | gemini-*) cell=${cell#*-} ;;
  esac
  printf '%s' "${cell%%-*}"
}

review_state() { # run-id
  local doc state phase n m confirmed cell kind plain color
  doc=$(review_doc "$1")
  [ -n "$doc" ] || return 1
  IFS=$'\x1f' read -r state phase n m confirmed < <(jq -r '
    [(.state // "running" | if . == "failed" then "dead" else . end), (.phase // "review"),
     ((.done // []) | length | tostring), ((.cells // []) | length | tostring),
     (.confirmed // "" | tostring)] | join("\u001f")' <<<"$doc")
  case "$state" in
    done) set_state "✓ report${confirmed:+ $confirmed}" "${GREEN}✓${RESET}${DIM} report${confirmed:+ $confirmed}"; return 0 ;;
    dead) set_state '✗ dead' "${RED}✗${RESET}${DIM} dead"; return 0 ;;
    cancelled) set_state cancelled cancelled; return 0 ;;
  esac
  case "$phase" in
    judge | verify | report) set_state "$phase" "$phase"; return 0 ;;
  esac
  plain="review $n/$m" color="review $n/$m"
  while IFS=$'\x1f' read -r cell kind; do
    [ -n "$cell" ] || continue
    plain="$plain $(glyph_plain "$kind")$(cell_label "$cell")"
    color="$color $(glyph "$kind")${DIM}$(cell_label "$cell")"
  done < <(jq -r '
    (.failed_cells // []) as $failed | (.done // []) as $done |
    (.cells // [])[] | . as $cell |
    [$cell, (if ($failed | index([$cell])) then "failed" elif ($done | index([$cell])) then "done" else "running" end)]
    | join("\u001f")' <<<"$doc")
  set_state "$plain" "$color" "review $n/$m" "review $n/$m"
}

image_state() { # run
  local file="$image_root/$1/state.json" n m running plain color vendor kind
  [ -r "$file" ] || return 1
  IFS=$'\x1f' read -r n m running < <(jq -r '(.cells // {}) as $c |
    [([$c[] | select(. == "done")] | length | tostring), ($c | length | tostring),
     ([$c[] | select(. == "running" or . == "queued")] | length | tostring)] | join("\u001f")' "$file" 2>/dev/null) || return 1
  if [ "$running" -gt 0 ]; then plain=gen color=gen; else plain="✓ $n/$m" color="${GREEN}✓${RESET}${DIM} $n/$m"; fi
  local short_plain=$plain short_color=$color
  while IFS=$'\x1f' read -r vendor kind; do
    [ -n "$vendor" ] || continue
    plain="$plain $(glyph_plain "$kind")$vendor"
    color="$color $(glyph "$kind")${DIM}$vendor"
  done < <(jq -r '(.cells // {}) | to_entries[] | [.key, .value] | join("\u001f")' "$file" 2>/dev/null)
  set_state "$plain" "$color" "$short_plain" "$short_color"
}

while IFS=$'\x1f' read -r sid columns id description start_ms tokens status model; do
  [ -n "$id" ] || continue

  tag="" run_id="" review_id="" image_id="" edits="" light_role="" fix_round=""
  cache="$cache_root/$sid/$id"
  if [ -n "$sid" ] && [ -f "$cache" ]; then
    IFS= read -r tag < "$cache"
    run_id=$(sed -n 's/^run=//p' "$cache" | tail -n1 | tr -cd 'a-z0-9-')
    review_id=$(sed -n 's/^review=//p' "$cache" | tail -n1 | tr -cd 'A-Za-z0-9-')
    image_id=$(sed -n 's/^image=//p' "$cache" | tail -n1 | tr -cd 'A-Za-z0-9_.-')
    edits=$(sed -n 's/^edit=//p' "$cache" | tail -n1 | tr -cd '0-9')
    light_role=$(sed -n 's/^light=//p' "$cache" | tail -n1 | tr -cd 'a-z')
  fi
  if [ -z "$tag" ] && printf '%s' "$description" | grep -qE "$tag_re: "; then
    tag=$(printf '%s' "$description" | grep -oE "$tag_re" | head -n1)
  fi
  [ -n "$tag" ] || tag="agent · $(model_short "$model") · $(session_account)"
  # The model shown is the one doing the work: a native row runs on the harness model, a light
  # relay's harness model is only its shell, so its run tag `<acct> · <model> · <effort>` is recast.
  case "$tag" in
    'fork · '* | 'agent · '*)
      rest=${tag#* · }
      [ -z "$model" ] || tag="${tag%% · *} · $(model_short "$model") · ${rest#* · }" ;;
    'light '*) ;;
    *' · '*' · '*)
      if [ -n "$light_role" ]; then
        rest=${tag#* · }
        tag="light $light_role · $(gemini_label "${rest%% · *}") · ${tag%% · *}"
      fi ;;
  esac

  # The harness label is the agent's momentary activity; the row names the task, so concurrent workers stay apart.
  title=$(printf '%s' "$description" | sed -E "s/^[A-Za-z0-9_.?-]+( [a-z]+)?( · [A-Za-z0-9_.?-]+){1,3}(: | — )//")
  if [ -z "$review_id" ] && [ -z "$run_id" ]; then
    review_id=$(printf '%s' "$description" | grep -oE "(WAIT|ATTACH) $review_id_re" | head -n1 | sed -E 's/^[A-Z]+ //')
  fi
  if [ -n "$review_id" ]; then
    review_tag=$(review_doc "$review_id" | jq -r 'def word(d): (if . == null then "" else tostring | gsub("[^A-Za-z0-9_.-]"; "") end) | if . == "" then d else . end;
      (if (.kind // "") == "task" or (.hunt // false) then "task" else "review" end) as $kind
      | [(.tier | word("T?")), (.composition | word("standard")), (.lens | word($kind))] | join(" · ")' 2>/dev/null)
    case "$tag" in 'agent · '*) review_tag=${review_tag:-review · ${review_id: -7}} ;; esac
    [ -z "$review_tag" ] || tag=$review_tag
    title=$(printf '%s' "$title" | sed -E "s/^(WAIT|ATTACH) $review_id_re:[[:space:]]*//")
  fi

  state_plain='' state_color='' state_short_plain='' state_short_color=''
  if [ -n "$run_id" ] && worker_state "$run_id" "$status"; then :
  elif [ -n "$review_id" ] && review_state "$review_id"; then :
  elif [ -n "$image_id" ] && image_state "$image_id"; then :
  elif [ "${tag%% · *}" = fork ] && { [ "$status" = running ] || [ -z "$status" ]; }; then
    if [ -n "$edits" ] && [ "$edits" -gt 0 ]; then set_state "edit $edits" "edit $edits"; else set_state explore explore; fi
  elif [ -n "$edits" ] && [ "$edits" -gt 0 ] && { [ "$status" = running ] || [ -z "$status" ]; }; then
    set_state "edit $edits" "edit $edits"
  elif [ -n "$status" ] && [ "$status" != running ]; then
    set_state "$status" "$status"
  fi

  case "$title" in
    fix:*) ;;
    *) [ -z "$fix_round" ] || title="fix: ${fix_round: -7}${title:+ $title}" ;;
  esac

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

  # Fit, dropping in order: tok, title tail down to TITLE_FLOOR, cell detail (counts stay), the rest
  # of the title; never the tag or the state.
  budget=0
  [[ "$columns" =~ ^[0-9]+$ ]] && [ "$columns" -gt 0 ] && budget=$((columns - reserve))
  [ "$budget" -gt 0 ] || [ "${columns:-0}" = 0 ] || budget=1
  row_width() {
    local w=${#tag}
    [ -z "$title" ] || w=$((w + 3 + ${#title}))
    [ -z "$state_plain" ] || w=$((w + 3 + ${#state_plain}))
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
    [ "$(row_width)" -le "$budget" ] || tok=""
    full_title=$title
    cut_title "$TITLE_FLOOR"
    if [ "$(row_width)" -gt "$budget" ]; then
      title=$full_title
      state_plain=$state_short_plain state_color=$state_short_color
    fi
    cut_title 0
  fi

  content="${MAGENTA}${tag}${RESET}"
  [ -z "$title" ] || content="${content} ${DIM}—${RESET} ${title}"
  [ -z "$state_plain" ] || content="${content} ${DIM}· ${state_color}${RESET}"
  [ -z "$elapsed" ] || content="${content} ${DIM}· ${elapsed}${RESET}"
  [ -z "$tok" ] || content="${content} ${DIM}· ${tok}${RESET}"
  jq -cn --arg id "$id" --arg content "$content" '{id: $id, content: $content}' 2>/dev/null
done <<EOF
$parsed
EOF

exit 0
