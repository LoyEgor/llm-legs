#!/usr/bin/env bash

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/limits-view.sh"

account_status_chat_account() {
  local vendor="$1" resolver="$2" pick name
  pick=$("$resolver") || return 0
  [ -n "$pick" ] && [ -x "$pick" ] || return 0
  name=$("$pick" --account "$vendor" --role chat 2>/dev/null) || return 0
  printf '%s' "$name"
}

account_status_rows() {
  local cache="${LLM_LIMITS_CACHE:-$HOME/.llm-limits.json}" now
  now=$("$accounts_now")
  if [ ! -r "$cache" ]; then printf '{"data":[]}'; return; fi
  jq -c --arg vendor "$accounts_store_vendor" --argjson now "$now" \
    --argjson thr5 "$LIMITS_STALE_FIVE_HOUR" --argjson thrw "$LIMITS_STALE_WEEKLY" \
    --argjson thrf "$LIMITS_STALE_FABLE" "$LIMITS_VIEW_JQ"'
    def bucket($b; $thr; $auth):
      (($b.resets_at // null) | limits_store_epoch) as $reset |
      (($b.as_of // null) | limits_store_epoch) as $asof |
      (limits_bucket_expired($now; $reset) or ($b.expired // false)) as $expired |
      (($b.stale // false) or limits_bucket_stale($now; $thr; $auth; ($b.origin // ""); ($asof // 0))) as $stale |
      {eff: (if ($b.used_pct | type) == "number" then limits_effective_pct(($b.effective_pct // $b.used_pct); $expired) else null end), reset: ($reset // 0),
       stale: $stale, expired: $expired, dim: ($stale or $expired), asof: $asof};
    {data: [.vendors[$vendor].accounts[]? |
      ((.auth.status // "ok") == "expired") as $auth |
      bucket(.five_hour; $thr5; $auth) as $h |
      bucket(.weekly; $thrw; $auth) as $w |
      bucket(.fable; $thrf; $auth) as $f |
      ([$h,$w,$f | select(.eff != null) | .asof | select(. != null)] | min) as $asof |
      {name: .account, disabled: (.enabled == false),
       h5: ($h.eff // 0), wk: ($w.eff // 0), fable: $f.eff,
       h5_eff: $h.eff, wk_eff: $w.eff, fable_eff: $f.eff,
       h5_stale: $h.stale, wk_stale: $w.stale, fable_stale: $f.stale,
       h5_expired: $h.expired, wk_expired: $w.expired, fable_expired: $f.expired,
       h5_dim: $h.dim, wk_dim: $w.dim, fable_dim: $f.dim,
       hreset: $h.reset, wreset: $w.reset,
       age: (if $asof == null then null else $now - $asof end)}]}
  ' "$cache" 2>/dev/null || printf '{"data":[]}'
}

accounts_reselect() {
  accounts_result=$("$accounts_rows")
  accounts_picked=$(account_status_chat_account "$accounts_vendor" "$accounts_pick_resolver")
  accounts_show_fable=$(printf '%s' "$accounts_result" | jq -r 'any(.data[]; .fable != null)')
}

collect_accounts() {
  local mode="$1"
  [ -z "${accounts_probe_dir:-}" ] || rm -rf "$accounts_probe_dir"
  accounts_probe_dir=""
  accounts_mode="$mode"
  if [ "$mode" = live ] && [ -n "$accounts_live_probe" ]; then
    accounts_probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/account-status.XXXXXX")
    "$accounts_live_probe" "$accounts_probe_dir"
  fi
  accounts_reselect
}

accounts_refresh_start() {
  local refresh_rc
  [ -z "${accounts_refresh_pid:-}" ] || return 1
  accounts_refresh_dir=$(mktemp -d "${TMPDIR:-/tmp}/account-status-refresh.XXXXXX") || { accounts_refresh_dir=''; return 1; }
  accounts_refresh_started=$(date +%s)
  # Job control puts the wrapper in its own process group, so cancelling can take
  # down the refresh children with it — a bare kill orphans them mid-request.
  # Redirect the parent too: shell job-control diagnostics also belong in the log.
  {
    set -m
    {
      # A failed refresh must still write the sentinel, or the spinner never stops.
      refresh_rc=0
      "$accounts_refresh_action" "$accounts_refresh_dir" "${1:-}" || refresh_rc=$?
      printf '%s\n' "$refresh_rc" >"$accounts_refresh_dir/.result"
      printf 'done\n' >"$accounts_refresh_dir/.done"
    } &
    accounts_refresh_pid=$!
    set +m
  } >"$accounts_refresh_dir/probe.log" 2>&1
  return 0
}

accounts_refresh_running() {
  [ -n "${accounts_refresh_pid:-}" ] || return 1
  [ ! -e "$accounts_refresh_dir/.done" ]
}

accounts_refresh_kill() {
  if [ -n "${accounts_refresh_pid:-}" ]; then
    kill -- "-$accounts_refresh_pid" 2>/dev/null || kill "$accounts_refresh_pid" 2>/dev/null || true
    wait "$accounts_refresh_pid" 2>/dev/null || true
  fi
  [ -z "${accounts_refresh_dir:-}" ] || rm -rf "$accounts_refresh_dir"
  accounts_refresh_pid=''
  accounts_refresh_dir=''
}

accounts_refresh_finish() {
  wait "$accounts_refresh_pid" 2>/dev/null || true
  [ -z "${accounts_probe_dir:-}" ] || rm -rf "$accounts_probe_dir"
  accounts_probe_dir="$accounts_refresh_dir"
  accounts_mode=live
  accounts_reselect
  accounts_status_line=$("$accounts_refresh_summary" "$accounts_probe_dir")
  # Ownership moved to accounts_probe_dir; drop the ref so kill/cleanup never double-frees.
  accounts_refresh_dir=''
  accounts_refresh_pid=''
}

accounts_spinner_frame() {
  local i="$1"
  local -a frames=('|' '/' '-' '\')
  printf '%s' "${frames[$(( i % ${#frames[@]} ))]}"
}

interactive_cleanup() {
  if [ -t 1 ]; then
    stty sane echo </dev/tty >/dev/tty 2>/dev/null || true
    tput cnorm 2>/dev/null || true
  fi
}

colored_percent() {
  local value="$1" dim="${2:-false}" mark="${3:-}" color pre=''
  if [ "$value" -lt 50 ]; then color=$'\033[32m'
  elif [ "$value" -lt 80 ]; then color=$'\033[33m'
  else color=$'\033[31m'
  fi
  [ "$dim" != true ] || pre=$'\033[2m'
  printf '%b%b%6s%b' "$pre" "$color" "${value}%${mark}" $'\033[0m'
}

render_sort_tab() {
  local label="$1" index="$2" active="$3"
  if [ "$index" -eq "$active" ]; then printf '\033[7m%s\033[0m' "$label"
  else printf '%s' "$label"
  fi
}

accounts_sort_filter() {
  case "$1" in
    name) printf '.data | sort_by(.name)[]' ;;
    h5) printf '.data | sort_by([-.h5, .name])[]' ;;
    wk) printf '.data | sort_by([-.wk, .name])[]' ;;
    fable) printf '.data | sort_by([-((.fable // -1)), .name])[]' ;;
    hreset) printf '.data | sort_by([(if .hreset > 0 then .hreset else 99999999999 end), .name])[]' ;;
    wreset) printf '.data | sort_by([(if .wreset > 0 then .wreset else 99999999999 end), .name])[]' ;;
  esac
}

sorted_account_names() {
  printf '%s' "$accounts_result" | jq -r "$(accounts_sort_filter "$1") | .name"
}

selection_after_move() {
  local dir="$1" cur="$2"; shift 2
  local -a names=("$@")
  local n=${#names[@]} i idx=-1
  if [ "$n" -eq 0 ]; then return 0; fi
  for i in "${!names[@]}"; do
    if [ "${names[$i]}" = "$cur" ]; then idx=$i; break; fi
  done
  if [ "$idx" -lt 0 ]; then
    if [ "$dir" = down ]; then idx=0; else idx=$((n - 1)); fi
  elif [ "$dir" = down ]; then
    [ "$idx" -lt $((n - 1)) ] && idx=$((idx + 1)) || true
  else
    [ "$idx" -gt 0 ] && idx=$((idx - 1)) || true
  fi
  printf '%s' "${names[$idx]}"
}

render_interactive_accounts() {
  local active="$1" sort_key="$2" sel="${3:-}" filter row name h5 wk fable hreset wreset age age_text marker off_text index=0
  local h5_mk wk_mk fable_mk h5_dim wk_dim fable_dim disabled hcell wcell sep_width row_out inv=$'\033[7m' sgr0=$'\033[0m'
  local render_now="$("$accounts_now")"
  printf '\033[H\033[2J'
  printf '  '
  render_sort_tab "$(printf '%-16s' NAME)" "$index" "$active"; index=$((index + 1)); printf ' '
  render_sort_tab "$(printf '%6s' 5H)" "$index" "$active"; index=$((index + 1)); printf '  '
  render_sort_tab "$(printf '%6s' WEEKLY)" "$index" "$active"; index=$((index + 1)); printf '  '
  if [ "$accounts_show_fable" = true ]; then
    render_sort_tab "$(printf '%6s' FABLE)" "$index" "$active"; index=$((index + 1)); printf '  '
  fi
  render_sort_tab "$(printf '%-11s' '5H RESET')" "$index" "$active"; index=$((index + 1)); printf ' '
  render_sort_tab "$(printf '%-11s' 'WEEKLY RESET')" "$index" "$active"
  printf ' AGE\n'
  sep_width=62
  [ "$accounts_show_fable" != true ] || sep_width=70
  printf '─%.0s' $(seq 1 "$sep_width"); printf '\n'
  filter=$(accounts_sort_filter "$sort_key")
  while IFS= read -r row; do
    IFS=$'\x1f' read -r name h5 wk fable h5_mk wk_mk fable_mk hreset wreset age h5_dim wk_dim fable_dim disabled < <(printf '%s' "$row" | jq -r --argjson now "$render_now" "$LIMITS_VIEW_JQ"'
      [.name,
       (if .h5_eff == null then "" else (.h5_eff | round | tostring) end),
       (if .wk_eff == null then "" else (.wk_eff | round | tostring) end),
       (if .fable_eff == null then "" else (.fable_eff | round | tostring) end),
       limits_markers(.h5_stale; .h5_expired),
       limits_markers(.wk_stale; .wk_expired),
       limits_markers(.fable_stale; .fable_expired),
       limits_reset_text(.hreset; $now), limits_reset_text(.wreset; $now),
       limits_age_text(.age),
       (.h5_dim | tostring), (.wk_dim | tostring), (.fable_dim | tostring),
       ((.disabled // false) | tostring)] | join("\u001f")')
    age_text="$age"
    if [ "$accounts_mode" = live ] && [ -n "$accounts_live_age" ]; then
      age_text=$("$accounts_live_age" "$name" "$age")
    fi
    marker=' '
    [ "$name" = "$accounts_picked" ] && marker='*'
    off_text=""
    [ "$disabled" != true ] || off_text=" off"
    hcell=$(printf '%-11s' "$hreset")
    [ "$h5_dim" != true ] || hcell=$'\033[2m'"$hcell"$'\033[0m'
    wcell=$(printf '%-11s' "$wreset")
    [ "$wk_dim" != true ] || wcell=$'\033[2m'"$wcell"$'\033[0m'
    row_out=$(
      printf '%s %-16s ' "$marker" "$name"
      if [ -n "$h5" ]; then colored_percent "$h5" "$h5_dim" "$h5_mk"; else printf '%6s' -; fi
      printf '  '
      if [ -n "$wk" ]; then colored_percent "$wk" "$wk_dim" "$wk_mk"; else printf '%6s' -; fi
      printf '  '
      if [ "$accounts_show_fable" = true ]; then
        if [ -n "$fable" ]; then colored_percent "$fable" "$fable_dim" "$fable_mk"; else printf '%6s' -; fi
        printf '  '
      fi
      printf '%s %s %s%s' "$hcell" "$wcell" "$age_text" "$off_text"
    )
    if [ -n "$sel" ] && [ "$name" = "$sel" ]; then
      # Re-assert reverse-video after every embedded reset so the whole row stays highlighted.
      printf '%s\n' "${inv}${row_out//$sgr0/$sgr0$inv}${sgr0}"
    else
      printf '%s\n' "$row_out"
    fi
  done < <(printf '%s' "$accounts_result" | jq -c "$filter")
  printf '\n\033[33m↑/↓ select  ⏎ launch  ←/→ sort  r refresh  q/Esc exit\033[0m\n'
  [ -z "${accounts_status_line:-}" ] || printf '%s\n' "$accounts_status_line"
}

interactive_accounts() {
  local active=0 key next final sort_count sel='' dir name rc spin_i=0 elapsed
  local -a sort_keys names
  accounts_launch=''
  accounts_refresh_pid=''
  accounts_refresh_dir=''
  accounts_status_line=''
  trap 'interactive_cleanup; accounts_refresh_kill; [ -z "${accounts_probe_dir:-}" ] || rm -rf "$accounts_probe_dir"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  sel=$(printf '%s' "$accounts_result" | jq -r '.data | sort_by(.name) | .[0].name // empty')
  if printf '%s' "$accounts_result" | jq -e --arg name "$accounts_picked" 'any(.data[]; .name == $name)' >/dev/null; then
    sel="$accounts_picked"
  fi
  tput civis 2>/dev/null || true
  while :; do
    sort_keys=(name h5 wk)
    [ "$accounts_show_fable" != true ] || sort_keys+=(fable)
    sort_keys+=(hreset wreset)
    sort_count=${#sort_keys[@]}
    [ "$active" -lt "$sort_count" ] || active=0
    if [ -n "$accounts_refresh_pid" ] && ! accounts_refresh_running; then
      accounts_refresh_finish
    fi
    if [ -n "$accounts_refresh_pid" ]; then
      elapsed=$(( $(date +%s) - accounts_refresh_started ))
      accounts_status_line=$(printf '\033[36m⟳ refreshing… %s (%ss)\033[0m' "$(accounts_spinner_frame "$spin_i")" "$elapsed")
      [ $(( spin_i % 3 )) -ne 0 ] || accounts_reselect
    fi
    render_interactive_accounts "$active" "${sort_keys[$active]}" "$sel" || return 1
    # A read timeout must not trip set -e; idle timeouts also reload the cache.
    if [ -n "$accounts_refresh_pid" ]; then
      rc=0
      IFS= read -rsn1 -t 0.3 key || rc=$?
      spin_i=$((spin_i + 1))
      if [ "$rc" -gt 128 ]; then continue; fi
      [ "$rc" -eq 0 ] || return 0
    else
      rc=0
      IFS= read -rsn1 -t 5 key || rc=$?
      if [ "$rc" -gt 128 ]; then accounts_reselect; continue; fi
      [ "$rc" -eq 0 ] || return 0
    fi
    case "$key" in
      q|$'\003') return 0 ;;
      ''|$'\r'|$'\n')
        if [ -n "$sel" ]; then accounts_launch="$sel"; return 0; fi
        ;;
      r)
        [ -n "$accounts_refresh_pid" ] || accounts_refresh_start "$sel" || true
        ;;
      $'\033')
        if ! IFS= read -rsn1 -t 0.08 next; then return 0; fi
        [ "$next" = '[' ] || return 0
        if ! IFS= read -rsn1 -t 0.08 final; then return 0; fi
        case "$final" in
          C) active=$(( (active + 1) % sort_count )) ;;
          D) active=$(( (active + sort_count - 1) % sort_count )) ;;
          A|B)
            names=()
            while IFS= read -r name; do names+=("$name"); done < <(sorted_account_names "${sort_keys[$active]}")
            if [ "$final" = A ]; then dir=up; else dir=down; fi
            if [ "${#names[@]}" -gt 0 ]; then sel=$(selection_after_move "$dir" "$sel" "${names[@]}"); fi
            ;;
        esac
        ;;
    esac
  done
}

account_status_show() {
  local mode="${1:-live}" force_plain="${2:-false}" allow_spend="${3:-false}" start_windows="${4:-false}" heal="${5:-false}"
  accounts_allow_spend="$allow_spend"
  accounts_start_windows="$start_windows"
  accounts_heal="$heal"
  accounts_probe_dir=''
  accounts_launch=''
  accounts_refresh_pid=''
  accounts_refresh_dir=''
  # The caller's rows function is authoritative in BOTH renders: claudeb builds rows from its own
  # per-profile limits store, and reading ~/.llm-limits.json instead emptied the interactive table
  # on any machine the collector had not written yet.
  local accounts_rows="${accounts_rows:-account_status_rows}"
  # A pty without a usable TERM (Emacs compilation buffer, CI) cannot show the picker: it would
  # get raw escapes and a read that never returns instead of the plain table.
  local interactive=true
  { [ "$force_plain" != true ] && [ -t 1 ] && [ -n "${TERM:-}" ] && [ "${TERM:-}" != dumb ]; } ||
    interactive=false
  collect_accounts "$mode"
  trap 'interactive_cleanup; accounts_refresh_kill; [ -z "${accounts_probe_dir:-}" ] || rm -rf "$accounts_probe_dir"' EXIT
  if [ "$interactive" = true ]; then
    if ! interactive_accounts; then
      interactive_cleanup
      "$accounts_plain"
    fi
  else
    "$accounts_plain"
  fi
  # The launch hook may exec, so cancel refresh children before handing over the terminal.
  accounts_refresh_kill
  [ -z "$accounts_probe_dir" ] || rm -rf "$accounts_probe_dir"
  accounts_probe_dir=''
  trap - EXIT INT TERM
  interactive_cleanup
  "$accounts_launch_hook"
}
