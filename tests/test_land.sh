#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAND="${LAND_BIN:-$ROOT/bin/land}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd -P "$WORK" && pwd)"
asserts=0
fail() { echo "FAIL: $*" >&2; [ -z "${T:-}" ] || cat "$T/err" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_not() { asserts=$((asserts + 1)); ! "$@" || fail "assert $asserts unexpectedly held: $*"; }
eq() { [ "$1" = "$2" ] || { printf 'expected [%s]\n     got [%s]\n' "$2" "$1" >&2; return 1; }; }
has() { grep -qF -- "$2" "$1" || { printf '%s lacks [%s]:\n' "$1" "$2" >&2; cat "$1" >&2; return 1; }; }

export HOME="$WORK/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME" "$WORK/bin"
printf '#!/bin/bash\n[ "$1" = sid-foreign ] && echo "Foreign Chat"\n' >"$WORK/bin/chat-name"
chmod +x "$WORK/bin/chat-name"
PATH="$WORK/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

lines() { local i; for i in 1 2 3 4 5 6 7 8; do printf '%s%s\n' "$1" "$i"; done; }
commit() { # dir file content message
  printf '%s\n' "$3" >"$1/$2" && git -C "$1" add "$2" && git -C "$1" commit -qm "$4"
}

# A bare remote, the main checkout M (a clone on main), the branch feat in its worktree W, and an
# other clone O standing for another chat that lands straight to origin.
setup() { # name [suites]
  T="$WORK/$1" R="$T/remote.git" M="$T/main" O="$T/other" W="$T/main/.claude/worktrees/feat"
  mkdir -p "$T"
  git init -q --bare -b main "$R"
  git clone -q "$R" "$M" 2>/dev/null
  printf '.claude/\n' >"$M/.gitignore"
  lines a >"$M/a.txt"; lines b >"$M/b.txt"; lines c >"$M/c.txt"
  if [ "${2:-}" = suites ]; then
    mkdir -p "$M/tests"
    printf '#!/bin/bash\necho "$*" >>"%s/affected.log"\necho tests/test_x.sh\n' "$T" >"$M/tests/affected"
    printf '#!/bin/bash\necho "$*" >>"%s/run-all.log"\n[ ! -e "%s/red" ]\n' "$T" "$T" >"$M/tests/run-all"
    chmod +x "$M/tests/affected" "$M/tests/run-all"
  fi
  git -C "$M" add -A && git -C "$M" commit -qm init && git -C "$M" push -q origin main 2>/dev/null
  git clone -q "$R" "$O" 2>/dev/null
  git -C "$M" worktree add -q -b feat "$W"
}
branch_edit() { commit "$W" "$1" "$2" "feat edits $1"; }
other_lands() { # file content message
  commit "$O" "$1" "$2" "$3" && git -C "$O" push -q origin main 2>/dev/null
}
sha() { git -C "$1" rev-parse "$2"; }
land_in() { # dir args... -> rc in $rc, stdout in $T/out, stderr in $T/err
  rc=0
  (cd "$1" && shift && "$LAND" "$@") >"$T/out" 2>"$T/err" || rc=$?
}
gone() { [ ! -e "$W" ] && ! git -C "$M" rev-parse -q --verify refs/heads/feat >/dev/null; }
kept() { [ -d "$W" ] && git -C "$M" rev-parse -q --verify refs/heads/feat >/dev/null; }

# Plain fast-forward from inside the worktree: pushed, worktree and branch gone.
setup plain
branch_edit a.txt "$(lines A)"
tip=$(sha "$W" HEAD)
land_in "$W"
assert eq "$rc" 0
assert eq "$(cat "$T/out")" "landed feat → main $(git -C "$M" rev-parse --short "$tip") (pushed), suites: skipped"
assert eq "$(sha "$M" main)" "$tip"
assert eq "$(sha "$R" main)" "$tip"
assert eq "$(git -C "$M" status --porcelain)" ""
assert gone

# A process of another session working inside the worktree: landed, the worktree and branch stay, the
# process named and never killed; land's own shell inside it does not count.
setup busy
branch_edit a.txt "$(lines A)"
tip=$(sha "$W" HEAD)
(cd "$W/" && exec sleep 600) &
busy=$!
sleep 0.3
land_in "$W"
alive=0; kill -0 "$busy" 2>/dev/null && alive=1
kill "$busy" 2>/dev/null
assert eq "$rc" 0
assert eq "$(cat "$T/out")" "landed feat → main $(git -C "$M" rev-parse --short "$tip") (pushed), suites: skipped"
assert eq "$(cat "$T/err")" "land: landed, but $W and branch feat stay, processes inside: $busy sleep 600; nothing killed, night-run finish prunes them once they end"
assert eq "$(sha "$R" main)" "$tip"
assert eq "$alive" 1
assert kept

# Foreign WIP in the main checkout: untouched files byte for byte, a touched dirty file 3-way merged.
setup wip
branch_edit a.txt "$(lines a | sed 's/^a8$/FEAT8/')"
printf 'WIP1\n' | cat - <(sed 1d "$M/a.txt") >"$T/a.wip" && cp "$T/a.wip" "$M/a.txt"
printf 'wip b\n' >>"$M/b.txt"; cp "$M/b.txt" "$T/b.wip"
printf 'untracked\n' >"$M/u.txt"
land_in "$W"
assert eq "$rc" 0
assert cmp -s "$M/b.txt" "$T/b.wip"
assert eq "$(cat "$M/u.txt")" untracked
assert eq "$(head -1 "$M/a.txt") $(tail -1 "$M/a.txt")" "WIP1 FEAT8"
assert eq "$(git -C "$M" show HEAD:a.txt | head -1) $(git -C "$M" show HEAD:a.txt | tail -1)" "a1 FEAT8"
assert eq "$(git -C "$M" diff --name-only | tr '\n' ' ')" "a.txt b.txt "
assert gone

# A WIP conflict changes nothing anywhere and names the file and its holder.
setup wipconflict
branch_edit a.txt "$(lines a | sed 's/^a8$/FEAT8/')"
sed 's/^a8$/WIP8/' "$M/a.txt" >"$T/a.wip" && cp "$T/a.wip" "$M/a.txt"
key=$(cd "$(git -C "$M" rev-parse --absolute-git-dir)" && pwd -P)
printf '1\tsid-old\t%s\ta.txt\n9\tsid-foreign\t%s\ta.txt\n9\tsid-other\tx\ta.txt\n' "$key" "$key" >"$(git -C "$M" rev-parse --path-format=absolute --git-common-dir)/claude-writes"
main_before=$(sha "$M" main) tip=$(sha "$W" HEAD)
land_in "$W"
assert eq "$rc" 1
assert has "$T/err" "a.txt (holder: Foreign Chat)"
assert cmp -s "$M/a.txt" "$T/a.wip"
assert eq "$(sha "$M" main)" "$main_before"
assert eq "$(sha "$R" main)" "$main_before"
assert eq "$(sha "$W" HEAD)" "$tip"
assert kept

# An untracked file in the way of the update is refused before the push.
setup untracked
branch_edit n.txt "from feat"
printf 'foreign\n' >"$M/n.txt"
main_before=$(sha "$M" main)
land_in "$W"
assert eq "$rc" 1
assert has "$T/err" "n.txt (holder: unknown) is untracked in the way of feat"
assert eq "$(cat "$M/n.txt")" foreign
assert eq "$(sha "$R" main)" "$main_before"
assert kept

# A rebase conflict names the file and main's commit on it, exits nonzero, leaves the branch as it was.
setup rebaseconflict
branch_edit a.txt "$(lines a | sed 's/^a8$/FEAT8/')"
other_lands a.txt "$(lines a | sed 's/^a8$/OTHER8/')" "Other fix (Ledger chat, night 1): a8 rewritten"
other=$(git -C "$O" rev-parse --short HEAD) main_before=$(sha "$M" main) tip=$(sha "$W" HEAD)
land_in "$W"
assert eq "$rc" 1
assert has "$T/err" "  a.txt"
assert has "$T/err" "    $other Other fix (Ledger chat, night 1): a8 rewritten (chat Ledger chat)"
assert eq "$(sha "$W" HEAD)" "$tip"
assert_not test -e "$(git -C "$W" rev-parse --git-path rebase-merge)"
assert eq "$(git -C "$W" status --porcelain)" ""
assert eq "$(sha "$M" main)" "$main_before"
assert kept

# Suites: skipped when upstream touched other files, run when it touched the branch's.
setup nooverlap suites
branch_edit a.txt "$(lines a | sed 's/^a8$/FEAT8/')"
other_lands c.txt "$(lines C)" "other edits c"
land_in "$W"
assert eq "$rc" 0
assert has "$T/out" "(pushed), suites: skipped"
assert_not test -e "$T/run-all.log"
assert eq "$(git -C "$M" log --format=%s -2 main | tr '\n' '|')" "feat edits a.txt|other edits c|"

setup overlap suites
branch_edit a.txt "$(lines a | sed 's/^a8$/FEAT8/')"
other_lands a.txt "$(lines a | sed 's/^a1$/OTHER1/')" "other edits a1"
land_in "$W"
assert eq "$rc" 0
assert has "$T/out" "(pushed), suites: ran 1"
assert eq "$(cat "$T/run-all.log")" "tests/test_x.sh"
assert eq "$(cat "$T/affected.log")" "a.txt"
assert eq "$(git -C "$M" show main:a.txt | sed -n '1p;8p' | tr '\n' ' ')" "OTHER1 FEAT8 "

setup notest suites
branch_edit a.txt "$(lines a | sed 's/^a8$/FEAT8/')"
other_lands a.txt "$(lines a | sed 's/^a1$/OTHER1/')" "other edits a1"
land_in "$W" --no-test
assert eq "$rc" 0
assert has "$T/out" "suites: skipped"
assert_not test -e "$T/run-all.log"

setup forcetest suites
branch_edit a.txt "$(lines A)"
land_in "$W" --test
assert eq "$rc" 0
assert has "$T/out" "suites: ran 1"

setup red suites
branch_edit a.txt "$(lines a | sed 's/^a8$/FEAT8/')"
other_lands a.txt "$(lines a | sed 's/^a1$/OTHER1/')" "other edits a1"
: >"$T/red"
remote_before=$(sha "$R" main)
land_in "$W"
assert eq "$rc" 1
assert eq "$(sha "$R" main)" "$remote_before"
assert_not git -C "$M" merge-base --is-ancestor "$remote_before" main
assert kept

# The remote moves between fetch and push: rebase again and push on the second try.
setup retry
branch_edit a.txt "$(lines A)"
printf '#!/bin/bash\n[ -e "%s/moved" ] && exit 0\n: >"%s/moved"\nprintf x >"%s/c.txt" && git -C "%s" commit -qam "other moved" && git -C "%s" push -q origin main 2>/dev/null\n' \
  "$T" "$T" "$O" "$O" "$O" >"$(git -C "$M" rev-parse --path-format=absolute --git-common-dir)/hooks/pre-push"
chmod +x "$(git -C "$M" rev-parse --path-format=absolute --git-common-dir)/hooks/pre-push"
land_in "$W"
assert eq "$rc" 0
assert has "$T/out" "(pushed)"
assert eq "$(git -C "$R" log --format=%s -3 main | tr '\n' '|')" "feat edits a.txt|other moved|init|"
assert eq "$(sha "$M" main)" "$(sha "$R" main)"
assert gone

# A remote that moves on every push: three tries, then a refusal with nothing landed.
setup retries
branch_edit a.txt "$(lines A)"
printf '#!/bin/bash\necho x >>"%s/pushes"\necho x >>"%s/c.txt" && git -C "%s" commit -qam "other moved" && git -C "%s" push -q origin main 2>/dev/null\n' \
  "$T" "$O" "$O" "$O" >"$(git -C "$M" rev-parse --path-format=absolute --git-common-dir)/hooks/pre-push"
chmod +x "$(git -C "$M" rev-parse --path-format=absolute --git-common-dir)/hooks/pre-push"
main_before=$(sha "$M" main)
land_in "$W"
assert eq "$rc" 1
assert eq "$(wc -l <"$T/pushes" | tr -d ' ')" 3
assert eq "$(sha "$M" main)" "$main_before"
assert kept

# A push origin refuses outright: nothing landed, the worktree and branch stay.
setup refused
branch_edit a.txt "$(lines A)"
printf '#!/bin/bash\nexit 1\n' >"$R/hooks/pre-receive" && chmod +x "$R/hooks/pre-receive"
main_before=$(sha "$M" main)
land_in "$W"
assert eq "$rc" 1
assert has "$T/err" "refused"
assert eq "$(sha "$M" main)" "$main_before"
assert kept

# A dirty worktree is refused in one line before anything moves.
setup dirty
branch_edit a.txt "$(lines A)"
printf 'scratch\n' >"$W/new.txt"
main_before=$(sha "$M" main)
land_in "$W"
assert eq "$rc" 1
assert eq "$(cat "$T/err")" "land: $W has 1 uncommitted files: commit them, then land again"
assert eq "$(sha "$M" main)" "$main_before"
assert eq "$(sha "$R" main)" "$main_before"
assert kept

# No remote: a local landing; a branch named from the main checkout without a worktree of its own.
setup local
git -C "$M" remote remove origin
branch_edit a.txt "$(lines a | sed 's/^a8$/FEAT8/')"
git -C "$M" worktree remove "$W"
commit "$M" c.txt "$(lines C)" "main moved locally"
land_in "$M" feat
assert eq "$rc" 0
assert has "$T/out" "(local), suites: skipped"
assert eq "$(git -C "$M" log --format=%s -3 main | tr '\n' '|')" "feat edits a.txt|main moved locally|init|"
assert eq "$(git -C "$M" worktree list | wc -l | tr -d ' ')" 1
assert gone

echo "PASS: test_land.sh ($asserts asserts)"
