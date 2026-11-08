#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# share/pages/app.py (the chats app on bin/page) against share/pages/CONTRACT.md "App": a temp PAGES_DIR, a
# fixture session registry, a stub `hs` and chat-find, port 0. Never the real Terminal, menubar or ~/Pages.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(cd -P "$(mktemp -d)" && pwd)"
RT="$(mktemp -d /tmp/pa-XXXX)"  # the stub daemon's control socket: a unix socket path is capped at 104 bytes
trap 'kill $(jobs -p) 2>/dev/null; [ -n "${chatpid:-}" ] && kill "$chatpid" 2>/dev/null; rm -rf "$WORK" "$RT"' EXIT
asserts=0
PAGE="$ROOT/bin/page"
like() { [[ $1 == $2 ]]; }
mkdir -p "$WORK/bin" "$WORK/sessions" "$WORK/tracks" "$WORK/proj"
sid=11111111-2222-3333-4444-555555555555
past=eeeeeeee-2222-3333-4444-555555555555
wsid=99999999-2222-3333-4444-555555555555

# A live "chat": a process on a pty (script(1) gives it a tty) with its account in its environment; a worker: the
# same with no tty. Python, not sleep: `ps -E` shows no environment of an Apple platform binary. The chat starts
# what it runs on cue (a `spawn` file): a server listening on a port with a child of its own, and a hook's helper.
PY=$(python3 -c 'import sys; print(sys.executable)')
mkdir -p "$WORK/.claude/hooks"
printf 'sleep 20\n' >"$WORK/.claude/hooks/keep.sh"
cat >"$WORK/kid.py" <<'PYKID'
import socket, subprocess, sys, time
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen()
subprocess.Popen(["sleep", "300"])
open(sys.argv[1] + "/port", "w").write(str(s.getsockname()[1]))
time.sleep(300)
PYKID
cat >"$WORK/chat.py" <<'PYCHAT'
import os, signal, subprocess, sys, time
signal.signal(signal.SIGCHLD, signal.SIG_IGN)  # reaps what ends, as Claude Code does
w = sys.argv[1]
for _ in range(3000):
    if os.path.exists(w + "/spawn"):
        os.remove(w + "/spawn")
        subprocess.Popen([sys.executable, "-c", open(w + "/kid.py").read(), w])
        subprocess.Popen(["/bin/bash", w + "/.claude/hooks/keep.sh"])
    time.sleep(0.1)
PYCHAT
env -u CLAUDEGPT_ACCOUNT CLAUDE_LIMITS_ACCOUNT=fixacct script -q /dev/null "$PY" "$WORK/chat.py" "$WORK" </dev/null >/dev/null 2>&1 &
scriptpid=$!
for _ in $(seq 50); do
  chatpid=$(pgrep -P "$scriptpid" | head -1)
  [ -n "$chatpid" ] && break
  sleep 0.1
done
[ -n "$chatpid" ] || fail "no pty child under script(1)"
env -u CLAUDEGPT_ACCOUNT -u CLAUDE_LIMITS_ACCOUNT CLAUDE_CONFIG_DIR="$HOME/.claude-profiles/wacct" "$PY" -c 'import time; time.sleep(300)' </dev/null &
workerpid=$!
lstart() { LC_ALL=C TZ=UTC ps -o lstart= -p "$1" | xargs; }
printf '{"pid": %s, "sessionId": "%s", "cwd": "/x/proj", "procStart": "%s", "kind": "interactive", "entrypoint": "cli", "status": "idle", "name": "derived"}' \
  "$chatpid" "$sid" "$(lstart "$chatpid")" >"$WORK/sessions/$chatpid.json"
printf '{"pid": %s, "sessionId": "%s", "cwd": "/x/w", "procStart": "%s", "kind": "interactive", "entrypoint": "sdk-cli", "status": "busy"}' \
  "$workerpid" "$wsid" "$(lstart "$workerpid")" >"$WORK/sessions/$workerpid.json"
# A record whose pid now belongs to another process (procStart differs) is not a live chat.
printf '{"pid": %s, "sessionId": "dead-0000-0000", "procStart": "Thu Jan  1 00:00:00 1970", "entrypoint": "cli"}' \
  "$$" >"$WORK/sessions/$$.json"

T="$WORK/proj/$sid.jsonl"
{
  echo '{"type":"user","message":{"role":"user","content":"<pasted_content id=a1>first line\nsecond</pasted_content id=a1>"},"timestamp":"t1"}'
  echo '{"type":"user","isMeta":true,"message":{"role":"user","content":"<system-reminder>x</system-reminder>"}}'
  echo '{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"thinking","thinking":"hidden"},{"type":"text","text":"Looking."},{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"ls -la","description":"List files"}}]}}'
  echo '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"a\nb","is_error":false}]}}'
  echo '{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"subagent noise"}]}}'
  echo '{"type":"user","message":{"role":"user","content":"<task-notification> <summary>Background command done</summary> </task-notification>"}}'
  echo '{"type":"user","message":{"role":"user","content":"<command-name>/model</command-name>\n<command-args>opus</command-args>"}}'
  echo '{"type":"system","subtype":"away_summary","content":"Goal: fixtures. Next: assert."}'
  echo '{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"Done **here**."}]}}'
} >"$T"
# chat-find --recent: the live chat and a past one that spoke earlier (listed first: the history sorts); a search
# prints $WORK/search.json (none: it fails) and leaves its arguments in $WORK/search-args. Both run by the
# server's python, as `chats --open-command` is: a past chat's resume line on its account, or a dead one's error.
# The past chat's transcript sits in a config root of its own (root/projects/<dir>/), as the trash finds it.
PT="$WORK/root/projects/-x-old/$past.jsonl"
mkdir -p "$(dirname "$PT")"
printf '{"type":"user","message":{"role":"user","content":"old words"}}' >"$PT"
printf '[{"session": "%s", "name": "Old chat", "path": "%s", "cwd": "/x/old/.claude/worktrees/b1", "spoke": %s, "role": "user", "text": "old words"}, {"session": "%s", "name": "Fixture chat", "path": "%s", "ctx": 42000, "model": "claude-opus-5-5", "spoke": %s, "ttl": 3600, "cwd": "/x/proj"}]' \
  "$past" "$PT" "$(($(date +%s) - 5000))" "$sid" "$T" "$(date +%s)" >"$WORK/chat-find.json"
cat >"$WORK/bin/chat-find" <<EOF
import sys
if "--recent" in sys.argv:
    print(open("$WORK/chat-find.json").read())
    sys.exit()
open("$WORK/search-args", "w").write(" ".join(sys.argv[1:]))
try:
    print(open("$WORK/search.json").read())
except OSError:
    sys.exit("index gone")
EOF
# claude-setup's session-trash (stub): its verbs in trash.log, a sweep's config root too; a sweep trashes what is
# marked, as the real one does with a chat no process holds.
cat >"$WORK/bin/trash" <<EOF
#!/bin/bash
case \$1 in
  sweep) echo "sweep \$CLAUDE_CONFIG_DIR" >>"$WORK/trash.log"; sed 's/^/trashed /' "$WORK/marks" 2>/dev/null; : >"$WORK/marks" ;;
  *) echo "\$1 \$2" >>"$WORK/trash.log" ;;
esac
case \$1 in
  mark) echo "\$2" >>"$WORK/marks"; echo "marked \$2" ;;
  unmark) grep -v "\$2" "$WORK/marks" >"$WORK/marks.n"; mv "$WORK/marks.n" "$WORK/marks"; echo "unmarked \$2" ;;
  restore) grep -qx "\$2" "$WORK/marks" 2>/dev/null && { echo "error: trashed session not found" >&2; exit 1; }; echo "restored \$2" ;;
esac
EOF
chmod +x "$WORK/bin/trash"
cat >"$WORK/bin/chats" <<'EOF'
import sys
sid = sys.argv[sys.argv.index("--open-command") + 1]
if sid.startswith("dead"):
    sys.exit("no transcript for " + sid)
