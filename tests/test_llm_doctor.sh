#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# llm-doctor reads fixture bench, worker-run and image-leg stores under a temp HOME: no real store is reachable.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCTOR="$ROOT/bin/llm-doctor"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }

unset XDG_CACHE_HOME WORKER_CLAIMS_DIR WORKER_WALLS_DIR GEMINI_WEB_DIR CHATGPT_WEB_DIR CLAUDEGPT_HOME \
  CODEXB_PROFILES_DIR GEMINIB_PROFILES_DIR GROKB_PROFILES_DIR LLM_LIMITS_GEMINI_ACCOUNTS_DIR \
  LLM_LIMITS_CODEX_CACHE LLM_LIMITS_CODEX_REMOVED LLM_LIMITS_GROK_CACHE GROKB_MAIN_GROK_HOME OPENCODE_GO_PROFILES \
  STATUSLINE_CACHE_DIR
export HOME="$WORK/home" CLAUDEB_DIR="$WORK/home/.claude-profiles/.claudeb"
export WORKER_STATS_DIR="$HOME/stats" WORKER_RUN_DIR="$HOME/runs" LLM_DOCTOR_DIR="$HOME/doctor"
export IMAGE_LEG_LOG="$HOME/image-legs/legs.jsonl" LLM_DOCTOR_LEDGER="$WORK/ledger.json"
export GEMINIB_CACHE_DIR="$WORK/geminib"
# The Mac's own reboots would turn every fixture run with no exit into one the reboot took down.
export LLM_DOCTOR_REBOOTS=""
unset REVIEW_DEBT_DIR
mkdir -p "$GEMINIB_CACHE_DIR"
cat >"$GEMINIB_CACHE_DIR/models.json" <<'JSON'
{"fetched_at": 1, "attempted_at": 1, "families": [
  {"family": "gemini-3.8-flash", "slug": "flash38", "agy_prefix": "gemini-3.8-flash", "label": "Gemini 3.8 Flash"}
]}
JSON
NOW=$(( $(date +%s) / 60 * 60 ))
export LLM_DOCTOR_NOW="$NOW"
mkdir -p "$WORK/bin"
cat >"$WORK/bin/review-anchors" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ANCHORS_ARGS"
[ -n "${ANCHORS_EXIT:-}" ] && exit "$ANCHORS_EXIT"
cat "$ANCHORS_ROWS"
SH
chmod +x "$WORK/bin/review-anchors"
export PATH="$WORK/bin:$PATH" ANCHORS_ARGS="$WORK/anchors-args" ANCHORS_ROWS="$WORK/anchors-rows.jsonl"
printf '{"session":"s1","kind":"touch-failed","detail":"/repo: review-anchors exited 1","count":2,"first":%d,"last":%d}\n{"session":"s1","kind":"hash-cap","detail":"/repo: more than 500 dirty paths","count":1090,"first":%d,"last":%d}\n{"session":"s1","kind":"hash-cap","detail":"/repo: 2 capped paths changed, first a.py","count":1,"first":%d,"last":%d}\n{"session":"s1","kind":"fixer-missing","detail":"R1 run-a","count":1,"first":%d,"last":%d}\n{"session":"s1","kind":"fixer-missing","detail":"R2 run-b","count":1,"first":%d,"last":%d}\n{"session":"s1","kind":"run-fold","detail":"w-1 /r: snapshots unreadable","count":1,"first":%d,"last":%d}\n{"session":"s1","kind":"run-fold","detail":"w-2 /r: review-anchors exited 1: boom","count":1,"first":%d,"last":%d}\n' \
  "$((NOW - 1800))" "$((NOW - 900))" "$((NOW - 259200))" "$((NOW - 259140))" "$((NOW - 259000))" "$((NOW - 259000))" \
  "$((NOW - 3000))" "$((NOW - 3000))" "$((NOW - 2000))" "$((NOW - 2000))" "$((NOW - 1500))" "$((NOW - 1500))" \
  "$((NOW - 1400))" "$((NOW - 1400))" >"$ANCHORS_ROWS"

export LLM_DOCTOR_REPOS="$WORK/repos"
FIXREPO="$LLM_DOCTOR_REPOS/review-bench"
mkdir -p "$FIXREPO/share/rbench"
fixgit() { git -C "$FIXREPO" -c user.name=t -c user.email=t@t "$@" >/dev/null; }
fixgit init -q
for file in cell_runtime report; do echo "$file" >"$FIXREPO/share/rbench/$file.py"; done
fixgit add -A
GIT_COMMITTER_DATE="@$((NOW - 30000))" GIT_AUTHOR_DATE="@$((NOW - 30000))" fixgit commit -q -m base
RUNTIME_COMMIT=$(git -C "$FIXREPO" rev-parse --short HEAD)
echo changed >>"$FIXREPO/share/rbench/report.py"
echo panel >"$FIXREPO/share/rbench/panel.py"
fixgit add share/rbench/panel.py
fixgit commit -q -m panel
PANEL_COMMIT=$(git -C "$FIXREPO" rev-parse --short HEAD)
printf '{"runtime": "review-bench@%s", "panel": "review-bench@%s"}\n' "$RUNTIME_COMMIT" "$PANEL_COMMIT" >"$WORK/commits.json"

python3 - "$NOW" "$WORKER_STATS_DIR/benches" "$WORKER_RUN_DIR" "$IMAGE_LEG_LOG" "$LLM_DOCTOR_LEDGER" "$LLM_DOCTOR_DIR" <<'PY'
import json, os, sys, time
now = int(sys.argv[1])
benches, runs, image_log, ledger, doctor = sys.argv[2:7]

def iso(offset):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - offset))

def iso_local(offset):
    return time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(now - offset))

def bench(offset, suffix, rows, **meta):
    name = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(now - offset - 600)) + "-" + suffix
    os.makedirs(os.path.join(benches, name))
    document = {"repo": "/Volumes/Work/Projects/llm-legs", "tier": "T2", "rater_runs": rows}
    document.update(meta)
    json.dump(document, open(os.path.join(benches, name, "meta.json"), "w"))
    return name

def cell(rater, model, offset, exit_code=0, stderr="", duration_s=100, **extra):
    row = {"rater": rater, "account": "main", "model": model, "exit_code": exit_code, "stderr": stderr,
           "duration_ms": duration_s * 1000, "finished_at": iso(offset), "findings": 1}
    row.update(extra)
    return row

clean = [cell("opus-%d" % index, "opus", 30000 + index * 60) for index in range(6)]
bench(30000, "aaaaaaa", clean)
bench(3 * 86400, "ddddddd", [cell("opus-old", "opus", 3 * 86400)])
# A cohort is model and effort: a high-effort leg is never judged against low-effort ones.
bench(50000, "eeeeeee", [cell("sonnet-low-%d" % index, "sonnet", 50000 - index * 60, effort="low")
                         for index in range(5)]
      + [cell("sonnet-low-slow", "sonnet", 40000, duration_s=300, effort="low"),
         cell("sonnet-high-first", "sonnet", 40000, duration_s=300, effort="high")])
# A model that turns 3x slower is slow for its first legs only, then its new speed is the norm.
bench(60000, "fffffff", [cell("haiku2-old-%d" % index, "haiku2", 60000 - index * 60) for index in range(5)]
      + [cell("haiku2-new-%d" % index, "haiku2", 50000 - index * 60, duration_s=300) for index in range(12)])
# Seconds-scale jitter stays under the absolute floor.
bench(60000, "ggggggg", [cell("tiny-%d" % index, "tiny", 60000 - index * 60, duration_s=5) for index in range(5)]
      + [cell("tiny-late", "tiny", 40000, duration_s=20)])
# Legs are judged against earlier legs of a similar input size: a 10x larger scope is unjudged, not slow.
bench(45000, "hhhhhhh", [cell("sz-%d" % index, "sz", 45000 - index * 60) for index in range(5)],
      scope_price={"files": 1, "lines": 100})
bench(44000, "iiiiiii", [cell("sz-big", "sz", 44000, duration_s=400)], scope_price={"files": 9, "lines": 1000})
bench(43000, "jjjjjjj", [cell("sz-same", "sz", 43000, duration_s=400)], scope_price={"files": 1, "lines": 150})
bench(3600, "bbbbbbb", session="cafebabe-0000-4000-8000-000000000001", rows=[
    cell("opus-high", "opus", 3600, duration_s=400),
    cell("opus-xhigh", "opus", 3600, duration_s=400, passes=4),
    cell("grok47-high", "grok47", 3700, exit_code=1, stderr=""),
    cell("grok47-high", "grok47", 3600, retry_of="weather: capacity"),
    cell("sol-high", "sol", 3600, exit_code=1, stderr="cell processing crashed: KeyError: 'spec'"),
    cell("flash38-high", "agy-flash38", 3600, exit_code=1,
         stderr="the pool has no gemini account left to run on; gemini is switched off for reviewers"),
    cell("pro-high", "agy-pro", 3600, exit_code=1, stderr="the pool has no gemini account left to run on"),
    cell("astra-high", "astra", 3600, exit_code=1, stderr="waiting (bounded by --print-timeout) then gone"),
    cell("grok-high", "grok", 3600, exit_code=1, killed="watchdog", duration_s=1200),
    cell("fable-high", "fable", 3600, exit_code=1, stderr="finishReason: SAFETY"),
    cell("sonnet-high", "sonnet", 3600, exit_code=1, stderr="rater SIGKILLed by the memory guard"),
    cell("haiku-high", "haiku", 3600, stderr="chunk 2: exit 1: HTTP 503 Service Unavailable"),
    cell("glm-high", "glm", 3600),
    cell("mini-high", "mini", 3600, stderr="chunk 1: exit -9: \nchunk 2: exit 1: Traceback (most recent call last):\n"
         "  File \"x.py\", line 1\nhttpx.HTTPStatusError: HTTP 503 Service Unavailable"),
], judge={"state": "failed", "reason": "the judge ruled on 3 of 5 claims", "model": "opus", "duration_ms": 9000},
   finished_at=iso(3500),
   integrity={"status": "changed", "roots": [{"root": "/Volumes/Work/Projects/other", "status": "changed",
                                              "changed": ["file.py"]}]},
   write_evidence=[["haiku-high", "main", "wrote /tmp/scratch/file"],
                   ["glm-high", "main", "wrote /Volumes/Work/Projects/other/file.py"]])
bench(18000, "ccccccc", [cell("sol-high", "sol", 18000, exit_code=1, stderr="cell processing crashed: OSError")])
# Started before X1's last fix and ended after it: the leg ran the old code.
bench(7000, "kkkkkkk", [cell("sol-high", "sol", 7000, exit_code=1, duration_s=400,
                             stderr="cell processing crashed: spanning the fix")])

