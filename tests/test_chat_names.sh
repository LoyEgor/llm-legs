#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
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
  {
    printf '{"type": "user", "cwd": "/tmp/proj", "sessionId": "%s", "timestamp": "2026-01-20T09:00:00.000Z", "message": {"role": "user", "content": "hello"}}\n' "$session"
    [ -z "$ai" ] || printf '{"type": "ai-title", "aiTitle": "%s", "sessionId": "%s"}\n' "$ai" "$session"
    [ -z "$custom" ] || printf '{"type": "custom-title", "customTitle": "%s", "sessionId": "%s"}\n' "$custom" "$session"
  } >"$CORPUS/$session.jsonl"
}

# session_record <pid> <session> <name> <nameSource|->
session_record() {
  local source=
  [ "$4" = "-" ] || source=", \"nameSource\": \"$4\""
  printf '{"pid": 1, "sessionId": "%s", "name": "%s", "cwd": "/tmp/proj"%s}\n' "$2" "$3" "$source" \
    >"$HOME/.claude-profiles/com/sessions/$1.json"
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
  python3 -S - "$ROOT/share/chat_names.py" "$@" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("chat_names", sys.argv[1])
cn = importlib.util.module_from_spec(importlib.util.spec_from_loader("chat_names", loader))
loader.exec_module(cn)
print("\n".join(cn.chat_label(session) for session in sys.argv[2:]))
PY
}

# The queries that share one state ask in one process, a line each.
{ read -r l_chat; read -r l_named; read -r l_plain; read -r l_worker; read -r l_shared; } \
  < <(resolve "$CHAT" "$NAMED" "$PLAIN" "$WORKER" "$SHARED")

# --- the original name, and nothing invented in its place --------------------
assert test "$l_chat" = "make review bench and commit push more simple"
# A name he typed himself outranks the model's guess; both are names he has seen.
assert test "$l_named" = "мой заголовок"

# --- a derived placeholder never surfaces ------------------------------------
# It is the whole reason this resolver exists: `arbostar-frs-frontend-59` is a string the harness
# made up, and a chat holding nothing else is an id.
assert test "$l_plain" = "22222222"
assert test -z "$(grep -o 'arbostar' <<<"$l_plain")"
# The refusal is aimed at the placeholder and not at the record: a session record naming a chat the
# harness did NOT derive carries the name Claude Code gave it.
session_record 4055 "$PLAIN" "live chat with no title event" -
assert test "$(resolve "$PLAIN")" = "live chat with no title event"
rm -f "$HOME/.claude-profiles/com/sessions/4055.json"

# --- a worker run is shown as the chat that launched it ----------------------
assert test "$l_worker" = "make review bench and commit push more simple"
assert test -z "$(grep -o 'TASK' <<<"$l_worker")"
# Two chats resumed one worker session: named for either it hands the reader the wrong
# conversation, so it is named for neither.
assert test "$l_shared" = "55555555"
# A headless run no record names stays an id, whatever its own transcript calls it.
assert test "$(python3 -S - "$ROOT/share/chat_names.py" "$LONE" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("chat_names", sys.argv[1])
cn = importlib.util.module_from_spec(importlib.util.spec_from_loader("chat_names", loader))
loader.exec_module(cn)
print(cn.chat_label(sys.argv[2], headless=True))
PY
)" = "66666666"

# --- the run-record walk both readers share ----------------------------------
assert test "$(python3 -S - "$ROOT/share/chat_names.py" <<'PY'
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
assert python3 -S -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('version') and d.get('rows') else 1)" "$CHAT_NAMES_CACHE"
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
worker_run 20260101T1240Z-n5 n4 n5
{ read -r l_n4; read -r l_n5; } < <(resolve n4 n5)
assert test "$l_n4" = "renamed after the cache was written"
# One hop further nobody is answered for: a record naming itself would walk here forever.
assert test "$l_n5" = "n5"

