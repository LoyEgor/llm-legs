#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" LLM_LIMITS_CACHE="$WORK/limits.json"
mkdir -p "$HOME"
. "$ROOT/share/account-status-tui.sh"
asserts=0
assert() { asserts=$((asserts + 1)); "$@" || { printf 'FAIL: assert %s: %s\n' "$asserts" "$*" >&2; exit 1; }; }
accounts_vendor=codex
accounts_store_vendor=codex
accounts_rows=account_status_rows
accounts_now=fixture_now
accounts_pick_resolver=fixture_pick_cmd
accounts_live_probe=''
accounts_live_age=''
accounts_refresh_action=fixture_refresh
accounts_refresh_summary=fixture_outcome
accounts_mode=cached
fixture_now() { printf 1800000000; }
fixture_pick_cmd() { printf '%s/pick' "$WORK"; }
fixture_refresh() { printf '%s' "$2" >"$WORK/refreshed"; printf 'probe error\n' >&2; }
fixture_outcome() { printf 'fixture refreshed'; }
printf '#!/usr/bin/env bash\n[ "$*" = "--account codex --role chat" ] || exit 2\nprintf beta\n' >"$WORK/pick"
chmod +x "$WORK/pick"
cat >"$LLM_LIMITS_CACHE" <<'JSON'
{"vendors":{"codex":{"accounts":[
 {"account":"gamma","enabled":false,"five_hour":{"used_pct":90,"resets_at":1799999000,"as_of":1799996000},"weekly":{"used_pct":null}},
 {"account":"alpha","five_hour":{"used_pct":40,"resets_at":1800003600,"as_of":1799999900},"weekly":{"used_pct":20,"as_of":1799999940}},
 {"account":"beta","five_hour":{"used_pct":25,"as_of":1799999900},"weekly":{"used_pct":15,"as_of":1799999940}}
]}}}
JSON
accounts_reselect
assert test "$accounts_picked" = beta
assert test "$accounts_show_fable" = false
assert jq -e '.data[] | select(.name == "gamma") | .disabled and .h5_eff == 0 and .h5_stale and .h5_expired and .wk_eff == null' <<<"$accounts_result" >/dev/null
assert jq -e '.data[] | select(.name == "alpha") | .age == 100 and .h5_eff == 40 and (.h5_dim | not)' <<<"$accounts_result" >/dev/null
loop() (
  accounts_picked="$2"
  interactive_accounts <<<"$1"
  accounts_refresh_kill
  printf 'LAUNCH=%s\n' "$accounts_launch"
)
out=$(loop $'\n' beta)
assert grep -qF $'\033[7m* beta' <<<"$out"
assert grep -q '^LAUNCH=beta$' <<<"$out"
assert test "${out#*FABLE}" = "$out"
assert grep -qF '0%~!' <<<"$(render_interactive_accounts 0 name)"
out=$(loop $'\n' '')
assert grep -q '^LAUNCH=alpha$' <<<"$out"
out=$(loop $'\n' absent)
assert grep -q '^LAUNCH=alpha$' <<<"$out"
out=$(loop $'\033[B\n' beta)
assert grep -q '^LAUNCH=gamma$' <<<"$out"
out=$(loop $'\033[A\n' beta)
assert grep -q '^LAUNCH=alpha$' <<<"$out"
out=$(loop $'\033[C\033[D\n' beta)
assert grep -q '^LAUNCH=beta$' <<<"$out"
for keys in q $'\033' $'\003'; do
  out=$(loop "$keys" beta)
  assert grep -q '^LAUNCH=$' <<<"$out"
done
accounts_result='{"data":[]}'
out=$(loop $'\nq' beta)
assert grep -q '^LAUNCH=$' <<<"$out"
accounts_reselect
accounts_refresh_pid=''; accounts_refresh_dir=''; accounts_probe_dir=''
accounts_refresh_start beta >"$WORK/terminal" 2>&1
wait "$accounts_refresh_pid"
assert test -e "$accounts_refresh_dir/.done"
assert test "$(cat "$WORK/refreshed")" = beta
assert grep -q 'probe error' "$accounts_refresh_dir/probe.log"
assert test "$(cat "$WORK/terminal")" = ""
accounts_refresh_finish
assert test "$accounts_status_line" = 'fixture refreshed'
rm -rf "$accounts_probe_dir"
accounts_probe_dir=''
accounts_store_vendor=claude
jq '.vendors.claude = .vendors.codex | .vendors.claude.accounts[0].fable = {used_pct:22,as_of:1799999900}' "$LLM_LIMITS_CACHE" >"$WORK/next.json"
mv "$WORK/next.json" "$LLM_LIMITS_CACHE"
accounts_reselect
assert test "$accounts_show_fable" = true
assert grep -q FABLE <<<"$(render_interactive_accounts 0 name)"

# account_status_show runs on a real pty: the CALLER's rows function serves both renders (claudeb
# builds rows from its own store, not ~/.llm-limits.json), and a terminal without a usable TERM
# takes the plain path instead of blocking in the picker.
cat >"$WORK/show.sh" <<EOF
set -u
. "$ROOT/share/account-status-tui.sh"
accounts_vendor=codex
accounts_store_vendor=codex
accounts_rows=caller_rows
accounts_now=fixture_now
accounts_pick_resolver=fixture_pick_cmd
accounts_live_probe=''
accounts_plain=fixture_plain
accounts_launch_hook=:
fixture_now() { printf 1800000000; }
fixture_pick_cmd() { printf '%s/pick' "$WORK"; }
caller_rows() { printf 'ROWS=caller\n' >&2; printf '{"data":[]}'; }
fixture_plain() { printf 'PLAIN\n'; }
interactive_accounts() { printf 'INTERACTIVE\n'; return 0; }
account_status_show cached false
EOF
cat >"$WORK/run-pty.py" <<'PY'
import os, pty, select, signal, sys, time
pid, master = pty.fork()
if pid == 0:
    os.execvp('bash', ['bash', sys.argv[1]])
out = bytearray()
deadline = time.monotonic() + 20
while time.monotonic() < deadline:
    if not select.select([master], [], [], 0.1)[0]:
        continue
    try:
        chunk = os.read(master, 65536)
    except OSError:
        break
    if not chunk:
        break
    out.extend(chunk)
else:
    os.kill(pid, signal.SIGKILL)
os.waitpid(pid, 0)
sys.stdout.buffer.write(bytes(out))
PY
show_pty() { TERM="$1" python3 "$WORK/run-pty.py" "$WORK/show.sh"; }
out=$(show_pty xterm-256color)
assert grep -q 'ROWS=caller' <<<"$out"
assert grep -q INTERACTIVE <<<"$out"
assert test "${out#*PLAIN}" = "$out"
out=$(show_pty dumb)
assert grep -q 'ROWS=caller' <<<"$out"
assert grep -q PLAIN <<<"$out"
assert test "${out#*INTERACTIVE}" = "$out"

printf 'PASS: %s asserts; shared account picker keys, initial selection, limits view, async refresh and the show entry point (caller rows in both renders, TERM-aware interactive path)\n' "$asserts"
