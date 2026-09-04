#!/usr/bin/env bash
# Tests for the parts of bin/chats that are not curses: the row a chat becomes,
# the column widths, the filter, the one-column ask mark, and argument handling.
# The picker's drawing is left to a terminal; what breaks silently is the data
# underneath it — including the track line it shares with the statusline.
set -u
export TZ=UTC

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/chats"
STATUSLINE="$ROOT/bin/statusline.sh"

asserts=0
fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The statusline's track file is what names the account a reply went through. The stamp is the
# reply the statusline attributed, which is the row's own reply here. The line carries a SECOND
# account — the one that session was running under when it last looked — deliberately different
# from the attributed one, so a reader counting to the wrong field is caught here.
TRACKS="$WORK/tracks"
mkdir -p "$TRACKS"
printf 'v2 1785996700 alona 0 3600 claude-haiku-4-5 reply-1 262144 1785996700 com\n' \
  > "$TRACKS/cache-ttl-track-abc123"
# A chat left open: the statusline went on to a reply this listing has not seen.
printf 'v2 1785996760 alona 0 3600 claude-haiku-4-5 reply-2 262144 1785996760 alona\n' \
  > "$TRACKS/cache-ttl-track-ahead"
# A track that stopped before this row's reply: whatever answered since is unproven.
printf 'v2 1785996640 alona 0 3600 claude-haiku-4-5 reply-0 262144 1785996640 alona\n' \
  > "$TRACKS/cache-ttl-track-behind"
printf 'v2 1785996700 ? 0 3600 claude-haiku-4-5 reply-9 262144 1785996700 com\n' \
  > "$TRACKS/cache-ttl-track-unknown"

OUT=$(STATUSLINE_CACHE_DIR="$TRACKS" python3 - "$SCRIPT" "$STATUSLINE" <<'PY'
import importlib.machinery, importlib.util, inspect, re, sys

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
# The statusline stamps the newest reply of any kind and this listing the newest one that SPOKE,
# so a chat ending on a tool call leaves the two naming different replies. A track AHEAD of the
# row is later knowledge and counts the lifetime from its own stamp; one behind it proves nothing.
ahead = dict(row, session="ahead"); chats.annotate([ahead])
behind = dict(row, session="behind"); chats.annotate([behind])
print("ahead:", chats.columns(ahead, now)[3], chats.warm_name(ahead, now + 330))
print("behind:", chats.columns(behind, now)[3])
# A reply that cached nothing, and a track the statusline could not attribute.
none = dict(row, ttl=0); chats.annotate([none])
lost = dict(row, session="unknown", uuid="reply-9"); chats.annotate([lost])
print("cold:", chats.columns(none, now)[3], chats.columns(lost, now)[3])
print("project:", cells[1])
print("name:", cells[4])
print("quote:", cells[5])
# One time column: a chat spoken in today is placed by its clock, anything older by its date,
# both five columns wide. Everything at or after today's midnight is placed by its clock, so a
# stamp from a skewed clock reads as an hour of today however far ahead of now it sits.
print("today:", repr(cells[0]))
print("midnight:", chats.when_label(1785974400.0, now), chats.when_label(1785974399.0, now))
print("older:", chats.when_label(now - 86400, now))
# The last window has no horizon, so two 07.04s in it can be a year apart.
print("dated:", chats.when_label(now - 86400, now, True), chats.when_label(now, now, True))
print("dated-cell:", repr(chats.columns(dict(row, at=now - 86400), now, True)[0]))
print("future:", chats.when_label(now + 600, now))
print("future-day:", chats.when_label(now + 86400, now))

nameless = dict(row, name=None)
print("nameless:", chats.columns(nameless, now)[4])
print("nameless-quote:", repr(chats.columns(nameless, now)[5]))

# A worktree lives inside its repository, so the column names the PROJECT it belongs to and
# leaves the branch to the title — while the resume path keeps the worktree itself, or claude
# slugs --resume against the wrong project and finds no transcript.
tree = "/w/proj/.claude/worktrees/WUT-1_x"
worktree_row = dict(row, cwd=tree)
print("wt-project:", chats.columns(worktree_row, now)[1])
print("wt-deep:", chats.columns(dict(row, cwd=tree + "/src/app"), now)[1])
print("wt-plain:", chats.columns(dict(row, cwd="/w/other"), now)[1])
print("wt-cwd-kept:", worktree_row["cwd"] == tree)
print("wt-resume-raw:", "project_label" not in inspect.getsource(chats.main))
# The cap holds on a project reached through a worktree exactly as on a plain one.
print("wt-plan:", chats.plan([dict(row, cwd="/w/" + "d" * 40 + "/.claude/worktrees/b")]))

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

# The mark is one column wide whether it is there or not: a row that widens when a chat
# starts waiting would move every field to its right.
print("mark-asking:", repr(chats.ask_mark(dict(row, asking=True))))
print("mark-plain:", repr(chats.ask_mark(row)))

# --- the track line is ONE format, written there and read here ---------------
# The reader counts fields by position, so reordering that printf keeps every suite green while
# the picker names the wrong account. Pin the two to each other rather than to a literal line.
writer = re.search(r"printf 'v2((?: %s)+)\\n'((?:[^\n]*\\\n)*[^\n]*)",
                   open(sys.argv[2], encoding="utf-8").read())
# The arg list ends where the redirect begins; a `>` never appears inside it.
args = re.findall(r'"\$\{?([a-z_]+)', writer.group(2).split(">")[0])
print("writer-fields:", writer.group(1).count("%s") == len(args), len(args))
print("pinned-ts:", args[chats.TRACK_TS - 1])
print("pinned-account:", args[chats.TRACK_ACCOUNT - 1])
PY
) || fail "module probe failed"