# --- a run record that is not text is skipped, not fatal ---------------------
mkdir -p "$WORKER_RUN_DIR/20260101T1300Z-corrupt"
printf '%s\n' "$CHAT" >"$WORKER_RUN_DIR/20260101T1300Z-corrupt/launcher"
printf '\377\376 not utf-8\n' >"$WORKER_RUN_DIR/20260101T1300Z-corrupt/worker-session"
assert test "$(resolve "$WORKER")" = "renamed after the cache was written"

# --- the corpus root and a Path argument are one call ------------------------
# `transcript_name` passes a Path; a caller narrowing to paths beside a root passes the same kind.
assert test "$(python3 -S - "$ROOT/share/chat_names.py" "$CORPUS" "$CHAT" <<'PY'
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

# --- a matcher that failed is no answer to remember ----------------------------
# A finished chat's transcript never changes again, so "no name" cached off a failed scan would
# keep it unnamed in every later process.
assert test "$(python3 -S - "$ROOT/share/chat_names.py" "$NAMED" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("chat_names", sys.argv[1])
cn = importlib.util.module_from_spec(importlib.util.spec_from_loader("chat_names", loader))
loader.exec_module(cn)
cn._cache()["rows"].pop(sys.argv[2], None)
working = cn.searcher
cn.searcher = lambda: (["sh", "-c", "exit 2"], "/bin/sh")
failed = cn.transcript_name(sys.argv[2])
cn.searcher = working
print(failed, sys.argv[2] in cn._cache()["rows"], cn.transcript_name(sys.argv[2]))
PY
)" = "None False мой заголовок"

# --- bin/chat-name: the same answer for the surfaces that hold no Python ------
# The shell hooks that print a chat to Egor (claude-setup commit-report.sh) go through this and
# through nothing else. Two answers rather than one: a name, or exit 1 with an empty stdout — every
# caller already has the id it asked about, and its own spelling of it is the fallback, so a chat
# with no name it may surface by must not come back as an id wrapped in parentheses beside nothing.
CLI="$ROOT/bin/chat-name"
cli_out=$("$CLI" "$CHAT" "$WORKER" 11111111 44444444 "$CHAT"); cli_rc=$?
{ read -r c_chat; read -r c_worker; read -r c_short; read -r c_worker_short; read -r c_full; } <<<"$cli_out"
assert test "$c_chat" = "renamed after the cache was written (11111111)"
assert test "$cli_rc" = 0
# A derived placeholder is no name here either, and the caller keeps its own id.
plain_out=$("$CLI" "$PLAIN" 2>/dev/null); plain_rc=$?
assert test -z "$plain_out"
assert test "$plain_rc" = 1
# A worker folds to the chat that launched it — the errand's own title never surfaces — while the
# id in parentheses stays the one the caller asked about.
assert test "$c_worker" = "renamed after the cache was written (44444444)"
# Two chats resumed one worker session: named for either it hands the reader the wrong
# conversation, so the caller keeps the id.
assert test "$("$CLI" "$SHARED" >/dev/null 2>&1; echo $?)" = 1
# A caller that named no chat asked nothing, and that is neither of the two answers above.
assert test "$("$CLI" >/dev/null 2>&1; echo $?)" = 2
assert test "$("$CLI" "" >/dev/null 2>&1; echo $?)" = 2

# --- the short id every surface prints is a question this resolver answers ----
# `<name> (11111111)` is what Egor and every hook see, so 11111111 is what a reader has in hand;
# asked about one of those the resolver printed nothing at all (live 2026-08-25).
assert test "$c_short" = "renamed after the cache was written (11111111)"
# A worker's short id folds to the chat that launched it, exactly as its full id does.
assert test "$c_worker_short" = "renamed after the cache was written (44444444)"
# The full id keeps answering as it always did: a prefix is an addition, not a replacement.
assert test "$c_full" = "renamed after the cache was written (11111111)"
# Shorter than eight is a coincidence waiting to happen, and a non-hex token is not a short id at
# all: both are taken as the id they are spelled as, which names no chat.
assert test "$("$CLI" 1111111 >/dev/null 2>&1; echo $?)" = 1
assert test "$("$CLI" zzzzzzzz >/dev/null 2>&1; echo $?)" = 1
assert test "$("$CLI" deadbeef >/dev/null 2>&1; echo $?)" = 1

