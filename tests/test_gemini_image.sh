#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
export IMAGE_LEG_LOG="$WORK/image-legs.jsonl"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$WORK/err" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
REAL_MAGICK=$(command -v magick) || exit 1
export REAL_MAGICK
UV_CACHE_DIR=${UV_CACHE_DIR:-$(uv cache dir 2>/dev/null)}
export UV_CACHE_DIR
export HOME="$WORK/home" GEMINIB_PROFILES_DIR="$WORK/profiles"
export WORKER_CLAIMS_DIR="$WORK/claims" WORKER_PICK_CONFIG_FILE="$WORK/worker-model"
export LLM_LIMITS_GEMINI_CACHE="$WORK/main-cache" LLM_LIMITS_GEMINI_REMOVED="$WORK/main-removed"
export LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$WORK/account-caches" TMPDIR="$WORK/tmp"
export FAKE_GEMINIB_CALLS="$WORK/calls" FAKE_GEMINIB_PROMPT="$WORK/prompt"
export PICK_CALLS="$WORK/picks" AGY_BIN="$WORK/bin/agy"
export GEMINIB_CACHE_DIR="$WORK/geminib-cache" FLOW_IMAGE_ENGINE="$WORK/bin/no-flow"
MANIFEST_CLI_VERSION=$(jq -r '.cli.version' "$ROOT/share/image-caps/gemini.json")
export MANIFEST_CLI_VERSION
. "$ROOT/tests/fixtures/geminib-families.sh"
mkdir -p "$HOME" "$WORK/bin" "$TMPDIR" "$WORK/output" "$GEMINIB_PROFILES_DIR/explicit" "$GEMINIB_PROFILES_DIR/picked"
ln -s "$ROOT/tests/fixtures/fake-geminib-image.sh" "$WORK/bin/geminib"
cat >"$WORK/bin/agy" <<'STUB'
#!/usr/bin/env bash
[ "$*" = --version ] || exit 91
printf '%s\n' "${FAKE_AGY_VERSION:-$MANIFEST_CLI_VERSION}"
STUB
cat >"$WORK/bin/worker-pick" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PICK_CALLS"
[ "${PICK_MODE:-ok}" != limit ] || exit 3
printf 'picked\n'
STUB
printf '#!/usr/bin/env bash\necho flow >>"%s"\nexit 1\n' "$WORK/flow-calls" >"$WORK/bin/no-flow"
chmod +x "$WORK/bin/agy" "$WORK/bin/worker-pick" "$WORK/bin/no-flow"
export PATH="$WORK/bin:$PATH"
: >"$FAKE_GEMINIB_CALLS"
: >"$PICK_CALLS"
: >"$WORK/err"
# The agy route; Flow is gemini-image's default and has its own suite (test_flow_image.sh).
route_args=(--route cli)
image_run() { bash "${SCRIPT:-$ROOT/bin/gemini-image}" ${route_args[@]+"${route_args[@]}"} "$@" >"$WORK/out" 2>"$WORK/err"; }
expect_rc() {
  local expected=$1 result=0
  shift
  image_run "$@" || result=$?
  assert test "$result" -eq "$expected"
}
args=(--dest "$WORK/output/result.png" --prompt 'a blue badge')
printf 'reference\n' >"$WORK/reference.jpg"
ref="$WORK/reference.jpg"
expect_rc 2 --dest relative.png --prompt badge
expect_rc 2 "${args[@]}" --aspect 5:4
expect_rc 2 "${args[@]}" --ref "$ref" --ref "$ref" --ref "$ref" --ref "$ref"
expect_rc 2 "${args[@]}" --ref relative.png
expect_rc 2 "${args[@]}" --ref "$WORK/missing.jpg"
expect_rc 2 "${args[@]}" --account 'bad name'
expect_rc 2 "${args[@]}" --account ""
assert grep -q -- "--account needs a profile name" "$WORK/err"
assert test ! -s "$FAKE_GEMINIB_CALLS"
assert test ! -s "$PICK_CALLS"
expect_rc 2 "${args[@]}" --resume fixture-session
expect_rc 2 "${args[@]}" --resume ../bad --account explicit
expect_rc 2 "${args[@]}" --resume absent --account explicit
expect_rc 2 --dest "$WORK/output/noext" --prompt badge
expect_rc 2 --dest "$WORK/output/bad.jpg" --prompt badge --transparent
expect_rc 2 "${args[@]}" --account unknown
assert grep -q 'unknown account: unknown (not on the gemini roster' "$WORK/err"
assert test ! -s "$FAKE_GEMINIB_CALLS"
assert test ! -d "$GEMINIB_PROFILES_DIR/unknown"
: >"$LLM_LIMITS_GEMINI_REMOVED"
expect_rc 2 "${args[@]}" --account main
rm -f "$LLM_LIMITS_GEMINI_REMOVED"
assert test ! -s "$FAKE_GEMINIB_CALLS"
expect_rc 2 "${args[@]}" --composite --account explicit
assert grep -q 'composite needs the image being edited' "$WORK/err"
expect_rc 2 "${args[@]}" --composite --resume fixture-session --account explicit
expect_rc 2 "${args[@]}" --ref "$ref" --composite=0.5,0.5,0.6,0.1 --account explicit
expect_rc 2 "${args[@]}" --ref "$ref" --composite= --account explicit
expect_rc 2 "${args[@]}" --ref "$ref" --composite --transparent --account explicit
assert test ! -s "$FAKE_GEMINIB_CALLS"