def worker(vendor, offset, model, exit_code=None, files=None, meta=None, killed=None):
    started = now - offset - 300
    name = "%s-%d-%d-abcd%d" % (vendor, started, 100 + offset % 97, offset % 10)
    directory = os.path.join(runs, name)
    os.makedirs(directory)
    open(os.path.join(directory, "tag"), "w").write("main · %s · task\n" % model)
    document = {"vendor": vendor, "account": "main", "workdir": "/Volumes/Work/Projects/llm-legs", "role": "workers"}
    document.update(meta or {})
    json.dump(document, open(os.path.join(directory, "meta.json"), "w"))
    for key, value in (files or {}).items():
        open(os.path.join(directory, key), "w").write(value)
    if killed:
        open(os.path.join(directory, "killed"), "w").write(killed + "\n")
    if exit_code is not None:
        path = os.path.join(directory, "exit_code")
        open(path, "w").write("%d\n" % exit_code)
        os.utime(path, (now - offset, now - offset))
    return name

worker("codex", 3000, "astra", 0)
worker("grok", 3100, "grok-4.5", 1, {"err": "error: unknown effort level 'xhigh' for grok-4.5\n"})
worker("codex", 3200, "astra", 0, {"workdir-escape": "/tmp/x/scratch\n"})
worker("claudeb", 3300, "opus", 1, {"workdir-escape": "/Volumes/Work/Projects/other\n"})
worker("codex", 3400, "astra", 1, {"outcome": "CODEX_USAGE_LIMIT\n"}, {"walled_accounts": ["spare"]}, killed="wall")
worker("grok", 3500, "grok", 5, {"research-outcome": "READ_ONLY_VIOLATION\n", "launcher": "feedface-0000\n",
                                 "err": "the tree digest of /x could not be taken\n"}, {"role": "research"})
outside = "UNKNOWN: transcript names a write outside the snapshotted repository; no content baseline was recorded: "
worker("claudeb", 3600, "sonnet", 0, {"files-note": outside + "/Volumes/Work/Projects/other/x.py\n"})
worker("claudeb", 3650, "sonnet", 0, {"files-note": outside + "/Volumes/Work/Projects/granted/x.py\n"},
       {"add_dirs": ["/Volumes/Work/Projects/granted"]})
worker("codex", 3700, "astra", 1, {"result": "the client now retries on rate limit exceeded\n", "err": "boom\n"})
worker("codex", 3800, "astra", 0, {"light-verdict": "SCOPE: escaped other/stray.txt\n"}, {"light": "edit"})
# The test shell is alive but younger than the recorded supervisor: its pid was reused.
worker("claudeb", 30000, "opus", None, None, {"pid": os.getppid(), "pid_started_at": now - 30300})
# Liveness is share/run-liveness.sh's: a legacy record of a live supervisor keeps running, pid 0 is gone.
worker("claudeb", 31000, "opus", None, None, {"pid": os.getppid()})
worker("claudeb", 32000, "opus", None, None, {"pid": 0})
os.makedirs(os.path.join(runs, "browse"))
os.utime(os.path.join(runs, "browse"), (now - 40 * 86400, now - 40 * 86400))
os.makedirs(runs, exist_ok=True)
with open(os.path.join(runs, "prelaunch.jsonl"), "w") as handle:
    for offset, outcome in ((2000, "CODEX_USAGE_LIMIT"), (2100, "MODEL_REFUSED"), (2200, "LIGHT_OFF")):
        handle.write(json.dumps({"ts": now - offset, "outcome": outcome, "vendor": "codex", "account": "",
                                 "model": "astra", "role": "workers", "light": ""}) + "\n")

os.makedirs(os.path.dirname(image_log))
with open(image_log, "w") as handle:
    for offset, rc, err in ((1000, 0, ""), (1100, 3, "GROK_USAGE_LIMIT"),
                            (1200, 1, "grok-image: no ImageGen event in the stream"), (1300, 4, "busy"),
                            (1400, 4, "grok-video: account refused by the worker pool"),
                            (1450, 4, "codex-image: alpha is out of the worker pool, so no headless run may use it"),
                            (1500, 1, "grok-image: no ImageGen event in the stream\nHTTP 503 Service Unavailable")):
        handle.write(json.dumps({"ts": now - offset, "tool": "grok-image", "kind": "image", "rc": rc,
                                 "seconds": 20, "account": "main", "served": "", "err": err}) + "\n")

commits = json.load(open(os.path.join(os.path.dirname(ledger), "commits.json")))
def fix(offset, files, commit=None, regressed=None):
    return {"at": iso_local(offset), "by": "Review owner", "files": files, "in": commit,
            "regressed_at": iso_local(regressed) if regressed else None}
def entry(id, block, match, title, status, fixes=(), **extra):
    row = {"id": id, "block": block, "match": match, "title": title, "status": status, "fixes": list(fixes),
           "same_cause": [], "last_reviewed": "2026-09-24", "reviewed_by": "Review owner", "note": "", "handoff": None}
    row.update(extra)
    return row
runtime = ["review-bench/share/rbench/cell_runtime.py"]
json.dump({"owner": "Doctor owner", "owners": {"reviewers": "Review owner", "workers": "Worker owner",
                                               "light": "Worker owner", "image": "Image owner"}, "rows": [
    # Fixed twice: a crash between the two fixes is judged by the last one.
    entry("X1", "reviewers", {"word": "crashed", "detail": "cell processing crashed"}, "processing crash", "fixed",
          [fix(20000, runtime, commits["runtime"], regressed=18000), fix(7200, runtime, commits["runtime"])],
          last_reviewed=time.strftime("%Y-%m-%d", time.gmtime(now - 86400))),
    entry("X2", "workers", {"word": "bad command", "model": "^grok", "detail": "unknown effort level"},
          "effort grok does not serve", "open"),
    entry("X3", "any", {"word": "killed memory", "detail": "memory guard"}, "memory guard", "not-a-bug"),
    entry("X4", "image", {"word": "bad output", "model": "^grok-image"}, "no event", "open"),
    # A dismissal that matches every leg is a ledger fault, never a verdict.
    entry("X5", "workers", {"word": "crashed", "detail": ".*"}, "every crash", "not-a-bug"),
    entry("X6", "workers", {"word": "unclassified", "detail": "boom", "until": iso_local(90000)},
          "old unclassified storm", "not-a-bug"),
    entry("X7", "reviewers", {"word": "auth", "detail": "HTTP 403"}, "committed since", "fixed-pending",
          [fix(5000, ["review-bench/share/rbench/panel.py"])]),
    entry("X8", "reviewers", {"word": "auth", "detail": "HTTP 401"}, "still uncommitted", "fixed-pending",
          [fix(5000, ["review-bench/share/rbench/report.py"])]),
    entry("H1", "any", {"health": "debt", "key": "^debt-gap:fixer-missing"}, "fixer gaps", "open"),
    entry("H2", "any", {"health": "debt", "key": "^debt-gap:run-fold:snapshots unreadable$"}, "fold gaps", "open"),
    entry("M1", "reviewers", {"machinery": "anchors"}, "anchor warnings", "open"),
    entry("M2", "reviewers", {"machinery": "integrity"}, "tree moved", "fixed", [fix(7200, runtime, commits["runtime"])]),
    entry("M3", "reviewers", {"machinery": "debt_scope"}, "debt scope", "fixed",
          [fix(7200, runtime, "review-bench@deadbee")]),
], "blind_spots": [
    {"id": "B1", "what": "worker false-green reports", "reason": "no reader", "since": "2026-09-29",
     "would_catch_if": "a worker's report were checked against its diff"},
    {"id": "B2", "what": "weakened tests", "reason": "no reader", "since": "2026-09-29",
     "would_catch_if": "test diffs were read against HEAD"}]}, open(ledger, "w"))
json.dump({"as_of": now - 60, "total": 9,
           "anomalies": {"anchors": 2, "closure_pending": 3, "debt_line": 0, "integrity": 1, "debt_scope": 3},
           "rows": {"integrity": [{"id": "r", "age_s": 600}], "debt_scope": [{"id": "d", "age_s": 9000}]}},
          open(os.path.join(os.path.dirname(benches), "doctor-snapshot.json"), "w"))

frozen_day = time.strftime("%Y-%m-%d", time.localtime(now - 10 * 86400))
os.makedirs(os.path.join(doctor, "daily"))
json.dump({"day": frozen_day, "covered": ["image"], "legs": {"image|grok-image": 9},
           "counts": {"image|grok-image|failed|bad output|ours|X4": 5, "image|grok-image|walled|||": 2}},
          open(os.path.join(doctor, "daily", frozen_day + ".json"), "w"))

cache = os.path.join(os.environ["HOME"], ".cache", "claude")
os.makedirs(os.path.join(cache, "review-debt", "gaps"))
with open(os.path.join(cache, "review-debt", "gaps", "s1"), "w") as handle:
    handle.write("%d\ttouch-failed\t/repo: review-anchors exited 1\n%d\ttouch-failed\t/repo: review-anchors exited 1\n"
                 "%d\tpre-missing\tsettled by a review\n" % (now - 1800, now - 900, now - 500))
PY

before=$(find "$LLM_DOCTOR_DIR" -type f | sort | tr '\n' ' ')
assert "$DOCTOR" --dry-run --json >"$WORK/doc.json"
assert test "$(find "$LLM_DOCTOR_DIR" -type f | sort | tr '\n' ' ')" = "$before"
# --json only prints: the menu's cache keeps its own window.
assert "$DOCTOR" --block reviewers --json >"$WORK/doc-block.json"
RUNS="$WORK/doctors-runs"
DOCTORS_DIR="$RUNS" DOCTOR_TRIGGER=menu "$DOCTOR" --dry-run --json </dev/null >/dev/null
assert jq -es 'length == 1 and (.[0] | (keys == ["cpu_s", "doctor", "start", "trigger", "wall_s"])
  and .doctor == "llm" and .trigger == "menu" and .wall_s > 0 and .cpu_s > 0)' "$RUNS/collector-runs.jsonl" >/dev/null
