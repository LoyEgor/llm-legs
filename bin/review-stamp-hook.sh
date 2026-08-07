#!/usr/bin/env bash
# PostToolUse(Bash): stamp the tree as reviewed after the commit that carries a review's fixes.
#
# Without this the review label never goes out: a panel reviews the code, the fixes it provoked
# change the tree, and the label lights again for the fixes, forever. The commit gate already names
# the end of that cycle — a triaged review buys a ticket recording the exact content the passing
# commit carries — so the whole judgement is `reviewed --ticket` and this is only its trigger.
#
# Fail-open everywhere: a hook that cannot tell stays silent and leaves the label lit.
set -u

# One jq for the whole payload: this runs after every Bash call in every session, and three
# more interpreter starts per call buy nothing.
input=$(cat) || exit 0
values=$(printf '%s' "$input" | jq -r '
  [(.hook_event_name // ""), (.tool_name // ""), (.cwd // ""), (.tool_input.command // "")]
  | join("\u001f")' 2>/dev/null) || exit 0
# -d '': a commit command is routinely a heredoc, and a plain read would stop at its first line.
IFS=$'\x1f' read -r -d '' hook_event tool_name cwd command <<< "$values" || :

[ "$hook_event" = PostToolUse ] || exit 0
[ "$tool_name" = Bash ] || exit 0
# Substring, not a parse of the command line: `git -C x commit`, `git commit -F -` and a commit
# behind `&&` all read the same here, and the ticket check refuses everything that is not one.
case "$command" in *commit*) ;; *) exit 0 ;; esac
[ -n "$cwd" ] || exit 0
top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0

# ~/.claude/hooks is itself a symlink into the config repository, and the entry there is a
# symlink into this one; a chain is the normal case, so follow it rather than the first hop.
self="$0"
for _ in 1 2 3 4 5; do
  [ -L "$self" ] || break
  target=$(readlink "$self")
  case "$target" in /*) self="$target" ;; *) self="$(dirname "$self")/$target" ;; esac
done
review_bench="${REVIEW_STAMP_HOOK_BENCH:-$(dirname "$self")/review-bench}"
[ -x "$review_bench" ] || exit 0

"$review_bench" reviewed --repo "$top" --ticket >/dev/null 2>&1
exit 0
