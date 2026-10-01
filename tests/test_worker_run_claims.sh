#!/usr/bin/env bash
. "$(dirname "$0")/worker_run_harness.sh"
set_config 'claudeb_model=opus' 'claudeb_effort=high'
export PICK_RC=0 PICK_ACCOUNT=recordacct CLAUDE_CODE_SESSION_ID=chat-abc
mkdir -p "$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture"
dirt_repo_init

clear_stub
INITIAL_REPO="$WORK/initial-repo"
mkdir -p "$INITIAL_REPO"
INITIAL_REPO=$(cd "$INITIAL_REPO" && pwd -P)
git -C "$INITIAL_REPO" init -q
export STUB_SLEEP=1
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Write file_path "$INITIAL_REPO/initial" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_ok claudeb --workdir "$INITIAL_REPO"
printf 'initial content\n' >"$INITIAL_REPO/initial"
git -C "$INITIAL_REPO" add initial
git -C "$INITIAL_REPO" -c user.name=fixture -c user.email=fixture@example.test commit -qm initial
assert await_done
assert grep -qx initial "$RUN_DIR/files"
assert grep -qxF -- $'-\t'"$(git -C "$INITIAL_REPO" rev-parse HEAD:initial)"$'\tinitial\tcommit' "$RUN_DIR/produced"

# --- What the run PRODUCED ------------------------------------------------------------------------
# A listing names paths; a debt reader prices CONTENT. `produced` is the run's own answer in the
# links that reader walks — `<prev>\t<cur>\t<path>`, with a fourth field `commit` on the transitions
# the run's own commits made — so ownership follows the BLOB and no longer a path and an epoch.
clear_stub
PROD_REPO="$WORK/produced-repo"
mkdir -p "$PROD_REPO/bin" "$PROD_REPO/tests"
git -C "$PROD_REPO" init -q .
printf 'one\n' >"$PROD_REPO/bin/modified"
printf 'here\n' >"$PROD_REPO/bin/deleted"
printf 'before\n' >"$PROD_REPO/bin/committed"
printf 'orig\n' >"$PROD_REPO/bin/committed-open"
printf 'never moved\n' >"$PROD_REPO/bin/untouched"
printf 'orig\n' >"$PROD_REPO/bin/co-tenant-open"
# A filename holding a BACKSLASH, which is a legal name git records verbatim. Handed to awk through
# `-v` it arrives with its escapes expanded, so the floor lookup matched no row and the link was
# priced from HEAD's blob instead of from the content the co-tenant left standing.
PROD_ESC='bin/back\slash'
printf 'orig\n' >"$PROD_REPO/$PROD_ESC"
git -C "$PROD_REPO" add -A >/dev/null
git -C "$PROD_REPO" -c user.email=t@t -c user.name=t commit -qm base >/dev/null
PROD_TOP=$(cd "$PROD_REPO" && pwd -P)
PROD_BASE=$(git -C "$PROD_REPO" rev-parse HEAD)
tab=$'\t'
blob_of() { printf '%s\n' "$1" | git -C "$PROD_REPO" hash-object --stdin; }
# A co-tenant's live edit, standing before this run was launched: it is what the run's own rewrite is
# measured against, and the one case HEAD's blob answers wrongly.
printf 'egor was here\n' >"$PROD_REPO/bin/co-tenant-open"
printf 'egor was here\n' >"$PROD_REPO/bin/committed-open"
printf 'egor was here\n' >"$PROD_REPO/$PROD_ESC"
TOOL_TS=$(iso $(($(date +%s) + 60)))
{
  tool_call Edit file_path "$PROD_TOP/bin/modified"
  tool_call Write file_path "$PROD_TOP/bin/born"
  tool_call Edit file_path "$PROD_TOP/bin/deleted"
  tool_call Edit file_path "$PROD_TOP/bin/untouched"
  tool_call Edit file_path "$PROD_TOP/bin/co-tenant-open"
  tool_call Edit file_path "$PROD_TOP/$PROD_ESC"
  tool_call Edit file_path "$PROD_TOP/bin/committed"
  tool_call Edit file_path "$PROD_TOP/bin/committed-open"
  tool_call Write file_path "$PROD_TOP/bin/committed-born"
} >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export CLAUDE_CODE_SESSION_ID=chat-abc STUB_SLEEP=1
start_ok claudeb --workdir "$PROD_REPO"
# The commit the tree stood on when the run was launched, written before the CLI takes a token: read
# at the end instead, every link the run committed would be measured against its own result.
assert test "$(cat "$RUN_DIR/head-before")" = "$PROD_BASE"
printf 'two\n' >"$PROD_REPO/bin/modified"
printf 'born\n' >"$PROD_REPO/bin/born"
rm -f "$PROD_REPO/bin/deleted"
touch "$PROD_REPO/bin/untouched"
printf 'the worker rewrote it\n' >"$PROD_REPO/bin/co-tenant-open"
printf 'the worker rewrote it\n' >"$PROD_REPO/$PROD_ESC"
printf 'after\n' >"$PROD_REPO/bin/committed"
printf 'the worker rewrote it\n' >"$PROD_REPO/bin/committed-open"
printf 'landed\n' >"$PROD_REPO/bin/committed-born"
git -C "$PROD_REPO" add bin/committed bin/committed-born bin/committed-open >/dev/null
git -C "$PROD_REPO" -c user.email=t@t -c user.name=t commit -qm 'the run committed' >/dev/null
assert await_done
assert grep -qxF -- "$(blob_of one)$tab$(blob_of two)${tab}bin/modified" "$RUN_DIR/produced"
# A file born and a file gone are the same row with `-` on the side holding no content: priced off
# the path alone, a birth reads as an edit of a file that was never there.
assert grep -qxF -- "-$tab$(blob_of born)${tab}bin/born" "$RUN_DIR/produced"
assert grep -qxF -- "$(blob_of here)$tab-${tab}bin/deleted" "$RUN_DIR/produced"
# Already dirty at launch: the floor's content is the prev, never HEAD's blob. Measured against the
# commit instead, this row claims a link the co-tenant produced.
assert grep -qxF -- "$(blob_of 'egor was here')$tab$(blob_of 'the worker rewrote it')${tab}bin/co-tenant-open" \
  "$RUN_DIR/produced"
