#!/usr/bin/env bash
# The Gemini capacity fallback (shared-invariants row `cn`): a 503 `No capacity available for model`
# walks the launch one Flash family down instead of leaving agy stalling in its own retry backoff.
# Everything here runs against a fake agy under a temp HOME; no real profile, keychain or account
# store is reachable.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/geminib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; [ ! -f "$WORK/err" ] || cat "$WORK/err" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
assert_eq() {
  asserts=$((asserts + 1))
  [ "$1" = "$2" ] || fail "assert $asserts: expected [$2], got [$1]"
}

HOME="$WORK/home"
FAKE_BIN="$WORK/bin"
CALLS="$WORK/calls"
export HOME CALLS
mkdir -p "$HOME/.gemini/antigravity-cli" "$HOME/.gemini-profiles/alpha" "$FAKE_BIN"
export GEMINIB_PROFILES_DIR="$HOME/.gemini-profiles"
export XDG_CACHE_HOME="$HOME/.cache"
MARKERS="$HOME/.cache/geminib/capacity"

# Records the model and log it was launched with, then answers as the incident does: a family named
# in STARVED prints the 503 into the log agy was handed. STALL mimics agy's in-process retry — a
# starved family does not exit, it sits there — and is what the watcher has to end.
cat >"$FAKE_BIN/agy" <<'AGY'
#!/usr/bin/env bash
log=''; model=''; want=''
for argument in "$@"; do
  case "$want" in
    log) log=$argument; want='' ;;
    model) model=$argument; want='' ;;
  esac
  case "$argument" in --log-file) want=log ;; --model) want=model ;; esac
done
printf 'model=%s log=%s\n' "$model" "$log" >>"$CALLS"
printf '%s\n' "${HOME:-}" >>"$CALLS-home"
printf '%s\n' "$$" >"$CALLS-pid"
[ "${IGNORE_TERM:-0}" = 0 ] || trap '' TERM
for ((step = 0; step < ${STEPS:-0}; step++)); do
  printf 'URL: https://example.invalid/v1internal:streamGenerateContent?alt=sse\n' >>"$log"
done
case " ${STARVED:-} " in
  *" $model "*)
    printf 'ERROR 503: No capacity available for model %s\n' "$model" >>"$log"
    sleep "${STALL:-0}"
    [ "${RECOVER:-0}" = 0 ] || { printf 'answer from %s\n' "$model"; exit 0; }
    exit 1
    ;;
esac
sleep "${HANG:-0}"
printf 'answer from %s\n' "$model"
AGY
printf '#!/usr/bin/env bash\nexit 0\n' >"$FAKE_BIN/security"
chmod +x "$FAKE_BIN/agy" "$FAKE_BIN/security"
export AGY_BIN="$FAKE_BIN/agy" GEMINIB_SECURITY_CMD="$FAKE_BIN/security"
export STARVED='' STALL=0 STEPS=0 RECOVER=0 IGNORE_TERM=0 HANG=0 GEMINIB_CAPACITY_HOLD_S=600 GEMINIB_CAPACITY_FALLBACK=1

run() { # agy arguments; STARVED/STALL and the two knobs are set by the caller beforehand
  : >"$CALLS"
  rm -f "$WORK/log"
  bash "$SCRIPT" profile alpha "$@" >"$WORK/out" 2>"$WORK/err"
}
models_launched() { sed -n 's/^model=\(.*\) log=.*/\1/p' "$CALLS" | tr '\n' ',' ; }
served_model() { tail -n1 "$WORK/err"; }

# --- A starved 3.8 hands the run to 3.7, at the same effort ---
STARVED='gemini-3.8-flash-high'
run --model gemini-3.8-flash-high --log-file "$WORK/log" --print hello
assert_eq "$?" 0
assert_eq "$(models_launched)" 'gemini-3.8-flash-high,gemini-3.7-flash-high,'
assert grep -qx 'answer from gemini-3.7-flash-high' "$WORK/out"
assert grep -qx 'geminib: capacity fallback gemini-3.8-flash-high -> gemini-3.7-flash-high' "$WORK/err"
# The served model is the last word on stderr, and it is what a caller records for the run.
assert_eq "$(served_model)" 'geminib: model gemini-3.7-flash-high'
# The marker is the starved FAMILY, effort stripped: the 503 is capacity, not a tier.
assert test -f "$MARKERS/gemini-3.8-flash"
assert test ! -e "$MARKERS/gemini-3.8-flash-high"
assert test ! -e "$MARKERS/gemini-3.7-flash"

