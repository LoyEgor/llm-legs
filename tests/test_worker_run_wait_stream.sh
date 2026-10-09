#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
RUNNER="$ROOT/bin/worker-run"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" WORKER_RUN_DIR="$WORK/runs" WORKER_STATS_DIR="$WORK/stats"
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDEB_WORKER WORKER_RUN_RECORD
mkdir -p "$HOME"
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { asserts=$((asserts + 1)); [ "$1" = "$2" ] || fail "expected [$1] got [$2]"; }
assert_has() { asserts=$((asserts + 1)); grep -Fqx -- "$1" <<<"$2" || fail "no line [$1] in [$2]"; }

# A claudeb run whose transcript holds a message, a long command and an edit, ended 4m05s after start.
ID=claudeb-1-2-x
RUN="$WORKER_RUN_DIR/$ID"
mkdir -p "$RUN"
now=$(date +%s)
ts=$(date -u -r "$now" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "@$now" +%Y-%m-%dT%H:%M:%S.000Z)
jq -nc --argjson s $((now - 245)) '{vendor:"claudeb",account:"acct",workdir:"/tmp",pid:0,started_at:$s,pid_started_at:$s}' >"$RUN/meta.json"
long='grep -n door bin/worker-launch-gate.sh | head -50 && echo a long command line that has to be cut at one hundred twenty characters'
jq -nc --arg ts "$ts" --arg long "$long" '{type:"assistant",timestamp:$ts,message:{id:"m1",
  usage:{input_tokens:10,output_tokens:5,cache_read_input_tokens:100},
  content:[{type:"text",text:"Reading the gate\nnow"},{type:"tool_use",id:"t1",name:"Bash",input:{command:$long}},
    {type:"tool_use",id:"t2",name:"Edit",input:{file_path:"/w/bin/gate.sh"}}]}}' >"$WORK/session.jsonl"
printf '%s\n' "$WORK/session.jsonl" >"$RUN/session-file"
printf '0\n' >"$RUN/exit_code"
: >"$RUN/out"; : >"$RUN/err"
printf 'acct · opus · high\n' >"$RUN/tag"

out=$("$RUNNER" wait "$ID" 2>&1)
assert_has '[4m05s] » Reading the gate now' "$out"
assert_has '[4m05s] Edit /w/bin/gate.sh' "$out"
bash_row=$(grep -F '[4m05s] Bash grep -n door' <<<"$out")
assert_eq 120 "$(printf '%s' "$bash_row" | wc -m | tr -d ' ')"
assert_eq '…' "$(printf '%s' "$bash_row" | perl -CSD -ne 'print substr($_, -1)')"
assert_eq 1 "$(grep -c '^STATUS: done' <<<"$out")"
# The run's usage so far is written beside its tag for the rows that render it.
assert_eq 115 "$(cat "$RUN/tokens")"
# A row is printed once however many times the wait reads the transcript.
assert_eq 1 "$(grep -c 'Reading the gate' <<<"$out")"

# `--max` keeps the bounded poll: a running run answers STATUS: running and streams nothing.
rm -f "$RUN/exit_code" "$RUN/tokens"
sleep 300 &
live=$!
jq -c --argjson p "$live" --argjson t "$(date +%s)" \
  '.pid = $p | .pid_started_at = $t' "$RUN/meta.json" >"$WORK/m" && mv "$WORK/m" "$RUN/meta.json"
out=$("$RUNNER" wait "$ID" --max 0 2>&1)
kill "$live" 2>/dev/null
assert_eq 1 "$(grep -c '^STATUS: running' <<<"$out")"
assert_eq 0 "$(grep -c '^\[' <<<"$out")"
# ... and still writes the worker's tokens, so a script's bounded waits keep the row's token cell.
assert_eq 115 "$(cat "$RUN/tokens" 2>/dev/null)"

printf 'PASS: %s asserts; a wait with no --max streams one `[elapsed] row` line per transcript message, tool and edit (cut to 120 characters with an ellipsis, never repeated), writes the run'"'"'s tokens beside its tag and ends on the terminal report, while --max keeps the bounded STATUS: running poll and the tokens\n' "$asserts"
