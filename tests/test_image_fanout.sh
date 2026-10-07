#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/image-fanout"
WORK="$(mktemp -d)"
export IMAGE_LEG_LOG="$WORK/image-legs.jsonl" VENDOR_CLI_UPDATE_STATE_DIR="$WORK/vendor-cli-update"
fanout_work() { (. "$ROOT/share/image-leg.sh"; f=$(image_leg_work_file fanout "$1" x); printf '%s\n' "${f%/*}"); }
# Every `worker_model_*` call shells `grokb models`: the fixture list answers it, and the
# `grok` CLI behind it can never be reached (row `cu`).
export GROKB_CACHE_DIR="$WORK/grokb-cache"
. "$ROOT/tests/fixtures/grokb-models.sh"
trap 'pkill -f "$WORK/" 2>/dev/null; rm -rf "$WORK"' EXIT
asserts=0
fail() { echo "FAIL: $*" >&2; [ -z "${FANOUT_ERR:-}" ] || sed -n '1,80p' "$FANOUT_ERR" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }

FAKE_BIN="$WORK/bin"
FAKE_LIST="$WORK/listers"
FAKE_SYS="$WORK/sys"
DEST="$WORK/out"
CALLS="$WORK/calls"
PICK_CALLS="$WORK/picks"
FANOUT_OUT="$WORK/fanout.out"
FANOUT_ERR="$WORK/fanout.err"
CHILDREN="$WORK/children"
LIVE="$WORK/live"
mkdir -p "$FAKE_BIN" "$FAKE_LIST" "$FAKE_SYS" "$DEST" "$WORK/refs" "$CHILDREN" "$LIVE"
: >"$CALLS"
: >"$PICK_CALLS"

for i in 1 2 3 4 5; do
  printf 'ref-%s\n' "$i" >"$WORK/refs/r$i.png"
done

# The memory reader's inputs: vm_stat pages (16 KB each, so MB * 64) and the pressure level.
MEM_MB="$WORK/mem-mb"
PRESSURE="$WORK/pressure"
printf '65536\n' >"$MEM_MB"
printf '1\n' >"$PRESSURE"
cat >"$FAKE_SYS/vm_stat" <<EOF
#!/usr/bin/env bash
printf 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\n'
printf 'Pages free:                               %s.\n' "\$((\$(cat "$MEM_MB") * 64))"
printf 'Pages inactive:                           0.\n'
printf 'Pages speculative:                        0.\n'
EOF
cat >"$FAKE_SYS/sysctl" <<EOF
#!/usr/bin/env bash
if [ "\$*" = '-n kern.memorystatus_vm_pressure_level' ]; then cat "$PRESSURE"; exit 0; fi
exec /usr/sbin/sysctl "\$@"
EOF
chmod +x "$FAKE_SYS/vm_stat" "$FAKE_SYS/sysctl"
# A copied system binary is killed by code signing; a symlink runs and carries the Chrome-like name.
ln -s /bin/sleep "$FAKE_BIN/chromefake"

# Account names pick the fake's behaviour: walled 3, disabled 4, broken 1, busy 5 (busyonce: the
# first call only), hang/stubborn start a child and never finish (stubborn ignores TERM), slow* and
# fast* sleep before delivering, chromey starts a process named like Chrome and stays up (chromeown
# in a session of its own, as Playwright starts Chrome; chromeorphan's ignores TERM and outlives
# the wrapper), webwall is a usage limit on every route but --route cli, lingers ignores TERM on
# its first call only.
cat >"$FAKE_BIN/fake-image" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'BIN=%s\n' "$(basename "$0")"
  printf 'ARG=%s\n' "$@"
  printf 'SCHED=%s\n' "${IMAGE_LEG_SCHEDULER:-}"
} >>"${FANOUT_CALLS:?}"
dest=''; account=''; count=1; route=''
own_session() { exec perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or exit 127' -- "$@"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dest) dest=$2; shift 2 ;;
    --account) account=$2; shift 2 ;;
    --count) count=$2; shift 2 ;;
    --route) route=$2; shift 2 ;;
    --prompt|--ref|--aspect|--size|--duration|--edit|--lock-wait) shift 2 ;;
    --transparent) shift ;;
    *) shift ;;
  esac
done
printf 'START %s %s %s\n' "${account:-routed}" "$(perl -MTime::HiRes=time -e 'printf "%.3f", time')" "${IMAGE_JOB_ID:-}" >>"$FANOUT_CALLS"
if [ -n "${FANOUT_LIVE:-}" ] && [ -n "$account" ]; then
  mkdir "$FANOUT_LIVE/$account" 2>/dev/null || printf 'OVERLAP %s\n' "$account" >>"$FANOUT_CALLS"
  trap 'rmdir "$FANOUT_LIVE/$account" 2>/dev/null || true' EXIT
fi
rc=0
case "$account" in
  walled) rc=3 ;;
  disabled) rc=4 ;;
  broken) rc=1 ;;
  busy) rc=5 ;;
  busyonce) [ -e "$FANOUT_CHILDREN/busyonce.seen" ] || { : >"$FANOUT_CHILDREN/busyonce.seen"; rc=5; } ;;
  hang|stubborn)
    [ "$account" = hang ] || trap '' TERM
    sleep 300 &
    printf '%s\n' "$!" >"$FANOUT_CHILDREN/$account.pid"
    wait
    ;;
  slow*|fast*) sleep "${FANOUT_SLEEP:-0.5}" ;;
  chromey) "$(dirname "$0")/chromefake" 8 & sleep 5 ;;
  chromeown) own_session "$(dirname "$0")/chromefake" 8 & sleep 5 ;;
  chromeorphan)
    ( trap '' TERM; own_session "$(dirname "$0")/chromefake" 300 ) &
    printf '%s\n' "$!" >"$FANOUT_CHILDREN/chromeorphan.pid"
    wait
    ;;
  webwall) [ "$route" = cli ] || rc=3 ;;
  flagged)
    printf 'fake: Flow flagged this account (PUBLIC_ERROR_UNUSUAL_ACTIVITY); nothing was charged\nFAKE_ACCOUNT_FLAGGED\n' >&2
    exit 3
    ;;
  lingers)
    if [ ! -e "$FANOUT_CHILDREN/lingers.seen" ]; then
      : >"$FANOUT_CHILDREN/lingers.seen"
      trap '' TERM
      sleep 300 &
      wait
    fi
    ;;
esac
if [ "$account" = staleacct ] || [ "${FANOUT_STALE:-}" = 1 ]; then
  printf 'model=x model_caps=stale verified=old\n' >&2
  printf 'caps=stale cli=9.9.9 verified=0.0.1\n' >&2
fi
[ -n "$account" ] || account=routed
if [ "$rc" -eq 3 ]; then printf 'USAGE_LIMIT\n' >&2; exit 3; fi
if [ "$rc" -eq 4 ]; then printf 'out of pool\n' >&2; exit 4; fi
if [ "$rc" -eq 5 ]; then printf 'ACCOUNT_BUSY account=%s\n' "$account" >&2; exit 5; fi
if [ "$rc" -ne 0 ]; then printf 'failed\n' >&2; exit "$rc"; fi
mkdir -p "$(dirname "$dest")"
: >"$dest"
printf 'job=%s\nroute=cli\nfallback_from=web\nfallback_reason=test\nphases={"lock":0.1,"saved":1.2}\n' "${IMAGE_JOB_ID:-none}"
printf 'composite=skipped reason=several-inputs\n'
printf 'dest=%s\nsize=64x64\nformat=png\naccount=%s\nsession=sess-1\nmodel=test-model model_caps=fresh\ncaps=fresh\n' \
  "$dest" "$account"
for ((i = 2; i <= count; i++)); do
  : >"${dest%.*}-$i.${dest##*.}"
  printf 'variant=%s size=32x32 session=sess-%s\n' "${dest%.*}-$i.${dest##*.}" "$i"
done
EOF
chmod +x "$FAKE_BIN/fake-image"
ln -s "$FAKE_BIN/fake-image" "$FAKE_BIN/codex-image"
ln -s "$FAKE_BIN/fake-image" "$FAKE_BIN/gemini-image"
ln -s "$FAKE_BIN/fake-image" "$FAKE_BIN/grok-image"
ln -s "$FAKE_BIN/fake-image" "$FAKE_BIN/grok-video"
ln -s "$FAKE_BIN/fake-image" "$FAKE_BIN/gemini-video"

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

