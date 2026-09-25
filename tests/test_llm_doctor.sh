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
unset STOP_GATE_JOURNAL WORDS_DIR REVIEW_DEBT_DIR
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

cache = os.path.join(os.environ["HOME"], ".cache", "claude")
for sub in ("stop-gate", "words", os.path.join("review-debt", "gaps")):
    os.makedirs(os.path.join(cache, sub), exist_ok=True)
def stop(offset, hooks, busy=""):
    return json.dumps({"ts": iso(offset), "session": "s1", "cwd": "/tmp", "busy": busy, "hooks": hooks}) + "\n"
with open(os.path.join(cache, "stop-gate", "journal.jsonl"), "w") as handle:
    handle.write(stop(3600, [{"name": "ask-slow.sh", "outcome": "error", "reason": "exit 124"}]))
    handle.write(stop(3000, [{"name": "ask-slow.sh", "outcome": "error", "reason": "exit 124"},
                             {"name": "ask-same.sh", "outcome": "asked", "reason": "do X"}]))
    handle.write(stop(2400, [{"name": "ask-same.sh", "outcome": "asked", "reason": "do X"}]))
    handle.write(stop(90000, [{"name": "ask-old.sh", "outcome": "error", "reason": "exit 1"}]))
    handle.write(stop(1200, [{"name": "notice-fine.sh", "outcome": "silent", "reason": ""}]))
with open(os.path.join(cache, "words", "journal.jsonl"), "w") as handle:
    for row in ({"ts": now - 500, "session": "s1", "turn": "1", "hook": "⚡ review", "match": False},
                {"ts": now - 400, "session": "s1", "turn": "2", "hook": "⚡ commit", "match": False},
                {"ts": now - 300, "session": "s1", "turn": "3", "hook": "⚡ push", "match": True},
                {"ts": now - 200, "session": "s1", "turn": "4", "hook": "⚡ pin", "match": None},
                {"ts": now - 100, "session": "s1", "turn": "5", "hook": "", "match": None, "silent": True},
                {"ts": now - 80, "session": "s2", "turn": "1", "chat": "Design system", "hook": None,
                 "model": ["⚡ понял: делаю сдвиг оттенка"], "match": False, "unprompted": True},
                {"ts": now - 70, "session": "s4", "turn": "1", "chat": "Design system (abcdef12)", "hook": None,
                 "model": ["⚡ понял: делаю сдвиг оттенка"], "match": False, "unprompted": True},
                {"ts": now - 60, "session": "s3", "turn": "1", "chat": "s3", "hook": "⚡ review", "match": False},
                {"mark": "ok", "ref": "%d:s1" % (now - 400)}):
        handle.write(json.dumps(row) + "\n")
with open(os.path.join(cache, "review-debt", "gaps", "s1"), "w") as handle:
    handle.write("%d\ttouch-failed\t/repo: review-anchors exited 1\n%d\tfixer-missing\told\n" % (now - 900, now - 90000))
PY

before=$(find "$LLM_DOCTOR_DIR" -type f | sort | tr '\n' ' ')
assert "$DOCTOR" --dry-run --json >"$WORK/doc.json"
assert test "$(find "$LLM_DOCTOR_DIR" -type f | sort | tr '\n' ' ')" = "$before"
# --json only prints: the menu's cache keeps its own window.
assert "$DOCTOR" --block reviewers --json >"$WORK/doc-block.json"
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

assert python3 - "$WORK/doc.json" "$NOW" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
blocks = {block["block"]: block for block in doc["blocks"]}
assert [block["block"] for block in doc["blocks"]] == ["reviewers", "workers", "light", "image"]
assert doc["not_measurable"] == ["worker false-green reports", "weakened tests"]
health = {row["name"]: row for row in doc["health"]}
assert [row["name"] for row in doc["health"]] == ["hooks", "debt"]
hooks = {(item["label"], item["chat"]): item["count"] for item in health["hooks"]["items"]}
assert hooks == {("ask-slow.sh: exit 124", "s1"): 2, ("ask-same.sh: same ask again within 30 min", "s1"): 1,
                 ("word notice with no reading: ⚡ review", "s1"): 1,
                 ("word notice with no reading: ⚡ review", "s3"): 1,
                 ("⚡ reading with no notice: ⚡ понял: делаю сдвиг оттенка", "Design system"): 2}, hooks
assert health["hooks"]["status"] == "problem" and health["hooks"]["count"] == 7
debt = {(item["label"], item["chat"]): item["count"] for item in health["debt"]["items"]}
assert debt == {("not recorded: touch-failed", "s1"): 1}, debt
assert health["debt"]["notes"] == ["losses.jsonl not written yet: only recording gaps are seen"]

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
slow_models = {}
for incident in slow["incidents"]:
    slow_models[incident["model"]] = slow_models.get(incident["model"], 0) + 1
