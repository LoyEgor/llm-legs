#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# shards: 4
. "$(dirname "$0")/worker_run_harness.sh" || exit 1

# Web search, every vendor against every entry point, driven from the one table the launcher reads:
# a vendor or an entry point added without the capability fails here rather than answering a
# research brief from memory.
WEB_SEARCH_ENTRY=''
. "$ROOT/share/web-search.sh"
cat >"$WORK/bin/sandbox-exec" <<'SANDBOX'
#!/usr/bin/env bash
shift 2
exec "$@"
SANDBOX
chmod +x "$WORK/bin/sandbox-exec"
export RESEARCH_SANDBOX_EXEC="$WORK/bin/sandbox-exec"
workdir="$WORK/websearch-workdir"
mkdir -p "$workdir" "$WORK/websearch"
git -C "$workdir" init -q
printf 'base\n' >"$workdir/file"
git -C "$workdir" add file
git -C "$workdir" -c user.name=fixture -c user.email=fixture@example.test commit -qm base
printf 'probe\nsecond line\n' >"$WORK/websearch/plain"
printf 'WEB: on\nprobe\nsecond line\n' >"$WORK/websearch/on"
printf 'WEB: off\nprobe\nsecond line\n' >"$WORK/websearch/off"
printf 'web: ON\nprobe\nsecond line\n' >"$WORK/websearch/on-lower"
printf 'probe\n' >"$WORK/websearch/light-plain"
printf 'WEB: on\nprobe\n' >"$WORK/websearch/light-on"
printf 'websearch\n' >"$STUB_DIR/gemini_profiles"
export PICK_RC=0 PICK_ACCOUNT=websearch

web_search_config() { # vendor
  set_config 'claudeb_model=opus' 'claudeb_effort=high' 'codex_effort=low' \
    'gemini_model=flash38' 'gemini_effort=high' 'grok_model=auto' 'grok_effort=high' \
    "light_research=$1" "light_edit=$1"
}

web_search_launch() { # brief vendor extra-arg...
  local file="$1" target="$2"
  shift 2
  clear_stub
  WORKER_TEST_BRIEF=$file WORKER_TEST_WORKDIR=$workdir start_ok "$target" "$@"
  WEB_SEARCH_ENTRY=$target
  assert await_exit
}

# The stubs record each argument as `ARG=%q`, so a table cell carrying anything the shell quotes
# (claudeb's `WebSearch,WebFetch`) never matches the raw cell text.
web_search_quoted() { # argv words on stdin
  local word
  while IFS= read -r word; do printf '%q\n' "$word"; done
}

# The state's whole argv as one adjacent run, never word by word: `-c` is codex's ordinary config
# flag and stands in both states and elsewhere in the command, so a per-word search reads a state
# the run was never launched in.
web_search_sequence_present() { # the state's argv words, one per line
  local needle='' haystack word quoted
  while IFS= read -r word; do
    printf -v quoted '%q' "$word"
    needle+=${needle:+$'\x1f'}$quoted
  done <<<"$1"
  [ -n "$needle" ] || return 1
  if [ "$WEB_SEARCH_ENTRY" = light ]; then
    # A Light edit run launches inside the write sandbox, which denies every path outside the Light
    # worktree and the run directory — the stub's shared call log among them — so the command the
    # launcher recorded is the only record of this entry point's argv.
    haystack=$'\x1f'$(jq -r '.cmd[]' "$RUN_DIR/meta.json" | web_search_quoted | paste -sd $'\x1f' -)$'\x1f'
  else
    haystack=$'\x1f'$(sed -n 's/^ARG=//p' "$CALL_LOG" | paste -sd $'\x1f' -)$'\x1f'
  fi
  # A tool list may go on past the cell: claudeb denies its wake-up tools in the same list.
  case "$haystack" in *$'\x1f'"$needle"$'\x1f'* | *$'\x1f'"$needle"'\,'*) return 0 ;; esac
  return 1
}