# Rosters per manifest: codex web and gemini flow list JSON from their engines, grok's CLI pool lines.
set_roster() { # lister-name body
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$FAKE_LIST/$1"
  chmod +x "$FAKE_LIST/$1"
}
set_roster chatgpt-web '[ "${1:-}" = accounts ] || exit 2
printf "%s\n" "{\"ok\":true,\"accounts\":[{\"account\":\"alpha\",\"login\":true,\"walled_until\":null},{\"account\":\"beta\",\"login\":false,\"walled_until\":null}]}"'
set_roster gemini-web '[ "${1:-}" = accounts ] || exit 2
printf "%s\n" "{\"ok\":true,\"accounts\":[{\"account\":\"gamma\",\"roster\":true,\"login\":true,\"walled_until\":null}]}"'
grok_roster() { set_roster grokb "[ \"\${1:-}\" = list ] || exit 2
printf '$1'"; }
grok_roster 'delta: Logged in\nstaleacct: Logged in\n'

FANOUT_ENV=(IMAGE_FANOUT_BIN_DIR="$FAKE_BIN" IMAGE_FANOUT_LISTER_DIR="$FAKE_LIST" PATH="$FAKE_SYS:$PATH"
  FANOUT_CALLS="$CALLS" PICK_CALLS="$PICK_CALLS" FANOUT_CHILDREN="$CHILDREN"
  IMAGE_FANOUT_LAUNCH_GAP_MS=0 IMAGE_FANOUT_MEM_POLL_MS=100 HARNESS_HOLDS_DIR="$WORK/harness/holds" HARNESS_WAITS_DIR="$WORK/harness/waits")
fanout() {
  env "${FANOUT_ENV[@]}" bash "$SCRIPT" "$@" >"$FANOUT_OUT" 2>"$FANOUT_ERR"
}
fanout_bg() { # extra-env... -- args...
  local -a extra=()
  while [ "$1" != -- ]; do extra+=("$1"); shift; done
  shift
  env "${FANOUT_ENV[@]}" ${extra[@]+"${extra[@]}"} bash "$SCRIPT" "$@" >"$FANOUT_OUT" 2>"$FANOUT_ERR" &
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
tsv_col() { # file vendor account column -> first matching row's column
  awk -F'\t' -v v="$2" -v a="$3" -v c="$4" '$1 == v && $2 == a { print $c; exit }' "$1"
}
dest_col() { # file dest column -> that dest's row column
  awk -F'\t' -v f="$2" -v c="$3" '$5 == f { print $c; exit }' "$1"
}
wait_for() { # seconds command...
  local tries=$(( $1 * 20 ))
  shift
  while [ "$tries" -gt 0 ]; do
    "$@" && return 0
    sleep 0.05
    tries=$((tries - 1))
  done
  return 1
}

REFS=(
  --ref "$WORK/refs/r1.png"
  --ref "$WORK/refs/r2.png"
  --ref "$WORK/refs/r3.png"
  --ref "$WORK/refs/r4.png"
  --ref "$WORK/refs/r5.png"
)
GEMINI_MAX=$(jq -r '.refs.max' "$ROOT/share/image-caps/gemini.json")
GEMINI_FLOW_MAX=$(jq -r '.flow_image.refs_max' "$ROOT/share/image-caps/gemini.json")
CODEX_MAX=$(jq -r '.refs.max' "$ROOT/share/image-caps/codex.json")
assert test "$GEMINI_MAX" = 3
assert test "$GEMINI_FLOW_MAX" = 10
assert test "$(jq -r '.routes[0]' "$ROOT/share/image-caps/gemini.json")" = flow
assert test "$CODEX_MAX" = 5

# --- the registry is the vendor list: no vendor name is written into the script ----------
assert test -z "$(grep -nwE 'codex|gemini|grok' "$SCRIPT" || true)"

# --- dry-run: refs truncation per manifest -----------------------------------
# gemini-image runs Flow by default (routes[0]), so its rows take Flow's 10 refs, not the CLI route's 3.
: >"$CALLS"
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --dry-run "${REFS[@]}" || rc=$?
assert test "$rc" -eq 0
assert test ! -s "$CALLS"
assert_fails "$(plan_reason gemini gamma)" 'refs '
gemini_cmd=$(plan_cmd gemini gamma)
assert test "$(grep -o -- '--ref' <<<"$gemini_cmd" | wc -l | tr -d ' ')" -eq 5
codex_cmd=$(plan_cmd codex alpha)
assert test "$(grep -o -- '--ref' <<<"$codex_cmd" | wc -l | tr -d ' ')" -eq 5
reason_cx=$(plan_reason codex alpha)
assert_fails "$reason_cx" 'refs '
# Roster rows from the web engines' JSON: login false is skipped, never launched.
assert grep -Fq $'codex beta\tskipped: login needed' "$FANOUT_OUT"
# Every image job may wait 5 s for its account's lock, then exits 5 and is requeued.
assert grep -Fq -- '--lock-wait 5' <<<"$gemini_cmd"
assert grep -Eq '^IMAGE_JOB_ID=fanout-[0-9TZ]+-[0-9]+-1-[0-9]+ ' <<<"$gemini_cmd"
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --dry-run "${REFS[@]}" "${REFS[@]}" --ref "$WORK/refs/r1.png" || rc=$?
assert test "$rc" -eq 0
assert grep -Fq 'refs 11→10' <<<"$(plan_reason gemini gamma)"
assert test "$(grep -o -- '--ref' <<<"$(plan_cmd gemini gamma)" | wc -l | tr -d ' ')" -eq "$GEMINI_FLOW_MAX"
# An --edit image is an input too: it takes one of the route's reference slots.
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --dry-run "${REFS[@]}" "${REFS[@]}" --edit "$WORK/refs/r2.png" || rc=$?
assert test "$rc" -eq 0
assert grep -Fq 'refs 10→9' <<<"$(plan_reason gemini gamma)"
assert grep -Fq -- "--edit $WORK/refs/r2.png" <<<"$(plan_cmd gemini gamma)"

# --- dry-run: aspect mapping + Codex prose -----------------------------------
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --dry-run --aspect 20:9 || rc=$?
assert test "$rc" -eq 0
assert grep -Fq 'aspect 20:9→16:9' <<<"$(plan_reason gemini gamma)"
assert grep -Fq -- '--aspect 16:9' <<<"$(plan_cmd gemini gamma)"
assert grep -Fq 'aspect 20:9→16:9' <<<"$(plan_reason grok delta)"
# Flow's five aspects, not the CLI route's seven: 2:3 is a CLI ratio Flow lacks.
for pair in 21:9=16:9 2:3=3:4; do
  rc=0
  fanout --dest-dir "$DEST" --prompt 'badge' --dry-run --aspect "${pair%=*}" || rc=$?
  assert test "$rc" -eq 0
  assert grep -Fq "aspect ${pair%=*}→${pair#*=}" <<<"$(plan_reason gemini gamma)"
  assert grep -Fq -- "--aspect ${pair#*=}" <<<"$(plan_cmd gemini gamma)"
done
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --dry-run --aspect 20:9 || rc=$?
assert grep -Fq -- '--aspect 16:9' <<<"$(plan_cmd grok delta)"
cx_reason=$(plan_reason codex alpha)
assert grep -Fq 'aspect 20:9→prompt' <<<"$cx_reason"
cx_cmd=$(plan_cmd codex alpha)
assert grep -Fq -- '--aspect 20:9' <<<"$cx_cmd"
assert_fails "$cx_cmd" 'aspect ratio'

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
assert grep -Fq -- '--aspect 16:9' <<<"$(plan_cmd codex alpha)"

# --- dry-run: video skips vendors without video ------------------------------
rc=0
fanout --dest-dir "$DEST" --prompt 'motion' --dry-run --video --ref "$WORK/refs/r1.png" || rc=$?
assert test "$rc" -eq 0
assert grep -Fq 'skipped: video unsupported' "$FANOUT_OUT"
assert grep -Fq $'codex -\tskipped: video unsupported' "$FANOUT_OUT"
assert_fails grep -Fq $'gemini -\tskipped: video unsupported' "$FANOUT_OUT"
assert grep -Fq 'gemini-video' <<<"$(plan_cmd gemini gamma)"
assert grep -Fq '.mp4' <<<"$(plan_cmd gemini gamma)"
assert grep -Fq 'grok-video' <<<"$(plan_cmd grok delta)"
assert grep -Fq '.mp4' <<<"$(plan_cmd grok delta)"
assert_fails "$(plan_cmd grok delta)" grok-image
assert grep -Fq -- '--lock-wait 5' <<<"$(plan_cmd grok delta)"
assert grep -Fq -- '--lock-wait 5' <<<"$(plan_cmd gemini gamma)"
# With several references gemini keeps to its listed lengths; grok's reference range takes any second in it.
rc=0
fanout --dest-dir "$DEST" --prompt 'motion' --dry-run --video --duration 5 --ref "$WORK/refs/r1.png" --ref "$WORK/refs/r2.png" || rc=$?
assert test "$rc" -eq 0
assert grep -Fq 'duration 5→4' <<<"$(plan_reason gemini gamma)"
assert grep -Fq -- '--duration 4' <<<"$(plan_cmd gemini gamma)"
assert_fails "$(plan_reason grok delta)" 'duration 5→'
assert_fails "$(cat "$FANOUT_OUT")" codex-image
assert_fails "$(cat "$FANOUT_OUT")" gemini-image
# Video never gets spares or packing: every take spends credits.
rc=0
fanout --dest-dir "$DEST" --prompt 'motion' --dry-run --video --ref "$WORK/refs/r1.png" --vendors gemini --takes 2 --pack 4 || rc=$?
assert test "$rc" -eq 0
assert test -n "$(plan_cmd gemini take2)"
assert test -z "$(plan_cmd gemini take3)"
assert_fails "$(cat "$FANOUT_OUT")" --count
assert_fails "$(cat "$FANOUT_OUT")" $'\tspare'

# --- live run: tsv columns, exit 0 ------------------------------------------
: >"$CALLS"
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors grok --accounts all || rc=$?
assert test "$rc" -eq 0
tsv="$(fanout_work "$DEST")/fanout.tsv"
assert test -f "$tsv"
assert test "$(head -n1 "$tsv")" = $'vendor\taccount\tstatus\treason\tdest\tsize\tsession\tmodel\tmodel_caps\tcaps\tjob\troute\tfallback_from\tphases\tcomposite'
delta_row=$(awk -F'\t' '$1=="grok" && $2=="delta" {print; exit}' "$tsv")
assert test "$(printf '%s' "$delta_row" | awk -F'\t' '{print $3}')" = ok
assert test "$(printf '%s' "$delta_row" | awk -F'\t' '{print $7}')" = sess-1
assert test "$(printf '%s' "$delta_row" | awk -F'\t' '{print $8}')" = test-model
assert test "$(printf '%s' "$delta_row" | awk -F'\t' '{print $9}')" = fresh
assert test "$(printf '%s' "$delta_row" | awk -F'\t' '{print $10}')" = fresh
# The vendor's own job=, route=, fallback_from=, phases= and composite= lines ride in the row.
assert grep -Eq '^fanout-[0-9TZ]+-[0-9]+-1-[12]$' <<<"$(printf '%s' "$delta_row" | awk -F'\t' '{print $11}')"
assert test "$(printf '%s' "$delta_row" | awk -F'\t' '{print $12}')" = cli
assert test "$(printf '%s' "$delta_row" | awk -F'\t' '{print $13}')" = web
assert test "$(printf '%s' "$delta_row" | awk -F'\t' '{print $14}')" = '{"lock":0.1,"saved":1.2}'
assert test "$(printf '%s' "$delta_row" | awk -F'\t' '{print $15}')" = 'skipped reason=several-inputs'
assert grep -Eq '^START delta [0-9.]+ fanout-[0-9TZ]+-[0-9]+-1-[12]$' "$CALLS"
assert grep -Fq 'ok=' "$FANOUT_OUT"
assert grep -Eq '^ok=[1-9] skipped=[0-9]+ usage_limit=[0-9]+ failed=[0-9]+$' "$FANOUT_OUT"

# --- STALE surfacing ---------------------------------------------------------
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors grok --accounts all || rc=$?
assert test "$rc" -eq 0
assert grep -Fq 'STALE: grok staleacct' "$FANOUT_OUT"

# --- exit 3: every attempted row is a usage limit ---------------------------
grok_roster 'walled: Logged in\n'
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors grok || rc=$?
assert test "$rc" -eq 3
assert grep -Fq 'usage_limit' "$(fanout_work "$DEST")/fanout.tsv"
assert grep -Fq 'ok=0' "$FANOUT_OUT"

# --- exit 1: a hard failure --------------------------------------------------
grok_roster 'broken: Logged in\n'
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors grok || rc=$?
assert test "$rc" -eq 1
assert grep -Fq 'failed' "$(fanout_work "$DEST")/fanout.tsv"
# The row's stderr survives beside the table and its last line rides in the reason column.
assert test -s "$(fanout_work "$DEST")/grok-broken.stderr"
assert grep -Fq 'exit 1; failed' "$(fanout_work "$DEST")/fanout.tsv"

# pool-disabled is skipped, not failed
grok_roster 'disabled: Logged in (out of pool)\n'
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors grok || rc=$?
assert test "$rc" -eq 1
assert grep -Fq $'grok\tdisabled\tskipped' "$(fanout_work "$DEST")/fanout.tsv"
assert grep -Fq 'out of pool' "$(fanout_work "$DEST")/fanout.tsv"
assert_fails "$(cat "$CALLS")" 'ARG=disabled'

# --takes never hands a take to an out-of-pool account while a pooled one is free
grok_roster 'disabled: Logged in (out of pool)\ndelta: Logged in\n'
: >"$CALLS"
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors grok --takes 1 || rc=$?
assert test "$rc" -eq 0
assert grep -Fq $'grok\tdelta\tok' "$(fanout_work "$DEST")/fanout.tsv"
assert_fails "$(cat "$CALLS")" 'ARG=disabled'

# restore grok lister for pick
grok_roster 'delta: Logged in\n'

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
assert grep -Fq $'grok\trouted\tok' "$(fanout_work "$DEST")/fanout.tsv"
assert grep -Fq "grok-pick.png" "$(fanout_work "$DEST")/fanout.tsv"

# --- --takes N: N takes plus the manifest's spares, each with a dest of its own ----------
grok_roster 'delta: Logged in\nepsilon: Logged in\n'
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors grok --takes 3 --dry-run || rc=$?
assert test "$rc" -eq 0
# grok spares.image {ratio 0.25, min 1}: 3 takes launch 3 + max(1, ceil(0.75)) = 4.
assert grep -Fq 'grok-delta.png' <<<"$(plan_cmd grok take1)"
assert grep -Fq 'grok-epsilon-2.png' <<<"$(plan_cmd grok take2)"
assert grep -Fq 'grok-delta-3.png' <<<"$(plan_cmd grok take3)"
assert grep -Fq 'grok-epsilon-4.png' <<<"$(plan_cmd grok take4)"
assert grep -Fq $'grok take4\t\tspare' "$FANOUT_OUT"
assert_fails "$(grep -F 'grok take3' "$FANOUT_OUT")" spare
assert test -z "$(plan_cmd grok take5)"
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors grok --takes 3 --spare 0 --dry-run || rc=$?
assert test "$rc" -eq 0
assert test -z "$(plan_cmd grok take4)"
# Each take has its own job id: the spare's file can never be another take's.
assert test "$(grep -oE 'IMAGE_JOB_ID=[^ ]+' "$FANOUT_OUT" | sort -u | wc -l | tr -d ' ')" -eq 3
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --accounts pick --takes 2 --dry-run || rc=$?
assert test "$rc" -eq 2
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --takes 0 --dry-run || rc=$?
assert test "$rc" -eq 2
for bad in '--pack 5' '--pack 0' '--spare -1' '--vendors nope' '--vendors grok,nope'; do
  rc=0
  # shellcheck disable=SC2086
  fanout --dest-dir "$DEST" --prompt 'badge' --dry-run $bad || rc=$?
  assert test "$rc" -eq 2
done
: >"$CALLS"
rc=0
fanout --dest-dir "$DEST" --prompt badge --accounts "" || rc=$?
assert test "$rc" -eq 2
assert test ! -s "$CALLS"

# --- per-account scheduling: one live job per account; takes queue for a free one -------
grok_roster 'slowa: Logged in\n'
: >"$CALLS"
rc=0
FANOUT_ENV+=(FANOUT_LIVE="$LIVE" FANOUT_SLEEP=0.3)
fanout --dest-dir "$DEST" --prompt 'badge' --vendors grok --takes 3 --spare 0 || rc=$?
assert test "$rc" -eq 0
assert test "$(grep -c '^START slowa ' "$CALLS")" -eq 3
assert_fails "$(cat "$CALLS")" OVERLAP
assert test "$(grep -c $'^grok\tslowa\tok\t' "$(fanout_work "$DEST")/fanout.tsv")" -eq 3
for f in grok-slowa.png grok-slowa-2.png grok-slowa-3.png; do
  assert test "$(dest_col "$(fanout_work "$DEST")/fanout.tsv" "$DEST/$f" 3)" = ok
done
assert test "$(grep -c '^ARG=--lock-wait$' "$CALLS")" -eq 3
# Two accounts, four takes: both accounts busy at once, never one account twice.
grok_roster 'slowa: Logged in\nslowb: Logged in\n'
: >"$CALLS"
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors grok --takes 4 --spare 0 || rc=$?
assert test "$rc" -eq 0
assert test "$(grep -c '^START slowa ' "$CALLS")" -eq 2
assert test "$(grep -c '^START slowb ' "$CALLS")" -eq 2
assert_fails "$(cat "$CALLS")" OVERLAP
assert grep -Fq 'ok=4 ' "$FANOUT_OUT"

# --- exit 5: a busy account frees its slot and the take moves to another idle account ------
grok_roster 'busy: Logged in\nfasta: Logged in\n'
: >"$CALLS"
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors grok --takes 1 --spare 0 || rc=$?
assert test "$rc" -eq 0
assert test "$(grep -c '^START busy ' "$CALLS")" -eq 1
assert grep -Fq $'grok\tfasta\tok' "$(fanout_work "$DEST")/fanout.tsv"
assert grep -Fq 'requeued: busy busy' <<<"$(tsv_col "$(fanout_work "$DEST")/fanout.tsv" grok fasta 4)"
# A pinned account that was busy is retried on itself once its cooldown passes.
grok_roster 'busyonce: Logged in\n'
rm -f "$CHILDREN/busyonce.seen"
: >"$CALLS"
rc=0
FANOUT_ENV+=(IMAGE_FANOUT_BUSY_RETRY_MS=200)
fanout --dest-dir "$DEST" --prompt 'badge' --vendors grok || rc=$?
assert test "$rc" -eq 0
assert test "$(grep -c '^START busyonce ' "$CALLS")" -eq 2
assert grep -Fq $'grok\tbusyonce\tok' "$(fanout_work "$DEST")/fanout.tsv"
# Busy past the give-up window is a failure, never an endless loop.
grok_roster 'busy: Logged in\n'
rc=0
env "${FANOUT_ENV[@]}" IMAGE_FANOUT_BUSY_GIVEUP_MS=500 bash "$SCRIPT" --dest-dir "$DEST" --prompt 'badge' --vendors grok \
  >"$FANOUT_OUT" 2>"$FANOUT_ERR" || rc=$?
assert test "$rc" -eq 1
assert grep -Fq 'exit 5 (account busy)' "$(fanout_work "$DEST")/fanout.tsv"
# A usage limit in the pool moves the take as well; the walled account is not tried again.
grok_roster 'walled: Logged in\nfasta: Logged in\n'
: >"$CALLS"
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors grok --takes 2 --spare 0 || rc=$?
assert test "$rc" -eq 0
assert test "$(grep -c '^START walled ' "$CALLS")" -eq 1
assert test "$(grep -c $'^grok\tfasta\tok' "$(fanout_work "$DEST")/fanout.tsv")" -eq 2
assert grep -Fq 'moved from walled after a usage limit' "$(fanout_work "$DEST")/fanout.tsv"

# --- spares: return once N takes are delivered; the rest end by process group, no orphan ----------
for straggler in hang stubborn; do
  grok_roster "fasta: Logged in\nfastb: Logged in\n$straggler: Logged in\n"
  rm -f "$CHILDREN/$straggler.pid"
  : >"$CALLS"
  rc=0
  started=$SECONDS
  env "${FANOUT_ENV[@]}" IMAGE_FANOUT_KILL_WAIT_MS=500 bash "$SCRIPT" --dest-dir "$DEST" --prompt 'badge' --vendors grok \
    --takes 2 >"$FANOUT_OUT" 2>"$FANOUT_ERR" || rc=$?
  assert test "$rc" -eq 0
  assert test $((SECONDS - started)) -lt 20
  assert test "$(grep -c "^START $straggler " "$CALLS")" -eq 1
  assert test "$(grep -c $'\tok\t' "$(fanout_work "$DEST")/fanout.tsv")" -eq 2
  assert grep -Fq $'grok\t'"$straggler"$'\tspare-cancelled\t' "$(fanout_work "$DEST")/fanout.tsv"
  assert grep -Fq 'spare-cancelled after 2 of 2 takes delivered' "$(fanout_work "$DEST")/fanout.tsv"
  assert grep -Fq 'ok=2 skipped=0 usage_limit=0 failed=0' "$FANOUT_OUT"
  assert test -s "$CHILDREN/$straggler.pid"
  child=$(cat "$CHILDREN/$straggler.pid")
  assert wait_for 5 eval "! kill -0 $child 2>/dev/null"
  assert test "$(jq -r '.cells[] | select(.status == "spare-cancelled") | .account' "$(fanout_work "$DEST")/fanout.state.json")" = "$straggler"
done

# --- --jobs: a batch, each line its own request, dest and job id; one table ---------------
grok_roster 'delta: Logged in\nepsilon: Logged in\n'
JOBS_DIR="$WORK/jobs out"
mkdir -p "$JOBS_DIR"
jq -cn --arg d "$JOBS_DIR" --arg r "$WORK/refs/r1.png" '
  {prompt: "a cat", dest: ($d + "/cat.png"), vendor: "grok", takes: 1},
  {prompt: "a dog", dest: ($d + "/dog.png"), vendor: "grok", account: "epsilon", takes: 2, refs: [$r], aspect: "16:9"},
  {prompt: "a cow", dest: ($d + "/cow.png"), vendor: "grok,gemini", transparent: true}' >"$WORK/jobs.jsonl"
: >"$CALLS"
rc=0
fanout --dest-dir "$DEST" --jobs "$WORK/jobs.jsonl" --spare 0 || rc=$?
assert test "$rc" -eq 0
jt="$(fanout_work "$DEST")/fanout.tsv"
for f in cat.png dog.png dog-2.png cow-grok.png cow-gemini.png; do
  assert test -e "$JOBS_DIR/$f"
  assert test "$(dest_col "$jt" "$JOBS_DIR/$f" 3)" = ok
done
assert test "$(grep -c $'\tok\t' "$jt")" -eq 5
assert test "$(grep -c '^START epsilon ' "$CALLS")" -ge 2
assert test "$(dest_col "$jt" "$JOBS_DIR/dog-2.png" 2)" = epsilon
assert grep -Eq -- '-1-1$' <<<"$(dest_col "$jt" "$JOBS_DIR/cat.png" 11)"
assert grep -Eq -- '-2-2$' <<<"$(dest_col "$jt" "$JOBS_DIR/dog-2.png" 11)"
assert test "$(cut -f11 "$jt" | tail -n +2 | sort -u | wc -l | tr -d ' ')" -eq 5
assert test "$(jq '[.cells[] | select(.job and .dest and .request and .take)] | length' "$(fanout_work "$DEST")/fanout.state.json")" -eq 5
assert test "$(jq -r '[.cells[] | .request] | unique | map(tostring) | join(",")' "$(fanout_work "$DEST")/fanout.state.json")" = 1,2,3
assert grep -Fq 'ARG=a dog' "$CALLS"
assert test "$(grep -c '^ARG=--transparent$' "$CALLS")" -eq 2
# The roster is listed once per vendor for the whole batch.
set_roster gemini-web "[ \"\${1:-}\" = accounts ] || exit 2
echo listed >>'$WORK/listed'
printf '%s\n' '{\"ok\":true,\"accounts\":[{\"account\":\"gamma\",\"login\":true}]}'"
jq -cn --arg d "$JOBS_DIR" '{prompt: "a", dest: ($d + "/a.png"), vendor: "gemini", takes: 1},
  {prompt: "b", dest: ($d + "/b.png"), vendor: "gemini", takes: 1},
  {prompt: "c", dest: ($d + "/c.png"), vendor: "gemini", takes: 1}' >"$WORK/three.jsonl"
rc=0
fanout --dest-dir "$DEST" --jobs "$WORK/three.jsonl" --dry-run || rc=$?
assert test "$rc" -eq 0
assert test "$(wc -l <"$WORK/listed" | tr -d ' ')" -eq 1
set_roster gemini-web '[ "${1:-}" = accounts ] || exit 2
printf "%s\n" "{\"ok\":true,\"accounts\":[{\"account\":\"gamma\",\"roster\":true,\"login\":true,\"walled_until\":null}]}"'
printf '{"prompt": "x", "dest": "relative.png"}\n' >"$WORK/bad.jsonl"
rc=0
fanout --dest-dir "$DEST" --jobs "$WORK/bad.jsonl" || rc=$?
assert test "$rc" -eq 2
assert grep -Fq -- '--jobs line 1: dest' "$FANOUT_ERR"
rc=0
fanout --dest-dir "$DEST" --jobs "$WORK/jobs.jsonl" --prompt x || rc=$?
assert test "$rc" -eq 2

# --- --pack: Flow takes of one request share a --count launch; each variant is a take -------
: >"$CALLS"
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors gemini --takes 4 --pack 4 --spare 0 || rc=$?
assert test "$rc" -eq 0
assert test "$(grep -c '^START gamma ' "$CALLS")" -eq 1
assert test "$(grep -A1 -Fx 'ARG=--count' "$CALLS" | tail -n 1)" = 'ARG=4'
for f in gemini-gamma.png gemini-gamma-2.png gemini-gamma-3.png gemini-gamma-4.png; do
  assert test "$(dest_col "$(fanout_work "$DEST")/fanout.tsv" "$DEST/$f" 3)" = ok
done
assert grep -Fq 'ok=4 ' "$FANOUT_OUT"
assert test "$(dest_col "$(fanout_work "$DEST")/fanout.tsv" "$DEST/gemini-gamma-3.png" 7)" = sess-3
assert test "$(dest_col "$(fanout_work "$DEST")/fanout.tsv" "$DEST/gemini-gamma.png" 7)" = sess-1
assert test "$(dest_col "$(fanout_work "$DEST")/fanout.tsv" "$DEST/gemini-gamma.png" 6)" = 64x64
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors gemini,grok --takes 3 --pack 2 --dry-run || rc=$?
assert test "$rc" -eq 0
assert grep -Fq -- '--count 2' <<<"$(plan_cmd gemini take1)"
assert grep -Fq -- '--count 2' <<<"$(plan_cmd gemini take3)"
assert test -z "$(plan_cmd gemini take2)"
assert_fails "$(plan_cmd grok take1)" --count
assert test -n "$(plan_cmd grok take4)"
# A spare that shares a pack: 1 take + 1 spare is one --count 2 launch.
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors gemini --takes 1 --pack 4 --dry-run || rc=$?
assert grep -Fq -- '--count 2' <<<"$(plan_cmd gemini take1)"
# Packing is the default up to the route's largest count; --pack 1 opts out.
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors gemini --takes 6 --spare 0 --dry-run || rc=$?
assert test "$rc" -eq 0
assert grep -Fq -- '--count 4' <<<"$(plan_cmd gemini take1)"
assert grep -Fq -- '--count 2' <<<"$(plan_cmd gemini take5)"
assert test -z "$(plan_cmd gemini take2)"
# ChatGPT's web route packs the same way: three takes are one --count 3 launch (tabs of one browser).
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors codex --takes 3 --spare 0 --dry-run || rc=$?
assert test "$rc" -eq 0
assert grep -Fq -- '--count 3' <<<"$(plan_cmd codex take1)"
assert test -z "$(plan_cmd codex take2)$(plan_cmd codex take3)"
# A ChatGPT spare never rides in the pack: each tab is its own generation the pack would wait for.
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors codex --takes 3 --spare 1 --dry-run || rc=$?
assert test "$rc" -eq 0
assert grep -Fq -- '--count 3' <<<"$(plan_cmd codex take1)"
assert test "$(awk -F'\t' '$1 == "codex take4" { print $3 }' "$FANOUT_OUT")" = spare
assert_fails "$(plan_cmd codex take4)" --count
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors gemini --takes 2 --spare 0 --pack 1 --dry-run || rc=$?
assert test "$rc" -eq 0
assert_fails "$(plan_cmd gemini take1)" --count
assert test -n "$(plan_cmd gemini take2)"

# --- another manifest is another vendor: nothing in the script names the vendors -----------------
CAPS="$WORK/caps"
mkdir -p "$CAPS/share/image-caps"
cp "$ROOT"/share/image-caps/*.json "$CAPS/share/image-caps/"
jq -n '{vendor: "zeta", verified: "2026-10-03", routes: ["cli"], scripts: {image: "zeta-image"},
  rosters: {cli: ["zetab", "list"]}, refs: {max: 2}, aspects: null, exact_size: false,
  transparent: "chroma", video: null}' >"$CAPS/share/image-caps/zeta.json"
ln -s "$FAKE_BIN/fake-image" "$FAKE_BIN/zeta-image"
set_roster zetab '[ "${1:-}" = list ] || exit 2
printf "omega: Logged in\n"'
grok_roster 'delta: Logged in\n'
: >"$CALLS"
rc=0
env "${FANOUT_ENV[@]}" IMAGE_FANOUT_CAPS_ROOT="$CAPS" bash "$SCRIPT" --dest-dir "$DEST" --prompt 'badge' --vendors all \
  "${REFS[@]}" >"$FANOUT_OUT" 2>"$FANOUT_ERR" || rc=$?
assert test "$rc" -eq 0
for row in $'codex\talpha\tok' $'gemini\tgamma\tok' $'grok\tdelta\tok' $'zeta\tomega\tok'; do
  assert grep -Fq "$row" "$(fanout_work "$DEST")/fanout.tsv"
done
assert grep -Fq 'refs 5→2' <<<"$(tsv_col "$(fanout_work "$DEST")/fanout.tsv" zeta omega 4)"
assert grep -Fq 'BIN=zeta-image' "$CALLS"
# No spares entry in its manifest: no spare take.
rc=0
env "${FANOUT_ENV[@]}" IMAGE_FANOUT_CAPS_ROOT="$CAPS" bash "$SCRIPT" --dest-dir "$DEST" --prompt 'badge' --vendors zeta \
  --takes 2 --dry-run >"$FANOUT_OUT" 2>"$FANOUT_ERR" || rc=$?
assert test "$rc" -eq 0
assert test -n "$(plan_cmd zeta take2)"
assert test -z "$(plan_cmd zeta take3)"

# --- memory admission: launches wait for normal pressure and room above the guard ----------
GUARD=$(sed -n 's/^GUARD_AVAIL_MB = \([0-9]*\).*/\1/p' "$ROOT/bin/chat-load")
assert test "$GUARD" -gt 0
MEM_DEST="$WORK/mem dest"
mkdir -p "$MEM_DEST"
for hold in "mem $((GUARD + 1199))" 'pressure 4'; do
  printf '65536\n' >"$MEM_MB"
  printf '1\n' >"$PRESSURE"
  case "$hold" in
    mem*) printf '%s\n' "${hold#mem }" >"$MEM_MB"; why="available $((GUARD + 1199)) MB < $((GUARD + 1200)) MB" ;;
    pressure*) printf '%s\n' "${hold#pressure }" >"$PRESSURE"; why='memory pressure level 4' ;;
  esac
  rm -f "$(fanout_work "$MEM_DEST")/fanout.state.json"
  : >"$CALLS"
  fanout_bg -- --dest-dir "$MEM_DEST" --prompt 'badge' --vendors grok
  fanout_pid=$!
  assert wait_for 5 grep -Fq "holding launches: $why" "$FANOUT_ERR"
  assert test "$(jq -r '.why' "$WORK/harness/holds/image-fanout-$fanout_pid.json")" = "$why"
  sleep 0.5
  assert test ! -s "$CALLS"
  assert test "$(jq -r '.cells[0].status' "$(fanout_work "$MEM_DEST")/fanout.state.json")" = waiting
  printf '%s\n' "$((GUARD + 1200))" >"$MEM_MB"
  printf '1\n' >"$PRESSURE"
  rc=0
  wait "$fanout_pid" || rc=$?
  assert test "$rc" -eq 0
  assert grep -Fq $'grok\tdelta\tok' "$(fanout_work "$MEM_DEST")/fanout.tsv"
  assert test ! -e "$WORK/harness/holds/image-fanout-$fanout_pid.json"
  assert grep -Fq '"class":"image-fanout"' "$WORK/harness/waits/"*.jsonl
