#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/worker_run_harness.sh"

# --- grok ----------------------------------------------------------------------------------------
# The brief rides a FILE (1.0.13 takes no prompt on argv), memory is off by env because the flag
# that did it is gone, and web search is off unless the brief asks: a worker inheriting the
# profile's memory carries another task's notes into this one.
clear_stub
set_config 'grok_model=auto' 'grok_effort=high'
export PICK_RC=0 PICK_ACCOUNT=grokacct
grok_workdir=$(cd "$WORK/workdir" && pwd -P)
start_ok grok
assert grep -qx 'TAG: grokacct · grok · high' "$WORK/start.out"
assert grep -qx 'grokacct · grok · high' "$RUN_DIR/tag"
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"
assert grep -qx 'SESSION: 01a05811-7788-7d22-a9c9-c028072cbff5' "$WORK/wait.out"
assert meta_account_is grokacct
assert test "$(jq -r '.served_model' "$RUN_DIR/meta.json")" = grok-4.7-build
# No turn cap by default: the wall-clock deadline is the runaway guard here as it is for claudeb,
# codex and gemini, and a cap borrowed from short reviewer cells ends an implementation brief the
# vendor was still serving.
assert test "$(jq -r 'has("max_turns")' "$RUN_DIR/meta.json")" = false
assert test "$(grep -c '^ARG=--max-turns$' "$CALL_LOG")" -eq 0
assert grep -qx 'GROK_MEMORY=0' "$CALL_LOG"
assert grep -qx 'ARG=--prompt-file' "$CALL_LOG"
assert grep -qxF "ARG=$RUN_DIR/brief.launch" "$CALL_LOG"
assert_launched_brief "$RUN_DIR/brief.launch"
assert grep -qx 'ARG=streaming-json' "$CALL_LOG"
assert grep -qx 'ARG=--always-approve' "$CALL_LOG"
assert grep -qx 'ARG=--no-subagents' "$CALL_LOG"
assert grep -qx 'ARG=--disable-web-search' "$CALL_LOG"
assert grep -qxF "ARG=$grok_workdir" "$CALL_LOG"
# `auto` means "whatever the account defaults to": a resolved id here pins a model nobody named.
assert test "$(grep -c '^ARG=-m$' "$CALL_LOG")" -eq 0
# The answer arrives as `text` chunks; the raw NDJSON is the one shape a report cannot be read from.
assert grep -qx 'grok result' <<<"$("$RUNNER" report "$RUN_ID")"

clear_stub
# A model that is not the one `grokb models` marks default is its own label; only that default
# and `auto` collapse to the vendor word.
set_config 'grok_model=grok-4.6' 'grok_effort=high'
start_ok grok
assert grep -qx 'TAG: grokacct · grok-4.6 · high' "$WORK/start.out"
assert grep -qx 'grokacct · grok-4.6 · high' "$RUN_DIR/tag"
assert await_done
assert grep -qx 'ARG=-m' "$CALL_LOG"
assert grep -qx 'ARG=grok-4.6' "$CALL_LOG"
assert grep -qx 'ARG=--reasoning-effort' "$CALL_LOG"
assert grep -qx 'ARG=high' "$CALL_LOG"

# --- fast is the chat pin's modifier, and it is workers only -------------------------------------
# `chat-pin grok-fast` writes `grok_fast=on` beside the pin: the default model becomes the `-fast`
# sibling `grokb models` lists beside it, carrying that slug's own label instead of the vendor word.
mkdir -p "$CHAT_PINS_DIR"
printf 'grok_profile=*\ngrok_fast=on\n' >"$CHAT_PINS_DIR/chat-fast"
clear_stub
set_config 'grok_model=auto' 'grok_effort=high'
CLAUDE_CODE_SESSION_ID=chat-fast start_ok grok
assert grep -qx 'TAG: grokacct · grok-4.7-build-fast · high' "$WORK/start.out"
assert test "$(jq -r '.model' "$RUN_DIR/meta.json")" = grok-4.7-build-fast
assert await_done
assert grep -qx 'ARG=-m' "$CALL_LOG"
assert grep -qx 'ARG=grok-4.7-build-fast' "$CALL_LOG"
# The chat's fast swap is judged against the picked account's own catalog too.
mkdir -p "$GROKB_PROFILES_DIR/grokacct"
printf '{"models":{"grok-4.7":{},"grok-4.6":{}}}\n' >"$GROKB_PROFILES_DIR/grokacct/models_cache.json"
clear_stub
CLAUDE_CODE_SESSION_ID=chat-fast start_ok grok
assert await_done
assert_fails grep -qx 'ARG=grok-4.7-build-fast' "$CALL_LOG"
assert grep -q 'grok: grokacct lists no grok-4.7-build-fast now' "$WORK/start.err"
rm -f "$GROKB_PROFILES_DIR/grokacct/models_cache.json"

# A model someone named is a choice and travels as named: fast stands in for the default and for
# `auto`, never for that.
clear_stub
set_config 'grok_model=grok-4.6' 'grok_effort=high'
CLAUDE_CODE_SESSION_ID=chat-fast start_ok grok
assert grep -qx 'TAG: grokacct · grok-4.6 · high' "$WORK/start.out"
assert await_done
assert grep -qx 'ARG=grok-4.6' "$CALL_LOG"