print('cd "/x/old" && claude --resume ' + sid)
print("account=acc3 source=cache")
EOF
printf 'v2 %s fixacct\n' "$(date +%s)" >"$WORK/tracks/cache-ttl-track-$sid"
printf '{"title": "Chats/other  1.0/2.0 cores", "rows": [{"text": "CPU   1.0 chats +  2.0 other =  3.0 of 10 cores"}, "-", {"text": "full speed  Fixture chat           1.0 cores   2.5 GB  ▁▂▃", "session": "%s", "pid": %s}]}' \
  "$sid" "$chatpid" >"$WORK/chats.json"

# The stub hs: the menubar, a screen with a menu on it (❯ on option 1), and every `do script` with the pasted
# file's text copied out before the server deletes it. With $WORK/queue holding a JSON list, the screen is Claude
# Code's empty input over that queue, and Up (`"[A" & c`) writes their popAll lines to the transcript as the CLI
# does and empties the queue.
cat >"$WORK/bin/hs" <<EOF
#!/usr/bin/env python3
import json, os, re, sys
lua = sys.argv[sys.argv.index("-c") + 1]
with open("$WORK/hs.log", "a") as log:
    log.write(lua.replace("\\n", " ") + "\\n")
    m = re.search(r'read POSIX file "([^"]+)"', lua)
    if m:
        log.write("TEXT=" + json.dumps(open(m.group(1), encoding="utf-8").read(), ensure_ascii=False) + "\\n")
        if open(m.group(1)).read() == "/exit" and os.path.exists("$WORK/exit-ok"):
            os.kill($chatpid, 15)  # the chat obeys its /exit
queue = json.load(open("$WORK/queue")) if os.path.exists("$WORK/queue") else None
box = lambda line: "\\u23fa working\\n" + "\\u2500" * 20 + "\\n\\u276f " + line + "\\n" + "\\u2500" * 20 + "\\n  status"
if "llm-limits" in lua:
    print(json.dumps({"items": [{"r": [{"t": "Routing: next fixacct"}], "sub": [{"r": [{"t": "row", "c": "e64033", "a": 1}]}]}, {"sep": True}]}))
elif "return history of tab" in lua:
    print(json.dumps({"ok": True, "res": "".join("h%06d\\n" % i for i in range(80000)) + "Pick a color"}))
elif "return contents of tab" in lua and os.path.exists("$WORK/screen-fails"):
    print(json.dumps({"ok": False, "err": "Terminal timed out"}))
elif "return contents of tab" in lua and queue is not None:
    print(json.dumps({"ok": True, "res": box("Press up to edit queued messages" if queue else "")}))
elif '"[A" & c' in lua and queue is not None:
    with open("$T", "a") as transcript:
        for text in queue:
            transcript.write(json.dumps({"type": "queue-operation", "operation": "popAll", "content": text}) + "\\n")
    json.dump([], open("$WORK/queue", "w"))
    print(json.dumps({"ok": True, "res": "sent"}))
elif "close window j" in lua:
    print(json.dumps({"ok": True, "res": "closed"}))
elif "return contents of tab" in lua:
    print(json.dumps({"ok": True, "res": "Pick a color\\n\\u276f 1. Red\\n  2. Green\\n  3. Blue\\nEnter to select"}))
else:
    print(json.dumps({"ok": True, "res": "sent"}))
EOF
chmod +x "$WORK/bin/hs"
# The stub transcriptions-gpt: its control socket (status, remote-start, stop, cancel, bubble, usealt, restore, and
# `stats` for this test) and a UDP receiver counting the relayed audio packets; a stop writes the take's text to the
# deliver path, a restore the cut take's.
cat >"$WORK/bin/daemon-stub" <<'STUB'
import json, os, socket, struct, sys, threading, time
rt, log = sys.argv[1], sys.argv[2]
st = {"state": "idle", "deliver": None, "packets": 0, "marked": 0, "silent": 0, "gaps": 0, "streams": [], "macmic": False}
udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
udp.bind(("127.0.0.1", 0))
def receive():
    last = {}
    while True:
        data = udp.recv(2048)
        magic, stream, seq = struct.unpack("!4sII", data[:12])
        if magic != b"TGMA" or len(data) != 652:
            continue
        if stream not in st["streams"]:
            st["streams"].append(stream)
        elif seq != last[stream] + 1:
            st["gaps"] += 1
        last[stream] = seq
        st["packets"] += 1
        st["marked"] += data[12:] == b"\x01\x02" * 320
        st["silent"] += data[12:] == bytes(640)
threading.Thread(target=receive, daemon=True).start()
def finish(text="текст с iPad"):
    time.sleep(0.3)
    with open(st["deliver"], "w") as f:
        f.write(text)
    st["state"] = "idle"
BUBBLE = {"pill": "", "polish_since": None, "alt": "", "degraded": False,
          "restore": {"name": "20261108T153230.wav", "at": 1794145895.6, "chars": 11834, "armed": True}}
srv = socket.socket(socket.AF_UNIX)
srv.bind(os.path.join(rt, "control.sock"))
srv.listen(8)
with open(os.path.join(rt, "udp-port"), "w") as f:
    f.write(str(udp.getsockname()[1]))
while True:
    conn, _ = srv.accept()
    line = conn.recv(4096).decode().strip()
    verb, _, arg = line.partition(" ")
    if verb not in ("status", "stats"):
        open(log, "a").write(line + "\n")
    if verb == "status":
        reply = st["state"]
    elif verb == "stats":
        reply = json.dumps({k: v for k, v in st.items() if k != "streams"} | {"streams": len(st["streams"])})
    elif verb == "remote-start":
        if not st["packets"]:
            reply = "err no stream"
        elif st["state"] != "idle":
            reply = "ignored " + st["state"]
        else:
            st["deliver"], st["state"], reply = json.loads(arg)["deliver"], "recording", "ok"
    elif verb == "stop" and st["state"] == "recording":
        st["state"], reply = "processing", "ok"
        threading.Thread(target=finish, daemon=True).start()
    elif verb == "cancel":
        st["state"], reply = "idle", "ok"
    elif verb == "bubble":
        reply = json.dumps(dict(BUBBLE, state=st["state"], remote=st["deliver"] is not None))
    elif verb == "usealt":
        reply = "ok" if st["state"] == "processing" else "ignored " + st["state"]
    elif verb == "ipad-want":
        reply = "ok"
    elif verb == "ipad-mic":
        reply = "ok present=%s connected=False peer=%s level=%s" % (st["macmic"], "fe80::1" if st["macmic"] else "None", 0.25 if st["macmic"] else 0.0)
    elif verb == "ipad-wake" and st.get("wakeable"):
        threading.Timer(0.6, lambda: st.update(macmic=True)).start()
        reply = "ok"
    elif verb == "ipad-webreset":
        reply = "ok"
    elif verb == "macmic-wakeable":
        st["wakeable"], reply = True, "ok"
    elif verb == "orphan":
        st["deliver"], st["state"], reply = "/gone/take.txt", "recording", "ok"
    elif verb == "restore" and st["state"] in ("idle", "recording"):
        st["deliver"], st["state"], reply = json.loads(arg)["deliver"], "processing", "ok"
        threading.Thread(target=finish, args=("пятнадцать минут диктовки",), daemon=True).start()
    else:
        reply = "ignored " + st["state"]
    conn.sendall(reply.encode() + b"\n")
    conn.close()
