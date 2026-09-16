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
# A track that stopped before this row's reply: the chat spoke, the statusline has not stamped yet.
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
mkdir -p "$CLAUDEGPT_HOME/accounts" "$CLAUDEGPT_HOME/sessions"
# A Claude chat once reopened through claudegpt keeps that launch's stamp for good.
printf 'v1 borodatch astra\n' > "$CLAUDEGPT_HOME/sessions/6ebc3bbe-66ec-498e-9f3d-736e61eed0ba"

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
# Only a live cache moves the account: the stamp of an old claudegpt reopen does not.
stamped = dict(row, session="6ebc3bbe-66ec-498e-9f3d-736e61eed0ba", model="claude-fable-5-1")
chats.annotate([stamped])
print("stamp-read:", chats.chat_resume.read_stamp(stamped["session"])["account"])
print("stamp-ignored:", chats.account_for(stamped, now, [("claudeb", "alona"), ("gpt", "borodatch")], 0))
print("gateway-open:", chats.chat_resume.switch_argv(
    "gw1", "notcom", model_id=gateway["model"], gateway=True))
print("claudeb-open:", chats.chat_resume.switch_argv(
    "abc123", "com", model_id=row["model"], gateway=False))
# A row already landed on is asked again while ←→ has not moved the account, so
# the cache expiring under a resting cursor hands it back; an override stands.
print("refollow:", chats.refollow(row, "abc123", 0, 0), chats.refollow(row, "abc123", 1, 0),
      chats.refollow(row, "other", 1, 0))
# The statusline stamps the newest reply of any kind and this listing the newest one that SPOKE,
# so the two name different replies whenever a chat ends on a tool call or is mid-turn. The
# lifetime counts from the track's own stamp either way: a track AHEAD of the row extends it, one
# BEHIND the row (the chat spoke, the statusline has not stamped yet) still names the account
# holding the cache, and only that stamp's expiry cools it.
ahead = dict(row, session="ahead"); chats.annotate([ahead])
behind = dict(row, session="behind"); chats.annotate([behind])
print("ahead:", chats.columns(ahead, now)[3], chats.warm_name(ahead, now + 330))
print("behind:", chats.columns(behind, now)[3], chats.warm_name(behind, now + 300))
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
assert grep -qx 'stamp-read: borodatch' <<<"$OUT"
assert grep -qx 'stamp-ignored: 0' <<<"$OUT"
assert grep -qx "gateway-open: \['claudegpt', 'p', 'notcom', '--model', 'astra', '--resume', 'gw1'\]" <<<"$OUT"
assert grep -qx "claudeb-open: \['claudeb', 'profile', 'com', '--resume', 'abc123'\]" <<<"$OUT"
assert grep -qx 'refollow: True False True' <<<"$OUT"
# The minute past this row's own expiry is still warm on the track's later stamp.
assert grep -qx 'ahead: alona alona' <<<"$OUT"
assert grep -qx 'behind: alona None' <<<"$OUT"
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
# worker-pick owns the choice; .claudeb-state is only what is left when it can staff nobody.
STUB="$WORK/stub-bin"
mkdir -p "$STUB"
cat >"$STUB/worker-pick" <<'EOF'
#!/usr/bin/env bash
[ "$*" = "--list --role chat" ] || { printf 'stub: %s\n' "$*" >&2; exit 2; }
[ -n "${PICK_ANSWER:-}" ] || exit 3
printf 'claudeb\t%s\t10\tok\nNEXT\tclaudeb\t%s\nNEXT\tcodex\t-\n' "$PICK_ANSWER" "$PICK_ANSWER"
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


def chosen():
    return chats.ranking()[3]


# The bar carries both stores; only a claudeb name can be what worker-pick or
# .claudeb-state answered.
names = [("claudeb", "alpha"), ("claudeb", "beta"), ("claudeb", "gamma"),
         ("gpt", "gamma")]
