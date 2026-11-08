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
wsid=99999999-2222-3333-4444-555555555555

# A live "chat": a process on a pty (script(1) gives it a tty) with its account in its environment; a worker: the
# same with no tty. Python, not sleep: `ps -E` shows no environment of an Apple platform binary.
PY=$(python3 -c 'import sys; print(sys.executable)')
env -u CLAUDEGPT_ACCOUNT CLAUDE_LIMITS_ACCOUNT=fixacct script -q /dev/null "$PY" -c 'import time; time.sleep(300)' </dev/null >/dev/null 2>&1 &
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
printf '[{"session": "%s", "name": "Fixture chat", "path": "%s", "ctx": 42000, "model": "claude-opus-5-5", "spoke": %s, "ttl": 3600, "cwd": "/x/proj"}]' \
  "$sid" "$T" "$(date +%s)" >"$WORK/chat-find.json"
printf 'print(open("%s").read())\n' "$WORK/chat-find.json" >"$WORK/bin/chat-find"  # run by the server's python
printf 'v2 %s fixacct\n' "$(date +%s)" >"$WORK/tracks/cache-ttl-track-$sid"
printf '{"title": "Chats/other  1.0/2.0 cores", "rows": [{"text": "CPU   1.0 chats +  2.0 other =  3.0 of 10 cores"}, "-", {"text": "full speed  Fixture chat           1.0 cores   2.5 GB  ▁▂▃", "session": "%s", "pid": %s}]}' \
  "$sid" "$chatpid" >"$WORK/chats.json"

# The stub hs: the menubar, a screen with a menu on it (❯ on option 1), and every `do script` with the pasted
# file's text copied out before the server deletes it.
cat >"$WORK/bin/hs" <<EOF
#!/usr/bin/env python3
import json, os, re, sys
lua = sys.argv[sys.argv.index("-c") + 1]
with open("$WORK/hs.log", "a") as log:
    log.write(lua.replace("\\n", " ") + "\\n")
    m = re.search(r'read POSIX file "([^"]+)"', lua)
    if m:
        log.write("TEXT=" + json.dumps(open(m.group(1), encoding="utf-8").read(), ensure_ascii=False) + "\\n")
if "llm-limits" in lua:
    print(json.dumps({"items": [{"r": [{"t": "Routing: next fixacct"}], "sub": [{"r": [{"t": "row", "c": "e64033", "a": 1}]}]}, {"sep": True}]}))
elif "return contents of tab" in lua and os.path.exists("$WORK/screen-fails"):
    print(json.dumps({"ok": False, "err": "Terminal timed out"}))
elif "return contents of tab" in lua:
    print(json.dumps({"ok": True, "res": "Pick a color\\n\\u276f 1. Red\\n  2. Green\\n  3. Blue\\nEnter to select"}))
else:
    print(json.dumps({"ok": True, "res": "sent"}))
EOF
chmod +x "$WORK/bin/hs"
# The stub transcriptions-gpt: its control socket (status, remote-start, stop, cancel, and `stats` for this test)
# and a UDP receiver counting the relayed audio packets; a stop writes the take's text to the deliver path.
cat >"$WORK/bin/daemon-stub" <<'STUB'
import json, os, socket, struct, sys, threading, time
rt, log = sys.argv[1], sys.argv[2]
st = {"state": "idle", "deliver": None, "packets": 0, "marked": 0, "silent": 0, "gaps": 0, "streams": []}
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
def finish():
    time.sleep(0.3)
    with open(st["deliver"], "w") as f:
        f.write("текст с iPad")
    st["state"] = "idle"
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
        else:
            st["deliver"], st["state"], reply = json.loads(arg)["deliver"], "recording", "ok"
    elif verb == "stop" and st["state"] == "recording":
        st["state"], reply = "processing", "ok"
        threading.Thread(target=finish, daemon=True).start()
    elif verb == "cancel":
        st["state"], reply = "idle", "ok"
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
  APP_MIC_PORT="$(cat "$RT/udp-port")" WORKER_RUN_DIR="$WORK/runs"

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
} >>"$T"
assert test "$(get "$base/api/chat/$sid/log?after=$whole")" = 200
assert test "$(jq -c '[.items[] | [.k, .t, .op, .at, .mid, .hide]]' "$WORK/body")" \
  = '[["asst","torn",null,"",null,null],["queued","check the scroll",null,"t5",null,false],["queued","",null,"",null,true],["unqueued","check the scroll","remove","t6",null,false],["user","check the scroll",null,"t5",true,null],["unqueued","","dequeue","",null,true]]'

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
assert test "$(post /api/mic/start '{}')" = 409
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
# Behind `tailscale serve` the page's origin is https.
assert test "$(post "/api/chat/$sid/key" '{"key": "esc"}' -H "Origin: https://127.0.0.1:$port")" = 200

# The screen, the menubar mirror, pages.
assert test "$(get "$base/api/chat/$sid/screen")" = 200
assert like "$(jq -r .res "$WORK/body")" "Pick a color*"
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

# It costs Claude Code nothing: no model call, no settings or hooks touched; the only programs it runs are ps,
# Hammerspoon and chat-find, and the client polls only while it is on screen, at most once a second.
assert test -z "$(grep -nE 'anthropic|openai|claude -p|settings\.json|hooks' "$ROOT/share/pages/app.py")"
assert test "$(grep -oE 'run\(\[[^],]+' "$ROOT/share/pages/app.py" | sort -u | tr '\n' ' ')" = 'run(["ps" run([HS run([sys.executable '
assert test "$(grep -c 'setInterval(' "$ROOT/share/pages/app/app.js")" = 1
assert "$PY" -c 'import sys
sys.exit("if (document.visibilityState !== \x27visible\x27) return;\n  tick++;" not in open(sys.argv[1]).read())' "$ROOT/share/pages/app/app.js"
assert test "$(grep -c '^}, 1000);$' "$ROOT/share/pages/app/app.js")" = 1

echo "PASS: $asserts asserts; test_pages_app.sh: client + manifest, LAN cookie, live registry (pid+procStart, tty, env account, worker split), chat-find/warm/load join, transcript items and offsets (torn line held back), send as one bracketed paste to the chat's tty, keys and menu choice, mic relay (remote take, packets, padding, deliver file, one stop, guarded cancel), https origin, screen, menu mirror, pages, worker runs (row ar liveness, horizon, exit code, pid 0), queued and mid-turn messages, capped failure logs, no LLM / settings / hooks, one visible-only 1 s poll"
