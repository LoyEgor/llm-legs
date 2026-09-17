#!/usr/bin/env bash
# gemini-weather reads fixture agy logs under a temp HOME: no real log root, profile or account
# store is reachable.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEATHER="$ROOT/bin/gemini-weather"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
assert_eq() {
  asserts=$((asserts + 1))
  [ "$1" = "$2" ] || fail "assert $asserts: expected [$2], got [$1]"
}

export HOME="$WORK/home"
export CLAUDEB_DIR="$HOME/claudeb" WORKER_RUN_DIR="$HOME/runs" GEMINIB_PROFILES_DIR="$HOME/profiles"
export GEMINIB_CACHE_DIR="$HOME/geminib" GEMINI_WEATHER_DIR="$HOME/weather"
NOW=$(( $(date +%s) / 60 * 60 ))
export GEMINI_WEATHER_NOW="$NOW"
BENCH="$CLAUDEB_DIR/worker-stats/benches/20260917T000000Z-abc1234"
mkdir -p "$BENCH" "$WORKER_RUN_DIR" "$GEMINIB_CACHE_DIR/logs" "$GEMINIB_CACHE_DIR/capacity" \
  "$GEMINIB_PROFILES_DIR/alpha/.gemini/antigravity-cli/log"

# mklog <path> <model line> <seconds before NOW of each step, oldest first> [503:<seconds before NOW>]...
# Stamps are agy's glog shape in local time; the file mtime is the newest event, as agy leaves it.
mklog() {
  python3 - "$NOW" "$@" <<'PY'
import os, sys, time
now = int(sys.argv[1]); path = sys.argv[2]; model = sys.argv[3]; events = sys.argv[4:]
def stamp(offset):
    epoch = now - offset
    return time.strftime("I%m%d %H:%M:%S", time.localtime(epoch)) + ".123456"
first = max(int(e.split(":")[-1]) for e in events) + 5 if events else 5
lines = ["%s       1 printmode.go:174] Print mode: starting (promptLength=6, model=\"%s\", conversationID=\"\")" % (stamp(first), model),
         "%s       1 model_resolver.go:93] Resolving model %s" % (stamp(first), model)]
for number, event in enumerate(events):
    if event.startswith("503:"):
        offset = int(event[4:])
        lines.append("%s     707 run.go:389] Run: attempt 1 failed (UNAVAILABLE (code 503): No capacity available for model %s on the server), retrying in 4s" % (stamp(offset), model))
    else:
        offset = int(event)
        lines.append("%s    1186 http_helpers.go:299] URL: https://daily-cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse Trace: 0x1 ResponseID: %s-%d" % (stamp(offset), os.path.basename(path), number))
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as handle:
    handle.write("\n".join(lines) + "\n")
newest = min(int(e.split(":")[-1]) for e in events) if events else first
os.utime(path, (now - newest, now - newest))
PY
}

# Healthy 3.7: two runs at 3 s a step, one in a worker run dir whose meta names its log.
mklog "$BENCH/agy-agy-flash37-high.log" gemini-3.7-flash-high 600 597 594 591
mkdir -p "$WORKER_RUN_DIR/gemini-1-1-a"
mklog "$WORKER_RUN_DIR/gemini-1-1-a/agy.log" gemini-3.7-flash-medium 300 297 294
jq -cn --arg log "$WORKER_RUN_DIR/gemini-1-1-a/agy.log" '{cmd:["geminib","profile","alpha","--log-file",$log,"--print","x"]}' \
  >"$WORKER_RUN_DIR/gemini-1-1-a/meta.json"
# Slow 3.6: 20 s a step.
mklog "$GEMINIB_CACHE_DIR/logs/20260917T000000Z-1.log" gemini-3.6-flash-high 900 880 860 840
# Starved 3.8: 503s between steps.
mklog "$GEMINIB_PROFILES_DIR/alpha/.gemini/antigravity-cli/log/cli-1.log" gemini-3.8-flash-low 1200 1197 503:1190 503:480 1194
# Pro by its label spelling, outside a 30-minute window but inside the 60-minute one.
mklog "$BENCH/agy-agy-pro-high.log" 'Gemini 3.1 Pro (High)' 2400 2396 2392
# Window cut-off: a 3.6 run from two hours ago, 503 included, must not count anywhere.
mklog "$BENCH/agy-agy-flash36-old.log" gemini-3.6-flash-high 7300 7290 503:7200
# The same run copied to a second root is one run, not two.
cp -p "$BENCH/agy-agy-flash37-high.log" "$GEMINIB_CACHE_DIR/logs/copy.log"
# A quota poll: agy's own log with no model and no step belongs to no family.
mklog "$GEMINIB_PROFILES_DIR/alpha/.gemini/antigravity-cli/log/cli-2.log" ''

json=$("$WEATHER" --json) || fail "gemini-weather --json exited nonzero"
family() { jq -r --arg f "$1" --arg k "$2" '.families[] | select(.family == $f) | .[$k] | tostring' <<<"$json"; }

assert_eq "$(jq -r '[.families[].family] | join(",")' <<<"$json")" \
  'gemini-3.8-flash,gemini-3.7-flash,gemini-3.6-flash,gemini-3.1-pro'
assert_eq "$(jq -r '.schema, .window_min, (.valid_until - .generated_at), .thresholds.slow_step_s' <<<"$json" | tr '\n' ' ')" \
  '1 60 3600 9 '
