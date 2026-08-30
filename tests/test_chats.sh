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

# The statusline's track file is what names the account a reply went through.
TRACKS="$(mktemp -d)"
trap 'rm -rf "$TRACKS"' EXIT
printf 'v2 1785996400 alona 0 3600 claude-haiku-4-5 reply-1 262144 1785996400 alona\n' \
  > "$TRACKS/cache-ttl-track-abc123"
printf 'v2 1785996400 ? 0 3600 claude-haiku-4-5 reply-9 262144 1785996400 com\n' \
  > "$TRACKS/cache-ttl-track-unknown"

OUT=$(STATUSLINE_CACHE_DIR="$TRACKS" python3 - "$SCRIPT" <<'PY'
import importlib.machinery, importlib.util, sys

loader = importlib.machinery.SourceFileLoader("chats", sys.argv[1])
spec = importlib.util.spec_from_loader("chats", loader)
chats = importlib.util.module_from_spec(spec)
loader.exec_module(chats)

now = 1786000000.0
row = {"at": now - 3600, "role": "assistant", "text": "done, the header holds",
       "cwd": "/Volumes/Work/Projects/llm-legs", "branch": "main",
       "model": "claude-haiku-4-5-20251001", "ctx": 42000,
       "name": "Header and shadows", "session": "abc123",
       "spoke": now - 3600 + 300, "uuid": "reply-1", "ttl": 3600}
chats.annotate([row])

cells = chats.columns(row, now)
print("model:", cells[2])
print("ctx:", cells[3])
# Five minutes of cache left: the column names the account holding it, and it is
# the account Enter would use.
print("warm:", chats.warm_name(row, now), chats.warm_name(row, now + 600))
# Landing on a row: its live cache decides, and a row without one hands the
# account back to the default the picker opened on — never to the previous row's.
print("account-warm:", chats.account_for(row, now, ["alona", "com"], 1))
print("account-cold:", chats.account_for(row, now + 600, ["alona", "com"], 1))
print("account-absent:", chats.account_for(row, now, ["com", "beta"], 1))
# A row already landed on is asked again while ←→ has not moved the account, so
# the cache expiring under a resting cursor hands it back; an override stands.
print("refollow:", chats.refollow(row, "abc123", 0, 0), chats.refollow(row, "abc123", 1, 0),
      chats.refollow(row, "other", 1, 0))
# The statusline saw a different reply last, so the account is unproven.
drift = dict(row, uuid="reply-2"); chats.annotate([drift])
print("drift:", chats.columns(drift, now)[3])
# A reply that cached nothing, and a track the statusline could not attribute.
none = dict(row, ttl=0); chats.annotate([none])
lost = dict(row, session="unknown", uuid="reply-9"); chats.annotate([lost])
print("cold:", chats.columns(none, now)[3], chats.columns(lost, now)[3])
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

print("filter-name:", chats.matches(row, "header"))
print("filter-branch:", chats.matches(row, "main"))
print("filter-words:", chats.matches(row, "llm-legs header"))
print("filter-miss:", chats.matches(row, "zzz"))
print("filter-empty:", chats.matches(row, ""))

# A CJK title is twice as wide as it is long. Every cut and every cursor
# position is measured in columns, or the quote lands on top of the head.
cjk = "Gemini树木图像生成对比"
print("cjk-width:", chats.width(cjk), len(cjk))
print("cjk-clip:", chats.clip(cjk, 10), chats.clip(cjk, 0) == "", chats.clip(cjk, 100) == cjk)
print("pad-invariant:", [chats.width(chats.pad(cjk, size, right=side))
                         for size in (0, 7, 10, 30) for side in (False, True)])
wrapped = dict(row, name="Gemini树木\nfoo\tbar")
print("name-oneline:", chats.columns(wrapped, now)[4])
print("blank-name:", chats.columns(dict(row, name="  \n "), now)[4:])

print("label0:", chats.label(0, chats.WINDOWS))
print("label-last:", chats.label(len(chats.WINDOWS) - 1, chats.WINDOWS))
print("label-pinned:", chats.label(0, (7,)))
PY
) || fail "module probe failed"

