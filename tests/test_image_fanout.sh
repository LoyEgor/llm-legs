#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/image-fanout"
WORK="$(mktemp -d)"
# Every `worker_model_*` call shells `grokb models`: the fixture list answers it, and the
# `grok` CLI behind it can never be reached (row `cu`).
export GROKB_CACHE_DIR="$WORK/grokb-cache"
. "$ROOT/tests/fixtures/grokb-models.sh"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { echo "FAIL: $*" >&2; [ -z "${FANOUT_ERR:-}" ] || sed -n '1,80p' "$FANOUT_ERR" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }

FAKE_BIN="$WORK/bin"
FAKE_LIST="$WORK/listers"
DEST="$WORK/out"
CALLS="$WORK/calls"
PICK_CALLS="$WORK/picks"
FANOUT_OUT="$WORK/fanout.out"
FANOUT_ERR="$WORK/fanout.err"
mkdir -p "$FAKE_BIN" "$FAKE_LIST" "$DEST" "$WORK/refs"
: >"$CALLS"
: >"$PICK_CALLS"

for i in 1 2 3 4 5; do
  printf 'ref-%s\n' "$i" >"$WORK/refs/r$i.png"
done

cat >"$FAKE_BIN/fake-image" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'BIN=%s\n' "$(basename "$0")"
  printf 'ARG=%s\n' "$@"
} >>"${FANOUT_CALLS:?}"
dest=''; account=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dest) dest=$2; shift 2 ;;
    --account) account=$2; shift 2 ;;
    --prompt|--ref|--aspect|--size|--duration) shift 2 ;;
    --transparent) shift ;;
    *) shift ;;
  esac
done
rc=0
case "$account" in
  walled) rc=3 ;;
  disabled) rc=4 ;;
  broken) rc=1 ;;
esac
if [ "$account" = staleacct ] || [ "${FANOUT_STALE:-}" = 1 ]; then
  printf 'model=x model_caps=stale verified=old\n' >&2
  printf 'caps=stale cli=9.9.9 verified=0.0.1\n' >&2
fi
[ -n "$account" ] || account=routed
if [ "$rc" -eq 3 ]; then printf 'USAGE_LIMIT\n' >&2; exit 3; fi
if [ "$rc" -eq 4 ]; then printf 'out of pool\n' >&2; exit 4; fi
if [ "$rc" -ne 0 ]; then printf 'failed\n' >&2; exit "$rc"; fi
mkdir -p "$(dirname "$dest")"
: >"$dest"
printf 'dest=%s\nsize=64x64\nformat=png\naccount=%s\nsession=sess-1\nmodel=test-model model_caps=fresh\ncaps=fresh\n' \
  "$dest" "$account"
EOF
chmod +x "$FAKE_BIN/fake-image"
ln -s "$FAKE_BIN/fake-image" "$FAKE_BIN/codex-image"
ln -s "$FAKE_BIN/fake-image" "$FAKE_BIN/gemini-image"
ln -s "$FAKE_BIN/fake-image" "$FAKE_BIN/grok-image"
ln -s "$FAKE_BIN/fake-image" "$FAKE_BIN/grok-video"

cat >"$FAKE_BIN/worker-pick" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${PICK_CALLS:?}"
vendor=''; role=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --account) vendor=$2; shift 2 ;;
    --role) role=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ "$role" = image ] || exit 2
[ -n "$vendor" ] || exit 2
if [ "${PICK_MODE:-ok}" = limit ]; then exit 3; fi
printf 'picked-%s\n' "$vendor"
EOF
chmod +x "$FAKE_BIN/worker-pick"

cat >"$FAKE_LIST/codexb" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = list ] || exit 2
printf 'alpha: Logged in\nbeta: Logged in (out of pool)\n'
EOF
cat >"$FAKE_LIST/geminib" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = list ] || exit 2
printf 'gamma: Logged in\n'
EOF
cat >"$FAKE_LIST/grokb" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = list ] || exit 2
printf 'delta: Logged in\nstaleacct: Logged in\n'
EOF
chmod +x "$FAKE_LIST/codexb" "$FAKE_LIST/geminib" "$FAKE_LIST/grokb"

fanout() {
  env IMAGE_FANOUT_BIN_DIR="$FAKE_BIN" IMAGE_FANOUT_LISTER_DIR="$FAKE_LIST" \
    FANOUT_CALLS="$CALLS" PICK_CALLS="$PICK_CALLS" \
    bash "$SCRIPT" "$@" >"$FANOUT_OUT" 2>"$FANOUT_ERR"
}