assert image_run "${args[@]}" --aspect 16:9 --ref "$ref" --ref "$ref" --ref "$ref"
assert grep -qx 'ImagePaths:' "$FAKE_GEMINIB_PROMPT"
assert test "$(grep -Fxc -- "- $ref" "$FAKE_GEMINIB_PROMPT")" -eq 3
assert grep -qx 'AspectRatio: 16:9' "$FAKE_GEMINIB_PROMPT"
assert grep -qx -- '--account gemini --role image' "$PICK_CALLS"
assert test -e "$WORKER_CLAIMS_DIR/gemini/picked"
assert test -e "$WORK/media-starts/gemini/picked"
assert grep -qx 'ARG=stream-json' "$FAKE_GEMINIB_CALLS"
job=$(sed -n 's/^job=//p' "$WORK/out")
assert grep -Eqx 'gemini-image-[0-9]{8}T[0-9]{6}Z-[0-9]+' <<<"$job"
printf 'dest=%s\nsize=16x12\nformat=png\naccount=picked\nsession=fixture-session\njob=%s\nroute=cli\nmodel=gemini-3.1-flash-image model_caps=fresh\ncaps=fresh\ncomposite=skipped reason=several-inputs\nedit_depth=1 root=%s\n' "$WORK/output/result.png" "$job" "$ref" >"$WORK/expected"
assert cmp "$WORK/expected" "$WORK/out"
assert jq -se --arg job "$job" '.[-1] | .job == $job and .route == "cli" and .requested == 1 and .delivered == 1
  and .composite == {kind: "skipped", changed: null, reason: "several-inputs"} and (has("fallback_from") | not)' "$IMAGE_LEG_LOG" >/dev/null

: >"$PICK_CALLS"
assert image_run "${args[@]}" --account explicit
assert grep -qx 'Omit ImagePaths.' "$FAKE_GEMINIB_PROMPT"
assert test ! -s "$PICK_CALLS"
assert test -e "$WORK/media-starts/gemini/explicit"
rm -rf "$WORK/media-starts"
: >"$FAKE_GEMINIB_CALLS"
assert image_run "${args[@]}" --prompt 'now make it bluer' --resume fixture-session --account explicit
assert test ! -e "$WORK/media-starts/gemini/explicit"
assert grep -qx 'ARG=--conversation' "$FAKE_GEMINIB_CALLS"
assert grep -qx 'ARG=fixture-session' "$FAKE_GEMINIB_CALLS"
assert grep -qx 'ARG=explicit' "$FAKE_GEMINIB_CALLS"
assert grep -q 'last generated image from this conversation as ImagePaths' "$FAKE_GEMINIB_PROMPT"
assert test "$(grep -c '^AspectRatio:' "$FAKE_GEMINIB_PROMPT")" -eq 0
assert image_run "${args[@]}" --prompt 'wider' --resume fixture-session --account explicit --aspect 16:9
assert grep -qx 'AspectRatio: 16:9' "$FAKE_GEMINIB_PROMPT"
assert grep -qx 'session=fixture-session' "$WORK/out"