done
printf '65536\n' >"$MEM_MB"

# --- launch spacing: the next launch waits for the previous job's Chrome, or the gap -------------
start_gap() { # -> seconds between the first two STARTs
  awk '/^START / { t[++n] = $3 } END { printf "%.3f\n", t[2] - t[1] }' "$CALLS"
}
grok_roster 'fasta: Logged in\nfastb: Logged in\n'
: >"$CALLS"
rc=0
env "${FANOUT_ENV[@]}" IMAGE_FANOUT_LAUNCH_GAP_MS=1500 FANOUT_SLEEP=2 bash "$SCRIPT" --dest-dir "$DEST" --prompt 'badge' \
  --vendors grok >"$FANOUT_OUT" 2>"$FANOUT_ERR" || rc=$?
assert test "$rc" -eq 0
assert awk -v g="$(start_gap)" 'BEGIN { exit !(g >= 1.2) }'
grok_roster 'chromey: Logged in\nfasta: Logged in\n'
: >"$CALLS"
rc=0
env "${FANOUT_ENV[@]}" IMAGE_FANOUT_LAUNCH_GAP_MS=8000 bash "$SCRIPT" --dest-dir "$DEST" --prompt 'badge' \
  --vendors grok >"$FANOUT_OUT" 2>"$FANOUT_ERR" || rc=$?
