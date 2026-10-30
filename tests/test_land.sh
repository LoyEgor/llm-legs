#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# bin/land on fixture repositories whose tests/affected and tests/run-all are stubs: what it selects, where the suites
# run, what lands, and what stays when it cannot (the three night hubs' land.sh bugs of 10-29/30 among them).
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'kill $(jobs -p) 2>/dev/null; [ -n "${KEEP:-}" ] || rm -rf "$WORK"' EXIT
asserts=0
STUB="$WORK/stub"
export HOME="$WORK/home" XDG_CACHE_HOME="$WORK/xdg" RUN_SUITES_JOURNAL="$WORK/runs.jsonl" STUB \
  GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1 NIGHT_RUN_SWEEP_REPOS="$WORK/sweep"
unset CLAUDE_CODE_SESSION_ID WORKER_RUN_ID
mkdir -p "$HOME" "$STUB"
printf '[user]\n\tname = t\n\temail = t@t\n[core]\n\thooksPath = /dev/null\n[init]\n\tdefaultBranch = main\n' >"$GIT_CONFIG_GLOBAL"
LAND="$ROOT/bin/land"

# Stubs: affected prints <repo>.overlap or <repo>.covering as paths in its own tests dir, notes a worker run's id and
# runs $STUB/ahook once if present; run-all journals one row, a suite red while its red.<suite> count lasts, and runs
# $STUB/hook once if present.
cat >"$WORK/affected" <<'EOF'
#!/usr/bin/env bash
d=$(cd "$(dirname "$0")" && pwd -P) n=$(cat "$(dirname "$0")/name")
echo "$n $*" >>"$STUB/calls"
[ -z "${WORKER_RUN_ID:-}" ] || echo "$n $WORKER_RUN_ID" >>"$STUB/worker"
if [ -x "$STUB/ahook" ]; then mv "$STUB/ahook" "$STUB/ahook.ran"; "$STUB/ahook.ran" "$n"; fi
if [ "${1:-}" = --overlap ]; then f="$STUB/$n.overlap"; else f="$STUB/$n.covering"; fi
[ ! -r "$f" ] || sed "s|^|$d/|" "$f"
EOF
cat >"$WORK/run-all" <<'EOF'
#!/usr/bin/env bash
d=$(cd "$(dirname "$0")" && pwd -P) n=$(cat "$(dirname "$0")/name") rows='' rc=0
for s in "$@"; do
  s=${s##*/} r=0
  echo "$n $d $s" >>"$STUB/ran"
  if [ -r "$STUB/red.$s" ] && [ "$(cat "$STUB/red.$s")" -gt 0 ]; then echo $(($(cat "$STUB/red.$s") - 1)) >"$STUB/red.$s"; r=1 rc=1; fi
  rows="$rows${rows:+,}\"$s\":{\"rc\":$r}"
done
if [ -x "$STUB/hook" ]; then mv "$STUB/hook" "$STUB/hook.ran"; "$STUB/hook.ran" "$n"; fi
printf '{"kind":"suites","pid":%s,"started_at":%s,"suites":{%s}}\n' "$$" "$(date +%s)" "$rows" >>"$RUN_SUITES_JOURNAL"
exit $rc
EOF

repo() { # name -> main checkout $WORK/<name> on the sweep list, its stub suites committed
  mkdir -p "$WORK/$1/tests"
  git -C "$WORK/$1" init -q
  printf '%s\n' "$1" >"$WORK/$1/tests/name"
  cp "$WORK/affected" "$WORK/run-all" "$WORK/$1/tests/" && chmod +x "$WORK/$1/tests/affected" "$WORK/$1/tests/run-all"
  printf 'one\n' >"$WORK/$1/file"
  git -C "$WORK/$1" add -A && git -C "$WORK/$1" commit -qm init
  printf '%s\n' "$WORK/$1" >>"$NIGHT_RUN_SWEEP_REPOS"
}
tree() { # repo branch [start] -> its worktree $WORK/wt/<repo>-<branch>
  git -C "$WORK/$1" worktree add -q -b "$2" "$WORK/wt/$1-${2//\//-}" "${3:-main}" && printf '%s\n' "$WORK/wt/$1-${2//\//-}"
}
change() { # dir file text subject
  printf '%s\n' "$3" >"$1/$2" && git -C "$1" add "$2" && git -C "$1" commit -qm "$4"
}
land() { (cd "$WORK" && "$LAND" "$@") >"$WORK/out" 2>&1; }
subjects() { git -C "$WORK/$1" log --format=%s main; }
ran() { cat "$STUB/ran" 2>/dev/null; }
reset_stub() { rm -f "$STUB"/*; }

assert_fails land
assert grep -q usage "$WORK/out"

# A day branch main did not move under: no overlap, no suite, main fast-forwards, worktree and branch go.
repo a; wt=$(tree a feat/x); change "$wt" x 'x' 'a: x'
assert land feat/x --repo "$WORK/a"
assert grep -qx 'landed a@[0-9a-f]\{12\}' "$WORK/out"
assert grep -qx 'commits=a:[0-9a-f]\{12\}' "$WORK/out"
assert test "$(subjects a | head -1)" = 'a: x'
assert test ! -d "$wt"
assert_fails git -C "$WORK/a" show-ref -q --verify refs/heads/feat/x
assert test -z "$(ran)"
assert grep -q '^a --overlap ' "$STUB/calls"

# Main moved: the overlap runs in the branch's own worktree, never the main checkout's copy (night 5921's false green).
reset_stub; repo b; wt=$(tree b feat/y); change "$wt" y y 'b: y'; change "$WORK/b" z z 'b: main z'
printf 'test_o.sh\n' >"$STUB/b.overlap"
assert land feat/y --repo "$WORK/b"
assert test "$(ran)" = "b $wt/tests test_o.sh"
assert test "$(subjects b | head -2 | tr '\n' ,)" = 'b: y,b: main z,'

# A night branch on its press snapshot: every covering suite runs (its worker ran none), the overlap is not asked,
# and the snapshot commit stays off main; an older night's base already on main is no base.
reset_stub; repo c
git -C "$WORK/c" update-ref refs/night/old/base main
snapwt="$WORK/wt/c-snap"; git -C "$WORK/c" worktree add -q --detach "$snapwt" main
change "$snapwt" wip wip 'c: snapshot'; git -C "$WORK/c" update-ref refs/night/n1/base "$(git -C "$snapwt" rev-parse HEAD)"
git -C "$WORK/c" worktree remove "$snapwt"
wt=$(tree c night/n1/fix refs/night/n1/base); change "$wt" fix fix 'c: fix'
change "$WORK/c" other other 'c: main other'
printf 'test_cov.sh\n' >"$STUB/c.covering"; printf 'test_over.sh\n' >"$STUB/c.overlap"
assert land night/n1/fix
assert test "$(ran)" = "c $wt/tests test_cov.sh"
assert_fails grep -q -- '--overlap' "$STUB/calls"
assert test "$(subjects c | tr '\n' ,)" = 'c: fix,c: main other,init,'

# One red suite reruns alone, the green ones never again (night 74c1 reran ~40); green alone lands as flaky.
reset_stub; repo d; wt=$(tree d feat/f); change "$wt" f f 'd: f'; change "$WORK/d" g g 'd: main g'
printf 'test_f.sh\ntest_g.sh\n' >"$STUB/d.overlap"; echo 1 >"$STUB/red.test_f.sh"
assert land feat/f --repo "$WORK/d"
assert test "$(ran | grep -c test_g.sh)" = 1
assert test "$(ran | grep -c test_f.sh)" = 2
assert grep -qx 'flaky test_f.sh' "$WORK/out"
assert test "$(subjects d | head -1)" = 'd: f'

# Red twice: back to the worker, main untouched, branch and worktree kept.
reset_stub; repo e; wt=$(tree e feat/r); change "$wt" r r 'e: r'; change "$WORK/e" s s 'e: main s'
printf 'test_r.sh\n' >"$STUB/e.overlap"; echo 2 >"$STUB/red.test_r.sh"
assert_fails land feat/r --repo "$WORK/e"
assert test "$(subjects e | head -1)" = 'e: main s'
assert test -d "$wt"
assert git -C "$WORK/e" show-ref -q --verify refs/heads/feat/r

# A conflict aborts its rebase: exit 1, no rebase left in progress, the branch tip unchanged.
reset_stub; repo f; wt=$(tree f feat/c); change "$wt" file mine 'f: mine'; change "$WORK/f" file theirs 'f: theirs'
tip=$(git -C "$wt" rev-parse HEAD)
assert_fails land feat/c --repo "$WORK/f"
assert grep -q conflicts "$WORK/out"
assert test ! -e "$(git -C "$wt" rev-parse --path-format=absolute --git-path rebase-merge)"
assert test "$(git -C "$wt" rev-parse HEAD)" = "$tip"

# Another land holding the branch: exit 3, nothing moves; a dead holder's lock is taken over.
reset_stub; repo g; wt=$(tree g feat/g); change "$wt" g g 'g: g'
lock="$WORK/g/.git/land-feat+g.lock"; mkdir "$lock"
sleep 60 & holder=$!; echo "$holder" >"$lock/pid"
land feat/g --repo "$WORK/g"; assert test $? = 3
assert test "$(subjects g | head -1)" = init
assert grep -q "pid $holder, [0-9]* s, sleep 60: bin/wait-until pid $holder" "$WORK/out"
kill "$holder"; wait "$holder" 2>/dev/null
assert land feat/g --repo "$WORK/g"
assert test "$(subjects g | head -1)" = 'g: g'
assert test ! -d "$lock"

# Main moving while the suites run (another lander): the merge is refused, the next pass rebases and lands.
reset_stub; repo h; wt=$(tree h feat/h); change "$wt" h h 'h: h'; change "$WORK/h" i i 'h: main i'
printf 'test_h.sh\n' >"$STUB/h.overlap"
printf '#!/usr/bin/env bash\ncd "%s" && printf j >j && git add j && git commit -qm "h: other lander"\n' "$WORK/h" >"$STUB/hook"
chmod +x "$STUB/hook"
assert land feat/h --repo "$WORK/h"
assert test "$(subjects h | head -3 | tr '\n' ,)" = 'h: h,h: other lander,h: main i,'
assert test "$(grep -c '^h --overlap' "$STUB/calls")" = 2

# A night branch across repositories: each with commits lands, one without only loses its worktree and branch.
reset_stub; repo i1; repo i2; repo i3
w1=$(tree i1 night/n2/two); w2=$(tree i2 night/n2/two); w3=$(tree i3 night/n2/two)
change "$w1" one one 'i1: one'; change "$w2" two two 'i2: two'
assert land night/n2/two
assert grep -q '^commits=i1:[0-9a-f]\{12\},i2:[0-9a-f]\{12\}$' "$WORK/out"
assert_fails grep -q 'landed i3' "$WORK/out"
assert test ! -d "$w3"
assert_fails git -C "$WORK/i3" show-ref -q --verify refs/heads/night/n2/two

# Any other branch lands only where it is named: a stale namesake in another sweep repository stays.
reset_stub; repo s1; repo s2; ws1=$(tree s1 feat/same); ws2=$(tree s2 feat/same)
change "$ws1" s s 's1: new'; change "$ws2" s s 's2: stale'
assert land feat/same --repo "$WORK/s1"
assert test "$(subjects s1 | head -1)" = 's1: new'
assert test "$(subjects s2 | head -1)" = init
assert test -d "$ws2"

# The main checkout's own uncommitted edit of a landed file: exit 3, the edit and the branch kept.
reset_stub; repo j; wt=$(tree j feat/j); change "$wt" file branch 'j: file'
printf 'wip\n' >"$WORK/j/file"
land feat/j --repo "$WORK/j"; assert test $? = 3
assert test "$(cat "$WORK/j/file")" = wip
assert git -C "$WORK/j" show-ref -q --verify refs/heads/feat/j
git -C "$WORK/j" checkout -q -- file

# Uncommitted work in the worktree goes back to the worker.
reset_stub; repo m; wt=$(tree m feat/m); change "$wt" m m 'm: m'; printf 'dirty\n' >"$wt/m"
assert_fails land feat/m --repo "$WORK/m"
assert grep -q 'uncommitted work' "$WORK/out"

# Two lands into one main at once: both land, neither waits on the other.
reset_stub; repo k; w1=$(tree k feat/k1); w2=$(tree k feat/k2); change "$w1" k1 k1 'k: k1'; change "$w2" k2 k2 'k: k2'
(cd "$WORK" && "$LAND" feat/k1 --repo "$WORK/k" >"$WORK/k1.out" 2>&1; echo $? >"$WORK/k1.rc") &
(cd "$WORK" && "$LAND" feat/k2 --repo "$WORK/k" >"$WORK/k2.out" 2>&1; echo $? >"$WORK/k2.rc") &
wait
assert test "$(cat "$WORK/k1.rc")$(cat "$WORK/k2.rc")" = 00
assert test "$(subjects k | sort | tr '\n' ,)" = 'init,k: k1,k: k2,'

# An older night's leftover, adopted and rebased onto this night's snapshot as its brief says, holds a copy of the old
# snapshot no ref names: neither lands. night-run's snapshot subject is the one land knows a copy by.
snap() { # repo night -> refs/night/<night>/base: pressed work on main, committed the way night-run's snapshot is
  local s="$WORK/wt/$1-snap-$2"
  git -C "$WORK/$1" worktree add -q --detach "$s" main && change "$s" "wip.$2" "$2" "night $2 base: the checkout as pressed" &&
    git -C "$WORK/$1" update-ref "refs/night/$2/base" "$(git -C "$s" rev-parse HEAD)" && git -C "$WORK/$1" worktree remove "$s"
}
assert grep -qF '"night $2 base: the checkout as pressed"' "$ROOT/bin/night-run"
reset_stub; repo n; snap n o1; old=$(tree n night/o1/x refs/night/o1/base); change "$old" x x 'n: x'
change "$WORK/n" y y 'n: main y'; snap n o2
wt=$(tree n night/o2/leftover-x night/o1/x); git -C "$wt" rebase -q refs/night/o2/base
assert land night/o2/leftover-x
assert test "$(subjects n | tr '\n' ,)" = 'n: x,n: main y,init,'

# Main moving between the selection and the rebase (another lander): its commit never lands untested, the next pass
# selects the suites it shares with the branch.
reset_stub; repo p; wt=$(tree p feat/p); change "$wt" p p 'p: p'; change "$WORK/p" q q 'p: main q'
printf '#!/usr/bin/env bash\ncd "%s" && printf r >r && git add r && git commit -qm "p: other lander"\n' "$WORK/p" >"$STUB/ahook"
chmod +x "$STUB/ahook"
assert land feat/p --repo "$WORK/p"
assert test "$(subjects p | head -3 | tr '\n' ,)" = 'p: p,p: other lander,p: main q,'
assert test "$(grep -c '^p --overlap' "$STUB/calls")" = 2

# A land from inside a worker run selects a night branch's covering suites as no worker's: the slow layer stays in.
reset_stub; repo q; wt=$(tree q night/n3/q); change "$wt" q q 'q: q'; printf 'test_q.sh\n' >"$STUB/q.covering"
export WORKER_RUN_ID=w1
assert land night/n3/q
unset WORKER_RUN_ID
assert test "$(ran)" = "q $wt/tests test_q.sh"
assert test ! -e "$STUB/worker"

# A namesake on origin is never land's to delete: the autopush hook deletes only the branches it pushed.
reset_stub; repo o; git clone -q --bare "$WORK/o" "$WORK/o.git"; git -C "$WORK/o" remote add origin "$WORK/o.git"
git -C "$WORK/o.git" branch feat/o main; git -C "$WORK/o" fetch -q origin
wt=$(tree o feat/o); change "$wt" o o 'o: o'
assert land feat/o --repo "$WORK/o"
assert test "$(subjects o | head -1)" = 'o: o'
assert git -C "$WORK/o.git" show-ref -q --verify refs/heads/feat/o

# The main checkout switched off main while the suites ran: exit 3, the other branch untouched, the branch kept.
reset_stub; repo u; wt=$(tree u feat/u); change "$wt" u u 'u: u'; change "$WORK/u" v v 'u: main v'
printf 'test_u.sh\n' >"$STUB/u.overlap"
printf '#!/usr/bin/env bash\ngit -C "%s" checkout -q -b other\n' "$WORK/u" >"$STUB/hook"; chmod +x "$STUB/hook"
land feat/u --repo "$WORK/u"; assert test $? = 3
assert grep -q 'is on the branch other: land again once it is back on main' "$WORK/out"
assert test "$(git -C "$WORK/u" log -1 --format=%s other)" = 'u: main v'
assert git -C "$WORK/u" show-ref -q --verify refs/heads/feat/u
git -C "$WORK/u" checkout -q main

# The base costs the same few git calls however many nights left a snapshot ref (one is added every night).
reset_stub; repo w; for n in 1 2 3 4 5 6; do git -C "$WORK/w" update-ref "refs/night/w$n/base" main; done
wt=$(tree w feat/w); change "$wt" w w 'w: w'
export GIT_TRACE="$WORK/trace"
assert land feat/w --repo "$WORK/w"
unset GIT_TRACE
assert test "$(grep -c 'git merge-base' "$WORK/trace")" -le 1

# Exit 3 tells the orchestrator what to wait for.
assert grep -q 'wait-until pid <n>' "$ROOT/docs/fix-orchestrator.md"

# A branch named with --repo lands only there, never on a namesake another session holds where land runs from.
reset_stub; repo x1; repo x2; wx1=$(tree x1 feat/z); wx2=$(tree x2 feat/z)
change "$wx1" z z 'x1: other session'; change "$wx2" z z 'x2: z'
(cd "$WORK/x1" && "$LAND" feat/z --repo "$WORK/x2") >"$WORK/out" 2>&1
assert test "$(subjects x2 | head -1)" = 'x2: z'
assert test "$(subjects x1 | head -1)" = init
assert test -d "$wx1"

# Repositories go in sorted order, wherever land runs from: two lands of one branch take its locks in one order.
reset_stub; repo y1; repo y2; wy1=$(tree y1 night/n4/y); wy2=$(tree y2 night/n4/y)
change "$wy1" y y 'y1: y'; change "$wy2" y y 'y2: y'
(cd "$WORK/y2" && "$LAND" night/n4/y) >"$WORK/out" 2>&1
assert grep -q '^commits=y1:[0-9a-f]\{12\},y2:[0-9a-f]\{12\}$' "$WORK/out"

# A stop after one repository landed: its commits= still prints, its worktree stays for its siblings' suites until
# all have landed, and the rerun reports it again and tears it down.
reset_stub; repo r1; repo r2; wr1=$(tree r1 night/n5/r); wr2=$(tree r2 night/n5/r)
change "$wr1" r r 'r1: r'; change "$wr2" r r 'r2: r'; printf 'test_r2.sh\n' >"$STUB/r2.covering"
printf '#!/usr/bin/env bash\ngit -C "%s" checkout -q -b other\n' "$WORK/r2" >"$STUB/hook"; chmod +x "$STUB/hook"
land night/n5/r; assert test $? = 3
assert grep -q '^commits=r1:[0-9a-f]\{12\}$' "$WORK/out"
assert test -d "$wr1"
git -C "$WORK/r2" checkout -q main
assert land night/n5/r
assert grep -q '^commits=r1:[0-9a-f]\{12\},r2:[0-9a-f]\{12\}$' "$WORK/out"
assert test ! -d "$wr1"
assert_fails git -C "$WORK/r1" show-ref -q --verify refs/heads/night/n5/r

# A land killed after its fast-forward and the worktree's removal: the rerun reports the landing, deletes the branch.
reset_stub; repo v; wt=$(tree v feat/v); change "$wt" v v 'v: v'
git -C "$WORK/v" update-ref refs/land/feat/v main; git -C "$WORK/v" merge -q --ff-only feat/v
git -C "$WORK/v" worktree remove "$wt"
assert land feat/v --repo "$WORK/v"
assert grep -qx "commits=v:$(git -C "$WORK/v" rev-parse --short=12 main)" "$WORK/out"
assert_fails git -C "$WORK/v" show-ref -q --verify refs/heads/feat/v

# A worktree left detached mid-rebase: without a land's mark the rebase is the worker's; with it, a killed land's,
# aborted, and the branch lands.
reset_stub; repo z; wt=$(tree z feat/zr); change "$wt" file mine 'z: mine'
git -C "$WORK/z" checkout -q -b side; change "$WORK/z" file theirs 'z: side'; git -C "$WORK/z" checkout -q main
git -C "$wt" rebase -q side >/dev/null 2>&1
land feat/zr --repo "$WORK/z"; assert test $? = 1
assert grep -q 'a rebase of feat/zr is in progress' "$WORK/out"
git -C "$WORK/z" update-ref refs/land/feat/zr main
assert land feat/zr --repo "$WORK/z"
assert test "$(subjects z | head -1)" = 'z: mine'

# The worker committing while the suites run: its untested commit never lands.
reset_stub; repo t; wt=$(tree t feat/t); change "$wt" t t 't: t'; change "$WORK/t" u u 't: main u'
printf 'test_t.sh\n' >"$STUB/t.overlap"
printf '#!/usr/bin/env bash\ncd "%s" && printf late >late && git add late && git commit -qm "t: untested"\n' "$wt" >"$STUB/hook"
chmod +x "$STUB/hook"
land feat/t --repo "$WORK/t"; assert test $? = 3
assert test -z "$(subjects t | grep untested)"

# A commit in the main checkout right after the fast-forward is never reported as the landing.
reset_stub; repo l; wt=$(tree l feat/l); change "$wt" l l 'l: l'; tip=$(git -C "$wt" rev-parse HEAD)
mkdir -p "$WORK/lhooks"; git -C "$WORK/l" config core.hooksPath "$WORK/lhooks"
printf '#!/usr/bin/env bash\nprintf m >m && git add m && git commit -qm "l: after"\n' >"$WORK/lhooks/post-merge"
chmod +x "$WORK/lhooks/post-merge"
assert land feat/l --repo "$WORK/l"
assert grep -qx "commits=l:${tip:0:12}" "$WORK/out"

# A new file the worker never added goes back to the worker too.
reset_stub; repo nf; wt=$(tree nf feat/nf); change "$wt" n n 'nf: n'; printf 'new\n' >"$wt/stray"
assert_fails land feat/nf --repo "$WORK/nf"
assert grep -q 'uncommitted work.*stray' "$WORK/out"

# A rebase git refuses with no conflict (the worktree's index.lock) is no conflict: exit 3, naming the lock's age.
reset_stub; repo il; wt=$(tree il feat/il); change "$wt" i i 'il: i'; change "$WORK/il" j j 'il: main j'
ilock=$(git -C "$wt" rev-parse --path-format=absolute --git-path index.lock); : >"$ilock"
land feat/il --repo "$WORK/il"; assert test $? = 3
assert grep -q 'index.lock, [0-9]* s old' "$WORK/out"
rm -f "$ilock"

# The main checkout's leftover index.lock: exit 3 naming its age, never git's advice to delete it.
reset_stub; repo ix; wt=$(tree ix feat/ix); change "$wt" x x 'ix: x'; : >"$WORK/ix/.git/index.lock"
land feat/ix --repo "$WORK/ix"; assert test $? = 3
assert grep -q "index.lock, [0-9]* s old" "$WORK/out"
assert_fails grep -q 'remove the file' "$WORK/out"
rm -f "$WORK/ix/.git/index.lock"

# Main moving under every pass: exit 3 with the commits it gained.
reset_stub; repo ch; wt=$(tree ch feat/ch); change "$wt" c c 'ch: c'; change "$WORK/ch" d d 'ch: main d'
printf 'test_ch.sh\n' >"$STUB/ch.overlap"
printf '#!/usr/bin/env bash\ncp "$0" "$STUB/hook"; cd "%s" && echo x >>churn && git add churn && git commit -qm "ch: churn"\n' \
  "$WORK/ch" >"$STUB/hook"; chmod +x "$STUB/hook"
land feat/ch --repo "$WORK/ch"; assert test $? = 3
assert grep -q 'main gained 5 commits' "$WORK/out"

# The main checkout's uncommitted edit of a file the branch changes stops land before the suites, not after them.
reset_stub; repo dw; wt=$(tree dw feat/dw); change "$wt" file branch 'dw: file'; change "$WORK/dw" e e 'dw: main e'
printf 'test_dw.sh\n' >"$STUB/dw.overlap"; printf 'wip\n' >"$WORK/dw/file"
land feat/dw --repo "$WORK/dw"; assert test $? = 3
assert test -z "$(ran)"
assert grep -q 'uncommitted edits to file' "$WORK/out"
git -C "$WORK/dw" checkout -q -- file

# A land killed during its suites (the background Bash cap): the rerun ends the orphaned run-all and selects from the
# base the killed rebase started from, not from the main it rebased onto.
reset_stub; repo kk; wt=$(tree kk feat/kk); change "$wt" k k 'kk: k'; change "$WORK/kk" m m 'kk: main m'
b0=$(git -C "$WORK/kk" rev-parse main~1); printf 'test_kk.sh\n' >"$STUB/kk.overlap"
printf '#!/usr/bin/env bash\necho $PPID >"$STUB/orphan"; kill -9 $(ps -o ppid= -p $PPID); sleep 20\n' >"$STUB/hook"
chmod +x "$STUB/hook"
{ land feat/kk --repo "$WORK/kk"; } 2>/dev/null
assert land feat/kk --repo "$WORK/kk"
assert test "$(grep '^kk --overlap' "$STUB/calls" | tail -1)" = "kk --overlap $b0"
assert test -z "$(ps -o pid= -p "$(cat "$STUB/orphan")")"
assert_fails git -C "$WORK/kk" show-ref -q --verify refs/land/feat/kk

printf 'PASS: %s asserts; land selects, runs in the worktree, retries a moved main and keeps everything it cannot land\n' "$asserts"