# --- The hold: the next launch skips the starved family outright and never asks it again ---
STARVED=''
run --model gemini-3.8-flash-high --log-file "$WORK/log" --print hello
assert_eq "$?" 0
assert_eq "$(models_launched)" 'gemini-3.7-flash-high,'
assert grep -qx 'geminib: capacity hold gemini-3.8-flash-high -> gemini-3.7-flash-high' "$WORK/err"
assert_eq "$(served_model)" 'geminib: model gemini-3.7-flash-high'

# --- Once the hold lapses the higher family is tried again: that is "back up when it is served" ---
GEMINIB_CAPACITY_HOLD_S=0
run --model gemini-3.8-flash-high --log-file "$WORK/log" --print hello
assert_eq "$?" 0
assert_eq "$(models_launched)" 'gemini-3.8-flash-high,'
assert_eq "$(served_model)" 'geminib: model gemini-3.8-flash-high'
GEMINIB_CAPACITY_HOLD_S=600

# --- A stalling agy is the real shape of the incident, and the whole chain walks under it ---
rm -rf "$MARKERS"
STARVED='gemini-3.8-flash-high gemini-3.7-flash-high'
STALL=30
run --model gemini-3.8-flash-high --log-file "$WORK/log" --print hello
assert_eq "$?" 0
assert_eq "$(models_launched)" 'gemini-3.8-flash-high,gemini-3.7-flash-high,gemini-3.6-flash-high,'
assert grep -qx 'geminib: capacity fallback gemini-3.7-flash-high -> gemini-3.6-flash-high' "$WORK/err"
assert test -f "$MARKERS/gemini-3.7-flash"
STALL=0

# --- A 503 after the model took a step is never relaunched: the brief would be re-fed over edits ---
rm -rf "$MARKERS"
STARVED='gemini-3.8-flash-high'
STEPS=2
run --model gemini-3.8-flash-high --log-file "$WORK/log" --print hello
assert_eq "$?" 1
assert_eq "$(models_launched)" 'gemini-3.8-flash-high,'
assert grep -qx 'geminib: capacity gemini-3.8-flash after 2 steps, not relaunched' "$WORK/err"
assert_eq "$(grep -c 'capacity fallback' "$WORK/err")" 0
assert_eq "$(served_model)" 'geminib: model gemini-3.8-flash-high'
assert test -f "$MARKERS/gemini-3.8-flash"
# Mid-run, agy's own retry is left to finish the attempt rather than being killed under it.
rm -rf "$MARKERS"
STALL=3 RECOVER=1
run --model gemini-3.8-flash-high --log-file "$WORK/log" --print hello
assert_eq "$?" 0
assert_eq "$(models_launched)" 'gemini-3.8-flash-high,'
assert grep -qx 'answer from gemini-3.8-flash-high' "$WORK/out"
assert_eq "$(grep -c 'capacity' "$WORK/err")" 0
STALL=0 RECOVER=0 STEPS=0

# --- A signal to the wrapper ends agy's own group, even an agy that ignores TERM, and leaves no files ---
rm -rf "$MARKERS"
STARVED=''
SIGNAL_TMP="$WORK/signal-tmp"
for ignore in 0 1; do
  mkdir -p "$SIGNAL_TMP"
  : >"$CALLS-pid"
  IGNORE_TERM=$ignore HANG=30 TMPDIR="$SIGNAL_TMP" bash "$SCRIPT" profile alpha --model gemini-3.8-flash-high \
    --log-file "$WORK/log" --print hello <<<'brief' >"$WORK/out" 2>"$WORK/err" &
  wrapper=$!
  for _ in $(seq 50); do [ ! -s "$CALLS-pid" ] || break; sleep 0.1; done
  agy_pid=$(cat "$CALLS-pid")
  assert test -n "$agy_pid"
  kill -TERM "$wrapper"
  wrapper_rc=0
  wait "$wrapper" || wrapper_rc=$?
  assert_eq "$wrapper_rc" 143
  for _ in $(seq 20); do kill -0 "$agy_pid" 2>/dev/null || break; sleep 0.1; done
  assert_eq "$(kill -0 "$agy_pid" 2>/dev/null && printf alive || printf gone)" gone
  assert_eq "$(find "$SIGNAL_TMP" -name 'geminib-*' | wc -l | tr -d ' ')" 0