assert grep -qx 'model: haiku-4-5' <<<"$OUT"
assert grep -qx 'ctx: alona' <<<"$OUT"
assert grep -qx 'warm: alona None' <<<"$OUT"
assert grep -qx 'account-warm: 0' <<<"$OUT"
assert grep -qx 'account-cold: 1' <<<"$OUT"
assert grep -qx 'account-absent: 1' <<<"$OUT"
assert grep -qx 'refollow: True False True' <<<"$OUT"
# The minute past this row's own expiry is still warm on the track's later stamp.
assert grep -qx 'ahead: alona alona' <<<"$OUT"
assert grep -qx 'behind: 42k' <<<"$OUT"
assert grep -qx 'cold: 42k 42k' <<<"$OUT"
assert grep -qx 'project: llm-legs' <<<"$OUT"
assert grep -qx 'name: Header and shadows' <<<"$OUT"
# Who spoke last is what says whether a chat is finished or waiting on him.
assert grep -qx 'quote: claude: done, the header holds' <<<"$OUT"
assert grep -qx "today: '06:06'" <<<"$OUT"
assert grep -qx 'midnight: 00:00 05.08' <<<"$OUT"
assert grep -qx 'older: 05.08' <<<"$OUT"
# The last window has no horizon, so the year is the only thing telling two 05.08s apart; the
# cell widens with it, once, for every row of that view rather than for the old ones alone.
assert grep -qx 'dated: 05.08.26 07:06' <<<"$OUT"
assert grep -qx "dated-cell: '05.08.26'" <<<"$OUT"
assert grep -qx 'future: 07:16' <<<"$OUT"
assert grep -qx 'future-day: 07:06' <<<"$OUT"
# With no name of its own, the last message stands in for one and is not repeated.
assert grep -qx 'nameless: claude: done, the header holds' <<<"$OUT"
assert grep -qx "nameless-quote: ''" <<<"$OUT"
assert grep -qx 'wt-project: proj' <<<"$OUT"
assert grep -qx 'wt-deep: proj' <<<"$OUT"
assert grep -qx 'wt-plain: other' <<<"$OUT"
assert grep -qx 'wt-cwd-kept: True' <<<"$OUT"
assert grep -qx 'wt-resume-raw: True' <<<"$OUT"
assert grep -qx 'wt-plan: \[22, 9, 5\]' <<<"$OUT"
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
assert grep -qx "mark-asking: '?'" <<<"$OUT"
assert grep -qx "mark-plain: ' '" <<<"$OUT"
assert grep -qx 'writer-fields: True 9' <<<"$OUT"
assert grep -qx 'pinned-ts: rec_ts' <<<"$OUT"
assert grep -qx 'pinned-account: rec_acct' <<<"$OUT"

# --- the account the picker opens on ----------------------------------------
# worker-pick owns the choice; llm-limits' current account and .claudeb-state are
# only what is left when it can staff nobody.
STUB="$WORK/stub-bin"
mkdir -p "$STUB"
cat >"$STUB/worker-pick" <<'EOF'
#!/usr/bin/env bash
[ "$*" = "--account claudeb --role chat" ] || { printf 'stub: %s\n' "$*" >&2; exit 2; }
[ -n "${PICK_ANSWER:-}" ] || exit 3
printf '%s\n' "$PICK_ANSWER"
EOF
chmod +x "$STUB/worker-pick"
printf 'beta\n' >"$WORK/claudeb-state"

