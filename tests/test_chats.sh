#!/usr/bin/env bash
# Tests for the parts of bin/chats that are not curses: the row a chat becomes,
# the column widths, the filter, and argument handling. The picker's drawing is
# left to a terminal; what breaks silently is the data underneath it.
set -u
export TZ=UTC

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/chats"

asserts=0
fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }

OUT=$(python3 - "$SCRIPT" <<'PY'
import importlib.machinery, importlib.util, sys

loader = importlib.machinery.SourceFileLoader("chats", sys.argv[1])
spec = importlib.util.spec_from_loader("chats", loader)
chats = importlib.util.module_from_spec(spec)
loader.exec_module(chats)

now = 1786000000.0
row = {"at": now - 3600, "role": "assistant", "text": "готово, хедер держится",
       "cwd": "/Volumes/Work/Projects/llm-legs", "branch": "main",
       "model": "claude-haiku-4-5-20251001", "ctx": 42000,
       "name": "Хедер и тени", "session": "abc123"}

cells = chats.columns(row, now)
print("model:", cells[2])
print("ctx:", cells[3])
print("project:", cells[1])
print("name:", cells[4])
print("quote:", cells[5])
print("ago:", chats.when_label(row["at"], now))
# A clock that ran backwards must not print a negative age.
print("future:", chats.when_label(now + 600, now))

nameless = dict(row, name=None)
print("nameless:", chats.columns(nameless, now)[4])
print("nameless-quote:", repr(chats.columns(nameless, now)[5]))

# Widths come from the rows, capped, and never from the timestamps.
print("plan:", chats.plan([row, dict(row, cwd="/x/" + "d" * 40)]))

print("filter-name:", chats.matches(row, "хедер"))
print("filter-branch:", chats.matches(row, "main"))
print("filter-words:", chats.matches(row, "llm-legs хедер"))
print("filter-miss:", chats.matches(row, "zzz"))
print("filter-empty:", chats.matches(row, ""))

print("label0:", chats.label(0, chats.WINDOWS))
print("label-last:", chats.label(len(chats.WINDOWS) - 1, chats.WINDOWS))
print("label-pinned:", chats.label(0, (7,)))
PY
) || fail "module probe failed"

assert grep -qx 'model: haiku-4-5' <<<"$OUT"
assert grep -qx 'ctx: 42k' <<<"$OUT"
assert grep -qx 'project: llm-legs' <<<"$OUT"
assert grep -qx 'name: Хедер и тени' <<<"$OUT"
# Who spoke last is what says whether a chat is finished or waiting on him.
assert grep -qx 'quote: claude: готово, хедер держится' <<<"$OUT"
assert grep -qx 'ago: 60m' <<<"$OUT"
assert grep -qx 'future: 0m' <<<"$OUT"
# With no name of its own, the last message stands in for one and is not repeated.
assert grep -qx 'nameless: claude: готово, хедер держится' <<<"$OUT"
assert grep -qx "nameless-quote: ''" <<<"$OUT"
assert grep -qx 'plan: \[22, 9, 3\]' <<<"$OUT"
assert grep -qx 'filter-name: True' <<<"$OUT"
assert grep -qx 'filter-branch: True' <<<"$OUT"
assert grep -qx 'filter-words: True' <<<"$OUT"
assert grep -qx 'filter-miss: False' <<<"$OUT"
assert grep -qx 'filter-empty: True' <<<"$OUT"
# The first window advertises that more history is a scroll away; the last does not.
assert grep -q 'label0: last 7d · ↓ for more' <<<"$OUT"
assert test -z "$(grep -o 'label-last:.*more' <<<"$OUT")"
assert grep -qx 'label-pinned: last 7d' <<<"$OUT"

# --- arguments are answered without a terminal ------------------------------
run() { OUT=$("$SCRIPT" "$@" </dev/null 2>&1); RC=$?; }

run --help
assert test "$RC" -eq 0
assert grep -q 'usage: chats' <<<"$OUT"

run --days abc
assert test "$RC" -ne 0
assert grep -q "not 'abc'" <<<"$OUT"

# An option silently dropped is worse than a refusal: the picker would open on a
# window he did not ask for.
run --days 7 --all
assert test "$RC" -ne 0
assert grep -q 'usage: chats' <<<"$OUT"

run --all extra
assert test "$RC" -ne 0

# Without a terminal it says so instead of dying inside curses.
run --days 7
assert test "$RC" -ne 0
assert grep -q 'full-screen picker' <<<"$OUT"

echo "PASS: chats ($asserts assertions)"