web_search_assert() { # vendor state
  local target="$1" want="$2" other=on want_words other_words
  [ "$want" = off ] || other=off
  want_words=$(web_search_args "$target" "$want")
  other_words=$(web_search_args "$target" "$other")
  [ -z "$want_words" ] || assert web_search_sequence_present "$want_words"
  [ -z "$other_words" ] || assert_fails web_search_sequence_present "$other_words"
  assert test "$(jq -r '.web_search' "$RUN_DIR/meta.json")" = "$([ "$want" = on ] && printf true || printf false)"
  # Named where a reader looks, not only in meta.json: the launch line and the report.
  assert grep -qx "WEB: $want" "$WORK/start.out"
  # Captured, not `<(...)`: grep -q quits at the match and a report left running outlives the shard's $WORK.
  assert grep -qx "WEB: $want" <<<"$("$RUNNER" report "$RUN_ID")"
}

# A state the vendor's column cannot reach, asked for outright: refused before an account is spent.
web_search_refused() { # brief vendor extra-arg...
  local file="$1" target="$2" rc=0
  shift 2
  clear_stub
  "$RUNNER" start "$target" --brief "$file" --workdir "$workdir" "$@" \
    >"$WORK/start.out" 2>"$WORK/start.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -qx 'OUTCOME: MODEL_REFUSED' "$WORK/start.out"
  assert grep -qF 'no switch that turns web search off' "$WORK/start.err"
  assert test ! -s "$CALL_LOG"
}

web_search_grid() { # vendor
  local vendor="$1" expected
  # Both columns empty argv is only legal where the vendor HAS no off switch: a blank cell there
  # would read as "the CLI already does this" and hide a flag nobody wired.
  if [ -z "$(web_search_args "$vendor" on)" ] && [ -z "$(web_search_args "$vendor" off)" ]; then
    assert test "$(web_search_column "$vendor" off)" = '!'
  fi
  web_search_config "$vendor"
  expected=$(web_search_state "$vendor" false)
  web_search_launch "$WORK/websearch/plain" "$vendor"
  web_search_assert "$vendor" "$expected"
  web_search_launch "$WORK/websearch/light-plain" light
  web_search_assert "$vendor" "$expected"

  expected=$(web_search_state "$vendor" true)
  web_search_launch "$WORK/websearch/plain" "$vendor" --web-search
  web_search_assert "$vendor" "$expected"
  web_search_launch "$WORK/websearch/on" "$vendor"
  web_search_assert "$vendor" "$expected"
  web_search_launch "$WORK/websearch/light-on" light
  web_search_assert "$vendor" "$expected"
  # Research needs no flag and no header: the role is the ask.
  web_search_launch "$WORK/websearch/plain" "$vendor" --role research
  web_search_assert "$vendor" "$expected"

  if [ "$(web_search_column "$vendor" off)" = '!' ]; then
    web_search_refused "$WORK/websearch/off" "$vendor" --role research
    web_search_refused "$WORK/websearch/plain" "$vendor" --no-web-search
  else
    expected=$(web_search_state "$vendor" false)
    web_search_launch "$WORK/websearch/off" "$vendor" --role research
    web_search_assert "$vendor" "$expected"
    web_search_launch "$WORK/websearch/plain" "$vendor" --no-web-search
    web_search_assert "$vendor" "$expected"
  fi
}

# The vendors come from the table: a row added without an entry point, or an entry point that
# stops reading the table, is what this grid exists to catch — a hand-written list catches neither.
web_search_grid_shard() { # shard -> the grid of every table vendor whose row index lands on it
  local index=0 vendor
  for vendor in $(web_search_table | cut -f1); do
    index=$((index % 4 + 1))
    [ "$index" != "$1" ] || web_search_grid "$vendor"
  done
}
if suite_shard_owns 1 ws-grid-1; then web_search_grid_shard 1; fi
if suite_shard_owns 2 ws-grid-2; then web_search_grid_shard 2; fi
if suite_shard_owns 3 ws-grid-3; then web_search_grid_shard 3; fi
if suite_shard_owns 4 ws-grid-4; then web_search_grid_shard 4; fi

