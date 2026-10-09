#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/worker_run_harness.sh" || exit 1

# The pool is a wall, not advice to the picker: a brief naming an excluded account cannot get in,
# and only the vendor pin overrides.
for vendor in claudeb codex gemini; do
  clear_stub
  set_config 'codex_effort=medium'
  export PICK_ACCOUNT=picked PICK_RC=0
  printf 'explicit\npicked\n' >"$STUB_DIR/gemini_profiles"
  pool_dir=$(pool_dir_for "$vendor")
  mkdir -p "$pool_dir"
  printf 'explicit\n' >"$pool_dir/disabled"
  rc=0
  "$RUNNER" start "$vendor" --brief "$WORK/brief" --account explicit \
    >"$WORK/pool-wall.out" 2>"$WORK/pool-wall.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -qx "OUTCOME: $(tr '[:lower:]' '[:upper:]' <<<"$vendor")_UNAVAILABLE" "$WORK/pool-wall.out"
  assert grep -q 'explicit is out of the worker pool' "$WORK/pool-wall.err"
  assert test ! -s "$CALL_LOG"
  assert test ! -e "$HOME/.cache/worker-claims/$vendor/explicit"
  set_config "${vendor}_profile=explicit" 'codex_effort=medium'
  start_ok "$vendor" --account explicit
  assert meta_account_is explicit
  assert test -e "$HOME/.cache/worker-claims/$vendor/explicit"
  assert await_done
  rm -f "$pool_dir/disabled"
done

clear_stub
set_config 'codex_effort=medium'
export PICK_RC=2
rc=0
"$RUNNER" start claudeb --brief "$WORK/brief" >"$WORK/no-pin.out" 2>"$WORK/no-pin.err" || rc=$?
assert test "$rc" -eq 4
assert grep -q 'needs an explicit account' "$WORK/no-pin.err"

clear_stub
set_config 'gemini_model=flash38' 'gemini_effort=high'
export PICK_RC=2
start_ok gemini --account main
assert meta_agy_is 'gemini-3.8-flash-high'
assert await_done
# Every Gemini leg runs high: an effort below it is RAISED with one note on stderr, never refused,
# and an effort above it is the same word for the same tier.
for forced in low medium xhigh max; do
  clear_stub
  start_ok gemini --account main --model flash38 --effort "$forced"
  assert meta_agy_is 'gemini-3.8-flash-high'
  assert grep -qx 'gemini effort forced to high' "$WORK/start.err"
  assert await_done
done
# The knob is raised the same way the flag is.
clear_stub
set_config 'gemini_model=flash38' 'gemini_effort=low'
start_ok gemini --account main
assert meta_agy_is 'gemini-3.8-flash-high'
assert await_done
set_config 'gemini_model=flash38' 'gemini_effort=high'
# The other families and Pro, each at the one effort they run.
for pair in 'flash37:gemini-3.7-flash-high' 'flash36:gemini-3.6-flash-high' 'pro:gemini-3.1-pro-high'; do
  clear_stub
  start_ok gemini --account main --model "${pair%%:*}"
  assert meta_agy_is "${pair#*:}"
  assert await_done
done
# No model named anywhere: the newest Flash family is the default, never `pro` however new it is.
clear_stub
set_config 'gemini_effort=high'
assert test "$(bash -c '. "$1"; worker_model_default_model gemini' _ "$ROOT/share/worker-model.sh")" = flash38
start_ok gemini --account main
assert meta_agy_is 'gemini-3.8-flash-high'
assert await_done
set_config 'gemini_model=flash38' 'gemini_effort=high'
# A word the table knows nothing of is a typo, and a typo is still refused rather than raised.
for bad_effort in ultra tiny; do
  clear_stub
  rc=0
  "$RUNNER" start gemini --brief "$WORK/brief" --account main --model flash38 --effort "$bad_effort" >"$WORK/reject.out" 2>&1 || rc=$?
  assert test "$rc" -eq 4
  assert grep -qx 'OUTCOME: EFFORT_REFUSED' "$WORK/reject.out"
  assert test ! -s "$CALL_LOG"
done
printf 'known\n' >"$STUB_DIR/gemini_profiles"
rc=0
"$RUNNER" start gemini --brief "$WORK/brief" --account unknown >"$WORK/unknown.out" 2>&1 || rc=$?
assert test "$rc" -eq 4
assert grep -qx 'OUTCOME: GEMINI_UNAVAILABLE' "$WORK/unknown.out"

clear_stub
set_config 'claudeb_model=opus' 'claudeb_effort=high'
export PICK_RC=0 PICK_ACCOUNT=resumeacct

# Resume without an explicit account must refuse: worker-pick may route to a
# profile that does not hold the session being resumed.
rc=0
"$RUNNER" start claudeb --brief "$WORK/brief" --resume claude-resume >"$WORK/resume-noacct.out" 2>&1 || rc=$?
assert test "$rc" -eq 4
assert grep -q -- '--resume requires --account' "$WORK/resume-noacct.out"