assert grep -qx 'model: haiku-4-5' <<<"$OUT"
assert grep -qx 'ctx: alona' <<<"$OUT"
assert grep -qx 'warm: alona None' <<<"$OUT"
assert grep -qx 'account-warm: 0' <<<"$OUT"
assert grep -qx 'account-cold: 1' <<<"$OUT"
assert grep -qx 'account-absent: 1' <<<"$OUT"
assert grep -qx 'refollow: True False True' <<<"$OUT"
assert grep -qx 'drift: 42k' <<<"$OUT"
assert grep -qx 'cold: 42k 42k' <<<"$OUT"
assert grep -qx 'project: llm-legs' <<<"$OUT"
assert grep -qx 'name: Header and shadows' <<<"$OUT"
# Who spoke last is what says whether a chat is finished or waiting on him.
assert grep -qx 'quote: claude: done, the header holds' <<<"$OUT"
assert grep -qx 'ago: 60m' <<<"$OUT"
assert grep -qx 'future: 0m' <<<"$OUT"
# With no name of its own, the last message stands in for one and is not repeated.
assert grep -qx 'nameless: claude: done, the header holds' <<<"$OUT"
assert grep -qx "nameless-quote: ''" <<<"$OUT"
assert grep -qx 'plan: \[22, 9, 5\]' <<<"$OUT"
assert grep -qx 'filter-name: True' <<<"$OUT"
assert grep -qx 'filter-branch: True' <<<"$OUT"
assert grep -qx 'filter-words: True' <<<"$OUT"
assert grep -qx 'filter-miss: False' <<<"$OUT"
assert grep -qx 'filter-empty: True' <<<"$OUT"
# The first window advertises that more history is a scroll away; the last does not.
# Six ASCII plus eight double-width glyphs: 22 columns out of 14 characters.
assert grep -qx 'cjk-width: 22 14' <<<"$OUT"
# A cut never splits a glyph, so ten columns hold six letters and two of them.
assert grep -qx 'cjk-clip: Gemini树木 True True' <<<"$OUT"
# Padding answers in columns whichever side it fills, and an odd size cannot be
# filled by half a glyph — it is filled with a space instead.
assert grep -qx 'pad-invariant: \[0, 0, 7, 7, 10, 10, 30, 30\]' <<<"$OUT"
assert grep -qx 'name-oneline: Gemini树木 foo bar' <<<"$OUT"
# A title of nothing but whitespace is no title: the last message stands in.
assert grep -qx "blank-name: \['claude: done, the header holds', ''\]" <<<"$OUT"
assert grep -q 'label0: last 7d · ↓ for more' <<<"$OUT"
assert test -z "$(grep -o 'label-last:.*more' <<<"$OUT")"
assert grep -qx 'label-pinned: last 7d' <<<"$OUT"

# --- the account the picker opens on ----------------------------------------
# worker-pick owns the choice; llm-limits' current account and .claudeb-state are
# only what is left when it can staff nobody.
STUB="$TRACKS/stub-bin"
mkdir -p "$STUB"
cat >"$STUB/worker-pick" <<'EOF'
#!/usr/bin/env bash
[ "$*" = "--account claudeb --role chat" ] || { printf 'stub: %s\n' "$*" >&2; exit 2; }
[ -n "${PICK_ANSWER:-}" ] || exit 3
printf '%s\n' "$PICK_ANSWER"
EOF
chmod +x "$STUB/worker-pick"
printf 'beta\n' >"$TRACKS/claudeb-state"

OUT=$(CLAUDEB_WORKER_PICK="$STUB/worker-pick" python3 - "$SCRIPT" "$TRACKS/claudeb-state" <<'PY'
import importlib.machinery, importlib.util, os, sys

loader = importlib.machinery.SourceFileLoader("chats", sys.argv[1])
spec = importlib.util.spec_from_loader("chats", loader)
chats = importlib.util.module_from_spec(spec)
loader.exec_module(chats)
chats.STATE = sys.argv[2]

names = ["alpha", "beta", "gamma"]
os.environ["PICK_ANSWER"] = "gamma"
print("pick:", chats.current_profile(names, None))
print("pick-over-announced:", chats.current_profile(names, "beta"))
os.environ["PICK_ANSWER"] = "ghost"
print("pick-unknown:", chats.current_profile(names, None))
del os.environ["PICK_ANSWER"]
print("none-announced:", chats.current_profile(names, "alpha"))
print("none-state:", chats.current_profile(names, None))
chats.STATE = sys.argv[2] + "-absent"
print("none-nothing:", chats.current_profile(names, None))
# The selector is the one beside this script, so a checkout answers with its own
# halves; the override is what a test — and an install that split them — has.
print("pick-binary:", chats.worker_pick())
del os.environ["CLAUDEB_WORKER_PICK"]
print("pick-sibling:", chats.worker_pick() == os.path.join(chats.HERE, "worker-pick"))
PY
) || fail "account probe failed"

assert grep -qx 'pick: 2' <<<"$OUT"
assert grep -qx 'pick-over-announced: 2' <<<"$OUT"
# An answer no profile here carries is no answer at all.
assert grep -qx 'pick-unknown: 1' <<<"$OUT"
assert grep -qx 'none-announced: 0' <<<"$OUT"
assert grep -qx 'none-state: 1' <<<"$OUT"
assert grep -qx "pick-binary: $STUB/worker-pick" <<<"$OUT"
assert grep -qx 'pick-sibling: True' <<<"$OUT"
assert grep -qx 'none-nothing: 0' <<<"$OUT"

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
