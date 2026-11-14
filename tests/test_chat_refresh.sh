#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# bin/chat-refresh on a private tmux socket (CHAT_TMUX_SOCKET) and a fixture HOME (its session registry): fake chats
# record their argv; a safe one is resumed in its own pane with its account and model, each other one is skipped
# with its word. The real server, registry and chats are never touched.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/bin/chat-refresh"
. "$ROOT/tests/lib/fake-chats.sh" chat-refresh
refresh() { "$PY" -B "$TOOL" "$@"; }

SAFE=11111111-1111-4111-8111-111111111111
BUSY=22222222-2222-4222-8222-222222222222
WORKER=33333333-3333-4333-8333-333333333333
TASKS=44444444-4444-4444-8444-444444444444
DRAFT=55555555-5555-4555-8555-555555555555
ASK=66666666-6666-4666-8666-666666666666
TERM_ONLY=77777777-7777-4777-8777-777777777777
CLOSED=88888888-8888-4888-8888-888888888888
EMPTY=99999999-9999-4999-8999-999999999999

read -r safe_pane safe_tty < <(open_chat $SAFE)
read -r busy_pane _ < <(open_chat $BUSY)
read -r worker_pane _ < <(open_chat $WORKER)
read -r tasks_pane _ < <(open_chat $TASKS)
read -r draft_pane _ < <(open_chat $DRAFT)
read -r ask_pane _ < <(open_chat $ASK)
open_chat $EMPTY bare >/dev/null
# A Terminal-tab chat: no pane of the chats' tmux (closing its tab would end it).
(perl -e 'sleep 600' "$WORK/hold" | CLAUDE_CONFIG_DIR="$HOME/.claude-profiles/acct1" "$WORK/bin/claude" --resume $TERM_ONLY >/dev/null) 2>/dev/null &
disown
until_ok registered "$TERM_ONLY" || fail "the Terminal chat did not register"

set_field $BUSY status '"busy"'
send "$worker_pane" "spawn:bash $WORK/bin/worker-run wait run-1"
send "$tasks_pane" "spawn:perl -e 'sleep 600' $WORK/task"
send "$draft_pane" "draft:half a message"
send "$ask_pane" "ask"
# Claude Code's own helper (a hook's sleeper) holds nothing: the safe chat runs one.
send "$safe_pane" "spawn:$HOME/.claude/hooks/keepalive.sh"
until_ok pgrep -f "worker-run wait run-1" >/dev/null || fail "the worker wait did not start"
until_ok pgrep -f "keepalive.sh" >/dev/null || fail "the hook helper did not start"
until_ok grep -q 'half a message' <(helper capture "$draft_pane") || fail "the draft did not show"
until_ok grep -q 'proceed' <(helper capture "$ask_pane") || fail "the question did not show"
safe_old=$(pid_of $SAFE)

# A dry run says what it would do and touches nothing.
out=$(refresh --all --dry-run)
assert grep -q "^11111111  would refresh [0-9]* MB: cd '$WORK/proj' && $WORK/bin/claudeb profile acct1 --resume $SAFE --model opus --permission-mode bypassPermissions$" <<<"$out"
assert grep -q '^would refresh 1, skipped 7$' <<<"$out"
assert [ "$(pid_of $SAFE)" = "$safe_old" ]
assert [ "$(wc -l <"$HOME/argv.log")" -eq 8 ]

# Each chat that is not at rest is skipped with its word; a closed one too.
out=$(refresh --all)
assert grep -q '^22222222  skipped busy$' <<<"$out"
assert grep -q '^33333333  skipped worker$' <<<"$out"
assert grep -q '^44444444  skipped tasks$' <<<"$out"
assert grep -q '^55555555  skipped draft$' <<<"$out"
assert grep -q '^66666666  skipped asking$' <<<"$out"
assert grep -q '^77777777  skipped terminal$' <<<"$out"
assert grep -q '^99999999  skipped empty$' <<<"$out"
assert grep -q '^11111111  refreshed [0-9]* -> [0-9]* MB$' <<<"$out"
assert grep -qE '^refreshed 1, skipped 7, -?[0-9]+ MB freed$' <<<"$out"

# The safe chat: ended (/exit), resumed in the same pane and tty, on the same account, model and mode.
safe_new=$(pid_of $SAFE)
assert [ -n "$safe_new" ]
refute [ "$safe_new" = "$safe_old" ]
refute kill -0 "$safe_old" 2>/dev/null
last=$(grep "\"pid\": $safe_new" "$HOME/argv.log")
assert [ "$("$PY" -c 'import json,sys; print(" ".join(json.loads(sys.argv[1])["argv"]))' "$last")" = \
  "--resume $SAFE --model opus --permission-mode bypassPermissions" ]
assert [ "$("$PY" -c 'import json,sys; print(json.loads(sys.argv[1])["config"])' "$last")" = "$HOME/.claude-profiles/acct1" ]
assert [ "$("$PY" -c 'import json,sys; print(json.loads(sys.argv[1])["tty"])' "$last")" = "$safe_tty" ]
assert [ "$(helper pane "$safe_tty")" = "$safe_pane" ]
# Nothing was typed into a live chat as a message (the resume line goes only to the pane's shell).
refute grep -qs -- '--resume' "$HOME/typed.log"
# The skipped chats run on as they were.
for sid in $BUSY $WORKER $TASKS $DRAFT $ASK $TERM_ONLY $EMPTY; do
  assert kill -0 "$(pid_of $sid)"
done
assert [ "$(grep -c "\"$BUSY\"" "$HOME/argv.log")" -eq 1 ]

# Named chats: a prefix picks one, an id that runs nowhere is closed; --night skips a chat under a day old and one
# under 400 MB.
out=$(refresh 22222222 $CLOSED)
assert grep -q '^22222222  skipped busy$' <<<"$out"
assert grep -q '^88888888  skipped closed$' <<<"$out"
assert grep -q '^refreshed 0, skipped 2$' <<<"$out"
set_field $BUSY status '"idle"'
out=$(refresh --night --dry-run)
assert grep -q '^22222222  skipped young$' <<<"$out"
set_field $BUSY startedAt "$(( ($(date +%s) - 2 * 86400) * 1000 ))"
out=$(refresh --night --dry-run)
assert grep -q '^22222222  skipped light$' <<<"$out"

# A second run while one holds the lock refreshes nothing.
perl -e 'use Fcntl ":flock"; open(my $f, ">", $ARGV[0]); flock($f, LOCK_EX); sleep 5' "$WORK/s/refresh.lock" &
locker=$!
perl -e 'select(undef,undef,undef,0.3)'
out=$(refresh --all; echo "rc=$?")
assert grep -q '^chat-refresh: another run is refreshing chats$' <<<"$out"
assert grep -q '^rc=1$' <<<"$out"
kill "$locker" 2>/dev/null

printf 'test_chat_refresh: %d asserts PASS\n' "$asserts"