start_ok claudeb --account resumeacct --resume claude-resume
assert await_done
assert grep -q '^ARG=--resume$' "$CALL_LOG"
assert grep -q '^ARG=claude-resume$' "$CALL_LOG"
assert test "$(tail -n1 "$CALL_LOG")" = 'ARG=claude-resume'

mkdir -p "$CLAUDEB_PROFILES_ROOT/resumeacct/projects/fixture"
claude_transcript="$CLAUDEB_PROFILES_ROOT/resumeacct/projects/fixture/claude-cold.jsonl"
printf '%s\n' '{"message":{"usage":{"input_tokens":1}}}' '{"message":{"usage":{"input_tokens":2,"cache_read_input_tokens":150000,"cache_creation_input_tokens":500}}}' >"$claude_transcript"
touch -t 202001010000 "$claude_transcript"
clear_stub
start_ok claudeb --account resumeacct --resume claude-cold
assert grep -q 'RESUME-COLD: claudeb' "$WORK/start.err"
assert grep -q 'context ~151k tokens' "$WORK/start.err"
assert await_done

touch "$claude_transcript"
clear_stub
start_ok claudeb --account resumeacct --resume claude-cold
assert test "$(grep -c 'RESUME-COLD:' "$WORK/start.err")" -eq 0
assert await_done

clear_stub
start_ok claudeb --account resumeacct --resume claude-missing
assert test "$(grep -c 'RESUME-COLD:' "$WORK/start.err")" -eq 0
assert await_done

clear_stub
set_config 'codex_effort=high'
start_ok codex --account resumeacct --resume codex-resume
assert await_done
assert grep -q '^CODEX_HOME=.*/\.codex-profiles/resumeacct$' "$CALL_LOG"
assert grep -q '^ARG=resume$' "$CALL_LOG"
assert grep -q '^ARG=codex-resume$' "$CALL_LOG"
assert test "$(grep -c '^ARG=-m$' "$CALL_LOG")" -eq 0
assert test "$(grep -c '^ARG=--color$' "$CALL_LOG")" -eq 0

mkdir -p "$CODEX_PROFILES_DIR/resumeacct/sessions/fixture"
codex_transcript="$CODEX_PROFILES_DIR/resumeacct/sessions/fixture/rollout-codex-cold.jsonl"
printf '%04000d\n' 0 >"$codex_transcript"
touch -t 202001010000 "$codex_transcript"
clear_stub
start_ok codex --account resumeacct --resume codex-cold
assert grep -q 'RESUME-COLD: codex' "$WORK/start.err"
assert grep -q 'cache TTL ~30m expired' "$WORK/start.err"
assert await_done

touch "$codex_transcript"
clear_stub
start_ok codex --account resumeacct --resume codex-cold
assert test "$(grep -c 'RESUME-COLD:' "$WORK/start.err")" -eq 0
# A resume with no explicit model keeps the session's own: the config default must not travel.
assert test "$(grep -c '^ARG=-m$' "$CALL_LOG")" -eq 0
assert await_done

# Explicit --model/--effort override a resumed session; config defaults never do.
clear_stub
set_config 'codex_effort=high'
start_ok codex --account resumeacct --resume codex-resume --model astra --effort low
assert grep -qx 'TAG: resumeacct · astra · low' "$WORK/start.out"
assert await_done
assert grep -q '^ARG=resume$' "$CALL_LOG"
assert grep -q '^ARG=-m$' "$CALL_LOG"
assert grep -q '^ARG=gpt-6.1-astra$' "$CALL_LOG"
assert grep -q '^ARG=model_reasoning_effort=low$' "$CALL_LOG"

# Fast Mode is per account and has to reach the worker launch, not only the menu: codexb writes
# the marker, and every codex command line is the only place a tier can still be applied.
clear_stub
mkdir -p "$HOME/.codex-profiles/.codexb/fast-mode"
printf 'fast\n' >"$HOME/.codex-profiles/.codexb/fast-mode/fastacct"
start_ok codex --account fastacct
assert await_done
assert grep -qxF 'ARG=--enable' "$CALL_LOG"
assert grep -qxF 'ARG=fast_mode' "$CALL_LOG"
assert grep -qxF 'ARG=service_tier=\"priority\"' "$CALL_LOG"

# OpenAI switches Fast per account and model in the catalog: switched on here but not listed there,
# the run goes standard and says so; listed again, it is Fast again with nobody touching the switch.
clear_stub
mkdir -p "$CODEX_PROFILES_DIR/fastacct"
jq '.models |= map(del(.service_tiers))' "$CODEXB_MODELS_CACHE" >"$CODEX_PROFILES_DIR/fastacct/models_cache.json"
start_ok codex --account fastacct
assert await_done
assert test "$(grep -c '^ARG=service_tier=' "$CALL_LOG")" -eq 1
assert grep -qxF 'ARG=service_tier=\"default\"' "$CALL_LOG"
assert grep -q 'OpenAI offers no Fast for gpt-6.1-astra on fastacct' "$WORK/start.err"
clear_stub
jq '.models |= map(.service_tiers = [{"id": "priority", "name": "Fast"}])' "$CODEXB_MODELS_CACHE" \
  >"$CODEX_PROFILES_DIR/fastacct/models_cache.json"