os.environ["PICK_ANSWER"] = "gamma"
print("pick:", chats.current_profile(names, chosen()))
os.environ["PICK_ANSWER"] = "ghost"
print("pick-unknown:", chats.current_profile(names, chosen()))
del os.environ["PICK_ANSWER"]
print("none-state:", chats.current_profile(names, chosen()))
chats.STATE = sys.argv[2] + "-absent"
print("none-nothing:", chats.current_profile(names, chosen()))
# The selector is the one beside this script, so a checkout answers with its own
# halves; the override is what a test — and an install that split them — has.
# A gateway account of the same name never answers for a claudeb one.
os.environ["PICK_ANSWER"] = "gamma"
print("pick-not-gateway:", chats.current_profile([("gpt", "gamma"), ("claudeb", "gamma")],
                                                  chosen()))
print("pick-binary:", chats.worker_pick())
del os.environ["CLAUDEB_WORKER_PICK"]
print("pick-sibling:", chats.worker_pick() == os.path.join(chats.HERE, "worker-pick"))
PY
) || fail "account probe failed"

assert grep -qx 'pick: 2' <<<"$OUT"
assert grep -qx 'pick-not-gateway: 1' <<<"$OUT"
# An answer no profile here carries is no answer at all.
assert grep -qx 'pick-unknown: 1' <<<"$OUT"
assert grep -qx 'none-state: 1' <<<"$OUT"
assert grep -qx "pick-binary: $STUB/worker-pick" <<<"$OUT"
assert grep -qx 'pick-sibling: True' <<<"$OUT"
assert grep -qx 'none-nothing: 0' <<<"$OUT"

# --- a gateway reply names no cache bucket, so the listing gives it a nominal one ---
REPLIES="$WORK/replies.jsonl"
cat >"$REPLIES" <<'EOF'
{"type":"user","timestamp":"2026-09-14T10:00:00.000Z","message":{"role":"user","content":"go"}}
{"type":"assistant","timestamp":"2026-09-14T10:00:05.000Z","uuid":"gw-reply","message":{"role":"assistant","model":"anthropic.ccr.astra","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":900,"cache_read_input_tokens":40000}}}
EOF
OUT=$(python3 - "$ROOT/bin/chat-find" "$REPLIES" <<'PY'
import importlib.machinery, importlib.util, os, sys

loader = importlib.machinery.SourceFileLoader("chat_find", sys.argv[1])
spec = importlib.util.spec_from_loader("chat_find", loader)
chat_find = importlib.util.module_from_spec(spec)
loader.exec_module(chat_find)

size = os.path.getsize(sys.argv[2])
print("gateway-ttl:", chat_find.tail_speech(sys.argv[2], size, size)["ttl"])
print("claude-bare-ttl:", chat_find.reply_ttl({"model": "claude-fable-5-1", "usage": {}}))
print("gateway-bucket-ttl:", chat_find.reply_ttl({"model": "anthropic.ccr.sol", "usage": {
    "cache_creation": {"ephemeral_5m_input_tokens": 10}}}))
PY
) || fail "gateway ttl probe failed"
assert grep -qx 'gateway-ttl: 3600' <<<"$OUT"
assert grep -qx 'claude-bare-ttl: 0' <<<"$OUT"
assert grep -qx 'gateway-bucket-ttl: 300' <<<"$OUT"

# --- the bar is worker-pick's ranking, per line -----------------------------
# Freest on the left, in the order `worker-pick --list` prints each vendor and never one the
# picker works out itself; a gateway account is ranked by the codex row of the same name.
mkdir -p "$WORK/profiles/alpha" "$WORK/profiles/beta" "$WORK/profiles/zeta" \
  "$WORK/profiles/omega" "$STUB/list"
cat >"$STUB/list/worker-pick" <<'EOF'
#!/usr/bin/env bash
[ "$*" = "--list --role chat" ] || exit 2
printf '%s\t%s\t%s\t%s\n' \
  claudeb omega 5 ok claudeb beta - login claudeb alpha 100 walled claudeb ghost 1 ok \
  codex delta 30 ok codex gamma 0 login codex epsilon 60 ok gemini alpha 3 ok
