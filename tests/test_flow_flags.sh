#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# share/flow_flags.py: Flow sends rebuilt from a fixture job ledger, each flag tied to its send (ledger rows, a clip
# send's own failed row, a failure report the ledger lacks), the context before it and the rates per condition.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$WORK"' EXIT
export GEMINI_WEB_DIR="$WORK/gw" TZ=UTC
mkdir -p "$GEMINI_WEB_DIR/failures" "$GEMINI_WEB_DIR/accounts"

python3 - "$ROOT/share" <<'EOF' || { echo "FAIL: test_flow_flags.sh" >&2; exit 1; }
import contextlib, io, json, os, sys, time
sys.path.insert(0, sys.argv[1])
import flow_flags as F

gw = os.environ["GEMINI_WEB_DIR"]
T0 = 1792000000
def image(ts, account, job, prompt="a cat", count=2, refs=()):
    return {"ts": ts, "kind": "flow-image", "event": "queued", "account": account, "job": job, "model": "pro",
            "count": count, "prompt": prompt, "refs": list(refs)}
rows = [image(T0, "a", "j1"), image(T0 + 100, "a", "j2"), image(T0 + 200, "a", "j3", prompt="a dog", refs=["r1"]),
        {"ts": T0 + 205, "event": "failed", "account": "a", "job": "j3", "model": "pro", "code": 3, "flagged": True},
        image(T0 + 250, "b", "j4", prompt="a dog", refs=["r1"]),
        {"ts": T0 + 400, "event": "failed", "kind": "flow-video", "account": "c", "model": "omni", "code": 3,
         "flagged": True, "count": 2, "refs": [], "prompt": "a river"},
        {"ts": T0 + 90000, "account": "a", "media_id": "m1", "dest": "/x/a.mp4", "state": "queued", "model": "fast",
         "job": "v1", "refs": []},
        {"ts": T0 + 90000, "account": "a", "media_id": "m2", "dest": "/x/a-2.mp4", "state": "queued", "model": "fast",
         "job": "v1", "refs": []}]
with open(os.path.join(gw, "jobs.jsonl"), "w") as out:
    out.write("".join(json.dumps(r) + "\n" for r in rows))
json.dump({"flagged_at": T0 + 205}, open(os.path.join(gw, "accounts", "a.json"), "w"))
stamp = time.strftime("%Y%m%dT%H%M%S", time.gmtime(T0 + 3000))
open(os.path.join(gw, "failures", stamp + "Z-d-1.txt"), "w").write(
    "reason: Flow flagged this account (PUBLIC_ERROR_UNUSUAL_ACTIVITY); nothing was charged\n")

F.gw.roster = lambda: ["a", "b", "c", "d"]
out = io.StringIO()
with contextlib.redirect_stdout(out):
    F.main(["--json"])
doc = json.loads(out.getvalue())
flags = {f["account"]: f for f in doc["flags"]}
assert doc["sends"] == 7 and sorted(flags) == ["a", "c", "d"], (doc["sends"], sorted(flags))
assert flags["a"]["job"] == "j3" and flags["a"]["takes_24h"] == 4 and flags["a"]["source"] == "ledger", flags["a"]
assert flags["c"]["kind"] == "clip" and flags["c"]["takes"] == 2, flags["c"]
assert flags["d"].get("unlogged") and flags["d"]["source"] == "report", flags["d"]
rates = doc["rates"]
assert rates["failover after a flag"]["True"] == {"sends": 1, "flags": 0}, rates["failover after a flag"]
assert rates["refs"]["shared with another account"] == {"sends": 1, "flags": 0}, rates["refs"]
assert rates["first send after a flag"]["True"] == {"sends": 1, "flags": 0}, rates["first send after a flag"]
assert rates["kind"] == {"clip": {"sends": 2, "flags": 1}, "image": {"sends": 4, "flags": 1}}, rates["kind"]
assert list(rates["takes in prior 24 h"]) == ["0", "1-5"], rates["takes in prior 24 h"]
EOF
echo "PASS: test_flow_flags.sh (a ledger flag on its send, a clip's failed send, a report-only flag, meta deduped, failover, shared refs, first send after a flag, rates per kind and in edge order)"
