#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT
WORK="$(cd -P "$WORK" && pwd)"
asserts=0
exec 8>&2
fail() { echo "FAIL: $*" >&8; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() {
  asserts=$((asserts + 1))
  "$@" && fail "assert $asserts unexpectedly succeeded: $*"
  return 0
}

export HOME="$WORK/home" GIT_CONFIG_NOSYSTEM=1 DOCTORS_DIR="$WORK/doctors" WORKTREE_PUSH_WAIT_S=5
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
FAKE_BIN="$WORK/bin"
PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
mkdir -p "$HOME" "$FAKE_BIN" "$WORK/hooks" "$DOCTORS_DIR/runs"
printf '#!/bin/sh\ngit push -q origin main\n' >"$WORK/hooks/post-merge"
cat >"$FAKE_BIN/review-bench" <<'EOF'
#!/usr/bin/env bash
[ "$1 $3" = "fix --print" ] || exit 2
[ ! -e "$WORK/open-$2" ] || cat "$WORK/open-$2"
EOF
cat >"$FAKE_BIN/code-doctor" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$WORK/code-checks"
case " $* " in *" --suites-passed "*) exit 0 ;; esac
echo "x: deletion proof: green suites not confirmed (--suites-passed)"
exit 1
EOF
chmod +x "$WORK/hooks/post-merge" "$FAKE_BIN"/*
export WORK NIGHT_RUN_CODE_DOCTOR="$FAKE_BIN/code-doctor"

wt() { bash "$ROOT/bin/worktree" "$@"; }
repo() { # name -> a main checkout on main with a bare origin, pushing main after each merge
  git init -q --bare "$WORK/$1.git"
  git init -q -b main "$WORK/$1"
  git -C "$WORK/$1" remote add origin "$WORK/$1.git"
  git -C "$WORK/$1" config core.hooksPath "$WORK/hooks"
  printf 'c\n' >"$WORK/$1/c.txt" && git -C "$WORK/$1" add c.txt && git -C "$WORK/$1" commit -qm root
  git -C "$WORK/$1" push -q origin main
}
commit() { printf '%s\n' "$3" >"$1/$2" && git -C "$1" add "$2" && git -C "$1" commit -qm "$4"; }
origin_main() { git -C "$WORK/$1.git" rev-parse refs/heads/main; }
repo r
repo s
R="$WORK/r" S="$WORK/s"

# new: <repo>/.claude/worktrees/<branch, / -> ->, excluded first, a new branch from main, an existing one reused.
wt new "$R" feat/x >"$WORK/out" || fail "new"
X="$R/.claude/worktrees/feat-x"
assert [ "$(cat "$WORK/out")" = "$X" ]
assert [ "$(git -C "$X" symbolic-ref --short HEAD)" = feat/x ]
assert [ "$(git -C "$X" rev-parse HEAD)" = "$(git -C "$R" rev-parse main)" ]
assert grep -qxF '.claude/worktrees/' "$R/.git/info/exclude"
assert [ -z "$(git -C "$R" status --porcelain)" ]
assert [ "$(wt new "$X" feat/x)" = "$X" ]
assert [ "$(grep -c worktrees "$R/.git/info/exclude")" = 1 ]
assert_fails wt new "$R" main 2>/dev/null
# --add-dir: the same branch in each other repository, one it cannot make named and skipped.
wt new "$R" feat/y --add-dir "$S" --add-dir "$WORK/nowhere" >"$WORK/out" 2>"$WORK/err" || fail "new --add-dir"
assert [ "$(cat "$WORK/out")" = "$(printf '%s\nADD-DIR: %s' "$R/.claude/worktrees/feat-y" "$S/.claude/worktrees/feat-y")" ]
assert [ "$(git -C "$S/.claude/worktrees/feat-y" symbolic-ref --short HEAD)" = feat/y ]
assert grep -qF "no worktree in $WORK/nowhere" "$WORK/err"
# A night branch starts from its night's base, never HEAD, and needs it.
assert_fails wt new "$R" night/n1/a 2>"$WORK/err"
assert grep -qF "no refs/night/n1/base in $R: run night-run base n1 first" "$WORK/err"
printf 'press-time\n' >"$R/wip.txt"
base=$(git -C "$R" add wip.txt && git -C "$R" write-tree) && git -C "$R" reset -q && rm "$R/wip.txt"
base=$(git -C "$R" commit-tree "$base" -p main -m "night n1 base")
git -C "$R" update-ref refs/night/n1/base "$base"
N="$(wt new "$R" night/n1/a)" || fail "night new"
assert [ "$N" = "$R/.claude/worktrees/night-n1-a" ]
assert [ "$(git -C "$N" rev-parse HEAD)" = "$base" ]

# land: rebase onto main, ff-merge in the main checkout, the hooks' push proven, worktree and branch gone here and on origin.
commit "$X" x.txt x 'feat x'
git -C "$R" push -q origin feat/x
commit "$R" day.txt d 'day work'
git -C "$R" push -q origin main
wt land "$X" >"$WORK/out" 2>"$WORK/err" || fail "land: $(cat "$WORK/err")"
tip=$(git -C "$R" rev-parse main)
assert [ "$(cat "$WORK/out")" = "landed r feat/x commits=r:$tip" ]
assert [ "$(git -C "$R" log -1 --format=%s main)" = 'feat x' ]
assert [ "$(git -C "$R" log -1 --format=%s main~1)" = 'day work' ]
assert [ "$(origin_main r)" = "$tip" ]
assert [ ! -e "$X" ]
assert_fails git -C "$R" rev-parse -q --verify refs/heads/feat/x
assert_fails git -C "$WORK/r.git" rev-parse -q --verify refs/heads/feat/x
D=$(wt new "$R" doctor-fix/d1)
git -C "$R" update-ref refs/doctor-fix/d1/base main
commit "$D" d1.txt d1 'day fix'
wt land "$D" >/dev/null 2>"$WORK/err" || fail "land doctor-fix: $(cat "$WORK/err")"
assert [ ! -e "$D" ]
assert_fails git -C "$R" rev-parse -q --verify refs/doctor-fix/d1/base

# Every refusal is one line, exit 1, everything in place.
Y="$R/.claude/worktrees/feat-y"
same() { [ "$(git -C "$R" rev-parse main)" = "$1" ] && [ -d "$Y" ] && git -C "$R" rev-parse -q --verify refs/heads/feat/y >/dev/null; }
main0=$(git -C "$R" rev-parse main)
printf 'loose\n' >"$Y/loose.txt"
assert_fails wt land "$Y" 2>"$WORK/err"
assert [ "$(wc -l <"$WORK/err" | tr -d ' ')" = 1 ]
assert grep -qF "$Y has 1 uncommitted files: commit them first" "$WORK/err"
assert same "$main0"
rm "$Y/loose.txt"
# A conflict aborts the rebase: the branch and its worktree as they were.
commit "$Y" c.txt mine 'feat y'
ytip=$(git -C "$R" rev-parse feat/y)
commit "$R" c.txt theirs 'main c'
git -C "$R" push -q origin main
main0=$(git -C "$R" rev-parse main)
assert_fails wt land feat/y --repo "$R" 2>"$WORK/err"
assert grep -qF "the rebase of feat/y onto main stopped on conflicts in c.txt: resolve it in $Y and land again" "$WORK/err"
assert [ "$(git -C "$R" rev-parse feat/y)" = "$ytip" ]
assert [ -z "$(git -C "$Y" status --porcelain)" ]
assert [ ! -d "$(git -C "$Y" rev-parse --git-path rebase-merge)" ]
assert same "$main0"
git -C "$Y" reset -q --hard main
commit "$Y" y.txt y 'feat y'
# The main checkout off main.
git -C "$R" checkout -q -b elsewhere
assert_fails wt land "$Y" 2>"$WORK/err"
assert grep -qF "the main checkout $R is not on main" "$WORK/err"
git -C "$R" checkout -q main && git -C "$R" branch -q -D elsewhere
# Someone's uncommitted edit in the way: git's refusal is the check, and the edit stays.
printf 'theirs\n' >"$R/y.txt"
assert_fails wt land "$Y" 2>"$WORK/err"
assert grep -qF "git refused to fast-forward main in $R to feat/y" "$WORK/err"
assert grep -qF 'y.txt' "$WORK/err"
assert [ "$(cat "$R/y.txt")" = theirs ]
assert same "$main0"
rm "$R/y.txt"
# An open review round blocks it.
printf 'ROUND: rb-open\n\n  0  P2  y.txt  defect\n' >"$WORK/open-rb-open"
assert_fails wt land "$Y" --review rb-1 --review rb-open 2>"$WORK/err"
assert grep -qF "review round rb-open has open findings" "$WORK/err"
assert same "$main0"
# Merged but never pushed: the worktree and branch stay; landing again once pushed finishes it.
git -C "$R" config core.hooksPath "$WORK/no-hooks"
assert_fails env WORKTREE_PUSH_WAIT_S=0 bash "$ROOT/bin/worktree" land "$Y" --review rb-1 2>"$WORK/err"
assert grep -qF "origin main lacks" "$WORK/err"
assert [ "$(git -C "$R" log -1 --format=%s main)" = 'feat y' ]
assert [ -d "$Y" ]
git -C "$R" push -q origin main
wt land "$Y" >"$WORK/out" || fail "land again once pushed"
assert [ "$(cat "$WORK/out")" = "landed r feat/y commits=" ]
assert [ ! -e "$Y" ]
git -C "$R" config core.hooksPath "$WORK/hooks"

# A night branch still on its night's base lands only its own commits: --onto main past the base.
commit "$N" n.txt n 'night a'
wt land "$N" >"$WORK/out" || fail "night land"
assert [ "$(git -C "$R" log -1 --format=%s main)" = 'night a' ]
assert [ "$(git -C "$R" log -1 --format=%s main~1)" = 'feat y' ]
assert [ ! -e "$R/wip.txt" ]
# A Code fixer branch passes code-doctor check first; once landed its worktree stays for that check.
C="$(wt new "$R" night/n1/code-code-20261001T020700Z-0b0b)" || fail "code new"
commit "$C" k.txt k 'code fix'
printf '{"id": "code-code-20261001T020700Z-0b0b", "doctor": "code"}\n' >"$DOCTORS_DIR/runs/code-code-20261001T020700Z-0b0b.json"
main0=$(git -C "$R" rev-parse main)
assert_fails wt land "$C" 2>"$WORK/err"
assert grep -qF "green suites not confirmed" "$WORK/err"
assert grep -qxF "check $DOCTORS_DIR/runs/code-code-20261001T020700Z-0b0b.json --base refs/night/n1/base --landing" "$WORK/code-checks"
assert [ "$(git -C "$R" rev-parse main)" = "$main0" ]
wt land "$C" --suites-passed >"$WORK/out" || fail "code land"
assert grep -qF "kept $C: code-doctor check reads the Code fixer run from it" "$WORK/out"
assert [ "$(git -C "$R" log -1 --format=%s main)" = 'code fix' ]
assert [ -d "$C" ]
# A process standing in a landed worktree keeps it; another's branch with no worktree just goes.
P="$(wt new "$R" feat/busy)" || fail "busy new"
commit "$P" p.txt p 'busy'
(cd "$P" && exec sleep 30) &
sleep 0.5
wt land "$P" >"$WORK/out" || fail "busy land"
assert grep -qF "kept $P: processes inside" "$WORK/out"
assert [ -d "$P" ]
git -C "$R" branch -q plain main && git -C "$R" checkout -q plain && commit "$R" q.txt q 'plain' && git -C "$R" checkout -q main
wt land plain --repo "$R" >"$WORK/out" || fail "branch land"
assert [ "$(git -C "$R" log -1 --format=%s main)" = plain ]
assert_fails git -C "$R" rev-parse -q --verify refs/heads/plain
assert [ "$(origin_main r)" = "$(git -C "$R" rev-parse main)" ]

echo "PASS: test_worktree.sh ($asserts asserts)"