if suite_shard_owns 1 ws-header-refusals; then
  web_search_config claudeb
  # A header that is neither state is a typo, not a default: launching on it would silently pick one.
  clear_stub
  printf 'WEB: maybe\nprobe\n' >"$WORK/websearch/bad"
  rc=0
  "$RUNNER" start claudeb --brief "$WORK/websearch/bad" --workdir "$workdir" \
    >"$WORK/websearch.out" 2>"$WORK/websearch.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -qF "brief header 'WEB: maybe' names no state" "$WORK/websearch.err"
  assert test ! -s "$CALL_LOG"

  # A WEB: line the header block cannot reach is refused, never dropped: a prose first line, a blank
  # line above the header, a space before the colon and a launcher's own prefix pushing it down all
  # used to launch a web-facing brief with search off and no word about it anywhere.
  printf 'probe\n\nWEB: on\n' >"$WORK/websearch/stray"
  printf 'WEB : on\nprobe\n' >"$WORK/websearch/spaced"
  printf 'REPOSITORY: /tmp\n\nWEB: on\nprobe\n' >"$WORK/websearch/pushed"
  for stray in stray spaced pushed; do
    clear_stub
    rc=0
    "$RUNNER" start claudeb --brief "$WORK/websearch/$stray" --workdir "$workdir" \
      >"$WORK/websearch.out" 2>"$WORK/websearch.err" || rc=$?
    assert test "$rc" -eq 4
    assert grep -qF 'spells a WEB: state worker-run does not read' "$WORK/websearch.err"
    assert test ! -s "$CALL_LOG"
  done
  # The key and the state are case-insensitive: `web: ON` was silently ignored while `WEB: yes`
  # failed loudly. worker-run takes the parsed state as is, so no vendor needs its own launch of it.
  assert test "$(web_search_brief_state "$WORK/websearch/on-lower")" = on
  # A body line that merely starts with `web:` names no state: `Web: <url>` is prose, not a header.
  printf 'probe\n\nWeb: https://example.test/page\n web: nginx\n' >"$WORK/websearch/prose"
  assert test "$(web_search_brief_state "$WORK/websearch/prose"; printf 'rc=%s' "$?")" = rc=0

  # Flag against header: the flag used to win in silence, so a brief that ruled live pages out was
  # launched on them by a caller who passed --web-search out of habit.
  while read -r flag brief; do
    clear_stub
    rc=0
    "$RUNNER" start claudeb --brief "$WORK/websearch/$brief" --workdir "$workdir" "$flag" \
      >"$WORK/websearch.out" 2>"$WORK/websearch.err" || rc=$?
    assert test "$rc" -eq 4
    assert grep -qF 'ask for opposite states' "$WORK/websearch.err"
    assert test ! -s "$CALL_LOG"
  done <<'CONTRADICTIONS'
--web-search off
--no-web-search on
CONTRADICTIONS
  clear_stub
  rc=0
  "$RUNNER" start claudeb --brief "$WORK/websearch/plain" --workdir "$workdir" --web-search --no-web-search \
    >"$WORK/websearch.out" 2>"$WORK/websearch.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -qF 'ask for opposite states' "$WORK/websearch.err"
fi

if suite_shard_owns 2 ws-meta-state; then
  for vendor in $(web_search_table | cut -f1); do
    jq -cn --arg v "$vendor" '{vendor:$v,web_search:true}' >"$WORK/websearch/meta.json"
    assert test "$(web_search_meta_state "$WORK/websearch/meta.json")" = on
    jq -cn --arg v "$vendor" '{vendor:$v,web_search:false}' >"$WORK/websearch/meta.json"
    assert test "$(web_search_meta_state "$WORK/websearch/meta.json")" = off
  done
