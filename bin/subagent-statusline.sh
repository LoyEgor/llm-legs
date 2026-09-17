#!/usr/bin/env bash
# subagentStatusLine renderer — docs/statusline-contract.md, "Task rows". stdin = {session_id,
# columns, tasks:[{id, type, status, description, startTime, tokenCount, model}]}, stdout =
# one {"id","content"} JSON line per row; content replaces the row body after the agent-type label.
# Every running local_agent task is painted: `<tag>[ — <title>] · <state> · <elapsed>[ · ↓ tok]`, the tag from
# the worker-spawn-hook/worker-tag-hook cache, else the tag embedded in the hook-rewritten
# description, else `agent · <model> · <account>` from the harness fields.
set -u
export LC_ALL=en_US.UTF-8

input=$(cat) || exit 0

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

MAGENTA=$'\033[35m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
cache_root="$HOME/.cache/claude-worker-tags"
runs_root="${WORKER_RUN_DIR:-$HOME/.cache/claude-worker-runs}"
progress_dir="${WORKER_STATS_DIR:-${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}/worker-stats}/progress"
# The harness prints the tree glyph and the agent-type label before the content this script emits.
reserve=${SUBAGENT_ROW_RESERVE:-3}
[[ "$reserve" =~ ^[0-9]+$ ]] || reserve=3
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

# Sets the full state and the short form the fit falls back to (a review's cell detail dropped).
set_state() { # plain color [short-plain short-color]
  state_plain=$1 state_color=$2
  state_short_plain=${3:-$1} state_short_color=${4:-$2}
}

worker_state() { # run-id
  local dir="$runs_root/$1" phase round
  [ -r "$dir/state.json" ] || return 1
  IFS=$'\x1f' read -r phase round fix_round < <(jq -r '[.phase // "", (.round // 0 | tostring),
    (.round_id // "" | tostring | gsub("[^A-Za-z0-9_-]"; ""))] | join("\u001f")' "$dir/state.json" 2>/dev/null) || return 1
  [ ! -f "$dir/exit_code" ] || return 1
  case "$phase" in
    start) set_state start start ;;
    wait) set_state "wait $round" "wait $round" ;;
    *) return 1 ;;
  esac
}

cells_state() { # stdin: label, done|failed|other, chunk passes read, chunk passes total, late, verifying
  local labels=() kinds=() reads=() totals=() lates=() verifies=() count=0 n=0 i j label kind r t late verify seen fin
  local g_cells g_done g_fail g_read g_total g_late g_verify detail detail_color plain="" color=""
  while IFS=$'\x1f' read -r label kind r t late verify; do
    [ -n "$label" ] || continue
    labels[count]=$label kinds[count]=$kind reads[count]=$r totals[count]=$t lates[count]=$late verifies[count]=$verify
    case "$kind" in done | failed) n=$((n + 1)) ;; esac
    count=$((count + 1))
  done
  for ((i = 0; i < count; i++)); do
    label=${labels[i]} seen=""
    for ((j = 0; j < i; j++)); do [ "${labels[j]}" != "$label" ] || { seen=1; break; }; done
    [ -z "$seen" ] || continue
    g_cells=0 g_done=0 g_fail=0 g_read=0 g_total=0 g_late="" g_verify=""
    for ((j = i; j < count; j++)); do
      [ "${labels[j]}" = "$label" ] || continue
      fin=""
      case "${kinds[j]}" in done) fin=1 ;; failed) fin=1 g_fail=$((g_fail + 1)) ;; esac
      g_cells=$((g_cells + 1))
      [ -z "${lates[j]}" ] || [ -n "$fin" ] || g_late=1
      [ -z "${verifies[j]}" ] || g_verify=1
      [ -z "$fin" ] || g_done=$((g_done + 1))
      if [ -n "${totals[j]}" ]; then
        g_total=$((g_total + totals[j]))
        if [ -n "$fin" ]; then g_read=$((g_read + totals[j])); else g_read=$((g_read + reads[j])); fi
      else
        g_total=$((g_total + 1))
        [ -z "$fin" ] || g_read=$((g_read + 1))
      fi
    done
    if [ -z "$g_verify" ] && [ "$g_fail" = 0 ] && [ "$g_done" = "$g_cells" ]; then
      detail='✓' detail_color="${GREEN}✓${RESET}${DIM}"
    elif [ -z "$g_verify" ] && [ "$g_fail" = "$g_cells" ]; then
      detail="✗$g_fail" detail_color="${RED}✗${RESET}${DIM}$g_fail"
    else
      detail="$g_read/$g_total" detail_color="$g_read/$g_total"
      [ "$g_fail" = 0 ] || detail="$detail ✗$g_fail" detail_color="$detail_color ${RED}✗${RESET}${DIM}$g_fail"
      [ -z "$g_verify" ] || detail="$detail verify" detail_color="$detail_color verify"
    fi
    if [ -n "$g_late" ]; then
      plain="$plain $label $detail" color="$color ${RESET}${RED}$label $detail${RESET}${DIM}"
    else
      plain="$plain $label $detail" color="$color $label $detail_color"
    fi
  done
  set_state "all $n/$count$plain" "all $n/$count$color" "all $n/$count" "all $n/$count"
}