start_ok codex --account fastacct
assert await_done
assert grep -qxF 'ARG=service_tier=\"priority\"' "$CALL_LOG"
assert_fails grep -q 'offers no Fast' "$WORK/start.err"
rm -r "$CODEX_PROFILES_DIR/fastacct"

clear_stub
printf 'default\n' >"$HOME/.codex-profiles/.codexb/fast-mode/fastacct"
start_ok codex --account fastacct
assert await_done
assert grep -qxF 'ARG=service_tier=\"default\"' "$CALL_LOG"

clear_stub
printf 'garbage\n' >"$HOME/.codex-profiles/.codexb/fast-mode/fastacct"
start_ok codex --account fastacct
assert await_done
assert test "$(grep -c '^ARG=service_tier=' "$CALL_LOG")" -eq 1
assert grep -qxF 'ARG=service_tier=\"default\"' "$CALL_LOG"

clear_stub
start_ok codex --account resumeacct
assert await_done
assert test "$(grep -c '^ARG=service_tier=' "$CALL_LOG")" -eq 1
assert grep -qxF 'ARG=service_tier=\"default\"' "$CALL_LOG"

# `chat-pin codex-fast` outranks the account's standing switch for the runs of this chat alone, and
# travels to the detached supervisor in meta.json.
clear_stub
mkdir -p "$CHAT_PINS_DIR"
printf 'codex_profile=*\ncodex_fast=on\n' >"$CHAT_PINS_DIR/chat-codex-fast"
CLAUDE_CODE_SESSION_ID=chat-codex-fast start_ok codex --account resumeacct
assert test "$(jq -r '.fast' "$RUN_DIR/meta.json")" = true
assert await_done
assert grep -qxF 'ARG=--enable' "$CALL_LOG"
assert grep -qxF 'ARG=fast_mode' "$CALL_LOG"
assert grep -qxF 'ARG=service_tier=\"priority\"' "$CALL_LOG"
assert test "$(grep -c '^ARG=service_tier=' "$CALL_LOG")" -eq 1
rm -f "$CHAT_PINS_DIR/chat-codex-fast"
rm -r "$HOME/.codex-profiles/.codexb/fast-mode"

# codex resume cannot carry --add-dir; refuse before launching anything.
clear_stub
rc=0
"$RUNNER" start codex --brief "$WORK/brief" --workdir "$WORK/workdir" --account resumeacct --resume codex-resume --add-dir "$WORK/extra" >"$WORK/start.out" 2>"$WORK/start.err" || rc=$?
assert test "$rc" -eq 4
assert grep -q 'codex resume does not support --add-dir' "$WORK/start.err"
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 0

clear_stub
printf 'resumeacct\n' >"$STUB_DIR/gemini_profiles"
gemini_transcript="$CLAUDEB_PROFILES_ROOT/resumeacct/projects/fixture/gemini-resume.jsonl"
printf '{}\n' >"$gemini_transcript"
touch -t 202001010000 "$gemini_transcript"
start_ok gemini --account resumeacct --resume gemini-resume
assert test "$(grep -c 'RESUME-COLD:' "$WORK/start.err")" -eq 0
assert await_done
assert grep -qxF "ARG=$HOME/.claude" "$CALL_LOG"
assert grep -q '^ARG=--conversation$' "$CALL_LOG"
assert grep -q '^ARG=gemini-resume$' "$CALL_LOG"
assert test "$(tail -n2 "$CALL_LOG" | head -n1)" = 'ARG=--print'
assert grep -q "^ARG=\$'test brief" <<<"$(tail -n1 "$CALL_LOG")"
assert grep -qF 'TEST LOOP: while iterating run a one-off probe' <<<"$(tail -n1 "$CALL_LOG")"
assert grep -qF 'ended by signal 9 (exit 137) was killed by the machine' <<<"$(tail -n1 "$CALL_LOG")"
assert cmp -s "$WORK/brief" "$RUN_DIR/brief"

clear_stub
set_config 'codex_effort=high'
start_ok codex --account options --add-dir "$WORK/extra" --image "$WORK/image.png" --web-search
assert await_done
assert grep -q '^ARG=--add-dir$' "$CALL_LOG"
assert grep -q '^ARG=-i$' "$CALL_LOG"
assert grep -q '^ARG=web_search=live$' "$CALL_LOG"
assert_launched_brief "$STUB_DIR/codex.stdin"

# Relative --image/--add-dir are pinned to the caller's cwd: the detached
# supervisor cds to workdir before the CLI resolves them.
clear_stub
set_config 'codex_effort=high'
printf 'img\n' >"$WORK/rel-image.png"
mkdir -p "$WORK/rel-extra"
(cd "$WORK" && "$RUNNER" start codex --brief "$WORK/brief" --workdir "$WORK/workdir" --account options --add-dir rel-extra --image rel-image.png) >"$WORK/start.out" 2>"$WORK/start.err" || fail "relative-path start failed: $(<"$WORK/start.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/start.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/start.out")
assert await_done
assert grep -qxF "ARG=$WORK/rel-extra" "$CALL_LOG"
assert grep -qxF "ARG=$WORK/rel-image.png" "$CALL_LOG"

