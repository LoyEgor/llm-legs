#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/worker_run_harness.sh"
PROJECTS=$(git_projects "$ROOT")

# A model no implementation worker may run is refused before the account is resolved: an explicit
# --model, the vendor's own `*_model=` key, and the default a missing key falls back to are three
# roads to the same list, and none of them may spend a run on a cheap model.
model_refused() { # vendor expected-offender [flags...]
  local vendor="$1" offender="$2" runs_before runs_after rc=0
  shift 2
  clear_stub
  runs_before=$(find "$WORKER_RUN_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  "$RUNNER" start "$vendor" --brief "$WORK/brief" --workdir "$WORK/workdir" "$@" \
    >"$WORK/refuse.out" 2>"$WORK/refuse.err" || rc=$?
  runs_after=$(find "$WORKER_RUN_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$rc" -eq 4 ] || { printf 'model_refused %s: exit %s\n' "$vendor" "$rc" >&2; return 1; }
  grep -qx 'OUTCOME: MODEL_REFUSED' "$WORK/refuse.out" || return 1
  grep -qF -- "$offender" "$WORK/refuse.err" || return 1
  # Nothing was spent: no pick, no vendor call, no run directory.
  [ ! -s "$PICK_LOG" ] || return 1
  [ ! -s "$CALL_LOG" ] || return 1
  [ "$runs_before" = "$runs_after" ]
}

set_config 'claudeb_model=opus' 'claudeb_effort=high' 'codex_effort=medium' \
  'gemini_model=flash38' 'gemini_effort=high' 'grok_model=auto' 'grok_effort=high'
export PICK_RC=0 PICK_ACCOUNT=picked
printf 'picked\n' >"$STUB_DIR/gemini_profiles"
for spec in 'claudeb:sonnet' 'claudeb:haiku' 'codex:gpt-5.6-terra' \
            'codex:gpt-5.6-luna' 'codex:gpt-5.6' 'gemini:flash' \
            'gemini:flash35' 'gemini:flash39' 'grok:grok-3'; do
  vendor=${spec%%:*}
  bad=${spec#*:}
  assert model_refused "$vendor" "$bad" --model "$bad"
done

# The same refusal when the toggle file carries it and no brief names a model at all.
for spec in 'claudeb:claudeb_model=sonnet' 'gemini:gemini_model=flash35' 'grok:grok_model=grok-3'; do
  vendor=${spec%%:*}
  key=${spec#*:}
  set_config "$key" 'claudeb_effort=high' 'codex_effort=medium' 'gemini_effort=high' 'grok_effort=high'
  assert model_refused "$vendor" "${key#*=}"
done
# Codex has no key of its own and its default is the allow-list's model, never `config.toml`'s:
# Egor's interactive picks land in that shared file and must neither refuse nor switch a worker.
set_config 'codex_effort=medium'
printf 'model = "gpt-5.6-terra"\n' >"$WORKER_RUN_CODEX_CONFIG"
for flags in '' '--model default'; do
  clear_stub
  # shellcheck disable=SC2086
  start_ok codex --account model $flags
  assert await_done
  assert grep -qx 'ARG=gpt-6.1-astra' "$CALL_LOG"
done
# A resume is not that run: `exec resume` keeps the session's own model and nothing sends the
# config's, so the file cannot refuse a resumed session — only a model the caller names can.
assert model_refused codex gpt-5.6-terra --account resumeacct --resume codex-resume --model gpt-5.6-terra
clear_stub
start_ok codex --account resumeacct --resume codex-resume
assert await_done
assert test "$(grep -c '^ARG=-m$' "$CALL_LOG")" -eq 0
printf 'model = "gpt-6-astra"\n' >"$WORKER_RUN_CODEX_CONFIG"

# The allowed model of every vendor still launches, from the brief and from the file alike.
set_config 'claudeb_model=opus' 'claudeb_effort=high' 'codex_effort=medium' \
  'gemini_model=flash38' 'gemini_effort=high' 'grok_model=auto' 'grok_effort=high'
clear_stub
start_ok claudeb --model opus
assert await_done
clear_stub
start_ok codex --model astra
assert await_done
clear_stub
start_ok gemini --account main --model flash38
assert meta_agy_is 'gemini-3.8-flash-high'
assert await_done
clear_stub
start_ok grok --model grok-4.6
assert await_done
clear_stub
start_ok grok --model auto
assert await_done

# --- One stamping point: every relay's rows reach the LAUNCHING chat ------------------------------
# The launcher is known at `start` and nowhere else: a fresh relay's own session id is not printed
# until its CLI exits, so a pairing read off the run record arrives AFTER every touch the worker
# made while it ran (live run claudeb-1788388059-13078-3ffd, 2026-09-03). So the chat is stamped
# into the launched process's ENVIRONMENT as CLAUDE_DEBT_OWNER, which every relay inherits whatever
# the vendor and whatever it goes on to launch, and the touch writer charges the anchors store to it.
#
# One case per relay type, each end to end: worker-run launches the stubbed CLI under a fake
# launching chat, a process inside that CLI edits a file in a git fixture and records it exactly as
# the relay's own PostToolUse hook would, and the touch that reaches the store must carry the
# LAUNCHER's id. Break the stamp for one relay and only that relay's case fails.
STAMP_HOOK="${CLAUDE_SETUP_ROOT:-$PROJECTS/claude-setup}/hooks/commit-journal.sh"
STAMP_LIB="${CLAUDE_SETUP_ROOT:-$PROJECTS/claude-setup}/hooks/lib/review-journal.sh"
STAMP_ANCHORS="${REVIEW_BENCH_ROOT:-$PROJECTS/review-bench}/bin/review-anchors"
if [ -r "$STAMP_HOOK" ] && [ -r "$STAMP_LIB" ] && [ -x "$STAMP_ANCHORS" ]; then
  STAMP_REPO="$WORK/stamp-repo"
  mkdir -p "$STAMP_REPO" "$WORK/stamp-bin"
  ln -sf "$STAMP_ANCHORS" "$WORK/stamp-bin/review-anchors"
  git -C "$STAMP_REPO" init -q -b main
  git -C "$STAMP_REPO" config user.email t@example.test
  git -C "$STAMP_REPO" config user.name t
  printf 'base\n' >"$STAMP_REPO/base.txt"
  git -C "$STAMP_REPO" add base.txt
  git -C "$STAMP_REPO" commit -q -m base
  STAMP_STORE=$(git -C "$STAMP_REPO" rev-parse --path-format=absolute --git-common-dir)/review-anchors.json
  STAMP_KEY=$(cd "$(git -C "$STAMP_REPO" rev-parse --absolute-git-dir)" && pwd -P)
  # The hook skips anything under TMPDIR and this suite's fixtures live there: it is pinned to a
  # directory no fixture sits under, or the paths asserted on here are silenced by where the suite
  # happens to run.
  STAMP_HOME="$WORK/stamp-home"
  mkdir -p "$STAMP_HOME" "$WORK/stamp-tmpdir"
  # The relay's own hook pair, both halves: the PreToolUse content snapshot the touch writer
  # measures a change against, then the PostToolUse payload naming the file the relay just wrote.
  # `$1` is the worker's OWN session id — the only one a relay's hook ever knows.
  cat >"$STUB_DIR/relay_hook" <<STAMPEOF
#!/usr/bin/env bash
worker=\$1
tag=\$(cat "$STUB_DIR/relay_tag" 2>/dev/null) || tag=untagged
path="$STAMP_REPO/relay-\$tag.txt"
export HOME="$STAMP_HOME" TMPDIR="$WORK/stamp-tmpdir" WORKER_RUN_DIR="$WORKER_RUN_DIR"
export GIT_CEILING_DIRECTORIES="$WORK" PATH="$WORK/stamp-bin:\$PATH"
. "$STAMP_LIB" || exit 0
rj_snapshot_content "\$worker" "call-\$tag" "$STAMP_REPO" "" "relay-\$tag.txt"
printf 'written by %s\n' "\$worker" >"\$path"
jq -cn --arg s "\$worker" --arg p "\$path" --arg c "$STAMP_REPO" --arg call "call-\$tag" \
  '{hook_event_name:"PostToolUse",tool_name:"Write",cwd:\$c,session_id:\$s,tool_use_id:\$call,
    tool_input:{file_path:\$p}}' |
  bash "$STAMP_HOOK" >"$STUB_DIR/relay_hook_out" 2>"$STUB_DIR/relay_hook_err"
printf '%s\n' "\$?" >"$STUB_DIR/relay_hook_rc"
STAMPEOF
  chmod +x "$STUB_DIR/relay_hook"
  # Who holds a touch on a path in the store, one id per line.
  stamp_owners() { # tag
    jq -r --arg k "$STAMP_KEY" --arg p "relay-$1.txt" '(.touches[$k][$p] // {}) | keys[]' \
      "$STAMP_STORE" 2>/dev/null | sort -u
  }
  stamp_relay() { # tag vendor [start-args...]
    local tag="$1" vendor="$2" keep_session="${STUB_SESSION-}"
    shift 2
    printf '%s\n' "$tag" >"$STUB_DIR/relay_tag"
    rm -f "$STUB_DIR/relay_hook_rc" "$STUB_DIR/relay_hook_err"
    # `clear_stub` unsets STUB_SESSION, and the re-attach case is exactly the one that sets it:
    # cleared, the run records the stub default and the case proves nothing about a resumed id.
    clear_stub
    [ -z "$keep_session" ] || export STUB_SESSION="$keep_session"
    export CLAUDE_CODE_SESSION_ID="stamp-chat-$tag"
    start_ok "$vendor" "$@"
    await_done || fail "the $vendor stamping run never finished"
    unset CLAUDE_CODE_SESSION_ID
    assert test "$(cat "$STUB_DIR/relay_hook_rc" 2>/dev/null)" = 0
    assert grep -qx "stamp-chat-$tag" <<<"$(stamp_owners "$tag")"
    # The launcher alone: a touch under the worker's own id is debt no chat on this machine reads.
    assert test "$(stamp_owners "$tag" | grep -c .)" -eq 1
  }
  set_config 'claudeb_model=opus' 'claudeb_effort=high' 'codex_effort=medium' \
    'gemini_model=flash38' 'gemini_effort=high' 'grok_model=auto' 'grok_effort=high'
  export PICK_RC=0 PICK_ACCOUNT=stampacct
  stamp_relay claudeb claudeb
  stamp_relay codex codex
  stamp_relay gemini gemini --account main
  stamp_relay grok grok
  # A RE-ATTACHED run: a `--resume` launch repeats the id the worker session already had, and its
  # touches still reach the launcher rather than that resumed id.
  export STUB_SESSION=reattached-session
  stamp_relay reattach claudeb --account stampacct --resume reattached-session
  assert grep -qx 'reattached-session' "$RUN_DIR/worker-session"
  assert_fails grep -qx 'reattached-session' <<<"$(stamp_owners reattach)"
  unset STUB_SESSION
  # An IMAGE SCRIPT and a POOL-RUN CELL are processes a relay starts, not relays of their own: they
  # record through whoever ran them, so the one thing they must not do is drop the stamp. Stood in
  # for here by a bare shell — which is what both are to the environment — launched with the
  # environment worker-run exported.
  printf '%s\n' image-cell >"$STUB_DIR/relay_tag"
  rm -f "$STUB_DIR/relay_hook_rc"
  ( export CLAUDE_DEBT_OWNER=stamp-chat-image-cell CLAUDE_CODE_SESSION_ID=some-worker
    "$STUB_DIR/relay_hook" nested-image-worker )
  assert test "$(cat "$STUB_DIR/relay_hook_rc")" = 0
  assert grep -qx 'stamp-chat-image-cell' <<<"$(stamp_owners image-cell)"
  assert_fails grep -qx 'nested-image-worker' <<<"$(stamp_owners image-cell)"
  # A worker with no stamp at all charges its own session id: the touch is still a fact, and the
  # hook stays quiet inside a worker.
  printf '%s\n' unstamped >"$STUB_DIR/relay_tag"
  rm -f "$STUB_DIR/relay_hook_rc"
  ( unset CLAUDE_DEBT_OWNER
    export CLAUDEB_WORKER=1
    "$STUB_DIR/relay_hook" unstamped-worker )
  assert test "$(cat "$STUB_DIR/relay_hook_rc")" = 0
  assert test "$(stamp_owners unstamped)" = unstamped-worker
  # And a chat's own shell is no relay worker: its touches are its own outright.
  printf '%s\n' quiet >"$STUB_DIR/relay_tag"
  rm -f "$STUB_DIR/relay_hook_rc"
  ( unset CLAUDE_DEBT_OWNER CLAUDEB_WORKER GROK_WORKER
    "$STUB_DIR/relay_hook" a-chat-of-its-own )
  assert test "$(cat "$STUB_DIR/relay_hook_rc")" = 0
  assert grep -qx 'a-chat-of-its-own' <<<"$(stamp_owners quiet)"
  rm -f "$STUB_DIR/relay_hook" "$STUB_DIR/relay_tag"
  unset PICK_RC PICK_ACCOUNT
  clear_stub
else
  fail "the touch writer of ../claude-setup or ../review-bench's review-anchors is unreadable (set CLAUDE_SETUP_ROOT / REVIEW_BENCH_ROOT)"
fi

# A round fixer and a non-round run of the same chat, concurrent in a two-repository round, both on
# the real review-anchors: the fixer's fix anchor lands on exactly what it wrote, in either
# repository, and the other run's edits to reviewed paths stay owed.
fix_owned_tests() {
  local a b round=20260902T100000Z-ccccccc fixer other saved_path="$PATH" repo path folded
  fix_kinds() { jq -r --arg p "$2" '.anchors[$p][]?.kind' "$1/.git/review-anchors.json"; }
  fix_holds_current() {
    jq -e --arg p "$2" --arg b "$(git -C "$1" hash-object "$1/$2")" \
      '[.anchors[$p][]?.blob] | index($b) != null' "$1/.git/review-anchors.json" >/dev/null
  }
  for repo in fix-a fix-b; do
    mkdir -p "$WORK/$repo"
    git -C "$WORK/$repo" init -q .
    for path in own.txt theirs.txt extra.txt shell.txt link.txt; do printf 'base\n' >"$WORK/$repo/$path"; done
    git -C "$WORK/$repo" add -A >/dev/null
    git -C "$WORK/$repo" -c user.email=t@t -c user.name=t commit -qm base >/dev/null
  done
  a=$(cd "$WORK/fix-a" && pwd -P)
  b=$(cd "$WORK/fix-b" && pwd -P)
  mkdir -p "$CLAUDEB_DIR/worker-stats/benches/$round"
  jq -n --arg a "$a" --arg b "$b" '{
    repos: [{repo: $a, common_dir: ($a + "/.git"), label: "fix-a"},
            {repo: $b, common_dir: ($b + "/.git"), label: "fix-b"}],
    reviewed: {"fix-a/own.txt": "x", "fix-a/theirs.txt": "x", "fix-a/shell.txt": "x",
               "fix-b/own.txt": "x", "fix-b/theirs.txt": "x", "fix-b/link.txt": "x", "fix-b/shell.txt": "x"}}' \
    >"$CLAUDEB_DIR/worker-stats/benches/$round/meta.json"
  export PATH="$WORK/stamp-bin:$PATH"
  # Reviewed before, outside this round: the fixer's edit is the only new content in it.
  review-anchors anchor --repo "$a" --kind review:20260901T000000Z-0000000 extra.txt
  mkdir -p "$HOME/.cache/claude/review-journal"
  printf '%s\n%s\n' "$a" "$b" >"$HOME/.cache/claude/review-journal/fix-chat.repos"
  set_config 'claudeb_model=opus' 'claudeb_effort=high' 'codex_effort=medium'
  clear_stub
  export PICK_RC=0 PICK_ACCOUNT=fixacct CLAUDE_CODE_SESSION_ID=fix-chat STUB_GATE="$WORK/fix-gate"
  export STUB_SESSION=fix-worker STUB_TRANSCRIPT_SESSION=fix-worker STUB_TRANSCRIPT_ACCOUNT=fixacct
  ln -s "$b" "$WORK/fix-b-link"
  export STUB_EDIT_PATH="own.txt"$'\n'"extra.txt"$'\n'"$b/own.txt"$'\n'"$WORK/fix-b-link/link.txt"
  WORKER_TEST_WORKDIR=$a start_ok claudeb --round "$round"
  fixer=$RUN_ID
  unset STUB_EDIT_PATH STUB_TRANSCRIPT_SESSION STUB_SESSION
  WORKER_TEST_WORKDIR=$a start_ok codex
  other=$RUN_ID
  printf 'fixed\n' >>"$a/own.txt"
  printf 'fixed\n' >>"$a/extra.txt"
  printf 'fixed\n' >>"$a/shell.txt"
  printf 'fixed\n' >>"$b/own.txt"
  printf 'fixed\n' >>"$b/link.txt"
  printf 'fixed\n' >>"$b/shell.txt"
  printf 'other\n' >>"$a/theirs.txt"
  printf 'other\n' >>"$b/theirs.txt"
  : >"$STUB_GATE"
  unset STUB_GATE
  RUN_ID=$fixer; assert await_done
  RUN_ID=$other; assert await_done
  assert grep -qx "fix:$round:$fixer" <<<"$(fix_kinds "$a" own.txt)"
  assert grep -qx "fix:$round:$fixer" <<<"$(fix_kinds "$b" own.txt)"
  assert grep -qx "fix:$round:$fixer" <<<"$(fix_kinds "$a" extra.txt)"
  assert fix_holds_current "$b" own.txt
  # Named through a symlink to the repository, which no literal prefix of its top matches.
  assert grep -qx "fix:$round:$fixer" <<<"$(fix_kinds "$b" link.txt)"
  assert_fails grep -q '^fix:' <<<"$(fix_kinds "$a" theirs.txt)"
  assert_fails grep -q '^fix:' <<<"$(fix_kinds "$b" theirs.txt)"
  assert_fails fix_holds_current "$a" theirs.txt
  assert_fails fix_holds_current "$b" theirs.txt
  # Written through the shell, so no record names it until the launching chat claims it.
  assert_fails grep -q '^fix:' <<<"$(fix_kinds "$a" shell.txt)"
  "$RUNNER" claim "$fixer" --paths "$a/shell.txt" >/dev/null || fail "claim of the fixer's shell write failed"
  assert grep -qx "fix:$round:$fixer" <<<"$(fix_kinds "$a" shell.txt)"
  assert_fails grep -q '^fix:' <<<"$(fix_kinds "$b" shell.txt)"
  "$RUNNER" claim "$fixer" --paths "$WORK/fix-b-link/shell.txt" >/dev/null ||
    fail "claim of the fixer's shell write in the second repository failed"
  assert grep -qx "fix:$round:$fixer" <<<"$(fix_kinds "$b" shell.txt)"
  assert_fails grep -q '^fix:' <<<"$(fix_kinds "$b" theirs.txt)"
  assert_fails "$RUNNER" claim "$fixer" --paths "$b/theirs.txt/nope" 2>/dev/null
  assert_fails grep -q '^fix:' <<<"$(fix_kinds "$a" theirs.txt)"
  # A run outside any round claiming in the sibling repository: the launcher's touch, and no fold.
  export STUB_GATE="$WORK/manual-gate"
  WORKER_TEST_WORKDIR=$a start_ok codex
  printf 'manual\n' >"$b/manual.txt"
  : >"$STUB_GATE"
  unset STUB_GATE
  assert await_done
  review-anchors untouch --repo "$b" --session fix-chat manual.txt
  folded=$(jq -r --arg r "$RUN_ID" '.runs[$r].folded' "$b/.git/review-anchors.json")
  sleep 1
  "$RUNNER" claim "$RUN_ID" --paths "$b/manual.txt" >/dev/null || fail "claim in the sibling repository failed"
  assert jq -e --arg k "$b/.git" '.touches[$k]["manual.txt"]["fix-chat"] != null' "$b/.git/review-anchors.json" >/dev/null
  assert test "$(jq -r --arg r "$RUN_ID" '.runs[$r].folded' "$b/.git/review-anchors.json")" = "$folded"
  assert test ! -e "$HOME/.cache/claude/review-debt/gaps/fix-chat"
  export PATH="$saved_path"
  rm -f "$HOME/.cache/claude/review-journal/fix-chat.repos"
  unset PICK_RC PICK_ACCOUNT CLAUDE_CODE_SESSION_ID STUB_TRANSCRIPT_ACCOUNT
  clear_stub
}
fix_owned_tests

# A round fixer launched in the parent of its repositories (claudeb-1790559409, 2026-09-28): the
# workdir is no repository, so its fold and its claims go through the families it snapshotted.
fix_nonrepo_tests() {
  local parent c round=20260903T100000Z-ddddddd saved_path="$PATH" path
  fix_kinds() { jq -r --arg p "$2" '.anchors[$p][]?.kind' "$1/.git/review-anchors.json"; }
  mkdir -p "$WORK/fix-np/c"
  git -C "$WORK/fix-np/c" init -q .
  for path in own.txt shell.txt theirs.txt; do printf 'base\n' >"$WORK/fix-np/c/$path"; done
  git -C "$WORK/fix-np/c" add -A >/dev/null
  git -C "$WORK/fix-np/c" -c user.email=t@t -c user.name=t commit -qm base >/dev/null
  parent=$(cd "$WORK/fix-np" && pwd -P)
  c="$parent/c"
  mkdir -p "$CLAUDEB_DIR/worker-stats/benches/$round"
  jq -n --arg c "$c" '{repos: [{repo: $c, common_dir: ($c + "/.git"), label: "c"}],
    reviewed: {"c/own.txt": "x", "c/shell.txt": "x", "c/theirs.txt": "x"}}' \
    >"$CLAUDEB_DIR/worker-stats/benches/$round/meta.json"
  export PATH="$WORK/stamp-bin:$PATH"
  set_config 'claudeb_model=opus' 'claudeb_effort=high'
  clear_stub
  export PICK_RC=0 PICK_ACCOUNT=fixacct CLAUDE_CODE_SESSION_ID=np-chat
  export STUB_SESSION=np-worker STUB_TRANSCRIPT_SESSION=np-worker STUB_TRANSCRIPT_ACCOUNT=fixacct
  export STUB_EDIT_PATH="c/own.txt"
  WORKER_TEST_WORKDIR=$parent start_gated claudeb --round "$round"
  assert test -f "$RUN_DIR/families/1/top"
  printf 'fixed\n' >>"$c/own.txt"
  printf 'fixed\n' >>"$c/shell.txt"
  printf 'other\n' >>"$c/theirs.txt"
  gate_open
  assert await_done
  unset STUB_EDIT_PATH STUB_TRANSCRIPT_SESSION STUB_SESSION
  assert grep -qx "fix:$round:$RUN_ID" <<<"$(fix_kinds "$c" own.txt)"
  assert_fails grep -q '^fix:' <<<"$(fix_kinds "$c" shell.txt)"
  assert_fails grep -q '^fix:' <<<"$(fix_kinds "$c" theirs.txt)"
  "$RUNNER" claim "$RUN_ID" --paths c/shell.txt >/dev/null || fail "claim under a non-repository workdir failed"
  assert grep -qx "fix:$round:$RUN_ID" <<<"$(fix_kinds "$c" shell.txt)"
  assert_fails grep -q '^fix:' <<<"$(fix_kinds "$c" theirs.txt)"
  assert_fails "$RUNNER" claim "$RUN_ID" --paths c/never-changed.txt 2>/dev/null
  export PATH="$saved_path"
  unset PICK_RC PICK_ACCOUNT CLAUDE_CODE_SESSION_ID STUB_TRANSCRIPT_ACCOUNT
  clear_stub
}
fix_nonrepo_tests