printf 'NEXT\t%s\t%s\n' claudeb omega codex delta gemini alpha grok -
EOF
chmod +x "$STUB/list/worker-pick"
OUT=$(CLAUDEB_WORKER_PICK="$STUB/list/worker-pick" python3 - "$SCRIPT" "$WORK/profiles" <<'PY'
import importlib.machinery, importlib.util, sys
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader("chats", sys.argv[1])
spec = importlib.util.spec_from_loader("chats", loader)
chats = importlib.util.module_from_spec(spec)
loader.exec_module(chats)
chats.PROFILES = sys.argv[2]

order, used, hidden, chosen = chats.ranking()
with patch.object(chats.chat_resume, "gateway_accounts",
                  return_value=["gamma", "epsilon", "zulu", "delta"]):
    names = chats.profiles()
bar = chats.arrange(names, order, hidden)
print("offered:", " ".join(chats.account_label(entry) for entry in bar))
lines = chats.account_lines(bar, used, 0)
print("line1:", "|".join(label.strip() for _, label, _ in lines[0]))
print("line2:", "|".join(label.strip() for _, label, _ in lines[1]))
print("chosen:", chosen, chats.current_profile(bar, chosen))
PY
) || fail "ranking probe failed"
# zeta and zulu have no row in the listing at all: no data is not a logout, so they follow the
# ranked ones unlabelled; ghost has no profile here, and gemini is no line of this bar.
assert grep -qx 'offered: omega alpha zeta gpt:delta gpt:epsilon gpt:zulu' <<<"$OUT"
assert grep -qx 'line1: omega 5%|alpha 100%!|zeta' <<<"$OUT"
assert grep -qx 'line2: gpt:delta 30%|gpt:epsilon 60%|gpt:zulu' <<<"$OUT"
assert grep -qx 'chosen: omega 0' <<<"$OUT"
assert test -z "$(grep -n 'llm-limits' "$SCRIPT")"

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
import importlib.machinery, importlib.util, json, os, sys, time
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader("chats", sys.argv[1])
spec = importlib.util.spec_from_loader("chats", loader)
chats = importlib.util.module_from_spec(spec)
loader.exec_module(chats)
c = chats.curses
names = [("claudeb", "alpha"), ("gpt", "beta")]
rows = [dict(session=str(i), cwd=sys.argv[2]) for i in range(10)]
TICK = object()


class Screen:
    def __init__(self, events):
        self.frames = []
        self.events = iter(events(self) if callable(events) else events)
        self.cells = {}

    def getmaxyx(self):
        return 7, 80

    def timeout(self, delay):
        self.delay = delay

    def get_wch(self):
        event = next(self.events)
        if event is TICK:
            time.sleep(0.02)
            raise c.error("no input")
        if isinstance(event, tuple):
            self.mouse = (0, event[0], event[1], 0, event[2])
            return c.KEY_MOUSE
        return event

    def erase(self):
        self.cells = {}

    def addstr(self, y, x, text, attribute=0):
        line = self.cells.get(y, "").ljust(x)
        self.cells[y] = line[:x] + text + line[x + len(text):]

    def refresh(self):
        pass


def play(events, initial=None, windows=(7,), accounts=names, load=True):
    screen = Screen(events)
    def draw(_, visible, view, accounts, profile, *rest):
        screen.frames.append((view["cursor"], view["top"], profile, len(visible), view["window"]))
    fetch = patch.object(chats, "fetch_chats", return_value=rows) if load \
        else patch.object(chats, "HERE", sys.argv[2])
    with patch.multiple(c, curs_set=lambda _: None, start_color=lambda: None,
                        use_default_colors=lambda: None, mouseinterval=lambda _: None), \
            patch.object(c, "mousemask") as mask, \
            patch.object(c, "getmouse", side_effect=lambda: screen.mouse), \
            patch.object(chats, "draw", side_effect=draw), \
            patch.object(chats, "account_for", return_value=0), \
            fetch as loads, \
            patch.object(chats, "annotate", side_effect=lambda rows: rows):
        result = chats.run(screen, rows if initial is None else initial, accounts, {}, 0, 0, windows)
        mask.assert_called_once_with(c.ALL_MOUSE_EVENTS | c.REPORT_MOUSE_POSITION)
        assert screen.delay == 100
        return result, screen.frames, getattr(loads, "call_count", None)