# Two chats behind one prefix: shown under either it hands the reader the wrong conversation, so it
# is shown under neither and the candidates are listed instead. The second of them exists only in a
# run record — a chat whose transcript has been swept still names the runs it spawned.
AMBIG_A=aabbccdd-0000-0000-0000-000000000000
AMBIG_B=aabbccdd-1111-1111-1111-111111111111
transcript "$AMBIG_A" "one of two behind the same prefix"
worker_run 20260101T1400Z-ambiguous "$AMBIG_B" ambiguous-worker
ambiguous_out=$("$CLI" aabbccdd 2>"$WORK/ambiguous.err"); ambiguous_rc=$?
ambiguous=$(<"$WORK/ambiguous.err")
assert test "$ambiguous_rc" = 3
assert test -z "$ambiguous_out"
assert grep -q 'names 2 chats' <<<"$ambiguous"
assert grep -qF "$AMBIG_A" <<<"$ambiguous"
assert grep -qF "$AMBIG_B" <<<"$ambiguous"
# The full id is unambiguous however crowded its prefix is.
assert test "$("$CLI" "$AMBIG_A")" = "one of two behind the same prefix (aabbccdd)"

# --- a menu names every chat it knows, and never by its id -------------------
# No window, list or picker Egor uses shows an id, so a menu row naming one tells him nothing: an
# untitled chat is described by its project and start, a run that kept no transcript by its profile.
title() {
  python3 -S - "$ROOT/share/chat_names.py" "$@" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("chat_names", sys.argv[1])
cn = importlib.util.module_from_spec(importlib.util.spec_from_loader("chat_names", loader))
loader.exec_module(cn)
print("\n".join(str(cn.chat_title(session)) for session in sys.argv[2:]))
PY
}
HEADLESS=77777777-7777-7777-7777-777777777777
mkdir -p "$HOME/.claude-profiles/com/session-env/$HEADLESS"
ERRAND=99999999-9999-9999-9999-999999999999
printf '%s\n' '{"type":"user","cwd":"/tmp/errand","timestamp":"2026-01-20T09:00:00.000Z","message":{"role":"user","content":"TASK"}}' \
  >"$CORPUS/$ERRAND.jsonl"
worker_run 20260101T1500Z-unnamed "$PLAIN" "$ERRAND"
{ read -r t_chat; read -r t_plain; read -r t_headless; read -r t_missing; read -r t_errand; read -r t_shared; } \
  < <(title "$CHAT" "$PLAIN" "$HEADLESS" 88888888-8888-8888-8888-888888888888 "$ERRAND" "$SHARED")
assert test "$t_chat" = "renamed after the cache was written"
assert grep -qE '^untitled chat · proj · [A-Z][a-z]{2} [0-9]{2}:[0-9]{2}$' <<<"$t_plain"
assert grep -qE '^run with no transcript · com · [A-Z][a-z]{2} [0-9]{2}:[0-9]{2}$' <<<"$t_headless"
assert test "$t_missing" = None
# A worker whose launcher has no name is described as that launcher, never by its own project and
# start; one two chats resumed is described as nothing.
assert grep -q '^untitled chat · proj · ' <<<"$t_errand"
assert test "$t_shared" = None
plain=$("$CLI" --json "$PLAIN")
assert test "$(jq -r '.name' <<<"$plain")" = ""
assert test "$(jq -r '.short' <<<"$plain")" = 22222222
assert grep -q '^untitled chat · proj · ' <<<"$(jq -r '.title' <<<"$plain")"
assert test "$("$CLI" --json "$CHAT" | jq -r '.name + "|" + .title')" = \
  "renamed after the cache was written|renamed after the cache was written"
assert test "$("$CLI" --json 88888888-8888-8888-8888-888888888888 >/dev/null 2>&1; echo $?)" = 1
assert test "$("$CLI" --json >/dev/null 2>&1; echo $?)" = 2

echo "PASS: chat-names ($asserts assertions)"