# Research is not a worker leg and never takes it (Egor).
clear_stub
set_config 'grok_model=auto' 'grok_effort=high' 'light_research=grok'
CLAUDE_CODE_SESSION_ID=chat-fast start_ok grok --role research
assert grep -qx 'TAG: grokacct · grok · high' "$WORK/start.out"
assert test "$(jq -r '.model' "$RUN_DIR/meta.json")" = auto
assert await_done

# Another chat's fast line is not this chat's.
clear_stub
set_config 'grok_model=auto' 'grok_effort=high'
CLAUDE_CODE_SESSION_ID=chat-plain start_ok grok
assert grep -qx 'TAG: grokacct · grok · high' "$WORK/start.out"
assert await_done
rm -f "$CHAT_PINS_DIR/chat-fast"

# The account's own Fast Mode swaps the model after the effort was checked on `auto`: the swapped
# slug's catalog efforts still decide, before anything launches.
cp "$GROKB_CACHE_DIR/models.json" "$WORK/grok-models.saved"
jq '.models |= map(if .slug == "grok-4.7-build-fast" then .efforts = ["high"] else . end)' "$WORK/grok-models.saved" \
  >"$GROKB_CACHE_DIR/models.json"
mkdir -p "$GROKB_PROFILES_DIR/.grokb/fast-mode"
printf 'fast\n' >"$GROKB_PROFILES_DIR/.grokb/fast-mode/grokacct"
clear_stub
set_config 'grok_model=auto' 'grok_effort=high'
rc=0
"$RUNNER" start grok --brief "$WORK/brief" --effort xhigh >"$WORK/grok-effort.out" 2>"$WORK/grok-effort.err" || rc=$?
assert test "$rc" -eq 4
assert grep -qx 'OUTCOME: EFFORT_REFUSED' "$WORK/grok-effort.out"
assert grep -q 'grok-4.7-build-fast' "$WORK/grok-effort.err"
assert test ! -s "$CALL_LOG"
cp "$WORK/grok-models.saved" "$GROKB_CACHE_DIR/models.json"
# The account's own catalog decides whether its Fast twin exists, not the shared list.
mkdir -p "$GROKB_PROFILES_DIR/grokacct"
printf '{"models":{"grok-4.7":{},"grok-4.6":{}}}\n' >"$GROKB_PROFILES_DIR/grokacct/models_cache.json"
clear_stub
start_ok grok
assert await_done
assert_fails grep -qx 'ARG=grok-4.7-build-fast' "$CALL_LOG"
assert grep -q 'grok: grokacct lists no grok-4.7-build-fast now' "$WORK/start.err"
printf '{"models":{"grok-4.7":{},"grok-4.7-build-fast":{}}}\n' >"$GROKB_PROFILES_DIR/grokacct/models_cache.json"
clear_stub
start_ok grok
assert await_done
assert grep -qx 'ARG=grok-4.7-build-fast' "$CALL_LOG"
rm -f "$GROKB_PROFILES_DIR/.grokb/fast-mode/grokacct" "$GROKB_PROFILES_DIR/grokacct/models_cache.json"

# `xhigh` is the CLI's to know: it travels as asked instead of being
# clamped here, and only an effort no grok has is refused before launch.
clear_stub
start_ok grok --effort xhigh
assert await_done
assert grep -qx 'ARG=xhigh' "$CALL_LOG"
clear_stub
rc=0
"$RUNNER" start grok --brief "$WORK/brief" --effort ultra >"$WORK/grok-effort.out" 2>"$WORK/grok-effort.err" || rc=$?
assert test "$rc" -eq 4
assert grep -qx 'OUTCOME: EFFORT_REFUSED' "$WORK/grok-effort.out"
assert test ! -s "$CALL_LOG"

clear_stub
set_config 'grok_effort=high'
export WORKER_RUN_GROK_MAX_TURNS=7
start_ok grok
assert await_done
assert grep -qx 'ARG=--max-turns' "$CALL_LOG"
assert grep -qx 'ARG=7' "$CALL_LOG"
assert test "$(jq -r '.max_turns' "$RUN_DIR/meta.json")" = 7
# A cap that is not a positive count is no cap at all — silently reading it as some default number
# would launch the run under a limit nobody asked for.
clear_stub
export WORKER_RUN_GROK_MAX_TURNS=nonsense
start_ok grok
assert await_done
assert test "$(grep -c '^ARG=--max-turns$' "$CALL_LOG")" -eq 0
assert test "$(jq -r 'has("max_turns")' "$RUN_DIR/meta.json")" = false
unset WORKER_RUN_GROK_MAX_TURNS

clear_stub
start_ok grok --web-search
assert await_done
assert test "$(grep -c '^ARG=--disable-web-search$' "$CALL_LOG")" -eq 0

