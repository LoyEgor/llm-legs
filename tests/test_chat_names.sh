#!/usr/bin/env bash
# Hermetic tests for share/chat_names.py — the one resolver every surface names a chat through.
#
# The rule it enforces: a chat surfaces under the name Claude Code gave it and under nothing else.
# The derived placeholder in a session record is a name Egor has never seen, a worker run is an
# errand rather than a conversation, and both have surfaced as chats before. Fixtures only: HOME,
# WORKER_RUN_DIR, CHAT_NAME_ROOTS and CHAT_NAMES_CACHE all point inside the work directory, so the
# real profile store is never read and never written.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }

export HOME="$WORK/home"
export WORKER_RUN_DIR="$WORK/runs"
export CHAT_NAMES_CACHE="$WORK/cache/chat-names.json"
mkdir -p "$HOME/.claude-profiles/com/projects/-tmp-proj" \
         "$HOME/.claude-profiles/com/sessions" "$WORK/runs"

CORPUS="$HOME/.claude-profiles/com/projects/-tmp-proj"

# transcript <session> [ai title] [custom title]
transcript() {
  local session=$1 ai=${2:-} custom=${3:-}
  local file="$CORPUS/$session.jsonl"
  python3 - "$file" "$session" "$ai" "$custom" <<'PY'
import json, sys
path, session, ai, custom = sys.argv[1:5]
with open(path, "w", encoding="utf-8") as handle:
    handle.write(json.dumps({"type": "user", "cwd": "/tmp/proj", "sessionId": session,
                             "timestamp": "2026-01-20T09:00:00.000Z",
                             "message": {"role": "user", "content": "hello"}},
                            ensure_ascii=False) + "\n")
    if ai:
        handle.write(json.dumps({"type": "ai-title", "aiTitle": ai, "sessionId": session},
                                ensure_ascii=False) + "\n")
    if custom:
        handle.write(json.dumps({"type": "custom-title", "customTitle": custom,
                                 "sessionId": session}, ensure_ascii=False) + "\n")
PY
}

# session_record <pid> <session> <name> <nameSource|->
session_record() {
  python3 - "$HOME/.claude-profiles/com/sessions/$1.json" "$2" "$3" "$4" <<'PY'
import json, sys
path, session, name, source = sys.argv[1:5]
entry = {"pid": 1, "sessionId": session, "name": name, "cwd": "/tmp/proj"}
if source != "-":
    entry["nameSource"] = source
open(path, "w", encoding="utf-8").write(json.dumps(entry) + "\n")
PY
}

# worker_run <run id> <launcher|-> <worker session>...
worker_run() {
  local directory="$WORKER_RUN_DIR/$1" launcher=$2
  shift 2
  mkdir -p "$directory"
  [ "$launcher" = "-" ] || printf '%s\n' "$launcher" >"$directory/launcher"
  printf '%s\n' "$@" >"$directory/worker-session"
}

CHAT=11111111-1111-1111-1111-111111111111
PLAIN=22222222-2222-2222-2222-222222222222
NAMED=33333333-3333-3333-3333-333333333333
WORKER=44444444-4444-4444-4444-444444444444
SHARED=55555555-5555-5555-5555-555555555555
LONE=66666666-6666-6666-6666-666666666666

transcript "$CHAT" "make review bench and commit push more simple"
transcript "$PLAIN"
transcript "$NAMED" "Gemini树木图像生成对比" "мой заголовок"
# A worker's own transcript carries a title of its own — the errand's, never a chat's.
transcript "$WORKER" "TASK: fix the overlay flicker"
transcript "$SHARED" "resumed by two chats"
transcript "$LONE" "headless errand nobody launched"

# The placeholder the harness derives from the working directory, over a chat that has no title of
# its own — the name Egor has never seen.
session_record 3916 "$PLAIN" "arbostar-frs-frontend-59" derived
worker_run 20260101T0900Z-shell "$CHAT" "$WORKER"
worker_run 20260101T1100Z-first "$CHAT" "$SHARED"
worker_run 20260101T1110Z-second "$NAMED" "$SHARED"

resolve() {
  python3 - "$ROOT/share/chat_names.py" "$@" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("chat_names", sys.argv[1])
cn = importlib.util.module_from_spec(importlib.util.spec_from_loader("chat_names", loader))
loader.exec_module(cn)
print("\n".join(cn.chat_label(session) for session in sys.argv[2:]))
PY
}

# --- the original name, and nothing invented in its place --------------------
assert test "$(resolve "$CHAT")" = "make review bench and commit push more simple"
# A name he typed himself outranks the model's guess; both are names he has seen.
assert test "$(resolve "$NAMED")" = "мой заголовок"

# --- a derived placeholder never surfaces ------------------------------------
# It is the whole reason this resolver exists: `arbostar-frs-frontend-59` is a string the harness
# made up, and a chat holding nothing else is an id.
assert test "$(resolve "$PLAIN")" = "22222222"
assert test -z "$(resolve "$PLAIN" | grep -o 'arbostar')"
# The refusal is aimed at the placeholder and not at the record: a session record naming a chat the
# harness did NOT derive carries the name Claude Code gave it.
session_record 4055 "$PLAIN" "live chat with no title event" -
assert test "$(resolve "$PLAIN")" = "live chat with no title event"
rm -f "$HOME/.claude-profiles/com/sessions/4055.json"