press, release = c.BUTTON1_PRESSED, c.BUTTON1_RELEASED
result, frames, _ = play([(0, 2, press), (0, 2, release), (0, 2, press)])
assert result[1] == rows[1] and len(frames) == 3
assert play([(0, 3, c.BUTTON1_DOUBLE_CLICKED)])[0][1] == rows[2]
assert play([(0, 1, c.BUTTON1_CLICKED)])[0][1] == rows[0]

# Seven rows: header, four body rows, the claudeb line at 5 and the gateway line at 6.
screen = Screen([])
assert chats.body_rows(screen) == 4
wide = [("claudeb", "alpha"), ("claudeb", "gamma"), ("gpt", "beta"), ("gpt", "delta")]
chats.paint(screen, [dict(row, at=0) for row in rows], {"cursor": 0, "top": 0, "now": 0, "window": "w"},
            wide, 2, "", {}, "")
assert [screen.cells[y][:2] for y in range(1, 5)] == ["▸ "] + ["  "] * 3, screen.cells
assert screen.cells[5].split() == ["alpha", "gamma"], screen.cells[5]
assert screen.cells[6].split()[:2] == ["gpt:beta", "gpt:delta"] and "↵ open" in screen.cells[6]
# A click lands on the label under it on either line; the body ends above the bar.
assert play([(len(" alpha "), 5, press), "\n"], accounts=wide)[0][0] == wide[1]
assert play([(len(" alpha "), 6, press), "\n"], accounts=wide)[0][0] == wide[2]
assert play([(len(" gpt:beta "), 6, press), "\n"], accounts=wide)[0][0] == wide[3]
assert play([(0, 5, press), (0, 6, press), "\n"], accounts=wide)[0][0] == wide[2]
assert play([(0, 4, press), (0, 4, press)])[0][1] == rows[3]
# ←→ is one ring over both lines; shift+↑↓ keeps the place within the line, clamped.
three = [("claudeb", "a"), ("claudeb", "b"), ("claudeb", "c"), ("gpt", "x"), ("gpt", "y")]
assert [chats.line_jump(three, p, 1) for p in range(5)] == [3, 4, 4, 3, 4]
assert [chats.line_jump(three, p, -1) for p in range(5)] == [0, 1, 2, 0, 1]
assert chats.line_jump([("claudeb", "a"), ("claudeb", "b")], 1, 1) == 1
assert play([c.KEY_SF, "\n"])[0][0] == names[1]
assert play([c.KEY_SF, c.KEY_SR, "\n"])[0][0] == names[0]
assert play([c.KEY_LEFT, c.KEY_RIGHT, c.KEY_RIGHT, "\n"])[0][0] == names[1]
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

# A filter widens the history in the background: keys keep answering, the header says so, and
# the wider listing replaces the narrower one when it lands — painted once, not on every tick.
calls = os.path.join(sys.argv[2], "chat-find.calls")
finder = os.path.join(sys.argv[2], "chat-find")
with open(finder, "w") as handle:
    handle.write("#!/usr/bin/env python3\nimport json, sys, time\n"
                 "open(%r, 'a').write(' '.join(sys.argv[1:]) + '\\n')\ntime.sleep(0.3)\n"
                 "print(json.dumps([{'session': 'q-new-%%d' %% i, 'cwd': '/'} for i in range(5)]))\n"
                 % calls)
