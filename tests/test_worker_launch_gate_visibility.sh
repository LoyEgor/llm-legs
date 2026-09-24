#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GATE="$ROOT/bin/worker-launch-gate.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" WORKER_RUN_DIR="$WORK/runs"
mkdir -p "$HOME"
unset CLAUDEB_WORKER
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

verdict() { # agent command [timeout-ms|null] [background]
  jq -cn --arg agent "$1" --arg command "$2" --argjson timeout "${3:-null}" --argjson bg "${4:-false}" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",session_id:"s1"}
     + (if $agent == "" then {} else {agent_type:$agent} end)
     + {tool_input:({command:$command} + (if $timeout == null then {} else {timeout:$timeout} end)
         + (if $bg then {run_in_background:true} else {} end))}' |
    bash "$GATE" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision // "pass"' 2>/dev/null
}
expect() { # decision agent command [timeout] [background]
  asserts=$((asserts + 1))
  local got
  got=$(verdict "${@:2}")
  [ "${got:-pass}" = "$1" ] || fail "[$3] as ${2:-main}: expected $1 got ${got:-pass}"
}

# 9: a print flag with an inline value is still headless.
expect deny '' 'claude --prompt=hi'
expect deny '' 'claude -p=hi'

# 42: every headless codex subcommand, codexb included.
expect deny '' 'codex e hi'
expect deny '' 'codex review'
expect deny '' 'codexb exec hi'

# 41: wrappers and program strings put the vendor back in command position.
for wrapped in "env -S 'claude -p hi'" 'eval "claude -p hi"' "tmux new -d 'codex exec hi'" \
  'nohup claude -p hi' 'caffeinate -i codex exec hi' 'sudo -u me claude -p hi' \
  'script -q /dev/null claude -p hi' 'watch -n1 claude -p hi' 'ssh host codex exec hi' \
  'find . -exec claude -p hi \;' 'xargs -I{} claude -p {}' 'setsid claude -p hi' \
  'stdbuf -oL codex exec hi' 'unbuffer claude -p hi' 'launchctl asuser 501 claude -p hi' \
  'arch -arm64 claude -p hi' "screen -dm codex exec hi" 'timeout 60 claude -p hi' "su me -c 'claude -p hi'"; do
  expect deny '' "$wrapped"
done

# 38: a sanctioned word exempts only from command position, never from a comment or an operand.
expect deny '' 'claude -p hi # worker-run'
expect deny '' 'codex exec hi; ls ~/bin/light-research'
expect pass '' 'ls ~/.local/bin/worker-run'
expect pass '' 'git log --grep codex'

# 40: the ask_* legs and the live probes run from no Claude Code Bash; reading a served model does.
expect deny '' 'ask_codex.sh "what is this"'
expect deny '' '~/.local/bin/ask_claude.sh --model opus q'
expect deny '' 'bin/codex-fast-probe'
expect deny '' 'gemini-probe --account rawi'
expect deny codex-worker 'ask_gemini.sh q'
expect pass '' 'ask_claude.sh --extract-served-model /tmp/out.json'

# 13: image-gen owns the image scripts, not worker-run launches.
expect deny image-gen 'worker-run start codex --brief /tmp/b --workdir /tmp'

# 23: a headless worker never launches a review panel; a plain wait stays open.
expect pass '' 'review-bench review --mode diff'
asserts=$((asserts + 1))
[ "$(CLAUDEB_WORKER=1 verdict '' 'review-bench review --mode diff')" = deny ] || fail "worker review-bench review passed"
asserts=$((asserts + 1))
[ "$(CLAUDEB_WORKER=1 verdict '' 'review-bench run --preset x')" = deny ] || fail "worker review-bench run passed"
asserts=$((asserts + 1))
[ "$(CLAUDEB_WORKER=1 verdict '' 'review-bench wait 20260924T000000Z-abc1234 --relaunch')" = deny ] ||
  fail "worker review-bench wait --relaunch passed"

# 10: `--max=N` is read as N.
expect pass codex-worker 'worker-run wait r1 --max=540' 600000
expect deny codex-worker 'worker-run wait r1 --max=540' 200000

# 43: review-waiter and light-research polls are held to the same timeout rule.
expect deny review-waiter 'review-bench wait 20260924T000000Z-abc1234' 600000
expect deny review-waiter 'review-bench wait 20260924T000000Z-abc1234 --max 540' 120000
expect pass review-waiter 'review-bench wait 20260924T000000Z-abc1234 --max 540' 600000
expect deny light-research 'light-research --attach r1 --out /tmp/o' 120000
expect pass light-research 'light-research --attach r1 --out /tmp/o' 600000

# 44: a backgrounded poll, or one through a variable with no timeout, lets the relay return early.
expect deny codex-worker 'worker-run wait r1 --max 540' 600000 true
expect deny codex-worker 'W=~/.local/bin/worker-run; $W wait r1'

printf 'PASS: %s asserts; the launch gate denies inline print flags, every headless codex subcommand, wrapped and program-string vendor calls, comment and operand exemptions, the ask_*/probe legs, image-gen worker-run launches, worker review panels, and relay polls that are backgrounded or outrun their timeout (--max=N read, review-waiter and light-research included), while plain reads pass\n' "$asserts"