# The same path spelled with a BACKSLASH, which is where the lookup into that floor is either
# literal or nothing: expanded as an escape, the name matched no row and the prev fell back to
# HEAD's blob, claiming the co-tenant's line as this run's.
assert grep -qxF -- "$(blob_of 'egor was here')$tab$(blob_of 'the worker rewrote it')$tab$PROD_ESC" \
  "$RUN_DIR/produced"
# Both sides WRITTEN to the object store, not merely named: the reader prices this link by diffing
# the two blobs there, and a side no store holds prices the whole file. Neither content is in any
# commit and `blob_of` writes nothing, so the floor's `-w` and the record's are all that can be
# holding them — the prev from the launch snapshot, the cur from the record written at the end.
assert git -C "$PROD_REPO" cat-file -e "$(blob_of 'egor was here')"
assert git -C "$PROD_REPO" cat-file -e "$(blob_of 'the worker rewrote it')"
# A listed path whose content never moved produced nothing: a row for it owns a link that is not
# there, and the reader would price the whole file against a base nobody wrote.
assert_fails grep -q 'bin/untouched' "$RUN_DIR/produced"
assert_fails grep -qx 'bin/untouched' "$RUN_DIR/files"
assert grep -qx 'bin/deleted' "$RUN_DIR/files"
assert test -f "$RUN_DIR/dirty-after-shas"
assert test "$(cat "$RUN_DIR/head-after")" = "$(git -C "$PROD_REPO" rev-parse HEAD)"
assert_fails grep -q '^UNKNOWN: \|^PARTIAL: ' "$RUN_DIR/files"
# The commits the run made, in the transitions git prints for them, marked so the reader can apply
# the first-row-wins rule that a cherry-picked blob needs and an edit does not.
assert grep -qxF -- "$(blob_of before)$tab$(blob_of after)${tab}bin/committed${tab}commit" "$RUN_DIR/produced"
assert grep -qxF -- "-$tab$(blob_of landed)${tab}bin/committed-born${tab}commit" "$RUN_DIR/produced"
assert grep -qxF -- "$(blob_of 'egor was here')$tab$(blob_of 'the worker rewrote it')${tab}bin/committed-open" "$RUN_DIR/produced"
# One grammar for both kinds, or the sweep reading these rows splits a path off the wrong field.
assert test "$(awk -F'\t' 'NF < 3 || NF > 4' "$RUN_DIR/produced" | wc -l | tr -d ' ')" -eq 0
assert test "$(awk -F'\t' 'NF == 4 && $4 != "commit"' "$RUN_DIR/produced" | wc -l | tr -d ' ')" -eq 0
assert test "$(awk -F'\t' '$3 == "bin/modified" { print NF }' "$RUN_DIR/produced")" = 3

