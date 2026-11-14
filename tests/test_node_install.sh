#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# bin/node-install: a first run puts a module in place, a second changes nothing and says so, a dry run lists each
# difference and writes nothing, and a link whose source is missing fails loudly. A fixture HOME and manifest; the
# real manifest is only read (dry run).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
unset NODE_CONFIG
mkdir -p "$HOME" "$WORK/root/proj/bin"
printf '#!/bin/sh\necho tool\n' >"$WORK/root/proj/bin/tool"
chmod +x "$WORK/root/proj/bin/tool"
asserts=0
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
check() { asserts=$((asserts + 1)); "$@" || fail "line ${BASH_LINENO[0]}: $*"; }
has() { grep -qF -- "$2" <<<"$1"; }

cat >"$WORK/manifest.json" <<'EOF'
{"binaries": {"sh": {"min": "0", "version": ["-c", "echo 1.0"]}, "nosuch-cli": {"min": "1.0"}},
 "modules": {
  "one": {"requires": ["sh"], "optional": ["nosuch-cli"],
          "links": {".local/bin/tool": "proj/bin/tool", ".claude/tool-again": "~/.local/bin/tool"},
          "settings": {"statusLine": {"type": "command", "command": "~/x"}},
          "hooks": [["Stop", "", "{root}/proj/bin/tool stop", {"timeout": 5}], ["PreToolUse", "Bash", "~/y"]]},
  "broken": {"links": {".local/bin/gone": "proj/bin/gone"}}}}
EOF
export NODE_MANIFEST="$WORK/manifest.json"
mkdir -p "$HOME/.claude"
printf '{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "~/kept"}]}]}, "model": "opus"}\n' \
  >"$HOME/.claude/settings.json"

dry=$("$ROOT/bin/node-install" --dry-run --modules one --root "$WORK/root" --name fixture); rc=$?
check test "$rc" -eq 1
check has "$dry" "node fixture: root $WORK/root, modules one"
check has "$dry" "5 of 7 items differ:"
check has "$dry" "link ~/.local/bin/tool: missing"
check has "$dry" "hook PreToolUse Bash ~/y: not in settings.json"
check has "$dry" "optional, absent: nosuch-cli not installed"
check test ! -e "$HOME/.local/bin/tool"
check test ! -e "$HOME/.config/llm-legs/node.json"

first=$("$ROOT/bin/node-install" --modules one --root "$WORK/root" --name fixture); rc=$?
check test "$rc" -eq 0
check has "$first" "did 6: wrote ~/.config/llm-legs/node.json; settings.json: statusLine set;"
check has "$first" "; linked 1 in ~/.local/bin; linked 1 in ~/.claude"
check test "$(readlink "$HOME/.local/bin/tool")" = "$WORK/root/proj/bin/tool"
check test "$("$HOME/.claude/tool-again")" = tool
check jq -e --arg c "$WORK/root/proj/bin/tool stop" '.model == "opus" and .statusLine.command == "~/x"
  and ([.hooks.Stop[].hooks[].command] == ["~/kept", $c]) and .hooks.Stop[0].hooks[1].timeout == 5
  and .hooks.PreToolUse[0].matcher == "Bash"' "$HOME/.claude/settings.json"
check jq -e --arg r "$WORK/root" '. == {"name": "fixture", "root": $r, "modules": ["one"]}' \
  "$HOME/.config/llm-legs/node.json"

# The second run reads node.json alone and changes nothing.
before=$(cksum <"$HOME/.claude/settings.json")
second=$("$ROOT/bin/node-install"); rc=$?
check test "$rc" -eq 0
check has "$second" "nothing to do: 7 items in place"
check test "$(cksum <"$HOME/.claude/settings.json")" = "$before"
again=$("$ROOT/bin/node-install" --dry-run); rc=$?
check test "$rc" -eq 0
check has "$again" "0 of 7 items differ"