os.chmod(finder, 0o755)
narrow = [dict(session="q-%d" % i, cwd="/") for i in range(3)] + [dict(session="z", cwd="/")]


def typed(*keys):
    def events(screen):
        yield from keys
        for _ in range(500):
            if len(screen.frames) >= 3:
                break
            yield TICK
        yield from [TICK] * 5 + ["\x04"]
    return events


result, frames, _ = play(typed("q"), narrow, (7, 30), load=False)
assert result is None and len(frames) == 3, frames
assert frames[0][3:] == (4, "last 7d · ↓ for more"), frames[0]
assert frames[1][3] == 3 and frames[1][4].endswith("· searching…"), frames[1]
assert frames[2][3:] == (5, "last 30d"), frames[2]
assert open(calls).read() == "--recent --json --days 30\n"
# Scrolling past the end while that load is in flight waits for it instead of loading twice.
os.unlink(calls)
result, frames, _ = play(typed("q", c.KEY_END, c.KEY_DOWN), narrow, (7, 30), load=False)
assert frames[-1][3:] == (5, "last 30d") and frames[-1][0] == 3, frames
assert open(calls).read() == "--recent --json --days 30\n"
print("PASS: chats mouse smoke (32 checks)")
PYMOUSE

# --- the screen is up before any subprocess, and both land together ---------
# The picker used to run its subprocesses one after another before curses opened, so Egor
# waited seconds on a blank terminal. Each stub here sleeps a second: a first paint that
# waits for either of them, or loads run in sequence, shows up as time on the clock rather
# than as a wrong-looking screen.
FAST="$WORK/fast"
mkdir -p "$FAST/bin" "$FAST/profiles/alpha" "$FAST/profiles/beta" "$FAST/profiles/gamma"
cat >"$FAST/bin/chat-find" <<'EOF'
#!/usr/bin/env python3
import json, time
time.sleep(1)
print(json.dumps([{"session": "s%d" % i, "cwd": "/", "at": 0, "ctx": 1000} for i in range(3)]))
EOF
cat >"$FAST/bin/worker-pick" <<'EOF'
#!/usr/bin/env bash
sleep 1
[ "$*" = "--list --role chat" ] || exit 2
printf '%s\t%s\t%s\t%s\n' claudeb gamma 10 ok claudeb alpha 40 ok claudeb beta - login
printf 'NEXT\t%s\t%s\n' claudeb gamma codex - gemini - grok -
EOF
chmod +x "$FAST/bin/chat-find" "$FAST/bin/worker-pick"
printf 'beta\n' >"$FAST/claudeb-state"

cat >"$FAST/probe.py" <<'PYFAST'
"""Run the picker headless over the sleeping stubs: argv is the script, the fixture
root, the account the bar must settle on, and optionally a key pressed before anything
has landed."""
import importlib.machinery, importlib.util, os, sys, time
from unittest.mock import patch

START = time.monotonic()
loader = importlib.machinery.SourceFileLoader("chats", sys.argv[1])
spec = importlib.util.spec_from_loader("chats", loader)
chats = importlib.util.module_from_spec(spec)
loader.exec_module(chats)
c = chats.curses
chats.PROFILES = os.path.join(sys.argv[2], "profiles")
chats.STATE = os.path.join(sys.argv[2], "claudeb-state")
WANT = sys.argv[3]
KEYS = [c.KEY_LEFT] if sys.argv[4:] == ["left"] else []
AFTER = [c.KEY_RIGHT, c.KEY_SF, "\n"] if sys.argv[4:] == ["after"] else []

frames = []


def done():
    last = frames[-1] if frames else None
    return bool(last and last["rows"] and last["used"] and last["account"] == WANT)


