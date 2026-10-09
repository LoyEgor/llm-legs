#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/worker_run_harness.sh"
mkdir -p "$WORK/shim"
CALLS="$WORK/tool-calls"
for tool in perl python3 find; do
  printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >>"%s"\nexec %q "$@"\n' "$tool" "$CALLS" "$(command -v "$tool")" >"$WORK/shim/$tool"
  chmod +x "$WORK/shim/$tool"
done
export PATH="$WORK/shim:$PATH"

# A claudeb run whose transcript holds a message, a long command and an edit, ended 4m05s after start.
ID=claudeb-1-2-x
RUN="$WORKER_RUN_DIR/$ID"
mkdir -p "$RUN"
now=$(date +%s)
jq -nc --argjson s $((now - 245)) '{vendor:"claudeb",account:"acct",workdir:"/tmp",pid:0,started_at:$s,pid_started_at:$s}' >"$RUN/meta.json"
long='grep -n door bin/worker-launch-gate.sh | head -50 && echo a long command line that has to be cut at one hundred twenty characters'
jq -nc --arg ts "$(iso "$now")" --arg long "$long" '{type:"assistant",timestamp:$ts,message:{id:"m1",
  usage:{input_tokens:10,output_tokens:5,cache_read_input_tokens:100},
  content:[{type:"text",text:"Reading the gate\nnow"},{type:"tool_use",id:"t1",name:"Bash",input:{command:$long}},
    {type:"tool_use",id:"t2",name:"Edit",input:{file_path:"/w/bin/gate.sh"}}]}}' >"$WORK/session.jsonl"
printf '%s\n' "$WORK/session.jsonl" >"$RUN/session-file"
printf '0\n' >"$RUN/exit_code"
: >"$RUN/out"; : >"$RUN/err"
printf 'acct · opus · high\n' >"$RUN/tag"


: >"$CALLS"
out=$("$RUNNER" wait "$ID" 2>&1)
# One perl cuts every row of a read, never one per row.
assert [ "$(grep -cF 'substr($_, 0, 119)' "$CALLS")" = 1 ]
waited=$(($(date +%s) - now))
# The label is wall-clock elapsed at the wait's read: 4m05s plus however long the machine took to reach it.
at=$(grep -oE '^\[[0-9]+m[0-5][0-9]s\]' <<<"$out" | head -n 1)
at_s=$(perl -ne 'print $1 * 60 + $2 if /^\[(\d+)m(\d+)s\]$/' <<<"$at")
assert [ -n "$at_s" ]
assert [ "$at_s" -ge 245 ]
assert [ "$at_s" -le $((245 + waited)) ]
assert grep -Fqx -- "$at » Reading the gate now" <<<"$out"
assert grep -Fqx -- "$at Edit /w/bin/gate.sh" <<<"$out"
bash_row=$(grep -F "$at Bash grep -n door" <<<"$out")
assert [ "$(printf '%s' "$bash_row" | wc -m | tr -d ' ')" = 120 ]
assert [ "$(printf '%s' "$bash_row" | perl -CSD -ne 'print substr($_, -1)')" = '…' ]
assert [ "$(grep -c '^STATUS: done' <<<"$out")" = 1 ]
# The run's usage so far is written beside its tag for the rows that render it.
assert [ "$(cat "$RUN/tokens")" = 115 ]
# A row is printed once however many times the wait reads the transcript.
assert [ "$(grep -c 'Reading the gate' <<<"$out")" = 1 ]

# `--max` keeps the bounded poll: a running run answers STATUS: running and streams nothing.
rm -f "$RUN/exit_code" "$RUN/tokens"
sleep 300 &
live=$!
jq -c --argjson p "$live" --argjson t "$(date +%s)" \
  '.pid = $p | .pid_started_at = $t' "$RUN/meta.json" >"$WORK/m" && mv "$WORK/m" "$RUN/meta.json"
out=$("$RUNNER" wait "$ID" --max 0 2>&1)
kill "$live" 2>/dev/null
assert [ "$(grep -c '^STATUS: running' <<<"$out")" = 1 ]
assert [ "$(grep -c '^\[' <<<"$out")" = 0 ]
# ... and still writes the worker's tokens, so a script's bounded waits keep the row's token cell.
assert [ "$(cat "$RUN/tokens" 2>/dev/null)" = 115 ]

