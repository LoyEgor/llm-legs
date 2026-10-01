#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GATE="$ROOT/bin/worker-launch-gate.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" WORKER_RUN_DIR="$WORK/runs"
mkdir -p "$HOME"
unset CLAUDEB_WORKER WORKER_PICK_CONFIG_FILE
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# The deployed gate lets a provably read-only call skip its scan, so every denial below also proves
# the skip swallows none.
export READONLY_COMMAND_LIB="${CLAUDE_SETUP_ROOT:-$ROOT/../claude-setup}/hooks/lib/readonly-command.sh"
[ -r "$READONLY_COMMAND_LIB" ] || fail "readonly-command.sh not readable (set CLAUDE_SETUP_ROOT)"

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

# The hook payload as the harness sends it: an agent's call carries its id beside its type.
raw_verdict() { # extra-json command
  jq -cn --argjson extra "$1" --arg command "$2" \
    '({hook_event_name:"PreToolUse",tool_name:"Bash",session_id:"s1",tool_input:{command:$command}}) * $extra' |
    bash "$GATE" 2>/dev/null
}
expect_as() { # decision extra-json command [reason-fragment]
  asserts=$((asserts + 1))
  local out got
  out=$(raw_verdict "$2" "$3")
  [ -n "$out" ] || out='{}'
  got=$(jq -r '.hookSpecificOutput.permissionDecision // "pass"' <<<"$out" 2>/dev/null)
  [ "${got:-pass}" = "$1" ] || fail "[$3] as $2: expected $1 got ${got:-pass}"
  [ -z "${4:-}" ] || jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out" | grep -Fq -- "$4" ||
    fail "[$3] as $2: the reason does not say [$4]"
}
RELAY='{"agent_type":"codex-worker","agent_id":"a1","tool_input":{"timeout":600000}}'
WAITER='{"agent_type":"review-waiter","agent_id":"a2","tool_input":{"timeout":600000}}'
FORK='{"agent_type":"fork","agent_id":"a3","tool_input":{"timeout":600000}}'

# The codex MCP tools are a headless codex launch outside every launcher.
for mcp_tool in mcp__codex__codex mcp__codex__codex-reply; do
  expect_as deny "{\"tool_name\":\"$mcp_tool\",\"tool_input\":{\"prompt\":\"hi\"}}" '' 'COMPUTER: yes'
done
expect_as pass '{"tool_name":"mcp__other__tool","tool_input":{"prompt":"hi"}}' ''

# The relay and review tokens are the hooks' to stamp; a command setting one forges its owner.
for forged in 'WORKER_RUN_RELAY=codex-worker:a1 worker-run start codex --brief /tmp/b --workdir /tmp' \
  'export WORKER_RUN_RELAY=codex-worker:a1; bash /tmp/launch.sh' 'env WORKER_RUN_RELAY=x python3 go.py' \
  'X=1 REVIEW_BENCH_DOOR=abc review-bench review --mode diff' 'declare -x REVIEW_BENCH_DOOR=abc' \
  'export WORKER_RUN_RELAY=codex-worker:a1; ls' "export WORKER_RUN_REL''AY=x; ls" "declare -x 'REVIEW_BENCH_DOOR'=abc"; do
  expect_as deny "$RELAY" "$forged" 'stamped by the hooks alone'
  expect_as deny '{}' "$forged" 'stamped by the hooks alone'
done
expect_as pass '{}' 'echo "$WORKER_RUN_RELAY"'
expect_as pass '{}' 'grep -n WORKER_RUN_RELAY= bin/worker-run'

# A review panel belongs to the chat's own shell: no agent type launches one, not even from a Monitor.
for agent in "$RELAY" "$WAITER" "$FORK" '{"agent_type":"general-purpose","agent_id":"a4"}'; do
  expect_as deny "$agent" 'review-bench review --tier T0' 'An agent never runs a review'
  expect_as deny "$agent" 'cd /tmp && review-bench run --preset x' 'An agent never runs a review'
  expect_as pass "$agent" 'review-bench review --help'
done
expect_as deny '{"tool_name":"Monitor"}' 'review-bench review --tier T0' 'launches a review panel past the door'
expect_as deny '{"tool_name":"Monitor"}' 'while true; do review-bench run --preset x; done' 'launches a review panel past the door'
expect_as pass '{"tool_name":"Monitor"}' 'tail -f /tmp/log'
# review-waiter alone keeps the recovery of the run it waits on.
expect_as pass "$WAITER" 'review-bench wait 20260924T000000Z-abc1234 --max 540 --relaunch'
expect_as pass "$WAITER" 'review-bench wait 20260924T000000Z-abc1234 --max 540 --finish-partial'
expect_as deny "$FORK" 'review-bench wait 20260924T000000Z-abc1234 --max 540 --relaunch' 'An agent never runs a review'

