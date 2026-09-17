#!/usr/bin/env bash
# gemini-probe against a fake agy under a temp HOME: no real profile, keychain, log root or account
# store is reachable.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$ROOT/bin/gemini-probe"
WORK="$(mktemp -d)"
trap '[ -n "${KEEP:-}" ] || rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; [ ! -f "$WORK/out" ] || cat "$WORK/out" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
assert_eq() {
  asserts=$((asserts + 1))
  [ "$1" = "$2" ] || fail "assert $asserts: expected [$2], got [$1]"
}

export HOME="$WORK/home"
FAKE_BIN="$WORK/bin"
export CALLS="$WORK/calls"
mkdir -p "$HOME/.gemini/antigravity-cli" "$HOME/.gemini-profiles/alpha" "$FAKE_BIN"
export GEMINIB_PROFILES_DIR="$HOME/.gemini-profiles" XDG_CACHE_HOME="$HOME/.cache"
export GEMINIB_CACHE_DIR="$HOME/.cache/geminib" GEMINI_WEATHER_DIR="$HOME/weather"
export CLAUDEB_DIR="$HOME/claudeb" WORKER_RUN_DIR="$HOME/runs"
unset GEMINI_WEATHER_NOW GEMINIB_CAPACITY_FALLBACK

# FAKE_<family> picks the behaviour per model: ok (2 s a step), slow (12 s a step), 503, hang.
# Stamps are written, not slept: a step's spacing is in the glog stamps gemini-weather reads.
cat >"$FAKE_BIN/agy" <<'AGY'
#!/usr/bin/env python3
import os, sys, time
args = sys.argv[1:]
model = args[args.index("--model") + 1]
log = args[args.index("--log-file") + 1]
prompt = args[args.index("--print") + 1]
kind = "short" if "pong" in prompt else "long"
family = model.lower().replace(" (high)", "").replace(" ", "-").replace("-high", "")
behaviour = os.environ.get("FAKE_" + family.replace("-", "_").replace(".", "_"), "ok")
with open(os.environ["CALLS"], "a") as calls:
    calls.write("model=%s kind=%s fallback=%s\n" % (model, kind, os.environ.get("GEMINIB_CAPACITY_FALLBACK", "unset")))
now = time.time()
def stamp(offset):
    return time.strftime("I%m%d %H:%M:%S", time.localtime(now + offset)) + ".123456"
steps = 1 if kind == "short" else 6
spacing = 12 if behaviour == "slow" else 2
lines = ['%s 1 printmode.go:174] Print mode: starting (promptLength=6, model="%s", conversationID="")' % (stamp(-30), model),
         "%s 1 session.go:168] Print mode: conversation=c-1, sending message" % stamp(1 - spacing)]
if behaviour == "503":
    lines.append("%s 707 run.go:389] Run: attempt 1 failed (UNAVAILABLE (code 503): No capacity available for model %s on the server)" % (stamp(1), model))
else:
    for step in range(steps if behaviour != "hang" else 1):
        lines.append("%s 1186 http_helpers.go:299] URL: https://x.invalid/v1internal:streamGenerateContent?alt=sse Trace: 0x1 ResponseID: %s-%d" % (stamp(1 + step * spacing), os.path.basename(log), step))
    lines.append("%s 1 server.go:2874] Language server shutting down" % stamp(1 + steps * spacing))
with open(log, "a") as handle:
    handle.write("\n".join(lines) + "\n")
if behaviour == "hang":
    with open(os.environ["CALLS"] + "-hung", "a") as pids:
        pids.write("%d\n" % os.getpid())
    os.execvp("sleep", ["sleep", "60"])
if behaviour == "503":
    sys.exit(1)
