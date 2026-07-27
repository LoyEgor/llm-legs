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
  if [ -n "$marker_label" ] && mkdir -p "$marker_dir" 2>/dev/null; then
    umask 077
    epoch=$(date +%s 2>/dev/null || printf '0')
    tmp_marker="$marker_file.tmp.$$"
    printf '%s %s\n' "$marker_label" "$epoch" > "$tmp_marker" 2>/dev/null \
      && mv -f "$tmp_marker" "$marker_file" 2>/dev/null
    rm -f "$tmp_marker" 2>/dev/null
  fi
fi

# The harness carries the session cwd at the top level; tool_input.cwd is a fallback
# for a caller that set one explicitly on the Bash call.
cwd=$(field '.cwd')
[ -n "$cwd" ] || cwd=$(field '.tool_input.cwd')
[ -n "$cwd" ] || exit 0
top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0
sha=$(git -C "$cwd" rev-parse --short=7 "$commitish" 2>/dev/null) || exit 0
repo=$(basename "$top") || exit 0
[ -n "$repo" ] && [ -n "$sha" ] || exit 0

if [ "$action" = review ]; then
  description="review $tier · $repo@$sha"
else
  description="review run · $repo@$sha"
  if [ -n "$raters" ]; then
    IFS=, read -r -a specs <<< "$raters"
    [ "${#specs[@]}" -gt 0 ] || exit 0
    short_raters=${specs[0]}
    [ -n "$short_raters" ] || exit 0
    i=1
    while [ "$i" -lt "${#specs[@]}" ] && [ "$i" -lt 3 ]; do
      [ -n "${specs[$i]}" ] || exit 0
      short_raters="$short_raters,${specs[$i]}"
      i=$((i + 1))
    done
    if [ "${#specs[@]}" -gt 3 ]; then
      short_raters="$short_raters,+$((${#specs[@]} - 3))"
    fi
    description="$description · $short_raters"
  fi
fi

[ "$(field '.tool_input.description')" = "$description" ] && exit 0
printf '%s' "$input" | jq -c --arg description "$description" '
  {hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    updatedInput: (.tool_input | .description = $description)
  }}
' 2>/dev/null
exit 0