# A sanctioned tool exempts only its own segment, never the launch chained after it.
expect_as deny '{}' 'llm-limits --table --no-write; claude -p hi' 'bare headless vendor launch'
expect_as deny '{}' 'review-bench debt && codex exec hi' 'bare headless vendor launch'
expect_as deny "$RELAY" 'worker-run wait r1 --max 540; codex exec hi' 'bare headless vendor launch'
expect_as pass '{}' 'llm-limits --table --no-write'

# A help screen launches nothing, while a real launch chained beside one still does.
for help in 'codex help exec' 'codex exec --help' 'claude -p --help' 'claude -p -h' 'codexb exec -h' \
  'gemini -p --help' 'grokb --prompt x --help' 'opencode run --help' 'codex exec --help | head -40' \
  'codex exec --help 2>&1 | head -30' 'codex exec -h 2>&1' 'codex exec --help >/tmp/x.txt' 'codex help exec 2>&1' \
  'codex exec --help > /tmp/out' 'claude -p --help 2> /dev/null'; do
  expect_as pass '{}' "$help"
  expect_as pass "$RELAY" "$help"
done
expect_as deny '{}' 'codex exec --help; codex exec hi' 'bare headless vendor launch'
expect_as deny '{}' 'claude -p "explain --help"' 'bare headless vendor launch'
expect_as deny '{}' 'codex exec help' 'bare headless vendor launch'
expect_as deny '{}' 'gemini help -p "fix src/x.py"' 'bare headless vendor launch'
expect_as deny '{}' 'claude help --print "fix it"' 'bare headless vendor launch'
# A help token inside the prompt is no help screen, however the quotes around it are spelled.
for prompt_help in 'claude -p "compare ls -h output"' 'codex exec "add a --help flag"' \
  "bash -c \"claude -p 'compare ls -h output'\"" "sh -c 'codex exec \"add a --help flag\"'" 'claude -p compare\ ls\ -h'; do
  expect_as deny '{}' "$prompt_help" 'bare headless vendor launch'
done
expect_as pass '{}' 'codex exec --help | grep -i "model"'

# The package runners and lock or exec wrappers put the vendor back in command position.
for wrapped in 'npx claude -p hi' 'bunx codex exec hi' 'pnpx claude -p hi' 'npm exec claude -p hi' \
  'pnpm dlx codex exec hi' 'yarn dlx claude -p hi' 'bun x claude -p hi' 'flock /tmp/l claude -p hi' \
  'exec claude -p hi' 'exec -a name codex exec hi'; do
  expect_as deny '{}' "$wrapped" 'bare headless vendor launch'
done

# A vendor fed on stdin is headless, and a scheduler runs its command where no gate reads it.
for scheduled in 'echo hi | gemini' 'cat /tmp/b | agy' 'printf q | nohup codex' 'echo hi | /opt/homebrew/bin/claude' \
  "echo 'claude -p hi' | at now" "(crontab -l; echo '* * * * * claude -p hi') | crontab -" 'crontab /tmp/tab' \
  'batch < /tmp/job' 'echo hi | "claude"'; do
  expect_as deny '{}' "$scheduled"
done
for plain in 'crontab -l' 'crontab -u me -l' 'false || claude' 'echo x | grep gemini' 'claude --version' \
  "rg 'gemini|claude ' docs" $'cat > /tmp/t.md <<EOF\n| codex | 40% |\nEOF' 'grep -c "agy\|gemini" share/*.py'; do
  expect_as pass '{}' "$plain"
done

# With Light off the relay Agents a deny names are the four vendor relays alone.
printf 'light_paused=on\n' >"$WORK/light-toggle"
WORKER_PICK_CONFIG_FILE="$WORK/light-toggle" expect_as deny '{}' 'claude -p hi' \
  "gemini-worker or grok-worker, the one worker-pick's NEXT row names, a read-only question in a brief"
expect_as deny '{}' 'claude -p hi' 'or light-research for a read-only question'

# The deny names the way that works: a relay is told worker-run start, everyone else the relay Agents.
expect_as deny "$RELAY" 'claude -p hi' 'Launch it through `worker-run start'
expect_as deny '{}' 'claude -p hi' 'claudeb-worker, codex-worker, gemini-worker, grok-worker or light-worker'
expect_as deny '{}' 'ask_codex.sh q' 'claudeb-worker, codex-worker, gemini-worker, grok-worker or light-worker'