print("pong" if kind == "short" else "summaries")
AGY
printf '#!/usr/bin/env bash\nexit 0\n' >"$FAKE_BIN/security"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >"$CALLS-pick"\nexit "${PICK_RC:-0}"\n' >"$FAKE_BIN/pick-limit"
printf '#!/usr/bin/env bash\nprintf "alpha\\n"\n' >"$FAKE_BIN/pick-alpha"
chmod +x "$FAKE_BIN"/*
export AGY_BIN="$FAKE_BIN/agy" GEMINIB_SECURITY_CMD="$FAKE_BIN/security"
export FAKE_gemini_3_8_flash=ok FAKE_gemini_3_7_flash=slow FAKE_gemini_3_6_flash=503 FAKE_gemini_3_1_pro=hang

probe() { : >"$CALLS"; "$PROBE" "$@" >"$WORK/out" 2>"$WORK/err"; }
# A profile's first geminib launch builds its keychain and links; parallel first launches race there.
bash "$ROOT/bin/geminib" profile alpha --model warm-up --log-file "$WORK/warm.log" --print pong >/dev/null 2>&1 ||
  fail "profile warm-up failed"

# --- The four behaviours in one run, the hung family cut by --timeout ---
started=$(date +%s)
probe --account alpha --timeout 3
assert_eq "$?" 1
assert test "$(( $(date +%s) - started ))" -lt 20
out=$(cat "$WORK/out")
assert_eq "$(sed -n 1p <<<"$out")" 'account: alpha'
assert_eq "$(sed -n 2p <<<"$out")" 'families: gemini-3.8-flash-high, gemini-3.7-flash-high, gemini-3.6-flash-high, Gemini 3.1 Pro (High)'
assert grep -Eq '^FAMILY +SHORT +LONG +WALL +503 +STATE$' <<<"$out"
assert grep -Eq '^gemini-3\.8-flash +1 step 2\.0s +6 steps med 2\.0s p90 2\.0s +[0-9]+s\+[0-9]+s +0 +ok$' <<<"$out"
assert grep -Eq '^gemini-3\.7-flash +1 step 12\.0s +6 steps med 12\.0s p90 12\.0s +[0-9]+s\+[0-9]+s +0 +slow$' <<<"$out"
assert grep -Eq '^gemini-3\.6-flash +0 steps, exit 1 +0 steps, exit 1 +[0-9]+s\+[0-9]+s +2 +starved$' <<<"$out"
assert grep -Eq '^gemini-3\.1-pro +1 step, timeout +1 step, timeout +[0-9]+s\+[0-9]+s +0 +failed$' <<<"$out"
assert_eq "$(grep -E '^(state|verdict): ' <<<"$out" | tr '\n' ';')" \
  'state: gemini-3.8-flash ok;state: gemini-3.7-flash slow;state: gemini-3.6-flash starved;state: gemini-3.1-pro failed;verdict: 1 of 4 families ok;'
# The probe must see the family it asked for: fallback off, no relaunch one family down.
assert_eq "$(grep -c 'fallback=0' "$CALLS")" 8
assert_eq "$(grep -c 'model=gemini-3.6-flash-high' "$CALLS")" 2
assert_eq "$(grep -Ec 'model=gemini-3.[78]-flash-high' "$CALLS")" 4
assert test "$(ls "$GEMINIB_CACHE_DIR/capacity" 2>/dev/null | wc -l)" -eq 0
# A hung agy is gone once the probe returns, children included.
assert_eq "$(wc -l <"$CALLS-hung" | tr -d ' ')" 2
while read -r hung; do assert_eq "$(kill -0 "$hung" 2>/dev/null && echo alive || echo gone)" gone; done <"$CALLS-hung"

# --- A plain gemini-weather afterwards sees the probe's runs, tagged as probes ---
weather=$("$ROOT/bin/gemini-weather" --window 5 --json --no-write)
assert_eq "$(jq -r '.families[] | select(.family == "gemini-3.8-flash") | "\(.state) \(.runs) \(.probe_runs) \(.steps)"' <<<"$weather")" 'ok 2 2 7'
assert_eq "$(jq -r '.families[] | select(.family == "gemini-3.7-flash") | .state' <<<"$weather")" slow
assert_eq "$(jq -r '.families[] | select(.family == "gemini-3.6-flash") | "\(.state) \(.errors_503)"' <<<"$weather")" 'starved 2'
table=$("$ROOT/bin/gemini-weather" --window 5 --no-write)
assert grep -Eq '^gemini-3\.8-flash +ok +2 \(2 probe\) +0 +7 ' <<<"$table"

# --- --families and --short-only: one family, one request ---
probe --account alpha --families 3.8 --short-only
assert_eq "$?" 0
assert grep -Eq '^FAMILY +SHORT +WALL +503 +STATE$' "$WORK/out"
assert grep -Fxq 'families: gemini-3.8-flash-high' "$WORK/out"
assert grep -Fxq 'verdict: 1 of 1 families ok' "$WORK/out"
assert_eq "$(cat "$CALLS")" 'model=gemini-3.8-flash-high kind=short fallback=0'

# --- The account: worker-pick's research answer by default, its exit 3 is the usage-limit outcome ---
GEMINI_PROBE_PICK_CMD="$FAKE_BIN/pick-alpha" probe --families 3.8 --short-only
assert_eq "$?" 0
assert grep -Fxq 'account: alpha' "$WORK/out"
PICK_RC=3 GEMINI_PROBE_PICK_CMD="$FAKE_BIN/pick-limit" probe
assert_eq "$?" 3
assert_eq "$(cat "$WORK/out")" 'OUTCOME: GEMINI_USAGE_LIMIT'
assert_eq "$(cat "$CALLS-pick")" '--account gemini --role research'
assert_eq "$(wc -c <"$CALLS" | tr -d ' ')" 0

# --- Usage errors exit 2 before anything launches ---
for bad in '--families 3.9' '--families 3.8,3.8' '--timeout 0' '--bogus'; do
  # shellcheck disable=SC2086
  probe --account alpha $bad
  assert_eq "$?" 2
done
assert_eq "$(wc -c <"$CALLS" | tr -d ' ')" 0

# `geminib families` always prints rows, so an empty list is a broken reader: probing nothing would
# otherwise end in a clean report saying every family is healthy.
mkdir -p "$WORK/no-families"
printf '{"fetched_at": 9999999999, "attempted_at": 9999999999, "families": [{"family": ""}]}\n' >"$WORK/no-families/models.json"
GEMINIB_CACHE_DIR="$WORK/no-families" probe --account alpha
assert_eq "$?" 1
assert grep -Fq 'geminib families' "$WORK/err"
assert_eq "$(wc -c <"$CALLS" | tr -d ' ')" 0

printf 'PASS: %s asserts; gemini-probe (ok, slow, 503, timeout, fallback off, weather sees probe runs, --families, --short-only, account pick, usage, no families)\n' "$asserts"
