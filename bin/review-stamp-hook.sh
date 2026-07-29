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
# behind `&&` all read the same here, and the git checks below refuse everything that is not one.
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

receipt=$("$review_bench" receipt --repo "$top" 2>/dev/null) || exit 0
values=$(printf '%s' "$receipt" | jq -r '
  [(.tree // ""), (.commit // ""), (.confirmed // 0 | tostring),
   (if .worktree then "1" else "" end), (.findings // 0 | tostring), (.base // "")]
  | join("\u001f")' 2>/dev/null) || exit 0
IFS=$'\x1f' read -r receipt_tree receipt_commit confirmed worktree findings base \
  <<< "$values"
[[ "$receipt_tree" =~ ^[0-9a-f]{40}$ ]] || exit 0

# Nothing may be left uncommitted, whichever kind of review this was: the stamp covers the whole
# working tree, so a dirty leftover would be marked reviewed along with the fixes.
[ -z "$(git -C "$top" status --porcelain 2>/dev/null)" ] || exit 0

if [ -n "$worktree" ]; then
  # A review of an uncommitted tree cannot be answered the way a commit review is. Its reviewed
  # tree is a snapshot that is the tree of no commit, so no commit will ever have it as a parent;
  # and the corpus refuses the run, so its confirmed count stays 0 forever. What it does have is
  # the base it was taken on and the findings it wrote, and a clean tree descending from that base
  # is the work it reviewed having landed — fixes and all. That is where this cycle ends: the
  # stamp then rewrites the receipt against HEAD, so the NEXT change lights the label again
  # instead of the review being switched off for good.
  [[ "$findings" =~ ^[0-9]+$ ]] && [ "$findings" -gt 0 ] || exit 0
  [[ "$base" =~ ^[0-9a-f]{40}$ ]] || exit 0
  # Exactly one commit past the base, the same bound the commit branch gets from comparing against
  # HEAD~1: without it any amount of never-reviewed code may ride along in later commits and be
  # stamped as reviewed with the fixes.
  [ "$base" = "$(git -C "$top" rev-parse 'HEAD~1' 2>/dev/null)" ] || exit 0
  # And that commit has to carry what was reviewed. --no-renames on both sides so a fix that renames
  # or deletes a reviewed file still lists the path it started from; with detection on, a rename
  # shows only its destination and the gate would never open again. A snapshot that changed nothing
  # against its base proves nothing and is refused.
  # Residual: writing DIFFERENT content into the same paths in that one commit is indistinguishable
  # from a fix here, and no comparison of trees can tell them apart — a fix changes the content too.
  [[ "$receipt_commit" =~ ^[0-9a-f]{40}$ ]] || exit 0
  # Landing the snapshot untouched applies no fixes: the findings stand, so the label must
  # stay lit.
  [ "$(git -C "$top" rev-parse 'HEAD^{tree}' 2>/dev/null)" != "$receipt_tree" ] || exit 0
  # -z, and never through a variable: command substitution drops NUL bytes, and without -z
  # git quotes paths carrying special characters — a quoted name never matches the literal
  # one handed to rev-parse. A reviewed path whose HEAD blob differs from base is landed
  # work (edits and deletions alike); one reverted back to base content is a discarded fix,
  # which is legal for SOME paths — only reverting every reviewed path proves nothing
  # landed, so only that refuses the stamp.
  [ -n "$(git -C "$top" diff --no-renames --name-only "$base" "$receipt_commit" 2>/dev/null \
    | head -c1)" ] || exit 0
  all_reverted=1
  while IFS= read -r -d '' reviewed_path; do
    [ -n "$reviewed_path" ] || continue
    base_blob=$(git -C "$top" rev-parse --verify "$base:$reviewed_path" 2>/dev/null || true)
    head_blob=$(git -C "$top" rev-parse --verify "HEAD:$reviewed_path" 2>/dev/null || true)
    [ "$base_blob" = "$head_blob" ] || all_reverted=
  done < <(git -C "$top" diff --no-renames --name-only -z "$base" "$receipt_commit" 2>/dev/null)
  [ -z "$all_reverted" ] || exit 0
else
  # HEAD must be the commit that just landed on the reviewed content.
  [[ "$confirmed" =~ ^[0-9]+$ ]] && [ "$confirmed" -gt 0 ] || exit 0
  parent_tree=$(git -C "$top" rev-parse 'HEAD~1^{tree}' 2>/dev/null) || exit 0
  [ "$parent_tree" = "$receipt_tree" ] || exit 0
fi

"$review_bench" reviewed --repo "$top" >/dev/null 2>&1
exit 0