# --- a worker run is shown as the chat that launched it ----------------------
assert test "$(resolve "$WORKER")" = "make review bench and commit push more simple"
assert test -z "$(resolve "$WORKER" | grep -o 'TASK')"
# Two chats resumed one worker session: named for either it hands the reader the wrong
# conversation, so it is named for neither.
assert test "$(resolve "$SHARED")" = "55555555"
# A headless run no record names stays an id, whatever its own transcript calls it.
assert test "$(python3 - "$ROOT/share/chat_names.py" "$LONE" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("chat_names", sys.argv[1])
cn = importlib.util.module_from_spec(importlib.util.spec_from_loader("chat_names", loader))
loader.exec_module(cn)
print(cn.chat_label(sys.argv[2], headless=True))
PY
)" = "66666666"

# --- the run-record walk both readers share ----------------------------------
assert test "$(python3 - "$ROOT/share/chat_names.py" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("chat_names", sys.argv[1])
cn = importlib.util.module_from_spec(importlib.util.spec_from_loader("chat_names", loader))
loader.exec_module(cn)
mapping = cn.worker_session_launchers()
print(len(mapping), mapping.get("44444444-4444-4444-4444-444444444444"),
      "55555555-5555-5555-5555-555555555555" in mapping)
PY
)" = "1 11111111-1111-1111-1111-111111111111 False"

# --- the cache answers the same and yields to a rename -----------------------
assert test -f "$CHAT_NAMES_CACHE"
assert grep -Fq 'make review bench and commit push more simple' "$CHAT_NAMES_CACHE"
# Written whole, never in place: a reader arriving mid-write must find the old file or the new
# one, and the temporary it was built in must not survive the swap.
assert test -z "$(ls "$(dirname "$CHAT_NAMES_CACHE")" | grep -o 'tmp')"
assert python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('version') and d.get('rows') else 1)" "$CHAT_NAMES_CACHE"
transcript "$CHAT" "renamed after the cache was written"
assert test "$(resolve "$CHAT")" = "renamed after the cache was written"
# A cache holding anything but its own document is no cache: read as one it would take every name
# off every surface at once, which is the opposite of what a best-effort cache is for.
for broken in null '[]' '"rows"' '{"version":1,"rows":[]}'; do
  printf '%s\n' "$broken" >"$CHAT_NAMES_CACHE"
  assert test "$(resolve "$CHAT")" = "renamed after the cache was written"
done

# --- a chain of spawns ends at the chat that started it ----------------------
# Four folds is what FOLD_HOPS allows; the chat at the end of a chain that long is still a chat.
for hop in 1 2 3 4 5; do transcript "n$hop" "TASK: nested $hop"; done
worker_run 20260101T1200Z-n1 "$CHAT" n1
worker_run 20260101T1210Z-n2 n1 n2
worker_run 20260101T1220Z-n3 n2 n3
worker_run 20260101T1230Z-n4 n3 n4
assert test "$(resolve n4)" = "renamed after the cache was written"
# One hop further nobody is answered for: a record naming itself would walk here forever.
worker_run 20260101T1240Z-n5 n4 n5
assert test "$(resolve n5)" = "n5"

# --- a run record that is not text is skipped, not fatal ---------------------
mkdir -p "$WORKER_RUN_DIR/20260101T1300Z-corrupt"
printf '%s\n' "$CHAT" >"$WORKER_RUN_DIR/20260101T1300Z-corrupt/launcher"
printf '\377\376 not utf-8\n' >"$WORKER_RUN_DIR/20260101T1300Z-corrupt/worker-session"
assert test "$(resolve "$WORKER")" = "renamed after the cache was written"

# --- the corpus root and a Path argument are one call ------------------------
# `transcript_name` passes a Path; a caller narrowing to paths beside a root passes the same kind.
assert test "$(python3 - "$ROOT/share/chat_names.py" "$CORPUS" "$CHAT" <<'PY'
import importlib.machinery, importlib.util, sys
from pathlib import Path
loader = importlib.machinery.SourceFileLoader("chat_names", sys.argv[1])
cn = importlib.util.module_from_spec(importlib.util.spec_from_loader("chat_names", loader))
loader.exec_module(cn)
root, session = sys.argv[2], sys.argv[3]
found = cn.names_by_path(root, [Path(root) / (session + ".jsonl")])
print((found.get(str(Path(root) / (session + ".jsonl"))) or {}).get("ai"))
PY
)" = "renamed after the cache was written"

# --- bin/chat-name: the same answer for the surfaces that hold no Python ------
# The shell hooks that print a chat to Egor (claude-setup commit-report.sh) go through this and
# through nothing else. Two answers rather than one: a name, or exit 1 with an empty stdout — every
# caller already has the id it asked about, and its own spelling of it is the fallback, so a chat
# with no name it may surface by must not come back as an id wrapped in parentheses beside nothing.
CLI="$ROOT/bin/chat-name"
assert test "$("$CLI" "$CHAT")" = "renamed after the cache was written (11111111)"
assert "$CLI" "$CHAT" >/dev/null
# A derived placeholder is no name here either, and the caller keeps its own id.
assert test -z "$("$CLI" "$PLAIN" 2>/dev/null)"
assert test "$("$CLI" "$PLAIN" >/dev/null 2>&1; echo $?)" = 1
# A worker folds to the chat that launched it — the errand's own title never surfaces — while the
# id in parentheses stays the one the caller asked about.
assert test "$("$CLI" "$WORKER")" = "renamed after the cache was written (44444444)"
# Two chats resumed one worker session: named for either it hands the reader the wrong
# conversation, so the caller keeps the id.
assert test "$("$CLI" "$SHARED" >/dev/null 2>&1; echo $?)" = 1
# A caller that named no chat asked nothing, and that is neither of the two answers above.
assert test "$("$CLI" >/dev/null 2>&1; echo $?)" = 2
assert test "$("$CLI" "" >/dev/null 2>&1; echo $?)" = 2

echo "PASS: chat-names ($asserts assertions)"