# Absolute image paths a codex brief names ride as -i once each; a missing file, a URL or a path
# inside a relative one never does.
cp "$WORK/brief" "$WORK/brief.noimg"
printf 'img\n' >"$WORK/shot.PNG"
printf 'img\n' >"$WORK/old.png"
{ cat "$WORK/brief.noimg"; printf 'See %s and (%s), not %s/gone.png, https://x.io%s, docs%s.\n' \
  "$WORK/shot.PNG" "$WORK/rel-image.png" "$WORK" "$WORK/shot.PNG" "$WORK/shot.PNG"
  printf 'Nor %s.bak, %s/new.gif2 or %s/new.pngs.\n' "$WORK/old.png" "$WORK" "$WORK"; } >"$WORK/brief"
clear_stub
set_config 'codex_effort=high'
(cd "$WORK" && "$RUNNER" start codex --brief "$WORK/brief" --workdir "$WORK/workdir" --account options --image rel-image.png) >"$WORK/start.out" 2>"$WORK/start.err" || fail "brief-image start failed: $(<"$WORK/start.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/start.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/start.out")
assert await_done
assert test "$(grep -cxF "ARG=$WORK/shot.PNG" "$CALL_LOG")" = 1
assert test "$(grep -cxF "ARG=$WORK/rel-image.png" "$CALL_LOG")" = 1
assert test "$(grep -cx 'ARG=-i' "$CALL_LOG")" = 2
assert grep -qxF "IMAGE-MISSING: $WORK/gone.png — the brief names it, it is not readable, the worker will not see it" "$WORK/start.out"
assert test "$(grep -c '^IMAGE-MISSING:' "$WORK/start.out")" = 1
assert grep -qxF "NEXT: worker-run wait $RUN_ID as a background Bash; a mid-run note: worker-run say $RUN_ID \"<text>\"" "$WORK/start.out"
cp "$WORK/brief.noimg" "$WORK/brief"

# A cross-repository brief grants its second repository in the header (the eight escaped legs of
# 2026-09-29 named it only in prose); an ADD-DIR: past the first body line is prose, never a grant.
cp "$WORK/brief" "$WORK/brief.plain"
mkdir -p "$WORK/header-extra" "$WORK/prose-extra"
{ printf 'ACCOUNT: options\nADD-DIR:  %s \nEFFORT: high\n\n' "$WORK/header-extra"
  printf 'ADD-DIR: %s\n' "$WORK/prose-extra"; cat "$WORK/brief.plain"; } >"$WORK/brief"
clear_stub
set_config 'codex_effort=high'
start_ok codex
assert await_done
assert grep -qxF "ARG=$WORK/header-extra" "$CALL_LOG"
assert test "$(jq -c '.add_dirs' "$RUN_DIR/meta.json")" = "$(jq -cn --arg d "$WORK/header-extra" '[$d]')"
printf 'ACCOUNT: options\nADD-DIR: rel-extra\n\n' >"$WORK/brief"
clear_stub
rc=0
"$RUNNER" start codex --brief "$WORK/brief" --workdir "$WORK/workdir" >"$WORK/start.out" 2>"$WORK/start.err" || rc=$?
assert test "$rc" -ne 0
assert grep -qF "'ADD-DIR: rel-extra' names no absolute directory" "$WORK/start.err"
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 0
cp "$WORK/brief.plain" "$WORK/brief"

# The 2026-10-01 escapes: hand-written briefs named another repository's task worktree only in prose,
# and a RESUME of a granted session repeated no grant. A main checkout named in prose, or a worktree
# that does not exist, is still granted nothing.
other="$WORK/other-repo"
mkdir -p "$other/.claude/worktrees/task-wt" "$WORK/inherited"
printf 'gitdir: x\n' >"$other/.claude/worktrees/task-wt/.git"
mkdir -p "$other/.git"
{ printf 'ACCOUNT: options\n\nWork in worktree %s/.claude/worktrees/task-wt. Read %s and %s/.claude/worktrees/gone.\n' \
    "$other" "$other" "$other"; cat "$WORK/brief.plain"; } >"$WORK/brief"
clear_stub
set_config 'codex_effort=high'
start_ok codex
assert await_done
assert test "$(jq -c '.add_dirs' "$RUN_DIR/meta.json")" = "$(jq -cn --arg d "$(cd "$other/.claude/worktrees/task-wt" && pwd -P)" '[$d]')"
# The 2026-10-03 escape: the brief handed over to a brief file, which listed the repository and named
# the existing worktree only as `<repo>/.claude/worktrees/<name>`.
mkdir -p "$WORK/nested"
printf 'Repos:\n- %s\n\nReuse `<repo>/.claude/worktrees/task-wt`, not <repo>/.claude/worktrees/gone.\n' "$other" >"$WORK/nested/brief.md"
{ printf 'ACCOUNT: options\n\nRead and follow exactly the brief at %s/nested/brief.md — in BOTH repos.\n' "$WORK"; cat "$WORK/brief.plain"; } >"$WORK/brief"
clear_stub
start_ok codex
assert await_done
assert test "$(jq -c '.add_dirs' "$RUN_DIR/meta.json")" = "$(jq -cn --arg d "$(cd "$other/.claude/worktrees/task-wt" && pwd -P)" '[$d]')"
# Granted once whichever spelling names it; the roots are read once per brief and the granted set
# resolved once per launch, not again per worktree name and per candidate.
ln -s "$other" "$WORK/other-link"
mkdir -p "$WORK/grep-shim"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s"\nexec %s "$@"\n' "$WORK/grep.log" "$(command -v grep)" >"$WORK/grep-shim/grep"
chmod +x "$WORK/grep-shim/grep"
{ printf 'ACCOUNT: options\nADD-DIR: %s/.claude/worktrees/task-wt\n\nWork in %s/.claude/worktrees/task-wt, alias repo/.claude/worktrees/task-wt, not repo/.claude/worktrees/gone. Read %s.\n' \
    "$WORK/other-link" "$other" "$other"; cat "$WORK/brief.plain"; } >"$WORK/brief"