# A repository CLEAN at launch writes an empty floor, and the rewrite scan that would re-hash the
# tree at the end is skipped over one — so the RECORD's own `hash-object -w` is the only thing that
# can put this `cur` in the store the reader diffs it out of. Which is the shape of every fresh
# worktree a worker is handed, and the case a repository already dirty at launch hides.
clear_stub
CLEAN_REPO="$WORK/clean-repo"
mkdir -p "$CLEAN_REPO/bin"
git -C "$CLEAN_REPO" init -q .
printf 'base\n' >"$CLEAN_REPO/bin/edited"
git -C "$CLEAN_REPO" add -A >/dev/null
git -C "$CLEAN_REPO" -c user.email=t@t -c user.name=t commit -qm base >/dev/null
CLEAN_TOP=$(cd "$CLEAN_REPO" && pwd -P)
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$CLEAN_TOP/bin/edited" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$CLEAN_REPO"
assert test ! -s "$RUN_DIR/dirty-before-shas"
printf 'rewritten\n' >"$CLEAN_REPO/bin/edited"
assert await_done
assert grep -qxF -- "$(blob_of base)$tab$(blob_of rewritten)${tab}bin/edited" "$RUN_DIR/produced"
assert git -C "$CLEAN_REPO" cat-file -e "$(blob_of rewritten)"

# A run that answers to a chat and worked in a git tree writes the record even when it holds nothing:
# its PRESENCE is this run answering for its own content, and its absence is what sends a reader back
# to the listing and the floor.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Read file_path "$PROD_TOP/bin/untouched" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_ok claudeb --workdir "$PROD_REPO"
assert await_done
assert test -e "$RUN_DIR/produced"
assert test ! -s "$RUN_DIR/produced"

# A run no chat answers for produces nothing anybody owns: rows written here would be content
# attributed to the empty session, which is what the dirt record already says better.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$PROD_TOP/bin/modified" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
unset CLAUDE_CODE_SESSION_ID
start_ok claudeb --workdir "$PROD_REPO"
assert await_done
assert test ! -e "$RUN_DIR/launcher"
assert test ! -e "$RUN_DIR/produced"
export CLAUDE_CODE_SESSION_ID=chat-abc

# A workdir in no repository has no blobs to name, and neither record is invented for it.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$WORK/workdir/bin/somewhere" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_ok claudeb
assert await_done
assert test ! -e "$RUN_DIR/head-before"
assert test ! -e "$RUN_DIR/produced"

# The rows are spelled the way the listing is — against the WORKDIR, absolute where they fall outside
# it — so one reader resolves both records the same way for a run launched a directory in.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
{
  tool_call Edit file_path "$PROD_TOP/tests/named-here"
  tool_call Edit file_path "$PROD_TOP/bin/named-from-the-top"
} >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$PROD_REPO/tests"
printf 'in the workdir\n' >"$PROD_REPO/tests/named-here"
printf 'above the workdir\n' >"$PROD_REPO/bin/named-from-the-top"
assert await_done
assert grep -qxF -- "-$tab$(blob_of 'in the workdir')${tab}named-here" "$RUN_DIR/produced"
assert grep -qxF -- "-$tab$(blob_of 'above the workdir')$tab$PROD_TOP/bin/named-from-the-top" \
  "$RUN_DIR/produced"