assert test "$(find "$LLM_DOCTOR_DIR" -type f | sort | tr '\n' ' ')" = "$before"
# An unwritable rollup directory costs the frozen days, never the collection.
chmod 500 "$LLM_DOCTOR_DIR/daily"
rc=0
"$DOCTOR" --quiet 2>"$WORK/daily-error" || rc=$?
chmod 700 "$LLM_DOCTOR_DIR/daily"
assert test "$rc" = 0
assert grep -q '^llm-doctor: daily rollup not written: ' "$WORK/daily-error"
assert test "$(find "$LLM_DOCTOR_DIR/daily" -type f | sort | tr '\n' ' ')" = "$(printf '%s\n' $before | grep '/daily/' | tr '\n' ' ')"
assert test -s "$LLM_DOCTOR_DIR/latest.json"
rm "$LLM_DOCTOR_DIR/latest.json"
# A written run records the sweep's commit of a pending fix; an uncommitted one stays pending.
assert python3 - "$LLM_DOCTOR_LEDGER" "$WORK/commits.json" <<'PY'
import json, sys
rows = {row["id"]: row for row in json.load(open(sys.argv[1]))["rows"]}
assert rows["X7"]["status"] == "fixed" and rows["X7"]["fixes"][-1]["in"] == json.load(open(sys.argv[2]))["panel"], rows["X7"]
assert rows["X8"]["status"] == "fixed-pending" and rows["X8"]["fixes"][-1]["in"] is None, rows["X8"]
assert rows["M3"]["fixes"][-1]["in"] == "review-bench@deadbee", rows["M3"]
PY

assert python3 - "$WORK/doc.json" "$NOW" <<'PY'
import datetime, json, re, sys
doc = json.load(open(sys.argv[1]))
blocks = {block["block"]: block for block in doc["blocks"]}
assert [block["block"] for block in doc["blocks"]] == ["reviewers", "workers", "light", "image"]
assert doc["not_measurable"] == ["worker false-green reports", "weakened tests"]
health = {row["name"]: row for row in doc["health"]}
assert [row["name"] for row in doc["health"]] == ["debt"]
debt = {(item["label"], item["chat"]): (item["count"], item["repeats"]) for item in health["debt"]["items"]}
assert debt == {("not recorded: touch-failed in repo", "unnamed chat"): (1, 2),
                ("not recorded: hash-cap in repo", "unnamed chat"): (1, 1091),
                ("not recorded: fixer-missing", "unnamed chat"): (2, 2),
                ("not recorded: run-fold: snapshots unreadable", "unnamed chat"): (1, 1),
                ("not recorded: run-fold: review-anchors exited 1", "unnamed chat"): (1, 1)}, debt
assert health["debt"]["count"] == 6 and health["debt"]["notes"] == [], health["debt"]

def problems(block):
    return {(item["label"], (item["ledger"] or {}).get("id", "")): item for item in blocks[block]["problems"]}

review = problems("reviewers")
labels = sorted(review)
# The crash after the fix regressed its ledger row; the crash before it counts as fixed, not as a bug.
crash = review[("failed · crashed", "X1")]
assert crash["kind"] == "bug" and crash["status"] == "regressed", crash
assert crash["status_text"] == "regressed ×1 · 2 before fix", crash["status_text"]
assert crash["looked"] == "looked at 1d ago", crash["looked"]
assert review[("failed · pool empty", "")]["status"] == "new", labels
assert review[("walled", "")]["kind"] == "weather", labels
assert review[("failed · unclassified", "")]["kind"] == "bug", labels
assert review[("cap", "")]["kind"] == "weather", labels
assert review[("failed · refused · theirs", "")]["kind"] == "weather", labels
assert review[("failed · server error · theirs", "")]["incidents"][0]["attempt"] == "chunk", labels
assert review[("failed · killed memory · not a bug", "X3")]["kind"] == "weather", labels
assert review[("failed · bad output", "")]["incidents"][0]["surface"] == "judge", labels
escaped = review[("escaped", "")]
assert escaped["count"] == 1 and escaped["models"] == ["glm"], escaped
retried = review[("retried", "")]
assert retried["count"] == 1 and retried["models"] == ["grok47"], retried
slow = review[("slow", "")]
slow_models = {}
for incident in slow["incidents"]:
    slow_models[incident["model"]] = slow_models.get(incident["model"], 0) + 1
assert slow["count"] == 8 and slow_models == {"opus": 1, "sonnet": 1, "haiku2": 5, "sz": 1}, (slow["count"], slow_models)
speed = blocks["reviewers"]["speed"]
assert speed["judged"] >= 15 and speed["unjudged"] >= 5, speed
assert blocks["reviewers"]["owner"] == "Review owner" and blocks["workers"]["owner"] == "Worker owner"
for problem in blocks["reviewers"]["problems"]:
    assert len(problem["daily"]) == 14, problem

workers = problems("workers")
assert workers[("failed · bad command", "X2")]["status"] == "open", sorted(workers)
assert workers[("walled", "")]["count"] == 2, workers[("walled", "")]
assert workers[("retried", "")]["count"] == 1, sorted(workers)
# The guard refusing an unsupported model before launch did its job: weather, never V5.
assert workers[("off", "")]["incidents"][0]["detail"] == "model refused", sorted(workers)
assert ("failed · bad command", "") not in workers, sorted(workers)
light = problems("light")
assert light[("failed · crashed", "")]["incidents"][0]["detail"] == "tree digest not taken", sorted(light)
assert light[("escaped", "")]["incidents"][0]["detail"] == "light scope escaped", sorted(light)
# Every incident names the chat that launched its run, where the run recorded one — by name, and a
# launcher nothing here knows as an unnamed chat, never by its id.
crashed = light[("failed · crashed", "")]["incidents"][0]
assert crashed["session"].startswith("feedface") and crashed["chat"] == "unnamed chat", crashed
launched = [incident for block in blocks.values() for problem in block["problems"]
            for incident in problem["incidents"] if incident["ref"].endswith("-bbbbbbb")]
assert launched and all(incident["session"].startswith("cafebabe") and incident["chat"] == "unnamed chat"
                           for incident in launched), launched
chats = [incident.get("chat") or "" for block in blocks.values() for problem in block["problems"]
         for incident in problem["incidents"]] + [item["chat"] for row in doc["health"] for item in row["items"]]
assert not [chat for chat in chats if re.search(r"\b[0-9a-f]{8}\b", chat)], chats
assert all(problem["incidents_total"] >= len(problem["incidents"])
           for block in blocks.values() for problem in block["problems"])
assert blocks["light"]["bugs"] == 2 and blocks["light"]["new"] == 2, blocks["light"]
assert workers[("failed · crashed", "")]["incidents"][0]["detail"] == "no exit: supervisor gone", sorted(workers)
assert workers[("failed · crashed", "")]["count"] == 2, workers[("failed · crashed", "")]
image = problems("image")
assert image[("walled", "")]["count"] == 1 and image[("failed · bad output", "X4")]["count"] == 1, sorted(image)
assert image[("failed · pool empty", "")]["count"] == 2, sorted(image)
assert image[("failed · server error · theirs", "")]["kind"] == "weather", sorted(image)
assert blocks["image"]["legs"] == 6, blocks["image"]["legs"]
# Weather keeps the empty id live, so a weather row must not relabel its frozen history away from it.
assert image[("walled", "")]["daily"][3] == 2, image[("walled", "")]["daily"]
# The frozen day predates X4 and carries no ledger id; X4 needs no detail text, so it claims the history.
assert image[("failed · bad output", "X4")]["daily"][3] == 5, image[("failed · bad output", "X4")]["daily"]
assert image[("failed · bad output", "X4")]["trend"] == "down", image[("failed · bad output", "X4")]
assert blocks["image"]["coverage_from"] is not None
assert blocks["workers"]["coverage_from"] >= int(sys.argv[2]) - 7 * 86400, blocks["workers"]["coverage_from"]
server = review[("failed · server error · theirs", "")]
assert server["count"] == 2 and all(item["attempt"] == "chunk" for item in server["incidents"]), server
assert any(item["detail"] == "chunk 1: signal 9" for item in review[("cap", "")]["incidents"]), review[("cap", "")]
assert workers[("escaped", "")]["count"] == 2, workers[("escaped", "")]
assert workers[("failed · unclassified", "")]["count"] == 1, sorted(workers)
assert doc["bugs"] == sum(block["bugs"] for block in doc["blocks"])
machinery = blocks["reviewers"]["machinery"]
assert [(item["class"], item["status"]) for item in machinery["classes"]] == [
    ("anchors", "open"), ("closure_pending", "new"), ("debt_scope", "new"), ("integrity", "regressed")], machinery
# M3 names no commit, so it is a ledger fault and judges nothing: its class reads new.
assert machinery["issues"] == 9 and machinery["classes"][0]["ledger"]["id"] == "M1", machinery
assert machinery["classes"][2]["ledger"] is None, machinery
for block in doc["blocks"]:
    for problem in block["problems"]:
        for incident in problem["incidents"]:
            assert set(incident) == {"age_s", "age", "at", "model", "surface", "project", "tier", "attempt", "detail",
                                     "ref", "event", "account", "session", "chat"}

# The doctors' contract envelope.
now = int(sys.argv[2])
assert {"contract", "doctor", "as_of", "judge", "status", "problem_count", "problems", "blind_spots", "self"} <= set(doc)
assert (doc["contract"], doc["doctor"], doc["as_of_s"]) == (1, "llm", now), doc["as_of_s"]
assert datetime.datetime.fromisoformat(doc["as_of"]).timestamp() == now and doc["as_of"][-6] in "+-", doc["as_of"]
assert re.fullmatch(r"[0-9a-f]{64}", doc["judge"]) and doc["self"]["error"] is None, doc["self"]
assert doc["status"] == "problems" and doc["blind"] == [], (doc["status"], doc["blind"])
assert [spot["id"] for spot in doc["blind_spots"]] == ["B1", "B2"] and doc["owner"] == "Doctor owner"
assert doc["limits"]["PROOF_MIN"] == 10 and all(item["limit_name"] in doc["limits"] for item in doc["near"]), doc["near"]
keys = {"id", "rule", "state", "fact", "value", "limit", "unit", "window_h", "exposure", "count", "first_seen",
        "last_seen", "evidence", "ledger"}
found = {}
for item in doc["problems"]:
    assert keys <= set(item) and item["id"] and item["id"] not in found, item
    found[item["id"]] = item
    refs = [event["ref"] for event in item["evidence"]]
    assert len(refs) == len(set(refs)) and all(set(event) == {"at", "ref", "account", "excerpt"}
                                               and len(event["excerpt"]) <= 300 for event in item["evidence"]), item
assert doc["problem_count"] == sum(1 for item in doc["problems"] if item["state"] in ("new", "open", "regressed")) > 0
tally = {}
for item in doc["problems"]:
    assert item["group"] in doc["groups"], item
    if item["state"] in ("new", "open", "regressed"):
        tally[item["group"]] = tally.get(item["group"], 0) + 1
