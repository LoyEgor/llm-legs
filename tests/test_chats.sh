#!/usr/bin/env bash
# Tests for the parts of bin/chats that are not curses: the row a chat becomes,
# the column widths, the filter, and argument handling.
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
# A gateway chat's track: the statusline stamps CLAUDEGPT_ACCOUNT there, a bare name that
# names an account in the OTHER store.
printf 'v2 1785996700 alona 0 3600 anthropic.ccr.astra reply-1 872000 1785996700 alona\n' \
  > "$TRACKS/cache-ttl-track-gw1"
# Never his real gateway store: the picker reads stamps out of it.
export CLAUDEGPT_HOME="$WORK/claudegpt"
mkdir -p "$CLAUDEGPT_HOME/accounts"

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
claudeb = [("claudeb", "alona"), ("claudeb", "com")]
print("account-warm:", chats.account_for(row, now, claudeb, 1))
print("account-cold:", chats.account_for(row, now + 600, claudeb, 1))
print("account-absent:", chats.account_for(row, now, [("claudeb", "com"), ("claudeb", "beta")], 1))
# A gateway chat: the model id says which store its account is in, so the warm name
# picked up from the track is the GATEWAY `notcom` and never the claudeb profile of
# the same name, and Enter reopens it through claudegpt rather than claudeb.
gateway = dict(row, session="gw1", model="anthropic.ccr.astra")
chats.annotate([gateway])
both = [("claudeb", "alona"), ("gpt", "alona"), ("claudeb", "com")]
print("gateway-model:", chats.columns(gateway, now)[2])
print("gateway-account:", chats.account_for(gateway, now, both, 2))
print("gateway-label:", chats.account_label(("gpt", "notcom")), chats.account_label(("claudeb", "notcom")))
print("gateway-open:", chats.chat_resume.switch_argv(
    "gw1", "notcom", model_id=gateway["model"], gateway=True))
print("claudeb-open:", chats.chat_resume.switch_argv(
    "abc123", "com", model_id=row["model"], gateway=False))
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
assert grep -qx 'gateway-model: Astra' <<<"$OUT"
assert grep -qx 'gateway-account: 1' <<<"$OUT"
assert grep -qx 'gateway-label: gpt:notcom notcom' <<<"$OUT"
assert grep -qx "gateway-open: \['claudegpt', 'p', 'notcom', '--model', 'astra', '--resume', 'gw1'\]" <<<"$OUT"
assert grep -qx "claudeb-open: \['claudeb', 'profile', 'com', '--resume', 'abc123'\]" <<<"$OUT"
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

# The bar carries both stores; only a claudeb name can be what worker-pick, the
# announced account or .claudeb-state answered.
names = [("claudeb", "alpha"), ("claudeb", "beta"), ("claudeb", "gamma"),
         ("gpt", "gamma")]
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
# A gateway account of the same name never answers for a claudeb one.
os.environ["PICK_ANSWER"] = "gamma"
print("pick-not-gateway:", chats.current_profile([("gpt", "gamma"), ("claudeb", "gamma")], None))
print("pick-binary:", chats.worker_pick())
del os.environ["CLAUDEB_WORKER_PICK"]
print("pick-sibling:", chats.worker_pick() == os.path.join(chats.HERE, "worker-pick"))
PY
) || fail "account probe failed"

assert grep -qx 'pick: 2' <<<"$OUT"
assert grep -qx 'pick-not-gateway: 1' <<<"$OUT"
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

python3 - "$SCRIPT" "$WORK" <<'PYMOUSE' || fail "mouse probe failed"
import importlib.machinery, importlib.util, sys
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader("chats", sys.argv[1])
spec = importlib.util.spec_from_loader("chats", loader)
chats = importlib.util.module_from_spec(spec)
loader.exec_module(chats)
c = chats.curses
names = [("claudeb", "alpha"), ("gpt", "beta")]
rows = [dict(session=str(i), cwd=sys.argv[2]) for i in range(10)]


class Screen:
    def __init__(self, events):
        self.events = iter(events)
        self.frames = []

    def getmaxyx(self):
        return 6, 80

    def get_wch(self):
        event = next(self.events)
        if isinstance(event, tuple):
            self.mouse = (0, event[0], event[1], 0, event[2])
            return c.KEY_MOUSE
        return event


def play(events, initial=None, windows=(7,)):
    screen = Screen(events)
    def draw(_, visible, view, accounts, profile, *rest):
        screen.frames.append((view["cursor"], view["top"], profile))
    with patch.multiple(c, curs_set=lambda _: None, start_color=lambda: None,
                        use_default_colors=lambda: None, mouseinterval=lambda _: None), \
            patch.object(c, "mousemask") as mask, \
            patch.object(c, "getmouse", side_effect=lambda: screen.mouse), \
            patch.object(chats, "draw", side_effect=draw), \
            patch.object(chats, "account_for", return_value=0), \
            patch.object(chats, "load_chats", return_value=rows) as load, \
            patch.object(chats, "annotate", side_effect=lambda rows: rows):
        result = chats.run(screen, rows if initial is None else initial, names, {}, 0, 0, windows)
        mask.assert_called_once_with(c.ALL_MOUSE_EVENTS | c.REPORT_MOUSE_POSITION)
        return result, screen.frames, load.call_count


press, release = c.BUTTON1_PRESSED, c.BUTTON1_RELEASED
result, frames, _ = play([(0, 2, press), (0, 2, release), (0, 2, press)])
assert result[1] == rows[1] and len(frames) == 3
assert play([(0, 3, c.BUTTON1_DOUBLE_CLICKED)])[0][1] == rows[2]
assert play([(0, 1, c.BUTTON1_CLICKED)])[0][1] == rows[0]
x = chats.width(chats.account_tail(names, {}, 0)[0][0])
assert play([(x, 5, press), "\n"])[0][0] == names[1]
# Wheel-down exists only where ncurses encodes five buttons; where it does not, the bit that
# spells it there is this build's BUTTON4_DOUBLE_CLICKED, and scrolling on it would answer a
# doubled wheel-UP by walking the list down.
down = getattr(c, "BUTTON5_PRESSED", 0)
if down:
    assert play([(0, 1, down), "\n"])[0][1] == rows[3]
    assert play([(0, 1, down), (0, 1, c.BUTTON4_PRESSED), "\n"])[0][1] == rows[0]
    assert play([(0, 1, down), "\n"], rows[:2], (7, 30))[2] == 1
assert play([(0, 1, c.BUTTON4_DOUBLE_CLICKED), "\n"])[0][1] == rows[0]
assert play([c.KEY_NPAGE, (0, 2, press), "\n"])[0][1] == rows[2]
assert play([(0, 0, press), (79, 5, press), "\n"])[0][0] == names[0]
assert play([c.KEY_RIGHT, "\n"])[0][0] == names[1]
assert play(["z", "\x1b", "\n"])[0][1] == rows[0]
print("PASS: chats mouse smoke (11 scenarios)")
PYMOUSE

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