# A relay's poll backgrounded behind a redirection or a chain returns before the run does.
expect_as deny "$RELAY" 'worker-run wait r1 --max 540 >/tmp/o 2>&1 &'
expect_as deny "$RELAY" 'cd /tmp && worker-run wait r1 --max 540 &'
expect_as pass "$RELAY" 'worker-run wait r1 --max 540 2>&1'
expect_as pass "$RELAY" 'worker-run wait r1 --max 540 >/tmp/o 2>&1 && cat /tmp/o'
# The `&` a poll is judged by is a shell one, never a character inside a heredoc body or a quote.
expect_as pass '{"agent_type":"light-research","agent_id":"a4","tool_input":{"timeout":600000}}' \
  $'cat >/tmp/q <<\'Q\'\ncompare light-research & worker-run\nQ\nlight-research --question-file /tmp/q'
expect_as pass '{"agent_type":"light-research","agent_id":"a4","tool_input":{"timeout":600000}}' \
  'light-research --question "light-research & worker-run"'

# A sanctioned launcher reading its stdin is still that launcher.
expect_as pass '{}' 'yes | claudeb revive acct1'
expect_as pass '{}' 'printf y | claudeb warm'
expect_as deny '{}' 'yes | claudeb -p hi'

# A quoted operand spanning lines is one word: its later lines are neither commands nor pipes.
for multi in $'git commit -m "Subject\n\nat least one run (at most once)"' \
  $'gh pr create --body "batch jobs\n(at most once)"' $'python3 -c "import x\nbatch = rows"' \
  $'git commit -m "Subject\n\nBody line | claude sees it"' $'git commit -m "t\n\n| codex | 40% |"' \
  $'echo it\'s # a comment\nls'; do
  expect_as pass '{}' "$multi"
done
# And a quote that closes on a later line leaves what follows it in command position.
expect_as deny '{}' $'echo "a\nb"; claude -p hi'
expect_as deny '{}' $'echo "a\\"b\nc"; claude -p hi'

# A relay's header deny says the call ran nothing, and a brief re-found by listing /tmp is another
# relay's.
mkdir -p "$WORK/t/subagents"
jq -cn '{type:"user", message:{content:"ACCOUNT: acct1\nFix it."}}' >"$WORK/t/subagents/agent-a1.jsonl"
RELAY_T=$(jq -cn --arg t "$WORK/t.jsonl" '{agent_type:"codex-worker",agent_id:"a1",transcript_path:$t,tool_input:{timeout:600000}}')
expect_as deny "$RELAY_T" $'BRIEF=$(mktemp /tmp/codex-brief.XXXXXX) && cat >"$BRIEF" <<\'BRIEF_EOF\'\nx\nBRIEF_EOF\nworker-run start codex --brief "$BRIEF" --workdir /w' \
  'retry the SAME call whole'
expect_as pass "$RELAY_T" $'BRIEF=$(mktemp /tmp/codex-brief.XXXXXX) && cat >"$BRIEF" <<\'BRIEF_EOF\'\nx\nBRIEF_EOF\nworker-run start codex --brief "$BRIEF" --workdir /w --account acct1'
for refound in 'BRIEF=$(ls -t /tmp/claudeb-brief.* | head -1); worker-run start codex --brief "$BRIEF" --workdir /w --account acct1' \
  'worker-run start codex --brief "$(find /tmp -name codex-brief.X -newer /tmp/x)" --workdir /w --account acct1' \
  'for b in /tmp/codex-brief.*; do :; done; worker-run start codex --brief "$b" --workdir /w --account acct1'; do
  expect_as deny "$RELAY_T" "$refound" 'another relay'"'"'s brief'
done

# Egor's autonomy span hands the ask_*/probe legs and scheduling back to the model; the mechanical
# denials stay.
printf 'words_span_live() { [ "$1" = s1 ]; }\n' >"$WORK/span-on.sh"
printf 'words_span_live() { [ "$1" = other ]; }\n' >"$WORK/span-off.sh"
for handed in 'ask_codex.sh "what is this"' 'gemini-probe --account rawi' 'crontab /tmp/tab' 'batch < /tmp/job'; do
  WORDS_LIB="$WORK/span-on.sh" expect pass '' "$handed"
  WORDS_LIB="$WORK/span-off.sh" expect deny '' "$handed"
done
WORDS_LIB="$WORK/span-on.sh" expect deny '' 'claude -p hi'
WORDS_LIB="$WORK/span-on.sh" expect deny '' 'echo hi | claude'

printf 'PASS: %s asserts; the launch gate denies inline print flags, every headless codex subcommand, wrapped and program-string vendor calls, comment and operand exemptions, the ask_*/probe legs, image-gen worker-run launches, worker review panels, relay polls that are backgrounded (behind a redirection or a chain too) or outrun their timeout (--max=N read, review-waiter and light-research included), hand-set relay and review tokens, review launches from any agent or a Monitor (review-waiter keeps its recoveries), a launch chained after a sanctioned segment and the package-runner, flock and exec wrappers, a vendor fed through a pipe, at/batch/crontab scheduling and the codex MCP tools, with deny texts naming the relay Agents, while plain reads pass\n' "$asserts"