# Snapshot attribution P1/P2 (after-snapshot UNKNOWN, first-row-wins, foreign HEAD, path shape, symlink, claim).
clear_stub
set_config 'claudeb_model=opus' 'claudeb_effort=high'
export PICK_RC=0 PICK_ACCOUNT=recordacct CLAUDE_CODE_SESSION_ID=chat-abc
mkdir -p "$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture"
ATTR_REPO="$WORK/attr-repo"
mkdir -p "$ATTR_REPO/bin"
git -C "$ATTR_REPO" init -q .
printf 'base\n' >"$ATTR_REPO/bin/keep"
git -C "$ATTR_REPO" add -A >/dev/null
git -C "$ATTR_REPO" -c user.email=t@t -c user.name=t commit -qm base >/dev/null
ATTR_TOP=$(cd "$ATTR_REPO" && pwd -P)
tab=$'\t'
blob_of() { printf '%s\n' "$1" | git -C "${1:-$ATTR_REPO}" hash-object --stdin; }
attr_blob() { printf '%s\n' "$1" | git -C "$ATTR_REPO" hash-object --stdin; }
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$ATTR_TOP/bin/keep" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"

start_gated claudeb --workdir "$ATTR_REPO"
printf 'stale-produced\n' >"$RUN_DIR/produced"
printf 'WORKDIR: %s\nstale-dirty\n' "$ATTR_TOP" >"$RUN_DIR/dirty"
mv "$ATTR_REPO/.git" "$ATTR_REPO/.git.hidden"
gate_open
assert await_done
mv "$ATTR_REPO/.git.hidden" "$ATTR_REPO/.git"
assert grep -q '^UNKNOWN: ' "$RUN_DIR/files"
assert test ! -e "$RUN_DIR/produced"
assert test ! -e "$RUN_DIR/dirty"
assert grep -q '^UNNAMED: ' "$WORK/wait.out"
assert grep -q "claim $RUN_ID" "$WORK/wait.out"
assert grep -q '^UNNAMED: ' <<<"$("$RUNNER" report "$RUN_ID")"
assert_fails "$RUNNER" claim "$RUN_ID" --paths bin/keep >"$WORK/claim-unknown.out" 2>&1
assert grep -q 'no after-snapshot' "$WORK/claim-unknown.out"