assert_eq "$(family gemini-3.7-flash state)" ok
assert_eq "$(family gemini-3.7-flash runs)" 2
assert_eq "$(family gemini-3.7-flash steps)" 7
assert_eq "$(family gemini-3.7-flash median_step_s)" 3.0
assert_eq "$(family gemini-3.7-flash last_step_age_s)" 294
assert_eq "$(family gemini-3.6-flash state)" slow
assert_eq "$(family gemini-3.6-flash median_step_s)" 20.0
assert_eq "$(family gemini-3.6-flash p90_step_s)" 20.0
assert_eq "$(family gemini-3.6-flash errors_503)" 0
assert_eq "$(family gemini-3.6-flash runs)" 1
assert_eq "$(family gemini-3.8-flash state)" starved
assert_eq "$(family gemini-3.8-flash errors_503)" 2
assert_eq "$(family gemini-3.8-flash last_503_age_s)" 480
assert_eq "$(family gemini-3.8-flash short)" 3.8
assert_eq "$(family gemini-3.1-pro state)" ok
assert_eq "$(family gemini-3.1-pro label)" '3.1 pro'
assert_eq "$(family gemini-3.1-pro short)" 3.1p
assert_eq "$(family gemini-3.1-pro median_step_s)" 4.0

# The cache is the JSON that was printed.
assert test -f "$GEMINI_WEATHER_DIR/latest.json"
assert_eq "$(jq -c . "$GEMINI_WEATHER_DIR/latest.json")" "$(jq -c . <<<"$json")"

# A narrower window drops the Pro run and ages 3.8's first 503 out.
narrow=$("$WEATHER" --json --no-write --window 15)
assert_eq "$(jq -r '.families[] | select(.family == "gemini-3.1-pro") | .state' <<<"$narrow")" no-data
assert_eq "$(jq -r '.families[] | select(.family == "gemini-3.8-flash") | .errors_503' <<<"$narrow")" 1
assert_eq "$(jq -r '.families[] | select(.family == "gemini-3.8-flash") | .median_step_s' <<<"$narrow")" null

# The hold marker alone starves a family with no traffic, and only while it is inside the window.
: >"$GEMINIB_CACHE_DIR/capacity/gemini-3.7-flash"
touch -r "$BENCH/agy-agy-flash37-high.log" "$GEMINIB_CACHE_DIR/capacity/gemini-3.7-flash"
held=$("$WEATHER" --json --no-write)
assert_eq "$(jq -r '.families[] | select(.family == "gemini-3.7-flash") | "\(.state) \(.hold_age_s)"' <<<"$held")" 'starved 591'
python3 -c 'import os,sys; t=int(sys.argv[2])-7200; os.utime(sys.argv[1],(t,t))' "$GEMINIB_CACHE_DIR/capacity/gemini-3.7-flash" "$NOW"
aged=$("$WEATHER" --json --no-write)
assert_eq "$(jq -r '.families[] | select(.family == "gemini-3.7-flash") | "\(.state) \(.hold_age_s)"' <<<"$aged")" 'ok 7200'

# A capacity relaunch appends the next family's attempt to the same log: each attempt keeps its own.
mklog "$GEMINIB_CACHE_DIR/logs/relaunch.log" gemini-3.8-flash-high 503:100
mklog "$WORK/second.log" gemini-3.7-flash-high 90 87
cat "$WORK/second.log" >>"$GEMINIB_CACHE_DIR/logs/relaunch.log"
touch -r "$WORK/second.log" "$GEMINIB_CACHE_DIR/logs/relaunch.log"
relaunch=$("$WEATHER" --json --no-write)
assert_eq "$(jq -r '.families[] | select(.family == "gemini-3.8-flash") | .errors_503' <<<"$relaunch")" 3
assert_eq "$(jq -r '.families[] | select(.family == "gemini-3.7-flash") | "\(.runs) \(.steps)"' <<<"$relaunch")" '3 9'
rm -f "$GEMINIB_CACHE_DIR/logs/relaunch.log" "$GEMINIB_CACHE_DIR/capacity/gemini-3.7-flash"

# The table: one header, one row per family, and one state line per family.
table=$("$WEATHER" --no-write)
assert grep -Eq '^FAMILY +STATE +RUNS +STEPS +MED S +P90 S +503 +LAST 503 +LAST STEP +HOLD$' <<<"$table"
assert grep -Eq '^gemini-3\.8-flash +starved +1 +3 +3\.0 +3\.0 +2 +8m +19m +-$' <<<"$table"
assert grep -Eq '^gemini-3\.6-flash +slow +1 +4 +20\.0 +20\.0 +0 +- +14m +-$' <<<"$table"
assert_eq "$(grep '^state: ' <<<"$table" | tr '\n' ';')" \
  'state: gemini-3.8-flash starved;state: gemini-3.7-flash ok;state: gemini-3.6-flash slow;state: gemini-3.1-pro ok;'
assert grep -Fq 'cache not written' <<<"$table"

# Nothing on disk at all reads no-data for every known family.
empty=$(HOME="$WORK/empty" CLAUDEB_DIR="$WORK/empty" WORKER_RUN_DIR="$WORK/empty" GEMINIB_PROFILES_DIR="$WORK/empty" \
  GEMINIB_CACHE_DIR="$WORK/empty" "$WEATHER" --json --no-write)
assert_eq "$(jq -r '[.families[].state] | unique | join(",")' <<<"$empty")" no-data
"$WEATHER" --window 0 >/dev/null 2>&1 && fail "a zero window was accepted"
asserts=$((asserts + 1))

printf 'PASS: %s asserts; gemini-weather (healthy, slow, starved, hold marker, window cut-off, relaunch segments, dedup, table, JSON, cache)\n' "$asserts"
