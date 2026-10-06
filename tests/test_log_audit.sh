#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd -P "$WORK" && pwd)"
asserts=0
fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
jqe() { jq -e "$@" >/dev/null; }

export LOG_AUDIT_DIR="$WORK/audit" CHAT_NAME_ROOTS="$WORK/projects" LOG_AUDIT_WORKER_RUN="$WORK/worker-run"
export CALLS="$WORK/calls" FAKE_RC=0
mkdir -p "$WORK/projects/-repo"
now=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
stamp() { date -u -r "$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%S.000Z; }

python3 - "$WORK/projects/-repo/chat.jsonl" "$(stamp 900)" "$(stamp 300)" "$now" <<'PY'
import json, sys
path, early, late, now = sys.argv[1:]
rows = [
    {"type": "custom-title", "customTitle": "Fixture chat"},
    {"type": "user", "timestamp": early, "entrypoint": "cli", "cwd": "/repo",
     "message": {"content": "<system-reminder>huge context</system-reminder>почему тест опять упал?"}},
    {"type": "assistant", "timestamp": early, "message": {"content": [
        {"type": "text", "text": "Running the suite."},
        {"type": "tool_use", "name": "Bash", "input": {"command": "bash tests/run-all"}}]}},
    {"type": "user", "timestamp": late, "message": {"content": [
        {"type": "tool_result", "content": "SECRET-OUTPUT " * 50, "is_error": False},
        {"type": "tool_result", "content": "FAIL: assert 3", "is_error": True}]}},
] + [{"type": "attachment", "timestamp": late, "attachment": {"type": "hook_success", "hookName": "PreToolUse:Bash",
                                                                "stderr": "awk: towc: multibyte conversion failure"}}] * 3 + [
    {"type": "system", "subtype": "turn_duration", "durationMs": 900000, "timestamp": now},
]
with open(path, "w") as handle:
    handle.write("\n".join(json.dumps(row) for row in rows) + "\n")
PY
python3 - "$WORK/projects/-repo/own.jsonl" "$now" <<'PY'
import json, sys
row = {"type": "user", "timestamp": sys.argv[2], "entrypoint": "sdk-cli", "message": {"content": "# Log audit: chunk 1 of 1"}}
open(sys.argv[1], "w").write(json.dumps(row) + "\n")
PY

cat >"$WORK/worker-run" <<'SH'
#!/usr/bin/env bash
case "$1" in
  start)
    shift
    brief=''; args="$*"
    while [ $# -gt 0 ]; do [ "$1" = --brief ] && brief=$2; shift; done
    printf '%s\t%s\t%s\n' "${WORKER_RUN_RELAY%%:*}" "$args" "$brief" >>"$CALLS"
    [ "$FAKE_RC" = 0 ] || { echo 'OUTCOME: CLAUDEB_USAGE_LIMIT'; exit "$FAKE_RC"; }
    n=$(wc -l <"$CALLS" | tr -d ' ')
    cp "$brief" "$CALLS.brief.$n"
    echo "RUN: fake-$n" ;;
  wait) echo 'STATUS: done' ;;
  report)
    n=${2#fake-}
    printf 'STATUS: done\nRESULT:\n'
    if grep -q '^# Log audit: merge' "$CALLS.brief.$n"; then
      echo '{"id": "hook-awk-multibyte", "title": "A Bash hook prints an awk multibyte error", "kind": "gate", "where": ["Fixture chat"], "quotes": ["H×3: PreToolUse:Bash stderr awk"], "why": "noise on every call", "minutes": 4, "fix": "hooks"}'
    else
      echo 'Reasoning first.'
      echo '{"title": "awk multibyte error from a hook", "kind": "gate", "where": ["Fixture chat"], "quote": "H×3: PreToolUse:Bash stderr awk", "why": "noise", "minutes": 4, "fix": "hooks"}'
    fi ;;
esac
SH
chmod +x "$WORK/worker-run"

# The skeleton keeps what was asked, said, done and failed; tool output and injected context are gone.
skeleton=$("$ROOT/bin/log-audit" skeleton "$WORK/projects/-repo/chat.jsonl")
assert grep -q '^### Fixture chat · cli · /repo$' <<<"$skeleton"
assert grep -q 'U: почему тест опять упал?$' <<<"$skeleton"
assert grep -q 'T: Bash bash tests/run-all$' <<<"$skeleton"
assert grep -q 'E: FAIL: assert 3$' <<<"$skeleton"
assert grep -q '^D: 10 min gap$' <<<"$skeleton"
assert grep -q 'D: turn took 15 min$' <<<"$skeleton"
assert grep -qx 'H×3: PreToolUse:Bash stderr awk: towc: multibyte conversion failure' <<<"$skeleton"
assert test "$(grep -c 'multibyte' <<<"$skeleton")" -eq 2
assert test "$(grep -c 'SECRET-OUTPUT\|huge context' <<<"$skeleton")" -eq 0

# A full read: every chunk and the merge run on Claude Sonnet under the log-audit relay type, and the
# audit's own transcripts are never read back.
out=$("$ROOT/bin/log-audit" run --night N1)
assert grep -q '^log-audit: 1 transcripts in 1 chunks read, 1 findings for the Harness doctor$' <<<"$out"
assert test "$(wc -l <"$CALLS" | tr -d ' ')" -eq 2
assert test "$(cut -f1 "$CALLS" | sort -u)" = log-audit
assert test "$(cut -f2 "$CALLS" | grep -c '^claudeb --model sonnet --effort medium ')" -eq 2
assert grep -q '^# Log audit: chunk 1 of 1$' "$CALLS.brief.1"
assert grep -q 'Fixture chat' "$CALLS.brief.1"
assert test "$(grep -c 'Log audit: chunk' "$CALLS.brief.1")" -eq 1
assert grep -q 'awk multibyte error from a hook' "$CALLS.brief.2"
assert jqe '.night == "N1" and .stop == "done" and .read == 1 and (.findings | length) == 1
  and .findings[0].id == "hook-awk-multibyte" and .findings[0].minutes == 4 and (.findings[0].at | type) == "number"' \
  "$LOG_AUDIT_DIR/findings.json"
first_until=$(jq -r '.until' "$LOG_AUDIT_DIR/findings.json")

# The next read starts where the last full one ended; a launch the account refuses stops the read, keeps the
# findings and leaves the start where it was, so the next night rereads those logs.
touch -t 202001010000 "$WORK/projects/-repo/chat.jsonl" "$WORK/projects/-repo/own.jsonl"
: >"$CALLS"
out=$("$ROOT/bin/log-audit" run --night N2)
assert grep -q '^log-audit: 0 transcripts in 0 chunks read, 0 findings' <<<"$out"
assert test ! -s "$CALLS"
assert jqe --argjson u "$first_until" '.since == $u and .stop == "done"' <(tail -1 "$LOG_AUDIT_DIR/runs.jsonl")
sleep 1
printf '{"type": "user", "timestamp": "%s", "message": {"content": "и снова"}}\n' "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
  >>"$WORK/projects/-repo/chat.jsonl"
FAKE_RC=3 "$ROOT/bin/log-audit" run --night N3 >"$WORK/out"; rc=$?
assert test "$rc" -eq 1
assert grep -q '^log-audit: stopped (launch-failed) after 0 of 1 chunks: worker-run start rc 3' "$WORK/out"
assert jqe '.findings[0].id == "hook-awk-multibyte"' "$LOG_AUDIT_DIR/findings.json"
assert jqe '.stop == "launch-failed" and .error != null' <(tail -1 "$LOG_AUDIT_DIR/runs.jsonl")
run_field() { jq -r ".$2" <(sed -n "$1p" "$LOG_AUDIT_DIR/runs.jsonl"); }
assert test "$(run_field 3 since)" = "$(run_field 2 until)"

# Detached, the read outlives the caller and leaves its line in detached.log.
: >"$CALLS"
printf '{"type": "user", "timestamp": "%s", "message": {"content": "ещё раз"}}\n' "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
  >>"$WORK/projects/-repo/chat.jsonl"
out=$("$ROOT/bin/log-audit" run --night N4 --detach)
assert grep -q '^log-audit: reading in the background (pid [0-9]*)' <<<"$out"
for _ in $(seq 1 100); do grep -q 'findings for the Harness doctor' "$LOG_AUDIT_DIR/detached.log" 2>/dev/null && break; sleep 0.1; done
assert grep -q '^log-audit: 1 transcripts in 1 chunks read, 1 findings for the Harness doctor$' "$LOG_AUDIT_DIR/detached.log"
assert jqe '.night == "N4" and .stop == "done"' "$LOG_AUDIT_DIR/findings.json"
assert test "$(run_field 4 since)" = "$(run_field 3 since)"

# The Harness doctor turns each finding into a red problem with its quotes, and none once the read is stale.
verdicts() { python3 - "$ROOT/bin/harness-doctor" "$1" <<'PY'
import importlib.machinery, importlib.util, json, sys
loader = importlib.machinery.SourceFileLoader("harness_doctor", sys.argv[1])
spec = importlib.util.spec_from_loader("harness_doctor", loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
found, at = module.audit_verdicts(float(sys.argv[2]))
print(json.dumps({"found": found, "at": at}))
PY
}
at=$(jq -r '.at' "$LOG_AUDIT_DIR/findings.json")
assert jqe '.found | length == 1 and .[0].rule == "log_audit" and .[0].ident == "hook-awk-multibyte" and .[0].level == "red"
  and .[0].group == "Log audit" and .[0].fact == "A Bash hook prints an awk multibyte error · ~4 min"
  and .[0].evidence[0].ref == "Fixture chat" and (.[0].evidence[0].excerpt | startswith("H×3"))' <(verdicts "$at")
assert jqe '.found == [] and (.at | type) == "number"' <(verdicts "$((at + 49 * 3600))")

echo "PASS: $asserts asserts; the transcript skeleton (asked, said, done, failed, gaps, long turns, repeated hook lines once with a count; tool output and injected context dropped), a full read on Claude Sonnet under the log-audit relay type that skips its own transcripts, the merge, an incremental next read, a refused launch that keeps the findings and the start, a detached read, and the Harness doctor's red problem per finding until the read goes stale"