clear_stub
printf 'B\n' >"$ATTR_REPO/bin/rewritten-open"
git -C "$ATTR_REPO" add bin/rewritten-open
git -C "$ATTR_REPO" -c user.email=t@t -c user.name=t commit -qm 'head blob B' >/dev/null
printf 'D\n' >"$ATTR_REPO/bin/rewritten-open"
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$ATTR_TOP/bin/rewritten-open" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_gated claudeb --workdir "$ATTR_REPO"
printf 'C\n' >"$ATTR_REPO/bin/rewritten-open"
git -C "$ATTR_REPO" add bin/rewritten-open
git -C "$ATTR_REPO" -c user.email=t@t -c user.name=t commit -qm 'the run committed C' >/dev/null
gate_open
assert await_done
assert grep -qxF -- "$(attr_blob D)$tab$(attr_blob C)${tab}bin/rewritten-open" "$RUN_DIR/produced"
assert_fails grep -q $'\tbin/rewritten-open\tcommit$' "$RUN_DIR/produced"
assert_fails grep -qxF -- "$(attr_blob B)$tab$(attr_blob C)${tab}bin/rewritten-open${tab}commit" "$RUN_DIR/produced"

clear_stub
UP_REPO="$WORK/upstream-repo"
mkdir -p "$UP_REPO/bin"
git -C "$UP_REPO" init -q .
printf 'shared\n' >"$UP_REPO/bin/shared"
git -C "$UP_REPO" add -A >/dev/null
git -C "$UP_REPO" -c user.email=t@t -c user.name=t commit -qm base >/dev/null
git clone -q "$UP_REPO" "$WORK/run-clone"
printf 'upstream\n' >"$UP_REPO/bin/from-upstream"
git -C "$UP_REPO" add bin/from-upstream
GIT_AUTHOR_DATE='2020-01-01T00:00:00' GIT_COMMITTER_DATE='2020-01-01T00:00:00' \
  git -C "$UP_REPO" -c user.email=t@t -c user.name=t commit -qm 'old upstream' >/dev/null