OUT=$(CLAUDEB_WORKER_PICK="$STUB/worker-pick" python3 - "$SCRIPT" "$WORK/claudeb-state" <<'PY'
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
assert grep -q '? marks a chat waiting' <<<"$OUT"

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

# --- share/chat_ask.py: the chat that stopped on a question to him -----------
# Read backwards from the end, so what must not be mistaken for his answer is everything the
# harness writes under the user's role — a tool result, a system reminder — and everything said
# in a conversation of its own: a subagent's turn. What must not be mistaken for a question is
# everything a REPORT ends on: the same verbs in the past tense, a `?` in code he was handed or
# in a quoted hook line, and an ask a screen above the conclusion.
ASK=$(python3 - "$ROOT/share/chat_ask.py" "$WORK" <<'PY'
import importlib.machinery, importlib.util, json, os, sys

loader = importlib.machinery.SourceFileLoader("chat_ask", sys.argv[1])
spec = importlib.util.spec_from_loader("chat_ask", loader)
ask = importlib.util.module_from_spec(spec)
loader.exec_module(ask)
work = sys.argv[2]


def transcript(name, *entries):
    path = os.path.join(work, name + ".jsonl")
    with open(path, "w", encoding="utf-8") as handle:
        for entry in entries:
            handle.write(json.dumps(entry, ensure_ascii=False) + "\n")
    return path


def said(role, text, **extra):
    content = text if role == "user" else [{"type": "text", "text": text}]
    return dict({"type": role, "message": {"role": role, "content": content}}, **extra)


def tool_result(text):
    return {"type": "user", "message": {"role": "user", "content": [
        {"type": "tool_result", "content": text}]}}


ASKED = "Патчи готовы, дерево чистое. Скажи, коммитить?"
REPORTED = "Патчи в дереве, тесты зелёные."
cases = [
    ("ask", transcript("ask", said("user", "почини гейт"), said("assistant", ASKED))),
    # His word came in: the chat is answered whatever it was asked.
    ("answered", transcript("answered", said("user", "почини гейт"), said("assistant", ASKED),
                            said("user", "ок, го"))),
    # A tool result is the middle of the assistant's own turn, so the question still stands.
    ("under-tool-result", transcript("under-tool-result", said("user", "почини гейт"),
                                     said("assistant", ASKED), tool_result("дай ок"))),
    # ...and its CONTENT is not a message: a file the chat read that asks for an ok says
    # nothing about whether this chat is waiting.
    ("tool-result-only-ask", transcript("tool-result-only-ask", said("user", "почини гейт"),
                                        said("assistant", REPORTED),
                                        tool_result("скажи «го» — жду подтверждения"))),
    # A reminder arrives under his role and would otherwise read as an answer.
    ("under-reminder", transcript("under-reminder", said("user", "почини гейт"),
                                  said("assistant", ASKED),
                                  said("user", "<system-reminder>гейт</system-reminder>"))),
    # A subagent asks its own supervisor, never Egor.
    ("sidechain", transcript("sidechain", said("user", "почини гейт"),
                             said("assistant", REPORTED),
                             said("assistant", "Скажи, продолжать?", isSidechain=True))),
    # A message of tool calls alone has not ended the turn it belongs to.
    ("under-tool-call", transcript("under-tool-call", said("user", "почини гейт"),
                                   said("assistant", ASKED),
                                   {"type": "assistant", "message": {"role": "assistant",
                                    "content": [{"type": "tool_use", "name": "Bash",
                                                 "input": {}}]}})),
    # The stub an API error leaves behind says nothing about who spoke last.
    ("under-synthetic", transcript("under-synthetic", said("user", "почини гейт"),
                                   said("assistant", ASKED),
                                   {"type": "assistant", "message": {
                                       "role": "assistant", "model": "<synthetic>",
                                       "content": [{"type": "text", "text": "API Error"}]}})),
    # A word for his word, with no question mark anywhere near it.
    ("word", transcript("word", said("user", "почини гейт"),
                        said("assistant", "Тесты зелёные.\n\nКоммит нужен твоим словом."))),
    # The ask is what the CLOSING paragraph says: an ask a screen above the end has been
    # answered by everything written after it.
    ("ask-then-report", transcript("ask-then-report", said("user", "почини гейт"),
                                   said("assistant", "Скажи, коммитить?\n\n" + REPORTED))),
    # The verbs of a report are the verbs of a request in the past tense.
    ("report", transcript("report", said("user", "закоммить"),
                          said("assistant", "Закоммитил и запушил (`4e9ae8c`). "
                                            "Действий не требуется."))),
    # A subordinate clause is not an ask: nothing is expected of him now.
    ("later", transcript("later", said("user", "почини гейт"),
                         said("assistant", "Правку можно влить мелким PR, когда скажешь."))),
    # A `?` inside a command he was handed, and one inside a quoted hook line.
    ("code-question", transcript("code-question", said("user", "почини гейт"),
                                 said("assistant", REPORTED + "\n\n```\ngit log -1 --format=%h?\n```"))),
    ("quoted-question", transcript("quoted-question", said("user", "почини гейт"),
                                   said("assistant", REPORTED + "\n\n> Гейт спросил: продолжать?"))),
    # A `?` that ends no sentence is a glob, not a question.
    ("glob", transcript("glob", said("user", "почини гейт"),
                        said("assistant", "Файлы a?.txt на месте, дерево чистое."))),
    # A closing `?` is still one under whatever punctuation trails it: an interrobang, a
    # typographic quote. The listing marks by the mark, not by the character after it.
    ("bang-question", transcript("bang-question", said("user", "почини гейт"),
                                 said("assistant", "Тесты зелёные. Мне продолжать?!"))),
    ("curly-question", transcript("curly-question", said("user", "почини гейт"),
                                  said("assistant", "Тесты зелёные. Он спросил: \u201cпродолжать?\u201d"))),
    # The ask is what a message ENDS on: a chat that merely quoted the word once, a screen
    # above its own conclusion, is not waiting on anybody.
    ("quoted-far-above", transcript("quoted-far-above", said("user", "почини гейт"),
                                    said("assistant", "Скажи. " + "И дальше по делу. " * 200))),
    # A tail window that holds nothing but one huge tool result widens instead of answering.
    ("wide-window", transcript("wide-window", said("user", "почини гейт"),
                               said("assistant", ASKED),
                               tool_result("x" * (400 * 1024)))),
    ("missing", os.path.join(work, "nobody.jsonl")),
]
for label, path in cases:
    print("%s: %s" % (label, ask.awaiting_answer(path)))
PY
) || fail "chat_ask probe failed"

assert grep -qx 'ask: True' <<<"$ASK"
assert grep -qx 'answered: False' <<<"$ASK"
assert grep -qx 'under-tool-result: True' <<<"$ASK"
assert grep -qx 'tool-result-only-ask: False' <<<"$ASK"
assert grep -qx 'under-reminder: True' <<<"$ASK"
assert grep -qx 'sidechain: False' <<<"$ASK"
assert grep -qx 'under-tool-call: True' <<<"$ASK"
assert grep -qx 'under-synthetic: True' <<<"$ASK"
assert grep -qx 'word: True' <<<"$ASK"
assert grep -qx 'ask-then-report: False' <<<"$ASK"
assert grep -qx 'report: False' <<<"$ASK"
assert grep -qx 'later: False' <<<"$ASK"
assert grep -qx 'code-question: False' <<<"$ASK"
assert grep -qx 'quoted-question: False' <<<"$ASK"
assert grep -qx 'glob: False' <<<"$ASK"
assert grep -qx 'bang-question: True' <<<"$ASK"
assert grep -qx 'curly-question: True' <<<"$ASK"
assert grep -qx 'quoted-far-above: False' <<<"$ASK"
assert grep -qx 'wide-window: True' <<<"$ASK"
assert grep -qx 'missing: False' <<<"$ASK"

# --- the ask column is answered once per version of a transcript -------------
# Scrolling past the last row reloads the WHOLE listing a window wider, and this column reads the
# tail of every transcript in it: a month of history paid those seconds again for an answer it
# already had.
CACHE=$(CHATS_ASK_CACHE="$WORK/ask-cache.json" python3 - "$SCRIPT" "$WORK" <<'PY'
import importlib.machinery, importlib.util, json, os, sys

loader = importlib.machinery.SourceFileLoader("chats", sys.argv[1])
spec = importlib.util.spec_from_loader("chats", loader)


def fresh():
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


chats = fresh()
work = sys.argv[2]
path = os.path.join(work, "cached.jsonl")


def rewrite(text):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(json.dumps({"type": "user", "message": {
            "role": "user", "content": "почини гейт"}}, ensure_ascii=False) + "\n")
        handle.write(json.dumps({"type": "assistant", "message": {
            "role": "assistant", "content": [{"type": "text", "text": text}]}},
            ensure_ascii=False) + "\n")


reads = []
tail = chats.awaiting_answer
chats.awaiting_answer = lambda p, size=None: (reads.append(p), tail(p, size))[1]

rewrite("Патчи готовы. Скажи, коммитить?")
print("first:", chats.asking(path), len(reads))
print("again:", chats.asking(path), len(reads))
os.utime(path, (0, 0))
print("touched:", chats.asking(path), len(reads))
rewrite("Патчи в дереве, тесты зелёные.")
print("rewritten:", chats.asking(path), len(reads))
print("missing:", chats.asking(os.path.join(work, "nobody.jsonl")), len(reads))
chats.save_ask_cache()
# A second launch is where the mark costs the most: with nothing on disk it re-reads the tail of
# every transcript the listing names, and the last window names all of them.
later = fresh()
later_reads = []
later_tail = later.awaiting_answer
later.awaiting_answer = lambda p, size=None: (later_reads.append(p), later_tail(p, size))[1]
print("relaunched:", later.asking(path), len(later_reads))
PY
) || fail "ask cache probe failed"

assert grep -qx 'first: True 1' <<<"$CACHE"
assert grep -qx 'again: True 1' <<<"$CACHE"
# The version is the file's own mtime and size: a transcript that moved is read again.
assert grep -qx 'touched: True 2' <<<"$CACHE"
assert grep -qx 'rewritten: False 3' <<<"$CACHE"
# A path that cannot be stat-ed answers without a read at all.
assert grep -qx 'missing: False 3' <<<"$CACHE"
# The answer survives the process that produced it.
assert grep -qx 'relaunched: False 0' <<<"$CACHE"
assert test -s "$WORK/ask-cache.json"

# --- a worker session's launcher comes off the run record --------------------
# The env stamp `worker-run` exports into a worker is one of two sides, and the one a sub-shell, a
# resumed session or a CLI that scrubs its environment loses. The other is the run record on disk:
# `worker-session` beside `launcher`, written while the run is still alive. Read here and by
# `review-bench debt` off this same module, so a row the journal filed under a worker id still
# prices as the chat that asked for it.
RUNS="$WORK/worker-runs"
mkdir -p "$RUNS/claudeb-1-1-aaaa" "$RUNS/claudeb-2-2-bbbb" "$RUNS/claudeb-3-3-cccc" \
  "$RUNS/claudeb-4-4-dddd"
printf 'chat-one\n' >"$RUNS/claudeb-1-1-aaaa/launcher"
printf 'worker-paired\n' >"$RUNS/claudeb-1-1-aaaa/worker-session"
# One worker id two CHATS resumed divides between neither of them.
printf 'chat-one\n' >"$RUNS/claudeb-2-2-bbbb/launcher"
printf 'worker-shared\n' >"$RUNS/claudeb-2-2-bbbb/worker-session"
printf 'chat-two\n' >"$RUNS/claudeb-3-3-cccc/launcher"
printf 'worker-shared\n' >"$RUNS/claudeb-3-3-cccc/worker-session"
# A record naming no launcher maps nothing; the worker session stays the only author there is.
printf 'worker-orphan\n' >"$RUNS/claudeb-4-4-dddd/worker-session"
LAUNCHERS=$(WORKER_RUN_DIR="$RUNS" python3 - "$ROOT/share/chat_names.py" <<'MAP'
import importlib.machinery, importlib.util, sys

loader = importlib.machinery.SourceFileLoader("chat_names", sys.argv[1])
spec = importlib.util.spec_from_loader("chat_names", loader)
chat_names = importlib.util.module_from_spec(spec)
loader.exec_module(chat_names)

mapping = chat_names.worker_session_launchers()
for worker in ("worker-paired", "worker-shared", "worker-orphan"):
    print(f"{worker}: {mapping.get(worker, '-')}")
MAP
) || fail "launcher mapping probe failed"

assert grep -qx 'worker-paired: chat-one' <<<"$LAUNCHERS"
assert grep -qx 'worker-shared: -' <<<"$LAUNCHERS"
assert grep -qx 'worker-orphan: -' <<<"$LAUNCHERS"

echo "PASS: chats ($asserts assertions)"