class Screen:
    def getmaxyx(self):
        return 10, 80

    def timeout(self, delay):
        self.delay = delay

    def get_wch(self):
        if KEYS:
            return KEYS.pop(0)
        if done():
            return AFTER.pop(0) if AFTER else "\x04"
        if time.monotonic() - START > 10:
            raise AssertionError("nothing landed: %r" % frames)
        time.sleep(0.01)
        raise c.error("no input")

    def erase(self):
        pass

    def addstr(self, *rest):
        pass

    def refresh(self):
        pass


def record(_, visible, view, accounts, profile, needle, used, note):
    frames.append({"at": time.monotonic() - START, "rows": len(visible), "used": len(used),
                   "accounts": " ".join(chats.account_label(e) for e in accounts),
                   "account": "-" if profile is None else chats.account_label(accounts[profile]),
                   "window": view["window"], "note": note})


with patch.multiple(c, curs_set=lambda _: None, start_color=lambda: None,
                    use_default_colors=lambda: None, mouseinterval=lambda _: None,
                    mousemask=lambda _: None), \
        patch.object(chats, "draw", side_effect=record), \
        patch.object(chats.chat_resume, "gateway_accounts", return_value=["delta"]), \
        patch.object(chats, "HERE", os.path.join(sys.argv[2], "bin")):
    result = chats.run(Screen(), None, None, None, None, 0, chats.WINDOWS)

first, full = frames[0], frames[-1]
print("quit:", result)
print("timing: first paint %.3fs, full data %.3fs" % (first["at"], full["at"]))
print("first-paint-fast:", first["at"] < 0.5)
# Two one-second stubs in parallel land inside two seconds; run one after another they
# could not.
print("loads-concurrent:", 1.0 <= full["at"] < 2.0)
print("first-window:", first["window"])
print("first-empty:", first["rows"], first["used"])
print("first-accounts:", first["accounts"])
print("first-account:", first["account"])
print("full-window:", full["window"])
print("full-rows:", full["rows"])
print("full-accounts:", full["accounts"])
print("full-account:", full["account"])
print("full-note:", full["note"])
# The 100ms poll paints on a key or a landed load and on nothing else; an idle picker
# redrawing every tick would leave dozens of frames behind in this second.
print("idle-quiet:", len(frames) <= 6)
PYFAST

OUT=$(PATH="$FAST/bin:$PATH" python3 "$FAST/probe.py" "$SCRIPT" "$FAST" gamma) \
  || fail "startup probe failed"

echo "$OUT" | grep '^timing:'
assert grep -qx 'quit: None' <<<"$OUT"
assert grep -qx 'first-paint-fast: True' <<<"$OUT"
assert grep -qx 'loads-concurrent: True' <<<"$OUT"
# Before anything lands: the header says so, the body is empty, the bar carries every
# account the two stores know without a subprocess — no percentage, nothing hidden — and
# it opens on the last profile launched.
assert grep -qx 'first-window: loading…' <<<"$OUT"
assert grep -qx 'first-empty: 0 0' <<<"$OUT"
assert grep -qx 'first-accounts: alpha beta gamma gpt:delta' <<<"$OUT"
assert grep -qx 'first-account: beta' <<<"$OUT"
# Once they land: rows, the window they came from, the bar in worker-pick's order with the
# logged-out account gone, and the account it named.
assert grep -qx 'full-window: last 7d · ↓ for more' <<<"$OUT"
assert grep -qx 'full-rows: 3' <<<"$OUT"
assert grep -qx 'full-accounts: gamma alpha gpt:delta' <<<"$OUT"
assert grep -qx 'full-account: gamma' <<<"$OUT"
assert grep -qx 'idle-quiet: True' <<<"$OUT"

# ←→ works while the screen is still empty, and the account landing a second later does
# not take that choice back.
OUT=$(PATH="$FAST/bin:$PATH" python3 "$FAST/probe.py" "$SCRIPT" "$FAST" alpha left) \
  || fail "early-key probe failed"
assert grep -qx 'first-account: beta' <<<"$OUT"
assert grep -qx 'full-account: alpha' <<<"$OUT"
assert grep -qx 'full-rows: 3' <<<"$OUT"