# What the launching chat CLAIMS is content this run produced too. Left out of the record, the very
# paths a claim exists to name are invisible to every reader that takes `produced` over the listing.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Bash command 'sed -i "" s/a/b/ bin/claimed-content' \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$PROD_REPO"
printf 'claimed content\n' >"$PROD_REPO/bin/claimed-content"
assert await_done
assert_fails grep -q 'bin/claimed-content' "$RUN_DIR/produced"
assert grep -qx 'bin/claimed-content' "$RUN_DIR/dirty"
assert "$RUNNER" claim "$RUN_ID" --paths bin/claimed-content >/dev/null
assert grep -qxF -- "-$tab$(blob_of 'claimed content')${tab}bin/claimed-content" "$RUN_DIR/produced"
# APPENDED, never recomputed: the rows already standing were measured when the run ended, and a
# fresh pass over the record now dates whatever a co-tenant has done since to this run.
printf 'a co-tenant moved it on\n' >"$PROD_REPO/bin/claimed-content"
assert "$RUNNER" claim "$RUN_ID" --paths bin/claimed-content >/dev/null
assert grep -qxF -- "-$tab$(blob_of 'claimed content')${tab}bin/claimed-content" "$RUN_DIR/produced"
assert test "$(grep -cF 'bin/claimed-content' "$RUN_DIR/produced")" -eq 1


legacy_claim_record() {
  local path
  printf 'WORKDIR: %s\nPARTIAL: legacy transcript listing\n' "$(jq -r '.workdir' "$RUN_DIR/meta.json")" >"$RUN_DIR/files"
  printf 'WORKDIR: %s\n' "$DIRT_TOP" >"$RUN_DIR/dirty"
  for path in "$@"; do printf '%s\n' "$path" >>"$RUN_DIR/dirty"; done
  rm -f "$RUN_DIR/dirty-after-shas" "$RUN_DIR/head-after"
  "$RUNNER" wait "$RUN_ID" --max 0 >"$WORK/wait.out"
}

# --- Naming what the run could not name -----------------------------------------------------------
# A run that worked through the shell lists nothing and its work is owned by nobody. The launching
# chat is the one reader who knows which of the paths that changed in the run's window are its
# worker's, so `wait` prints them and `claim` records the answer.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Bash command 'sed -i "" s/a/b/ bin/claimed-one' \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export CLAUDE_CODE_SESSION_ID=chat-abc
export STUB_SLEEP=1
start_ok claudeb --workdir "$DIRT_REPO"
printf 'through the shell\n' >"$DIRT_REPO/bin/claimed-one"
printf 'through the shell\n' >"$DIRT_REPO/bin/claimed-two"
assert await_done
legacy_claim_record 'bin/claimed-one' 'bin/claimed-two'
assert grep -q '^PARTIAL: ' "$RUN_DIR/files"
# The line the orchestrator acts on, and the paths in it are already spelled the way `claim` takes
# them: a list it has to re-spell is a list it gets wrong.
assert grep -qxF "UNNAMED: 2 path(s) changed in this run's window that no record names — claim yours: worker-run claim $RUN_ID --paths $DIRT_TOP/bin/claimed-one $DIRT_TOP/bin/claimed-two" \
  "$WORK/wait.out"

# A live run is still writing its own record, and a claim landing mid-flight is overwritten by the
# next sweep — so the run has to have ended before anybody may name its files.
mv "$RUN_DIR/exit_code" "$RUN_DIR/exit_code.held"
assert_fails "$RUNNER" claim "$RUN_ID" --paths bin/claimed-one
assert grep -q 'is still running' \
  <<<"$("$RUNNER" claim "$RUN_ID" --paths bin/claimed-one 2>&1 >/dev/null)"
mv "$RUN_DIR/exit_code.held" "$RUN_DIR/exit_code"

# Only the chat that spawned the run may name its work: another chat signing for it is one session
# taking a waiver over work it has never read.
assert_fails env CLAUDE_CODE_SESSION_ID=chat-somebody-else "$RUNNER" claim "$RUN_ID" --paths bin/claimed-one
assert grep -q 'launched by chat-abc' \
  <<<"$(CLAUDE_CODE_SESSION_ID=chat-somebody-else "$RUNNER" claim "$RUN_ID" --paths bin/claimed-one 2>&1 >/dev/null)"