# Without --route a resume lands on the route that made the session (Flow is the default), and a record
# from before routes were kept falls back to the agy conversation on the account; a contradicting --route
# is refused before anything runs.
route_args=()
session_record="$WORK/sessions/gemini/fixture-session"
assert test "$(sed -n 2p "$session_record")" = cli
: >"$FAKE_GEMINIB_CALLS"
assert image_run "${args[@]}" --prompt 'bluer still' --resume fixture-session --account explicit
assert grep -qx 'ARG=fixture-session' "$FAKE_GEMINIB_CALLS"
head -n 1 "$session_record" >"$session_record.old" && mv "$session_record.old" "$session_record"
: >"$FAKE_GEMINIB_CALLS"
assert image_run "${args[@]}" --prompt 'bluer again' --resume fixture-session --account explicit
assert grep -qx 'ARG=fixture-session' "$FAKE_GEMINIB_CALLS"
: >"$FAKE_GEMINIB_CALLS"
expect_rc 2 "${args[@]}" --prompt 'x' --resume fixture-session --account explicit --route flow
assert test "$(cat "$WORK/err")" = 'gemini-image: --resume fixture-session was made on --route cli and continues there; drop --route flow'
assert test ! -s "$FAKE_GEMINIB_CALLS"
assert test ! -e "$WORK/flow-calls"
route_args=(--route cli)

result="$WORK/output/result.png"
assert image_run "${args[@]}" --account explicit
assert test "$(tail -n 1 "$WORK/out")" = "edit_depth=0 root=$result"
assert test "$(jq -c . "$result.edit.json")" = "{\"root\":\"$result\",\"depth\":0,\"edits\":[]}"
assert image_run --dest "$WORK/output/step1.png" --prompt 'red hair' --resume fixture-session --account explicit
assert test "$(tail -n 1 "$WORK/out")" = "edit_depth=1 root=$result"
assert image_run --dest "$WORK/output/step2.png" --prompt 'moon pendant' --ref "$WORK/output/step1.png" --account explicit
assert test "$(tail -n 1 "$WORK/out")" = "edit_depth=2 root=$result"
assert test "$(jq -c '[.edits[] | [.prompt, .region, .points, .route, .vendor, .account]]' "$WORK/output/step2.png.edit.json")" = \
  '[["red hair",null,[],"cli","gemini","explicit"],["moon pendant",null,[],"cli","gemini","explicit"]]'