clear_stub
: >"$WORK/grep.log"
PATH="$WORK/grep-shim:$PATH" start_ok codex
assert await_done
assert test "$(jq -c '.add_dirs' "$RUN_DIR/meta.json")" = "$(jq -cn --arg d "$WORK/other-link/.claude/worktrees/task-wt" '[$d]')"
assert test "$(grep -cxF -- "-qxF -- $(cd "$other/.claude/worktrees/task-wt" && pwd -P)" "$WORK/grep.log")" -eq 0
assert test "$(grep -cxF -- "-oE /[A-Za-z0-9._~+-][A-Za-z0-9._~+/-]*" "$WORK/grep.log")" -eq 1
mkdir -p "$WORKER_RUN_DIR/prior-granted"
printf 'claude-granted\n' >"$WORKER_RUN_DIR/prior-granted/worker-session"
jq -n --arg d "$(cd "$WORK/inherited" && pwd -P)" '{add_dirs: [$d]}' >"$WORKER_RUN_DIR/prior-granted/meta.json"
cp "$WORK/brief.plain" "$WORK/brief"
clear_stub
set_config 'claudeb_model=opus' 'claudeb_effort=high'
start_ok claudeb --account resumeacct --resume claude-granted
assert await_done
assert test "$(jq -c '.add_dirs' "$RUN_DIR/meta.json")" = "$(jq -cn --arg d "$(cd "$WORK/inherited" && pwd -P)" '[$d]')"
assert grep -qxF "ARG=$(cd "$WORK/inherited" && pwd -P)" "$CALL_LOG"
rm -rf "$WORKER_RUN_DIR/prior-granted"

# The W5 escapes of 2026-10-02: a relay dropped --resume for a 'RESUME <sid>:' brief and launched it
# fresh in the chat's home directory, away from the repository the session had worked in.
session_repo="$WORK/session-repo"
git init -q "$session_repo"
mkdir -p "$WORKER_RUN_DIR/prior-workdir" "$WORK/scratch-workdir"
printf 'claude-moved\n' >"$WORKER_RUN_DIR/prior-workdir/worker-session"
jq -n --arg d "$session_repo" '{workdir: $d, add_dirs: []}' >"$WORKER_RUN_DIR/prior-workdir/meta.json"
{ printf 'RESUME claude-moved:\nACCOUNT: resumeacct\n\n'; cat "$WORK/brief.plain"; } >"$WORK/brief"
clear_stub
start_ok claudeb
assert await_done
assert test "$(jq -r '.resume' "$RUN_DIR/meta.json")" = claude-moved
assert grep -q '^ARG=claude-moved$' "$CALL_LOG"
assert test "$(jq -c '.add_dirs' "$RUN_DIR/meta.json")" = "$(jq -cn --arg d "$(cd "$session_repo" && pwd -P)" '[$d]')"
cp "$WORK/brief.plain" "$WORK/brief"
printf 'claude-scratch\n' >"$WORKER_RUN_DIR/prior-workdir/worker-session"
jq -n --arg d "$WORK/scratch-workdir" '{workdir: $d, add_dirs: []}' >"$WORKER_RUN_DIR/prior-workdir/meta.json"
clear_stub
start_ok claudeb --account resumeacct --resume claude-scratch
assert await_done
assert test "$(jq -c '.add_dirs' "$RUN_DIR/meta.json")" = '[]'
{ printf 'RESUME claude-moved:\nACCOUNT: resumeacct\n\n'; cat "$WORK/brief.plain"; } >"$WORK/brief"
clear_stub
rc=0
"$RUNNER" start claudeb --brief "$WORK/brief" --workdir "$WORK/workdir" --resume claude-other >"$WORK/start.out" 2>"$WORK/start.err" || rc=$?
assert test "$rc" -eq 4
assert grep -qF "contradicts the brief's first line 'RESUME claude-moved:'" "$WORK/start.err"
rm -rf "$WORKER_RUN_DIR/prior-workdir"
cp "$WORK/brief.plain" "$WORK/brief"
clear_stub
rc=0
"$RUNNER" start claudeb --brief "$WORK/brief" --workdir "$HOME" --account resumeacct >"$WORK/start.out" 2>"$WORK/start.err" || rc=$?
assert test "$rc" -eq 4
assert grep -qF 'workdir is the home directory' "$WORK/start.err"
assert_fails grep -q "^ARG=" "$CALL_LOG"

