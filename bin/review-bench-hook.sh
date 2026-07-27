#!/usr/bin/env bash
set -u

input=$(cat) || exit 0

field() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }

hook_event=$(field '.hook_event_name')
[ "$hook_event" = PreToolUse ] || [ "$hook_event" = PostToolUse ] || exit 0
[ "$(field '.tool_name')" = Bash ] || exit 0

command=$(field '.tool_input.command')
command_re='(^|[[:space:];&|()])([^[:space:];&|()]*/)?review-bench[[:space:]]+(review|run)[[:space:]]+([^[:space:];&|()<>`$]+)'
[[ "$command" =~ $command_re ]] || exit 0
action=${BASH_REMATCH[3]}
first_arg=${BASH_REMATCH[4]}

commitish=""
tier=""
raters=""
if [ "$action" = review ]; then
  if [[ "$first_arg" =~ ^T[0-3]$ ]]; then
    tier=$first_arg
    commitish=HEAD
  else
    tier_re='--tier(=|[[:space:]]+)(T[0-3])([^A-Za-z0-9]|$)'
    [[ "$command" =~ $tier_re ]] || exit 0
    tier=${BASH_REMATCH[2]}
    commitish=$first_arg
  fi
else
  commitish=$first_arg
  raters_re='--raters(=|[[:space:]]+)([^[:space:];&|()<>`$]+)'
  if [[ "$command" =~ $raters_re ]]; then
    raters=${BASH_REMATCH[2]}
  fi
fi

session_id=$(field '.session_id' | tr -cd 'A-Za-z0-9_-')
[ -n "$session_id" ] || session_id=_
marker_dir="$HOME/.cache/claude-review-bench/$session_id"
marker_file="$marker_dir/running"

if [ "$hook_event" = PostToolUse ]; then
  [ "$action" = run ] || exit 0
  rm -f "$marker_file" 2>/dev/null
  rmdir "$marker_dir" 2>/dev/null
  exit 0
fi

if [ "$action" = run ]; then
  marker_label=""
  if [ -n "$raters" ]; then
    marker_label="bench $commitish: $raters"
  else
    auto_re='--auto(=|[[:space:]]+)([0-9]+)([^0-9]|$)'
    if [[ "$command" =~ $auto_re ]]; then
      marker_label="bench $commitish: auto ${BASH_REMATCH[2]}"
    fi
  fi
  umask 077
  if [ -n "$marker_label" ] && mkdir -p "$marker_dir" 2>/dev/null; then
    epoch=$(date +%s 2>/dev/null || printf '0')
    tmp_marker="$marker_file.tmp.$$"
    printf '%s %s\n' "$marker_label" "$epoch" > "$tmp_marker" 2>/dev/null \
      && mv -f "$tmp_marker" "$marker_file" 2>/dev/null
    rm -f "$tmp_marker" 2>/dev/null
  fi
fi

exit 0