# A shell that names no chat at all is not the launching chat either: read as an empty session it
# would match a record whose launcher is empty and claim the work of a run nobody can answer for.
assert_fails env -u CLAUDE_CODE_SESSION_ID "$RUNNER" claim "$RUN_ID" --paths bin/claimed-one
assert grep -q 'this shell names no chat' \
  <<<"$(env -u CLAUDE_CODE_SESSION_ID "$RUNNER" claim "$RUN_ID" --paths bin/claimed-one 2>&1 >/dev/null)"

# And a run whose own record names no launching chat is claimable by nobody, whoever is asking:
# the answer to "whose worker was this" is the record, and an empty one is not an open invitation.
mv "$RUN_DIR/launcher" "$RUN_DIR/launcher.held"
: >"$RUN_DIR/launcher"
assert_fails "$RUNNER" claim "$RUN_ID" --paths bin/claimed-one
assert grep -q 'records no launching chat' \
  <<<"$("$RUNNER" claim "$RUN_ID" --paths bin/claimed-one 2>&1 >/dev/null)"
mv -f "$RUN_DIR/launcher.held" "$RUN_DIR/launcher"

# A path outside the run's workdir is not the run's to claim, and the whole call is refused rather
# than half applied — a claim that took some of its paths leaves the caller unable to tell which.
assert_fails "$RUNNER" claim "$RUN_ID" --paths /etc/hosts
assert_fails "$RUNNER" claim "$RUN_ID" --paths bin/claimed-one ../outside-the-workdir
assert_fails grep -qx 'bin/claimed-one' "$RUN_DIR/files"
assert_fails "$RUNNER" claim "$RUN_ID"

# The claim itself: an ordinary listing row, the caveat beside it untouched, and the path gone from
# the dirt record — it carries an owner now.
claimed=$("$RUNNER" claim "$RUN_ID" --paths bin/claimed-one)
assert grep -qx "CLAIMED: 1 path(s) for $RUN_ID" <<<"$claimed"
assert grep -qx 'bin/claimed-one' <<<"$claimed"
assert grep -qx 'bin/claimed-one' "$RUN_DIR/files"
assert grep -q '^PARTIAL: ' "$RUN_DIR/files"
assert test "$(head -n1 "$RUN_DIR/files")" = "WORKDIR: $DIRT_TOP"
assert_fails grep -qx 'bin/claimed-one' "$RUN_DIR/dirty"
assert grep -qx 'bin/claimed-two' "$RUN_DIR/dirty"
# The rewritten record keeps the header its rows are spelled against: dropped, `unnamed_line` bails
# out on an empty `top` and every later wait silently stops naming what nobody has claimed.
assert test "$(head -n1 "$RUN_DIR/dirty")" = "WORKDIR: $DIRT_TOP"

# Absolute or workdir-relative, one answer; and a path the dirt record never held is named without
# being ADDED to the set of paths nobody names.
assert "$RUNNER" claim "$RUN_ID" --paths "$DIRT_TOP/bin/claimed-two" bin/never-was-dirty >/dev/null
assert grep -qx 'bin/claimed-two' "$RUN_DIR/files"
assert grep -qx 'bin/never-was-dirty' "$RUN_DIR/files"
assert test ! -e "$RUN_DIR/dirty"
# Nothing left unnamed, so the line is gone although the run's own list is still a floor.
assert grep -q '^PARTIAL: ' "$RUN_DIR/files"
assert_fails grep -q '^UNNAMED: ' <<<"$("$RUNNER" wait "$RUN_ID" --max 0)"

