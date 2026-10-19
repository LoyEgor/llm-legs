#!/usr/bin/env bash
# PreToolUse(Agent): delegation is the chat's own `worker-run` call, never a subagent. A relay or
# native type is denied with the direct protocol; a fork spawns, its description rewritten to the
# canonical `fork · <model> · <account>: <title>` and seeded for worker-tag-hook.sh. Fail-open.
{
[ -r ~/.claude/hooks/lib/hook-time.sh ] && . ~/.claude/hooks/lib/hook-time.sh
set -u

input=$(cat) || exit 0

direct='Delegate from this chat: write the brief with the Write tool (a heredoc ends early at its delimiter); then ONE Bash with run_in_background `worker-run run %s --brief <file> --workdir <dir>`: it picks the account, starts, waits and prints the whole report, so its completion notification wakes the chat with the answer in that output. Mid-run note: `worker-run say <run-id> "<text>"` (its RUN: line); a run in flight with no live wait gets `worker-run wait <run-id> --report` in the background again.'
# A relay or native type is denied by this one jq: only a fork pulls the prompt into the shell.
parsed=$(jq -r --arg hook "${0##*/}" --arg direct "$direct" '
  [.session_id // "", .hook_event_name // "", .tool_name // "", .tool_input.subagent_type // "",
   .tool_input.description // "", .tool_input.prompt // "", .tool_input.model // "", .transcript_path // "",
   .tool_use_id // ""]
  | ($direct | split("%s")) as [$head, $tail]
  | if any(.[]; iterables) then error("not scalar") else . end
  | if .[1] != "PreToolUse" then [.[0], "skip"]
    elif .[3] == "fork" then [.[0], "fork"] + .[3:]
    else ((.[3] | tostring | if . == "" then "general-purpose" else . end) as $type
      | (if IN($type; "claudeb-worker", "codex-worker", "gemini-worker", "grok-worker", "light-worker") then
           "the \($type) relay is retired. \($head)\($type | rtrimstr("-worker"))\($tail)"
         elif $type == "light-research" then
           "the light-research agent is retired. Run `light-research --prompt-file <file> --out <answer-file> --repo <abs>` as a Bash with run_in_background; its completion notification wakes this chat and the answer is in --out."
         elif $type == "review-waiter" then
           "review-waiter is retired. Run `review-bench wait <run-id>` as a Bash with run_in_background; its completion notification wakes this chat (`--relaunch` / `--finish-partial` recover a dead or interrupted run)."
         else "native \($type) is not spawned. \($head)auto\($tail)" end) as $r
      | [.[0], "deny", ({hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
          permissionDecisionReason: ("[" + $hook + "] " + $r)}} | tojson)])
    end | @sh' <<<"$input" 2>/dev/null) || exit 0
fields=()
eval "fields=($parsed)"
hook_session=${fields[0]-}

case "${fields[1]-}" in
  fork) ;;
  deny) printf '%s\n' "${fields[2]-}"; exit 0 ;;
  *) exit 0 ;;
esac
subagent=${fields[2]-}
description=${fields[3]-}
prompt=${fields[4]-}
account=${CLAUDE_LIMITS_ACCOUNT:-}
if [ -z "$account" ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "$CLAUDE_CONFIG_DIR" != "$HOME/.claude" ]; then
  account=$(basename "$CLAUDE_CONFIG_DIR")
fi
model=${fields[5]-}
if [ -z "$model" ]; then
  transcript=${fields[6]-}
  [ ! -r "$transcript" ] || model=$(tail -n 200 "$transcript" 2>/dev/null |
    jq -rR 'fromjson? | select(type == "object" and .type == "assistant") | .message | objects | .model // empty' 2>/dev/null |
    tail -n1)
fi
model=${model#claude-} model=${model%%-*}
prefix="fork · ${model:-inherit} · ${account:-main}"

title=$description
[[ $title =~ ^[A-Za-z0-9_.?-]+(\ [a-z]+)?(\ ·\ [A-Za-z0-9_.?-]+){1,3}(:\ |\ —\ ) ]] && title=${title#"${BASH_REMATCH[0]}"}
[ -n "$title" ] || title=task

session_id=${hook_session//[^A-Za-z0-9_-]/}
[ -n "$session_id" ] || session_id=_
pending_dir="$HOME/.cache/claude-worker-tags/$session_id"
# One seed per spawn: two forks spawned in the same turn each claim their own, oldest first,
# instead of the second overwriting the first one's tag.
spawn_key=${fields[7]-}
spawn_key=${spawn_key//[^A-Za-z0-9_-]/}
[ -n "$spawn_key" ] || spawn_key="$(date +%s)-$$-$RANDOM"
if [ -d "$pending_dir" ] || mkdir -p "$pending_dir" 2>/dev/null; then
  umask 077
  tmp_pending="$pending_dir/.pending-$subagent.tmp.$$"
  first_line=${prompt%%$'\n'*}
  if command -v sha256sum >/dev/null; then spawn_hash=$(sha256sum <<<"$first_line" 2>/dev/null)
  else spawn_hash=$(shasum -a 256 <<<"$first_line" 2>/dev/null); fi
  { printf '%s\n' "$prefix"; printf 'spawn=%s\n' "${spawn_hash:0:16}"; } > "$tmp_pending" 2>/dev/null &&
    mv -f "$tmp_pending" "$pending_dir/pending-$subagent-$spawn_key" 2>/dev/null
  [ ! -e "$tmp_pending" ] || rm -f "$tmp_pending" 2>/dev/null
fi

updated="$prefix: $title"
[ "$updated" != "$description" ] || exit 0

jq -c --arg description "$updated" '
  {hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    updatedInput: (.tool_input | .description = $description)
  }}
' <<<"$input" 2>/dev/null
exit 0
exit; }