CLONE_TOP=$(cd "$WORK/run-clone" && pwd -P)
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$CLONE_TOP/bin/ours" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_gated claudeb --workdir "$WORK/run-clone"
git -C "$WORK/run-clone" fetch -q origin && git -C "$WORK/run-clone" merge --ff-only -q FETCH_HEAD
printf 'ours\n' >"$WORK/run-clone/bin/ours"
gate_open
assert await_done
assert grep -q 'bin/ours' "$RUN_DIR/produced"
assert_fails grep -q 'from-upstream' "$RUN_DIR/produced"
assert_fails grep -qx 'bin/from-upstream' "$RUN_DIR/files"
assert grep -q 'outside the run window' "$RUN_DIR/files-note"

clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$ATTR_TOP/bin/keep" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_gated claudeb --workdir "$ATTR_REPO"
printf 'dash\n' >"$ATTR_REPO/-odd-name"
gate_open
assert await_done
assert grep -q '^UNKNOWN: ' "$RUN_DIR/files"
assert_fails grep -q -- '-odd-name' "$RUN_DIR/files"
assert test ! -e "$RUN_DIR/produced"

# Present before the run and untouched by it, the same file leaves the rest of the snapshot standing.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$ATTR_TOP/bin/keep" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_gated claudeb --workdir "$ATTR_REPO"
printf 'kept-by-run\n' >"$ATTR_REPO/bin/keep"
gate_open
assert await_done
assert_fails grep -q '^UNKNOWN: ' "$RUN_DIR/files"
assert grep -qx 'bin/keep' "$RUN_DIR/files"
assert_fails grep -q -- '-odd-name' "$RUN_DIR/files" "$RUN_DIR/produced"
assert grep -q $'\tbin/keep$' "$RUN_DIR/produced"

clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$ATTR_TOP/bin/keep" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_gated claudeb --workdir "$ATTR_REPO"
printf 'rewritten\n' >"$ATTR_REPO/-odd-name"
gate_open
assert await_done
assert grep -q '^UNKNOWN: ' "$RUN_DIR/files"
assert test ! -e "$RUN_DIR/produced"
# The launching chat can still name what the unknown snapshot could not.
assert test ! -e "$RUN_DIR/head-after"
assert "$RUNNER" claim "$RUN_ID" --paths bin/keep --complete >/dev/null
assert grep -qx 'bin/keep' "$RUN_DIR/files"
git -C "$ATTR_REPO" checkout -q -- bin/keep
rm -f "$ATTR_REPO/-odd-name"

clear_stub
mkdir -p "$ATTR_REPO/target-dir"
printf 'old-target\n' >"$ATTR_REPO/old-file"
printf 'new-target\n' >"$ATTR_REPO/new-file"
ln -s old-file "$ATTR_REPO/link-file"
ln -s target-dir "$ATTR_REPO/link-dir"
git -C "$ATTR_REPO" add -A >/dev/null
git -C "$ATTR_REPO" -c user.email=t@t -c user.name=t commit -qm 'symlinks' >/dev/null
TOOL_TS=$(iso $(($(date +%s) + 60)))
# A symlink is made with `ln`, never with an editor call: the run says so, or the two links below
# that no tool call names read as another writer's.
{
  tool_call Edit file_path "$ATTR_TOP/link-file"
  tool_call Bash command 'ln -sf new-file link-file; ln -s missing dangling'
} >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_gated claudeb --workdir "$ATTR_REPO"
ln -sf new-file "$ATTR_REPO/link-file"
ln -s missing "$ATTR_REPO/dangling"
ln -s target-dir "$ATTR_REPO/new-link-dir"
gate_open
assert await_done
link_prev=$(printf '%s' old-file | git -C "$ATTR_REPO" hash-object --stdin)
link_cur=$(printf '%s' new-file | git -C "$ATTR_REPO" hash-object --stdin)
dang_cur=$(printf '%s' missing | git -C "$ATTR_REPO" hash-object --stdin)
dir_cur=$(printf '%s' target-dir | git -C "$ATTR_REPO" hash-object --stdin)
assert grep -qxF -- "$link_prev$tab$link_cur${tab}link-file" "$RUN_DIR/produced"
assert_fails grep -q 'dangling\|new-link-dir' "$RUN_DIR/produced"
assert grep -qx dangling "$RUN_DIR/dirty"
assert grep -qx new-link-dir "$RUN_DIR/dirty"
assert "$RUNNER" claim "$RUN_ID" --paths dangling new-link-dir >/dev/null
assert grep -qxF -- "-$tab$dang_cur${tab}dangling" "$RUN_DIR/produced"
assert grep -qxF -- "-$tab$dir_cur${tab}new-link-dir" "$RUN_DIR/produced"
assert_fails grep -q $'\t-\tdangling$' "$RUN_DIR/produced"
assert_fails grep -q $'\t-\tnew-link-dir$' "$RUN_DIR/produced"
assert_fails grep -q $'\t-\tlink-dir$' "$RUN_DIR/produced"