assert {group: count for group, count in doc["groups"].items() if count} == tally, (doc["groups"], tally)
assert sum(doc["groups"].values()) == doc["problem_count"], doc["groups"]
assert {"reviewers", "workers", "machinery", "debt"} <= set(tally), tally
states = {pid: (item["state"], item["rule"], item["ledger"]) for pid, item in found.items()}
assert states["X1"] == ("regressed", "leg-failure", "X1"), states
assert states["leg-failure:reviewers/pool empty"] == ("new", "leg-failure", None), states
assert states["leg-failure:workers/crashed"] == ("new", "leg-failure", None), states
assert states["X2"] == ("open", "leg-failure", "X2") and states["X4"] == ("open", "leg-failure", "X4"), states
assert states["X8"] == ("fixed-pending", "fix-proof", "X8") and states.get("X7", ("",))[0] != "fixed-pending", states
assert states["H1"] == ("open", "debt-gap", "H1") and "debt-gap:fixer-missing" not in states, states
assert states["debt-gap:touch-failed/repo"] == ("new", "debt-gap", None), states
assert states["H2"] == ("open", "debt-gap", "H2") and "debt-gap:run-fold:snapshots unreadable" not in states, states
assert states["debt-gap:run-fold:review-anchors exited 1"] == ("new", "debt-gap", None), states
assert states["M1"][0] == "open" and states["M2"][0] == "regressed" and "M3" not in states, states
assert states["machinery:closure_pending"] == ("new", "machinery", None), states
assert states["machinery:debt_scope"] == ("new", "machinery", None), states
assert "matches every leg" in found["ledger:X5"]["fact"] and "deadbee is no commit" in found["ledger:M3"]["fact"], states
assert sorted(pid for pid in found if pid.startswith("ledger:")) == ["ledger:M3", "ledger:X5"], states
# First seen is the earliest start of any loaded leg of the cause, not of the window's.
assert datetime.datetime.fromisoformat(found["X1"]["first_seen"]).timestamp() == now - 18100, found["X1"]
assert crash["ledger"]["fixes"][0]["regressed_at"] and len(crash["ledger"]["fixes"]) == 2, crash["ledger"]
assert found["X1"]["count"] == 1 and found["X1"]["evidence"][0]["ref"].endswith("#4"), found["X1"]
# One event per ref, in each store's own shape: never a tool name or a run shared by its cells.
assert all(event["ref"].startswith("image:") and event["ref"].count("/") == 2 and event["account"] == "main"
           for event in found["X4"]["evidence"]), found["X4"]["evidence"]
image_events = [incident["event"] for problem in blocks["image"]["problems"] for incident in problem["incidents"]]
assert len(image_events) == len(set(image_events)) == 5 and \
    all(re.fullmatch(r"image:\d+/grok-image/main", event) for event in image_events), image_events
refused = [incident["event"] for problem in blocks["workers"]["problems"] for incident in problem["incidents"]
           if incident["event"].startswith("prelaunch:")]
assert len(set(refused)) == 2 and all(re.fullmatch(r"prelaunch:\d+/-", event) for event in refused), refused
PY

assert "$DOCTOR" --quiet
assert test -s "$LLM_DOCTOR_DIR/latest.json"
assert jq -e '[.contract, .doctor, .as_of, .as_of_s, .judge, .status, .problem_count, .problems, .blind_spots, .self]
  | all(. != null)' "$LLM_DOCTOR_DIR/latest.json" >/dev/null
# A required store that is missing leaves its rules unable to see: blind, and named.
assert env WORKER_RUN_DIR="$WORK/no-runs" "$DOCTOR" --dry-run --json >"$WORK/blind.json"
assert jq -e '.status == "blind" and .blind == ["worker runs"]' "$WORK/blind.json" >/dev/null
# A per-account store holding a name the roster no longer lists is one problem in its own group,
# whatever how many stores hold it; a roster account's data is no remnant (row di).
mkdir -p "$HOME/.codex-profiles/alive" "$HOME/.codex-profiles/.codexb/fast-mode" "$HOME/.cache/worker-claims/codex"
touch "$HOME/.codex-profiles/.codexb/fast-mode/ghost" "$HOME/.cache/worker-claims/codex/ghost" \
  "$HOME/.cache/worker-claims/codex/alive"
assert env LLM_LIMITS_CODEX_REMOVED="$WORK/codex-main.removed" "$DOCTOR" --dry-run --json >"$WORK/remnants.json"
assert jq -e '[.problems[] | select(.group == "accounts")] as $rows | .groups.accounts == 1 and ($rows | length) == 1
  and $rows[0].id == "remnant:codex:ghost" and $rows[0].value == 2
  and ($rows[0].fact | contains("purge: python3 share/account_stores.py purge codex ghost"))' "$WORK/remnants.json" >/dev/null
rm -rf "$HOME/.codex-profiles" "$HOME/.cache/worker-claims"
# Days the bench store covers whole are frozen to disk; the older image day stays as it was.
assert test "$(find "$LLM_DOCTOR_DIR/daily" -name '*.json' | wc -l | tr -d ' ')" -ge 3
assert grep -q '"image|grok-image|failed|bad output|ours|X4": 5' "$LLM_DOCTOR_DIR/daily/$(python3 -c 'import time,sys; print(time.strftime("%Y-%m-%d", time.localtime(int(sys.argv[1]) - 10 * 86400)))' "$NOW").json"
assert python3 -c 'import json,sys; json.load(open(sys.argv[1]))["blocks"]' "$LLM_DOCTOR_DIR/latest.json"
assert grep -q '"image|grok-image|walled|||": 2' "$LLM_DOCTOR_DIR/daily/$(python3 -c 'import time,sys; print(time.strftime("%Y-%m-%d", time.localtime(int(sys.argv[1]) - 10 * 86400)))' "$NOW").json"
assert env TZ=Europe/Kyiv python3 - "$DOCTOR" <<'PY'
import calendar, importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("llm_doctor", sys.argv[1])
spec = importlib.util.spec_from_loader("llm_doctor", loader)
doctor = importlib.util.module_from_spec(spec)
loader.exec_module(doctor)
days = doctor.trend_days(calendar.timegm((2026, 10, 25, 21, 30, 0)))
assert len(set(days)) == 14 and days[-1] == "2026-10-25" and days[0] == "2026-10-12", days
PY

"$DOCTOR" --dry-run --block reviewers >"$WORK/view.txt" || fail "the text view failed"
assert grep -q '^Reviewers: ' "$WORK/view.txt"
assert grep -q 'X1' "$WORK/view.txt"
assert test "$(grep -c '^Workers: ' "$WORK/view.txt")" -eq 0
assert test "$(grep -Ec '[0-9]{8}T[0-9]{6}Z|codex-[0-9]{9}' "$WORK/view.txt")" -eq 0

assert grep -qx 'gaps --days 7 --json' "$ANCHORS_ARGS"
printf '{"at":%d,"kind":"run-fold-skip","repo":"/r","path":"x.py","session":"s1","lines":5,"detail":"run w-1: a co-tenant touched it during the run"}\n{"at":%d,"kind":"run-fold-skip","repo":"/r","path":"y.py","session":"s1","lines":7,"detail":"run w-1: a co-tenant touched it during the run"}\n{"at":%d,"kind":"run-fold-skip","repo":"/r","path":"x.py","session":"s1","lines":2,"detail":"run w-2: a co-tenant touched it during the run"}\n{"at":%d,"kind":"untouch","repo":"/r","path":"a.py","session":"s1","lines":12}\n{"at":%d,"kind":"migrate","repo":"/w/r1","path":"b.py","session":"","lines":3}\n{"at":%d,"kind":"migrate","repo":"/w/r2/","path":"c.py","session":"","lines":4}\n' \
  "$((NOW - 700))" "$((NOW - 690))" "$((NOW - 680))" "$((NOW - 600))" "$((NOW - 500))" "$((NOW - 400))" \
  >"$HOME/.cache/claude/review-debt/losses.jsonl"
assert "$DOCTOR" --dry-run --json >"$WORK/doc2.json"
assert python3 - "$WORK/doc2.json" <<'PY'
import json, sys
debt = [row for row in json.load(open(sys.argv[1]))["health"] if row["name"] == "debt"][0]
items = {(item["label"], item["chat"]): (item["count"], item["lines"]) for item in debt["items"]}
assert items == {("not recorded: touch-failed in repo", "unnamed chat"): (1, 0),
                 ("not recorded: hash-cap in repo", "unnamed chat"): (1, 0),
                 ("not recorded: fixer-missing", "unnamed chat"): (2, 0),
                 ("not recorded: run-fold: snapshots unreadable", "unnamed chat"): (1, 0),
                 ("not recorded: run-fold: review-anchors exited 1", "unnamed chat"): (1, 0),
                 ("lost unreviewed: run-fold-skip", "unnamed chat"): (2, 14),
                 ("lost unreviewed: untouch", "unnamed chat"): (1, 12), ("lost unreviewed: migrate", "r1"): (1, 3),
                 ("lost unreviewed: migrate", "r2"): (1, 4)} and debt["notes"] == [], debt
PY
"$DOCTOR" --dry-run >"$WORK/view2.txt" || fail "the text view with health failed"
assert grep -q 'not recorded: hash-cap in repo · seen 1091×' "$WORK/view2.txt"
ANCHORS_EXIT=1 "$DOCTOR" --dry-run --json >"$WORK/doc3.json" || fail "a failing gaps reader broke the doctor"
assert python3 - "$WORK/doc3.json" <<'PY'
import json, sys
debt = [row for row in json.load(open(sys.argv[1]))["health"] if row["name"] == "debt"][0]
assert debt["notes"] == ["gaps not read: review-anchors exited 1"], debt
assert {item["label"] for item in debt["items"]} == {"lost unreviewed: run-fold-skip", "lost unreviewed: untouch",
                                                    "lost unreviewed: migrate"}, debt
PY

# Bug or weather, one rule per record shape: the module's own readers on fixtures of each shape.
UNIT="$WORK/unit"
mkdir -p "$UNIT"
assert env LLM_LIMITS_ACTION_LOG="$UNIT/actions.log" WORKER_RUN_DIR="$UNIT/runs" IMAGE_LEG_LOG="$UNIT/legs.jsonl" \
  WORKER_STATS_DIR="$UNIT/stats" python3 - "$DOCTOR" "$NOW" "$UNIT" <<'PY'
import contextlib, importlib.machinery, importlib.util, io, json, os, shutil, sys, time
loader = importlib.machinery.SourceFileLoader("llm_doctor", sys.argv[1])
spec = importlib.util.spec_from_loader("llm_doctor", loader)
doctor = importlib.util.module_from_spec(spec)
loader.exec_module(doctor)
now, unit = int(sys.argv[2]), sys.argv[3]

def local(offset):
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now - offset))

def iso(offset):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - offset))

with open(os.path.join(unit, "actions.log"), "w") as handle:
    for offset, line in ((3700, "grok_reviewers=off"), (90000, "gemini_reviewers=off"), (90000, "codex_workers=off"),
                         (80000, "codex_workers=on"), (5000, "claudeb_workers=off")):
        handle.write("%s  done               worker-model %s exit=0\n" % (local(offset), line))
    handle.write("%s  done               grokb disable spare exit=0\n" % local(5000))