fi

if suite_shard_owns 3 ws-grok-research-fence; then
  # The answer contract asks the grok research leg to fetch pages, and its sandbox fails a run that
  # saves one: the fence rides in the launched brief only, never in the recorded one.
  set_config 'grok_model=auto' 'grok_effort=high' 'light_research=grok' 'light_edit=grok'
  web_search_launch "$WORK/websearch/plain" grok --role research
  assert grep -qF 'READ-ONLY TREE' "$RUN_DIR/brief.launch"
  assert test "$(grep -cF 'READ-ONLY TREE' "$RUN_DIR/brief")" = 0
  web_search_launch "$WORK/websearch/plain" grok
  assert test "$(grep -cF 'READ-ONLY TREE' "$RUN_DIR/brief.launch")" = 0
  assert test "$(grep -cF 'EDITS: change repository files only' "$RUN_DIR/brief.launch")" = 0
fi

if suite_shard_owns 4 ws-grok-sandbox; then
  set_config 'grok_model=auto' 'grok_effort=high' 'light_research=grok' 'light_edit=grok'
  # Grok research runs in the write-deny sandbox: a co-tenant's edit to the shared tree mid-run is
  # no violation (it was, under the old before/after digest), and a write tool the sandbox refused is.
  cat >"$STUB_DIR/relay_hook" <<EOF
#!/usr/bin/env bash
printf 'cotenant\n' >"$workdir/cotenant.txt"
EOF
  chmod +x "$STUB_DIR/relay_hook"
  web_search_launch "$WORK/websearch/plain" grok --role research
  assert test "$(cat "$RUN_DIR/exit_code")" -eq 0
  assert test ! -s "$RUN_DIR/research-outcome"
  assert grep -qxF "(allow file-write* (subpath \"$(readlink -f "$GROKB_PROFILES_DIR/websearch")\"))" "$RUN_DIR/sandbox.sb"
  assert grep -qxF "(deny file-write* (subpath \"$(readlink -f "$workdir")\"))" "$RUN_DIR/sandbox.sb"
  assert test "$(jq -r '.sandbox_exec' "$RUN_DIR/meta.json")" = "$RESEARCH_SANDBOX_EXEC"
  rm -f "$workdir/cotenant.txt"
  cat >"$STUB_DIR/relay_hook" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"type":"tool_call","toolCallId":"call-1","title":"write","kind":"write","rawInput":{"file_path":"notes.txt"}}' \
  '{"type":"tool_call_update","toolCallId":"call-1","status":"failed","rawOutput":{"error":"tool_execution_failed","message":"IO Error: Operation not permitted (os error 1)"}}'
EOF
  web_search_launch "$WORK/websearch/plain" grok --role research
  assert test "$(cat "$RUN_DIR/exit_code")" -eq 5
  assert grep -qx 'READ_ONLY_VIOLATION' "$RUN_DIR/research-outcome"
  # A read the sandbox or TCC refused is no write.
  sed -i '' 's/"kind":"write"/"kind":"execute"/' "$STUB_DIR/relay_hook"
  web_search_launch "$WORK/websearch/plain" grok --role research
  assert test "$(cat "$RUN_DIR/exit_code")" -eq 0
  rm -f "$STUB_DIR/relay_hook"
fi

if suite_shard_owns 2 ws-claudeb-edits; then
  web_search_config claudeb
  # A claudeb worker is told up front what worker-edit-guard would otherwise refuse call by call.
  web_search_launch "$WORK/websearch/plain" claudeb
  assert grep -qF 'EDITS: change repository files only through the Edit and Write tools' "$RUN_DIR/brief.launch"
  assert test "$(grep -cF 'EDITS:' "$RUN_DIR/brief")" = 0
fi

echo "PASS: $asserts asserts; web search as one table every vendor and every entry point resolves through"