"$REAL_MAGICK" -size 256x192 xc:'#00FF00' "$WORK/green.png"
assert image_run --dest "$WORK/output/composite.png" --prompt 'add a blue patch' --ref "$WORK/green.png" --composite --account explicit
assert grep -Eq '^composite=auto changed=[0-9.]+%$' "$WORK/out"
assert grep -qx 'size=256x192' "$WORK/out"
assert test "$("$REAL_MAGICK" "$WORK/output/composite.png" -depth 8 -format '%[pixel:p{3,3}]' info:)" = 'srgb(0,255,0)'
assert test "$("$REAL_MAGICK" "$WORK/output/composite.png" -depth 8 -format '%[fx:int(255*p{128,96}.b)]' info:)" -gt 200
assert test "$(tail -n 1 "$WORK/out")" = "edit_depth=1 root=$WORK/green.png"
assert test "$(jq -r '.edits[0].region' "$WORK/output/composite.png.edit.json")" = null
# The fixture paints blue over x 80..175 of 256: the 0..0.2 corner rectangle keeps the whole input green,
# and the resumed edit's 0.25..0.5 band takes only the blue left of x 128 — the rest stays the input's.
assert image_run --dest "$WORK/output/composite.png" --prompt 'corner' --ref "$WORK/green.png" --composite=0,0,0.2,0.2 --account explicit
assert image_run --dest "$WORK/output/composite.png" --prompt 'again' --resume fixture-session --composite=0.25,0.25,0.25,0.5 --account explicit
assert grep -Eq '^composite=region changed=' "$WORK/out"
assert test "$("$REAL_MAGICK" "$WORK/output/composite.png" -depth 8 -format '%[fx:int(255*p{100,96}.b)]' info:)" -gt 200
assert test "$("$REAL_MAGICK" "$WORK/output/composite.png" -depth 8 -format '%[pixel:p{150,96}]' info:)" = 'srgb(0,255,0)'
assert test "$(tail -n 1 "$WORK/out")" = "edit_depth=2 root=$WORK/green.png"
assert test "$(jq -r '.edits[1].region' "$WORK/output/composite.png.edit.json")" = 0.25,0.25,0.25,0.5
# Composite is on by default for every edit: a single --ref or the resumed session's last image, the
# vendor's render kept beside the dest; a global change is refused and delivered as rendered.
assert image_run --dest "$WORK/output/default.png" --prompt 'add a blue patch' --ref "$WORK/green.png" --account explicit
assert grep -Eq '^composite=auto changed=[0-9.]+%$' "$WORK/out"
assert grep -qx "rendered=$WORK/output/default.rendered.png" "$WORK/out"
assert test "$("$REAL_MAGICK" "$WORK/output/default.png" -depth 8 -format '%[pixel:p{3,3}]' info:)" = 'srgb(0,255,0)'
assert test "$("$REAL_MAGICK" "$WORK/output/default.rendered.png" -format '%wx%h' info:)" = 16x12
assert test "$(jq -r '.edits[0].composite.kind' "$WORK/output/default.png.edit.json")" = auto
"$REAL_MAGICK" -size 256x192 xc:'#00FF00' "$WORK/output/default.png"
assert image_run --dest "$WORK/output/default2.png" --prompt 'again' --resume fixture-session --account explicit
assert grep -Eq '^composite=auto changed=[0-9.]+%$' "$WORK/out"
assert grep -qx "rendered=$WORK/output/default2.rendered.png" "$WORK/out"
assert test "$("$REAL_MAGICK" "$WORK/output/default2.png" -format '%wx%h' info:)" = 256x192
assert image_run --dest "$WORK/output/optout.png" --prompt 'add a blue patch' --ref "$WORK/green.png" --no-composite --account explicit
assert test "$(grep -c '^composite=\|^rendered=' "$WORK/out")" -eq 0
assert test ! -e "$WORK/output/optout.rendered.png"
assert test "$(jq -c '.edits[0].composite' "$WORK/output/optout.png.edit.json")" = '{"kind":"skipped","changed":null,"reason":"opted-out"}'
assert image_run --dest "$WORK/output/keyed.png" --prompt 'a patch' --ref "$WORK/green.png" --transparent --account explicit
assert test "$(grep -c '^composite=' "$WORK/out")" -eq 0
"$REAL_MAGICK" -size 256x192 xc:red "$WORK/red.png"
assert image_run --dest "$WORK/output/global.png" --prompt 'repaint' --ref "$WORK/red.png" --account explicit
assert grep -Eqx 'composite=refused reason=global changed=[0-9.]+% kind=auto' "$WORK/out"
assert test ! -e "$WORK/output/global.rendered.png"
assert test "$("$REAL_MAGICK" "$WORK/output/global.png" -format '%wx%h' info:)" = 16x12
assert test "$(jq -r '.edits[0].composite.kind' "$WORK/output/global.png.edit.json")" = refused
"$REAL_MAGICK" -size 256x256 xc:'#00FF00' "$WORK/square.png"
assert image_run --dest "$WORK/output/outpaint.png" --prompt 'widen' --ref "$WORK/square.png" --account explicit
assert grep -qx 'composite=skipped reason=aspect-changed from=256x256 to=16x12' "$WORK/out"
assert test ! -e "$WORK/output/outpaint.rendered.png"
assert image_run --dest "$WORK/output/both.png" --prompt 'merge' --ref "$WORK/green.png" --ref "$WORK/square.png" --account explicit
assert grep -qx 'composite=skipped reason=several-inputs' "$WORK/out"
expect_rc 2 "${args[@]}" --ref "$WORK/green.png" --composite --no-composite --account explicit

for mode in stream rescue init-only subagent; do
  FAKE_GEMINIB_MODE=$mode assert image_run "${args[@]}" --account explicit
  assert grep -qx 'session=fixture-session' "$WORK/out"
  assert grep -qx 'model=gemini-3.1-flash-image model_caps=fresh' "$WORK/out"
