#!/usr/bin/env bash
# PreToolUse(Agent): delegation is the chat's own `worker-run` call, never a subagent. A relay or
# native type is denied with the direct protocol; a fork spawns, its description rewritten to the
# canonical `fork · <model> · <account>: <title>` and seeded for worker-tag-hook.sh. Fail-open.
{
[ -r ~/.claude/hooks/lib/hook-time.sh ] && . ~/.claude/hooks/lib/hook-time.sh
set -u

input=$(cat) || exit 0

direct='Delegate from this chat: write the brief with the Write tool (a heredoc ends early at its delimiter); Bash `worker-run start %s --brief <file> --workdir <dir>` (prints RUN:/TAG:/DIR:); then Bash with run_in_background `worker-run wait <run-id>`; on its completion notification, `worker-run report <run-id>`. Mid-run note: `worker-run say <run-id> "<text>"`; a run in flight with no live wait gets `worker-run wait <run-id>` in the background again.'
# A relay or native type is denied by this one jq: only a fork pulls the prompt into the shell.
parsed=$(jq -r --arg hook "${0##*/}" --arg direct "$direct" '
  [.session_id // "", .hook_event_name // "", .tool_name // "", .tool_input.subagent_type // "",
   .tool_input.description // "", .tool_input.prompt // "", .tool_input.model // "", .transcript_path // "",
   .tool_use_id // ""]
  | ($direct | split("%s")) as [$head, $tail]
  | if any(.[]; iterables) then error("not scalar") else . end
  | if .[1] != "PreToolUse" or .[2] == "Workflow" then [.[0], "skip"]
    elif .[3] == "fork" then [.[0], "fork"] + .[3:]
    else ((.[3] | tostring | if . == "" then "general-purpose" else . end) as $type
      | (if IN($type; "claudeb-worker", "codex-worker", "gemini-worker", "grok-worker", "light-worker") then
           "the \($type) relay is retired. \($head)\($type | rtrimstr("-worker"))\($tail)"
         elif $type == "light-research" then
           "the light-research agent is retired. Run `light-research --prompt-file <file> --out <answer-file> --repo <abs>` as a Bash with run_in_background; its completion notification wakes this chat and the answer is in --out; a call that ends on `STATUS: running` is resumed with `light-research --attach <run-id> --out <answer-file>` in the background."
         elif $type == "review-waiter" then
           "review-waiter is retired. Run `review-bench wait <run-id>` as a Bash with run_in_background; its completion notification wakes this chat (`--relaunch` / `--finish-partial` recover a dead or interrupted run)."
         else "native \($type) is not spawned. \($head)<vendor of worker-pick'"'"'s START line>\($tail)" end) as $r
      | [.[0], "deny", ({hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
          permissionDecisionReason: ("[" + $hook + "] " + $r)}} | tojson)])
    end | @sh' <<<"$input" 2>/dev/null) || exit 0
fields=()
eval "fields=($parsed)"
hook_session=${fields[0]-}
[ -z "$hook_session" ] || export CLAUDE_CODE_SESSION_ID="$hook_session"

case "${fields[1]-}" in
  fork) ;;
  deny) printf '%s\n' "${fields[2]-}"; exit 0 ;;
  *) exit 0 ;;
esac
subagent=${fields[2]-}
description=${fields[3]-}
prompt=${fields[4]-}
session_account() {
  local acct=${CLAUDE_LIMITS_ACCOUNT:-}
  if [ -z "$acct" ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "$CLAUDE_CONFIG_DIR" != "$HOME/.claude" ]; then
    acct=$(basename "$CLAUDE_CONFIG_DIR")
  fi
  printf '%s' "${acct:-main}"
}
model_short() { # model id
  local model=${1#claude-}
  printf '%s' "${model%%-*}"
}
model=${fields[5]-}
if [ -z "$model" ]; then
  transcript=${fields[6]-}
  [ ! -r "$transcript" ] || model=$(tail -n 200 "$transcript" 2>/dev/null |
    jq -rR 'fromjson? | select(type == "object" and .type == "assistant") | .message | objects | .model // empty' 2>/dev/null |
    tail -n1)
fi
model=$(model_short "$model")
prefix="fork · ${model:-inherit} · $(session_account)"

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
  spawn_hash=$(printf '%s\n' "$first_line" | if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi 2>/dev/null)
  { printf '%s\n' "$prefix"; printf 'spawn=%s\n' "${spawn_hash:0:16}"; } > "$tmp_pending" 2>/dev/null &&
    mv -f "$tmp_pending" "$pending_dir/pending-$subagent-$spawn_key" 2>/dev/null
  [ ! -e "$tmp_pending" ] || rm -f "$tmp_pending" 2>/dev/null
fi

updated="$prefix: $title"
[ "$updated" != "$description" ] || exit 0

printf '%s' "$input" | jq -c --arg description "$updated" '
  {hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    updatedInput: (.tool_input | .description = $description)
  }}
' 2>/dev/null
exit 0
exit; }