def text_reading(text, exit_code=1):
    return doctor.classify_failure_text(text, exit_code)[:4]

# Login states are the owner's to renew; a refused credential export is still ours (R12).
for text in ("Error: not logged in; run grokb add", "Eligibility check failed: Verify your account to continue",
             "open https://accounts.google.com/signin/continue to sign in", "you are not eligible for Antigravity"):
    assert text_reading(text) == ("walled", "login", "needs login", ""), (text, text_reading(text))
assert text_reading("cell preparation refused: credential export: not logged in")[1:] == ("auth", "auth", "ours")
# A status is a status: a cited line number or prose saying forbidden is not an auth failure.
assert doctor.failure_reason("finding at panel.py:401 and 403 lines") == "unclassified"
assert doctor.failure_reason("HTTP 403 Forbidden") == "auth"
assert doctor.failure_reason("rater task crashed: File /Volumes/Work/runner.py:429: ValueError") == "crashed"
assert doctor.failure_reason("HTTP 429") == "bare 429"
assert doctor.failure_reason("Your AI credits balance is too low to continue.") == "walled"
assert doctor.failure_reason('{"is_error":true,"api_error_status":429}') == "bare 429"
# The provider's own clock is theirs.
for text in ("upstream request timeout", "rpc error: DEADLINE_EXCEEDED", "504 Gateway Timeout", "gateway time-out"):
    assert text_reading(text) == ("failed", "timeout", "provider timeout", "theirs"), (text, text_reading(text))
assert text_reading("rater timed out waiting")[3] == "ours"
# A configured turn budget is a cap; another bad-output phrase beside it is still bad output.
assert text_reading("grok stopped at the 10-turn budget")[:2] == ("cap", "turns")
assert text_reading("stopped at the 10-turn budget; malformed JSON")[1] == "bad output"
# The pool quotes the last account's error: a crash there is ours, a wall there is weather.
assert text_reading("grok has no reviewer account left: account lookup failed: ValueError")[1:] \
    == ("crashed", "pool empty: crashed", "ours")
assert text_reading("grok has no reviewer account left: usage limit")[0] == "walled"
# A model swap is read before any vocabulary word, as panel.cell_status reads it.
assert text_reading("served grok-4 instead of grok-5; malformed JSON")[1:] == ("mismatch", "mismatch", "theirs")

# Escapes: a copy's source is read, not written; home-relative targets count; another account's
# profile is not the cell's own state.
home = os.environ["HOME"]
watched = ["/Volumes/Work/repo", home + "/.codex", "/Users/u/.grok-profiles", "/home/me/repo", home + "/other-repo"]
def evidence(value, account="main", roots=watched):
    return doctor.escape_evidence({"write_evidence": [["r", account, value]], "integrity": {"status": "changed",
        "roots": [{"root": root, "status": "changed", "changed": ["x"]} for root in roots]}})
# write_evidence is lexical: with no root seen changing, a denied or quoted write is no escape.
assert evidence("cp /tmp/x /Volumes/Work/repo/file", roots=[]) == {}
assert doctor.escape_evidence({"write_evidence": [["r", "main", "cp /tmp/x /Volumes/Work/repo/file"]],
                               "rater_runs": [{"integrity_checks": [{"roots": [{"root": "/Volumes/Work/repo",
                                                                               "changed": ["file"]}]}]}]}) \
    == {"r": {"main"}}
# Every path shape the extractor emits: home-relative and any absolute root.
assert evidence("rm ~/other-repo/file") == {"r": {"main"}}
assert evidence("rm /home/me/repo/file") == {"r": {"main"}}
assert evidence("cp /Volumes/Work/repo/file /tmp/copy") == {}
assert evidence("cp /tmp/x /Volumes/Work/repo/file") == {"r": {"main"}}
assert evidence("rm ~/.codex/config.toml") == {"r": {"main"}}
assert evidence("rm ~/.cache/x/file") == {}
assert evidence("touch /Users/u/.grok-profiles/other/config.json", "spare") == {"r": {"spare"}}
assert evidence("touch /Users/u/.grok-profiles/spare/config.json", "spare") == {}

def run_legs(rows, **meta):
    document = {"repo": "/Volumes/Work/Projects/llm-legs", "rater_runs": rows}
    document.update(meta)
    return doctor.run_legs(document, "20260101T000000Z-abc", now - 4600, now - 86400, now)

def cell(rater, finished=3600, exit_code=1, stderr="", **extra):
    row = {"rater": rater, "account": "main", "model": rater, "exit_code": exit_code, "stderr": stderr,
           "duration_ms": 100000, "finished_at": iso(finished), "findings": 1}
    row.update(extra)
    return row

def readings(legs):
    return {(row["model"], row["attempt"]): (row["class"], row["reason"], row["detail"], row["origin"]) for row in legs}

legs = readings(run_legs([
    # Closed mid-run: the cell obeyed the owner's hand. Closed the day before: staffed on a closed vendor.
    cell("grok", stderr="grok has no reviewer account left: grok is switched off for reviewers"),
    cell("gemini", stderr="gemini has no reviewer account left: gemini is switched off for reviewers"),
    # A stall kill 300 s before the panel's last cell bought no wall time.
    cell("astra", finished=3900, exit_code=124, killed="stall", stalled_s=240),
    cell("haiku", exit_code=0, stderr="".join("chunk %d: exit 1: HTTP 503 Service Unavailable\n" % n for n in range(9, 13))),
    cell("flash", stderr="chunk 1: exit 1: usage limit\nchunk 2: exit 1: account lookup failed: ValueError"),
    cell("sonnet", exit_code=143),
    cell("opus", exit_code=0, findings=0, stderr="chunk 3: exit 1: no parseable finding"),
    cell("ghost", exit_code=None),
], finished=iso(3000)))
assert legs[("grok", "final")] == ("off", "off", "switched off mid-run", ""), legs
assert legs[("gemini", "final")][:2] == ("failed", "pool empty"), legs
assert legs[("astra", "final")][:2] == ("failed", "killed early") and "panel ran 300s more" in legs[("astra", "final")][2], legs
assert legs[("haiku", "chunk")] == ("failed", "server error", "chunks 9–12: server error", "theirs"), legs
assert legs[("flash", "final")][0] == "walled" and legs[("flash", "chunk")][:2] == ("failed", "crashed"), legs
assert legs[("sonnet", "final")] == ("cap", "cut", "signal exit 143", ""), legs
assert legs[("opus", "final")][0] is None and legs[("opus", "chunk")][1] == "bad output", legs
assert legs[("ghost", "final")] == ("failed", "no output", "no exit recorded", ""), legs
# The run's current `finished` field dates the judge, not the run id.
judge = [row for row in run_legs([], finished=iso(3000), judge={"state": "ran", "model": "opus"})
         if row["surface"] == "judge"]
assert judge and judge[0]["at"] == now - 3000, judge
# A cancelled panel keeps its finished rows' defects and drops only the unfinished ones.
cancelled = readings(run_legs([cell("sol", stderr="account lookup failed"), cell("glm", exit_code=None)], cancelled=True))
assert cancelled == {("sol", "final"): ("failed", "crashed", "crashed", "ours")}, cancelled
# An escape by a superseded attempt on another account survives the retry that succeeded.
repo_changed = {"status": "changed", "roots": [{"root": "/Volumes/Work/repo", "status": "changed", "changed": ["f"]}]}
escaped = run_legs([cell("kimi", finished=3700), cell("kimi", exit_code=0, account="spare")],
                   write_evidence=[["kimi", "main", "cp /tmp/x /Volumes/Work/repo/file"]], integrity=repo_changed)
assert [(row["attempt"], row["class"]) for row in escaped] == [("superseded", "escaped"), ("final", None)], escaped
# Once per cell: two attempts on the escaping account and a retry elsewhere surface one escape.
twice = run_legs([cell("kimi", finished=3800), cell("kimi", finished=3700), cell("kimi", exit_code=0, account="spare")],
                 write_evidence=[["kimi", "main", "cp /tmp/x /Volumes/Work/repo/file"]], integrity=repo_changed)
assert [row["class"] for row in twice].count("escaped") == 1, twice
# A model swap is read before any other word, as panel.cell_status reads it.
swap = readings(run_legs([cell("grok", stderr="served grok-4 instead of grok-5\nrater SIGKILLed by the memory guard")]))
assert swap[("grok", "final")] == ("failed", "mismatch", "mismatch", "theirs"), swap
assert doctor.verdict_of(escaped[0]) == "bug" and doctor.problem_key(escaped[0]) == ("escaped", "", "")

# One cause across many legs is one bug; incidents keep the legs.
legs = [doctor.leg("workers", "worker", "astra", now - offset, "failed", "crashed", "crashed", "ours")
        for offset in (100, 200, 300)]
legs.append(doctor.leg("workers", "worker", "astra", now - 400, "failed", "unclassified", "unclassified · exit 2", ""))
legs += [doctor.leg("workers", "worker", "grok", now - 500 - offset, "failed", "timeout", "timeout %ds" % offset, "ours")
         for offset in (60, 90)]
doctor.mark_problems(doctor.load_ledger(), legs)
days = doctor.trend_days(now)
block = doctor.build_block("workers", legs, doctor.load_ledger(), {day: {"counts": {}, "legs": {}, "covered": []}
                                                                   for day in days}, now - 86400, now, {})
assert (block["bugs"], block["new"]) == (3, 3), block
assert sorted(problem["incidents_total"] for problem in block["problems"]) == [1, 2, 3], block["problems"]
assert {row["model"]: row["bugs"] for row in block["models"]} == {"astra": 2, "grok": 1}, block["models"]
timed_legs = [dict(doctor.leg("workers", "worker", "astra", now - 100 - step, None, None, "", ""), duration=duration,
                  baseline=10) for step, duration in enumerate((30, 10))]
doctor.mark_problems(doctor.load_ledger(), timed_legs)
speed = doctor.build_block("workers", timed_legs, doctor.load_ledger(), {day: {"counts": {}, "legs": {}, "covered": []}
                                                                         for day in days}, now - 86400, now, {})["speed"]
assert (speed["ratio_p50"], speed["ratio_p95"]) == (1.0, 3.0), speed

# Workers.
def worker(name, meta=None, files=None):
    directory = os.path.join(unit, "w", name)
    os.makedirs(directory)
    for key, value in (files or {}).items():
        open(os.path.join(directory, key), "w").write(value)
    return directory