done
FAKE_GEMINIB_MODE=saved-then-error assert image_run "${args[@]}" --account explicit
assert grep -qx 'model=gemini-3.1-flash-image model_caps=fresh' "$WORK/out"
assert grep -q 'agy exited 3 after the image was saved' "$WORK/err"
FAKE_GEMINIB_MODE=saved-then-quota assert image_run "${args[@]}" --account explicit
assert grep -q 'agy exited 3 after the image was saved' "$WORK/err"
assert test "$(grep -c GEMINI_USAGE_LIMIT "$WORK/err")" = 0
assert test -s "$WORK/output/result.png"
FAKE_GEMINIB_MODE=no-session assert image_run "${args[@]}" --account explicit
assert grep -qx 'session=none' "$WORK/out"
assert grep -qx 'model=unknown model_caps=unknown' "$WORK/out"
FAKE_GEMINIB_MODE=no-model assert image_run "${args[@]}" --account explicit
assert grep -qx 'model=unknown model_caps=unknown' "$WORK/out"
FAKE_IMAGE_MODEL=gemini-future-image FAKE_AGY_VERSION=1.3.0 assert image_run "${args[@]}" --account explicit
assert grep -qx 'model=gemini-future-image model_caps=stale verified=gemini-3.1-flash-image' "$WORK/out"
assert grep -qx "caps=stale cli=1.3.0 verified=$MANIFEST_CLI_VERSION" "$WORK/out"

for mode in quota quota-plain quota-stderr quota-log quota-exit quota-credits quota-tool; do
  FAKE_GEMINIB_MODE=$mode expect_rc 3 "${args[@]}" --account explicit
  assert grep -qx GEMINI_USAGE_LIMIT "$WORK/err"
  assert test ! -s "$WORK/out"
done
for mode in error api-error no-image stale; do
  FAKE_GEMINIB_MODE=$mode expect_rc 1 "${args[@]}" --account explicit
done
FAKE_GEMINIB_MODE=pool expect_rc 4 "${args[@]}" --account explicit
assert grep -q 'refused by the worker pool' "$WORK/err"
assert test ! -s "$WORK/out"
: >"$FAKE_GEMINIB_CALLS"
mkdir -p "$GEMINIB_PROFILES_DIR/.geminib"
printf 'explicit\n' >"$GEMINIB_PROFILES_DIR/.geminib/disabled"
expect_rc 4 "${args[@]}" --account explicit
assert test ! -s "$FAKE_GEMINIB_CALLS"
rm -f "$GEMINIB_PROFILES_DIR/.geminib/disabled"
: >"$FAKE_GEMINIB_CALLS"
PICK_MODE=limit expect_rc 3 "${args[@]}"
assert test ! -s "$FAKE_GEMINIB_CALLS"

assert image_run "${args[@]}" --prompt 'transparent badge' --transparent --account explicit
assert grep -q '#00FF00' "$FAKE_GEMINIB_PROMPT"
assert test "$(sips -g hasAlpha "$WORK/output/result.png" | awk '/hasAlpha:/ {print $2}')" = yes
CLAUDE_LAUNCHER_SESSION=launching-chat assert image_run "${args[@]}" --account explicit
assert grep -qx 'CLAUDE_LAUNCHER_SESSION=launching-chat' "$FAKE_GEMINIB_CALLS"
assert test -z "$(find "$TMPDIR" -name 'gemini-image.*' -print -quit)"

mkdir -p "$WORK/repo/bin" "$WORK/repo/share/image-caps"
cp "$ROOT/bin/gemini-image" "$WORK/repo/bin/"
printf '#!/usr/bin/env bash\nexec bash "%s" "$@"\n' "$ROOT/bin/geminib" >"$WORK/repo/bin/geminib"
chmod +x "$WORK/repo/bin/geminib"
cp "$ROOT/share/"{image-caps,image-chroma,image-leg,account-arg,account-roster,gemini-accounts,codex-accounts,worker-model,worker-pool,worker-walls,worker-claims,flow-image}.sh "$WORK/repo/share/"
jq '.refs.max=1 | .aspects.generate=["5:4"] | .aspects.edit=["5:4"] | .aspects.default="5:4"' "$ROOT/share/image-caps/gemini.json" >"$WORK/repo/share/image-caps/gemini.json"
SCRIPT="$WORK/repo/bin/gemini-image"
assert image_run "${args[@]}" --ref "$ref" --account explicit
assert grep -qx 'AspectRatio: 5:4' "$FAKE_GEMINIB_PROMPT"
expect_rc 2 "${args[@]}" --ref "$ref" --ref "$ref" --account explicit
expect_rc 2 "${args[@]}" --aspect 1:1 --account explicit
jq '.transparent="native"' "$ROOT/share/image-caps/gemini.json" >"$WORK/repo/share/image-caps/gemini.json"
expect_rc 1 "${args[@]}" --transparent --account explicit

