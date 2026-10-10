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
export GEMINI_RESEARCH_SANDBOX_EXEC="$WORK/bin/sandbox-exec"
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
  "$RUNNER" start "$target" --brief "$file" --workdir "$workdir" "$@" \
    >"$WORK/start.out" 2>"$WORK/start.err" || fail "web-search start $target failed: $(<"$WORK/start.err")"
  RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/start.out")
  RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/start.out")
  WEB_SEARCH_ENTRY=$target
  assert await_done
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
web_search_sequence_present() { # vendor state
  local needle haystack
  needle=$(web_search_args "$1" "$2" | web_search_quoted | paste -sd $'\x1f' -)
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
  local target="$1" want="$2" other=on
  [ "$want" = off ] || other=off
  [ -z "$(web_search_args "$target" "$want")" ] || assert web_search_sequence_present "$target" "$want"
  [ -z "$(web_search_args "$target" "$other")" ] || assert_fails web_search_sequence_present "$target" "$other"
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
  # The key and the state are case-insensitive: `web: ON` was silently ignored while `WEB: yes`
  # failed loudly, so the shape a caller guesses wrong is the one that costs a run.
  web_search_launch "$WORK/websearch/on-lower" "$vendor"
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
shard=0
for vendor in $(web_search_table | cut -f1); do
  shard=$((shard % 4 + 1))
  if suite_shard_owns "$shard" "ws-grid-$vendor"; then web_search_grid "$vendor"; fi
done

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
  # The grok research leg is policed from outside by a tree digest, and the answer contract now asks
  # it to fetch pages: the fence rides in the launched brief only, never in the recorded one.
  set_config 'grok_model=auto' 'grok_effort=high' 'light_research=grok' 'light_edit=grok'
  web_search_launch "$WORK/websearch/plain" grok --role research
  assert grep -qF 'READ-ONLY TREE' "$RUN_DIR/brief.launch"
  assert test "$(grep -cF 'READ-ONLY TREE' "$RUN_DIR/brief")" = 0
  web_search_launch "$WORK/websearch/plain" grok
  assert test "$(grep -cF 'READ-ONLY TREE' "$RUN_DIR/brief.launch")" = 0
  assert test "$(grep -cF 'EDITS: change repository files only' "$RUN_DIR/brief.launch")" = 0

  # Grok research digests non-git trees and catches edits outside git repos.
  nongit="$WORK/websearch/scratchpad"
  mkdir -p "$nongit"
  web_search_launch "$WORK/websearch/plain" grok --role research --workdir "$nongit"
  assert test "$(cat "$RUN_DIR/exit_code")" -eq 0
  assert test ! -s "$RUN_DIR/research-outcome"

  cat >"$STUB_DIR/relay_hook" <<EOF
#!/usr/bin/env bash
touch "$nongit/leaked.txt"
EOF
  chmod +x "$STUB_DIR/relay_hook"
  web_search_launch "$WORK/websearch/plain" grok --role research --workdir "$nongit"
  assert test "$(cat "$RUN_DIR/exit_code")" -eq 5
  assert grep -qx 'READ_ONLY_VIOLATION' "$RUN_DIR/research-outcome"
  rm -f "$nongit/leaked.txt" "$STUB_DIR/relay_hook"
  # The non-git digest hashes its files in one git start, re-batching past a file it cannot read,
  # and a one-byte edit still moves it.
  (
    eval "$(sed -n '/^non_git_tree_digest() {/,/^}/p' "$RUNNER")"
    mkdir -p "$nongit/sub" "$WORK/digest-shim"
    for name in a b c sub/d sub/e; do printf '%s\n' "$name" >"$nongit/$name"; done
    ln -s a "$nongit/link"
    printf '#!/usr/bin/env bash\necho >>"%s/starts"\nexec %s "$@"\n' "$WORK/digest-shim" "$(command -v git)" \
      >"$WORK/digest-shim/git"
    chmod +x "$WORK/digest-shim/git"
    : >"$WORK/digest-shim/starts"
    clean=$(PATH="$WORK/digest-shim:$PATH" non_git_tree_digest "$nongit")
    assert test "$(wc -l <"$WORK/digest-shim/starts" | tr -d ' ')" = 1
    assert grep -qxF "$(printf 'f\t%s\t./sub/d' "$(git hash-object "$nongit/sub/d")")" <<<"$clean"
    assert grep -qxF "$(printf 'l\ta\t./link')" <<<"$clean"
    assert grep -qxF "$(printf 'd\t./sub')" <<<"$clean"
    chmod 000 "$nongit/b"
    : >"$WORK/digest-shim/starts"
    unreadable=$(PATH="$WORK/digest-shim:$PATH" non_git_tree_digest "$nongit")
    assert test "$(wc -l <"$WORK/digest-shim/starts" | tr -d ' ')" = 3
    assert grep -qxF "$(printf 'f\t-\t./b')" <<<"$unreadable"
    assert test "$(grep -vF './b' <<<"$unreadable")" = "$(grep -vF './b' <<<"$clean")"
    chmod 644 "$nongit/b"
    printf 'c\r' >"$nongit/c"
    assert test "$(non_git_tree_digest "$nongit")" != "$clean"
  )
  assert test "$?" -eq 0
  # A claudeb worker is told up front what worker-edit-guard would otherwise refuse call by call.
  web_search_launch "$WORK/websearch/plain" claudeb
  assert grep -qF 'EDITS: change repository files only through the Edit and Write tools' "$RUN_DIR/brief.launch"
  assert test "$(grep -cF 'EDITS:' "$RUN_DIR/brief")" = 0
fi

if suite_shard_owns 2 ws-research-model-refused; then
  # Off the light_research row the refusal names what to pass, not just that something is missing.
  set_config 'codex_effort=low' 'light_research=gemini' 'light_edit=gemini'
  clear_stub
  rc=0
  "$RUNNER" start codex --brief "$WORK/websearch/plain" --workdir "$workdir" --role research \
    >"$WORK/websearch.out" 2>"$WORK/websearch.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -qx 'OUTCOME: MODEL_REFUSED' "$WORK/websearch.out"
  assert grep -qF -- '--model <id>' "$WORK/websearch.err"
  assert grep -qF 'light ids (astra' "$WORK/websearch.err"
  assert test ! -s "$CALL_LOG"
fi

echo "PASS: $asserts asserts; web search as one table every vendor and every entry point resolves through"
