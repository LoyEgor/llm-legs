#!/usr/bin/env bash
# A relay agent spells its launcher as a bare word, so a rename that leaves no link in
# ~/.local/bin fails only inside the agent, as `command not found`, and no fixture suite sees it.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS=${CLAUDE_AGENTS_DIR:-$HOME/.claude/agents}
LINKS=${LOCAL_BIN_DIR:-$HOME/.local/bin}
if [ ! -d "$AGENTS" ] || [ ! -d "$LINKS" ]; then
  echo "SKIP: no agents or no $LINKS on this machine"
  exit 0
fi

pass=0 fail=0
for bin in "$ROOT"/bin/*; do
  name=$(basename "$bin")
  [ -f "$bin" ] && [ -x "$bin" ] || continue
  grep -qw -- "$name" "$AGENTS"/*.md 2>/dev/null || continue
  if [ -x "$LINKS/$name" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: an agent names \`$name\` and $LINKS/$name does not resolve"
  fi
done
for link in "$LINKS"/*; do
  [ -L "$link" ] || continue
  case "$(readlink "$link")" in "$ROOT"/*) ;; *) continue ;; esac
  if [ -e "$link" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: $link points at a file this repository no longer has"
  fi
done
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