plan_cmd() { # vendor account
  awk -F'\t' -v key="$1 $2" '$1 == key { getline; print; exit }' "$FANOUT_OUT"
}
plan_reason() { # vendor account
  awk -F'\t' -v key="$1 $2" '$1 == key { print $2; exit }' "$FANOUT_OUT"
}
assert_fails() {
  asserts=$((asserts + 1))
  if grep -Fq -- "$2" <<<"$1"; then
    fail "assert $asserts unexpectedly found: $2"
  fi
}

REFS=(
  --ref "$WORK/refs/r1.png"
  --ref "$WORK/refs/r2.png"
  --ref "$WORK/refs/r3.png"
  --ref "$WORK/refs/r4.png"
  --ref "$WORK/refs/r5.png"
)
GEMINI_MAX=$(jq -r '.refs.max' "$ROOT/share/image-caps/gemini.json")
CODEX_MAX=$(jq -r '.refs.max' "$ROOT/share/image-caps/codex.json")
assert test "$GEMINI_MAX" = 3
assert test "$CODEX_MAX" = 5

# --- dry-run: refs truncation per manifest -----------------------------------
: >"$CALLS"
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --dry-run "${REFS[@]}" || rc=$?
assert test "$rc" -eq 0
assert test ! -s "$CALLS"
assert grep -Fq 'refs 5→3' <<<"$(plan_reason gemini gamma)"
gemini_cmd=$(plan_cmd gemini gamma)
assert test "$(grep -o -- '--ref' <<<"$gemini_cmd" | wc -l | tr -d ' ')" -eq "$GEMINI_MAX"
codex_cmd=$(plan_cmd codex alpha)
assert test "$(grep -o -- '--ref' <<<"$codex_cmd" | wc -l | tr -d ' ')" -eq 5
reason_cx=$(plan_reason codex alpha)
assert_fails "$reason_cx" 'refs '

# --- dry-run: aspect mapping + Codex prose -----------------------------------
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --dry-run --aspect 20:9 || rc=$?
assert test "$rc" -eq 0
assert grep -Fq 'aspect 20:9→16:9' <<<"$(plan_reason gemini gamma)"
assert grep -Fq -- '--aspect 16:9' <<<"$(plan_cmd gemini gamma)"
assert grep -Fq 'aspect 20:9→16:9' <<<"$(plan_reason grok delta)"
assert grep -Fq -- '--aspect 16:9' <<<"$(plan_cmd grok delta)"
cx_reason=$(plan_reason codex alpha)
assert grep -Fq 'aspect 20:9→prompt' <<<"$cx_reason"
cx_cmd=$(plan_cmd codex alpha)
assert grep -E -q 'aspect(\\)? ratio(\\)? 20:9' <<<"$cx_cmd"
assert_fails "$cx_cmd" --aspect

# grok edit list includes 20:9, so a ref keeps it
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --dry-run --aspect 20:9 --ref "$WORK/refs/r1.png" || rc=$?
assert test "$rc" -eq 0
assert grep -Fq -- '--aspect 20:9' <<<"$(plan_cmd grok delta)"
assert_fails "$(plan_reason grok delta)" 'aspect 20:9→'

# --- dry-run: --size maps to aspect except exact_size (none today) -----------
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --dry-run --size 1920x1080 || rc=$?
assert test "$rc" -eq 0
assert grep -Fq 'size 1920x1080→aspect 16:9' <<<"$(plan_reason gemini gamma)"
assert grep -Fq -- '--aspect 16:9' <<<"$(plan_cmd gemini gamma)"
assert_fails "$(plan_cmd gemini gamma)" --size
assert grep -Fq 'size 1920x1080→prompt 16:9' <<<"$(plan_reason codex alpha)"

# --- dry-run: video skips vendors without video ------------------------------
rc=0
fanout --dest-dir "$DEST" --prompt 'motion' --dry-run --video --ref "$WORK/refs/r1.png" || rc=$?
assert test "$rc" -eq 0
assert grep -Fq 'skipped: video unsupported' "$FANOUT_OUT"
assert grep -Fq $'codex -\tskipped: video unsupported' "$FANOUT_OUT"
assert grep -Fq $'gemini -\tskipped: video unsupported' "$FANOUT_OUT"
assert grep -Fq 'grok-video' <<<"$(plan_cmd grok delta)"
assert grep -Fq '.mp4' <<<"$(plan_cmd grok delta)"
assert_fails "$(plan_cmd grok delta)" grok-image
assert_fails "$(cat "$FANOUT_OUT")" codex-image
assert_fails "$(cat "$FANOUT_OUT")" gemini-image