STUB
"$PY" "$WORK/bin/daemon-stub" "$RT" "$WORK/daemon.log" &
for _ in $(seq 100); do [ -s "$RT/udp-port" ] && break; sleep 0.1; done
[ -s "$RT/udp-port" ] || fail "no stub daemon"
stats() { "$PY" -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(b"stats\n"); print(s.recv(4096).decode())' "$RT/control.sock"; }

# worker-run's run dirs: two live runs on the worker's pid stamped with its real start (one holding a slot, one
# waiting for it), and four the list must skip: an exit code, a launch past the 2-day horizon, a reused pid
# (stamped 1000 s off) and the pre-launch pid 0.
now=$(date +%s)
began=$("$PY" -c 'import re, subprocess, sys, time
p = [int(x) for x in re.split("[-:]", subprocess.check_output(["ps", "-o", "etime=", "-p", sys.argv[1]]).decode().strip())]
print(int(time.time() - sum(v * m for v, m in zip(reversed(p), (1, 60, 3600, 86400)))))' "$workerpid")
wsid2=77777777-2222-3333-4444-555555555555
echo '{"type":"user","message":{"role":"user","content":"worker brief"}}' >"$WORK/proj/$wsid2.jsonl"
mkrun() { # name pid stamp slot-json -> run dir
  mkdir -p "$WORK/runs/$1"
  printf '{"vendor": "%s", "pid": %s, "pid_started_at": %s%s}' "${1%%-*}" "$2" "$3" "$4" >"$WORK/runs/$1/meta.json"
  echo "$WORK/runs/$1"
}
d=$(mkrun "claudeb-$((now - 100))-1-aa01" "$workerpid" "$began" ', "slot_at": 1, "cli_pid": 2')
printf '{"phase": "run", "session": "%s", "account": "acc1", "model": "claude-opus-5-5", "effort": "xhigh", "started_epoch": %s}' \
  "$sid" "$((now - 90))" >"$d/state.json"
echo "Fixture review" >"$d/title"; echo 1200 >"$d/tokens"; echo "$wsid2" >"$d/worker-session"
echo "$WORK/proj/$wsid2.jsonl" >"$d/session-file"
d=$(mkrun "codex-$((now - 50))-1-aa02" "$workerpid" "$began" ', "slot_at": 1')
printf '{"phase": "wait", "session": "%s", "account": "acc2", "started_epoch": %s}' "$sid" "$((now - 40))" >"$d/state.json"
d=$(mkrun "gemini-$((now - 60))-1-aa03" "$workerpid" "$began" ''); echo 0 >"$d/exit_code"
mkrun "grok-$((now - 3 * 86400))-1-aa04" "$workerpid" "$began" '' >/dev/null
mkrun "codex-$((now - 70))-1-aa05" "$workerpid" "$((began - 1000))" '' >/dev/null
mkrun "codex-$((now - 80))-1-aa06" 0 "$began" '' >/dev/null
export PAGES_DIR="$WORK/pages" APP_SESSIONS="$WORK/sessions" APP_HS="$WORK/bin/hs" APP_CHAT_FIND="$WORK/bin/chat-find" \
  APP_CHATS_JSON="$WORK/chats.json" STATUSLINE_CACHE_DIR="$WORK/tracks" TRANSCRIBER_RUNTIME_DIR="$RT" \
  APP_MIC_PORT="$(cat "$RT/udp-port")" WORKER_RUN_DIR="$WORK/runs" APP_CHATS="$WORK/bin/chats" APP_CLOSE_WAIT=1 \
  APP_TRASH="$WORK/bin/trash" CHAT_PINS_FILE="$WORK/pins.json" CHAT_NAME_ROOTS="$WORK/root/projects"

"$PAGE" serve --port 0 >"$WORK/serve.out" 2>&1 &
"$ROOT/bin/wait-until" --max 10 log "$WORK/serve.out" 'page serve: http' >/dev/null || fail "serve: $(cat "$WORK/serve.out")"
port=$(sed -n 's|^page serve: http://127.0.0.1:\([0-9]*\) .*|\1|p' "$WORK/serve.out")
base="http://127.0.0.1:$port"
get() { curl -s -o "$WORK/body" -w '%{http_code}' "$@"; }
post() { # path body [curl args] -> status
  curl -s -o "$WORK/body" -w '%{http_code}' -H 'Content-Type: application/json' -d "$2" "${@:3}" "$base$1"; }

# The client and its manifest; a LAN client without the cookie gets nothing.
assert test "$(get "$base/app/")" = 200
assert grep -q 'app.js' "$WORK/body"
assert test "$(get "$base/app/app.js")" = 200
assert test "$(get "$base/app/../store.py")" = 404
assert test "$(get "$base/app/manifest.webmanifest")" = 200
token=$(cat "$PAGES_DIR/.lan-token")
assert test "$(jq -r .start_url "$WORK/body")" = "/app/?k=$token"
assert test "$(get -H "Host: mac.local:$port" "$base/api/chats")" = 403
assert test "$(get -H "Host: mac.local:$port" -H "Cookie: pages_k=$token" "$base/api/chats")" = 200

# The list: the live chat with its tty, the account from its own environment, chat-find's facts, the warm cache,
# memlogd's load, the last line and the recap; the worker apart; the stale record nowhere.
assert test "$(get "$base/api/chats")" = 200
assert test "$(jq -r '.chats | length' "$WORK/body")" = 1
assert test "$(jq -r '.chats[0] | [.sid, .name, .account, .vendor, .warm, .ctx, .load.state] | join("|")' "$WORK/body")" \
  = "$sid|Fixture chat|fixacct|claude|fixacct|42000|full speed"
assert test "$(jq -r '.chats[0].load.cores == 1 and .chats[0].load.gb == 2.5' "$WORK/body")" = true
assert like "$(jq -r '.chats[0].tty' "$WORK/body")" "/dev/ttys*"
assert test "$(jq -r '.chats[0].until > now' "$WORK/body")" = true
assert test "$(jq -r '.chats[0].last.t' "$WORK/body")" = "Done **here**."
assert test "$(jq -r '.chats[0].away' "$WORK/body")" = "Goal: fixtures. Next: assert."
assert test "$(jq -r '.workers | map(.sid + "|" + .account) | join(",")' "$WORK/body")" = "$wsid|wacct"
assert test "$(jq -r '.machine.lines[0]' "$WORK/body")" = "CPU   1.0 chats +  2.0 other =  3.0 of 10 cores"
assert like "$(jq -r '.client' "$WORK/body")" "????????"  # the client files' fingerprint: a change reloads the app
# Worker runs, newest first, by row `ar`'s liveness; a claude run's transcript is readable by its worker session.
assert test "$(jq -r '[.runs[].id] | join(",")' "$WORK/body")" = "codex-$((now - 50))-1-aa02,claudeb-$((now - 100))-1-aa01"
assert test "$(jq -r '.runs[1] | [.vendor, .account, .model, .effort, .title, .launcher, .queued, .sid, .tokens, .started] | join("|")' "$WORK/body")" \
  = "claude|acc1|claude-opus-5-5|xhigh|Fixture review|$sid|false|$wsid2|1200|$((now - 90))"
assert test "$(jq -r '.runs[0] | [.vendor, .queued, .sid] | join("|")' "$WORK/body")" = "codex|true|"
assert test "$(get "$base/api/chat/$wsid2/log")" = 200
assert test "$(jq -r '.items[0].t' "$WORK/body")" = "worker brief"
# The list stays cheap: chats + workers + runs in well under a second on the fixture.
assert "$PY" -c 'import sys, time, urllib.request
t = time.time(); urllib.request.urlopen(sys.argv[1]).read(); sys.exit(time.time() - t > 1.0)' "$base/api/chats"

# The transcript: speech, tool calls with their results, events, the recap; no meta, thinking or sidechain.
assert test "$(get "$base/api/chat/$sid/log")" = 200
assert test "$(jq -r '[.items[].k] | join(",")' "$WORK/body")" = "user,asst,tool,result,event,user,away,asst"
assert test "$(jq -r '.items[0].t' "$WORK/body")" = "first line
second"
assert test "$(jq -r '.items[2] | [.n, .s] | join("|")' "$WORK/body")" = "Bash|List files
ls -la"
assert test "$(jq -r '.items[3] | [.id, .t] | join("|")' "$WORK/body")" = "tu1|a
b"
assert test "$(jq -r '.items[4].t' "$WORK/body")" = "Background command done"
assert test "$(jq -r '.items[5].t' "$WORK/body")" = "/model opus"
end=$(jq -r .end "$WORK/body")
assert test "$end" = "$(wc -c <"$T" | tr -d ' ')"
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"later"}]}}' >>"$T"
whole=$(wc -c <"$T" | tr -d ' ')
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"torn' >>"$T"
assert test "$(get "$base/api/chat/$sid/log?after=$end")" = 200
assert test "$(jq -r '[.items[].t] | join(",")' "$WORK/body")" = "later"
assert test "$(jq -r '.end' "$WORK/body")" = "$whole"
assert test "$(get "$base/api/chat/$sid/log?before=$end")" = 200
assert test "$(jq -r '.start' "$WORK/body")" = 0
assert test "$(get "$base/api/chat/bad..id/log")" = 404
# A message typed while the chat works: queued, then taken mid-turn (back as his own words at its own time) or
# sent as the next turn (a dequeue names no text: it takes the head). A task notification's entry stays in the
# mirrored queue with no text; its attachment is not his.
printf '"}]}}\n' >>"$T"
{
  echo '{"type":"queue-operation","operation":"enqueue","content":"check the scroll","timestamp":"t5"}'
  echo '{"type":"queue-operation","operation":"enqueue","content":"<task-notification>x</task-notification>"}'
  echo '{"type":"queue-operation","operation":"remove","content":"check the scroll","timestamp":"t6"}'
  echo '{"type":"attachment","attachment":{"type":"queued_command","commandMode":"prompt","prompt":"check the scroll","origin":{"kind":"human"},"timestamp":"t5"},"timestamp":"t6"}'
  echo '{"type":"attachment","attachment":{"type":"queued_command","commandMode":"prompt","prompt":"done","origin":{"kind":"task-notification"}}}'
  echo '{"type":"queue-operation","operation":"dequeue"}'
  # What the app sends is a bracketed paste, which Claude Code wraps: still his (it was hidden as a notification).
  printf '%s\n' '{"type":"queue-operation","operation":"enqueue","content":"<pasted_content id=\"ab12\">\nfrom the iPad\n</pasted_content id=\"ab12\">","timestamp":"t7"}'
} >>"$T"
assert test "$(get "$base/api/chat/$sid/log?after=$whole")" = 200
assert test "$(jq -c '[.items[] | [.k, .t, .op, .at, .mid, .hide]]' "$WORK/body")" \
  = '[["asst","torn",null,"",null,null],["queued","check the scroll",null,"t5",null,false],["queued","",null,"",null,true],["unqueued","check the scroll","remove","t6",null,false],["user","check the scroll",null,"t5",true,null],["unqueued","","dequeue","",null,true],["queued","from the iPad",null,"t7",null,false]]'

