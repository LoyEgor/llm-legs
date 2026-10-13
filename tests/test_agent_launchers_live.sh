#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# A relay agent spells its launcher as a bare word, so a rename that leaves no link in
# ~/.local/bin fails only inside the agent, as `command not found`, and no fixture suite sees it.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS=${CLAUDE_AGENTS_DIR:-$HOME/.claude/agents}
LINKS=${LOCAL_BIN_DIR:-$HOME/.local/bin}
HOOKS=${CLAUDE_HOOKS_DIR:-$HOME/.claude/hooks}
if [ ! -d "$AGENTS" ] || [ ! -d "$LINKS" ]; then
  echo "SKIP: no agents or no $LINKS on this machine"
  exit 0
fi

pass=0 fail=0
agents=$(cat "$AGENTS"/*.md 2>/dev/null)
for bin in "$ROOT"/bin/*; do
  name=${bin##*/}
  [ -f "$bin" ] && [ -x "$bin" ] || continue
  [[ $agents =~ (^|[^[:alnum:]_])"$name"([^[:alnum:]_]|$) ]] || continue
  [ -x "$HOOKS/$name" ] && [ ! -e "$LINKS/$name" ] && continue
  if [ -x "$LINKS/$name" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: an agent names \`$name\` and $LINKS/$name does not resolve"
  fi
done
while IFS= read -r link; do
  if [ -e "$link" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: $link points at a file this repository no longer has"
  fi
done < <(find -H "$LINKS" -mindepth 1 -maxdepth 1 ! -name '.*' -type l -lname "$ROOT/*" | sort)
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
