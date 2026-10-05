#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/worker_run_harness.sh"

# --- the anchors store ---------------------------------------------------------------------------
# `review-anchors` belongs to another repository; here it is a PATH shim logging one tab-separated
# line per call, so what worker-run promises the store is checked without the store existing.
anchors_store_tests() {
  local repo bench rc bad changed fold bases saved_path
  local dirty_base doomed_base empty_blob=e69de29bb2d1d6434b8b29ae775ad8c2e48c5391
  local anchors_tab=$'\t'
  ANCHOR_LOG="$WORK/anchors.log"
  export ANCHOR_LOG
  cat >"$WORK/bin/review-anchors" <<'ANCHORS'
#!/usr/bin/env bash
{ printf '%s' "$1"; shift; [ "$#" -eq 0 ] || printf '\t%s' "$@"; printf '\n'; } >>"$ANCHOR_LOG"
[ -z "${ANCHORS_FAIL:-}" ] || { printf 'store locked\nsecond line\n' >&2; exit 3; }
ANCHORS
  chmod +x "$WORK/bin/review-anchors"
  : >"$ANCHOR_LOG"

  anchors_line() { grep "^$1$anchors_tab" "$ANCHOR_LOG" | tail -n 1; }
  anchors_changed() {
    anchors_line run-fold | tr '\t' '\n' |
      awk '/^--/ { listing = 0 } listing { sub(/^\.\//, ""); print } $0 == "--changed" { listing = 1 }'
  }
  anchors_bases() {
    anchors_line run-fold | tr '\t' '\n' | awk 'sub(/^--base=\.\//, "") { print }'
  }

  repo="$WORK/anchors-repo"
  mkdir -p "$repo/bin"
  git -C "$repo" init -q .
  printf 'base\n' >"$repo/bin/keep"
  printf 'gone\n' >"$repo/bin/doomed"
  git -C "$repo" add -A >/dev/null
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm base >/dev/null
  repo=$(cd "$repo" && pwd -P)
  bench="${CLAUDEB_DIR}/worker-stats/benches"
  mkdir -p "$bench/20260901T100000Z-aaaaaaa" "$bench/20260901T110000Z-bbbbbbb"

  set_config 'codex_model=default' 'codex_effort=high' 'claudeb_model=opus' 'claudeb_effort=high'
  export PICK_RC=0 PICK_ACCOUNT=recordacct CLAUDE_CODE_SESSION_ID=anchors-chat

  # An id of the wrong shape and an id no bench holds are refused at LAUNCH and alike: a run bound
  # to a round nothing recorded would anchor its fix against nothing at all.
  for bad in 20260901T100000Z-AAAAAAA 20260901T100000Z-aaaaaa 20260901T990000Z-fffffff; do
    clear_stub
    rc=0
    "$RUNNER" start codex --brief "$WORK/brief" --workdir "$repo" --round "$bad" \
      >"$WORK/anchors.out" 2>"$WORK/anchors.err" || rc=$?
    assert test "$rc" -eq 4
    assert test "$(wc -l <"$WORK/anchors.err" | tr -d ' ')" = 1
    assert grep -Fq -- '--round names no review round on record' "$WORK/anchors.err"
    assert_fails grep -q '^RUN: ' "$WORK/anchors.out"
  done
  assert test ! -s "$ANCHOR_LOG"

  # The flag is the binding review-bench composes; the header it also writes is the fallback, so a
  # brief naming another round loses to it.
  clear_stub
  printf 'ROUND: 20260901T110000Z-bbbbbbb\nFix the confirmed findings.\n' >"$WORK/anchors-brief"
  # Left dirty BEFORE the launch, so the base the fold reports for it can only have come from the
  # run's own before-listing and not from the commit the run started on.
  printf 'first\n' >"$repo/bin/dirty-first"
  dirty_base=$(git -C "$repo" hash-object "$repo/bin/dirty-first")
  doomed_base=$(git -C "$repo" rev-parse HEAD:bin/doomed)
  # Two Cyrillic names a UTF-8 awk collates as equal: a lookup by name must still tell them apart.
  printf 'ef\n' >"$repo/bin/ф"
  export STUB_GATE="$WORK/anchors-gate"
  rm -f "$STUB_GATE"
  LC_ALL=en_US.UTF-8 "$RUNNER" start codex --brief "$WORK/anchors-brief" --workdir "$repo" \
    --round 20260901T100000Z-aaaaaaa >"$WORK/anchors.out" 2>"$WORK/anchors.err" ||
    fail "round start failed: $(<"$WORK/anchors.err")"
  RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/anchors.out")
  RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/anchors.out")
  assert test "$(jq -r '.review_round' "$RUN_DIR/meta.json")" = 20260901T100000Z-aaaaaaa
  await_launched
  # A round run opens its record, so the fold can tell the run's own commits from a commit landed
  # beside it.
  assert test "$(anchors_line run-start)" = \
    "run-start${anchors_tab}--repo${anchors_tab}${repo}${anchors_tab}--run${anchors_tab}${RUN_ID}${anchors_tab}--session${anchors_tab}anchors-chat"
  # Every kind of change the run's own listings can see, and nothing the transcript has to name: a
  # file written through a heredoc, a file deleted, a file committed inside the run.
  printf 'heredoc\n' >"$repo/bin/heredoc-only"
  printf 'new\n' >"$repo/bin/новый"
  printf 'second\n' >>"$repo/bin/dirty-first"
  rm "$repo/bin/doomed"
  printf 'committed\n' >"$repo/bin/committed"
  git -C "$repo" add bin/committed >/dev/null
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm inside >/dev/null
  : >"$STUB_GATE"
  unset STUB_GATE
  assert await_done
  changed=$(anchors_changed)
  assert grep -qx 'bin/heredoc-only' <<<"$changed"
  assert grep -qx 'bin/doomed' <<<"$changed"
  assert grep -qx 'bin/committed' <<<"$changed"
  assert grep -qx 'bin/dirty-first' <<<"$changed"
  assert_fails grep -qx 'bin/keep' <<<"$changed"
  assert grep -qx 'bin/новый' <<<"$changed"
  assert_fails grep -qx 'bin/ф' <<<"$changed"
  # Every changed path carries what it stood at before the run, which is the only thing that lets
  # the store anchor a path no review has ever read: the path's own before-content where it had
  # one, the HEAD it started from where it was clean, and the empty blob where the run made it.
  bases=$(anchors_bases)
  assert test "$(grep -c . <<<"$bases")" = "$(grep -c . <<<"$changed")"
  assert grep -qx "bin/dirty-first=$dirty_base" <<<"$bases"
  assert grep -qx "bin/doomed=$doomed_base" <<<"$bases"
  assert grep -qx "bin/heredoc-only=$empty_blob" <<<"$bases"
  assert grep -qx "bin/committed=$empty_blob" <<<"$bases"
  assert grep -qx "bin/новый=$empty_blob" <<<"$bases"
  assert test "$(git -C "$repo" hash-object -t blob /dev/null)" = "$empty_blob"
  fold=$(anchors_line run-fold)
  assert grep -qF -- "--repo${anchors_tab}${repo}${anchors_tab}--run${anchors_tab}${RUN_ID}" <<<"$fold"
  assert grep -qF -- "--session${anchors_tab}anchors-chat" <<<"$fold"
  assert grep -qF -- "--round${anchors_tab}20260901T100000Z-aaaaaaa" <<<"$fold"
  assert grep -qF -- "--after=./bin/heredoc-only=$(git -C "$repo" hash-object bin/heredoc-only)" <<<"$fold"
  assert grep -qF -- "--after=./bin/doomed=$empty_blob" <<<"$fold"

  # A round run that also writes in an --add-dir repository is folded there too, or a fix it makes
  # there is never anchored.
  clear_stub
  : >"$ANCHOR_LOG"
  other="$WORK/anchors-other"
  mkdir -p "$other"
  git -C "$other" init -q .
  printf 'base\n' >"$other/kept"
  git -C "$other" add -A >/dev/null
  git -C "$other" -c user.email=t@t -c user.name=t commit -qm base >/dev/null
  other=$(cd "$other" && pwd -P)
  kept_base=$(git -C "$other" rev-parse HEAD:kept)
  export STUB_GATE="$WORK/anchors-gate"
  rm -f "$STUB_GATE"
  "$RUNNER" start codex --brief "$WORK/anchors-brief" --workdir "$repo" --add-dir "$other" \
    --round 20260901T100000Z-aaaaaaa >"$WORK/anchors.out" 2>"$WORK/anchors.err" ||
    fail "two-family start failed: $(<"$WORK/anchors.err")"
  RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/anchors.out")
  RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/anchors.out")
  await_launched
  assert grep -qxF "run-start${anchors_tab}--repo${anchors_tab}${other}${anchors_tab}--run${anchors_tab}${RUN_ID}${anchors_tab}--session${anchors_tab}anchors-chat" "$ANCHOR_LOG"
  printf 'fixed\n' >>"$other/kept"
  : >"$STUB_GATE"
  unset STUB_GATE
  assert await_done
  fold=$(grep "^run-fold${anchors_tab}--repo${anchors_tab}${other}${anchors_tab}" "$ANCHOR_LOG" | tail -n 1)
  assert grep -qF -- "--run${anchors_tab}${RUN_ID}" <<<"$fold"
  assert grep -qF -- "--round${anchors_tab}20260901T100000Z-aaaaaaa" <<<"$fold"
  assert grep -qF -- "--changed${anchors_tab}./kept${anchors_tab}" <<<"$fold"
  assert grep -qF -- "--base=./kept=$kept_base" <<<"$fold"
  assert grep -qF -- "--after=./kept=$(git -C "$other" hash-object kept)" <<<"$fold"
  assert test "$(grep -c "^run-fold${anchors_tab}--repo${anchors_tab}${other}${anchors_tab}" "$ANCHOR_LOG")" = 1

  # A workdir in a linked worktree (night run 20260930T001419Z-8480, run 56f7): the sibling family
  # is the other repository's worktree on the same branch, never its main checkout.
  clear_stub
  : >"$ANCHOR_LOG"
  git -C "$repo" worktree add -q -b night/n1/job "$WORK/anchors-repo-wt" >/dev/null 2>&1 ||
    fail "worktree add in $repo failed"
  git -C "$other" worktree add -q -b night/n1/job "$WORK/anchors-other-wt" >/dev/null 2>&1 ||
    fail "worktree add in $other failed"
  repo_wt=$(cd "$WORK/anchors-repo-wt" && pwd -P)
  other_wt=$(cd "$WORK/anchors-other-wt" && pwd -P)
  export STUB_GATE="$WORK/anchors-gate"
  rm -f "$STUB_GATE"
  "$RUNNER" start codex --brief "$WORK/anchors-brief" --workdir "$repo_wt" --add-dir "$other" \
    --round 20260901T100000Z-aaaaaaa >"$WORK/anchors.out" 2>"$WORK/anchors.err" ||
    fail "worktree start failed: $(<"$WORK/anchors.err")"
  RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/anchors.out")
  RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/anchors.out")
  await_launched
  assert grep -qxF "run-start${anchors_tab}--repo${anchors_tab}${other_wt}${anchors_tab}--run${anchors_tab}${RUN_ID}${anchors_tab}--session${anchors_tab}anchors-chat" "$ANCHOR_LOG"
  assert_fails grep -qF "run-start${anchors_tab}--repo${anchors_tab}${other}${anchors_tab}" "$ANCHOR_LOG"
  assert grep -qxF "$other_wt" "$RUN_DIR/families/1/top"
  # A family worktree landed and removed mid-run drops its run record in the main checkout, and
  # anchors nothing there.
  git -C "$other" worktree remove --force "$other_wt" >/dev/null 2>&1
  : >"$STUB_GATE"
  unset STUB_GATE
  assert await_done
  assert test "$(grep "^run-fold${anchors_tab}--repo${anchors_tab}${other}${anchors_tab}" "$ANCHOR_LOG")" = \
    "run-fold${anchors_tab}--repo${anchors_tab}${other}${anchors_tab}--run${anchors_tab}${RUN_ID}${anchors_tab}--session${anchors_tab}anchors-chat${anchors_tab}--round${anchors_tab}20260901T100000Z-aaaaaaa${anchors_tab}--owned"
  assert grep -qF "run-fold${anchors_tab}--repo${anchors_tab}${repo_wt}${anchors_tab}--run${anchors_tab}${RUN_ID}" "$ANCHOR_LOG"
  git -C "$repo" worktree remove --force "$repo_wt" >/dev/null 2>&1

  # A run bound to no round tells the store nothing: debt is per repository, priced from git, and no
  # per-chat run record opens or folds. Failed or not, and whatever it changed.
  clear_stub
  : >"$ANCHOR_LOG"
  export STUB_CODE=3
  start_gated codex --workdir "$repo" --add-dir "$other"
  printf 'plain\n' >"$repo/bin/plain-run"
  gate_open
  assert await_done
  assert grep -q '^STATUS: failed' "$WORK/wait.out"
  assert test ! -s "$ANCHOR_LOG"
  assert test ! -e "$HOME/.cache/claude/review-debt/gaps"
  rm -f "$repo/bin/plain-run"
  unset STUB_CODE

  # A round run on a machine with no store, or one whose store refuses, still completes, and no gap
  # file stands in for the store.
  clear_stub
  : >"$ANCHOR_LOG"
  mv "$WORK/bin/review-anchors" "$WORK/bin/review-anchors.off"
  saved_path=$PATH
  PATH=$(IFS=:; keep=''
    for entry in $PATH; do
      { [ -z "$entry" ] || [ -x "$entry/review-anchors" ]; } && continue
      keep="${keep:+$keep:}$entry"
    done
    printf '%s' "$keep")
  export PATH
  start_gated codex --workdir "$repo" --round 20260901T100000Z-aaaaaaa
  gate_open
  assert await_done
  PATH=$saved_path
  export PATH
  assert test ! -s "$ANCHOR_LOG"
  mv "$WORK/bin/review-anchors.off" "$WORK/bin/review-anchors"
  clear_stub
  export ANCHORS_FAIL=1
  start_ok codex --workdir "$repo" --round 20260901T100000Z-aaaaaaa
  assert await_done
  assert grep -q "^run-fold$anchors_tab" "$ANCHOR_LOG"
  unset ANCHORS_FAIL
  assert test ! -e "$HOME/.cache/claude/review-debt/gaps"

  # A workdir that became a repository during the run has nothing to fold; its families still do.
  clear_stub
  : >"$ANCHOR_LOG"
  born="$WORK/anchors-born"
  mkdir -p "$born"
  born=$(cd "$born" && pwd -P)
  WORKER_TEST_WORKDIR=$born start_gated codex --add-dir "$repo" --round 20260901T100000Z-aaaaaaa
  git -C "$born" init -q .
  git -C "$born" -c user.email=t@t -c user.name=t commit -q --allow-empty -m born
  gate_open
  assert await_done
  assert_fails grep -qF "run-fold${anchors_tab}--repo${anchors_tab}${born}${anchors_tab}" "$ANCHOR_LOG"
  assert test ! -e "$born/.git/review-anchors.json"
  assert grep -qF "run-fold${anchors_tab}--repo${anchors_tab}${repo}${anchors_tab}--run${anchors_tab}${RUN_ID}" "$ANCHOR_LOG"

  # The vendor process is told both: whose debt what it writes is, and where its own run record is.
  clear_stub
  : >"$ANCHOR_LOG"
  start_ok claudeb --workdir "$repo"
  assert await_done
  assert test "$(cat "$STUB_DIR/debt_owner_env")" = anchors-chat
  assert test "$(cat "$STUB_DIR/run_record_env")" = "$RUN_DIR"

  clear_stub
  unset CLAUDE_CODE_SESSION_ID
}
attribution_repair_tests() {
  local repo="$WORK/attribution-repair" outside="$WORK/outside-repair" command variant report note
  eval "$(sed -n '/^writes_through_shell() {/,/^}/p' "$RUNNER")"
  parser_failure_is_unknown() (
    python3() { return 2; }
    writes_through_shell 'git diff'
  )
  assert parser_failure_is_unknown
  for command in 'python3 -c "rewrite()"' 'python3 -' 'tee target' 'perl -pi -e s/a/b/ target' \
      'git apply changes.patch' 'patch -p1' 'mv source target' 'cp source target' \
      'install source target' 'bash tests/../rewrite.sh' 'printf data >target' 'grep x source >target' \
      'sed -n "1p" -e "w target" source' 'bash -c "rewrite"' 'unknown-command' \
      'grep "unterminated' 'printf "$(rewrite)"' 'pnpm install >/dev/null 2>&1' \
      "node -e 'items.filter(x => x)'"; do
    assert writes_through_shell "$command"
  done
  for command in '' 'grep x source' 'sed -n "1,5p" source' 'git diff --stat' \
      'bash tests/test_worker_run.sh' 'git status --short 2>/dev/null' \
      'grep x source | head -n 3' 'git diff 2>&1' \
      "printf '%s' 'a >= b' 'x => x'"; do
    assert_fails writes_through_shell "$command"
  done
  clear_stub
  set_config 'claudeb_model=opus' 'claudeb_effort=high'
  export PICK_RC=0 PICK_ACCOUNT=recordacct CLAUDE_CODE_SESSION_ID=chat-abc
  mkdir -p "$repo/bin" "$outside" "$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture"
  git -C "$repo" init -q
  printf 'base\n' >"$repo/bin/restored"
  git -C "$repo" add bin/restored
  git -C "$repo" -c user.name=fixture -c user.email=fixture@example.test commit -qm base
  repo=$(cd "$repo" && pwd -P)
  outside=$(cd "$outside" && pwd -P)
  for variant in readonly python sed bash unknown empty whitespace undated comment splitcalls unreadable missing namedonly shellonly; do
    [ -z "${WORKER_RUN_TEST_ATTRIBUTION_CASE:-}" ] || [ "$variant" = "$WORKER_RUN_TEST_ATTRIBUTION_CASE" ] || continue
    case "$variant" in
      readonly) command='grep base bin/restored; sed -n "1,5p" bin/restored; git diff; bash tests/run.sh' ;;
      python) command=$'python3 - <<\'EOF\'\nfrom pathlib import Path\nPath("bin/restored").write_text("base\\n")\nEOF' ;;
      sed) command='sed -i "" s/dirty/base/ bin/restored' ;;
      bash) command='bash -c "python3 rewrite.py"' ;;
      unknown) command='custom-rewriter bin/restored' ;;
      empty) command='' ;;
      whitespace) command='   ' ;;
      undated) command='grep base bin/restored' ;;
      comment) command=$'grep base bin/restored # inspected\npython3 -c "rewrite()"' ;;
      splitcalls) command="echo '" ;;
      unreadable|missing) command='git diff' ;;
      namedonly) command='python3 -c "rewrite()"' ;;
      shellonly) command=$'python3 - <<\'EOF\'\nfrom pathlib import Path\nPath("bin/restored").write_text("base\\n")\nEOF' ;;
    esac
    printf 'dirty\n' >"$repo/bin/restored"
    TOOL_TS=$(iso $(($(date +%s) + 60)))
    {
      [ "$variant" = shellonly ] || tool_call Edit file_path "$repo/bin/named"
      if [ "$variant" = undated ]; then
        tool_call Bash command "$command" | jq '.timestamp = "unparseable"'
      else
        tool_call Bash command "$command"
      fi
      [ "$variant" != splitcalls ] || tool_call Bash command "python3 -c rewrite #'"
    } >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
    case "$variant" in
      unreadable) printf 'not json\n' >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl" ;;
      missing) rm "$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl" ;;
    esac
    if [ "$variant" = shellonly ]; then
      printf '#!/usr/bin/env bash\n%s\n' "$command" >"$STUB_DIR/relay_hook"
      chmod +x "$STUB_DIR/relay_hook"
    fi
    start_gated claudeb --workdir "$repo"
    [ "$variant" = namedonly ] || git -C "$repo" show HEAD:bin/restored >"$repo/bin/restored"
    [ "$variant" = shellonly ] || printf '%s\n' "$variant" >"$repo/bin/named"
    gate_open
    assert await_done
    rm -f "$STUB_DIR/relay_hook"
    if [ "$variant" = unreadable ] || [ "$variant" = missing ]; then
      assert_fails grep -qx bin/named "$RUN_DIR/files"
      assert_fails grep -q bin/named "$RUN_DIR/produced"
      assert grep -qx bin/named "$RUN_DIR/dirty"
      assert grep -qx bin/restored "$RUN_DIR/dirty"
      assert_fails grep -q 'snapshot stands\|another writer' "$RUN_DIR/files-note"
      assert "$RUNNER" claim "$RUN_ID" --paths bin/named bin/restored >/dev/null
      assert grep -qx bin/restored "$RUN_DIR/files"
      assert grep -q bin/restored "$RUN_DIR/produced"
      continue
    elif [ "$variant" = shellonly ]; then
      assert grep -qx base "$repo/bin/restored"
      assert_fails grep -qx bin/named "$RUN_DIR/files"
    else
      assert grep -qx bin/named "$RUN_DIR/files"
      assert grep -q bin/named "$RUN_DIR/produced"
    fi
    assert bash -c '! grep -qx "$1" "$2"' \
      'rule change: restoring a co-tenant path does not establish ownership' bin/restored "$RUN_DIR/files"
    assert_fails grep -q bin/restored "$RUN_DIR/produced"
    if [ "$variant" = namedonly ]; then
      assert grep -q '^PARTIAL: ' "$RUN_DIR/files"
      assert test ! -e "$RUN_DIR/dirty"
      continue
    fi
    if [ "$variant" = readonly ]; then
      note="1 path(s) changed in the checkout during the run by another writer and are not this run's: bin/restored"
      assert_fails grep -q '^PARTIAL: ' "$RUN_DIR/files"
      assert test ! -e "$RUN_DIR/dirty"
    else
      note="1 path(s) changed in the run's window that its own listing does not name and nobody answers for (the run also ran shell commands, whose edits no transcript records): bin/restored"
      assert grep -q '^PARTIAL: ' "$RUN_DIR/files"
      assert grep -qx bin/restored "$RUN_DIR/dirty"
      assert_fails grep -qx bin/named "$RUN_DIR/dirty"
      assert_fails grep -q 'another writer' "$RUN_DIR/files-note"
    fi
    assert grep -qxF "$note" "$RUN_DIR/files-note"
    report=$("$RUNNER" report "$RUN_ID")
    assert grep -qxF "RUN-FILES-NOTE: $note" <<<"$report"
    if [ "$variant" != readonly ]; then
      assert grep -q "^UNNAMED: .*worker-run claim $RUN_ID" <<<"$report"
      assert "$RUNNER" claim "$RUN_ID" --paths bin/restored >/dev/null
      assert grep -qx bin/restored "$RUN_DIR/files"
      assert grep -q bin/restored "$RUN_DIR/produced"
    fi
  done
  for variant in outside outside_dotdot outside_only; do
    [ -z "${WORKER_RUN_TEST_ATTRIBUTION_CASE:-}" ] || [ "$variant" = "$WORKER_RUN_TEST_ATTRIBUTION_CASE" ] || continue
    git -C "$outside" init -q
    printf 'before\n' >"$outside/edited"
    git -C "$outside" add edited
    git -C "$outside" -c user.name=fixture -c user.email=fixture@example.test commit -qm base
    TOOL_TS=$(iso $(($(date +%s) + 60)))
    {
      [ "$variant" = outside_only ] || tool_call Edit file_path "$repo/bin/named"
      if [ "$variant" = outside_dotdot ]; then
        tool_call Edit file_path "$repo/../outside-repair/edited"
      else
        tool_call Edit file_path "$outside/edited"
      fi
      tool_call Edit file_path "$repo/../outside-repair/second"
    } >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
    start_gated claudeb --workdir "$repo"
    [ "$variant" = outside_only ] || printf 'inside %s\n' "$variant" >"$repo/bin/named"
    printf 'after\n' >"$outside/edited"
    printf 'after\n' >"$outside/second"
    printf 'co-tenant\n' >"$repo/bin/outside-cotenant"
    gate_open
    assert await_done
    if [ "$variant" = outside_only ]; then
      assert_fails grep -qx bin/named "$RUN_DIR/files"
      assert test ! -s "$RUN_DIR/produced"
    else
      assert grep -qx bin/named "$RUN_DIR/files"
      assert grep -q bin/named "$RUN_DIR/produced"
    fi
    note="UNKNOWN: transcript names a write outside the snapshotted repository; no content baseline was recorded: $outside/edited"
    assert grep -qxF "$note" "$RUN_DIR/files-note"
    assert grep -qxF "RUN-FILES-NOTE: $note" <<<"$("$RUNNER" report "$RUN_ID")"
    note="UNKNOWN: transcript names a write outside the snapshotted repository; no content baseline was recorded: $outside/second"
    assert grep -qxF "$note" "$RUN_DIR/files-note"
    assert grep -qxF "RUN-FILES-NOTE: $note" <<<"$("$RUNNER" report "$RUN_ID")"
    assert grep -q '^PARTIAL: .*outside the snapshotted repository' "$RUN_DIR/files"
    assert_fails grep -q '^UNKNOWN: ' "$RUN_DIR/files"
    assert_fails grep -q "$outside/edited" "$RUN_DIR/produced"
    assert test ! -e "$RUN_DIR/dirty"
    assert_fails grep -q bin/outside-cotenant "$RUN_DIR/produced"
  done
}

anchors_store_tests
attribution_repair_tests

echo "PASS: $asserts asserts; the review-anchors store and attribution repair"