assert slow["count"] == 8 and slow_models == {"opus": 1, "sonnet": 1, "haiku2": 5, "sz": 1}, (slow["count"], slow_models)
speed = blocks["reviewers"]["speed"]
assert speed["judged"] >= 15 and speed["unjudged"] >= 5, speed
assert blocks["reviewers"]["owner"] == "Review owner" and blocks["workers"]["owner"] == ""
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
# Every incident names the chat that launched its run, where the run recorded one.
assert light[("failed · crashed", "")]["incidents"][0]["chat"] == "feedface", light[("failed · crashed", "")]
launched = [incident for block in blocks.values() for problem in block["problems"]
            for incident in problem["incidents"] if incident["ref"].endswith("-bbbbbbb")]
assert launched and all(incident["chat"] == "cafebabe" for incident in launched), launched
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
    ("anchors", "open"), ("closure_pending", "new"), ("debt_scope", "fixed"), ("integrity", "regressed")], machinery
assert machinery["issues"] == 6 and machinery["classes"][0]["ledger"]["id"] == "M1", machinery
for block in doc["blocks"]:
    for problem in block["problems"]:
        for incident in problem["incidents"]:
            assert set(incident) == {"age_s", "age", "model", "surface", "project", "tier", "attempt", "detail", "ref",
                                     "session", "chat"}
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

printf '{"at":%d,"kind":"untouch","repo":"/r","path":"a.py","session":"s1","lines":12}\n' "$((NOW - 600))" \
  >"$HOME/.cache/claude/review-debt/losses.jsonl"
assert "$DOCTOR" --dry-run --json >"$WORK/doc2.json"
assert python3 - "$WORK/doc2.json" <<'PY'
import json, sys
debt = [row for row in json.load(open(sys.argv[1]))["health"] if row["name"] == "debt"][0]
items = {item["label"]: (item["count"], item["lines"]) for item in debt["items"]}
assert items == {"not recorded: touch-failed": (1, 0), "lost unreviewed: untouch": (1, 12)} and debt["notes"] == [], debt
PY

# Bug or weather, one rule per record shape: the module's own readers on fixtures of each shape.
UNIT="$WORK/unit"
mkdir -p "$UNIT"
assert env LLM_LIMITS_ACTION_LOG="$UNIT/actions.log" WORKER_RUN_DIR="$UNIT/runs" IMAGE_LEG_LOG="$UNIT/legs.jsonl" \
  WORKER_STATS_DIR="$UNIT/stats" STOP_GATE_JOURNAL="$UNIT/journal.jsonl" python3 - "$DOCTOR" "$NOW" "$UNIT" <<'PY'
import importlib.machinery, importlib.util, json, os, sys, time
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
for leg_row in legs:
    leg_row["state"], leg_row["ledger"] = doctor.judge_leg_state(doctor.load_ledger(), leg_row)
days = doctor.trend_days(now)
block = doctor.build_block("workers", legs, doctor.load_ledger(), {day: {"counts": {}, "legs": {}, "covered": []}
                                                                   for day in days}, now - 86400, now, {})
assert (block["bugs"], block["new"]) == (3, 3), block
assert sorted(problem["incidents_total"] for problem in block["problems"]) == [1, 2, 3], block["problems"]
assert {row["model"]: row["bugs"] for row in block["models"]} == {"astra": 2, "grok": 1}, block["models"]

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

# One busy repeated ask is one problem, not a busy one and a repeat.
with open(os.path.join(unit, "journal.jsonl"), "w") as handle:
    for offset in (600, 300):
        handle.write(json.dumps({"ts": iso(offset), "session": "s9", "busy": "yes",
                                 "hooks": [{"name": "gate.sh", "outcome": "asked", "reason": "review"}]}) + "\n")
hooks = doctor.hooks_health(now - 3600, now)
assert [(item["label"], item["count"]) for item in hooks["items"] if item["label"].startswith("gate.sh")] \
    == [("gate.sh: asked while busy", 2)], hooks

# The judge's short ruling has its own ledger row, never R1's review-cell shapes.
os.environ["LLM_DOCTOR_LEDGER"] = os.path.join(os.path.dirname(os.path.dirname(sys.argv[1])), "share", "doctor-ledger.json")
ledger = doctor.load_ledger()
short = doctor.leg("reviewers", "judge", "opus", now, "failed", "bad output", "bad output", "ours",
                   text="the judge ruled on 3 of 5 claims")
assert doctor.ledger_match(ledger, short)["id"] == "V14"
tool_event = doctor.leg("reviewers", "review", "astra", now, "failed", "bad output", "bad output", "ours",
                        text="malformed JSON after command_execution completed")
assert doctor.ledger_match(ledger, tool_event)["id"] != "N5"
PY

echo "PASS: $asserts asserts; four blocks off fixture bench, worker-run, prelaunch and image-leg stores, bug vs weather, ledger new/open/regressed/fixed/dismissed, per-pass slow, superseded retries, chunk and judge legs, escape filtering, frozen daily history, rate trend against the rollup, files-note escapes, machinery classes held against the ledger, dry-run writes nothing, text view without run ids, hooks health (hook errors, a repeated ask, an unanswered word notice minus an ok mark), debt health (recording gaps, logged losses with their lines) and one bug-or-weather rule per record shape (login, status anchors, provider clock, turn budgets, owner switches, killed early, chunk readings, escapes, run records, prelaunch and image refusals, machinery age)"