# Input: one bracketed paste of the exact text into the chat's own tty, through ChatGate.terminalScript.
assert test "$(post "/api/chat/$sid/send" '{"text": "привет\nдве строки"}')" = 200
assert grep -q "terminalScript('pages-app'" "$WORK/hs.log"
assert grep -q "tty of tab i of window j is \"$(jq -r '.chats[0].tty' <(curl -s "$base/api/chats"))\"" "$WORK/hs.log"
assert grep -qF '[200~" & txt & e & "[201~"' "$WORK/hs.log"
assert test "$(grep '^TEXT=' "$WORK/hs.log" | tail -1)" = 'TEXT="привет\nдве строки"'
assert test -z "$(ls -A "$(python3 -c 'import tempfile; print(tempfile.gettempdir())')/pages-app" 2>/dev/null)"
assert test "$(post "/api/chat/$sid/send" '{"text": "  "}')" = 400
assert test "$(post "/api/chat/$wsid/send" '{"text": "x"}')" = 404
assert test "$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: text/plain' -d '{"text":"x"}' "$base/api/chat/$sid/send")" = 403
assert test "$(post "/api/chat/$sid/send" '{"text": "x"}' -H "Origin: http://evil.example")" = 403

# Keys: choose 3 from the ❯ on 1 is two downs then the Return do script adds; esc is ESC.
: >"$WORK/hs.log"
assert test "$(post "/api/chat/$sid/key" '{"choose": 3}')" = 200
assert grep -qF 'do script (e & "[B") & (e & "[B") in tab i of window j' "$WORK/hs.log"
assert test "$(post "/api/chat/$sid/key" '{"key": "esc"}')" = 200
assert grep -qF 'do script (ASCII character 27) in tab i of window j' "$WORK/hs.log"
assert test "$(post "/api/chat/$sid/key" '{"key": "rm"}')" = 502
assert test "$(post "/api/chat/$sid/key" '{"choose": 99}')" = 400