done

# --- The end of the chain is agy's own: no watcher, no fourth attempt, its status is the run's ---
rm -rf "$MARKERS"
STARVED='gemini-3.6-flash-high'
run --model gemini-3.6-flash-high --log-file "$WORK/log" --print hello
assert_eq "$?" 1
assert_eq "$(models_launched)" 'gemini-3.6-flash-high,'
assert test ! -e "$MARKERS/gemini-3.6-flash"
assert_eq "$(served_model)" 'geminib: model gemini-3.6-flash-high'

# --- Without a log of its own the launch makes one, and every attempt appends to that same file ---
rm -rf "$MARKERS"
STARVED='gemini-3.8-flash-high'
run --model gemini-3.8-flash-high --print hello
assert_eq "$?" 0
assert_eq "$(models_launched)" 'gemini-3.8-flash-high,gemini-3.7-flash-high,'
own_log=$(sed -n '1s/.* log=//p' "$CALLS")
assert test -n "$own_log"
asserts=$((asserts + 1))
case "$own_log" in "$HOME/.cache/geminib/logs/"*) ;; *) fail "own log outside the cache: $own_log" ;; esac
assert_eq "$(sed -n '2s/.* log=//p' "$CALLS")" "$own_log"
assert grep -Fq 'No capacity available for model gemini-3.8-flash-high' "$own_log"

# --- The switch: with the fallback off the starved family is the run, stall and all ---
rm -rf "$MARKERS"
GEMINIB_CAPACITY_FALLBACK=0
run --model gemini-3.8-flash-high --log-file "$WORK/log" --print hello
assert_eq "$?" 1
assert_eq "$(models_launched)" 'gemini-3.8-flash-high,'
assert test ! -e "$MARKERS/gemini-3.8-flash"
assert_eq "$(grep -c 'capacity fallback' "$WORK/err")" 0
assert_eq "$(served_model)" 'geminib: model gemini-3.8-flash-high'
GEMINIB_CAPACITY_FALLBACK=1

# --- An interactive session is Egor's: it is never killed and relaunched under him ---
rm -rf "$MARKERS"
run --model gemini-3.8-flash-high --log-file "$WORK/log"
assert_eq "$?" 1
assert_eq "$(models_launched)" 'gemini-3.8-flash-high,'
assert test ! -e "$MARKERS/gemini-3.8-flash"

# --- A model outside the chain has no fallback to walk, and Pro is the one that matters ---
rm -rf "$MARKERS"
STARVED='Gemini 3.1 Pro (High)'
run --model 'Gemini 3.1 Pro (High)' --log-file "$WORK/log" --print hello
assert_eq "$?" 1
assert_eq "$(models_launched)" 'Gemini 3.1 Pro (High),'
assert test ! -e "$MARKERS/gemini-3.8-flash"
assert_eq "$(served_model)" 'geminib: model Gemini 3.1 Pro (High)'

# --- agy-launch: the same mechanism for a consumer that resolved agy and seeded its own HOME ---
# A review-bench cell rewrites `geminib profile <account> …` into a direct run of the resolved agy
# binary inside a sandbox, so the fallback only reaches it through a subcommand that touches neither
# HOME nor the profile store.
CELL_HOME="$WORK/cellhome"
CELL_CACHE="$WORK/cellcache"
CELL_MARKERS="$CELL_CACHE/capacity"
mkdir -p "$CELL_HOME"
agy_run() { # agy arguments
  : >"$CALLS"
  : >"$CALLS-home"
  rm -f "$WORK/log"
  env HOME="$CELL_HOME" GEMINIB_CACHE_DIR="$CELL_CACHE" \
    bash "$SCRIPT" agy-launch --agy "$FAKE_BIN/agy" -- "$@" >"$WORK/out" 2>"$WORK/err"
}

