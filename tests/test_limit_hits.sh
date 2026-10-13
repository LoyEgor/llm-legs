#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# The limit-hit journal: both writers' line, the limits.json registry both ways, and the Harness
# doctor's Limits section over a fixture journal and fixture registries.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
assert_eq() { asserts=$((asserts + 1)); [ "$1" = "$2" ] || fail "assert $asserts: expected [$1], got [$2]${3:+ ($3)}"; }
export LIMIT_HITS_LOG="$WORK/hits.jsonl"

anchor_line() { grep -n -m1 -F -- "$2" "$ROOT/$1" | cut -d: -f1; }

LIMIT_HITS_LOG="$WORK/py.jsonl" python3 "$ROOT/share/limit_hit.py" probe.py 30 s kill "the answer" \
  'bin/claudeb:CLAUDEB_LOCK_RETRIES' --observed 40 --usual 10 --session sess-1
assert_eq "llm-legs:probe.py|30|s|kill|the answer|bin/claudeb:$(anchor_line bin/claudeb CLAUDEB_LOCK_RETRIES)|40|10|sess-1" \
  "$(jq -r '[.limit, .value, .unit, .action, .lost, .where, .observed, .usual, .session] | map(tostring) | join("|")' "$WORK/py.jsonl")"

(
  . "$ROOT/share/limit-hit.sh"
  WORKER_RUN_ID=run-1 limit_hit probe.sh 5 count drop $'two\nlines "quoted"' 'bin/worker-run:IDLE=${' 3
  limit_hit other:probe.sh 7 bytes trim lost bin/worker-run:12
)
assert_eq "llm-legs:probe.sh|5|count|drop|two lines \"quoted\"|bin/worker-run:$(anchor_line bin/worker-run 'IDLE=${')|3|null|run-1" \
  "$(jq -r 'select(.limit == "llm-legs:probe.sh") | [.limit, .value, .unit, .action, .lost, .where, .observed, .usual, .run]
    | map(tostring) | join("|")' "$WORK/hits.jsonl" | tr '\n' ' ' | sed 's/ $//')" \
  "bash writer line"
assert_eq "other:probe.sh bin/worker-run:12" "$(jq -r 'select(.limit == "other:probe.sh") | "\(.limit) \(.where)"' "$WORK/hits.jsonl")"

long=$(printf 'ж%.0s' $(seq 1 5000))
LIMIT_HITS_LOG="$WORK/long.jsonl" python3 "$ROOT/share/limit_hit.py" long.py 1 s kill "$long" bin/claudeb:1
( . "$ROOT/share/limit-hit.sh"; LIMIT_HITS_LOG="$WORK/long.jsonl" limit_hit long.sh 1 s kill "$long" bin/claudeb:1 )
assert_eq 2 "$(jq -c . "$WORK/long.jsonl" | wc -l | tr -d ' ')"
assert_eq "" "$(LC_ALL=C awk 'length($0) > 3500' "$WORK/long.jsonl")"

for i in $(seq 1 24); do
  ( . "$ROOT/share/limit-hit.sh"; LIMIT_HITS_LOG="$WORK/race.jsonl" limit_hit "race.$i" "$i" count drop "$long" bin/claudeb:1 ) &
done
wait
assert_eq 24 "$(jq -c 'select(.lost | length == 600)' "$WORK/race.jsonl" | wc -l | tr -d ' ')" "parallel long lines stay whole"

: >"$WORK/not-a-dir"
( . "$ROOT/share/limit-hit.sh"; LIMIT_HITS_LOG="$WORK/not-a-dir/x.jsonl" limit_hit broken 1 s kill x bin/claudeb:1; echo "rc=$?" ) \
  >"$WORK/broken.out" 2>/dev/null
assert_eq rc=0 "$(cat "$WORK/broken.out")"
LIMIT_HITS_LOG="$WORK/not-a-dir/x.jsonl" python3 -c "
import sys; sys.path.insert(0, '$ROOT/share'); import limit_hit
limit_hit.hit('broken', 1, 's', 'kill', 'x', 'bin/claudeb:1'); print('alive')" >"$WORK/broken.out" 2>/dev/null
assert_eq alive "$(cat "$WORK/broken.out")"