# Every account logged out: the bar is empty rather than the unfiltered list, no account is the
# default, and ←→, Shift+↓ and ↵ on the empty bar change nothing and open nothing.
mkdir -p "$FAST/login"
cat >"$FAST/login/worker-pick" <<'EOF'
#!/usr/bin/env bash
[ "$*" = "--list --role chat" ] || exit 2
printf '%s\t%s\t%s\t%s\n' claudeb gamma 10 login claudeb alpha 40 login claudeb beta - login \
  codex delta 20 login
printf 'NEXT\t%s\t%s\n' claudeb - codex - gemini - grok -
EOF
chmod +x "$FAST/login/worker-pick"
OUT=$(PATH="$FAST/bin:$PATH" CLAUDEB_WORKER_PICK="$FAST/login/worker-pick" \
  python3 "$FAST/probe.py" "$SCRIPT" "$FAST" - after) || fail "all-login probe failed"
assert grep -qx 'quit: None' <<<"$OUT"
assert grep -qx 'full-rows: 3' <<<"$OUT"
assert grep -qx 'full-accounts: ' <<<"$OUT"
assert grep -qx 'full-account: -' <<<"$OUT"
assert grep -qx 'full-note: no logged-in account to open it under' <<<"$OUT"

# --- a worker session's launcher comes off the run record --------------------
# The env stamp `worker-run` exports into a worker is one of two sides, and the one a sub-shell, a
# resumed session or a CLI that scrubs its environment loses. The other is the run record on disk:
# `worker-session` beside `launcher`, written while the run is still alive. Read here and by
# `review-bench debt` off this same module, so a row the journal filed under a worker id still
# prices as the chat that asked for it.
RUNS="$WORK/worker-runs"
mkdir -p "$RUNS/claudeb-1-1-aaaa" "$RUNS/claudeb-2-2-bbbb" "$RUNS/claudeb-3-3-cccc" \
  "$RUNS/claudeb-4-4-dddd" "$RUNS/claudeb-5-5-eeee"
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

echo "== non-interactive open command"
OPEN_HOME="$WORK/open-home"
OPEN_SID=12345678-1234-1234-1234-123456789abc
NO_CWD_SID=22345678-1234-1234-1234-123456789abc
GONE_CWD_SID=32345678-1234-1234-1234-123456789abc
UNKNOWN_GATEWAY_SID=42345678-1234-1234-1234-123456789abc
mkdir -p "$OPEN_HOME/.claude/projects/project" "$OPEN_HOME/.claude-profiles/picked" \
  "$OPEN_HOME/.claude-profiles/last" "$OPEN_HOME/.claude-profiles/.claudeb" "$WORK/open-bin"
printf 'last\n' > "$OPEN_HOME/.claude-profiles/.claudeb/.claudeb-state"
python3 - "$OPEN_HOME/.claude/projects/project" "$OPEN_SID" "$NO_CWD_SID" \
  "$GONE_CWD_SID" "$UNKNOWN_GATEWAY_SID" "$WORK" <<'PYOPEN'
import datetime, json, sys
root, open_sid, no_cwd_sid, gone_cwd_sid, gateway_sid, cwd = sys.argv[1:]
def write(session, directory, model="claude-sonnet-4-6"):
    row = {"type": "assistant", "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
           "cwd": directory, "uuid": "reply-" + session,
           "message": {"role": "assistant", "model": model,
                       "content": [{"type": "text", "text": "A fixture reply"}],
                       "usage": {"input_tokens": 10, "cache_creation_input_tokens": 10,
                                 "cache_creation": {"ephemeral_1h_input_tokens": 10}}}}
    with open(root + "/" + session + ".jsonl", "w") as handle:
        handle.write(json.dumps(row) + "\n")