# `--complete` is the caller stating that this IS the whole list, and it is the only thing that
# retires the caveat: an ordinary claim adds real paths and says nothing about what stands beside
# them.
printf '%s\n' "UNKNOWN: no session transcript for a claim test" >>"$RUN_DIR/files"
assert "$RUNNER" claim "$RUN_ID" --paths bin/claimed-one --complete >/dev/null
assert test "$(grep -c '^PARTIAL: \|^UNKNOWN: ' "$RUN_DIR/files")" -eq 0
assert grep -qx 'bin/claimed-one' "$RUN_DIR/files"
assert grep -qx 'bin/claimed-two' "$RUN_DIR/files"
assert test "$(head -n1 "$RUN_DIR/files")" = "WORKDIR: $DIRT_TOP"

# The printed line is pasted into a shell, so it has to survive one: a path carrying a space
# reached `claim` as several paths, and one carrying a `*` as whatever the tree held beside it.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Bash command 'sed -i "" s/a/b/ "bin/named with a space"' \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$DIRT_REPO"
printf 'through the shell\n' >"$DIRT_REPO/bin/named with a space"
assert await_done
legacy_claim_record 'bin/named with a space'
printed=$(grep '^UNNAMED: ' "$WORK/wait.out")
assert test -n "$printed"
assert eval "\"$RUNNER\" ${printed#*claim yours: worker-run }" >/dev/null
assert grep -qxF 'bin/named with a space' "$RUN_DIR/files"
assert test ! -e "$RUN_DIR/dirty"

# The path split inside `claim` is lexical too: a `*` answered by the directory the caller happens
# to be standing in names a file this run never touched, and names it as the caller's own work.
printf 'a decoy the split must not find\n' >"$DIRT_REPO/globbedXstar"
assert eval '(cd "$DIRT_REPO" && "$RUNNER" claim "$RUN_ID" --paths "bin/globbed*star")' >/dev/null
assert grep -qxF 'bin/globbed*star' "$RUN_DIR/files"
assert_fails grep -q 'globbedXstar' "$RUN_DIR/files"

# A run launched in a SUBDIRECTORY: its dirt is its REPOSITORY's, spelled against the top, so the
# command `wait` prints names paths outside the workdir. Checked against the workdir alone, that
# exact command is refused whole and not one of its paths is claimed.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Bash command 'sed -i "" s/a/b/ bin/claimed-from-a-subdirectory' \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$DIRT_REPO/tests"
printf 'through the shell\n' >"$DIRT_REPO/bin/claimed-from-a-subdirectory"
assert await_done
legacy_claim_record 'bin/claimed-from-a-subdirectory'
assert grep -qxF "UNNAMED: 1 path(s) changed in this run's window that no record names — claim yours: worker-run claim $RUN_ID --paths $DIRT_TOP/bin/claimed-from-a-subdirectory" \
  "$WORK/wait.out"
assert eval "\"$RUNNER\" $(grep '^UNNAMED: ' "$WORK/wait.out" | sed 's/.*claim yours: worker-run //')" >/dev/null
# Spelled absolutely in the listing, exactly as any path outside the workdir is.
assert grep -qxF "$DIRT_TOP/bin/claimed-from-a-subdirectory" "$RUN_DIR/files"
assert test ! -e "$RUN_DIR/dirty"
# Outside the repository is still nobody's to claim: what widened is the run's own tree, no more.
assert_fails "$RUNNER" claim "$RUN_ID" --paths /etc/hosts

# What the UNNAMED line turns on is the run saying it cannot name its own files — not on there
# being dirt. A caveat retired by `--complete` over a record that still holds rows prints nothing,
# and the complete-listing run below would pass that assertion with the guard deleted.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Bash command 'sed -i "" s/a/b/ bin/still-unnamed' \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$DIRT_REPO"
printf 'through the shell\n' >"$DIRT_REPO/bin/still-unnamed"
assert await_done
legacy_claim_record 'bin/still-unnamed'
assert grep -q '^UNNAMED: ' "$WORK/wait.out"
assert "$RUNNER" claim "$RUN_ID" --paths bin/was-never-dirty --complete >/dev/null
assert grep -qx 'bin/still-unnamed' "$RUN_DIR/dirty"
assert_fails grep -q '^UNNAMED: ' <<<"$("$RUNNER" wait "$RUN_ID" --max 0)"