# --- live run: tsv columns, exit 0 ------------------------------------------
: >"$CALLS"
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors grok --accounts all || rc=$?
assert test "$rc" -eq 0
tsv="$DEST/fanout.tsv"
assert test -f "$tsv"
assert test "$(head -n1 "$tsv")" = $'vendor\taccount\tstatus\treason\tdest\tsize\tsession\tmodel\tmodel_caps\tcaps'
delta_row=$(awk -F'\t' '$1=="grok" && $2=="delta" {print; exit}' "$tsv")
assert test "$(printf '%s' "$delta_row" | awk -F'\t' '{print $3}')" = ok
assert test "$(printf '%s' "$delta_row" | awk -F'\t' '{print $7}')" = sess-1
assert test "$(printf '%s' "$delta_row" | awk -F'\t' '{print $8}')" = test-model
assert test "$(printf '%s' "$delta_row" | awk -F'\t' '{print $9}')" = fresh
assert test "$(printf '%s' "$delta_row" | awk -F'\t' '{print $10}')" = fresh
assert grep -Fq 'ok=' "$FANOUT_OUT"
assert grep -Eq '^ok=[1-9] skipped=[0-9]+ usage_limit=[0-9]+ failed=[0-9]+$' "$FANOUT_OUT"

# --- STALE surfacing ---------------------------------------------------------
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors grok --accounts all || rc=$?
assert test "$rc" -eq 0
assert grep -Fq 'STALE: grok staleacct' "$FANOUT_OUT"

# --- exit 3: every attempted row is a usage limit ---------------------------
cat >"$FAKE_LIST/grokb" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = list ] || exit 2
printf 'walled: Logged in\n'
EOF
chmod +x "$FAKE_LIST/grokb"
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors grok || rc=$?
assert test "$rc" -eq 3
assert grep -Fq 'usage_limit' "$DEST/fanout.tsv"
assert grep -Fq 'ok=0' "$FANOUT_OUT"

# --- exit 1: a hard failure --------------------------------------------------
cat >"$FAKE_LIST/grokb" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = list ] || exit 2
printf 'broken: Logged in\n'
EOF
chmod +x "$FAKE_LIST/grokb"
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors grok || rc=$?
assert test "$rc" -eq 1
assert grep -Fq 'failed' "$DEST/fanout.tsv"
# The row's stderr survives beside the table and its last line rides in the reason column.
assert test -s "$DEST/grok-broken.stderr"
assert grep -Fq 'exit 1; failed' "$DEST/fanout.tsv"

# pool-disabled is skipped, not failed
cat >"$FAKE_LIST/grokb" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = list ] || exit 2
printf 'disabled: Logged in (out of pool)\n'
EOF
chmod +x "$FAKE_LIST/grokb"
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors grok || rc=$?
assert test "$rc" -eq 1
assert grep -Fq $'grok\tdisabled\tskipped' "$DEST/fanout.tsv"

# restore grok lister for pick
cat >"$FAKE_LIST/grokb" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = list ] || exit 2
printf 'delta: Logged in\n'
EOF
chmod +x "$FAKE_LIST/grokb"

# --- --accounts pick does not pin --account (wrappers route and claim) -------
: >"$PICK_CALLS"
: >"$CALLS"
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --accounts pick --dry-run || rc=$?
assert test "$rc" -eq 0
assert test ! -s "$PICK_CALLS"
assert grep -Fq 'grok-pick.png' <<<"$(plan_cmd grok pick)"
assert_fails "$(plan_cmd grok pick)" --account
assert_fails "$(plan_cmd gemini pick)" --account
assert_fails "$(plan_cmd codex pick)" --account

: >"$CALLS"
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors grok --accounts pick || rc=$?
assert test "$rc" -eq 0
assert_fails "$(cat "$CALLS")" 'ARG=--account'
assert grep -Fq $'grok\trouted\tok' "$DEST/fanout.tsv"
assert grep -Fq "grok-pick.png" "$DEST/fanout.tsv"

# --- --video without --ref is a usage error before planning -----------------
: >"$CALLS"
rc=0
fanout --dest-dir "$DEST" --prompt 'motion' --dry-run --video || rc=$?
assert test "$rc" -eq 2
assert grep -Fq -- '--video requires --ref' "$FANOUT_ERR"
assert test ! -s "$CALLS"