# A probe's timeout journals a kill named by its command; any other failure of the probe journals nothing.
LIMIT_HITS_LOG="$WORK/expired.jsonl" python3 -c "
import subprocess, sys; sys.path.insert(0, '$ROOT/share'); import limit_hit
try:
    subprocess.run(['sleep', '5'], timeout=0.2)
except subprocess.SubprocessError as error:
    limit_hit.expired('probe.git', error, 'read as none', 'bin/claudeb:1')
limit_hit.expired('probe.git', subprocess.TimeoutExpired(['git', '-C', '$WORK', 'log', '-1'], 0.2), 'read as none', 'bin/claudeb:1')
limit_hit.expired('probe.git', subprocess.CalledProcessError(1, ['git']), 'read as none', 'bin/claudeb:1')
limit_hit.expired('probe.git', OSError('gone'), 'read as none', 'bin/claudeb:1')"
assert_eq "llm-legs:probe.git|0.2|s|kill|0.2|sleep 5: read as none llm-legs:probe.git|0.2|s|kill|0.2|git log -1: read as none" \
  "$(jq -r '[.limit, .value, .unit, .action, .observed, .lost] | map(tostring) | join("|")' "$WORK/expired.jsonl" | paste -sd' ' -)" \
  "expired: timeouts only, the command ahead of the loss, git's -C dropped"

python3 - "$ROOT" <<'EOF' || fail "registry check"
import json, os, re, subprocess, sys
root = sys.argv[1]
with open(os.path.join(root, "limits.json")) as handle:
    text = handle.read()
registry = json.loads(text)
assert list(registry) == sorted(registry), "limits.json is not sorted by name"
units = {"s", "bytes", "rows", "count", "chars", "pct"}
calls = {}
out = subprocess.run(["grep", "-rnE", "--exclude=*.json", r'(limit_hit|tag_limit_hit) [a-z][a-z0-9.-]+ |limit_hit\.(hit|expired)\("[a-z][a-z0-9.-]+"', "bin", "share", "hammerspoon",
                      *[f for f in os.listdir(root) if f.endswith((".sh", ".py"))]],
                     cwd=root, capture_output=True, text=True).stdout
for found in out.splitlines():
    path, _, text = found.split(":", 2)
    match = re.search(r'(?:limit_hit|tag_limit_hit) ([a-z][a-z0-9.-]+) (.*)|limit_hit\.(hit|expired)\("([a-z][a-z0-9.-]+)",(.*)', text)
    name, rest = (match.group(1), match.group(2)) if match.group(1) else (match.group(4), match.group(5))
    unit = "s" if match.group(3) == "expired" else next((w for w in re.split(r'[\s",]+', rest) if w in units), None)
    calls.setdefault(name, set()).add((path, unit))
unregistered = sorted(set(calls) - set(registry))
unused = sorted(set(registry) - set(calls))
assert not unregistered, "hit names missing from limits.json: %s" % unregistered
assert not unused, "limits.json entries no code hits: %s" % unused
for name, entry in registry.items():
    assert set(entry) == {"value", "unit", "where", "set_by", "why", "normal"}, name
    assert isinstance(entry["value"], (int, float)) and entry["unit"] in units, name
    assert re.fullmatch(r"(Egor|chat|night|worker)( [0-9a-f]{7,40})?", entry["set_by"]), name
    assert entry["why"].strip() and entry["normal"].strip(), name
    assert os.path.isfile(os.path.join(root, entry["where"].split(":")[0])), name
    for path, unit in calls[name]:
        assert unit == entry["unit"], "%s hits in %s with unit %s, registered %s" % (name, path, unit, entry["unit"])
print("registry ok: %d limits" % len(registry))
EOF
asserts=$((asserts + 1))

REPOS="$WORK/repos"
mkdir -p "$REPOS/llm-legs" "$REPOS/claude-setup" "$REPOS/token-map"
cat >"$REPOS/llm-legs/limits.json" <<'EOF'
{"a.fresh": {"value": 30, "unit": "s", "where": "bin/x:1", "set_by": "chat", "why": "w", "normal": "n"},
 "a.ok": {"value": 30, "unit": "s", "where": "bin/x:2", "set_by": "chat", "why": "w", "normal": "n"},
 "a.ratio": {"value": 30, "unit": "s", "where": "bin/x:3", "set_by": "Egor", "why": "his", "normal": "rarely"}}