# The microphone: a remote take on transcriptions-gpt fed with the browser's PCM as receiver packets (its own
# stream, contiguous seq, silence between bursts), the text back from the deliver file, one stop only.
assert test "$(post /api/mic/start '{}')" = 200
mic=$(jq -r .id "$WORK/body")
assert like "$mic" "????????????????"
assert grep -q "^remote-start {\"deliver\": \"/.*/pages-app/mic-$mic.txt\"}$" "$WORK/daemon.log"
pcm() { "$PY" -c 'import sys; sys.stdout.buffer.write(b"\x01\x02" * int(sys.argv[1]))' "$1" >"$WORK/pcm"; }
chunk() { curl -s -o "$WORK/body" -w '%{http_code}' -H "Content-Type: ${2:-application/octet-stream}" --data-binary @"$WORK/pcm" "$base/api/mic/$1/chunk"; }
pcm 500
assert test "$(chunk "$mic")" = 200
pcm 140  # 1000 + 280 bytes: the torn tail of the first chunk goes out with the second, two whole frames
assert test "$(chunk "$mic")" = 200
assert test "$(chunk "$mic" text/plain)" = 403
assert test "$(chunk 0123456789abcdef)" = 404
"$PY" -c 'import sys; sys.stdout.buffer.write(bytes(300 << 10))' >"$WORK/pcm"
assert test "$(chunk "$mic")" = 400
before=$(stats | jq .silent)
sleep 0.9
assert test "$(stats | jq --argjson b "$before" '.silent > $b + 4')" = true
assert test "$(stats | jq -r '[.marked, .gaps, .streams] | join(",")')" = "2,0,1"
assert test "$(post "/api/mic/$mic/stop" '{}')" = 200
assert test "$(jq -r '[.ok, .text] | join("|")' "$WORK/body")" = "true|текст с iPad"
assert test "$(grep -c '^stop$' "$WORK/daemon.log")" = 1
assert test -z "$(ls -A "$(python3 -c 'import tempfile; print(tempfile.gettempdir())')/pages-app" 2>/dev/null)"
assert test "$(post "/api/mic/$mic/stop" '{}')" = 404
# Cancel reaches the daemon only while it records: on an idle one it is the Esc of another track.
assert test "$(post /api/mic/start '{}')" = 200
mic=$(jq -r .id "$WORK/body")
assert test "$(post "/api/mic/$mic/cancel" '{}')" = 200
assert test "$(grep -c '^cancel$' "$WORK/daemon.log")" = 1
pcm 320
assert test "$(chunk "$mic")" = 404
# A new start supersedes a take its page left open (a reload): it is cancelled, never a 409 for ten seconds.
assert test "$(post /api/mic/start '{}')" = 200
old=$(jq -r .id "$WORK/body")
assert test "$(post /api/mic/start '{}')" = 200
mic=$(jq -r .id "$WORK/body")
assert test "$(chunk "$old")" = 404
assert test "$(chunk "$mic")" = 200
assert test "$(grep -c '^cancel$' "$WORK/daemon.log")" = 2
assert test "$(post "/api/mic/$mic/cancel" '{}')" = 200
# The Mac's voice pill, mirrored (he never sees it from the iPad): its state as the daemon's `bubble` gives it, the
# other result on a tap, and a cut take restored into this app instead of pasted on the Mac, also over a take of
# ours still recording (the daemon discards it; our relay must not cancel the restore).
assert test "$(get "$base/api/mic/bubble")" = 200
assert test "$(jq -r '[.ok, .state, .restore.name, .restore.armed] | join("|")' "$WORK/body")" = "true|idle|20261108T153230.wav|true"
assert test "$(post /api/mic/usealt '{}')" = 200
assert test "$(jq -r '[.ok, .err] | join("|")' "$WORK/body")" = "false|ignored idle"
assert test "$(post /api/mic/restore '{"name": "20261108T153230.wav"}')" = 200
assert test "$(jq -r '[.ok, .text] | join("|")' "$WORK/body")" = "true|пятнадцать минут диктовки"
assert grep -q '^restore {"deliver": "/.*/pages-app/restore-[0-9a-f]*.txt", "name": "20261108T153230.wav"}$' "$WORK/daemon.log"
assert test "$(post /api/mic/start '{}')" = 200
mic=$(jq -r .id "$WORK/body")
cancels=$(grep -c '^cancel$' "$WORK/daemon.log")
assert test "$(post /api/mic/restore '{}')" = 200
assert test "$(jq -r .text "$WORK/body")" = "пятнадцать минут диктовки"
assert test "$(chunk "$mic")" = 404
sleep 0.3
assert test "$(grep -c '^cancel$' "$WORK/daemon.log")" = "$cancels"
assert test -z "$(ls -A "$(python3 -c 'import tempfile; print(tempfile.gettempdir())')/pages-app" 2>/dev/null)"
# MacMic (Egor 2026-11-08: iPadOS refused the browser the microphone, no prompt, through reloads and a relaunch,
# while it gave it to MacMic): each look at the pill keeps MacMic streaming 2 h (ipad-want), a take via MacMic wakes
# it when asleep (ipad-wake: a launch in the background) and records its stream: no packet of ours reaches the
# receiver, the client's /alive beats stand for its chunks.
assert test "$(get "$base/api/mic/bubble")" = 200
assert test "$(jq -r .macmic "$WORK/body")" = asleep
assert grep -q '^ipad-want 7200$' "$WORK/daemon.log"
# The Home Screen app's refusal outlives a reload (WebKit bug 329593): its row has the Mac end SafariViewService.
assert test "$(post /api/mic/webreset '{}')" = 200
assert grep -q '^ipad-webreset$' "$WORK/daemon.log"
assert test "$(post /api/mic/start '{"via": "macmic"}')" = 409
"$PY" -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(b"macmic-wakeable\n"); s.recv(64)' "$RT/control.sock"
packets=$(stats | jq .packets)
assert test "$(post /api/mic/start '{"via": "macmic"}')" = 200
assert grep -q '^ipad-wake$' "$WORK/daemon.log"
assert test "$(jq -r .via "$WORK/body")" = macmic
mic=$(jq -r .id "$WORK/body")
assert test "$(get "$base/api/mic/bubble")" = 200
assert test "$(jq -r .macmic "$WORK/body")" = streaming
sleep 0.9
assert test "$(post "/api/mic/$mic/alive" '{}')" = 200
assert test "$(jq -r '[.level, .macmic] | join("|")' "$WORK/body")" = "0.25|streaming"
assert test "$(stats | jq .packets)" = "$packets"
assert test "$(post "/api/mic/$mic/stop" '{}')" = 200
assert test "$(jq -r '[.ok, .text] | join("|")' "$WORK/body")" = "true|текст с iPad"
assert test "$(post "/api/mic/$mic/alive" '{}')" = 404
# A take of ours that outlived its page, its cancel lost (Egor 2026-11-08: each tap then got "ignored recording"
# until the daemon gave up on it): a new start ends it and records. A take not of ours (no file) is left alone.
"$PY" -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(b"orphan\n"); s.recv(64)' "$RT/control.sock"
: >"$WORK/daemon.log"
assert test "$(post /api/mic/start '{}')" = 200
assert test "$(grep -E '^(remote-start|cancel|bubble)' "$WORK/daemon.log" | cut -d' ' -f1 | tr '\n' ' ')" = "remote-start bubble cancel remote-start "
mic=$(jq -r .id "$WORK/body")
assert test "$(post "/api/mic/$mic/cancel" '{}')" = 200
# Behind `tailscale serve` the page's origin is https.
assert test "$(post "/api/chat/$sid/key" '{"key": "esc"}' -H "Origin: https://127.0.0.1:$port")" = 200

# The screen, the menubar mirror, pages.
assert test "$(get "$base/api/chat/$sid/screen")" = 200
assert like "$(jq -r .res "$WORK/body")" "Pick a color*"
# Scrolled past the screen, the Terminal sheet gets the tab's scrollback: its last 400 KB, from a line start.
assert test "$(get "$base/api/chat/$sid/screen?history=1")" = 200
assert test "$(jq -r '[.ok, (.res | length <= 409600), (.res | test("^h[0-9]{6}\n")), (.res | endswith("h079999\nPick a color"))] | all' "$WORK/body")" = true
# The load per chat for the sidebar's meters: bin/chat-load's rows as they are (a row's sub list included).
assert test "$(get "$base/api/load")" = 200
assert test "$(jq -r '[.title, .rows[1], .rows[2].session] | join("|")' "$WORK/body")" = "Chats/other  1.0/2.0 cores|-|$sid"
assert test "$(get "$base/api/menu")" = 200
assert test "$(jq -r '.items[0].sub[0].r[0].c' "$WORK/body")" = e64033
assert test "$(get "$base/api/pages")" = 200
assert test "$(jq -r '.pages | length' "$WORK/body")" = 0

# What failed is logged for `page report`, never a flood: a failing screen poll is one line per chat a minute,
# the client's own reports 20 a minute.
touch "$WORK/screen-fails"
for _ in 1 2 3; do get "$base/api/chat/$sid/screen" >/dev/null; sleep 0.9; done
rm "$WORK/screen-fails"
assert test "$(jq -s '[.[] | select(.op == "screen")] | length' "$PAGES_DIR/.events.jsonl")" = 1
assert test "$(jq -rs '[.[] | select(.op == "screen")][0] | [.sid, .error] | join("|")' "$PAGES_DIR/.events.jsonl")" \
  = "$sid|Terminal timed out"
for k in $(seq 25); do post /api/client-log "{\"kind\": \"offline\", \"ms\": $k, \"count\": 3, \"msg\": \"/api/chats: TypeError\", \"evil\": 1}" >/dev/null; done
assert test "$(jq -s '[.[] | select(.op == "client")] | length' "$PAGES_DIR/.events.jsonl")" = 20
assert test "$(jq -rs '[.[] | select(.op == "client")][0] | [.kind, .ms, .count, .msg, .evil] | join("|")' "$PAGES_DIR/.events.jsonl")" \
  = "offline|1|3|/api/chats: TypeError|"

# The info panel: the chat's statusline in full words with its colours (the fitted render only without a full one),
# and the files its edits that went through changed, summed per file, newest first; the transcript is read again
# only for what it grew by.
printf '\033[36mOpus 5.5 xhigh\033[0m \033[35mfixacct\033[0m \033[2m│\033[0m \033[34mproj\033[0m\nctx \033[32m8%%\033[0m \033[2m→11:56\033[0m' \
  >"$WORK/tracks/render-full-$sid"
printf '\033[36mOP5.5\033[0m\nctx' >"$WORK/tracks/render-$sid"
{
  echo '{"type":"user","timestamp":"2026-11-08T10:00:00Z","toolUseResult":{"filePath":"/x/proj/share/a.py","structuredPatch":[{"lines":[" keep","-old","+new","+more"]}]},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"e1","content":"ok"}]}}'
  echo '{"type":"user","timestamp":"2026-11-08T10:01:00Z","toolUseResult":{"type":"create","filePath":"/x/proj/b.md","content":"one\ntwo\nthree","structuredPatch":[]},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"e2","content":"ok"}]}}'
  echo '{"type":"user","timestamp":"2026-11-08T10:02:00Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"e3","content":"String not found","is_error":true}]}}'
} >>"$T"
assert test "$(get "$base/api/chat/$sid/info")" = 200
assert test "$(jq -c .status "$WORK/body")" \
  = '[[["Opus 5.5 xhigh","cyan"],[" ",""],["fixacct","magenta"],[" ",""],["│","dim"],[" ",""],["proj","blue"]],[["ctx ",""],["8%","green"],[" ",""],["→11:56","dim"]]]'