assert test "$rc" -eq 0
assert awk -v g="$(start_gap)" 'BEGIN { exit !(g < 3) }'
# Playwright's Chrome runs in a session of its own, outside the unit's process group: found by parent pid.
grok_roster 'chromeown: Logged in\nfasta: Logged in\n'
: >"$CALLS"
rc=0
env "${FANOUT_ENV[@]}" IMAGE_FANOUT_LAUNCH_GAP_MS=8000 bash "$SCRIPT" --dest-dir "$DEST" --prompt 'badge' \
  --vendors grok >"$FANOUT_OUT" 2>"$FANOUT_ERR" || rc=$?
assert test "$rc" -eq 0
assert awk -v g="$(start_gap)" 'BEGIN { exit !(g < 3) }'
# A cancelled unit's own-session Chrome that ignores TERM outlives its wrapper: the KILL still reaches it.
grok_roster 'chromeorphan: Logged in\nfasta: Logged in\n'
rm -f "$CHILDREN/chromeorphan.pid"
: >"$CALLS"
rc=0
env "${FANOUT_ENV[@]}" IMAGE_FANOUT_KILL_WAIT_MS=500 FANOUT_SLEEP=1 bash "$SCRIPT" --dest-dir "$DEST" --prompt 'badge' \
  --vendors grok --takes 1 --spare 1 >"$FANOUT_OUT" 2>"$FANOUT_ERR" || rc=$?