EOF
echo '{}' >"$REPOS/claude-setup/limits.json"
echo 'not json' >"$REPOS/token-map/limits.json"
now=$(date +%s)
journal() { # first-hit-age-s
  {
    printf '{"ts":%s,"limit":"llm-legs:a.ok","value":30,"unit":"s","action":"kill","lost":"old"}\n' "$((now - $1))"
    printf '{"ts":%s,"limit":"llm-legs:a.ok","value":30,"unit":"s","observed":60,"usual":30,"action":"kill","lost":"ok"}\n' "$((now - 3600))"
    printf '{"ts":%s,"limit":"llm-legs:a.ratio","value":30,"unit":"s","observed":20,"usual":10,"action":"kill","lost":"r1"}\n' "$((now - 2 * 86400))"
    printf '{"ts":%s,"limit":"llm-legs:a.ratio","value":30,"unit":"s","observed":60,"usual":10,"action":"kill","lost":"r2","where":"bin/x:3"}\n' "$((now - 3600))"
    printf '{"ts":%s,"limit":"llm-legs:a.fresh","value":30,"unit":"s","action":"kill","lost":"f"}\n' "$((now - 1800))"
    printf '{"ts":%s,"limit":"llm-legs:unknown","value":1,"unit":"count","action":"drop","lost":"u"}\n' "$((now - 3 * 86400))"
    printf '{"ts":%s,"limit":"review-bench:b.x","value":1,"unit":"count","action":"drop","lost":"b"}\n' "$((now - 600))"
    printf '{"ts":%s,"limit":"claude-setup:c.unreg","value":1,"unit":"count","action":"drop","lost":"c"}\n' "$((now - 2 * 86400))"
  } >"$WORK/fixture.jsonl"
}
limits() { # -> red rows, lead lines and state of the Limits section
  LIMIT_HITS_LOG="$WORK/fixture.jsonl" LIMIT_REPOS_DIR="$REPOS" python3 - "$ROOT/bin/harness-doctor" "$now" <<'EOF'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("harness_doctor", sys.argv[1])
module = importlib.util.module_from_spec(importlib.util.spec_from_loader("harness_doctor", loader))
loader.exec_module(module)
out = module.limits_section(float(sys.argv[2]))
red = sorted(r["cells"][0] for r in out["rows"] if r["red"])
levels = sorted({v["level"] or "-" for r in out["rows"] for v in r["judge"]})
leads = [l["say"].split(" ")[0] for l in out.get("lead") or ()]
print("red=%s levels=%s leads=%s state=%s rows=%d" % (",".join(red), ",".join(levels), ",".join(leads), out["state"], len(out["rows"])))
EOF
}
journal $((9 * 86400))
assert_eq "red=claude-setup:c.unreg,llm-legs:a.fresh,llm-legs:a.ratio,llm-legs:unknown,review-bench:b.x levels=-,red leads=review-bench,token-map state=problem rows=6" \
  "$(limits)" "ratio, fresh after 7 quiet days, unregistered in a readable registry"
journal $((2 * 86400))
assert_eq "red=claude-setup:c.unreg,llm-legs:a.ratio,llm-legs:unknown levels=-,red leads=review-bench,token-map state=problem rows=6" \
  "$(limits)" "a journal younger than 8 d proves no quiet week"
journal $((10 * 86400))
LIMIT_HITS_LOG="$WORK/fixture.jsonl" python3 - "$WORK/fixture.jsonl" <<'EOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
keep = [r for r in rows if r["limit"] in ("llm-legs:a.ok", "review-bench:b.x")]
for r in keep:
    if r["limit"] == "review-bench:b.x":
        r["ts"] -= 3 * 86400
open(sys.argv[1], "w").write("".join(json.dumps(r) + "\n" for r in keep))
EOF
assert_eq "red= levels=- leads=review-bench,token-map state=watch rows=2" "$(limits)" "no fault: a missing registry still shows"

echo "PASS: $asserts asserts; both writers' line, anchor resolution, the line cap, whole lines under racing writers, write failures that change nothing, limits.json both ways with units, and the Harness Limits section's ratio, quiet-week, unregistered and missing-registry rules"