# A run whose window changed hundreds of paths printed all of them shell-quoted into ONE line at
# the end of every wait — multiple kilobytes, crowding out the outcome and the result tail it is
# printed beside. Past the cap the count is still exact and the reader is sent to the record.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Bash command 'sed -i "" s/a/b/ bin/capped-one' \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$DIRT_REPO"
for capped in one two three; do
  printf 'through the shell\n' >"$DIRT_REPO/bin/capped-$capped"
done
assert await_done
legacy_claim_record 'bin/capped-one' 'bin/capped-two' 'bin/capped-three'
CAPPED_COUNT=$(grep -cv '^WORKDIR: ' "$RUN_DIR/dirty")
assert test "$CAPPED_COUNT" -ge 3
capped_line=$(WORKER_RUN_UNNAMED_INLINE_MAX=1 "$RUNNER" wait "$RUN_ID" --max 0 | grep '^UNNAMED: ')
assert grep -qF "UNNAMED: $CAPPED_COUNT path(s)" <<<"$capped_line"
# Named by the run's own record — spelled the way `wait` spells it, which is not always the
# absolute form `start` printed.
assert grep -qF "listed one per line in " <<<"$capped_line"
assert grep -qF "$RUN_ID/dirty" <<<"$capped_line"
assert_fails grep -q 'bin/capped-one' <<<"$capped_line"
assert test "${#capped_line}" -lt 400
# Under the cap it is still the paste-ready list, spelled the way `claim` takes it.
capped_full=$(WORKER_RUN_UNNAMED_INLINE_MAX="$CAPPED_COUNT" "$RUNNER" wait "$RUN_ID" --max 0 \
  | grep '^UNNAMED: ')
assert grep -qF "$DIRT_TOP/bin/capped-one" <<<"$capped_full"
assert eval "\"$RUNNER\" $(sed 's/.*claim yours: worker-run //' <<<"$capped_full")" >/dev/null

# The record it sends the reader to is spelled against the repository TOP, while `claim` resolves a
# relative operand against the run's WORKDIR: for a run launched in a subdirectory a row pasted as
# it stands names a path the run never touched, and the widened repository check takes it. So the
# line states the prefix, and following it mechanically claims what the record actually holds.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Bash command 'sed -i "" s/a/b/ bin/capped-sub-one' \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$DIRT_REPO/tests"
for capped in one two three; do
  printf 'through the shell\n' >"$DIRT_REPO/bin/capped-sub-$capped"
done
assert await_done
legacy_claim_record 'bin/capped-sub-one' 'bin/capped-sub-two' 'bin/capped-sub-three'
capped_sub_line=$(WORKER_RUN_UNNAMED_INLINE_MAX=1 "$RUNNER" wait "$RUN_ID" --max 0 \
  | grep '^UNNAMED: ')
assert grep -qF -e "--paths $DIRT_TOP/<row>" <<<"$capped_sub_line"
capped_sub_rows=$(grep -v '^WORKDIR: ' "$RUN_DIR/dirty" | sed '/^$/d')
capped_sub_paths=$(while IFS= read -r capped_row; do
  printf '%q ' "$DIRT_TOP/$capped_row"
done <<<"$capped_sub_rows")
assert eval "\"$RUNNER\" claim \"$RUN_ID\" --paths $capped_sub_paths" >/dev/null
while IFS= read -r capped_row; do
  assert grep -qxF "$DIRT_TOP/$capped_row" "$RUN_DIR/files"
done <<<"$capped_sub_rows"
assert test ! -e "$RUN_DIR/dirty"

# A run whose own list is complete has nothing for anyone to claim, so the line is never printed.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$DIRT_TOP/tests/tracked-by-the-editor" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_ok claudeb --workdir "$DIRT_REPO"
assert await_done
assert_fails grep -q '^UNNAMED: ' "$WORK/wait.out"