write(open_sid, cwd)
write(no_cwd_sid, None)
write(gone_cwd_sid, cwd + "/missing")
write(gateway_sid, cwd, "anthropic.ccr.astra")
PYOPEN
printf '%s\n' "$OPEN_SID" >"$RUNS/claudeb-5-5-eeee/launcher"
printf 'worker-open\n' >"$RUNS/claudeb-5-5-eeee/worker-session"
cat > "$WORK/open-bin/worker-pick" <<'PICK'
#!/bin/sh
printf 'NEXT\tclaudeb\tpicked\n'
PICK
chmod +x "$WORK/open-bin/worker-pick"
open_command_test() {
  HOME="$OPEN_HOME" PATH="$WORK/open-bin:$PATH" CLAUDEB_DIR="$OPEN_HOME/.claude-profiles/.claudeb" \
    CHAT_FIND_ROOT="$OPEN_HOME/.claude/projects" \
    WORKER_RUN_DIR="$RUNS" \
    CLAUDEB_WORKER_PICK=worker-pick CHAT_FIND_CACHE="$WORK/open-cache.json" \
    STATUSLINE_CACHE_DIR="$WORK/open-tracks" "$SCRIPT" --open-command "$@"
}
OPEN=$(open_command_test "$OPEN_SID")
assert [ "$?" -eq 0 ]
assert [ "$(printf '%s\n' "$OPEN" | wc -l | tr -d ' ')" = 2 ]
assert [ "$(printf '%s\n' "$OPEN" | tail -1)" = 'account=picked source=pick' ]
assert test "${OPEN#*"$OPEN_SID"}" != "$OPEN"
assert test "${OPEN#*"$ROOT/bin/claudeb"}" != "$OPEN"
OPEN=$(open_command_test worker-open)
assert test "${OPEN#*"--resume $OPEN_SID"}" != "$OPEN"
case "$OPEN" in *worker-open*) fail "worker session was not folded in open command" ;; esac
open_command_test "$NO_CWD_SID" > "$WORK/open-out" 2> "$WORK/open-error"
assert [ "$?" -eq 1 ]
assert grep -qx 'chats: no such directory: ?' "$WORK/open-error"
open_command_test "$GONE_CWD_SID" > "$WORK/open-out" 2> "$WORK/open-error"
assert [ "$?" -eq 1 ]
assert grep -qx "chats: no such directory: $WORK/missing" "$WORK/open-error"
open_command_test "$UNKNOWN_GATEWAY_SID" > "$WORK/open-out" 2> "$WORK/open-error"
assert [ "$?" -eq 1 ]
assert grep -qx 'chats: gateway account unknown for this chat' "$WORK/open-error"
cat > "$WORK/open-bin/worker-pick" <<'PICK'
#!/bin/sh
exec sleep 2
PICK
OPEN=$(open_command_test "$OPEN_SID" --timeout 0.05)
assert [ "$?" -eq 0 ]
assert [ "$(printf '%s\n' "$OPEN" | tail -1)" = 'account=last source=fallback' ]
mkdir -p "$WORK/open-tracks"
printf 'v2 %s picked\n' "$(date +%s)" > "$WORK/open-tracks/cache-ttl-track-$OPEN_SID"
OPEN=$(open_command_test "$OPEN_SID" --timeout 0.05)
assert [ "$(printf '%s\n' "$OPEN" | tail -1)" = 'account=picked source=cache' ]
printf 'v1 gateway-test astra\n' > "$CLAUDEGPT_HOME/sessions/$OPEN_SID"
OPEN=$(open_command_test "$OPEN_SID" --timeout 0.05)
assert test "${OPEN#*"$ROOT/bin/claudegpt"}" != "$OPEN"
assert [ "$(printf '%s\n' "$OPEN" | tail -1)" = 'account=gateway-test source=cache' ]
open_command_test unknown > "$WORK/open-out" 2> "$WORK/open-error"
assert [ "$?" -eq 1 ]
assert [ ! -s "$WORK/open-out" ]
assert [ "$(wc -l < "$WORK/open-error" | tr -d ' ')" = 1 ]

echo "PASS: chats ($asserts assertions)"