# W6, 2026-10-04: starts interrupted while hashing a large dirty tree left runs with no supervisor.
# A floor that never finishes must not hold start: the detached supervisor takes it.
real_git=$(command -v git)
cat >"$WORK/bin/git" <<GIT
#!/usr/bin/env bash
case " \$* " in *' status --porcelain --no-renames -uall '*)
  printf 'GIT_STATUS\n' >>"\$CALL_LOG"
  while [ -e "$WORK/floor-hold" ]; do sleep 0.05; done ;;
esac
exec "$real_git" "\$@"
GIT
chmod +x "$WORK/bin/git"
git init -q "$WORK/floor-repo"
printf 'before\n' >"$WORK/floor-repo/dirty"
: >"$WORK/floor-hold"
clear_stub
rc=0
perl -e 'alarm 20; exec @ARGV' "$RUNNER" start claudeb --brief "$WORK/brief" --workdir "$WORK/floor-repo" \
  --account resumeacct >"$WORK/start.out" 2>"$WORK/start.err" || rc=$?
assert test "$rc" -eq 0
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/start.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/start.out")
assert test "$(jq -r '.pid' "$RUN_DIR/meta.json")" != 0
assert test ! -e "$RUN_DIR/dirty-before"
rm -f "$WORK/floor-hold"
assert await_done
assert grep -qx dirty "$RUN_DIR/dirty-before"
# One status walk gives the floor both its path list and its blobs.
assert test "$(awk '/^CLAUDEB_CALL$/ { exit } /^GIT_STATUS$/ { n++ } END { print n + 0 }' "$CALL_LOG")" = 1
assert test "$(cut -f2 "$RUN_DIR/dirty-before-shas")" = "$(cat "$RUN_DIR/dirty-before")"
rm -f "$WORK/bin/git"

# These picks keep naming the one account that walls — a picker that ignores
# --exclude — so the run has nowhere to reroute and the limit outcome reaches
# the caller.
# Codex's "out of credits" is the same wall in other words: the plan's window is spent and it
# offers paid credits to continue — the account is back at the reset, not broken.
for spec in 'claudeb:usage limit reached:CLAUDEB_USAGE_LIMIT' 'codex:quota exhausted:CODEX_USAGE_LIMIT' 'codex:Your workspace is out of credits:CODEX_USAGE_LIMIT' 'gemini:RESOURCE_EXHAUSTED:GEMINI_USAGE_LIMIT' 'gemini:Your AI credits balance is too low to continue.:GEMINI_USAGE_LIMIT'; do
  IFS=: read -r vendor error outcome <<<"$spec"
  clear_stub
  set_config 'claudeb_model=opus' 'claudeb_effort=high' 'codex_effort=medium' 'gemini_model=flash38' 'gemini_effort=high'
  export PICK_RC=0 PICK_ACCOUNT=limitacct STUB_CODE=9 STUB_ERROR="$error"
  printf 'limitacct\n' >"$STUB_DIR/gemini_profiles"
  start_ok "$vendor"
  assert await_done
  assert grep -q '^STATUS: failed$' "$WORK/wait.out"
  assert grep -qx "OUTCOME: $outcome" "$WORK/wait.out"
  assert grep -qx 'WALL: pool exhausted (walled: limitacct)' "$WORK/wait.out"
done

clear_stub
set_config 'codex_effort=medium'
export PICK_RC=0 PICK_ACCOUNT=limitacct STUB_CODE=9
export STUB_ERROR='ERROR: unexpected status 402 Payment Required: Payment Required, url: https://chatgpt.com/backend-api/codex/responses, cf-ray: a34f7001de413244-VIE, auth error: 402, auth error code: deactivated_workspace'
start_ok codex
assert await_done
assert grep -qx 'OUTCOME: CODEX_USAGE_LIMIT' "$WORK/wait.out"

clear_stub
set_config 'claudeb_model=opus' 'claudeb_effort=high'
export PICK_RC=0 PICK_ACCOUNT=limitacct STUB_CODE=9
export STUB_STDOUT="{\"result\":\"You've hit your session limit · resets 10:40pm (Europe/Kiev)\",\"is_error\":true}"
start_ok claudeb
assert await_done
assert grep -qx 'OUTCOME: CLAUDEB_USAGE_LIMIT' "$WORK/wait.out"

clear_stub
export PICK_RC=0 PICK_ACCOUNT=ordinary STUB_CODE=9
export STUB_STDOUT='{"result":"ordinary failure","is_error":true}'
start_ok claudeb
assert await_done
assert grep -qx 'OUTCOME: CLAUDEB_FAILED' "$WORK/wait.out"

clear_stub
export PICK_RC=0 PICK_ACCOUNT=servedacct
export STUB_MODEL_USAGE='{"claude-haiku-4-5-20251001":{"outputTokens":500},"claude-opus-4-8":{"outputTokens":43}}'
start_ok claudeb
assert await_done
assert test "$(jq -r '.served_model' "$RUN_DIR/meta.json")" = claude-opus-4-8