assert test "$rc" -eq 0
assert grep -Fq $'grok\tchromeorphan\tspare-cancelled\t' "$(fanout_work "$DEST")/fanout.tsv"
assert test -s "$CHILDREN/chromeorphan.pid"
orphan=$(cat "$CHILDREN/chromeorphan.pid")
assert wait_for 5 eval "! kill -0 $orphan 2>/dev/null"

# --- a cancelled unit's kill grace never stalls the schedule; its account stays held until reaped ---
# lingers holds request 1's take and ignores TERM; fasta's spare delivers first. busyonce retries
# 1 s after its busy exit, inside the 8 s grace; request 2, pinned to lingers, waits out the grace.
grok_roster 'lingers: Logged in\nfasta: Logged in\nbusyonce: Logged in\n'
rm -f "$CHILDREN/lingers.seen" "$CHILDREN/busyonce.seen"
jq -cn --arg d "$DEST" '
  {prompt: "a", dest: ($d + "/linger-a.png"), vendor: "grok", takes: 1},
  {prompt: "b", dest: ($d + "/linger-b.png"), vendor: "grok", account: "lingers"},
  {prompt: "c", dest: ($d + "/linger-c.png"), vendor: "grok", account: "busyonce"}' >"$WORK/linger.jsonl"
: >"$CALLS"
rc=0
env "${FANOUT_ENV[@]}" FANOUT_LIVE= FANOUT_SLEEP=0.3 IMAGE_FANOUT_KILL_WAIT_MS=8000 IMAGE_FANOUT_BUSY_RETRY_MS=1000 \
  bash "$SCRIPT" --dest-dir "$DEST" --jobs "$WORK/linger.jsonl" --spare 1 >"$FANOUT_OUT" 2>"$FANOUT_ERR" || rc=$?
