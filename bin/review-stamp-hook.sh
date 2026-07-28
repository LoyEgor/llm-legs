#!/usr/bin/env bash
# PostToolUse(Bash): stamp the tree as reviewed after the commit that carries a review's fixes.
#
# Without this the review label never goes out: a panel reviews the code, the fixes it provoked
# change the tree, and the label lights again for the fixes, forever. The one moment a machine
# can recognise the end of that cycle is a commit whose PARENT tree is exactly the reviewed one,
# made while a review that found something still stands as this repository's receipt. That is the
# fix commit and nothing else — new work sits on top of a later tree, and a review that confirmed
# no defects provokes no fixes, so it never arms this.
#
# Fail-open everywhere: a hook that cannot tell stays silent and leaves the label lit.
set -u

input=$(cat) || exit 0
field() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }

[ "$(field '.hook_event_name')" = PostToolUse ] || exit 0
[ "$(field '.tool_name')" = Bash ] || exit 0
# Substring, not a parse of the command line: `git -C x commit`, `git commit -F -` and a commit
# behind `&&` all read the same here, and the git checks below refuse everything that is not one.
case "$(field '.tool_input.command')" in *commit*) ;; *) exit 0 ;; esac

cwd=$(field '.cwd')
[ -n "$cwd" ] || exit 0
top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0

self="$0"
[ -L "$self" ] && self=$(readlink "$self")
case "$self" in /*) ;; *) self="$(dirname "$0")/$self" ;; esac
review_bench="${REVIEW_STAMP_HOOK_BENCH:-$(dirname "$self")/review-bench}"
[ -x "$review_bench" ] || exit 0

receipt=$("$review_bench" receipt --repo "$top" 2>/dev/null) || exit 0
receipt_tree=$(printf '%s' "$receipt" | jq -r '.tree // empty' 2>/dev/null)
confirmed=$(printf '%s' "$receipt" | jq -r '.confirmed // 0' 2>/dev/null)
[[ "$receipt_tree" =~ ^[0-9a-f]{40}$ ]] || exit 0
[[ "$confirmed" =~ ^[0-9]+$ ]] && [ "$confirmed" -gt 0 ] || exit 0

# HEAD must be the commit that just landed on the reviewed content, and nothing may be left
# uncommitted: the stamp covers the whole working tree, so a dirty leftover would be marked
# reviewed along with the fixes.
parent_tree=$(git -C "$top" rev-parse 'HEAD~1^{tree}' 2>/dev/null) || exit 0
[ "$parent_tree" = "$receipt_tree" ] || exit 0
[ -z "$(git -C "$top" status --porcelain 2>/dev/null)" ] || exit 0

"$review_bench" reviewed --repo "$top" >/dev/null 2>&1
exit 0