# snapshot_tab_or_newline_path_unknown
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$ATTR_TOP/bin/keep" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_gated claudeb --workdir "$ATTR_REPO"
printf 'during-run\n' >"$ATTR_REPO/bin/keep"
printf 'tabbed\n' >"$ATTR_REPO/bin/has${tab}tab"
printf 'nl\n' >"$ATTR_REPO/bin/has"$'\n'"nl"
gate_open
assert await_done
assert test "$(head -n1 "$RUN_DIR/files")" = "WORKDIR: $ATTR_TOP"
assert grep -q '^UNKNOWN: ' "$RUN_DIR/files"
assert_fails grep -q '^PARTIAL: ' "$RUN_DIR/files"
assert test "$(grep -cv '^WORKDIR: \|^UNKNOWN: ' "$RUN_DIR/files")" -eq 0
assert_fails grep -qx 'bin/keep' "$RUN_DIR/files"
assert test ! -s "$RUN_DIR/produced"
rm -f "$ATTR_REPO/bin/has${tab}tab" "$ATTR_REPO/bin/has"$'\n'"nl"

# snapshot_linked_worktree_attribution
clear_stub
WT_DIR="$WORK/attr-linked-wt"
git -C "$ATTR_REPO" worktree add -b attr-linked "$WT_DIR" >/dev/null
WT_TOP=$(cd "$WT_DIR" && pwd -P)
printf 'wt-head\n' >"$WT_DIR/bin/in-wt"
git -C "$WT_DIR" add bin/in-wt
git -C "$WT_DIR" -c user.email=t@t -c user.name=t commit -qm 'worktree head' >/dev/null
WT_HEAD=$(git -C "$WT_DIR" rev-parse HEAD)
WT_PREV=$(git -C "$WT_DIR" rev-parse HEAD:bin/in-wt)
MAIN_HEAD=$(git -C "$ATTR_REPO" rev-parse HEAD)
assert test "$WT_HEAD" != "$MAIN_HEAD"
printf 'main-only\n' >"$ATTR_REPO/bin/main-dirt"
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$WT_TOP/bin/in-wt" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_gated claudeb --workdir "$WT_DIR"
printf 'run-edit\n' >"$WT_DIR/bin/in-wt"
gate_open
assert await_done
assert test "$(cat "$RUN_DIR/head-before")" = "$WT_HEAD"
assert grep -qx 'bin/in-wt' "$RUN_DIR/files"
assert grep -qxF -- "$WT_PREV$tab$(attr_blob run-edit)${tab}bin/in-wt" "$RUN_DIR/produced"
assert_fails grep -q 'main-dirt' "$RUN_DIR/files"
assert_fails grep -q 'main-dirt' "$RUN_DIR/produced"
assert_fails grep -q '^UNKNOWN: \|^PARTIAL: ' "$RUN_DIR/files"