assert test "$rc" -eq 0
start_at() { # account nth -> its nth START time
  awk -v a="$1" -v n="$2" '$1 == "START" && $2 == a && ++k == n { print $3; exit }' "$CALLS"
}
assert awk -v a="$(start_at busyonce 1)" -v b="$(start_at busyonce 2)" 'BEGIN { exit !(b != "" && b - a < 5) }'
assert awk -v f="$(start_at fasta 1)" -v l="$(start_at lingers 2)" 'BEGIN { exit !(l != "" && l - f >= 7) }'
assert grep -Fq $'grok\tlingers\tspare-cancelled\t' "$(fanout_work "$DEST")/fanout.tsv"
assert test "$(dest_col "$(fanout_work "$DEST")/fanout.tsv" "$DEST/linger-b.png" 3)" = ok
assert test "$(dest_col "$(fanout_work "$DEST")/fanout.tsv" "$DEST/linger-c.png" 3)" = ok

# --- primary takes launch before spares; a spare still runs when a slot is free ---------------------
grok_roster 'fasta: Logged in\nfastb: Logged in\nfastc: Logged in\n'
jq -cn --arg d "$DEST" '
  {prompt: "a", dest: ($d + "/prim-a.png"), vendor: "grok", takes: 1},
  {prompt: "b", dest: ($d + "/prim-b.png"), vendor: "grok", account: "fastc"}' >"$WORK/prim.jsonl"
: >"$CALLS"
rc=0
env "${FANOUT_ENV[@]}" IMAGE_FANOUT_LAUNCH_GAP_MS=400 FANOUT_SLEEP=2 bash "$SCRIPT" --dest-dir "$DEST" --jobs "$WORK/prim.jsonl" \
  --spare 1 --max-parallel 2 >"$FANOUT_OUT" 2>"$FANOUT_ERR" || rc=$?
assert test "$rc" -eq 0
assert test "$(awk '/^START / { print $2 }' "$CALLS" | paste -sd, -)" = fasta,fastc
assert grep -Fq $'grok\t-\tspare-cancelled\t' "$(fanout_work "$DEST")/fanout.tsv"

# --- a packed request's spare waits for its pack to run lazily long without delivering ---------------
set_roster gemini-web '[ "${1:-}" = accounts ] || exit 2
printf "%s\n" "{\"ok\":true,\"accounts\":[{\"account\":\"slowp\",\"login\":true},{\"account\":\"fastq\",\"login\":true}]}"'
: >"$CALLS"
rc=0
env "${FANOUT_ENV[@]}" FANOUT_SLEEP=0.6 IMAGE_FANOUT_LAZY_SPARE_MS=2000 bash "$SCRIPT" --dest-dir "$DEST" --prompt 'badge' \
  --vendors gemini --takes 4 --spare 1 >"$FANOUT_OUT" 2>"$FANOUT_ERR" || rc=$?