granted = worker("granted", files={"workdir-escape": "/Volumes/Work/other/x\n"})
assert doctor.classify_worker(granted, {"add_dirs": ["/Volumes/Work/other"]}, "", 0)[0] is None
assert doctor.classify_worker(granted, {}, "", 0)[0] == "escaped"
turns = worker("turns", files={"outcome": "GROK_MAX_TURNS\n", "err": "x"})
assert doctor.classify_worker(turns, {}, "", 1)[:2] == ("cap", "turns")
phase = worker("phase", files={"state.json": '{"phase": "failed"}', "err": "sandbox_apply failed: internal error\n"})
assert doctor.classify_worker(phase, {}, "", 0)[1:] == ("crashed", "crashed · failed under exit 0", "ours")
cancel = worker("cancel", files={"state.json": '{"phase": "failed"}', "out": '{"type":"end","stopReason":"cancelled"}\n'})
assert doctor.classify_worker(cancel, {}, "", 0)[1:] == ("cancelled", "cancelled before the first turn", "theirs")
# A retained old run id whose attempt ended inside the window still reaches the reader.
old = os.path.join(unit, "runs", "codex-%d-1-abcd" % (now - 23 * 86400))
os.makedirs(old)
open(os.path.join(old, "tag"), "w").write("main · astra · task\n")
open(os.path.join(old, "err"), "w").write("account lookup failed\n")
open(os.path.join(old, "exit_code"), "w").write("1\n")
os.utime(os.path.join(old, "exit_code"), (now - 600, now - 600))
worker_legs = doctor.worker_legs(now - 86400, now)[0]
# A run with no exit whose supervisor is gone, still short of NO_EXIT_S, is a near miss and no leg yet.
young = os.path.join(unit, "runs", "codex-%d-3-cafe" % (now - 4 * 3600))
os.makedirs(young)
open(os.path.join(young, "tag"), "w").write("main · astra · task\n")
doctor._NEAR.clear()
assert not [row for row in doctor.worker_legs(now - 86400, now)[0] if row["ref"] == os.path.basename(young)]
assert (doctor._NEAR["NO_EXIT_S"]["value"], doctor._NEAR["NO_EXIT_S"]["ref"]) == \
    (4 * 3600, "run:" + os.path.basename(young)), doctor._NEAR
shutil.rmtree(young)
# A run the Mac's reboot took down is weather, not a crashed supervisor.
rebooted = os.path.join(unit, "runs", "codex-%d-2-beef" % (now - 8 * 3600))
os.makedirs(rebooted)
open(os.path.join(rebooted, "tag"), "w").write("main · astra · task\n")
open(os.path.join(rebooted, "out"), "w").write("working\n")
os.utime(os.path.join(rebooted, "out"), (now - 7 * 3600, now - 7 * 3600))
os.environ["LLM_DOCTOR_REBOOTS"] = "%d" % (now - 7 * 3600 + 60)
doctor._REBOOTS.clear()
reboot_legs = [row for row in doctor.worker_legs(now - 86400, now)[0] if row["ref"] == os.path.basename(rebooted)]
assert [(row["class"], row["reason"], doctor.verdict_of(row)) for row in reboot_legs] == \
    [("rebooted", "reboot", "weather")], reboot_legs
# A run silent for hours before a later boot died on its own.
os.environ["LLM_DOCTOR_REBOOTS"] = "%d" % (now - 2 * 3600)
doctor._REBOOTS.clear()
reboot_legs = [row for row in doctor.worker_legs(now - 86400, now)[0] if row["ref"] == os.path.basename(rebooted)]
assert [(row["class"], row["reason"]) for row in reboot_legs] == [("failed", "crashed")], reboot_legs
# `last` orders day and month by the locale; both read as the same boot.
shim = os.path.join(unit, "last-shim")
os.makedirs(shim)
with open(os.path.join(shim, "last"), "w") as handle:
    handle.write("#!/bin/sh\nprintf 'reboot time   Mon 28 Sep 16:39\\nreboot time   Mon Sep 28 16:39\\n'\n")
os.chmod(os.path.join(shim, "last"), 0o755)
del os.environ["LLM_DOCTOR_REBOOTS"]
saved_path = os.environ["PATH"]
os.environ["PATH"] = shim + os.pathsep + saved_path
doctor._REBOOTS.clear()
sep28 = int(time.mktime(time.strptime("2026 28 Sep 16:39", "%Y %d %b %H:%M")))
boots = doctor.reboots(sep28 + 3600)
os.environ["PATH"] = saved_path
assert boots == [sep28, sep28], boots
os.environ["LLM_DOCTOR_REBOOTS"] = ""
doctor._REBOOTS.clear()
reboot_legs = [row for row in doctor.worker_legs(now - 86400, now)[0] if row["ref"] == os.path.basename(rebooted)]
assert [(row["class"], row["reason"]) for row in reboot_legs] == [("failed", "crashed")], reboot_legs
shutil.rmtree(rebooted)
assert [(row["ref"], row["reason"]) for row in worker_legs] == [(os.path.basename(old), "crashed")], worker_legs

# A refusal that met a closed switch or pool membership is the gate working.
with open(os.path.join(unit, "runs", "prelaunch.jsonl"), "w") as handle:
    for offset, vendor in ((1000, "claudeb"), (1100, "codex")):
        handle.write(json.dumps({"ts": now - offset, "outcome": vendor.upper() + "_UNAVAILABLE", "vendor": vendor,
                                 "account": "", "model": "m", "role": "workers", "light": ""}) + "\n")
prelaunch = {row["at"]: row["class"] for row in doctor.prelaunch_legs(now - 86400, now)[0]}
assert prelaunch == {now - 1000: "off", now - 1100: "failed"}, prelaunch
with open(os.path.join(unit, "legs.jsonl"), "w") as handle:
    for offset, rc, account, err in ((500, 4, "spare", "grok-image: account refused by the worker pool"),
                                     (600, 4, "main", "grok-image: account refused by the worker pool"),
                                     (700, 1, "main", "grok-video: no video generation on its tier")):
        handle.write(json.dumps({"ts": now - offset, "tool": "grok-image", "rc": rc, "account": account, "err": err}) + "\n")
image = {row["at"]: (row["class"], row["reason"]) for row in doctor.image_legs(now - 86400, now)[0]}
assert image == {now - 500: ("off", "off"), now - 600: ("failed", "pool empty"),
                 now - 700: ("walled", "not entitled")}, image

# Machinery: an open class still counts; a snapshot older than the window counts nothing.
ledger = doctor.load_ledger()
ledger["machinery"] = {"closure_pending": {"status": "open", "_fixed_at": None}}
os.makedirs(os.path.join(unit, "stats"))
snapshot = os.path.join(unit, "stats", "doctor-snapshot.json")
json.dump({"as_of": now - 60, "anomalies": {"closure_pending": 2}}, open(snapshot, "w"))
assert doctor.machinery(ledger, now, now - 86400)["issues"] == 2
json.dump({"as_of": now - 30 * 86400, "anomalies": {"unrecognized": 2}}, open(snapshot, "w"))
stale = doctor.machinery(ledger, now, now - 86400)
assert stale["issues"] == 0 and stale["stale"], stale

# A leg slow while the Harness doctor judged this Mac slow is local, never the model's weather.
harness = os.path.join(unit, "harness.json")
os.environ["HARNESS_DOCTOR_LATEST"] = harness
json.dump({"local_slow": [[now - 1000, now - 500]]}, open(harness, "w"))
def timed(offset, duration):
    return doctor.leg("workers", "worker", "opus", now - offset, None, None, "", "", duration=duration)
slow_legs = [timed(9000 - step * 100, 20) for step in range(6)] + [timed(600, 300), timed(100, 300)]
doctor.mark_slow(slow_legs)
assert [(row["class"], row["reason"]) for row in slow_legs[-2:]] == [("slow", "local slow"), ("slow", "slow")], \
    slow_legs[-2:]
os.remove(harness)

# The judge's short ruling has its own ledger row, never R1's review-cell shapes.
os.environ["LLM_DOCTOR_LEDGER"] = os.path.join(os.path.dirname(os.path.dirname(sys.argv[1])), "share", "doctor-ledger.json")
ledger = doctor.load_ledger()
short = doctor.leg("reviewers", "judge", "opus", now, "failed", "bad output", "bad output", "ours",
                   text="the judge ruled on 3 of 5 claims")
assert doctor.ledger_match(ledger, short)["id"] == "V14"
tool_event = doctor.leg("reviewers", "review", "astra", now, "failed", "bad output", "bad output", "ours",
                        text="malformed JSON after command_execution completed")
assert (doctor.ledger_match(ledger, tool_event) or {}).get("id") != "N5"
# A bug no row names reads new under its own id: no catch-all row stands in for a review.
unseen = doctor.leg("reviewers", "review", "astra", now, "failed", "pool empty", "pool empty", "ours")
assert doctor.judge_leg_state(ledger, unseen) == ("new", None)
assert doctor.leg_id(unseen, None) == "leg-failure:reviewers/pool empty"
committed = json.load(open(os.environ["LLM_DOCTOR_LEDGER"]))
assert doctor.ledger_faults(committed) == [], doctor.ledger_faults(committed)
# A judge edit is no fix of the row it unmasked: recorded as one, it would move H11's fix time past real recurrences.
assert ledger["by_id"]["H11"]["fixes"][-1]["files"] == ["llm-legs/bin/worker-run"], ledger["by_id"]["H11"]["fixes"]

# The judge is pinned: loosening a dismissal, a theirs word, an exemption or a limit is an edit here.
assert sorted((row["id"], row["match"].get("until")) for row in committed["rows"]
              if row["status"] in doctor.DISMISSALS) == [
    ("N4", "2026-09-16T23:59:59+03:00"), ("N5", None), ("N6", "2026-09-14T23:59:59+03:00"),
    ("N7", "2026-09-13T23:59:59+03:00")]
# Every image rc=2 reads `bad command` and every wrapper prints `usage:` on any bad argv: a row that catches that
# usage text ends at its triage. A row narrowed to another cause keeps no `until`, or its own regression reads new.
WRAPPERS = ("codex-image", "gemini-image", "gemini-listen", "gemini-music", "gemini-sfx", "gemini-video",
            "grok-image", "grok-video")
for row in ledger["rows"]:
    if row["block"] == "image" and row["match"].get("word") == "bad command" and any(
            (not row["_model"] or row["_model"].search(w))
            and (not row["_detail"] or row["_detail"].search("usage: %s --dest" % w))
            for w in WRAPPERS):
        assert row["_until"] is not None, row["id"]
eof = doctor.leg("image", "image", "codex-image", now, "failed", "bad command", "bad arguments", "ours",
                 text="/x/bin/codex-image: line 689: unexpected EOF while looking for matching `\"'")
assert doctor.ledger_match(ledger, eof)["id"] == "I20"
assert doctor.judge_leg_state(ledger, eof)[0] == "regressed"
assert sorted(word for word, origin in doctor.FAILURE_ORIGIN.items() if origin == "theirs") == [
    "bare 429", "cancelled", "capacity", "mismatch", "refused", "server error", "throttled", "walled"]