assert test "$(jq -r .root "$WORK/body")" = /x/proj
assert test "$(jq -c '[.files[] | [.p, .add, .del]]' "$WORK/body")" = '[["/x/proj/b.md",3,0],["/x/proj/share/a.py",2,1]]'
echo '{"type":"user","timestamp":"2026-11-08T10:03:00Z","toolUseResult":{"filePath":"/x/proj/share/a.py","structuredPatch":[{"lines":["-x","-y","+z"]}]}}' >>"$T"
rm "$WORK/tracks/render-full-$sid"
assert test "$(get "$base/api/chat/$sid/info")" = 200
assert test "$(jq -c '[.files[] | [.p, .add, .del]]' "$WORK/body")" = '[["/x/proj/share/a.py",3,3],["/x/proj/b.md",3,0]]'
assert test "$(jq -c .status "$WORK/body")" = '[[["OP5.5","cyan"]],[["ctx",""]]]'
assert test "$(get "$base/api/chat/0000-nope-0000/info")" = 404

# A queued message taken back: Up pulls Claude Code's queue into the empty input, the clears and a backslash leave
# nothing to submit, and every other message is pasted back in order (the first after clearing the backslash's
# line). Only an empty input over a queue is touched; a text already read comes back as an error, nothing lost.
assert test "$(post "/api/chat/$sid/unqueue" '{"text": " "}')" = 400
assert test "$(post "/api/chat/$sid/unqueue" '{"text": "drop B"}')" = 502
assert test "$(jq -r .err "$WORK/body")" = "no prompt on the Mac's screen"
echo '[]' >"$WORK/queue"
assert test "$(post "/api/chat/$sid/unqueue" '{"text": "drop B"}')" = 502
assert test "$(jq -r .err "$WORK/body")" = "nothing queued on the Mac"
echo '["keep A", "drop  B", "keep C", "<task-notification>x</task-notification>"]' >"$WORK/queue"
: >"$WORK/hs.log"
assert test "$(post "/api/chat/$sid/unqueue" '{"text": "drop B"}')" = 200
assert test "$(grep -c 'do script (e & "\[A" & c & "\\\\")' "$WORK/hs.log")" = 1
assert grep -q 'repeat 40 times' "$WORK/hs.log"
assert test "$(grep '^TEXT=' "$WORK/hs.log" | tr '\n' '|')" = 'TEXT="keep A"|TEXT="keep C"|'
assert test "$(grep -c 'do script (c & e & "\[200~"' "$WORK/hs.log")" = 1
assert grep -q 'repeat 4 times' "$WORK/hs.log"
echo '["keep A"]' >"$WORK/queue"
: >"$WORK/hs.log"
assert test "$(post "/api/chat/$sid/unqueue" '{"text": "gone"}')" = 502
assert test "$(jq -r .err "$WORK/body")" = "it had already gone to the chat"
assert test "$(grep '^TEXT=' "$WORK/hs.log" | tr '\n' '|')" = 'TEXT="keep A"|'
rm "$WORK/queue"

# Past chats. The history is chat-find --recent, newest first, live ones in it too (the client marks them); a
# search hands chat-find his words and maps its rows; a failed search is a 502 and is not cached.
assert test "$(get "$base/api/history")" = 200
assert test "$(jq -r '[.chats[] | .sid + "|" + .name + "|" + .text] | join(",")' "$WORK/body")" = "$sid|Fixture chat|,$past|Old chat|old words"
# Its project is the folder `chats` shows (a worktree's main checkout); its hash spares an unchanged list.
assert test "$(jq -r '[.chats[].project] | join(",")' "$WORK/body")" = "proj,old"
h=$(jq -r .h "$WORK/body")
assert test "$(get "$base/api/history?h=$h")" = 200
assert test "$(jq -c . "$WORK/body")" = "{\"same\":true,\"h\":\"$h\"}"
assert test "$(get "$base/api/search?q=old%20%20words")" = 502
assert like "$(jq -r .err "$WORK/body")" "chat-find failed: *index gone*"
printf '[{"session": "%s", "name": "Old chat", "at": 1000, "cwd": "/x/old", "title": "t", "snippet": "…old words…"}]' "$past" >"$WORK/search.json"
assert test "$(get "$base/api/search?q=old%20%20words")" = 200
assert test "$(jq -r '.chats[0] | [.sid, .name, .cwd, .spoke, .title, .text] | join("|")' "$WORK/body")" = "$past|Old chat|/x/old|1000|t|…old words…"
assert test "$(cat "$WORK/search-args")" = "--json --limit 40 -- old words"
# Open: a live chat is only shown (a second resume would fork it); a past one runs `chats`' command in a new
# Terminal window, its quotes escaped for AppleScript; a `chats` failure comes back in its own words.
: >"$WORK/hs.log"
assert test "$(post "/api/chat/$sid/open" '{}')" = 200
assert test "$(jq -r .live "$WORK/body")" = true
assert test ! -s "$WORK/hs.log"
assert test "$(post "/api/chat/$past/open" '{}')" = 200
assert test "$(jq -r '[.account, .source] | join("|")' "$WORK/body")" = "acc3|cache"
assert grep -qF "do script \"cd \\\"/x/old\\\" && claude --resume $past\" end tell" "$WORK/hs.log"
assert test "$(post "/api/chat/dead0000-2222-3333-4444-555555555555/open" '{}')" = 502
assert test "$(jq -r .err "$WORK/body")" = "no transcript for dead0000-2222-3333-4444-555555555555"
assert test "$(post "/api/chat/abc/open" '{}')" = 400
# A chat's menu (Egor 2026-11-08). Rename: a live chat gets /rename typed, a closed one the custom-title line
# /rename writes; branch: `chats`' command with --fork-session and the name, the chat open or not; trash:
# session-trash marks it and sweeps its own config root (a live one is ended instead, below); untrash restores.
: >"$WORK/hs.log"
# Never typed over a question on its screen (its Return would answer it).
assert test "$(post "/api/chat/$sid/rename" '{"name": "x"}')" = 409
assert test -z "$(grep '^TEXT=' "$WORK/hs.log")"
echo '[]' >"$WORK/queue"; sleep 0.9
assert test "$(post "/api/chat/$sid/rename" '{"name": "  New\n name  "}')" = 200
rm -f "$WORK/queue"
assert test "$(grep '^TEXT=' "$WORK/hs.log")" = 'TEXT="/rename New name"'
assert test "$(post "/api/chat/$past/rename" '{"name": "Старый, но новый"}')" = 200
assert test "$(tail -1 "$PT" | jq -r '[.type, .customTitle, .sessionId] | join("|")')" = "custom-title|Старый, но новый|$past"
assert test "$(head -1 "$PT" | jq -r .type)" = user
assert test "$(post "/api/chat/$past/rename" '{"name": " "}')" = 400
: >"$WORK/hs.log"
assert test "$(post "/api/chat/$sid/branch" '{"name": "a branch"}')" = 200
assert grep -qF "claude --resume $sid --fork-session --name='a branch'\" end tell" "$WORK/hs.log"
assert test "$(post "/api/chat/$sid/branch" '{"name": "-x"}')" = 200
assert grep -qF -- "--fork-session --name=-x\" end tell" "$WORK/hs.log"
assert test "$(post "/api/chat/$past/trash" '{}')" = 200
assert test "$(tr '\n' '|' <"$WORK/trash.log")" = "mark $past|sweep $WORK/root|"
assert test "$(post "/api/chat/$past/untrash" '{}')" = 200
assert test "$(tail -1 "$WORK/trash.log")" = "restore $past"
# An undo before the chat's end moved it (a live one is purged 2 s after it ends) takes its mark off instead.
"$WORK/bin/trash" mark "$past" >/dev/null; : >"$WORK/trash.log"
assert test "$(post "/api/chat/$past/untrash" '{}')" = 200
assert test "$(tr '\n' '|' <"$WORK/trash.log")" = "restore $past|unmark $past|"
# A branch (Egor 2026-11-08: it opened empty) has no transcript until its first message: it reads as the chat it
# branched from as that chat stood when the branch began (Egor: it showed what the parent said afterwards), then as
# its own file, which the client sees change.
fsid=ffffffff-2222-3333-4444-555555555555
printf '\n{"type":"user","message":{"role":"user","content":"before the branch"},"timestamp":"2026-01-01T00:00:00.000Z"}\n' >>"$PT"
"$PY" -c 'import time; time.sleep(300)' --resume "$past" --permission-mode x --fork-session --name 'a b' </dev/null &
forkpid=$!
printf '{"pid": %s, "sessionId": "%s", "cwd": "/x/old", "procStart": "%s", "entrypoint": "cli", "status": "idle", "startedAt": %s000}' \
  "$forkpid" "$fsid" "$(lstart "$forkpid")" "$(date +%s)" >"$WORK/sessions/$forkpid.json"
printf '{"type":"user","message":{"role":"user","content":"after the branch"},"timestamp":"2099-01-01T00:00:00.000Z"}\n' >>"$PT"
sleep 1.6
assert test "$(get "$base/api/chats")" = 200
assert test "$(get "$base/api/chat/$fsid/log")" = 200
assert test "$(jq -r '.file + "|" + ([.items[] | select(.k == "user") | .t] | join(","))' "$WORK/body")" = "$past.jsonl|old words,before the branch"
printf '{"type":"user","message":{"role":"user","content":"branch words"}}\n' >"$WORK/root/projects/-x-old/$fsid.jsonl"
sleep 2.6; get "$base/api/chats" >/dev/null
assert test "$(get "$base/api/chat/$fsid/log")" = 200
assert test "$(jq -r '.file + "|" + ([.items[].t] | join(","))' "$WORK/body")" = "$fsid.jsonl|branch words"
kill "$forkpid"; rm -f "$WORK/sessions/$forkpid.json" "$WORK/root/projects/-x-old/$fsid.jsonl"; sleep 1.6
# End: only a live terminal chat, never one at work; /exit typed into it, then its window closes once it is gone.
# One that does not exit in time keeps its window.
assert test "$(post "/api/chat/$wsid/close" '{}')" = 404
sed -i '' 's/"status": "idle"/"status": "busy"/' "$WORK/sessions/$chatpid.json"; sleep 1.6
assert test "$(post "/api/chat/$sid/close" '{}')" = 409
echo '[]' >"$WORK/queue"; sleep 0.9
assert test "$(post "/api/chat/$sid/rename" '{"name": "x"}')" = 409
rm -f "$WORK/queue"
: >"$WORK/trash.log"
assert test "$(post "/api/chat/$sid/trash" '{}')" = 409
assert test ! -s "$WORK/trash.log"
sed -i '' 's/"status": "busy"/"status": "idle"/' "$WORK/sessions/$chatpid.json"; sleep 1.6
: >"$WORK/hs.log"
assert test "$(post "/api/chat/$sid/close" '{}')" = 504
assert test "$(grep '^TEXT=' "$WORK/hs.log")" = 'TEXT="/exit"'
assert test -z "$(grep 'close window' "$WORK/hs.log")"
# A live chat's trash is its mark and its end; one that does not end keeps no mark.
assert test "$(post "/api/chat/$sid/trash" '{}')" = 504
assert test "$(tr '\n' '|' <"$WORK/trash.log")" = "mark $sid|unmark $sid|"
# What a chat runs (Egor 2026-11-08: see it, stop it, end a chat that holds it): its children but Claude Code's own
# (a hook's helper), each with its tree and the ports it listens on. A stop takes only one of them; an end or a
# trash of a chat holding any asks first (409, how many), forced it stops them and ends the chat.
spawned() { rm -f "$WORK/port"; touch "$WORK/spawn"; for _ in $(seq 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done; cat "$WORK/port"; }
port=$(spawned); sleep 2.6
assert test "$(get "$base/api/chats")" = 200
assert test "$(jq -r '.chats[0].procs' "$WORK/body")" = 1
assert test "$(get "$base/api/chat/$sid/procs")" = 200
assert test "$(jq -r '.procs[] | [.n, (.ports | join(",")), (.cmd | startswith("python -c import socket"))] | map(tostring) | join("|")' "$WORK/body")" = "2|$port|true"
kid=$(jq -r '.procs[0].pid' "$WORK/body")
assert test "$(get "$base/api/chat/$sid/info")" = 200
assert test "$(jq -r '[.procs[].ports[]] | join(",")' "$WORK/body")" = "$port"
assert test "$(post "/api/chat/$sid/stop" '{"pid": '"$$"'}')" = 404
assert test "$(post "/api/chat/$sid/close" '{}')" = 409
assert test "$(jq -r .procs "$WORK/body")" = 1
assert test "$(post "/api/chat/$sid/trash" '{}')" = 409
assert test "$(post "/api/chat/$sid/stop" '{"pid": '"$kid"'}')" = 200
assert test "$(jq -r .stopped "$WORK/body")" = 2
assert test -z "$(pgrep -P "$kid")"
assert test -z "$(ps -o pid= -p "$kid")"
port=$(spawned)
assert test "$(get "$base/api/chat/$sid/procs")" = 200
kid=$(jq -r '.procs[0].pid' "$WORK/body")
touch "$WORK/exit-ok"
assert test "$(post "/api/chat/$sid/close" '{"force": true}')" = 200
assert test -z "$(ps -o pid= -p "$kid")"
assert test "$(jq -r .window "$WORK/body")" = closed
assert grep -qF 'if (count tabs of window j) is 1 then close window j' "$WORK/hs.log"
assert test "$(get "$base/api/chats")" = 200
assert test "$(jq -r '.chats | length' "$WORK/body")" = 0

# A line longer than the read window (a pasted image, a huge result) never stalls Earlier: the window reaches back
# to the line's start, so every call moves on (it once answered its own offset with nothing, and the app asked again
# forever).
"$PY" -c 'import json, sys
line = lambda t: json.dumps({"type": "user", "message": {"role": "user", "content": t}}) + "\n"
open(sys.argv[1], "a").write(line("x" * 900000) + line("after the big one"))' "$T"
assert test "$(get "$base/api/chat/$sid/log")" = 200
assert test "$(jq -r '.items[-1].t' "$WORK/body")" = "after the big one"
s1=$("$PY" -c 'import sys; d = open(sys.argv[1], "rb").read(); print(d.rindex(b"\n", 0, len(d) - 1) + 1)' "$T")
assert test "$(get "$base/api/chat/$sid/log?before=$s1")" = 200
assert test "$(jq -r '[.end == '"$s1"', .start < '"$s1"' - 900000, .items[-1].k == "user"] | all' "$WORK/body")" = true
# An Earlier block is a block: windows of a few big lines each are joined until six things were said in it, so one
# scroll of his brings a screenful, not three lines (the app then asked again and again on its own).
"$PY" -c 'import json, sys
line = lambda t: json.dumps({"type": "user", "message": {"role": "user", "content": t}}) + "\n"
open(sys.argv[1], "a").write("".join(line("b%02d " % i + "y" * 200000) for i in range(30)) + line("the end"))' "$T"
assert test "$(get "$base/api/chat/$sid/log")" = 200
s2=$(jq -r .start "$WORK/body")
assert test "$(get "$base/api/chat/$sid/log?before=$s2")" = 200
assert test "$(jq -r '[(.items | length >= 6), .end == '"$s2"', (.items[-1].t | startswith("b"))] | all' "$WORK/body")" = true
# The tail reaches back the same way, and on until something was said: a chat whose last 768 KB are two tool calls
# and their screenshots opened on them alone (Egor 2026-11-08: nothing of what was said, only its spinner).
"$PY" -c 'import json, sys
res = lambda: json.dumps({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "u1", "content": "z" * 400000}]}}) + "\n"
said = json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "before the tools"}]}}) + "\n"
open(sys.argv[1], "a").write(said + "".join(res() for _ in range(3)))' "$T"
assert test "$(get "$base/api/chat/$sid/log")" = 200
assert test "$(jq -r '[(.items | length >= 6), ([.items[].t] | index("before the tools") != null)] | all' "$WORK/body")" = true
# A block counts what was said, not tool calls: 8 MB of tool output between two exchanges is crossed in one block
# (Egor 2026-11-08: Earlier brought one or two Bash calls and nothing said).
"$PY" -c 'import json, sys
res = lambda: json.dumps({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "u1", "content": "z" * 800000}]}}) + "\n"
said = lambda t: json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": t}]}}) + "\n"
open(sys.argv[1], "a").write(said("s0") + "".join(res() for _ in range(10)) + "".join(said("s%d" % i) for i in range(1, 7)))' "$T"
assert test "$(get "$base/api/chat/$sid/log")" = 200
assert test "$(jq -r '[.items[] | select(.k == "asst") | .t] | join(",")' "$WORK/body")" = "s1,s2,s3,s4,s5,s6"
s3=$(jq -r .start "$WORK/body")
assert test "$(get "$base/api/chat/$sid/log?before=$s3")" = 200
assert test "$(jq -r '([.items[].t] | index("s0") != null) and ([.items[] | select(.k == "result")] | length >= 10)' "$WORK/body")" = true