# A running run's liveness, for the one reader who has nothing else: claudeb writes its JSON once,
# at the end, so OUT-BYTES reads 0 for the whole run and a wrapper agent declared a healthy
# 52-minute run stalled one minute before it finished (live 2026-08-24). The dirt tracker already
# knows which paths are this run's, and the newest of their mtimes is the answer.
clear_stub
printf 'delete me\n' >"$DIRT_REPO/bin/deletion-is-work"
git -C "$DIRT_REPO" add bin/deletion-is-work
git -C "$DIRT_REPO" -c user.email=t@t -c user.name=t commit -qm 'track deletion liveness'
# Every probe below has to land while the run is still going, and there are a dozen of them: 4s
# failed under a parallel suite wave (2026-09-04) and 12s at load average 130 (2026-10-01), purely
# on machine load; `await_done` at the end budgets 100+ s.
export STUB_SLEEP=40
start_ok claudeb --workdir "$DIRT_REPO"
idle=$("$RUNNER" wait "$RUN_ID" --max 0)
assert grep -qx 'STATUS: running' <<<"$idle"
assert grep -qx 'OUT-BYTES: 0' <<<"$idle"
# Nothing has changed yet, and the dirt every co-tenant left behind before this run started is on
# the floor rather than in this answer.
assert grep -qx 'LAST-EDIT: none' <<<"$idle"
rm -f "$DIRT_REPO/bin/deletion-is-work"
deleting=$("$RUNNER" wait "$RUN_ID" --max 0)
assert grep -Eq '^LAST-EDIT: [0-9]$' <<<"$deleting"
printf 'the run is working\n' >"$DIRT_REPO/bin/proof-of-life"
working=$("$RUNNER" wait "$RUN_ID" --max 0)
assert grep -Eq '^LAST-EDIT: [0-9]$' <<<"$working"
assert grep -qx 'OUT-BYTES: 0' <<<"$working"
assert grep -Eq '^CPU-SECONDS: [0-9]+$' <<<"$working"
# The rows a relay already parses keep their bytes.
assert grep -Eq '^ELAPSED: [0-9]+$' <<<"$working"
assert grep -Eq '^ERR-BYTES: [0-9]+$' <<<"$working"
assert grep -Eq '^SESSION: ' <<<"$working"
assert grep -Eq '^(LAST-EDIT|CPU-SECONDS): ' <<<"$("$RUNNER" report "$RUN_ID")"
# Past the long-run mark the report says so next to ELAPSED: the launching chat's prompt cache
# cools past the hour, so the remainder belongs in a split brief rather than in this run.
assert_fails grep -q '^LONG-RUN: ' <<<"$working"
sleep 1
assert grep -q '^LONG-RUN: 0 min — the orchestrator' \
  <<<"$(WORKER_RUN_LONG_RUN_S=1 "$RUNNER" wait "$RUN_ID" --max 0)"
# And once per RUN: a relay returns a checkpoint on any LONG-RUN line, so a second round past the
# same mark saying it again bounced an attached relay back every ~9 minutes. The rest of the
# running rows are unchanged there.
said_again=$(WORKER_RUN_LONG_RUN_S=1 "$RUNNER" wait "$RUN_ID" --max 0)
assert_fails grep -q '^LONG-RUN: ' <<<"$said_again"
assert grep -qx 'STATUS: running' <<<"$said_again"
assert test -f "$RUN_DIR/long-run-said"
# That marker is the whole of what silences it: the threshold and its knob answer as before.
rm -f "$RUN_DIR/long-run-said"
jq '.started_at -= 1560' "$RUN_DIR/meta.json" >"$WORK/aged-meta.json"
mv "$WORK/aged-meta.json" "$RUN_DIR/meta.json"
long=$("$RUNNER" wait "$RUN_ID" --max 0)
assert grep -q '^LONG-RUN: 26 min — the orchestrator' <<<"$long"
assert grep -Eq '^ELAPSED: [0-9]+$' <<<"$long"
assert grep -qx 'STATUS: running' <<<"$long"
assert await_done
# A terminal report answers with the run's files instead; a liveness row there is a run still going.
assert test "$(grep -c '^LAST-EDIT: \|^CPU-SECONDS: ' "$WORK/wait.out")" -eq 0
unset STUB_SLEEP
unset CLAUDE_CODE_SESSION_ID


echo "PASS: $asserts asserts; initial and produced repositories, legacy claims, unnamed files, long-run notes"
