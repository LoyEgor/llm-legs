#!/usr/bin/env bash
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUS=${REPORT_BUS_BIN:-$ROOT/bin/report-bus}
WORK=$(mktemp -d)
trap 'chmod -R u+w "$WORK"; rm -rf "$WORK"' EXIT
export HOME="$WORK/home" XDG_CACHE_HOME="$WORK/cache" WORKER_RUN_IDLE_S=0
unset CLAUDEB_WORKER GROK_WORKER CLAUDE_LAUNCHER_SESSION CLAUDE_CODE_SESSION_ID WORKER_RUN_DIR REVIEW_BENCH_SESSION_DIR
mkdir -p "$HOME" "$WORK/bin"
STORE="$XDG_CACHE_HOME/claude-reports"
asserts=0
assert() { asserts=$((asserts + 1)); "$@" || { printf 'FAIL: assert %s: %s\n' "$asserts" "$*" >&2; exit 1; }; }
count() { find "$1" -maxdepth 1 -type f -name '*.txt' 2>/dev/null | wc -l | tr -d ' '; }
post() { printf '%s' "${3:-body}" | "$BUS" post --kind notice --id "$2" --session "$1"; }
flush() { printf '{"session_id":"%s"}\n' "$1" | "$BUS" flush --event "${2:-PostToolUse}"; }
message() { jq -r .systemMessage; }

post basic one 'first  '
assert test "$(count "$STORE/basic/pending")" = 1
post basic one changed
assert test "$(count "$STORE/basic/pending")" = 1
assert test "$(jq -r .body "$STORE/basic/pending/"*.txt)" = 'first  '
rc=0
printf body | "$BUS" post --kind bogus --session basic 2>"$WORK/error" || rc=$?
assert test "$rc" = 2
for args in 'post --kind notice --session ../escape' 'flush --event bogus' 'list --last -1' 'emit --kind notice --session basic' 'doctor --last 1'; do
  rc=0
  # shellcheck disable=SC2086
  "$BUS" $args </dev/null 2>"$WORK/error" || rc=$?
  assert test "$rc" = 2
done
post basic two second
first=$(find "$STORE/basic/pending" -name '*__one.txt')
second=$(find "$STORE/basic/pending" -name '*__two.txt')
touch -t 202001010001 "$first"
touch -t 202001010002 "$second"
clock=$(jq -r .clock "$first")
clock2=$(jq -r .clock "$second")
output=$(flush basic)
expected=$(printf '▌ notice · %s\nfirst\n\n▌ notice · %s\nsecond' "$clock" "$clock2")
assert test "$(message <<<"$output")" = "$expected"
assert test "$(count "$STORE/basic/pending")" = 0
assert test "$(count "$STORE/basic/delivered")" = 2
assert test "$(jq -s length "$STORE/history.log")" = 2
assert jq -e 'select(.id == "one") | .session == "basic" and .kind == "notice" and .event == "PostToolUse" and .epoch > 0 and .bytes == (.text | utf8bytelength)' "$STORE/history.log" >/dev/null
post basic one again
assert test "$(count "$STORE/basic/pending")" = 0
assert test "$("$BUS" list --session basic)" = "$expected"
assert test "$("$BUS" list --session basic --last 1)" = "$(printf '▌ notice · %s\nsecond' "$clock")"
assert test -z "$("$BUS" list --session basic --last 0)"

for event in PostToolUse SubagentStop Stop UserPromptSubmit; do
  post "event-$event" item
  assert test -n "$(flush "event-$event" "$event")"
  assert test "$(count "$STORE/event-$event/pending")" = 0
  assert jq -e --arg e "$event" 'select(.session == ("event-" + $e)) | .event == $e' "$STORE/history.log" >/dev/null
done

post skipped item
output=$(CLAUDEB_WORKER=1 "$BUS" flush --session skipped --event Stop </dev/null)
assert test -z "$output"
assert test "$(count "$STORE/skipped/pending")" = 1
for payload in '{"agent_id":"child"}' '{"transcript_path":"/tmp/subagents/child.jsonl"}' \
  '{"agent_type":"codex-worker"}' '{"agent_type":"claudeb-worker"}' '{"agent_type":"gemini-worker"}' \
  '{"agent_type":"grok-worker"}' '{"agent_type":"image-gen"}' '{"agent_type":"gemini-research"}'; do
  output=$(jq '. + {session_id:"skipped"}' <<<"$payload" | "$BUS" flush --event Stop)
  assert test -z "$output"
  assert test "$(count "$STORE/skipped/pending")" = 1
done
assert test -n "$(flush skipped Stop)"