# A Flash-less family list is a broken reader — `geminib families` answers from its built-in list
# when it has nothing else — and the launch would pin the nameless model `-low`.
noflash="$WORK/geminib-no-flash"
mkdir -p "$noflash"
jq '.families = (.families | map(select(.family | endswith("-flash") | not)))' \
  "$GEMINIB_CACHE_DIR/models.json" >"$noflash/models.json"
GEMINIB_CACHE_DIR="$noflash" image_run "${args[@]}" --account explicit
noflash_rc=$?
assert test "$noflash_rc" -eq 1
assert grep -q 'no Flash row' "$WORK/err"

mkdir -p "$WORK/bare-log"
(cd "$WORK/bare-log" && IMAGE_LEG_LOG=legs.jsonl bash -c '. "$1/share/image-leg.sh"; image_leg_start probe image; exit 4' _ "$ROOT") 2>/dev/null
assert test -f "$WORK/bare-log/legs.jsonl"
assert test "$(jq -r '"\(.tool) \(.rc)"' "$WORK/bare-log/legs.jsonl")" = 'probe 4'

# Flow is routes[0]: a route-level failure there (sign-in, busy, limit, unsent) reruns a request the cli
# route can express on agy; anything sent, refused or unknown, Flow-only flags and --route stay Flow's.
unset SCRIPT
route_args=()
export FLOW_CALLS="$WORK/flow-engine-calls"
cat >"$WORK/bin/fake-flow" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FLOW_CALLS"
fail() { printf '{"ok": false, "reason": "%s", "account": "flowacct"%s}\n' "$2" "$3"; exit "$1"; }
case "${FLOW_MODE:-unset}" in
  signin) fail 4 'no browser login' ', "sent": false' ;;
  busy) fail 5 'every Flow account is busy' ', "sent": false' ;;
  limit) fail 3 'every Flow account is walled' ', "sent": false' ;;
  unsent) fail 1 'Flow UI drift before the prompt' ', "sent": false' ;;
  sent) fail 1 'no image came back' ', "sent": true' ;;
  limit-sent) fail 3 'walled after the prompt went' ', "sent": true' ;;
  unknown) fail 1 'crashed' '' ;;
  refused) fail 1 'Flow refused the image: PUBLIC_ERROR_UNSAFE' ', "sent": false' ;;
  *) exit 99 ;;
esac
EOF
chmod +x "$WORK/bin/fake-flow"
export FLOW_IMAGE_ENGINE="$WORK/bin/fake-flow"
flow_run() { # mode args...
  local mode=$1
  shift
  rm -f "$FLOW_CALLS"
  : >"$FAKE_GEMINIB_CALLS"
  flow_rc=0
  FLOW_MODE=$mode image_run "$@" || flow_rc=$?
}
for trigger in signin:sign-in busy:busy limit:limit unsent:not-sent; do
  flow_run "${trigger%:*}" "${args[@]}" --aspect 2:3 --account explicit --lock-wait 45
  assert test "$flow_rc" -eq 0
  assert grep -qx 45 <<<"$(grep -A1 -x -- --lock-wait "$FLOW_CALLS")"
  assert grep -qx 3:4 "$FLOW_CALLS"
  assert grep -qx 'ARG=explicit' "$FAKE_GEMINIB_CALLS"
  assert grep -qx 'AspectRatio: 2:3' "$FAKE_GEMINIB_PROMPT"
  assert grep -qx 'route=cli' "$WORK/out"
  assert grep -qx 'fallback_from=flow' "$WORK/out"
  assert grep -qx "fallback_reason=${trigger#*:}" "$WORK/out"
  assert grep -qx 'account=explicit' "$WORK/out"
  assert jq -e --arg why "${trigger#*:}" '.rc == 0 and .route == "cli" and .fallback_from == "flow" and .fallback_reason == $why
    and .requested == 1 and .delivered == 1' <<<"$(tail -n 1 "$IMAGE_LEG_LOG")" >/dev/null
