# Approved visual mock, 2026-10-08. Demo only: pasted before the final printf of bin/statusline.sh, it read
# $statusline_cache_dir/demo-work-<sid> (probe-format lines) and replaced work_rows. Not production code.
demo_work="$statusline_cache_dir/demo-work-${session_id:-none}"
if [ -f "$demo_work" ]; then
  work_rows=() d_n=0 d_more=0 d_mw=0 d_mm=0 d_mc=0
  d_kind=() d_head=() d_title=() d_state=() d_el=() d_tok=()
  d_src=("$demo_work")
  [[ "${work_mtime:-}" =~ ^[0-9]+$ ]] && [ "$((now - work_mtime))" -le 15 ] && d_src=("$work_cache" "$demo_work")
  while IFS= read -r d_line || [ -n "$d_line" ]; do
    IFS=$'\037' read -r d_k d_cls d_start d_repo d_label d_done d_failed d_total _ <<<"${d_line//$'\t'/$'\037'}"
    [ "$d_k" = main ] && [[ "$d_start" =~ ^[0-9]+$ ]] || continue
    if [ "$d_n" -ge 5 ]; then
      d_more=$((d_more + 1))
      case "$d_cls" in worker) d_mw=$((d_mw + 1)) ;; media) d_mm=$((d_mm + 1)) ;; *) d_mc=$((d_mc + 1)) ;; esac
      continue
    fi
    d_s=$((now - d_start)); [ "$d_s" -ge 0 ] || d_s=0
    if [ "$d_s" -lt 60 ]; then d_e="${d_s}s"
    elif [ "$d_s" -lt 3600 ]; then printf -v d_e '%dm %02ds' $((d_s / 60)) $((d_s % 60))
    else printf -v d_e '%dh %02dm' $((d_s / 3600)) $((d_s % 3600 / 60))
    fi
    case "$d_cls" in
      worker) d_kind+=(agent) d_head+=("$d_repo") d_state+=("$d_done") d_tok+=("$d_total") ;;
      media) d_kind+=(agent) d_head+=("image · $d_repo") d_state+=("") d_tok+=("") ;;
      *)
        d_st=""
        [[ "$d_total" =~ ^[0-9]+$ ]] && d_st="$d_done/$d_total"
        [[ "$d_failed" =~ ^[1-9][0-9]*$ ]] && d_st="$d_st ✗$d_failed"
        d_kind+=(cmd) d_head+=("$d_cls · $d_repo") d_state+=("$d_st") d_tok+=("") ;;
    esac
    d_title+=("$d_label") d_el+=("$d_e")
    d_n=$((d_n + 1))
  done < <(cat "${d_src[@]}" 2>/dev/null | awk -F'\t' '$2=="worker"||$2=="media"{print;next}{r[++n]=$0}END{for(i=1;i<=n;i++)print r[i]}')
  d_sw=0 d_ew=0 d_tw=0 d_lw=0
  for ((d_i = 0; d_i < d_n; d_i++)); do
    [ "$((${#d_head[d_i]} + 3 + ${#d_title[d_i]}))" -le "$d_lw" ] || d_lw=$((${#d_head[d_i]} + 3 + ${#d_title[d_i]}))
    [ "${#d_state[d_i]}" -le "$d_sw" ] || d_sw=${#d_state[d_i]}
    [ "${#d_el[d_i]}" -le "$d_ew" ] || d_ew=${#d_el[d_i]}
    [ "${#d_tok[d_i]}" -le "$d_tw" ] || d_tw=${#d_tok[d_i]}
  done
  d_right=$((2 + d_ew))
  [ "$d_sw" -eq 0 ] || d_right=$((d_right + 2 + d_sw))
  [ "$d_tw" -eq 0 ] || d_right=$((d_right + 2 + d_tw))
  d_left=$d_lw
  [ -z "$fit_cols" ] || [ "$((fit_cols - d_right))" -ge "$d_left" ] || d_left=$((fit_cols - d_right))
  for ((d_i = 0; d_i < d_n; d_i++)); do
    d_t=${d_title[d_i]}
    d_avail=$((d_left - ${#d_head[d_i]} - 3))
    [ "$d_avail" -ge 1 ] || d_avail=1
    [ "${#d_t}" -le "$d_avail" ] || d_t="${d_t:0:$((d_avail - 1))}…"
    d_p1=""
    printf -v d_p2 '%*s' $((d_avail - ${#d_t})) ''
    if [ "${d_kind[d_i]}" = agent ]; then d_row="${MAGENTA}${d_head[d_i]}${RESET}${d_p1} ${DIM}—${RESET} ${d_t}${d_p2}"
    else d_row="${CYAN}${d_head[d_i]}${RESET}${d_p1} ${DIM}— ${d_t}${RESET}${d_p2}"
    fi
    if [ "$d_sw" -gt 0 ]; then
      d_st=${d_state[d_i]}
      printf -v d_p3 '%*s' $((d_sw - ${#d_st})) ''
      [[ "$d_st" != *✗* ]] || d_st="${d_st%%✗*}${RESET}${RED}✗${d_st#*✗}${RESET}${DIM}"
      d_row="$d_row  ${DIM}${d_st}${d_p3}${RESET}"
    fi
    printf -v d_p4 '%*s' $((d_ew - ${#d_el[d_i]})) ''
    d_row="$d_row  ${DIM}${d_p4}${d_el[d_i]}${RESET}"
    if [ "$d_tw" -gt 0 ]; then
      printf -v d_p5 '%*s' $((d_tw - ${#d_tok[d_i]})) ''
      d_row="$d_row  ${DIM}${d_p5}${d_tok[d_i]}${RESET}"
    fi
    work_rows+=("$d_row")
  done
  if [ "$d_more" -gt 0 ]; then
    d_parts=""
    [ "$d_mw" -eq 0 ] || d_parts="${d_parts:+$d_parts, }$d_mw workers"
    [ "$d_mm" -eq 0 ] || d_parts="${d_parts:+$d_parts, }$d_mm image"
    [ "$d_mc" -eq 0 ] || d_parts="${d_parts:+$d_parts, }$d_mc commands"
    work_rows+=("${DIM}+${d_parts}${RESET}")
  fi
fi

