#!/usr/bin/env bash

input=$(cat) || exit 0
parsed=$(printf '%s' "$input" | jq -r '
  def value: if . == null then "" else tostring end;
  [(.hook_event_name | value), (.agent_type | value), (.agent_id | value | gsub("[^A-Za-z0-9_-]"; "")),
   (.tool_input.description | value),
   ((.tool_input.description // "")
    | (try capture("^Worker account: (?<tag>.+)$") catch {})
    | (.tag // "")
    | gsub("^[[:space:]]+|[[:space:]]+$"; ""))]
  | join("\u001f")
' 2>/dev/null) || exit 0

IFS=$'\x1f' read -r hook_event agent_type agent_id description seed_tag <<< "$parsed"
# The rewrite payload hardcodes hookEventName PreToolUse; any other
# registration must be a silent no-op.
[ "$hook_event" = PreToolUse ] || exit 0
case "$agent_type" in
  codex-worker|claudeb-worker) ;;
  *) exit 0 ;;
esac
[ -n "$agent_id" ] || exit 0

cache_dir="$HOME/.cache/claude-worker-tags"
tag_file="$cache_dir/$agent_id"

if [ -n "$seed_tag" ]; then
  mkdir -p "$cache_dir" || exit 0
  umask 077
  tmp_file="$tag_file.tmp.$$"
  trap 'rm -f "$tmp_file" 2>/dev/null; exit 0' EXIT
  printf '%s\n' "$seed_tag" > "$tmp_file" && mv -f "$tmp_file" "$tag_file"
else
  [ -f "$tag_file" ] || exit 0
  IFS= read -r tag < "$tag_file" || exit 0
  [ -n "$tag" ] || exit 0
  case "$description" in
    "Worker account:"*) exit 0 ;;
  esac
  tag_prefix="$tag — "
  [ "${description:0:${#tag_prefix}}" = "$tag_prefix" ] && exit 0
  if [ -n "$description" ]; then
    updated_description="$tag — $description"
  else
    updated_description=$tag
  fi
  # Worker sessions already bypass permissions; allow avoids a redundant prompt.
  printf '%s' "$input" | jq -c --arg description "$updated_description" '
    {hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      updatedInput: (.tool_input | .description = $description)
    }}
  ' 2>/dev/null || exit 0
fi

marker="$cache_dir/.tag-prune"
now=$(date +%s 2>/dev/null)
marker_mtime=$(stat -f %m "$marker" 2>/dev/null || stat -c %Y "$marker" 2>/dev/null || printf '0')
if [[ "$now" =~ ^[0-9]+$ ]] && [[ "$marker_mtime" =~ ^[0-9]+$ ]] && [ "$((now - marker_mtime))" -gt 3600 ]; then
  find "$cache_dir" -type f ! -name '.tag-prune' -mtime +7 -delete >/dev/null 2>&1
  touch "$marker" 2>/dev/null
fi

exit 0