done
for stays in sent:1 limit-sent:3 unknown:1 refused:1; do
  flow_run "${stays%:*}" "${args[@]}" --account explicit
  assert test "$flow_rc" -eq "${stays#*:}"
  assert test -s "$FLOW_CALLS"
  assert test ! -s "$FAKE_GEMINIB_CALLS"
  assert jq -e '.route == "flow" and (has("fallback_from") | not) and .delivered == 0' <<<"$(tail -n 1 "$IMAGE_LEG_LOG")" >/dev/null
done
for blocked in "--route flow" "--count 2" "--model nb2" "--aspect 21:9" "--ref $ref --ref $ref --ref $ref --ref $ref"; do
  read -r -a blocked_args <<<"$blocked"
  flow_run signin "${args[@]}" "${blocked_args[@]}"
  assert test "$flow_rc" -eq 4
  assert test -s "$FLOW_CALLS"
  assert test ! -s "$FAKE_GEMINIB_CALLS"
done
flow_run busy "${args[@]}" --route flow
assert test "$flow_rc" -eq 5
assert grep -qx 'ACCOUNT_BUSY account=flowacct' "$WORK/err"
flow_run busy "${args[@]}" --count 3
assert test "$flow_rc" -eq 5
assert grep -qx 'ACCOUNT_BUSY account=flowacct' "$WORK/err"
flow_run signin "${args[@]}" --lock-wait -1
assert test "$flow_rc" -eq 2
assert test ! -e "$FLOW_CALLS"

# --edit is the composite base and the first reference on both routes; the other refs are references only.
"$REAL_MAGICK" -size 16x12 'xc:#00FF00' "PNG24:$WORK/edit-base.png"
"$REAL_MAGICK" -size 16x12 'xc:#FF0000' "PNG24:$WORK/style-a.png"
"$REAL_MAGICK" -size 16x12 'xc:#0000FF' "PNG24:$WORK/style-b.png"
edit_args=(--edit "$WORK/edit-base.png" --ref "$WORK/style-a.png" --ref "$WORK/style-b.png")
flow_run signin "${args[@]}" --route flow "${edit_args[@]}"
assert test "$(grep -A1 -x -- --ref "$FLOW_CALLS" | grep -v -x -- --ref | grep -v -x -- -- | tr '\n' ' ')" = \
  "$WORK/edit-base.png $WORK/style-a.png $WORK/style-b.png "
assert grep -qx 'The first image is the one to edit; the other images are references only.' "$FLOW_CALLS"
route_args=(--route cli)
assert image_run "${args[@]}" "${edit_args[@]}" --account explicit
assert test "$(grep -x -- "- $WORK/[a-z-]*.png" "$FAKE_GEMINIB_PROMPT" | tr '\n' ' ')" = \
  "- $WORK/edit-base.png - $WORK/style-a.png - $WORK/style-b.png "
assert grep -qx 'The first image is the one to edit; the other images are references only.' "$FAKE_GEMINIB_PROMPT"
assert grep -Eqx 'composite=auto changed=[0-9.]+%' "$WORK/out"
assert grep -qx "edit_depth=1 root=$WORK/edit-base.png" "$WORK/out"
assert jq -e '.composite.kind == "auto" and .size == 4' <<<"$(tail -n 1 "$IMAGE_LEG_LOG")" >/dev/null
expect_rc 2 "${args[@]}" "${edit_args[@]}" --ref "$ref" --account explicit
expect_rc 2 "${args[@]}" --edit "$WORK/edit-base.png" --resume fixture-session --account explicit
assert grep -q -- '--edit names the image to edit' "$WORK/err"

printf 'PASS: %s asserts; manifest limits, account isolation, stream paths, resume, brain rescue, model provenance, quota, chroma, no Flash family, composite, edit lineage, output contract, flow-to-cli fallback only on sign-in/busy/limit/unsent for a cli-expressible request, exit 5 ACCOUNT_BUSY, --lock-wait forwarded, and --edit as composite base and first reference\n' "$asserts"