assert test "$rc" -eq 0
assert test "$(grep -c '^START slowp ' "$CALLS")" -eq 1
assert test "$(grep -c '^START fastq ' "$CALLS")" -eq 0
assert grep -Fq 'ok=4 ' "$FANOUT_OUT"
: >"$CALLS"
rc=0
env "${FANOUT_ENV[@]}" FANOUT_SLEEP=2 IMAGE_FANOUT_LAZY_SPARE_MS=800 bash "$SCRIPT" --dest-dir "$DEST" --prompt 'badge' \
  --vendors gemini --takes 4 --spare 1 >"$FANOUT_OUT" 2>"$FANOUT_ERR" || rc=$?
assert test "$rc" -eq 0
assert awk -v p="$(start_at slowp 1)" -v s="$(start_at fastq 1)" 'BEGIN { exit !(s != "" && s - p >= 0.8) }'
# On a packing route a lone take's spare waits too, unpacked.
set_roster chatgpt-web '[ "${1:-}" = accounts ] || exit 2
printf "%s\n" "{\"ok\":true,\"accounts\":[{\"account\":\"tabp\",\"login\":true},{\"account\":\"tabq\",\"login\":true}]}"'
: >"$CALLS"
rc=0
env "${FANOUT_ENV[@]}" FANOUT_SLEEP=0.6 IMAGE_FANOUT_LAZY_SPARE_MS=2000 bash "$SCRIPT" --dest-dir "$DEST" --prompt 'badge' \
  --vendors codex --takes 1 --spare 1 >"$FANOUT_OUT" 2>"$FANOUT_ERR" || rc=$?
assert test "$rc" -eq 0
assert test "$(grep -c '^START ' "$CALLS")" -eq 1
assert_fails "$(cat "$CALLS")" 'ARG=--count'
set_roster chatgpt-web '[ "${1:-}" = accounts ] || exit 2
printf "%s\n" "{\"ok\":true,\"accounts\":[{\"account\":\"alpha\",\"login\":true,\"walled_until\":null},{\"account\":\"beta\",\"login\":false,\"walled_until\":null}]}"'