printf 'line 1\n  line 2\t\n' >"$WORK/body"
export CLAUDE_CODE_SESSION_ID=emitted
output=$("$BUS" emit --kind commit --repo /some/project/ --title 'Done' --id commit "$WORK/body")
clock=$(date +%H:%M)
block=$(printf '▌ commit · project · %s · Done\nline 1\n  line 2' "$clock")
assert test "$(message <<<"$output")" = "$(printf '\n%s' "$block")"
assert test "$("$BUS" list)" = "$block"
assert test "$(count "$STORE/emitted/pending")" = 0
assert test -z "$("$BUS" emit --kind commit --id commit "$WORK/body")"
for kind in review push pool-run worker notice; do
  assert test -n "$(printf body | "$BUS" emit --kind "$kind")"
done
unset CLAUDE_CODE_SESSION_ID

large=$(printf '%09000d' 0)
post capped first "$large"
post capped second "$large"
output=$(flush capped)
assert test "$(message <<<"$output" | wc -c | tr -d ' ')" -le 16000
assert test "$(count "$STORE/capped/pending")" = 1
assert test "$(count "$STORE/capped/delivered")" = 1
assert test "$(jq -s '[.[] | select(.session == "capped")] | length' "$STORE/history.log")" = 1
assert test -n "$(flush capped)"
post oversized huge "$(printf '%020000d' 0)"
post oversized small 'small report'
touch -t 202001010001 "$STORE/oversized/pending/"*__huge.txt
output=$(flush oversized)
assert test "$(message <<<"$output" | tail -n1)" = "$(printf '%020000d' 0)"
assert test "$(count "$STORE/oversized/pending")" = 1
assert test "$(message <<<"$(flush oversized)" | tail -n1)" = 'small report'

post broken item
broken=$(find "$STORE/broken/pending" -name '*.txt')
printf 'not JSON\n' >"$broken"
assert test -z "$(flush broken)"
output=$(flush broken Stop)
assert test "$(message <<<"$output")" = "report-bus: 1 report(s) undelivered — $STORE/broken/pending"
assert test -f "$broken"
assert test "$(count "$STORE/broken/delivered")" = 0
post broken valid 'still deliverable'
output=$(flush broken Stop)
assert test "$(message <<<"$output" | tail -n1)" = "report-bus: 1 report(s) undelivered — $STORE/broken/pending"
assert test "$(count "$STORE/broken/pending")" = 1

printf orphan | "$BUS" post --kind notice --id orphan
assert test "$(count "$STORE/_orphan/pending")" = 1
output=$(flush adopter UserPromptSubmit)
assert test "$(message <<<"$output" | sed -n '2p')" = 'chat: unknown'
assert test "$(count "$STORE/_orphan/pending")" = 0
assert test "$(count "$STORE/adopter/delivered")" = 1
printf orphan | "$BUS" post --kind notice --id orphan
assert test "$(count "$STORE/_orphan/pending")" = 0
assert test -z "$(flush another)"

export WORKER_RUN_DIR="$HOME/.cache/claude-worker-runs"
mkdir -p "$WORKER_RUN_DIR/outer" "$WORKER_RUN_DIR/inner"
printf 'launch-chat\n' >"$WORKER_RUN_DIR/outer/launcher"
printf 'outer-session\n' >"$WORKER_RUN_DIR/outer/worker-session"
printf 'outer-session\n' >"$WORKER_RUN_DIR/inner/launcher"
printf 'inner-session\n' >"$WORKER_RUN_DIR/inner/worker-session"
export CLAUDE_CODE_SESSION_ID=inner-session CLAUDE_LAUNCHER_SESSION=outer-session
post explicit wins
assert test "$(count "$STORE/explicit/pending")" = 1
printf chain | "$BUS" post --kind worker --id chain
assert test "$(count "$STORE/launch-chat/pending")" = 1
WORKER_RUN_DIR="$WORKER_RUN_DIR/inner" CLAUDE_LAUNCHER_SESSION=wrong "$BUS" post --kind worker --id direct <<<direct
assert test "$(count "$STORE/launch-chat/pending")" = 2
unset CLAUDE_LAUNCHER_SESSION
printf chain | "$BUS" post --kind worker --id env-chain
assert test "$(count "$STORE/launch-chat/pending")" = 3
export CLAUDE_CODE_SESSION_ID=plain-chat
printf plain | "$BUS" post --kind notice --id plain
assert test "$(count "$STORE/plain-chat/pending")" = 1
unset CLAUDE_CODE_SESSION_ID
mkdir -p "$HOME/.claude/sessions"
printf '{"sessionId":"registry-chat"}\n' >"$HOME/.claude/sessions/$$.json"
printf registry | "$BUS" post --kind notice --id registry
assert test "$(count "$STORE/registry-chat/pending")" = 1
rm "$HOME/.claude/sessions/$$.json"
printf fallback | "$BUS" post --kind notice --id fallback
assert test "$(count "$STORE/_orphan/pending")" = 1
flush cleanup >/dev/null

printf 'same\n' | "$BUS" post --kind notice --session hash
printf 'same\n' | "$BUS" post --kind notice --session hash
hash=$(printf 'same\n' | shasum -a 256 | cut -c1-12)
assert test "$(count "$STORE/hash/pending")" = 1
assert test "$(jq -r .id "$STORE/hash/pending/"*.txt)" = "$hash"
for n in 1 2 3 4; do post parallel same & done
wait
assert test "$(count "$STORE/parallel/pending")" = 1