# It costs Claude Code nothing: no model call, no settings or hooks touched; the only programs it runs are ps,
# Hammerspoon, chat-find, chats (to open a past chat), the trash /trash uses and lsof (the ports a chat's processes
# listen on), and the client polls only while it is on screen, at most once a second.
# (OWN_KID names the hooks' helpers' paths only to leave them out of what a chat runs.)
assert test -z "$(grep -nE 'anthropic|openai|claude -p|settings\.json|hooks' "$ROOT/share/pages/app.py" | grep -v ':OWN_KID = ')"
assert test "$(grep -oE 'run\(\[[^],]+' "$ROOT/share/pages/app.py" | sort -u | tr '\n' ' ')" = 'run(["lsof" run(["ps" run([HS run([sys.executable run([TRASH '
assert test "$(grep -c 'setInterval(' "$ROOT/share/pages/app/app.js")" = 1
assert "$PY" -c 'import sys
sys.exit("if (document.visibilityState !== \x27visible\x27) return;\n  tick++;" not in open(sys.argv[1]).read())' "$ROOT/share/pages/app/app.js"
assert test "$(grep -c '^}, 1000);$' "$ROOT/share/pages/app/app.js")" = 1
# Egor 2026-11-08, a first tap on the iPad lost: iOS drops a tap whose node a redraw replaces, so the polls' list,
# meters, title and mic redraw only on a change; no hover style on a touch screen (it ate the first tap); a lost tap
# is reported (tap-lost), its touchend caught on the touched node too, since a removed node's never reaches document.
for g in 'if (listHtml !== html) {' 'if (box.dataset.h !== html) { box.dataset.h = html; box.innerHTML = html; }' \
  'if (t.dataset.h !== html) { t.dataset.h = html; t.innerHTML = html; }' "if (\$('#mic').dataset.rec !== String(rec))" \
  "el.addEventListener('touchend', tapEnd, {once: true, passive: true});" "report({kind: 'tap-lost'"; do
  assert grep -qF "$g" "$ROOT/share/pages/app/app.js"