# --- --aspect auto: pass-through where listed, else drop --------------------
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --dry-run --aspect auto || rc=$?
assert test "$rc" -eq 0
assert grep -Fq -- '--aspect auto' <<<"$(plan_cmd grok delta)"
assert_fails "$(plan_reason grok delta)" 'aspect auto'
assert grep -Fq 'aspect auto dropped (vendor default)' <<<"$(plan_reason gemini gamma)"
assert_fails "$(plan_cmd gemini gamma)" --aspect
assert grep -Fq 'aspect auto dropped (vendor default)' <<<"$(plan_reason codex alpha)"
assert_fails "$(plan_cmd codex alpha)" --aspect
assert_fails "$(plan_cmd codex alpha)" 'aspect ratio auto'

# --- --dry-run writes nothing under dest-dir --------------------------------
DRYDEST="$WORK/drydest"
mkdir -p "$DRYDEST"
printf 'canary\n' >"$DRYDEST/canary"
rc=0
fanout --dest-dir "$DRYDEST" --prompt 'badge' --dry-run --vendors grok || rc=$?
assert test "$rc" -eq 0
assert test ! -e "$DRYDEST/fanout.tsv"
assert test -f "$DRYDEST/canary"
assert test "$(find "$DRYDEST" -type f | wc -l | tr -d ' ')" = 1

# --- dest paths with spaces survive kv_last ---------------------------------
SPDEST="$WORK/dest with spaces"
mkdir -p "$SPDEST"
rc=0
fanout --dest-dir "$SPDEST" --prompt 'badge' --vendors grok --accounts all || rc=$?
assert test "$rc" -eq 0
sp_row=$(awk -F'\t' '$1=="grok" && $2=="delta" {print; exit}' "$SPDEST/fanout.tsv")
assert test "$(printf '%s' "$sp_row" | awk -F'\t' '{print $5}')" = "$SPDEST/grok-delta.png"

# --- login-needed roster rows are skipped, not launched ---------------------
cat >"$FAKE_LIST/grokb" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = list ] || exit 2
printf 'ghost: login needed\ndelta: Logged in\n'
EOF
chmod +x "$FAKE_LIST/grokb"
cat >"$FAKE_LIST/geminib" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = list ] || exit 2
printf 'absent: Not logged in\ngamma: Logged in\n'
EOF
chmod +x "$FAKE_LIST/geminib"
: >"$CALLS"
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors grok,gemini || rc=$?
assert test "$rc" -eq 0
assert grep -Fq $'grok\tghost\tskipped\tlogin needed' "$DEST/fanout.tsv"
assert grep -Fq $'gemini\tabsent\tskipped\tlogin needed' "$DEST/fanout.tsv"
assert grep -Fq $'grok\tdelta\tok' "$DEST/fanout.tsv"
assert_fails "$(cat "$CALLS")" 'ARG=ghost'
assert_fails "$(cat "$CALLS")" 'ARG=absent'

# --- STALE line is the value, not a temp path --------------------------------
cat >"$FAKE_LIST/grokb" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = list ] || exit 2
printf 'staleacct: Logged in\n'
EOF
chmod +x "$FAKE_LIST/grokb"
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors grok --accounts all || rc=$?
assert test "$rc" -eq 0
stale_line=$(grep '^STALE:' "$FANOUT_OUT" || true)
assert grep -Fq 'STALE: grok staleacct model_caps=stale' <<<"$stale_line"
assert_fails "$stale_line" '/image-fanout.'

# --- fanout.state.json: the task row's live cells, rewritten on every change ---
cat >"$FAKE_LIST/grokb" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = list ] || exit 2
printf 'delta: Logged in\nslow: Logged in\nbroken: Logged in\nwalled: Logged in\n'
EOF
chmod +x "$FAKE_LIST/grokb"
cat >"$FAKE_BIN/grok-image-slow" <<'EOF'
#!/usr/bin/env bash
case " $* " in *' --account slow '*) while [ ! -e "${FANOUT_RELEASE:?}" ]; do sleep 0.05; done ;; esac
exec "$(dirname "$0")/fake-image" "$@"
EOF
chmod +x "$FAKE_BIN/grok-image-slow"
rm "$FAKE_BIN/grok-image"
ln -s "$FAKE_BIN/grok-image-slow" "$FAKE_BIN/grok-image"
STATE_DEST="$WORK/state dest"
mkdir -p "$STATE_DEST"
state_cells() { jq -c '[.kind, [.cells[] | [.vendor, .account, .status, .exit]]]' "$STATE_DEST/fanout.state.json" 2>/dev/null; }
env IMAGE_FANOUT_BIN_DIR="$FAKE_BIN" IMAGE_FANOUT_LISTER_DIR="$FAKE_LIST" FANOUT_CALLS="$CALLS" PICK_CALLS="$PICK_CALLS" \
  FANOUT_RELEASE="$WORK/release" bash "$SCRIPT" --dest-dir "$STATE_DEST" --prompt 'badge' --vendors grok \
  >"$FANOUT_OUT" 2>"$FANOUT_ERR" &
