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

unset WORKER_RUN_DIR
export HOME="$WORK/home" XDG_CACHE_HOME="$WORK/cache" CLAUDE_LAUNCHER_SESSION=sid-land GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export HARNESS_LAND_DIR="$WORK/land" HARNESS_WAITS_DIR="$WORK/waits"
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
    printf '#!/bin/bash\necho "$*" >>"%s/affected.log"\n[ ! -e "%s/affected-red" ] || exit 1\necho tests/test_x.sh\n' "$T" "$T" >"$M/tests/affected"
    printf '#!/bin/bash\necho "${WORKER_RUN_ID:-}$*" >>"%s/run-all.log"\n[ ! -e "%s/slow" ] || sleep 1.2\n[ ! -e "%s/red" ]\n' "$T" "$T" "$T" >"$M/tests/run-all"
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
journal() { # jq filter the last land journal row must pass
  local last
  last=$(cat "$HARNESS_LAND_DIR"/*.jsonl 2>/dev/null | tail -1)
  jq -e "$1" >/dev/null 2>&1 <<<"$last" || { printf 'last land row fails [%s]:\n%s\n' "$1" "$last" >&2; return 1; }
}
suite_waits() { cat "$HARNESS_WAITS_DIR"/*.jsonl 2>/dev/null | grep -c '"class":"suites","source":"land main/feat"'; }
gone() { [ ! -e "$W" ] && ! git -C "$M" rev-parse -q --verify refs/heads/feat >/dev/null; }
kept() { [ -d "$W" ] && git -C "$M" rev-parse -q --verify refs/heads/feat >/dev/null; }

# Plain fast-forward from inside the worktree: pushed, worktree and branch gone.
setup plain
branch_edit a.txt "$(lines A)"
tip=$(sha "$W" HEAD)
land_in "$W"
assert eq "$rc" 0
assert eq "$(cat "$T/out")" "landed feat → main $(git -C "$M" rev-parse --short "$tip"), suites: skipped"
assert eq "$(sha "$M" main)" "$tip"
assert eq "$(sha "$R" main)" "$tip"
assert eq "$(git -C "$M" status --porcelain)" ""
assert gone
assert journal '.outcome == "landed" and .reason == null and .repo == "main" and .branch == "feat" and .tries == 1
  and .suites == 0 and .suite_secs == 0 and .behind == null and .kept == null and .conflict_files == null
  and (.secs | type) == "number" and (.at | type) == "number"'
pushes() { cat "$XDG_CACHE_HOME"/claude-reports/sid-land/pending/*__push__* 2>/dev/null; }
short_tip=$(git -C "$M" rev-parse --short "$tip")
assert eq "$(pushes | jq -r '.id')" "main-----feat-${short_tip}-origin-main"
assert pushes | jq -e --arg p "$short_tip → origin/main" '.body | contains($p) and contains("main ⧉ feat")' >/dev/null
rm -f "$XDG_CACHE_HOME"/claude-reports/sid-land/pending/*

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
assert eq "$(cat "$T/out")" "landed feat → main $(git -C "$M" rev-parse --short "$tip"), suites: skipped"
assert eq "$(cat "$T/err")" "land: warning: landed, but $W and branch feat stay, processes inside: $busy sleep 600; nothing killed, night-run finish prunes them once they end"
assert eq "$(sha "$R" main)" "$tip"
assert eq "$alive" 1
assert kept
assert journal '.outcome == "landed" and .kept == "worktree (held)"'

# Foreign WIP the landing does not touch stays byte for byte through the fast-forward.
setup wip
branch_edit a.txt "$(lines A)"
tip=$(sha "$W" HEAD)
printf 'wip b\n' >>"$M/b.txt"; cp "$M/b.txt" "$T/b.wip"
printf 'untracked\n' >"$M/u.txt"
land_in "$W"
assert eq "$rc" 0
assert eq "$(sha "$M" main)" "$tip"
assert cmp -s "$M/b.txt" "$T/b.wip"
assert eq "$(cat "$M/u.txt")" untracked
assert eq "$(git -C "$M" status --porcelain | tr '\n' ' ')" " M b.txt ?? u.txt "
assert eq "$(cat "$T/err")" ""
assert gone

# WIP on a file the landing changes: pushed anyway, git refuses the checkout's fast-forward, the WIP
# byte-identical, the checkout left behind, the warning naming the file and its holder.
setup wipoverlap
branch_edit a.txt "$(lines a | sed 's/^a8$/FEAT8/')"
sed 's/^a8$/WIP8/' "$M/a.txt" >"$T/a.wip" && cp "$T/a.wip" "$M/a.txt"
key=$(cd "$(git -C "$M" rev-parse --absolute-git-dir)" && pwd -P)
printf '1\tsid-old\t%s\ta.txt\n9\tsid-foreign\t%s\ta.txt\n9\tsid-other\tx\ta.txt\n' "$key" "$key" >"$(git -C "$M" rev-parse --path-format=absolute --git-common-dir)/claude-writes"
main_before=$(sha "$M" main) tip=$(sha "$W" HEAD)
land_in "$W"
assert eq "$rc" 0
assert eq "$(sha "$R" main)" "$tip"
assert eq "$(sha "$M" main)" "$main_before"
assert cmp -s "$M/a.txt" "$T/a.wip"
assert eq "$(cat "$T/err")" "land: warning: the main checkout $M stays at $(git -C "$M" rev-parse --short main): a.txt (holder: Foreign Chat) in the way; the next land catches it up, night-run leftovers lists it until then"
assert gone
assert journal '.outcome == "landed" and .behind.files == [{"file": "a.txt", "holder": "Foreign Chat"}]
  and (.behind.why | test("stays at [0-9a-f]+: a.txt \\(holder: Foreign Chat\\) in the way"))'

# An untracked file in the way: landed, the file kept, the checkout behind with the file named.
setup untracked
branch_edit n.txt "from feat"
printf 'foreign\n' >"$M/n.txt"
main_before=$(sha "$M" main)
land_in "$W"
assert eq "$rc" 0
assert has "$T/err" "n.txt (holder: unknown) in the way"
assert eq "$(cat "$M/n.txt")" foreign
assert eq "$(sha "$R" main)" "$(sha "$M" refs/remotes/origin/main)"
assert eq "$(sha "$M" main)" "$main_before"
assert gone

# Renames: a staged rename in the WIP is in the way under its old name; a branch rename counts both
# names, so upstream edits to the old name run the suites.
setup renames suites
git -C "$W" mv c.txt c2.txt && git -C "$W" commit -qm "feat renames c"
branch_edit b.txt "$(lines B)"
other_lands c.txt "$(lines c | sed 's/^c1$/OTHER1/')" "other edits c1"
git -C "$M" mv b.txt b2.txt
main_before=$(sha "$M" main)
land_in "$W"
assert eq "$rc" 0
assert grep -qE '^landed feat → main [0-9a-f]+, suites: ran 1$' "$T/out"
assert has "$T/err" "b.txt (holder: unknown) in the way"
assert eq "$(git -C "$R" show main:c2.txt | head -1)" OTHER1
assert eq "$(sha "$M" main)" "$main_before"
assert eq "$(git -C "$M" status --porcelain | tr '\n' ' ')" "R  b.txt -> b2.txt "

# Another chat commits on local main while land runs: landed on origin, local main left to its owner,
# named in a warning; a second land still lands; land in the main checkout then publishes the stray
# commit over foreign WIP, and the checkout catches up keeping that WIP.
setup concurrent
branch_edit a.txt "$(lines A)"
hook="$(git -C "$M" rev-parse --path-format=absolute --git-common-dir)/hooks/pre-push"
printf '#!/bin/bash\n[ -e "%s/moved" ] && exit 0\n: >"%s/moved"\nprintf x >"%s/c.txt" && git -C "%s" commit -qam "stray on main"\n' "$T" "$T" "$M" "$M" >"$hook"
chmod +x "$hook"
land_in "$W"
assert eq "$rc" 0
assert eq "$(git -C "$R" log --format=%s -2 main | tr '\n' '|')" "feat edits a.txt|init|"
assert eq "$(git -C "$M" log --format=%s -2 main | tr '\n' '|')" "stray on main|init|"
assert has "$T/err" "land: warning: local main has commits not on origin/main, left to their owner: $(git -C "$M" rev-parse --short main) stray on main; land in the main checkout publishes them"
assert gone
git -C "$M" worktree add -q -b feat "$W" origin/main
branch_edit b.txt "$(lines B)"
land_in "$W"
assert eq "$rc" 0
assert eq "$(git -C "$R" log --format=%s -3 main | tr '\n' '|')" "feat edits b.txt|feat edits a.txt|init|"
assert has "$T/err" "stray on main"
assert gone
printf 'wip c\n' >>"$M/c.txt"; cp "$M/c.txt" "$T/c.wip"
land_in "$M"
assert eq "$rc" 0
assert has "$T/out" "landed main → main"
assert eq "$(git -C "$R" log --format=%s -4 main | tr '\n' '|')" "stray on main|feat edits b.txt|feat edits a.txt|init|"
assert eq "$(sha "$M" main)" "$(sha "$R" main)"
assert cmp -s "$M/c.txt" "$T/c.wip"
assert eq "$(cat "$T/err")" ""
assert eq "$(git -C "$M" worktree list | wc -l | tr -d ' ')" 1
land_in "$M"
assert eq "$(cat "$T/out")" "main has no unpushed commits: nothing to land"
assert journal '.outcome == "nothing" and .reason == null and .branch == "main" and .tries == 0'

# Local commits on main that only add to origin/main land with the branch.
setup onmain
commit "$M" c.txt "$(lines C)" "main local"
branch_edit a.txt "$(lines A)"
land_in "$W"
assert eq "$rc" 0
assert eq "$(git -C "$R" log --format=%s -3 main | tr '\n' '|')" "feat edits a.txt|main local|init|"
assert eq "$(sha "$M" main)" "$(sha "$R" main)"

# A commit added to the branch after its rebase survives the landing.
setup late
branch_edit a.txt "$(lines A)"
tip=$(sha "$W" HEAD)
hook="$(git -C "$M" rev-parse --path-format=absolute --git-common-dir)/hooks/pre-push"
printf '#!/bin/bash\ngit -C "%s" commit -q --allow-empty -m late\n' "$W" >"$hook" && chmod +x "$hook"
land_in "$W"
assert eq "$rc" 0
assert eq "$(sha "$R" main)" "$tip"
assert eq "$(git -C "$M" log --format=%s -1 feat)" late
assert has "$T/err" "branch feat got commits after the rebase and stays"
assert journal '.outcome == "landed" and .kept == "branch"'

# A headless land never prompts: ssh runs in batch mode.
setup noprompt
branch_edit a.txt "$(lines A)"
mkdir -p "$T/bin"
printf '#!/bin/bash\ncase "$*" in *BatchMode=yes*) ;; *) : >"%s/prompted" ;; esac\nexit 255\n' "$T" >"$T/bin/ssh"
chmod +x "$T/bin/ssh"
git -C "$M" remote set-url origin "ssh://nohost/x.git"
rc=0
(cd "$W" && env -u GIT_ASKPASS -u SSH_ASKPASS PATH="$T/bin:$PATH" "$LAND") >"$T/out" 2>"$T/err" || rc=$?
assert eq "$rc" 1
assert has "$T/err" "fetch from origin failed"
assert_not test -e "$T/prompted"
assert kept
assert journal '.outcome == "refused" and .reason == "fetch" and .tries == 0'

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
assert journal '.outcome == "refused" and .reason == "conflict" and .conflict_files == ["a.txt"] and .tries == 1'

setup conflictbare
branch_edit a.txt "$(lines a | sed 's/^a8$/FEAT8/')"
git -C "$M" worktree remove "$W"
other_lands a.txt "$(lines a | sed 's/^a8$/OTHER8/')" "other edits a8"
land_in "$M" feat
assert eq "$rc" 1
assert has "$T/err" "land: resolve it in a worktree on feat with git rebase $(sha "$O" HEAD), then land again"
assert eq "$(git -C "$M" worktree list | wc -l | tr -d ' ')" 1

# Suites: skipped when upstream touched other files, run when it touched the branch's.
setup nooverlap suites
branch_edit a.txt "$(lines a | sed 's/^a8$/FEAT8/')"
other_lands c.txt "$(lines C)" "other edits c"
land_in "$W"
assert eq "$rc" 0
assert grep -qE '^landed feat → main [0-9a-f]+, suites: skipped$' "$T/out"
assert_not test -e "$T/run-all.log"
assert eq "$(git -C "$M" log --format=%s -2 main | tr '\n' '|')" "feat edits a.txt|other edits c|"

setup overlap suites
branch_edit a.txt "$(lines a | sed 's/^a8$/FEAT8/')"
other_lands a.txt "$(lines a | sed 's/^a1$/OTHER1/')" "other edits a1"
: >"$T/slow"
waits_before=$(suite_waits)
WORKER_RUN_ID=run-1 land_in "$W"
assert eq "$rc" 0
assert grep -qE '^landed feat → main [0-9a-f]+, suites: ran 1$' "$T/out"
assert eq "$(suite_waits)" "$((waits_before + 1))"
assert journal '.outcome == "landed" and .suites == 1 and .suite_secs >= 1 and .secs >= .suite_secs'
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

# --test runs again on a retry's new base.
setup testretry suites
branch_edit a.txt "$(lines A)"
hook="$(git -C "$M" rev-parse --path-format=absolute --git-common-dir)/hooks/pre-push"
printf '#!/bin/bash\n[ -e "%s/moved" ] && exit 0\n: >"%s/moved"\nprintf x >"%s/c.txt" && git -C "%s" commit -qam "other moved" && git -C "%s" push -q origin main 2>/dev/null\n' \
  "$T" "$T" "$O" "$O" "$O" >"$hook" && chmod +x "$hook"
waits_before=$(suite_waits)
land_in "$W" --test
assert eq "$rc" 0
assert has "$T/out" "suites: ran 2"
assert eq "$(wc -l <"$T/run-all.log" | tr -d ' ')" 2
assert eq "$(suite_waits)" "$((waits_before + 2))"
assert journal '.outcome == "landed" and .suites == 2 and .tries == 2'

# A failing tests/affected leaves coverage unknown: --test stops before publishing, auto warns and lands.
setup affectedred suites
branch_edit a.txt "$(lines a | sed 's/^a8$/FEAT8/')"
other_lands a.txt "$(lines a | sed 's/^a1$/OTHER1/')" "other edits a1"
: >"$T/affected-red"
tip=$(sha "$W" HEAD) remote_before=$(sha "$R" main)
land_in "$W" --test
assert eq "$rc" 1
assert has "$T/err" "coverage unknown"
assert journal '.outcome == "refused" and .reason == "coverage"'
assert eq "$(sha "$R" main)" "$remote_before"
assert eq "$(sha "$W" HEAD)" "$tip"
land_in "$W"
assert eq "$rc" 0
assert has "$T/err" "land: warning: tests/affected failed on feat, coverage unknown"
assert has "$T/out" "suites: skipped"
assert_not test -e "$T/run-all.log"
assert gone

# A red suite puts the branch back at its pre-land tip; the rerun runs the suites again.
setup red suites
branch_edit a.txt "$(lines a | sed 's/^a8$/FEAT8/')"
other_lands a.txt "$(lines a | sed 's/^a1$/OTHER1/')" "other edits a1"
: >"$T/red"
remote_before=$(sha "$R" main) tip=$(sha "$W" HEAD) waits_before=$(suite_waits)
land_in "$W"
assert eq "$rc" 1
assert journal '.outcome == "refused" and .reason == "suites" and .suites == 1'
assert eq "$(suite_waits)" "$((waits_before + 1))"
assert eq "$(sha "$R" main)" "$remote_before"
assert_not git -C "$M" merge-base --is-ancestor "$remote_before" main
assert eq "$(sha "$W" HEAD)" "$tip"
assert has "$T/err" "feat is back at its pre-land tip $(git -C "$M" rev-parse --short "$tip")"
assert kept
rm "$T/red"
land_in "$W"
assert eq "$rc" 0
assert has "$T/out" "suites: ran 1"
assert eq "$(wc -l <"$T/run-all.log" | tr -d ' ')" 2
assert gone

# The remote moves between fetch and push: rebase again and push on the second try.
setup retry
branch_edit a.txt "$(lines A)"
printf '#!/bin/bash\n[ -e "%s/moved" ] && exit 0\n: >"%s/moved"\nprintf x >"%s/c.txt" && git -C "%s" commit -qam "other moved" && git -C "%s" push -q origin main 2>/dev/null\n' \
  "$T" "$T" "$O" "$O" "$O" >"$(git -C "$M" rev-parse --path-format=absolute --git-common-dir)/hooks/pre-push"
chmod +x "$(git -C "$M" rev-parse --path-format=absolute --git-common-dir)/hooks/pre-push"
land_in "$W"
assert eq "$rc" 0
assert grep -qE '^landed feat → main [0-9a-f]+, suites: ' "$T/out"
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
assert journal '.outcome == "refused" and .reason == "moved" and .tries == 3'

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
assert journal '.outcome == "refused" and .reason == "push"'

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
assert journal '.outcome == "refused" and .reason == "dirty" and .tries == 0 and .branch == "feat"'

# A journal that cannot be written changes neither the exit status nor the output.
setup unjournaled
branch_edit a.txt "$(lines A)"
tip=$(sha "$W" HEAD) rows_before=$(cat "$HARNESS_LAND_DIR"/*.jsonl | wc -l)
: >"$T/not-a-dir"
HARNESS_LAND_DIR="$T/not-a-dir" land_in "$W"
assert eq "$rc" 0
assert eq "$(cat "$T/out")" "landed feat → main $(git -C "$M" rev-parse --short "$tip"), suites: skipped"
assert eq "$(cat "$T/err")" ""
assert eq "$(cat "$HARNESS_LAND_DIR"/*.jsonl | wc -l)" "$rows_before"

# A land with no share/limiter-hold.sh beside it runs its suites and journals no wait.
setup nowaitnote suites
branch_edit a.txt "$(lines A)"
mkdir -p "$T/legs/bin" "$T/legs/share"
cp "$LAND" "$T/legs/bin/land" && cp "$(dirname "$LAND")/../share/processes.sh" "$T/legs/share/"
waits_before=$(suite_waits)
rc=0
(cd "$W" && LAND_REPORT_BUS="$(dirname "$LAND")/report-bus" "$T/legs/bin/land" --test) >"$T/out" 2>"$T/err" || rc=$?
assert eq "$rc" 0
assert has "$T/out" "suites: ran 1"
assert eq "$(cat "$T/err")" ""
assert eq "$(suite_waits)" "$waits_before"
assert journal '.outcome == "landed" and .suites == 1'

# No remote: a local landing; a branch named from the main checkout without a worktree of its own.
setup local
git -C "$M" remote remove origin
branch_edit a.txt "$(lines a | sed 's/^a8$/FEAT8/')"
git -C "$M" worktree remove "$W"
commit "$M" c.txt "$(lines C)" "main moved locally"
mkdir "$M/feat"
rm -f "$XDG_CACHE_HOME"/claude-reports/sid-land/pending/*
land_in "$M" feat
assert eq "$rc" 0
assert has "$T/out" "(local), suites: skipped"
assert eq "$(pushes)" ""
assert eq "$(git -C "$M" log --format=%s -3 main | tr '\n' '|')" "feat edits a.txt|main moved locally|init|"
assert eq "$(git -C "$M" worktree list | wc -l | tr -d ' ')" 1
assert gone

echo "PASS: test_land.sh ($asserts asserts)"