# 1.0.13 grants directories through --cwd alone and attaches no images, so those flags are refused
# where a caller can still read the refusal instead of in a CLI error nobody sees.
for grok_flag in "--add-dir $WORK/extra" "--image $WORK/image.png"; do
  clear_stub
  rc=0
  # shellcheck disable=SC2086
  "$RUNNER" start grok --brief "$WORK/brief" $grok_flag >"$WORK/grok-flag.out" 2>"$WORK/grok-flag.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -q 'grok does not support --add-dir or --image' "$WORK/grok-flag.err"
  assert test ! -s "$CALL_LOG"
done

# A research run is refused with them: grok reads the one tree `--cwd` names, so a brief over
# several repositories would be answered from the only one the run could open.
clear_stub
rc=0
"$RUNNER" start grok --brief "$WORK/brief" --role research --add-dir "$WORK/extra" \
  >"$WORK/grok-research.out" 2>"$WORK/grok-research.err" || rc=$?
assert test "$rc" -eq 4
assert grep -q 'grok does not support --add-dir or --image' "$WORK/grok-research.err"
assert test ! -s "$CALL_LOG"

# A continued session rides `-r`: `-s` only ever CREATES and rejects an id that already exists, so
# handing it the session to continue ends the run before the brief is read.
clear_stub
export STUB_GROK_SESSION=grok-resumed-1
start_ok grok --account grokacct --resume grok-resumed-1
assert await_done
assert grep -qx 'ARG=-r' "$CALL_LOG"
assert grep -qx 'ARG=grok-resumed-1' "$CALL_LOG"
assert grep -qx 'SESSION: grok-resumed-1' "$WORK/wait.out"
assert test "$(grep -c '^ARG=-s$' "$CALL_LOG")" -eq 0
grok_collision_rc=0
CALL_LOG="$WORK/grok-collision-calls" "$WORK/bin/grokb" profile grokacct -s grok-resumed-1 \
  >"$WORK/grok-collision.out" 2>"$WORK/grok-collision.err" || grok_collision_rc=$?
assert test "$grok_collision_rc" -eq 1
assert grep -q 'already in use' "$WORK/grok-collision.err"
assert test ! -s "$WORK/grok-collision.out"

# grok's `main` is the real ~/.grok, which holds no worker login: with the picker gone and nothing
# pinned the run fails closed where codex and agy fall back to main.
clear_stub
set_config 'grok_effort=high'
export PICK_RC=2 PICK_ACCOUNT=ignored
rc=0
"$RUNNER" start grok --brief "$WORK/brief" >"$WORK/grok-nomain.out" 2>"$WORK/grok-nomain.err" || rc=$?
assert test "$rc" -eq 4
assert grep -qx 'OUTCOME: GROK_UNAVAILABLE' "$WORK/grok-nomain.out"
assert grep -q 'grok has no account to fall back on' "$WORK/grok-nomain.err"
assert test ! -s "$CALL_LOG"
assert test "$(grep -c 'main' "$WORK/grok-nomain.err")" -eq 0
clear_stub
set_config 'grok_effort=high' 'grok_profile=grokpin'
start_ok grok
assert meta_account_is grokpin
assert jq -e 'has("pinned") | not' "$RUN_DIR/meta.json" >/dev/null
assert await_done

# A vendor the picker can read NOTHING about — no accounts, no usage snapshot — is not a walled one:
# its quota may be untouched, and this whole system exists so nothing reports a limit it has no data
# for. Live-caught on the grok leg before its quota reader landed: `no selectable grok account
# (unavailable)` came back as GROK_USAGE_LIMIT.
# The reasons are the ones worker-pick really prints: its whole vendor line sits inside the
# parens, so an unprefixed sentence would test only the stub (tests/test_worker_pick.sh pins
# `no selectable grok account (grok: unavailable)` on the producing side).
for pick_reason in 'grok: unavailable' 'grok: no quota data' \
                   'grok: pin gone absent → no selectable account | unavailable'; do
  clear_stub
  set_config 'grok_effort=high'
  export PICK_RC=3 PICK_ACCOUNT=ignored
  export PICK_STDERR="worker-pick: no selectable grok account ($pick_reason)"
  rc=0
  "$RUNNER" start grok --brief "$WORK/brief" >"$WORK/grok-nodata.out" 2>"$WORK/grok-nodata.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -qx 'OUTCOME: GROK_UNAVAILABLE' "$WORK/grok-nodata.out"
  assert grep -q 'no usage data for grok' "$WORK/grok-nodata.err"
  assert test ! -s "$CALL_LOG"
  unset PICK_STDERR
done
# Any other reason at that exit is the wall it says it is.
clear_stub
export PICK_RC=3 PICK_ACCOUNT=ignored
export PICK_STDERR='worker-pick: no selectable grok account (grok: all walled)'
rc=0
"$RUNNER" start grok --brief "$WORK/brief" >"$WORK/grok-walled-reason.out" 2>&1 || rc=$?
assert test "$rc" -eq 3
assert grep -qx 'OUTCOME: GROK_USAGE_LIMIT' "$WORK/grok-walled-reason.out"
unset PICK_STDERR


echo "PASS: $asserts asserts; grok launches, models, fast mode, efforts, turn caps and flags"
