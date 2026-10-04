#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
MEDIA_RUN="$ROOT/bin/media-run"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { asserts=$((asserts + 1)); }

CAPS="$WORK/caps" BIN="$WORK/bin" CACHE="$WORK/cache" LOG="$WORK/log"
mkdir -p "$CAPS" "$BIN" "$CACHE" "$LOG"
cp "$ROOT"/share/image-caps/*.json "$CAPS/"
# A fourth vendor no line of media-run knows, with a kind no real vendor has.
printf '%s\n' '{"vendor":"zeta","routes":["cli"],"scripts":{"image":"zeta-image","sfx":"zeta-sfx","smell":"zeta-smell"}}' >"$CAPS/zeta.json"

fake() { # name: records its pid, IMAGE_JOB_ID and every argument NUL-terminated, then exits FAKE_RC
  cat >"$BIN/$1" <<'EOF'
#!/usr/bin/env bash
name=${0##*/}
printf '%s\n' "$$" >"$FAKE_LOG/$name.pid"
printf '%s' "${IMAGE_JOB_ID-unset}" >"$FAKE_LOG/$name.job"
: >"$FAKE_LOG/$name.args"
for arg in "$@"; do printf '%s\0' "$arg" >>"$FAKE_LOG/$name.args"; done
exit "${FAKE_RC:-0}"
EOF
  chmod +x "$BIN/$1"
}
for script in $(cat "$CAPS"/*.json | jq -r '.scripts // {} | .[]' | sort -u) image-fanout; do fake "$script"; done
cat >"$WORK/worker-pick" <<'EOF'
#!/usr/bin/env bash
[ "$*" = '--account zeta --role image' ] && printf 'zacct\n'
EOF
chmod +x "$WORK/worker-pick"

run() { # args... -> rc in $rc, stderr in $WORK/err
  rm -f "$LOG"/*
  MEDIA_RUN_CAPS_DIR="$CAPS" MEDIA_RUN_BIN_DIR="$BIN" MEDIA_RUN_WORKER_PICK="$WORK/worker-pick" \
    STATUSLINE_CACHE_DIR="$CACHE" FAKE_LOG="$LOG" "$MEDIA_RUN" "$@" 2>"$WORK/err"
  rc=$?
}
pointer() { tr '\t' '\037' <"$CACHE/media-$1"; }
same_args() { # script expected-args...
  local want="$WORK/want" arg
  : >"$want"
  for arg in "${@:2}"; do printf '%s\0' "$arg" >>"$want"; done
  cmp -s "$want" "$LOG/$1.args"
}

# The prompt and every argument reach the script byte for byte.
nasty_prompt=$'a "quoted" \'single\' $HOME `date` $(id)\nsecond line — ünïcødé 🎨 \\back\\slash *?[x]'
args=(--dest '/tmp/out dir/a.png' --prompt "$nasty_prompt" -leading-dash '' '--=' ' spaced ' --ref /tmp/r.png)
run image --vendor zeta -- "${args[@]}"
[ "$rc" = 0 ] || fail "zeta image run exited $rc: $(cat "$WORK/err")"
same_args zeta-image "${args[@]}" || fail "the arguments did not reach zeta-image byte for byte"
ok
run image --vendors all --takes-not-mine 2>/dev/null
[ "$rc" = 2 ] || fail "an option of the script's before -- was not refused (rc $rc)"
ok
run image --vendors codex,zeta -- "${args[@]}"
same_args image-fanout --vendors codex,zeta "${args[@]}" || fail "the fan-out did not get the arguments byte for byte"
ok

# The vendor list and the kinds are the manifests'.
run smell -- --dest /tmp/a.smell
[ "$rc" = 0 ] && same_args zeta-smell --dest /tmp/a.smell || fail "a kind only one manifest names did not run its script"
ok
run image -- --dest /tmp/a.png --prompt x
[ "$rc" = 2 ] && grep -q 'codex gemini grok zeta' "$WORK/err" || fail "an image with no vendor did not ask for one: $(cat "$WORK/err")"
ok
run image --vendors all -- --dest-dir /tmp/fan --prompt x
same_args image-fanout --vendors codex,gemini,grok,zeta --dest-dir /tmp/fan --prompt x || fail "--vendors all is not every image manifest"
ok
run video --vendors all -- --dest-dir /tmp/fan --prompt x
same_args image-fanout --vendors gemini,grok --video --dest-dir /tmp/fan --prompt x || fail "a video fan-out is not the video vendors with --video"
ok
run music --vendors all -- --dest /tmp/a.wav --prompt x
[ "$rc" = 0 ] && same_args gemini-music --dest /tmp/a.wav --prompt x || fail "a one-vendor --vendors all did not exec that script"
ok
run sfx --vendors all -- --dest /tmp/a.wav --prompt x
[ "$rc" = 2 ] && [ ! -e "$LOG/image-fanout.args" ] || fail "a sound fan-out reached image-fanout (rc $rc)"
ok
run image --vendor nope -- --prompt x
[ "$rc" = 2 ] || fail "an unknown vendor was not refused"
ok
run image --vendor zeta --vendors all -- --prompt x
[ "$rc" = 2 ] || fail "--vendor with --vendors was not refused"
ok
run teleport -- --prompt x
[ "$rc" = 2 ] || fail "a kind no manifest names was not refused"
ok

# Takes and jobs fan out even on one vendor.
run image --vendor zeta -- --dest-dir /tmp/fan --prompt x --takes 3
same_args image-fanout --vendors zeta --dest-dir /tmp/fan --prompt x --takes 3 || fail "--takes on one vendor did not fan out"
ok
run image --vendor zeta --jobs /tmp/jobs.jsonl -- --dest-dir /tmp/fan
same_args image-fanout --vendors zeta --jobs /tmp/jobs.jsonl --dest-dir /tmp/fan || fail "--jobs did not reach image-fanout"
ok

# The exit code is the script's, exit 5 (account busy) included.
FAKE_RC=5 run image --vendor zeta -- --prompt x
[ "$rc" = 5 ] || fail "exit 5 of the script came back as $rc"
ok

# The job pointer: same pid as the script (exec), the account worker-pick names for a CLI route, the
# media tag, gen/edit, the job id the script got.
run image --vendor zeta -- --dest /tmp/a.png --prompt x --ref /tmp/r.png
pid=$(cat "$LOG/zeta-image.pid")
pointer="$CACHE/media-$pid"
[ -f "$pointer" ] || fail "no media pointer for pid $pid"
IFS=$'\037' read -r p_start p_tag p_label p_state p_job < <(pointer "$pid")
[[ "$p_start" =~ ^[0-9]+$ ]] && [ "$p_tag" = 'zacct · img·zeta' ] && [ "$p_label" = edit ] && [ -z "$p_state" ] ||
  fail "pointer reads '$p_start|$p_tag|$p_label|$p_state'"
ok
[ -n "$p_job" ] && [ "$p_job" = "$(cat "$LOG/zeta-image.job")" ] || fail "the pointer's job '$p_job' is not the script's IMAGE_JOB_ID"
ok
run image --vendor zeta -- --dest /tmp/a.png --prompt x --account pinned
IFS=$'\037' read -r _ p_tag p_label _ < <(pointer "$(cat "$LOG/zeta-image.pid")")
[ "$p_tag" = 'pinned · img·zeta' ] && [ "$p_label" = gen ] || fail "a pinned account reads '$p_tag' '$p_label'"
ok
run image --vendor codex -- --dest /tmp/a.png --prompt x
IFS=$'\037' read -r _ p_tag _ < <(pointer "$(cat "$LOG/codex-image.pid")")
[ "$p_tag" = "pool · img·$(jq -r '.routes[0]' "$CAPS/codex.json")" ] || fail "a browser route reads '$p_tag'"
ok
run image --vendor codex -- --dest /tmp/a.png --prompt x --route cli
IFS=$'\037' read -r _ p_tag _ < <(pointer "$(cat "$LOG/codex-image.pid")")
[ "$p_tag" = 'pool · img·cli' ] || fail "an explicit cli route reads '$p_tag'"
ok
run image --vendors codex,zeta -- --dest-dir /tmp/fan --prompt x
IFS=$'\037' read -r _ p_tag p_label p_state _ < <(pointer "$(cat "$LOG/image-fanout.pid")")
[ "$p_tag" = 'fanout · img' ] && [ "$p_label" = all ] && [ "$p_state" = /tmp/fan/fanout.state.json ] ||
  fail "a fan-out pointer reads '$p_tag|$p_label|$p_state'"
ok
[ "$(cat "$LOG/image-fanout.job")" = unset ] || fail "a fan-out inherited one job id for all its cells"
ok
run image --vendors codex,zeta -- --dest-dir /tmp/fan --prompt x --dry-run
IFS=$'\037' read -r _ _ _ p_state _ < <(pointer "$(cat "$LOG/image-fanout.pid")")
[ -z "$p_state" ] || fail "a dry run named a state file"
ok

# No vendor literal in the door itself.
[ -z "$(grep -nE 'codex|gemini|grok' "$MEDIA_RUN")" ] || fail "media-run names a vendor: $(grep -nE 'codex|gemini|grok' "$MEDIA_RUN")"
ok

echo "PASS: $asserts asserts; media-run passes the prompt and every argument to the vendor script or image-fanout byte for byte, takes its vendors and kinds from the manifests alone (a fourth fake vendor and kind run with no code change), fans out on several vendors, --takes or --jobs, returns the script's exit code, and leaves a work-line pointer with the account, the media tag and gen/edit"