# Codex: the rollout's last turn_context model, or the server's reroute after it.
clear_stub
export PICK_RC=0 PICK_ACCOUNT=servedcodex
printf '%s\n' '{"type":"session_meta","payload":{}}' '{"type":"turn_context","payload":{"model":"gpt-6.1-astra"}}' \
  '{"type":"event_msg","payload":{"type":"model_reroute","from_model":"gpt-6.1-astra","to_model":"gpt-6-astra"}}' \
  >"$STUB_DIR/codex_rollout"
start_ok codex
assert await_done
assert test "$(jq -r '.served_model' "$RUN_DIR/meta.json")" = gpt-6-astra
assert grep -qx 'SERVED: gpt-6-astra' <<<"$("$RUNNER" report "$RUN_ID")"
clear_stub
export PICK_ACCOUNT=servedcodex2
printf '%s\n' '{"type":"turn_context","payload":{"model":"gpt-6.1-astra"}}' >"$STUB_DIR/codex_rollout"
start_ok codex
assert await_done
assert test "$(jq -r '.served_model' "$RUN_DIR/meta.json")" = gpt-6.1-astra
rm -f "$STUB_DIR/codex_rollout"

# Gemini: the last backend override label in agy's log.
clear_stub
export STUB_GEMINI_LABEL='Gemini 3.8 Flash (High)'
start_ok gemini --account main
assert await_done
assert test "$(jq -r '.served_model' "$RUN_DIR/meta.json")" = 'Gemini 3.8 Flash (High)'
assert grep -qx 'SERVED: Gemini 3.8 Flash (High)' <<<"$("$RUNNER" report "$RUN_ID")"

# A family word is resolved again on the account the attempt runs on: its own list, not the
# machine-wide newest one.
clear_stub
saved_models_cache=$CODEXB_MODELS_CACHE
unset CODEXB_MODELS_CACHE
mkdir -p "$HOME/.codex-profiles/ownlist" "$HOME/.codex-profiles/otherlist"
jq '.client_version = "0.156.1" | .fetched_at = "2026-09-23T00:00:00.000000Z"' "$saved_models_cache" \
  >"$HOME/.codex-profiles/ownlist/models_cache.json"
jq '.client_version = "0.156.1" | .fetched_at = "2026-09-24T00:00:00.000000Z" | .models |= map(select(.slug != "gpt-6.1-astra"))' \
  "$saved_models_cache" >"$HOME/.codex-profiles/otherlist/models_cache.json"
export PICK_RC=0 PICK_ACCOUNT=ownlist
start_ok codex --model astra
assert await_done
assert grep -qx 'ARG=gpt-6.1-astra' "$CALL_LOG"
assert test "$(jq -r '.model_id' "$RUN_DIR/meta.json")" = gpt-6.1-astra
rm -r "$HOME/.codex-profiles/ownlist" "$HOME/.codex-profiles/otherlist"
export CODEXB_MODELS_CACHE=$saved_models_cache

# The launch line resolves on the account too, not only the supervisor: Fast is judged on the slug
# the account really runs, and a family only the picked account lists is no refusal.
clear_stub
unset CODEXB_MODELS_CACHE
mkdir -p "$HOME/.codex-profiles/ownlist" "$HOME/.codex-profiles/otherlist" "$HOME/.codex-profiles/.codexb/fast-mode"
jq '.client_version = "0.156.1" | .fetched_at = "2026-09-23T00:00:00.000000Z"
    | .models |= map(if .slug == "gpt-6.1-astra" then .service_tiers = [{"id": "priority", "name": "Fast"}] else . end)' \
  "$saved_models_cache" >"$HOME/.codex-profiles/ownlist/models_cache.json"
jq '.client_version = "0.156.1" | .fetched_at = "2026-09-24T00:00:00.000000Z" | .models |= map(select(.slug != "gpt-6.1-astra"))' \
  "$saved_models_cache" >"$HOME/.codex-profiles/otherlist/models_cache.json"
printf 'fast\n' >"$HOME/.codex-profiles/.codexb/fast-mode/ownlist"
export PICK_RC=0 PICK_ACCOUNT=ownlist
start_ok codex --model astra
assert_fails grep -q 'offers no Fast' "$WORK/start.err"
assert jq -e 'any(.cmd[]; . == "gpt-6.1-astra")' "$RUN_DIR/meta.json"
assert await_done
assert grep -qxF 'ARG=service_tier=\"priority\"' "$CALL_LOG"
clear_stub
jq '.models |= map(select(.slug | test("astra") | not))' "$saved_models_cache" \
  | jq '.client_version = "0.156.1" | .fetched_at = "2026-09-24T00:00:00.000000Z"' >"$HOME/.codex-profiles/otherlist/models_cache.json"
start_ok codex --model astra
assert await_done
assert grep -qx 'ARG=gpt-6.1-astra' "$CALL_LOG"
clear_stub
start_ok codex --model astra --account ownlist
assert await_done
assert grep -qx 'ARG=gpt-6.1-astra' "$CALL_LOG"
rm -r "$HOME/.codex-profiles/ownlist" "$HOME/.codex-profiles/otherlist" "$HOME/.codex-profiles/.codexb/fast-mode/ownlist"
export CODEXB_MODELS_CACHE=$saved_models_cache