# A live claudeb run: the wait reads each log line once (bytes it already read are never re-read, so
# the rewritten first line stays unprinted), keeps a partial last line for the next read, and counts
# the tokens on its first and last read only.
row() { jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" --arg text "$1" '{type:"assistant",timestamp:$ts,message:{content:[{type:"text",text:$text}]}}'; }
await() { local i; for i in $(seq 100); do grep -Fq -- "$1" "$WORK/live.out" && return 0; sleep 0.1; done; fail "no [$1] in $(cat "$WORK/live.out")"; }
rm -f "$RUN/exit_code" "$RUN/tokens"
sleep 300 &
live=$!
jq -c --argjson p "$live" --argjson t "$(date +%s)" '.pid = $p | .pid_started_at = $t' "$RUN/meta.json" >"$WORK/m" &&
  mv "$WORK/m" "$RUN/meta.json"
row alpha-row >"$WORK/session.jsonl"
: >"$CALLS"
WORKER_RUN_WAIT_POLL_S=1 "$RUNNER" wait "$ID" >"$WORK/live.out" 2>&1 &
waiter=$!
await alpha-row
row bravo-row >"$WORK/session.jsonl"
part=$(row charlie-row)
printf '%s' "${part:0:20}" >>"$WORK/session.jsonl"
sleep 2.5
printf '%s\n' "${part:20}" >>"$WORK/session.jsonl"
await charlie-row
row delta-row >>"$WORK/session.jsonl"
printf '0\n' >"$RUN/exit_code"
wait "$waiter"
kill "$live" 2>/dev/null
live_out=$(cat "$WORK/live.out")
assert [ "$(grep -c 'alpha-row' <<<"$live_out")" = 1 ]
assert [ "$(grep -c 'bravo-row' <<<"$live_out")" = 0 ]
assert [ "$(grep -c 'charlie-row' <<<"$live_out")" = 1 ]
assert [ "$(grep -c 'delta-row' <<<"$live_out")" = 1 ]
assert [ "$(grep -c "^python3 - .* $ID claudeb " "$CALLS")" = 2 ]

# A codex run's rollout is looked up once per wait, never once per poll.
CID=codex-1-2-x
CRUN="$WORKER_RUN_DIR/$CID"
mkdir -p "$CRUN" "$HOME/.codex/sessions/2026"
jq -nc --argjson s "$now" --argjson p "$$" '{vendor:"codex",account:"main",workdir:"/tmp",pid:$p,started_at:$s,pid_started_at:$s}' >"$CRUN/meta.json"
printf 'session id: abc123\n' >"$CRUN/err"
: >"$CRUN/out"
jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" '{timestamp:$ts,payload:{type:"function_call",name:"exec_command",arguments:"{\"cmd\":\"ls\"}"}}' \
  >"$HOME/.codex/sessions/2026/rollout-abc123.jsonl"
sleep 300 &
live=$!
jq -c --argjson p "$live" --argjson t "$(date +%s)" '.pid = $p | .pid_started_at = $t' "$CRUN/meta.json" >"$WORK/m" && mv "$WORK/m" "$CRUN/meta.json"
: >"$CALLS"
WORKER_RUN_WAIT_POLL_S=1 "$RUNNER" wait "$CID" >"$WORK/live.out" 2>&1 &
waiter=$!
await '$ ls'
sleep 2.5
printf '0\n' >"$CRUN/exit_code"
wait "$waiter"
kill "$live" 2>/dev/null
assert [ "$(grep -c '^find .*-name \*abc123\*' "$CALLS")" = 1 ]

printf 'PASS: %s asserts; a wait with no --max streams one `[elapsed] row` line per transcript message, tool and edit (cut to 120 characters with an ellipsis, never repeated), writes the run'"'"'s tokens beside its tag and ends on the terminal report, while --max keeps the bounded STATUS: running poll and the tokens\n' "$asserts"