# A real file where a link goes is kept aside, never overwritten.
rm "$HOME/.local/bin/tool"
printf 'mine\n' >"$HOME/.local/bin/tool"
moved=$("$ROOT/bin/node-install")
check has "$moved" "the old one kept as ~/.local/bin/tool.before-node-install"
check test "$(cat "$HOME/.local/bin/tool.before-node-install")" = mine

# A source that is missing is a failure, not a quiet skip.
broken=$("$ROOT/bin/node-install" --modules one,broken 2>"$WORK/err"); rc=$?
check test "$rc" -eq 1
check grep -qF "FAILED link ~/.local/bin/gone: its source $WORK/root/proj/bin/gone is missing" "$WORK/err"
check test ! -e "$HOME/.local/bin/gone"

# The real manifest is well formed, and a dry run of an empty HOME lists its links without writing one.
unset NODE_MANIFEST
check python3 -c 'import json, sys; m = json.load(open(sys.argv[1])); assert all(set(x) <= {"requires", "optional",
  "links", "hooks", "settings", "builds", "deploys", "shell_path"} for x in m["modules"].values())' \
  "$ROOT/share/node-manifest.json"
mv "$HOME" "$WORK/home-used" && mkdir -p "$HOME"
real=$("$ROOT/bin/node-install" --dry-run --modules accounts,limits --root "$WORK/root" --name fixture); rc=$?
check test "$rc" -eq 1
check has "$real" "link ~/.local/bin/claudeb: its source $WORK/root/llm-legs/bin/claudeb is missing"
check has "$real" "link ~/.local/bin/claude-relogin: its source $WORK/root/llm-legs/bin/claude-relogin is missing"
check test -z "$(ls -A "$HOME")"

# --to: every ssh call of the run rides one master opened in a private 0700 dir and closed at the end
# (share/ssh-mux.sh), so a run never trips sshd's MaxStartups by itself; a banner timeout opening it is retried once.
cat >"$WORK/ssh" <<'EOF'
#!/usr/bin/env bash
path='' verb='' open=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) case "$2" in ControlPath=*) path=${2#ControlPath=} ;; esac; shift 2 ;;
    -O) verb=$2; shift 2 ;;
    -f) open=true; shift ;;
    -*) shift ;;
    *) break ;;
  esac
done
printf '%s\n' "${path:--}" >>"$SSH_LOG.paths"
if [ -n "$verb" ]; then printf '%s\n' "$verb" >>"$SSH_LOG"; exit 0; fi
if $open; then
  printf 'open %s\n' "$(stat -f %Lp "${path%/*}")" >>"$SSH_LOG"
  [ "$(grep -c '^open' "$SSH_LOG")" -gt "${STUB_BANNER:-0}" ] ||
    { printf 'Connection timed out during banner exchange\n' >&2; exit 255; }
  exit 0
fi
case "$2" in
  *'print -r -- "$HOME"'*) printf 'probe\n' >>"$SSH_LOG"; printf '/nodehome\n' ;;
  *node-install*) printf 'install\n' >>"$SSH_LOG"; printf 'node mac-x: the dry run there\n' ;;
esac
EOF
chmod +x "$WORK/ssh"
there=$(SSH_LOG="$WORK/ssh.log" NODE_INSTALL_SSH="$WORK/ssh" STUB_BANNER=1 \
  "$ROOT/bin/node-install" --to mac-x --host u@h --modules core --dry-run 2>"$WORK/err"); rc=$?
check test "$rc" -eq 0
check has "$there" "the dry run there"
check test "$(paste -sd' ' - <"$WORK/ssh.log")" = "open 700 open 700 probe install exit"
check test "$(sort -u "$WORK/ssh.log.paths" | wc -l | tr -d ' ')" = 1
mux_path=$(head -n 1 "$WORK/ssh.log.paths")
check test "$mux_path" != -
check test ! -e "${mux_path%/*}"

printf 'PASS: node-install dry run, first run, idempotent second run, kept-aside file, missing source fails, one ssh connection per --to run (%d asserts)\n' "$asserts"