# --- busy and limit reach the fan-out; the next route is its last resort --------------------------
(
  . "$ROOT/share/image-leg.sh"
  IMAGE_LEG_ROUTE=web
  for code in 3 5; do
    IMAGE_LEG_FALLBACK_FROM='' IMAGE_LEG_SCHEDULER=''
    image_leg_fallback "$code" '{}' cli 2>/dev/null || exit 1
    IMAGE_LEG_FALLBACK_FROM='' IMAGE_LEG_SCHEDULER=1
    ! image_leg_fallback "$code" '{}' cli 2>/dev/null || exit 1
  done
  IMAGE_LEG_FALLBACK_FROM='' IMAGE_LEG_SCHEDULER=1
  image_leg_fallback 4 '{}' cli 2>/dev/null
)
assert test "$?" -eq 0
codex_roster() { set_roster chatgpt-web "[ \"\${1:-}\" = accounts ] || exit 2
printf '%s\n' '{\"ok\":true,\"accounts\":[$1]}'"; }
codex_roster '{"account":"webwall","login":true},{"account":"alphb","login":true}'
: >"$CALLS"
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors codex --takes 1 --spare 0 || rc=$?
assert test "$rc" -eq 0
assert grep -Fq 'moved from webwall after a usage limit' <<<"$(tsv_col "$(fanout_work "$DEST")/fanout.tsv" codex alphb 4)"
assert test "$(grep -c '^SCHED=1$' "$CALLS")" -eq 2
assert_fails "$(cat "$CALLS")" 'ARG=--route'
# No account left on the web route: the take relaunches on the CLI route, where the wrapper picks.
codex_roster '{"account":"webwall","login":true}'
: >"$CALLS"
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors codex --takes 1 --spare 0 || rc=$?
assert test "$rc" -eq 0
assert test "$(grep -A1 -Fx 'ARG=--route' "$CALLS" | tail -n 1)" = 'ARG=cli'
assert test "$(grep -c -Fx 'ARG=--account' "$CALLS")" -eq 1
assert grep -Fq -- '--route cli after a usage limit' <<<"$(tsv_col "$(fanout_work "$DEST")/fanout.tsv" codex routed 4)"
# A pinned account keeps itself on the CLI route.
: >"$CALLS"
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors codex || rc=$?
assert test "$rc" -eq 0
assert grep -Fq $'codex\twebwall\tok' "$(fanout_work "$DEST")/fanout.tsv"
assert test "$(grep -c -Fx 'ARG=webwall' "$CALLS")" -eq 2
assert test "$(grep -c -Fx 'ARG=--route' "$CALLS")" -eq 1
# A pack the next route cannot carry (its counts) stays a usage limit.
set_roster gemini-web '[ "${1:-}" = accounts ] || exit 2
printf "%s\n" "{\"ok\":true,\"accounts\":[{\"account\":\"webwall\",\"login\":true}]}"'
: >"$CALLS"
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors gemini --takes 4 --spare 0 || rc=$?
assert test "$rc" -eq 3
assert_fails "$(cat "$CALLS")" 'ARG=--route'

# --- a flagged account (the engine's `flagged`) is exit 3 but never reported as a usage limit ------
flag_err=$( (. "$ROOT/share/image-leg.sh"; image_leg_limit GEMINI '{"ok":false,"code":3,"flagged":true}') 2>&1 )
assert test "$?:$flag_err" = '3:GEMINI_ACCOUNT_FLAGGED'
flag_err=$( (. "$ROOT/share/image-leg.sh"; image_leg_limit GEMINI '{"ok":false,"code":3}') 2>&1 )
assert test "$?:$flag_err" = '3:GEMINI_USAGE_LIMIT'
flag_err=$( (. "$ROOT/share/image-leg.sh"; IMAGE_LEG_ROUTE=flow; image_leg_fallback 3 '{"flagged":true}' cli) 2>&1 )
assert grep -Fq 'failed (flagged)' <<<"$flag_err"
grok_roster 'flagged: Logged in\nfasta: Logged in\n'
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors grok --takes 1 --spare 0 || rc=$?
assert test "$rc" -eq 0
flag_reason=$(tsv_col "$(fanout_work "$DEST")/fanout.tsv" grok fasta 4)
assert grep -Fq 'moved from flagged after an account flag (unusual activity)' <<<"$flag_reason"
assert_fails "$flag_reason" 'usage limit'
grok_roster 'flagged: Logged in\n'
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors grok || rc=$?
assert test "$rc" -eq 3
flag_reason=$(tsv_col "$(fanout_work "$DEST")/fanout.tsv" grok flagged 4)
assert test "$(tsv_col "$(fanout_work "$DEST")/fanout.tsv" grok flagged 3)" = usage_limit
assert grep -Fq 'account flagged (unusual activity)' <<<"$flag_reason"
assert_fails "$flag_reason" 'usage limit'

# --- pool order: the roster's least recently used free account first, ties in roster order ---------
codex_roster '{"account":"lrua","login":true,"last_used":1791000200},{"account":"lrub","login":true,"last_used":1791000100}'
: >"$CALLS"
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors codex --takes 1 --spare 0 || rc=$?
assert test "$rc" -eq 0
assert test "$(awk '/^START / { print $2 }' "$CALLS" | paste -sd, -)" = lrub
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors codex --takes 2 --spare 0 --pack 1 --dry-run || rc=$?
assert grep -Fq 'codex-lrub.png' <<<"$(plan_cmd codex take1)"
assert grep -Fq 'codex-lrua-2.png' <<<"$(plan_cmd codex take2)"
set_roster chatgpt-web '[ "${1:-}" = accounts ] || exit 2
printf "%s\n" "{\"ok\":true,\"accounts\":[{\"account\":\"alpha\",\"login\":true,\"walled_until\":null},{\"account\":\"beta\",\"login\":false,\"walled_until\":null}]}"'
set_roster gemini-web '[ "${1:-}" = accounts ] || exit 2
printf "%s\n" "{\"ok\":true,\"accounts\":[{\"account\":\"gamma\",\"roster\":true,\"login\":true,\"walled_until\":null}]}"'

# --- --video without --ref is a usage error before planning -----------------
grok_roster 'delta: Logged in\n'
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
assert test ! -e "$(fanout_work "$DRYDEST")"
assert test -f "$DRYDEST/canary"
assert test "$(find "$DRYDEST" -type f | wc -l | tr -d ' ')" = 1

# --- dest paths with spaces survive kv_last ---------------------------------
SPDEST="$WORK/dest with spaces"
mkdir -p "$SPDEST"
rc=0
fanout --dest-dir "$SPDEST" --prompt 'badge' --vendors grok --accounts all || rc=$?
assert test "$rc" -eq 0
sp_row=$(awk -F'\t' '$1=="grok" && $2=="delta" {print; exit}' "$(fanout_work "$SPDEST")/fanout.tsv")
assert test "$(printf '%s' "$sp_row" | awk -F'\t' '{print $5}')" = "$SPDEST/grok-delta.png"

# --- login-needed, out-of-pool and walled roster rows are skipped, not launched ---------------------
grok_roster 'ghost: login needed\ndelta: Logged in\n'
set_roster gemini-web '[ "${1:-}" = accounts ] || exit 2
printf "%s\n" "{\"ok\":true,\"accounts\":[{\"account\":\"absent\",\"login\":false},{\"account\":\"gamma\",\"login\":true},{\"account\":\"stray\",\"roster\":false,\"login\":true},{\"account\":\"wall\",\"login\":true,\"walled_until\":9999999999},{\"account\":\"thawed\",\"login\":true,\"walled_until\":1}]}"'
: >"$CALLS"
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors grok,gemini || rc=$?
assert test "$rc" -eq 0
assert grep -Fq $'grok\tghost\tskipped\tlogin needed' "$(fanout_work "$DEST")/fanout.tsv"
assert grep -Fq $'gemini\tabsent\tskipped\tlogin needed' "$(fanout_work "$DEST")/fanout.tsv"
assert grep -Fq $'gemini\tstray\tskipped\tout of pool' "$(fanout_work "$DEST")/fanout.tsv"
assert grep -Fq $'gemini\twall\tskipped\twalled' "$(fanout_work "$DEST")/fanout.tsv"
assert grep -Fq $'gemini\tthawed\tok' "$(fanout_work "$DEST")/fanout.tsv"
assert grep -Fq $'grok\tdelta\tok' "$(fanout_work "$DEST")/fanout.tsv"
assert_fails "$(cat "$CALLS")" 'ARG=ghost'
assert_fails "$(cat "$CALLS")" 'ARG=absent'
assert_fails "$(cat "$CALLS")" 'ARG=wall'

# --- STALE line is the value, not a temp path --------------------------------
grok_roster 'staleacct: Logged in\n'
rc=0
fanout --dest-dir "$DEST" --prompt 'badge' --vendors grok --accounts all || rc=$?
assert test "$rc" -eq 0
stale_line=$(grep '^STALE:' "$FANOUT_OUT" || true)
assert grep -Fq 'STALE: grok staleacct model_caps=stale' <<<"$stale_line"
assert_fails "$stale_line" '/image-fanout.'

# --- fanout.state.json: the task row's live cells, rewritten on every change ---
grok_roster 'delta: Logged in\nslow: Logged in\nbroken: Logged in\nwalled: Logged in\n'
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
state_cells() { jq -c '[.kind, [.cells[] | [.vendor, .account, .status, .exit]]]' "$(fanout_work "$STATE_DEST")/fanout.state.json" 2>/dev/null; }
fanout_bg FANOUT_RELEASE="$WORK/release" -- --dest-dir "$STATE_DEST" --prompt 'badge' --vendors grok
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
assert test "$(find "$(fanout_work "$STATE_DEST")" -name 'fanout.state.json.tmp*' | wc -l | tr -d ' ')" = 0

# A cell holding for a parallel slot has no process yet: `waiting`, never `running`, so the row
# does not count queued accounts as work in flight. Every planned cell is listed from the start.
rm -f "$(fanout_work "$STATE_DEST")/fanout.state.json" "$WORK/release"
fanout_bg FANOUT_RELEASE="$WORK/release" -- --dest-dir "$STATE_DEST" --prompt 'badge' --vendors grok --max-parallel 1
fanout_pid=$!
state_queued='["image",[["grok","delta","done",0],["grok","slow","running",null],["grok","broken","waiting",null],["grok","walled","waiting",null]]]'
for _ in $(seq 1 200); do
  [ "$(state_cells)" = "$state_queued" ] && break
  sleep 0.05
done
assert test "$(state_cells)" = "$state_queued"
: >"$WORK/release"
wait "$fanout_pid"
assert test "$(state_cells)" = '["image",[["grok","delta","done",0],["grok","slow","done",0],["grok","broken","failed",1],["grok","walled","failed",3]]]'
rm -f "$(fanout_work "$STATE_DEST")/fanout.state.json"
rc=0
fanout --dest-dir "$STATE_DEST" --prompt 'motion' --video --ref "$WORK/refs/r1.png" --vendors grok --dry-run || rc=$?
assert test "$rc" -eq 0
assert test ! -e "$(fanout_work "$STATE_DEST")/fanout.state.json"

# --- the caps model check: fresh, stale and unknown ---------------------------
# shellcheck source=share/image-caps.sh
. "$ROOT/share/image-caps.sh"
video_model=$(jq -r '.model.video' "$ROOT/share/image-caps/grok.json")
checks="$VENDOR_CLI_UPDATE_STATE_DIR/caps-checks.jsonl"
mkdir -p "$VENDOR_CLI_UPDATE_STATE_DIR"
: >"$checks"
assert test "$(image_caps_model_check "$ROOT" grok video "$video_model")" = "model=$video_model model_caps=fresh"
assert test "$(image_caps_model_check "$ROOT" grok video '')" = 'model=unknown model_caps=unknown'
assert test "$(image_caps_model_check "$ROOT" grok video 'other-model')" = "model=other-model model_caps=stale verified=$video_model"
assert test "$(jq -c 'select(.vendor == "grok" and .section == "model.video") | [.state, .what]' "$checks" | paste -sd' ' -)" = \
  "[\"fresh\",\"model=$video_model verified=$video_model\"] [\"stale\",\"model=other-model verified=$video_model\"]"
cli_version=$(jq -r '.cli.version' "$ROOT/share/image-caps/grok.json")
printf '#!/bin/sh\necho "grok %s"\n' "$cli_version" >"$WORK/grok-current"
printf '#!/bin/sh\necho "grok 9.9.9"\n' >"$WORK/grok-newer"
chmod +x "$WORK/grok-current" "$WORK/grok-newer"
image_caps_check "$ROOT" grok "$WORK/grok-current" >/dev/null
image_caps_check "$ROOT" grok "$WORK/grok-newer" >/dev/null
assert test "$(jq -c 'select(.vendor == "grok" and .section == "cli") | [.state, .what]' "$checks" | paste -sd' ' -)" = \
  "[\"fresh\",\"cli=$cli_version verified=$cli_version\"] [\"stale\",\"cli=9.9.9 verified=$cli_version\"]"

printf 'PASS: %s asserts; registry-driven vendors (no name in the script, another manifest picked up), roster JSON and pool lines (login, pool, walls), dry-run plans/adaptations (refs incl. --edit, aspect auto, Codex prose, size, video skip/ref, no video spares or packs), tsv columns incl. job/route/fallback_from/phases, per-account scheduling with no overlap, exit-5 requeue, pinned retry and give-up, usage-limit moves, spares cancelled by process group with no orphan (TERM and KILL), --jobs batch with per-job dest/job ids/state keys, --pack variants as takes, memory admission (floor and pressure), launch spacing and the Chrome shortcut (own-session Chrome by parent pid, its KILL after the wrapper died), a non-blocking kill grace that holds the account, primaries before spares, lazy spares of packs, busy/limit left to the scheduler with the next route as last resort, a flagged account told from a usage limit, least recently used pool order, dest spaces, dry-run dest-dir untouched, exit 0/3/1/2, STALE value, pick without --account, live fanout.state.json cells, caps model check\n' "$asserts"