assert set(doctor.FAILURE_ORIGIN.values()) == {"ours", "theirs"} and doctor.IMAGE_ORIGIN == dict.fromkeys(
    ("bad output", "browser not sent", "browser price", "browser profile", "browser upload", "browser download",
     "browser no output", "browser hide", "browser drift", "browser owner step", "browser other"), "ours")
assert doctor.PRELAUNCH_SKIP == ("LIGHT_OFF", "RESUME_BUSY", "DUPLICATE_RUN")
assert doctor.PROFILE_HOME_RE.pattern == r"/\.(?:claude|gemini|codex|grok|opencode)-profiles/|/\.gemini/(?:antigravity/brain|tmp)/"
assert doctor.MAIN_STATE_RE.pattern == r"/\.gemini/(?:antigravity/brain|tmp)/"
assert [doctor.is_scratch_path(path) for path in ("/tmp/x", "/private/var/folders/x", "/a/scratchpad/x",
                                                  home + "/.cache/x", "/Volumes/Work/x", "/Users/u/.claude/x")] \
    == [True, True, True, True, False, False]
assert doctor.limits() == {
    "SLOW_FACTOR": 2, "SLOW_MIN_LEGS": 5, "SLOW_BASE_N": 20, "SLOW_FLOOR_S": 30, "SLOW_SIZE_RATIO": 2, "SLOW_BASE_D": 7,
    "NO_EXIT_S": 21600, "REBOOT_SLACK_S": 300, "REBOOT_QUIET_S": 3600,
    "TREND_MIN": 3, "PROOF_MIN": 10, "RECOVERED_MIN": 3, "NEAR_SHARE": 0.5, "KILLED_EARLY_SLACK_S": 60,
    "SWITCH_SLACK_S": 60, "DEBT_GAP_DAYS": 7}
digest = doctor.judge_digest(ledger)
ledger["by_id"]["V14"]["note"] = "a tracking edit"
assert doctor.judge_digest(ledger) == digest
ledger["by_id"]["N5"]["status"] = "weather"
assert doctor.judge_digest(ledger) != digest

# A dismissal that matches (nearly) every leg is a fault; a faulty row judges nothing.
def entry(match, status="not-a-bug", **extra):
    row = {"id": "Z", "block": "reviewers", "match": match, "title": "t", "status": status, "fixes": [],
           "same_cause": [], "last_reviewed": "2026-09-29", "reviewed_by": "c", "note": "", "handoff": None}
    row.update(extra)
    return row
def fix_at(offset, commit="review-bench@abc1234", regressed=None):
    return {"at": time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(now - offset)), "by": "c",
            "files": ["review-bench/x.py"], "in": commit, "regressed_at": regressed}
narrow = {"word": "crashed", "detail": "cell processing crashed"}
assert doctor.row_faults(entry(narrow), ["Z"]) == []
for match in ({"word": "crashed"}, {"word": "crashed", "detail": ".*"}, {"word": "crashed", "detail": "."},
              {"word": "crashed", "detail": "abc|"}, {"word": "crashed", "model": "^o"},
              {"word": "crashed", "until": "2026-09-01T00:00:00+03:00"}, {"word": "walled", "detail": "usage limit"},
              {"word": "crashed", "detail": "abcdef", "until": "yesterday"}, {"health": "debt", "key": ".*"},
              {"machinery": "anchors", "word": "crashed"}, {"health": "hooks", "key": "^hook-error:x"}):
    assert doctor.row_faults(entry(match), ["Z"]), match
# A machinery row matches a whole review-bench class: open or fixed, never dismissed.
assert [bool(doctor.row_faults(entry({"machinery": "integrity"}, status), ["Z"])) for status in
        ("not-a-bug", "weather", "open")] == [True, True, False]
for status, extra in (("fixed", {}), ("fixed", {"fixes": [fix_at(100, None)]}),
                      ("fixed-pending", {"fixes": [fix_at(100)]}), ("open", {"fixes": [fix_at(100, "abc1234")]}),
                      ("open", {"fixed_in": ["review-bench@abc1234"]}), ("open", {"same_cause": ["Q"]}),
                      ("closed", {})):
    assert doctor.row_faults(entry(narrow, status, **extra), ["Z"]), (status, extra)
path = os.path.join(unit, "ledger.json")
def fixture_ledger(rows):
    json.dump({"owner": "o", "owners": {block: "o" for block in doctor.BLOCKS}, "rows": rows, "blind_spots": []},
              open(path, "w"))
    os.environ["LLM_DOCTOR_LEDGER"] = path
    return doctor.load_ledger()
broad = fixture_ledger([entry({"word": "crashed", "detail": ".*"})])
crash = doctor.leg("reviewers", "review", "sol", now - 100, "failed", "crashed", "crashed", "ours", text="boom")
assert doctor.judge_leg_state(broad, crash) == ("new", None) and broad["faults"], broad["faults"]
# `until` ends a dismissal: a leg after it is judged again.
until = fixture_ledger([entry(dict(narrow, until=time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(now - 500))))])
before = doctor.leg("reviewers", "review", "sol", now - 600, "failed", "crashed", "crashed", "ours",
                    text="cell processing crashed")
after = dict(before, at=now - 400)
assert doctor.judge_leg_state(until, before)[0] == "weather" and doctor.judge_leg_state(until, after)[0] == "new"

# Re-fixed: both fixes stay, the last one judges, and a leg regresses a fix only if it started after it.
fixes = [fix_at(20000, regressed=time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(now - 18000))), fix_at(7200)]
refixed = fixture_ledger([entry(narrow, "fixed", fixes=fixes)])
assert doctor.ledger_view(refixed["by_id"]["Z"])["fixes"] == fixes
def crashed(start, end):
    return doctor.leg("reviewers", "review", "sol", now - end, "failed", "crashed", "crashed", "ours",
                      text="cell processing crashed", start=now - start)
assert [doctor.judge_leg_state(refixed, crashed(start, end))[0] for start, end in
        ((18100, 18000), (7400, 7000), (7100, 7000))] == ["fixed", "fixed", "regressed"]

# A fix committed on a branch dates from when it reached main (W3, afb7e91): a leg between the two
# ran on code without it and regresses nothing.
late_repos, saved_repos = os.path.join(unit, "late-repos"), os.environ["LLM_DOCTOR_REPOS"]
late = os.path.join(late_repos, "late")
os.makedirs(late)
def late_git(offset, *args):
    env = dict(os.environ, GIT_COMMITTER_DATE="@%d" % (now - offset), GIT_AUTHOR_DATE="@%d" % (now - offset))
    return doctor.subprocess.run(["git", "-C", late, "-c", "user.name=t", "-c", "user.email=t@t"] + list(args),
                                 check=True, capture_output=True, text=True, env=env).stdout.strip()
late_git(30000, "init", "-q", "-b", "main")
late_git(30000, "commit", "-q", "--allow-empty", "-m", "base")
late_git(9000, "checkout", "-q", "-b", "night/n/job")
late_git(9000, "commit", "-q", "--allow-empty", "-m", "fix")
branch_fix = late_git(9000, "rev-parse", "--short", "HEAD")
late_git(8000, "checkout", "-q", "main")
late_git(8000, "commit", "-q", "--allow-empty", "-m", "other")
late_git(3000, "merge", "-q", "--no-ff", "-m", "land", "night/n/job")
os.environ["LLM_DOCTOR_REPOS"] = late_repos
landed = fixture_ledger([entry(narrow, "fixed", fixes=[fix_at(7200, "late@" + branch_fix)])])
assert [doctor.judge_leg_state(landed, crashed(start, start - 50))[0] for start in (5000, 2000)] \
    == ["fixed", "regressed"]
other_fix = late_git(8000, "rev-parse", "--short", "HEAD^1")
late_git(2500, "checkout", "-q", "-b", "night/n/two")
late_git(2500, "commit", "-q", "--allow-empty", "-m", "fix one")
two_fix = late_git(2500, "rev-parse", "--short", "HEAD")
late_git(2400, "commit", "-q", "--allow-empty", "-m", "fix two")
late_git(2300, "checkout", "-q", "-b", "night/n/open")
late_git(2300, "commit", "-q", "--allow-empty", "-m", "never merged")
open_fix = late_git(2300, "rev-parse", "--short", "HEAD")
late_git(1000, "checkout", "-q", "main")
late_git(1000, "merge", "-q", "--no-ff", "-m", "land two", "night/n/two")
assert [doctor.fix_landed("late@" + ref, late_repos) for ref in (two_fix, open_fix, other_fix)] \
    == [now - 1000, None, now - 8000]
# Run in a worktree (a night close), the doctor still reads the main checkouts: a landed fix keeps its date.
saved_root = doctor.ROOT_DIR
del os.environ["LLM_DOCTOR_REPOS"]
for root in ("/p/llm-legs/.claude/worktrees/night-x", "/p/llm-legs"):
    doctor.ROOT_DIR = root
    assert doctor.repos_dir() == "/p", doctor.repos_dir()
doctor.ROOT_DIR = saved_root
os.environ["LLM_DOCTOR_REPOS"] = saved_repos

# A cause every retry hid still adds up: three lost attempts are a watch problem with their seconds.
recovered = fixture_ledger([])
lost = [doctor.leg("reviewers", "review", "kimi", now - 100 * step, "failed", "crashed", "crashed", "ours",
                   attempt="superseded", duration=60, event="bench:r/kimi#%d" % step) for step in (1, 2, 3)]
lost.append(doctor.leg("reviewers", "review", "kimi", now - 50, None, None, "", "", event="bench:r/kimi#4"))
doctor.mark_problems(recovered, lost)
found = doctor.leg_problems(recovered, lost, now - 86400, 24, now)
assert [(item["id"], item["state"], item["recovered"], item["lost_s"], len(item["evidence"])) for item in found] \
    == [("leg-failure:reviewers/crashed", "watch", 3, 180, 3)], found
assert doctor.leg_problems(recovered, lost[1:], now - 86400, 24, now) == []