# snapshot_rename_delete_and_birth
clear_stub
printf 'same-blob\n' >"$ATTR_REPO/bin/renamed-from"
git -C "$ATTR_REPO" add bin/renamed-from
git -C "$ATTR_REPO" -c user.email=t@t -c user.name=t commit -qm 'to rename' >/dev/null
TOOL_TS=$(iso $(($(date +%s) + 60)))
{
  tool_call Edit file_path "$ATTR_TOP/bin/renamed-from"
  tool_call Write file_path "$ATTR_TOP/bin/renamed-to"
  tool_call Bash command 'git mv bin/renamed-from bin/renamed-to'
} >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_gated claudeb --workdir "$ATTR_REPO"
git -C "$ATTR_REPO" mv bin/renamed-from bin/renamed-to
git -C "$ATTR_REPO" -c user.email=t@t -c user.name=t commit -qm 'rename inside the run' >/dev/null
gate_open
assert await_done
rename_blob=$(attr_blob same-blob)
assert grep -qx 'bin/renamed-from' "$RUN_DIR/files"
assert grep -qx 'bin/renamed-to' "$RUN_DIR/files"
assert grep -qxF -- "$rename_blob$tab-${tab}bin/renamed-from${tab}commit" "$RUN_DIR/produced"
assert grep -qxF -- "-$tab$rename_blob${tab}bin/renamed-to${tab}commit" "$RUN_DIR/produced"
assert_fails grep -q 'renamed-from.*renamed-to' "$RUN_DIR/produced"
assert_fails grep -q 'renamed-to.*renamed-from' "$RUN_DIR/produced"

# snapshot_missing_after_killed_supervisor
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$ATTR_TOP/bin/keep" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_gated claudeb --workdir "$ATTR_REPO"
printf 'killed-edit\n' >"$ATTR_REPO/bin/keep"
gate_open
assert await_done
assert test -f "$RUN_DIR/dirty-before-shas"
assert test -f "$RUN_DIR/head-before"
rm -f "$RUN_DIR/head-after" "$RUN_DIR/dirty-after-shas" "$RUN_DIR/files" "$RUN_DIR/produced"
killed_report=$("$RUNNER" report "$RUN_ID")
assert grep -qi 'UNKNOWN\|unknown' <<<"$killed_report"
assert grep -q "claim $RUN_ID" <<<"$killed_report"
assert_fails "$RUNNER" claim "$RUN_ID" --paths bin/keep >"$WORK/claim-killed.out" 2>&1
assert grep -q 'no after-snapshot' "$WORK/claim-killed.out"

clear_stub
rc=0
"$RUNNER" start codex --brief "$WORK/brief" --chrome >"$WORK/start.out" 2>"$WORK/start.err" || rc=$?
assert test "$rc" -eq 4
assert grep -q 'only claudeb supports --chrome' "$WORK/start.err"
assert test ! -s "$CALL_LOG"

clear_stub
start_ok claudeb
assert await_done
assert test "$(grep -c '^ARG=--chrome$' "$CALL_LOG")" -eq 0
assert jq -e '.chrome == false' "$RUN_DIR/meta.json" >/dev/null

