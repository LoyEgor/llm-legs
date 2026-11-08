#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# share/pages/app.py (the chats app on bin/page) against share/pages/CONTRACT.md "App": a temp PAGES_DIR, a
# fixture session registry, a stub `hs` and chat-find, port 0. Never the real Terminal, menubar or ~/Pages.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(cd -P "$(mktemp -d)" && pwd)"
trap 'kill $(jobs -p) 2>/dev/null; [ -n "${chatpid:-}" ] && kill "$chatpid" 2>/dev/null; rm -rf "$WORK"' EXIT
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
import json, re, sys
lua = sys.argv[sys.argv.index("-c") + 1]
with open("$WORK/hs.log", "a") as log:
    log.write(lua.replace("\\n", " ") + "\\n")
    m = re.search(r'read POSIX file "([^"]+)"', lua)
    if m:
        log.write("TEXT=" + json.dumps(open(m.group(1), encoding="utf-8").read(), ensure_ascii=False) + "\\n")
if "llm-limits" in lua:
    print(json.dumps({"items": [{"r": [{"t": "Routing: next fixacct"}], "sub": [{"r": [{"t": "row", "c": "e64033", "a": 1}]}]}, {"sep": True}]}))
elif "return contents of tab" in lua:
    print(json.dumps({"ok": True, "res": "Pick a color\\n\\u276f 1. Red\\n  2. Green\\n  3. Blue\\nEnter to select"}))
else:
    print(json.dumps({"ok": True, "res": "sent"}))
EOF
chmod +x "$WORK/bin/hs"
export PAGES_DIR="$WORK/pages" APP_SESSIONS="$WORK/sessions" APP_HS="$WORK/bin/hs" APP_CHAT_FIND="$WORK/bin/chat-find" \
  APP_CHATS_JSON="$WORK/chats.json" STATUSLINE_CACHE_DIR="$WORK/tracks"

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

# The screen, the menubar mirror, pages.
assert test "$(get "$base/api/chat/$sid/screen")" = 200
assert like "$(jq -r .res "$WORK/body")" "Pick a color*"
assert test "$(get "$base/api/menu")" = 200
assert test "$(jq -r '.items[0].sub[0].r[0].c' "$WORK/body")" = e64033
assert test "$(get "$base/api/pages")" = 200
assert test "$(jq -r '.pages | length' "$WORK/body")" = 0

echo "PASS: $asserts asserts; test_pages_app.sh: client + manifest, LAN cookie, live registry (pid+procStart, tty, env account, worker split), chat-find/warm/load join, transcript items and offsets (torn line held back), send as one bracketed paste to the chat's tty, keys and menu choice, screen, menu mirror, pages"
