#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/worker_run_harness.sh"

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

out=$("$RUNNER" wait "$ID" 2>&1)
# The label is wall-clock elapsed at the wait's read: a loaded machine reaches it seconds after 4m05s.
at=$(grep -oE '^\[4m[0-5][0-9]s\]' <<<"$out" | head -n 1)
assert [ "$(printf '%.4s' "$at")" = '[4m0' ]
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

printf 'PASS: %s asserts; a wait with no --max streams one `[elapsed] row` line per transcript message, tool and edit (cut to 120 characters with an ellipsis, never repeated), writes the run'"'"'s tokens beside its tag and ends on the terminal report, while --max keeps the bounded STATUS: running poll and the tokens\n' "$asserts"