review_state() { # run-id session tag-cache-path
  local doc state phase confirmed phase_at
  doc=$(review_doc "$1")
  [ -n "$doc" ] || return 1
  IFS=$'\x1f' read -r state phase confirmed j_account j_model j_effort phase_at < <(jq -r '
    def word: if type == "string" then gsub("[^A-Za-z0-9_.-]"; "") else "" end;
    def epoch: if type == "number" then floor
      elif type == "string" then (try fromdateiso8601 catch null) else null end;
    (if (.judge | type) == "object" then .judge else {} end) as $j |
    [(.state // "running" | if . == "failed" then "dead" else . end), (.phase // "review"),
     (.confirmed // "" | tostring), ($j.account | word), ($j.model | word), ($j.effort | word),
     ((.phase_at // $j.ts // null) | epoch | if . == null then "" else tostring end)]
    | join("\u001f")' <<<"$doc")
  case "$state" in
    dead) set_state '✗ dead' "${RED}✗${RESET}${DIM} dead"; return 0 ;;
    cancelled) return 0 ;;
  esac
  # The judge is its own row from its phase on, so the panel freezes at the moment the phase changed.
  case "$phase" in
    judge | report)
      judge_hash=${1: -7}
      judge_since=$phase_at
      if [ -z "$judge_since" ] && [ -n "$3" ]; then
        judge_since=$(tr -cd '0-9' 2>/dev/null < "$3.judge")
        if [ -z "$judge_since" ]; then
          judge_since=$((now_ms / 1000))
          printf '%s\n' "$judge_since" > "$3.judge" 2>/dev/null || :
        fi
      fi ;;
  esac
  case "$state" in
    done) set_state "✓ report${confirmed:+ $confirmed}" "${GREEN}✓${RESET}${DIM} report${confirmed:+ $confirmed}"; return 0 ;;
  esac
  case "$phase" in
    report) set_state "$phase" "$phase"; return 0 ;;
  esac
  cells_state < <(jq -r --arg sid "$2" --argjson now "$((now_ms / 1000))" '
    (.failed_cells // []) as $failed | (.done // []) as $done |
    (if (.started_epoch | type) == "number" and (.started_epoch | floor) == .started_epoch and .started_epoch > 0
     then .started_epoch else null end) as $started_epoch |
    (if (.expected | type) == "object" then .expected else {} end) as $expected |
    ($sid != "" and ($sid == .session or $sid == ((.waiter | objects | .session) // null))) as $launcher |
    (if (.chunks | type) == "object" then .chunks else {} end) as $chunks |
    (if (.verifying | type) == "object" then .verifying else {} end) as $verifying |
    (.cells // [])[] | . as $cell |
    ($chunks[$cell] // null) as $pass |
    (($pass | type) == "array" and ($pass | length) == 2 and ($pass[0] | type) == "number"
      and ($pass[1] | type) == "number" and $pass[1] > 1) as $chunked |
    [($cell | tostring | sub("#.*$"; "") | if test("^(claude|codex|oc|opencode|gemini)-") then sub("^[^-]*-"; "") else . end | sub("-.*$"; "")),
     (if ($failed | index([$cell])) then "failed" elif ($done | index([$cell])) then "done" else "running" end),
     (if $chunked then $pass[0] | floor | tostring else "" end), (if $chunked then $pass[1] | floor | tostring else "" end),
     ($expected[$cell] as $expected_ms
      | if $launcher and $started_epoch != null and ($expected_ms | type) == "number" and $expected_ms >= 0
          and (($now - $started_epoch) * 1000 > ([3 * $expected_ms, 120000] | max)) then "late" else "" end),
     (if $verifying[$cell] == "running" then "verify" else "" end)]
    | join("\u001f")' <<<"$doc")
  if [ -n "$judge_since" ]; then
    state_plain="$state_plain · ✓ done" state_color="$state_color ${DIM}· ${GREEN}✓${RESET}${DIM} done"
    state_short_plain="$state_short_plain · ✓ done" state_short_color="$state_short_color ${DIM}· ${GREEN}✓${RESET}${DIM} done"
  fi
}

image_state() { # dest-dir
  local cells
  cells=$(jq -r '(.cells // [])[] | [(.vendor // "?" | tostring),
    (if .status == "done" or .status == "failed" then .status else "running" end), "", "", "", ""] | join("\u001f")' \
    "$1/fanout.state.json" 2>/dev/null) || return 1
  cells_state <<<"$cells"
}

media_state() { # gen|edit exit
  [ -z "$2" ] || return 1
  set_state "$1" "$1"
}

while IFS=$'\x1f' read -r sid columns id description start_ms tokens status model; do
  [ -n "$id" ] || continue

  tag="" run_id="" review_id="" image_dir="" media="" media_exit="" edits="" light_role="" fix_round=""
  cache="$cache_root/$sid/$id"
  if [ -n "$sid" ] && [ -f "$cache" ]; then
    IFS= read -r tag < "$cache"
    run_id=$(sed -n 's/^run=//p' "$cache" | tail -n1 | tr -cd 'a-z0-9-')
    review_id=$(sed -n 's/^review=//p' "$cache" | tail -n1 | tr -cd 'A-Za-z0-9-')
    image_dir=$(sed -n 's/^image=//p' "$cache" | tail -n1)
    [[ "$image_dir" = /* ]] || image_dir=""
    media=$(sed -n 's/^media=//p' "$cache" | tail -n1 | tr -cd 'a-z')
    media_exit=$(sed -n 's/^exit=//p' "$cache" | tail -n1 | tr -cd '0-9')
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
  fi

  state_plain='' state_color='' state_short_plain='' state_short_color=''
  judge_since='' judge_hash='' j_account='' j_model='' j_effort=''
  if [ -n "$run_id" ] && worker_state "$run_id"; then :
  elif [ -n "$review_id" ] && review_state "$review_id" "$sid" "$cache"; then :
  elif [ -n "$image_dir" ] && image_state "$image_dir"; then :
  elif [ -n "$media" ] && media_state "$media" "$media_exit"; then :
  elif [ "${tag%% · *}" = fork ]; then
    if [ -n "$edits" ] && [ "$edits" -gt 0 ]; then set_state "edit $edits" "edit $edits"; else set_state explore explore; fi
  elif [ -n "$edits" ] && [ "$edits" -gt 0 ]; then
    set_state "edit $edits" "edit $edits"
  fi

  prefix="" hash=""
  if [ -n "$fix_round" ]; then
    title="" prefix="fix: " hash=${fix_round: -7}
  elif [ -z "$run_id" ] && [ -n "$review_id" ] && [ "${tag##* · }" = task ]; then
    title=$(printf '%s' "$title" | sed -E "s/^(WAIT|ATTACH) $review_id_re(: | — )?//")
  elif [ -z "$run_id" ] && { [ -n "$review_id" ] || [ -n "$image_dir" ] || [ -n "$media" ]; }; then
    title=""
  fi

  elapsed="" judge_elapsed=""
  start_int=${start_ms%.*}
  if [[ "$start_int" =~ ^[0-9]+$ ]] && [ "$now_ms" -gt "$start_int" ]; then
    elapsed=$(elapsed_str "$(( (now_ms - start_int) / 1000 ))")
    if [ -n "$judge_since" ] && [ "$judge_since" -gt "$((start_int / 1000))" ]; then
      elapsed=$(elapsed_str "$(( judge_since - start_int / 1000 ))")
    fi
  fi
  if [ -n "$judge_since" ] && [ "$((now_ms / 1000))" -ge "$judge_since" ]; then
    judge_elapsed=$(elapsed_str "$(( now_ms / 1000 - judge_since ))")
  fi
  tok=""
  tok_int=${tokens%.*}
  if [[ "$tok_int" =~ ^[0-9]+$ ]] && [ "$tok_int" -gt 0 ]; then
    if [ "$tok_int" -ge 1000 ]; then tok="↓ $((tok_int / 1000)).$(((tok_int % 1000) / 100))k tok"; else tok="↓ $tok_int tok"; fi
  fi

  # Fallback for a harness that shows only a row's first line: the judge fields replace the cells in it.
  if [ -n "$judge_since" ] && [ "${SUBAGENT_JUDGE_ROW:-}" = inline ]; then
    jtag=$j_account
    [ -z "$j_model" ] || jtag="${jtag:+$jtag · }$j_model"
    [ -z "$j_effort" ] || jtag="${jtag:+$jtag · }$j_effort"
    state_plain="judge:${jtag:+ $jtag}${judge_hash:+ · $judge_hash}"
    state_color="${MAGENTA}judge:${jtag:+ $jtag}${RESET}${DIM}${judge_hash:+ · $judge_hash}"
    state_short_plain=$state_plain state_short_color=$state_color
    elapsed=$judge_elapsed
  fi

  # Fit, dropping in order: title tail down to TITLE_FLOOR, the rest of the title, tok, elapsed, the fix
  # hash, group detail (the `all n/m` total stays); never the tag or the state word with its number.
  budget=0
  [[ "$columns" =~ ^[0-9]+$ ]] && [ "$columns" -gt 0 ] && budget=$((columns - reserve))
  [ "$budget" -gt 0 ] || [ "${columns:-0}" = 0 ] || budget=1
  row_width() {
    local w=$((${#prefix} + ${#tag}))
    [ -z "$hash" ] || w=$((w + 3 + ${#hash}))
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
    cut_title "$TITLE_FLOOR"
    cut_title 0
    [ "$(row_width)" -le "$budget" ] || tok=""
    [ "$(row_width)" -le "$budget" ] || elapsed=""
    [ "$(row_width)" -le "$budget" ] || hash=""
    [ "$(row_width)" -le "$budget" ] || state_plain=$state_short_plain state_color=$state_short_color
  fi

  content="${MAGENTA}${prefix}${tag}${RESET}"
  [ -z "$hash" ] || content="${content} ${DIM}· ${hash}${RESET}"
  [ -z "$title" ] || content="${content} ${DIM}—${RESET} ${title}"
  [ -z "$state_plain" ] || content="${content} ${DIM}· ${state_color}${RESET}"
  [ -z "$elapsed" ] || content="${content} ${DIM}· ${elapsed}${RESET}"
  [ -z "$tok" ] || content="${content} ${DIM}· ${tok}${RESET}"
  if [ -n "$judge_since" ] && [ "${SUBAGENT_JUDGE_ROW:-}" != inline ]; then
    jm=$j_model je=$j_effort jhash=$judge_hash jel=$judge_elapsed
    jtag_build() {
      jtag=$j_account
      [ -z "$jm" ] || jtag="${jtag:+$jtag · }$jm"
      [ -z "$je" ] || jtag="${jtag:+$jtag · }$je"
    }
    judge_row() {
      local sep=" " sepc=" "
      jplain="judge:" jcolor="${MAGENTA}judge:${RESET}"
      if [ -n "$jtag" ]; then
        jplain="$jplain$sep$jtag" jcolor="$jcolor${MAGENTA}$sep$jtag${RESET}" sep=" · " sepc=" ${DIM}· "
      fi
      if [ -n "$jhash" ]; then
        jplain="$jplain$sep$jhash" jcolor="$jcolor$sepc${DIM}$jhash${RESET}" sep=" · " sepc=" ${DIM}· "
      fi
      [ -z "$jel" ] || { jplain="$jplain$sep$jel" jcolor="$jcolor$sepc${DIM}$jel${RESET}"; }
    }
    # The judge row's own fit: the hash, then the effort, the model, the elapsed; prefix and account stay.
    jtag_build; judge_row
    if [ "$budget" -gt 0 ]; then
      [ "${#jplain}" -le "$budget" ] || { jhash=""; judge_row; }
      [ "${#jplain}" -le "$budget" ] || { je=""; jtag_build; judge_row; }
      [ "${#jplain}" -le "$budget" ] || { jm=""; jtag_build; judge_row; }
      [ "${#jplain}" -le "$budget" ] || { jel=""; judge_row; }
    fi
    content="$content"$'\n'"$jcolor"
  fi
  jq -cn --arg id "$id" --arg content "$content" '{id: $id, content: $content}' 2>/dev/null
done <<EOF
$parsed
EOF

exit 0
