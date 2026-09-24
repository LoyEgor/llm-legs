#!/usr/bin/env bash
# llm-doctor reads fixture bench, worker-run and image-leg stores under a temp HOME: no real store is reachable.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCTOR="$ROOT/bin/llm-doctor"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }

export HOME="$WORK/home"
export WORKER_STATS_DIR="$HOME/stats" WORKER_RUN_DIR="$HOME/runs" LLM_DOCTOR_DIR="$HOME/doctor"
export IMAGE_LEG_LOG="$HOME/image-legs/legs.jsonl" LLM_DOCTOR_LEDGER="$WORK/ledger.json"
export GEMINIB_CACHE_DIR="$WORK/geminib"
mkdir -p "$GEMINIB_CACHE_DIR"
cat >"$GEMINIB_CACHE_DIR/models.json" <<'JSON'
{"fetched_at": 1, "attempted_at": 1, "families": [
  {"family": "gemini-3.8-flash", "slug": "flash38", "agy_prefix": "gemini-3.8-flash", "label": "Gemini 3.8 Flash"}
]}
JSON
NOW=$(( $(date +%s) / 60 * 60 ))
export LLM_DOCTOR_NOW="$NOW"

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
bench(3600, "bbbbbbb", [
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
   write_evidence=[["haiku-high", "main", "wrote /tmp/scratch/file"],
                   ["glm-high", "main", "wrote /Volumes/Work/Projects/other/file.py"]])
bench(18000, "ccccccc", [cell("sol-high", "sol", 18000, exit_code=1, stderr="cell processing crashed: OSError")])

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
worker("grok", 3500, "grok", 5, {"research-outcome": "READ_ONLY_VIOLATION\n",
                                 "err": "the tree digest of /x could not be taken\n"}, {"role": "research"})
outside = "UNKNOWN: transcript names a write outside the snapshotted repository; no content baseline was recorded: "
worker("claudeb", 3600, "sonnet", 0, {"files-note": outside + "/Volumes/Work/Projects/other/x.py\n"})
worker("claudeb", 3650, "sonnet", 0, {"files-note": outside + "/Volumes/Work/Projects/granted/x.py\n"},
       {"add_dirs": ["/Volumes/Work/Projects/granted"]})
worker("codex", 3700, "astra", 1, {"result": "the client now retries on rate limit exceeded\n", "err": "boom\n"})
worker("codex", 3800, "astra", 0, {"light-verdict": "SCOPE: escaped other/stray.txt\n"}, {"light": "edit"})
# The test shell is alive but younger than the recorded supervisor: its pid was reused.
worker("claudeb", 30000, "opus", None, None, {"pid": os.getppid(), "pid_started_at": now - 30300})
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

json.dump({"owners": {"reviewers": "Review owner", "workers": None, "light": None, "image": None}, "rows": [
    {"id": "X1", "block": "reviewers", "match": {"word": "crashed", "detail": "cell processing crashed"},
     "title": "processing crash", "status": "fixed", "fixed_in": ["review-bench@abc1234"], "fixed_at": iso_local(7200),
     "last_reviewed": time.strftime("%Y-%m-%d", time.gmtime(now - 86400)), "reviewed_by": "Review owner", "note": ""},
    {"id": "X2", "block": "workers", "match": {"word": "bad command", "model": "^grok", "detail": "unknown effort level"},
     "title": "effort grok does not serve", "status": "open", "fixed_in": [], "fixed_at": None,
     "last_reviewed": "2026-09-24", "reviewed_by": "", "note": ""},
    {"id": "X3", "block": "any", "match": {"word": "killed memory"}, "title": "memory guard", "status": "not-a-bug",
     "fixed_in": [], "fixed_at": None, "last_reviewed": "2026-09-24", "reviewed_by": "", "note": ""},
    {"id": "X4", "block": "image", "match": {"word": "bad output", "model": "^grok-image"}, "title": "no event",
     "status": "open", "fixed_in": [], "fixed_at": None, "last_reviewed": "2026-09-24", "reviewed_by": "", "note": ""},
    {"id": "X5", "block": "image", "match": {"word": "walled"}, "title": "image walls", "status": "weather",
     "fixed_in": [], "fixed_at": None, "last_reviewed": "2026-09-24", "reviewed_by": "", "note": ""},
    {"id": "X6", "block": "workers", "match": {"word": "unclassified", "until": iso_local(90000)},
     "title": "old unclassified storm", "status": "not-a-bug", "fixed_in": [], "fixed_at": None,
     "last_reviewed": "2026-09-24", "reviewed_by": "", "note": ""},
    {"id": "M1", "block": "reviewers", "match": {"machinery": "anchors"}, "title": "anchor warnings", "status": "open",
     "fixed_in": [], "fixed_at": None, "last_reviewed": "2026-09-24", "reviewed_by": "", "note": ""},
    {"id": "M2", "block": "reviewers", "match": {"machinery": "integrity"}, "title": "tree moved", "status": "fixed",
     "fixed_in": ["review-bench@abc1234"], "fixed_at": iso_local(7200), "last_reviewed": "2026-09-24",
     "reviewed_by": "", "note": ""},
    {"id": "M3", "block": "reviewers", "match": {"machinery": "debt_scope"}, "title": "debt scope", "status": "fixed",
     "fixed_in": ["review-bench@abc1234"], "fixed_at": iso_local(7200), "last_reviewed": "2026-09-24",
     "reviewed_by": "", "note": ""},
]}, open(ledger, "w"))
json.dump({"as_of": now - 60, "total": 9,
           "anomalies": {"anchors": 2, "closure_pending": 3, "debt_line": 0, "integrity": 1, "debt_scope": 3},
           "rows": {"integrity": [{"id": "r", "age_s": 600}], "debt_scope": [{"id": "d", "age_s": 9000}]}},
          open(os.path.join(os.path.dirname(benches), "doctor-snapshot.json"), "w"))

frozen_day = time.strftime("%Y-%m-%d", time.localtime(now - 10 * 86400))
os.makedirs(os.path.join(doctor, "daily"))
json.dump({"day": frozen_day, "covered": ["image"], "legs": {"image|grok-image": 9},
           "counts": {"image|grok-image|failed|bad output|ours|X4": 5, "image|grok-image|walled|||": 2}},
          open(os.path.join(doctor, "daily", frozen_day + ".json"), "w"))
PY

before=$(find "$LLM_DOCTOR_DIR" -type f | sort | tr '\n' ' ')
assert "$DOCTOR" --dry-run --json >"$WORK/doc.json"
assert test "$(find "$LLM_DOCTOR_DIR" -type f | sort | tr '\n' ' ')" = "$before"

assert python3 - "$WORK/doc.json" "$NOW" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
blocks = {block["block"]: block for block in doc["blocks"]}
assert [block["block"] for block in doc["blocks"]] == ["reviewers", "workers", "light", "image"]
assert doc["not_measurable"] == ["worker false-green reports", "weakened tests"]

def problems(block):
    return {(item["label"], (item["ledger"] or {}).get("id", "")): item for item in blocks[block]["problems"]}

review = problems("reviewers")
labels = sorted(review)
# The crash after the fix regressed its ledger row; the crash before it counts as fixed, not as a bug.
crash = review[("failed · crashed", "X1")]
assert crash["kind"] == "bug" and crash["status"] == "regressed", crash
assert crash["status_text"] == "regressed ×1 · 1 before fix", crash["status_text"]
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
assert slow["count"] == 1 and slow["models"] == ["opus"], slow
assert blocks["reviewers"]["owner"] == "Review owner" and blocks["workers"]["owner"] == ""
for problem in blocks["reviewers"]["problems"]:
    assert len(problem["daily"]) == 14, problem

workers = problems("workers")
assert workers[("failed · bad command", "X2")]["status"] == "open", sorted(workers)
assert workers[("walled", "")]["count"] == 2, workers[("walled", "")]
assert workers[("retried", "")]["count"] == 1, sorted(workers)
assert workers[("failed · bad command", "")]["incidents"][0]["detail"] == "model refused", sorted(workers)
light = problems("light")
assert light[("failed · crashed", "")]["incidents"][0]["detail"] == "tree digest not taken", sorted(light)
assert light[("escaped", "")]["incidents"][0]["detail"] == "light scope escaped", sorted(light)
assert blocks["light"]["bugs"] == 2 and blocks["light"]["new"] == 2, blocks["light"]
assert workers[("failed · crashed", "")]["incidents"][0]["detail"] == "no exit: supervisor gone", sorted(workers)
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
    ("anchors", "open"), ("closure_pending", "new"), ("debt_scope", "fixed"), ("integrity", "regressed")], machinery
assert machinery["issues"] == 4 and machinery["classes"][0]["ledger"]["id"] == "M1", machinery
for block in doc["blocks"]:
    for problem in block["problems"]:
        for incident in problem["incidents"]:
            assert set(incident) == {"age_s", "age", "model", "surface", "project", "tier", "attempt", "detail", "ref"}
PY

assert "$DOCTOR" --quiet
assert test -s "$LLM_DOCTOR_DIR/latest.json"
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

echo "PASS: $asserts asserts; four blocks off fixture bench, worker-run, prelaunch and image-leg stores, bug vs weather, ledger new/open/regressed/fixed/dismissed, per-pass slow, superseded retries, chunk and judge legs, escape filtering, frozen daily history, rate trend against the rollup, files-note escapes, machinery classes held against the ledger, dry-run writes nothing, text view without run ids"