# The sweep's commit settles a pending fix; a ledger changed since it was read is left alone.
pending = entry(narrow, "fixed-pending", fixes=[fix_at(100, None)])
fixture_ledger([pending])
source = open(path).read()
doctor.write_settled({"Z": "review-bench@abc1234"}, source + " ")
assert open(path).read() == source
doctor.write_settled({"Z": "review-bench@abc1234"}, source)
settled = json.load(open(path))["rows"][0]
assert settled["status"] == "fixed" and settled["fixes"][-1]["in"] == "review-bench@abc1234", settled
repos, saved_repos = os.path.join(unit, "cross-repos"), os.environ["LLM_DOCTOR_REPOS"]
for name in ("one", "two"):
    top = os.path.join(repos, name)
    os.makedirs(top)
    open(os.path.join(top, "f.py"), "w").write(name)
    for args in (["init", "-q"], ["add", "f.py"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", name]):
        doctor.subprocess.run(["git", "-C", top] + args, check=True, capture_output=True)
os.environ["LLM_DOCTOR_REPOS"] = repos
cross = {"id": "C", "status": "fixed-pending", "fixes": [{"at": doctor.iso_time(now - 3600), "files": ["one/f.py", "two/f.py"],
                                                          "in": None}]}
settled_ids, _ = doctor.settle_fixes({"by_id": {"C": cross}})
assert list(settled_ids) == ["C"] and cross["status"] == "fixed" \
    and doctor.re.fullmatch(r"(one|two)@[0-9a-f]+", cross["fixes"][-1]["in"]), cross
os.environ["LLM_DOCTOR_REPOS"] = saved_repos

# A rescued worker run starts at its restamped attempt, not at its directory's epoch.
rescued = os.path.join(unit, "runs", "codex-%d-9-f00d" % (now - 5000))
os.makedirs(rescued)
for name, text in (("tag", "main · astra · task\n"), ("err", "account lookup failed\n"), ("exit_code", "1\n"),
                   ("meta.json", json.dumps({"started_at": now - 1000}))):
    open(os.path.join(rescued, name), "w").write(text)
os.utime(os.path.join(rescued, "exit_code"), (now - 500, now - 500))
assert [row["start"] for row in doctor.worker_legs(now - 86400, now)[0]
        if row["ref"] == os.path.basename(rescued)] == [now - 1000]
shutil.rmtree(rescued)

# A malformed row is a fault of its own, never a crash of the whole collection.
id_less = dict(entry(narrow))
del id_less["id"]
for bad in (id_less, entry({"word": ["crashed"], "detail": "cell processing crashed"}), entry({"machinery": ""}, "open")):
    assert doctor.row_faults(bad, ["Z"]), bad
json.dump({"owner": "o", "owners": {block: "o" for block in doctor.BLOCKS},
           "rows": [id_less, entry({"word": ["x"], "detail": "abcdef"}, id=["L"]), entry({"machinery": ""}, "open", id="E")],
           "blind_spots": [{"id": "B"}]}, open(path, "w"))
malformed = doctor.load_ledger()
assert (malformed["by_id"], malformed["blind_spots"]) == ({}, []), malformed
assert ("rows[0]", "no id") in malformed["faults"] and ("blind_spots", "each is {id, what, reason, since, would_catch_if}") \
    in malformed["faults"], malformed["faults"]
# One problem per faulty place, under the row's whole id.
several = doctor.fault_problems([("leg-failure:workers/crashed", "no title"), ("leg-failure:workers/crashed", "block 'x'"),
                                 ("blind_spots", "a"), ("blind_spots", "b")], 24, now)
assert [(item["id"], item["count"]) for item in several] == [("ledger:leg-failure:workers/crashed", 2),
                                                             ("ledger:blind_spots", 2)], several
# A settlement meets a non-object row in the file without raising.
fixture_ledger([pending])
junk = dict(json.load(open(path)), rows=["junk", pending])
json.dump(junk, open(path, "w"))
source = open(path).read()
doctor.write_settled({"Z": "review-bench@abc1234"}, source)
assert json.load(open(path))["rows"][1]["status"] == "fixed"

# A commit git cannot vouch for is a fault only when git says so, and such a row judges nothing.
os.environ["LLM_DOCTOR_REPOS"] = late_repos
assert doctor.missing_commit("late@" + branch_fix) is None and doctor.missing_commit("late@deadbee")
os.environ["PATH"] = unit
assert doctor.missing_commit("late@deadbee") is None
os.environ["PATH"] = saved_path
bogus = fixture_ledger([entry(narrow, "fixed", fixes=[fix_at(7200, "late@deadbee")])])
_, bogus_faults = doctor.settle_fixes(bogus)
assert bogus_faults == [("Z", "deadbee is no commit of late")] and "Z" not in bogus["by_id"], bogus_faults
assert doctor.judge_leg_state(bogus, crashed(100, 50)) == ("new", None)
os.environ["LLM_DOCTOR_REPOS"] = saved_repos

# Frozen history keeps a row that is only faulty for now, and moves an unledgered id to a row that now claims it.
frozen = {"reviewers|sol|failed|crashed|ours|Z": 4, "reviewers|sol|failed|crashed|ours|leg-failure:reviewers/crashed": 3}
faulty = fixture_ledger([entry(narrow, reviewed_by="")])
assert doctor.relabel_frozen(frozen, faulty, now - 86400) == frozen
claims = fixture_ledger([entry({"word": "crashed", "model": "^sol"}, "open", id="S")])
assert doctor.relabel_frozen(frozen, claims, now - 86400) == {"reviewers|sol|failed|crashed|ours|S": 7}

# Hidden retries count only while their row still calls them bugs; a fix-proof row is listed once and keeps
# a post-fix match even at full exposure.
def hidden_attempts(ledger, start):
    rows = [doctor.leg("reviewers", "review", "kimi", now - 100 * step, "failed", "crashed", "crashed", "ours",
                       attempt="superseded", start=now - start - 100 * step, text="cell processing crashed",
                       event="bench:h/kimi#%d" % step) for step in (1, 2, 3)]
    doctor.mark_problems(ledger, rows)
    return [(item["id"], item["rule"], item["state"]) for item in doctor.leg_problems(ledger, rows, now - 86400, 24, now)]
assert hidden_attempts(fixture_ledger([entry(narrow)]), 0) == []
fixed_z = [entry(narrow, "fixed", fixes=[fix_at(7200)])]
assert hidden_attempts(fixture_ledger(fixed_z), 9000) == [("Z", "fix-proof", "watch")]
assert hidden_attempts(fixture_ledger(fixed_z), 0) == [("Z", "leg-failure", "watch")]
proven = fixture_ledger([entry({"word": "crashed", "model": "^sol"}, "fixed", fixes=[fix_at(90000)])])
history = [doctor.leg("reviewers", "review", "sol", now - 80000 + step, None, None, "", "", start=now - 80000 + step - 10)
           for step in range(10)]
history.append(doctor.leg("reviewers", "review", "sol", now - 70000, "failed", "crashed", "crashed", "ours",
                          start=now - 70010))
doctor.mark_problems(proven, history)
assert [(item["id"], item["rule"]) for item in doctor.leg_problems(proven, history, now - 3600, 1, now)] \
    == [("Z", "fix-proof")]

# A machinery or debt fix awaiting its commit stays listed once its anomalies are gone.
awaiting = fixture_ledger([entry({"machinery": "integrity"}, "fixed-pending", fixes=[fix_at(100, None)], id="MP"),
                           entry({"health": "debt", "key": "^debt-gap:abcdef"}, "fixed-pending", fixes=[fix_at(100, None)],
                                 id="HP", block="any")])
assert [(item["id"], item["state"]) for item in doctor.pending_fix_problems(awaiting, [], 24, now)] \
    == [("MP", "fixed-pending"), ("HP", "fixed-pending")]
assert doctor.pending_fix_problems(awaiting, [{"id": "MP"}, {"id": "HP"}], 24, now) == []

# A run gap the launch-time code made (no before listing) regresses a debt fix only when its run started after
# the fix, like a leg; one the fold made ran on the code current at the fold and is dated by it.
fixed_fold = fixture_ledger([entry({"health": "debt", "key": "^debt-gap:run-fold:snapshots unreadable$"}, "fixed",
                                   fixes=[fix_at(7200)], id="HF", block="any")])
def fold_states(run, before=False, family=False):
    snap = os.path.join(os.environ["WORKER_RUN_DIR"], run, *(["families", "1"] if family else []))
    os.makedirs(snap, exist_ok=True)
    if family:
        open(os.path.join(snap, "top"), "w").write("/r\n")
    if before:
        open(os.path.join(snap, "dirty-before-shas"), "w").close()
    with open(os.environ["ANCHORS_ROWS"], "w") as rows:
        rows.write(json.dumps({"session": "s9", "kind": "run-fold", "detail": "%s /r: snapshots unreadable" % run,
                               "count": 1, "first": now - 100, "last": now - 100}) + "\n")
    row = doctor.debt_health(now - 86400, now, 24)
    return [(item["id"], item["state"]) for item in doctor.health_problems(row, fixed_fold, 24) if item["rule"] == "debt-gap"]
assert fold_states("claudeb-%d-1-ab" % (now - 9000)) == []
assert fold_states("claudeb-%d-2-ab" % (now - 9000), family=True) == []
assert fold_states("claudeb-%d-3-ab" % (now - 9000), before=True) == [("HF", "regressed")]
assert fold_states("claudeb-%d-4-ab" % (now - 9000), before=True, family=True) == [("HF", "regressed")]
assert fold_states("claudeb-%d-1-ab" % (now - 3000)) == [("HF", "regressed")]
assert fold_states("w-1") == [("HF", "regressed")]

# A collector that throws leaves an error document, never an older document's colour.
os.environ["LLM_DOCTOR_DIR"] = os.path.join(unit, "doctor-error")
def broken(*args, **kwargs):
    raise RuntimeError("boom")
doctor.collect = broken
with contextlib.redirect_stderr(io.StringIO()) as said:
    assert doctor.main(["--quiet"]) == 1
assert said.getvalue() == "llm-doctor: collector failed: RuntimeError: boom\n", said.getvalue()
failed = json.load(open(os.path.join(unit, "doctor-error", "latest.json")))
assert (failed["status"], failed["self"]["error"], failed["problem_count"]) == ("error", "RuntimeError: boom", 0), failed

PY

echo "PASS: $asserts asserts; four blocks off fixture bench, worker-run, prelaunch and image-leg stores, bug vs weather, ledger new/open/regressed/fixed/dismissed, per-pass slow, superseded retries, chunk and judge legs, escape filtering, frozen daily history, rate trend against the rollup, files-note escapes, machinery classes held against the ledger, dry-run writes nothing, text view without run ids, debt health (open gaps from review-anchors counted once per cause (kind and repository, or kind and run, a run gap's why its own ledger key) with their repeats, old open gaps kept, a failing reader noted, logged losses once per drop with their lines, sessionless losses grouped by repository) and one bug-or-weather rule per record shape (login, status anchors, provider clock, turn budgets, owner switches, killed early, chunk readings, escapes, run records, prelaunch and image refusals, machinery age), the doctors' contract envelope (stable ids, states, evidence one per event ref, a missing required store blind, judge digest, a near miss under NO_EXIT_S), ledger faults for broad dismissals and fix records, a re-fixed row judged by its last fix and by leg start, causes retries hid, pending fixes settled from a fixture repo, the pinned judge (dismissal rows, theirs words, exemptions, prelaunch skips, limits) and the collector's error document"
