#!/usr/bin/env bash
# llm-weather reads fixture bench and worker-run stores under a temp HOME: no real store is reachable.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEATHER="$ROOT/bin/llm-weather"
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
export WORKER_STATS_DIR="$HOME/stats" WORKER_RUN_DIR="$HOME/runs" LLM_WEATHER_DIR="$HOME/weather"
NOW=$(( $(date +%s) / 60 * 60 ))
export LLM_WEATHER_NOW="$NOW"

python3 - "$NOW" "$WORKER_STATS_DIR/benches" "$WORKER_RUN_DIR" <<'PY'
import json, os, sys, time
now, benches, runs = int(sys.argv[1]), sys.argv[2], sys.argv[3]
SESSION = "1704c529-ba45-4acb-bf5f-ccc125f34aa2"

def run_id(offset, suffix):
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(now - offset)) + "-" + suffix

def iso(offset):
    return time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(now - offset))

def cell(model, rater=None, ended=7000, duration=60000, exit_code=0, stderr="", findings=2, **extra):
    row = {"rater": rater or model + "-high", "model": model, "account": "acct", "duration_ms": duration,
           "exit_code": exit_code, "findings": findings, "stderr": stderr,
           "started_at": iso(ended + duration // 1000), "finished_at": iso(ended)}
    row.update(extra)
    return row

def bench(offset, suffix, cells, **extra):
    directory = os.path.join(benches, run_id(offset, suffix))
    os.makedirs(directory)
    meta = {"run_id": os.path.basename(directory), "session": SESSION,
            "repo": "/Volumes/Work/Projects/llm-legs/.claude/worktrees/feat-a", "rater_runs": cells}
    meta.update(extra)
    with open(os.path.join(directory, "meta.json"), "w") as handle:
        json.dump(meta, handle)

bench(7300, "aaa1111", [
    cell("sol", rater="sol-1", duration=100000), cell("sol", rater="sol-2", duration=100000),
    cell("sol", rater="sol-3", duration=100000), cell("sol", rater="sol-4", duration=100000),
    cell("sol", rater="sol-5", duration=100000), cell("sol", rater="sol-6", duration=300000, ended=6000),
    cell("agy-flash38", rater="f38-a", exit_code=1, errored=True, stderr="Individual quota reached", findings=0),
    cell("agy-flash38", rater="f38-b", exit_code=1, errored=True, stderr="429 Too Many Requests", findings=0),
    cell("agy-flash38", rater="f38-c", served_model="gemini-3.7-flash-high", killed="watchdog",
         duration=407000, exit_code=1, errored=True, stderr="Error: timeout waiting for response"),
    cell("grok", rater="grok-high"),
    cell("oc-kimik3", exit_code=1, errored=True, stderr="agy -skill returned malformed Markdown", findings=0),
    cell("oc-kimik3", rater="kimik3-b", exit_code=1, errored=True, stderr="HTTP 503 upstream", findings=0),
    cell("oc-kimik3", rater="kimik3-c", exit_code=1, errored=True, stderr="error: context canceled", findings=0),
    cell("agy-flash36", exit_code=1, errored=True, findings=0, timeout_s=990,
         stderr="agy returned empty output: [agy] print timeout after 16m30s with turn in progress"),
    cell("oc-glm", exit_code=1, errored=True, findings=0, timeout_s=600, stderr="Error: authentication timed out."),
    cell("agy-pro", killed="stall", stalled_s=300, exit_code=1, errored=True, stderr="rater stalled", ended=5000),
    cell("oc-haiku", rater="haiku-1", duration=0), cell("oc-haiku", rater="haiku-2", duration=0),
    cell("agy-pro", rater="pro-w"),
], clone_escapes=[["grok-high", "acct", "/Users/someone/.gemini/brain/" + SESSION + "/scratch"]],
   write_evidence=[["pro-w", "acct", "/Volumes/Work/Projects/llm-legs/bin/x"]])

bench(3600, "bbb2222", [
    cell("agy-flash38", rater="f38-x", exit_code=1, errored=True, stderr="usage limit", ended=3000),
], cancelled=True)

old_cells = [cell("agy-flash38", rater="f38-old-%d" % n, ended=3 * 86400) for n in range(5)]
old_cells.append(cell("agy-flash38", rater="f38-old-wall", exit_code=1, errored=True,
                      stderr="has no codex account left", findings=0, ended=3 * 86400))
old_cells += [cell("oc-haiku", rater="haiku-old-%d" % n, duration=0, exit_code=1, errored=True,
                   stderr="no result event in the claude stream", findings=0, ended=3 * 86400)
              for n in range(3)]
bench(3 * 86400 + 600, "ccc3333", old_cells,
      repo="/Users/someone/.claude-profiles/.claudeb/worker-stats/merged/e807d71a50caebfd",
      repos=[{"label": "review-bench", "repo": "/Volumes/Work/Projects/review-bench"}])

bench(10 * 86400, "ddd4444", [cell("agy-flash38", rater="f38-ancient", exit_code=1, errored=True,
                                    stderr="usage limit", findings=0, ended=10 * 86400)])

def worker(prefix, started_offset, ended_offset, tag, workdir="/Volumes/Work/Projects/llm-legs", **files):
    name = "%s-%d-%d-%s" % (prefix, now - started_offset, 4000 + started_offset, "ab%02x" % (started_offset % 256))
    directory = os.path.join(runs, name)
    os.makedirs(directory)
    files.setdefault("launcher", SESSION + "\n")
    files["tag"] = tag + "\n"
    files["meta.json"] = json.dumps({"vendor": prefix, "workdir": workdir, "started_at": now - started_offset})
    for filename, content in files.items():
        with open(os.path.join(directory, filename), "w") as handle:
            handle.write(content)
        os.utime(os.path.join(directory, filename), (now - ended_offset, now - ended_offset))
    return name

worker("claudeb", 1600, 1000, "acct · opus · high", exit_code="0\n",
       **{"files-note": "2 path(s) changed in the checkout during the run by another writer and are not this run's: a, b\n"
                       "9 path(s) changed in the run's window that its own listing does not name and nobody answered for\n"
                       "UNKNOWN: transcript names a write outside the snapshotted repository; no content baseline was recorded: /tmp/probe.sh\n"
                       "UNKNOWN: transcript names a write outside the snapshotted repository; no content baseline was recorded: /private/tmp/claude-501/x/scratchpad/a.json\n"
                       "UNKNOWN: transcript names a write outside the snapshotted repository; no content baseline was recorded: " + os.environ["HOME"] + "/.cache/nudge/a.focus\n"})
worker("claudeb", 2400, 900, "acct · opus · high", exit_code="143\n", killed="silent 300\n")
worker("codexb", 3000, 800, "acct · astra · medium", exit_code="0\n", result="OUTCOME: CODEX_USAGE_LIMIT\nrest\n")
worker("grok", 4000, 700, "acct · grok · high", exit_code="1\n", **{"workdir-escape": "x\n"})
worker("grok", 4100, 600, "acct · grok · high", exit_code="0\n",
       **{"files-note": "UNKNOWN: transcript names a write outside the snapshotted repository; no content baseline was recorded: /tmp/ok.sh\n"
                        "UNKNOWN: transcript names a write outside the snapshotted repository; no content baseline was recorded: /Volumes/Other/repo/file.py\n"})
worker("grok", 4200, 500, "acct · grok · high", exit_code="143\n", killed="deadline 1800\n")
worker("grok", 4300, 400, "acct · grok · high", exit_code="2\n",
       workdir="/Users/someone/proj/.claude/worktrees/fix-b")
worker("grok", 4400, 300, "acct · grok · high")
worker("gemini", 5000, 200, "acct · flash38 · high", killed="wall\n")
worker("claudeb", 2 * 86400, 2 * 86400, "acct · fable · high", exit_code="0\n")
os.makedirs(os.path.join(runs, "walls"))
PY

json=$("$WEATHER" --json) || fail "llm-weather --json exited nonzero"
assert test ! -e "$LLM_WEATHER_DIR/latest.json"
model() { jq -c --arg m "$1" ".models[] | select(.model == \$m) | $2" <<<"$json"; }

assert_eq "$(jq -c 'keys' <<<"$json")" '["as_of","models","trend_d","window_h","worst"]'
assert_eq "$(jq -r '"\(.as_of - '"$NOW"') \(.window_h) \(.trend_d)"' <<<"$json")" '0 24 7'
assert_eq "$(jq -c '[.models[0] | keys[]]' <<<"$json")" \
  '["bad","classes","incidents","legs","model","origins","surfaces","trend"]'
assert_eq "$(jq -r '[.models[] | "\(.model):\(.legs)/\(.bad)"] | join(",")' <<<"$json")" \
  'grok:5/5,flash38:3/3,kimik3:3/3,pro:2/2,sol:6/1,opus:2/1,astra:1/1,flash36:1/1,flash37:1/1,glm:1/1,haiku:2/0'
assert_eq "$(jq -r '.worst' <<<"$json")" 'grok escaped ×3 · flash38 walled ×3'

assert_eq "$(model grok .classes)" '{"escaped":3,"cap":1,"failed":1}'
assert_eq "$(model grok .surfaces)" '["review","worker"]'
assert_eq "$(model grok '[.incidents[].detail]')" '["exit 2","deadline 1800s","outside write","workdir-escape","outside write"]'
assert_eq "$(model grok '[.incidents[].project]')" '["proj/fix-b","llm-legs","llm-legs","llm-legs","llm-legs/feat-a"]'
assert_eq "$(model grok '[.incidents[].age_s] == ([.incidents[].age_s] | sort)')" 'true'
assert_eq "$(model grok '.incidents[0] | "\(.age_s) \(.age) \(.surface) \(.class)"')" '"400 6m worker failed"'
assert_eq "$(model flash38 .classes)" '{"walled":3}'
assert_eq "$(model flash38 .surfaces)" '["review","worker"]'
assert_eq "$(model flash38 '[.incidents[].detail]')" '["wall","walled","throttled"]'
assert_eq "$(model flash38 .trend)" '"up"'
assert_eq "$(model flash37 '.incidents[0] | "\(.class) \(.detail) \(.age)"')" '"cap watchdog 407s 1h"'
assert_eq "$(model sol '.incidents[0] | "\(.class) \(.detail)"')" '"slow 5m vs 2m median"'
assert_eq "$(model sol .trend)" '""'
assert_eq "$(model opus '.incidents[0] | "\(.class) \(.detail)"')" '"stalled silent 300s"'
assert_eq "$(model opus .classes)" '{"stalled":1}'
assert_eq "$(model astra '.incidents[0] | "\(.class) \(.detail)"')" '"walled usage limit"'
assert_eq "$(model kimik3 '.incidents[0] | "\(.class) \(.detail)"')" '"failed bad output"'
assert_eq "$(model kimik3 .classes)" '{"failed":3}'
assert_eq "$(model kimik3 .origins)" '{"ours":1,"theirs":2}'
assert_eq "$(model kimik3 '[.incidents[] | "\(.detail) \(.origin)"]')" '["bad output ours","server error theirs","cancelled theirs"]'
assert_eq "$(model flash38 .origins)" '{}'
assert_eq "$(model flash38 '[.incidents[].origin] | unique')" '[""]'
assert_eq "$(model grok '[.incidents[].origin] | unique')" '[""]'
assert_eq "$(model flash36 '.incidents[0] | "\(.class) \(.detail)"')" '"cap print timeout 16m"'
assert_eq "$(model glm '.incidents[0] | "\(.class) \(.detail)"')" '"cap timeout 600s"'
assert_eq "$(model pro '.incidents[0] | "\(.class) \(.detail)"')" '"stalled stall 300s"'
assert_eq "$(model pro '.incidents[1] | "\(.class) \(.detail)"')" '"escaped outside write"'
assert_eq "$(model haiku '"\(.classes) \(.trend) \(.incidents)"')" '"{} down []"'
assert_eq "$(jq '[.models[] | select(.model == "fable")] | length' <<<"$json")" 0
assert_eq "$(jq '[.. | strings | select(test("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-|^/"))] | length' <<<"$json")" 0
assert_eq "$(jq '[.models[].incidents[].detail | select(length > 40)] | length' <<<"$json")" 0

# The default run writes the cache atomically and it is the document --json printed.
summary=$("$WEATHER") || fail "llm-weather exited nonzero"
assert_eq "$summary" 'llm-weather: 11 models · grok escaped ×3 · flash38 walled ×3'
assert_eq "$(jq -c . "$LLM_WEATHER_DIR/latest.json")" "$(jq -c . <<<"$json")"
assert_eq "$(ls -A "$LLM_WEATHER_DIR" | tr '\n' ' ')" 'latest.json '

rm -f "$LLM_WEATHER_DIR/latest.json"
dry=$("$WEATHER" --dry-run)
assert_eq "$dry" "$summary"
assert test ! -e "$LLM_WEATHER_DIR/latest.json"

# A 96 h window reaches the 3-day-old run (its merged clone named by the repo it reviewed) but not the 10-day one.
wide=$("$WEATHER" --json --window 96)
assert_eq "$(jq -r '.window_h' <<<"$wide")" 96
assert_eq "$(jq -r '.models[] | select(.model == "flash38") | "\(.legs) \(.bad) \(.classes.walled)"' <<<"$wide")" '9 4 4'
assert_eq "$(jq -r '.models[] | select(.model == "flash38") | .incidents[-1].project' <<<"$wide")" review-bench
assert_eq "$(jq -r '.models[] | select(.model == "fable") | .legs' <<<"$wide")" 1

empty=$(WORKER_STATS_DIR="$WORK/none" WORKER_RUN_DIR="$WORK/none" "$WEATHER" --json)
assert_eq "$(jq -c '[.models, .worst]' <<<"$empty")" '[[],""]'
assert_eq "$(WORKER_STATS_DIR="$WORK/none" WORKER_RUN_DIR="$WORK/none" "$WEATHER" --dry-run)" 'llm-weather: 0 models · ok'
"$WEATHER" --window 0 >/dev/null 2>&1 && fail "a zero window was accepted"
asserts=$((asserts + 1))

printf 'PASS: %s asserts; llm-weather (every class, cancelled run, co-tenant note, served model, slow median, trend, sort, worst, window, atomic cache)\n' "$asserts"