post failed-output item
real_jq=$(command -v jq)
cat >"$WORK/bin/jq" <<'JQ'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in '{systemMessage:$m}') exit 1 ;; esac
done
exec "$REAL_JQ" "$@"
JQ
chmod +x "$WORK/bin/jq"
output=$(REAL_JQ="$real_jq" PATH="$WORK/bin:$PATH" "$BUS" flush --session failed-output --event Stop </dev/null)
assert test -z "$output"
assert test "$(count "$STORE/failed-output/pending")" = 1
assert test "$(count "$STORE/failed-output/delivered")" = 0

# macOS's own /bin/bash is 3.2, and a hook that finds no newer one on PATH runs the bus under it:
# an array idiom only bash 4 accepts takes delivery down exactly where it is least visible.
if [ -x /bin/bash ]; then
  printf 'thirty two\n' | /bin/bash "$BUS" post --kind notice --id bash32 --session bash32
  assert test "$(count "$STORE/bash32/pending")" = 1
  assert test -n "$(printf '{"session_id":"bash32"}\n' | /bin/bash "$BUS" flush --event Stop)"
  assert test "$(count "$STORE/bash32/pending")" = 0
  assert test "$(count "$STORE/bash32/delivered")" = 1
  assert test -z "$(printf '{"session_id":"bash32"}\n' | /bin/bash "$BUS" flush --event Stop)"
fi

post old aged
touch -t 202001010001 "$STORE/old/pending/"*.txt
output=$("$BUS" doctor)
assert grep -q '^old: 1 pending older than 10 min' <<<"$output"
assert grep -qx 'orphans: 0' <<<"$output"
assert grep -qx 'lost.log: 0 bytes' <<<"$output"

mkdir -p "$WORK/fail-cache/claude-reports"
: >"$WORK/fail-cache/claude-reports/lost.log"
chmod 500 "$WORK/fail-cache/claude-reports"
rc=0
printf 'saved body\n' | XDG_CACHE_HOME="$WORK/fail-cache" "$BUS" post --kind notice --session lost 2>"$WORK/error" || rc=$?
assert test "$rc" = 0
assert grep -qx 'saved body' "$WORK/fail-cache/claude-reports/lost.log"
assert grep -q '^report-bus: ' "$WORK/error"
chmod 700 "$WORK/fail-cache/claude-reports"

post pruned retained
flush pruned >/dev/null
source_file=$(find "$STORE/pruned/delivered" -name '*.txt')
for ((n=1; n<=201; n++)); do
  cp "$source_file" "$STORE/pruned/delivered/${n}__notice__fixture-$n.txt"
done
touch -t 202001010001 "$source_file"
flush pruned >/dev/null
assert test "$(count "$STORE/pruned/delivered")" = 200
assert test ! -e "$source_file"
post pruned retained
assert test "$(count "$STORE/pruned/pending")" = 0
assert test -n "$("$BUS" list --session pruned)"

printf orphan | "$BUS" post --kind notice --id adopted-once
post resolved adopted-once
output=$(flush resolved)
assert test "$(message <<<"$output" | grep -c '^▌')" = 1
post unrelated history-tail
flush unrelated >/dev/null
post resolved adopted-once
assert test "$(count "$STORE/resolved/pending")" = 0
post other-chat adopted-once
assert test "$(count "$STORE/other-chat/pending")" = 0
for lock_state in dead aged; do
  mkdir "$STORE/.lock"
  if [ "$lock_state" = dead ]; then printf '99999999\n' >"$STORE/.lock/pid"
  else printf '%s\n' "$$" >"$STORE/.lock/pid"; touch -t 202001010001 "$STORE/.lock"; fi
  post recovered "$lock_state"
  assert test "$(count "$STORE/recovered/pending")" = "$([ "$lock_state" = dead ] && echo 1 || echo 2)"
done
output=$(printf context | "$BUS" emit --kind notice --id contextual --context 'model directive' --event Stop)
assert jq -e '.hookSpecificOutput == {hookEventName:"Stop",additionalContext:"model directive"} and (.systemMessage | endswith("context"))' <<<"$output" >/dev/null
output=$(printf push | "$BUS" emit --kind push --id 'abc@origin/main')
assert jq -e '.systemMessage | startswith("\n▌ push ") and endswith("push")' <<<"$output" >/dev/null
lines=$(jq -s length "$STORE/history.log")
rc=0
repeat=$(printf push | "$BUS" emit --kind push --id 'abc@origin/main') || rc=$?
assert test "$rc" = 3
assert test -z "$repeat"
assert test "$(jq -s length "$STORE/history.log")" = "$lines"
post safe 'post@origin/main'
assert test -f "$(find "$STORE/safe/pending" -name '*__post-origin-main.txt')"

printf 'PASS: %s asserts; report bus delivery, history, isolation and failure retention\n' "$asserts"