clear_stub
start_ok claudeb --chrome
assert await_done
assert grep -qx 'ARG=--chrome' "$CALL_LOG"
assert jq -e '.chrome == true' "$RUN_DIR/meta.json" >/dev/null
assert jq -e '.cmd | index("--chrome") != null' "$RUN_DIR/meta.json" >/dev/null

clear_stub
: >"$STUB_DIR/claudeb_drop_effort"
start_ok claudeb --chrome
assert await_done
assert test "$(grep -c '^CLAUDEB_CALL$' "$CALL_LOG")" -eq 2
assert test "$(grep -c '^ARG=--chrome$' "$CALL_LOG")" -eq 2
assert jq -e '.effort_flag_dropped == true' "$RUN_DIR/meta.json" >/dev/null
assert jq -e '.chrome == true' "$RUN_DIR/meta.json" >/dev/null
# Each CLI launch is stamped, the effort-flag retry inside one attempt included, with its own
# duration and exit code; the run's end and its terminal reason beside them.
assert jq -e '(.cli_starts | length) == 2 and (.attempt_secs | length) == 2 and .attempt_rcs[-1] == 0
  and (.cli_starts | all(type == "number" and . >= $m.pid_started_at))
  and .ended_at >= .cli_starts[-1] and .terminal_reason == "done"' --argjson m "$(cat "$RUN_DIR/meta.json")" \
  "$RUN_DIR/meta.json" >/dev/null
# Every child of the run knows which run it belongs to.
assert test "$(cat "$STUB_DIR/run_id_env")" = "$RUN_ID"

# runs.jsonl: one row per finished run, the record's timings with it; never a second row for one run.
RUNS_JOURNAL="$CLAUDEB_DIR/worker-stats/runs.jsonl"
assert jq -se --arg r "$RUN_ID" '[.[] | select(.run == $r)] | length == 1' "$RUNS_JOURNAL" >/dev/null
assert jq -se --arg r "$RUN_ID" --argjson m "$(cat "$RUN_DIR/meta.json")" 'map(select(.run == $r))[0] as $row
  | ($row | keys) == (["run", "vendor", "account", "role", "model", "effort", "light", "workdir", "launcher", "resume",
      "round", "pid_started_at", "started_at", "cli_starts", "attempt_secs", "attempt_rcs", "walled", "ended_at",
      "exit_code", "status", "reason"] | sort)
  and $row.vendor == "claudeb" and $row.status == "done" and $row.reason == "done" and $row.exit_code == 0
  and $row.cli_starts == $m.cli_starts and $row.attempt_secs == $m.attempt_secs and $row.ended_at == $m.ended_at
  and $row.started_at == $m.started_at and $row.pid_started_at == $m.pid_started_at and $row.resume == false' \
  "$RUNS_JOURNAL" >/dev/null

# A walled attempt rerouted: two launches on two accounts, the wall named in the row, and started_at
# restamped for the rescue attempt as the watchdog's deadline needs.
clear_stub
printf 'wall\n' >"$STUB_DIR/wall_accounts"
PICK_ACCOUNT=rescue start_ok codex --account wall
assert await_done
assert jq -e '(.cli_starts | length) == 2 and .attempt_rcs[0] != 0 and .attempt_rcs[1] == 0
  and .started_at >= .cli_starts[0] and .walled_accounts == ["wall"] and .terminal_reason == "done"' \
  "$RUN_DIR/meta.json" >/dev/null
assert jq -se --arg r "$RUN_ID" 'map(select(.run == $r)) | length == 1 and .[0].walled == ["wall"]
  and (.[0].attempt_rcs | length) == 2' "$RUNS_JOURNAL" >/dev/null

# A run that never reached its CLI ends as no-start, and still gets its row.
clear_stub
no_start="$WORKER_RUN_DIR/codex-no-start"
mkdir -p "$no_start"
jq -n --arg w "$WORK/workdir" '{vendor: "codex", account: "a", workdir: $w, started_at: 1, pid_started_at: 1}' \
  >"$no_start/meta.json"
"$RUNNER" _deliver "$no_start" 4 >/dev/null 2>&1
assert jq -e '.terminal_reason == "no-start" and (.ended_at | type) == "number"' "$no_start/meta.json" >/dev/null
assert jq -se 'map(select(.run == "codex-no-start")) | length == 1 and .[0].reason == "no-start" and .[0].cli_starts == []' \
  "$RUNS_JOURNAL" >/dev/null

# Rows are kept 35 days: the first run end of a day drops older ones, a later one leaves the file alone.
now=$(date +%s)
jq -nc --argjson t "$((now - 36 * 86400))" '{run: "old", ended_at: $t}' >>"$RUNS_JOURNAL"
jq -nc --argjson t "$((now - 34 * 86400))" '{run: "kept", ended_at: $t}' >>"$RUNS_JOURNAL"
rm -f "$RUNS_JOURNAL.pruned"
"$RUNNER" _deliver "$no_start" 4 >/dev/null 2>&1
assert jq -se 'map(.run) | index("old") == null and index("kept") != null' "$RUNS_JOURNAL" >/dev/null
jq -nc --argjson t "$((now - 40 * 86400))" '{run: "old-again", ended_at: $t}' >>"$RUNS_JOURNAL"
"$RUNNER" _deliver "$no_start" 4 >/dev/null 2>&1
assert jq -se 'map(.run) | index("old-again") != null' "$RUNS_JOURNAL" >/dev/null
assert test ! -e "$RUNS_JOURNAL.lock"

echo "PASS: $asserts asserts; refused models, the launcher stamp on every relay, fix anchors, snapshot attribution"