fanout_pid=$!
state_live='["image",[["grok","delta","done",0],["grok","slow","running",null],["grok","broken","failed",1],["grok","walled","failed",3]]]'
for _ in $(seq 1 200); do
  [ "$(state_cells)" = "$state_live" ] && break
  sleep 0.05
done
assert test "$(state_cells)" = "$state_live"
: >"$WORK/release"
wait "$fanout_pid"
assert test "$(state_cells)" = '["image",[["grok","delta","done",0],["grok","slow","done",0],["grok","broken","failed",1],["grok","walled","failed",3]]]'
assert test "$(find "$STATE_DEST" -name 'fanout.state.json.tmp*' | wc -l | tr -d ' ')" = 0

# A cell holding for a parallel slot has no process yet: `waiting`, never `running`, so the row
# does not count queued accounts as work in flight.
rm -f "$STATE_DEST/fanout.state.json" "$WORK/release"
env IMAGE_FANOUT_BIN_DIR="$FAKE_BIN" IMAGE_FANOUT_LISTER_DIR="$FAKE_LIST" FANOUT_CALLS="$CALLS" PICK_CALLS="$PICK_CALLS" \
  FANOUT_RELEASE="$WORK/release" bash "$SCRIPT" --dest-dir "$STATE_DEST" --prompt 'badge' --vendors grok \
  --max-parallel 1 >"$FANOUT_OUT" 2>"$FANOUT_ERR" &
fanout_pid=$!
state_queued='["image",[["grok","delta","done",0],["grok","slow","running",null],["grok","broken","waiting",null]]]'
for _ in $(seq 1 200); do
  [ "$(state_cells)" = "$state_queued" ] && break
  sleep 0.05
done
assert test "$(state_cells)" = "$state_queued"
: >"$WORK/release"
wait "$fanout_pid"
assert test "$(state_cells)" = '["image",[["grok","delta","done",0],["grok","slow","done",0],["grok","broken","failed",1],["grok","walled","failed",3]]]'
rm -f "$STATE_DEST/fanout.state.json"
rc=0
fanout --dest-dir "$STATE_DEST" --prompt 'motion' --video --ref "$WORK/refs/r1.png" --vendors grok --dry-run || rc=$?
assert test "$rc" -eq 0
assert test ! -e "$STATE_DEST/fanout.state.json"

# --- a manifest kind with a model and no short name is stale caps -------------
CAPS_ROOT="$WORK/caps-root"
mkdir -p "$CAPS_ROOT/share/image-caps"
jq 'del(.short.video)' "$ROOT/share/image-caps/grok.json" >"$CAPS_ROOT/share/image-caps/grok.json"
# shellcheck source=share/image-caps.sh
. "$ROOT/share/image-caps.sh"
video_model=$(jq -r '.model.video' "$ROOT/share/image-caps/grok.json")
assert test "$(image_caps_model_check "$CAPS_ROOT" grok video "$video_model")" = "model=$video_model model_caps=stale short=missing"
assert test "$(image_caps_model_check "$CAPS_ROOT" grok video '')" = 'model=unknown model_caps=stale short=missing'
assert test "$(image_caps_model_check "$ROOT" grok video "$video_model")" = "model=$video_model model_caps=fresh"
for caps_vendor in codex gemini grok; do
  assert jq -e '[.model | to_entries[] | select(.value != null) | .key] - (.short | keys) == []' \
    "$ROOT/share/image-caps/$caps_vendor.json" >/dev/null
done

printf 'PASS: %s asserts; dry-run plans/adaptations (refs, aspect auto, Codex prose, size, video skip/ref), tsv columns, dest spaces, login-needed skip, dry-run dest-dir untouched, exit 0/3/1/2, STALE value, pick without --account, live fanout.state.json cells (none on dry-run, a queued cell waiting), short-name caps check\n' "$asserts"