rm -rf "$CELL_CACHE" "$MARKERS"
STARVED='gemini-3.8-flash-high'
agy_run --model gemini-3.8-flash-high --log-file "$WORK/log" --print hello
assert_eq "$?" 0
assert_eq "$(models_launched)" 'gemini-3.8-flash-high,gemini-3.7-flash-high,'
assert grep -qx 'answer from gemini-3.7-flash-high' "$WORK/out"
assert grep -qx 'geminib: capacity fallback gemini-3.8-flash-high -> gemini-3.7-flash-high' "$WORK/err"
assert_eq "$(served_model)" 'geminib: model gemini-3.7-flash-high'
# The markers follow the cache the caller named — the one it added to its sandbox write roots — and
# the launching user's own cache is left out of it.
assert test -f "$CELL_MARKERS/gemini-3.8-flash"
assert test ! -e "$MARKERS/gemini-3.8-flash"
# Every attempt keeps the caller's HOME: the sandbox holds the account's auth, a profile home would
# be unreadable there.
assert_eq "$(sort -u "$CALLS-home")" "$CELL_HOME"

# The hold is read back out of that same cache on the next launch.
STARVED=''
agy_run --model gemini-3.8-flash-high --log-file "$WORK/log" --print hello
assert_eq "$?" 0
assert_eq "$(models_launched)" 'gemini-3.7-flash-high,'
assert grep -qx 'geminib: capacity hold gemini-3.8-flash-high -> gemini-3.7-flash-high' "$WORK/err"

# A launch that brings no log gets one under the named cache, shared by every attempt.
rm -rf "$CELL_CACHE"
STARVED='gemini-3.8-flash-high'
agy_run --model gemini-3.8-flash-high --print hello
assert_eq "$?" 0
cell_log=$(sed -n '1s/.* log=//p' "$CALLS")
asserts=$((asserts + 1))
case "$cell_log" in "$CELL_CACHE/logs/"*) ;; *) fail "agy-launch log outside the named cache: $cell_log" ;; esac
assert_eq "$(sed -n '2s/.* log=//p' "$CALLS")" "$cell_log"

# The served line repeats the slug as launched, spaces and all, on the path that never falls back.
rm -rf "$CELL_CACHE"
STARVED=''
agy_run --model 'Gemini 3.1 Pro (High)' --log-file "$WORK/log" --print hello
assert_eq "$?" 0
assert_eq "$(models_launched)" 'Gemini 3.1 Pro (High),'
assert_eq "$(served_model)" 'geminib: model Gemini 3.1 Pro (High)'

# A binary this wrapper cannot run is refused before anything launches, in one line.
: >"$WORK/plain-agy"
for bad in "$WORK/no-such-agy" "$WORK/plain-agy"; do
  agy_rc=0
  env HOME="$CELL_HOME" bash "$SCRIPT" agy-launch --agy "$bad" -- --model gemini-3.8-flash-high \
    --print hello >"$WORK/out" 2>"$WORK/err" || agy_rc=$?
  assert_eq "$agy_rc" 2
  assert_eq "$(grep -c . "$WORK/err")" 1
  assert grep -q 'agy-launch needs an executable agy binary' "$WORK/err"
done
agy_rc=0
env HOME="$CELL_HOME" bash "$SCRIPT" agy-launch --model gemini-3.8-flash-high --print hello \
  >"$WORK/out" 2>"$WORK/err" || agy_rc=$?
assert_eq "$agy_rc" 2
assert grep -qx 'usage: geminib agy-launch --agy <path> -- <agy args...>' "$WORK/err"

printf 'PASS: %s asserts; geminib capacity fallback (503 walks 3.8 -> 3.7 -> 3.6 at one effort, a stalling agy ended by the watcher, a 503 after a model step surfaced and never relaunched, a signal ending the agy process group with no leaked files, family markers and their hold with the way back up, the chain end left to agy, a log made when the caller brought none and shared by every attempt, GEMINIB_CAPACITY_FALLBACK=0, interactive and off-chain launches untouched, served model on stderr, and the same mechanism under `agy-launch` for a sandboxed consumer: its own agy binary, GEMINIB_CACHE_DIR for markers and logs, HOME untouched, a display-name model repeated verbatim, and a bad --agy refused)\n' "$asserts"