done
assert "$PY" -c 'import re, sys
bad = []
for path in sys.argv[1:]:
    stack, buf = [], ""
    for ch in re.sub(r"/\*.*?\*/", "", open(path).read(), flags=re.S):
        if ch == "{":
            sel = buf.strip(); stack.append(sel); buf = ""
            if ":hover" in sel and not sel.startswith("@") and "@media (hover: hover)" not in stack[:-1]: bad.append(sel)
        elif ch in "};": buf = ""; ch == "}" and stack and stack.pop()
        else: buf += ch
sys.exit("hover outside @media (hover: hover): %s" % bad if bad else 0)' "$ROOT/share/pages/app/app.css" "$ROOT/share/pages/kit/ui.css"
assert grep -q 'touch-action: manipulation' "$ROOT/share/pages/app/app.css"
# Egor 2026-11-08: a message on its way vanished when an update reloaded the app (the outbox is kept); the voice
# pill's buttons live inside the composer, no bar of their own; a take stays in sight above a page or a sheet.
assert grep -qF "keep('outbox'" "$ROOT/share/pages/app/app.js"
assert test -z "$(grep -n 'micbar' "$ROOT/share/pages/app/index.html" "$ROOT/share/pages/app/app.js")"
assert "$PY" -c 'import re, sys
html = open(sys.argv[1]).read()
form = html[html.index("<form id=\"composer\">"):html.index("</form>")]
sys.exit(not ("id=\"waveb\"" in form and "id=\"lost\"" in form and "id=\"takepill\"" in html))' "$ROOT/share/pages/app/index.html"
assert "$PY" -c 'import re, sys
css = open(sys.argv[1]).read()
z = lambda sel: int(re.search(re.escape(sel) + r" \{[^}]*z-index: (\d+)", css).group(1))
sys.exit(not z("#takepill") > max(z("#overlay"), z("#close")))' "$ROOT/share/pages/app/app.css"
# MacMic: while it streams a tap records it and never asks the page's microphone (which would interrupt it); a
# refusal links to it.
assert "$PY" -c 'import sys
js = open(sys.argv[1]).read()
start = js[js.index("async function micStart() {"):]
sys.exit(not (start.index("micMacMic()") < start.index("getUserMedia") and "href=\"macmic://open\"" in js))' "$ROOT/share/pages/app/app.js"
# No window of its own in the Home Screen app (WebKit bug 329593: one costs the microphone until SafariViewService
# ends): its links go to Safari (x-safari-), a tab keeps target=_blank, and a refusal there offers the restart.
assert "$PY" -c 'import sys
js = open(sys.argv[1]).read()
link = js[js.index("const outLink"):js.index("function inline(")]
sys.exit(not (js.count("_blank") == 1 and "_blank" in link and "STANDALONE ? `<a href=\"x-safari-${url}\">" in link
  and "window.open" not in js and "STANDALONE && MIC.refused === \x27refused\x27" in js and "data-webreset" in js))' "$ROOT/share/pages/app/app.js"

echo "PASS: $asserts asserts; test_pages_app.sh: client + manifest, LAN cookie, live registry (pid+procStart, tty, env account, worker split), chat-find/warm/load join, transcript items and offsets (torn line held back), send as one bracketed paste to the chat's tty, keys and menu choice, mic relay (remote take, packets, padding, deliver file, one stop, guarded cancel, the pill mirrored: bubble, usealt, restore from idle and over a take, MacMic: kept streaming, woken, a take on its stream with no packets of ours), https origin, screen and its capped scrollback, menu mirror, load rows, pages, worker runs (row ar liveness, horizon, exit code, pid 0), queued and mid-turn messages, queue take-back (Up, clears, backslash, kept ones re-pasted in order), a line longer than the read window, Earlier blocks of 12 items, past chats (history newest first, search on chat-find with an uncached failure, open live/past/failed/bad id, end: worker 404, busy 409, no exit 504 keeps the window, exit closes a one-tab window), info panel (full statusline runs, changed files, incremental), capped failure logs, no LLM / settings / hooks, one visible-only 1 s poll, taps (redraws on change only, no touch hover, tap-lost), the tail reaching back to speech, a queued paste shown, the outbox kept, the voice pill's buttons in the composer, the take pill above a page, MacMic first, a refusal linking to it, what a chat runs (its tree, ports, a stop of its own only, a forced end), a chat's menu (rename live/closed, branch (its parent's history up to its start until its own), trash and its undo, a busy or unended one refused), Earlier's project and hash"