# A picked account whose catalog lists no model of the family (a lapsed plan keeps the free models
# only) is passed over, never launched on the machine-wide id; none left is a model refusal.
clear_stub
unset CODEXB_MODELS_CACHE
mkdir -p "$HOME/.codex-profiles/ownlist" "$HOME/.codex-profiles/lapsed"
jq '.client_version = "0.156.1" | .fetched_at = "2026-09-23T00:00:00.000000Z"' "$saved_models_cache" \
  >"$HOME/.codex-profiles/ownlist/models_cache.json"
jq '.models |= map(select(.slug | test("astra") | not))' "$saved_models_cache" \
  | jq '.client_version = "0.156.1" | .fetched_at = "2026-09-24T00:00:00.000000Z"' >"$HOME/.codex-profiles/lapsed/models_cache.json"
export WORKER_CLAIMS_DIR="$WORK/claims" PICK_CLAIMS="$WORK/claims"
printf '%s\n' '0 lapsed' '0 ownlist' >"$STUB_DIR/pick_queue"
start_ok codex --model astra
assert grep -qF 'codex/lapsed lists no model of astra' "$WORK/start.err"
assert grep -q -- '--exclude lapsed$' "$PICK_LOG"
assert meta_account_is ownlist
assert await_done
assert grep -qx 'ARG=gpt-6.1-astra' "$CALL_LOG"
# The claim the picker recorded on the account passed over is released; a claim held before stays.
assert test ! -e "$WORK/claims/codex/lapsed"
assert test -e "$WORK/claims/codex/ownlist"
clear_stub
touch "$WORK/claims/codex/lapsed"
printf '%s\n' '0 lapsed' '0 ownlist' >"$STUB_DIR/pick_queue"
start_ok codex --model astra
assert test -e "$WORK/claims/codex/lapsed"
assert await_done
# A refusal after the pick launches nothing, and the claim the pick took is handed back.
clear_stub
set_config 'codex_workers=off'
rm -f "$WORK/claims/codex/ownlist"
printf '0 ownlist\n' >"$STUB_DIR/pick_queue"
assert_fails "$RUNNER" start codex --brief "$WORK/brief" --workdir "$WORK/workdir" --model astra >/dev/null 2>&1
assert test ! -e "$WORK/claims/codex/ownlist"
set_config 'claudeb_model=opus' 'claudeb_effort=high'
unset PICK_CLAIMS
rm -rf "$WORK/claims"
# A pinned slug is checked against the account's own catalog too, and so is an account whose
# catalog cannot be read: neither launches on the machine-wide list.
clear_stub
printf '%s\n' '0 lapsed' '0 nohome' '0 ownlist' >"$STUB_DIR/pick_queue"
start_ok codex --model gpt-6.1-astra
assert grep -qF 'codex/lapsed lists no model of gpt-6.1-astra' "$WORK/start.err"
assert grep -qF 'codex/nohome lists no model of gpt-6.1-astra' "$WORK/start.err"
assert meta_account_is ownlist
assert await_done
clear_stub
printf '%s\n' '0 lapsed' '3' >"$STUB_DIR/pick_queue"
unlisted_rc=0
"$RUNNER" start codex --brief "$WORK/brief" --workdir "${WORKER_TEST_WORKDIR:-$WORK/workdir}" --model astra \
  >"$WORK/start.out" 2>"$WORK/start.err" || unlisted_rc=$?
assert test "$unlisted_rc" -eq 4
assert grep -qx 'OUTCOME: MODEL_REFUSED' "$WORK/start.out"
assert grep -qF 'passed over lapsed' "$WORK/start.err"
assert test ! -s "$CALL_LOG"
# Walled accounts behind the one passed over are a usage limit to wait out, never a missing model.
clear_stub
printf '%s\n' '0 lapsed' '3' >"$STUB_DIR/pick_queue"
unlisted_rc=0
PICK_STDERR='worker-pick: no selectable codex account (ownlist 100% 5h 100% WALLED)' \
  "$RUNNER" start codex --brief "$WORK/brief" --workdir "${WORKER_TEST_WORKDIR:-$WORK/workdir}" --model astra \
  >"$WORK/start.out" 2>"$WORK/start.err" || unlisted_rc=$?
assert test "$unlisted_rc" -eq 3
assert grep -qx 'OUTCOME: CODEX_USAGE_LIMIT' "$WORK/start.out"
assert_fails grep -q 'MODEL_REFUSED' "$WORK/start.out"
assert test ! -s "$CALL_LOG"
unset WORKER_CLAIMS_DIR
rm -f "$STUB_DIR/pick_queue"
rm -r "$HOME/.codex-profiles/ownlist" "$HOME/.codex-profiles/lapsed"
export CODEXB_MODELS_CACHE=$saved_models_cache


echo "PASS: $asserts asserts; the worker pool wall, agy models, resume, limit outcomes, model lists and claims"
