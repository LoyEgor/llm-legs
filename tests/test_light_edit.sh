#!/usr/bin/env bash
# The Light edit contract: a run lands on the shared checkout only through its own worktree, and
# only when the brief's SCOPE fence held and its VERIFY command passed. Every case here proves the
# shared tree is either advanced by a green run or byte-identical after a red one.
set -u
unset WORKER_PICK_CONFIG_FILE WORKER_RUN_CONFIG_FILE CLAUDE_LAUNCHER_SESSION CLAUDE_CODE_SESSION_ID
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# Every `worker_model_*` call shells `grokb models`: the fixture list answers it, and the
# `grok` CLI behind it can never be reached (row `cu`).
export GROKB_CACHE_DIR="$WORK/grokb-cache"
. "$ROOT/tests/fixtures/grokb-models.sh"
. "$ROOT/tests/fixtures/codexb-models.sh"
fail(){ printf 'FAIL(line %s): %s\n' "${BASH_LINENO[1]-?}" "$*" >&2
  [ ! -f "$WORK/out" ] || { printf -- '--- out ---\n'; cat "$WORK/out"; } >&2
  [ ! -f "$WORK/err" ] || { printf -- '--- err ---\n'; cat "$WORK/err"; } >&2
  exit 1; }
asserts=0
assert(){ asserts=$((asserts + 1)); "$@" || fail "$*"; }

HOME="$WORK/home"; BIN="$WORK/bin"; SHARED="$WORK/shared"; RUNS="$WORK/runs"
export HOME
mkdir -p "$HOME/.claude" "$HOME/.claude-profiles/picked" "$HOME/.claude/projects" "$HOME/.codex-profiles/picked" "$BIN" "$SHARED/src" "$RUNS"
ln -s "$HOME/.claude/projects" "$HOME/.claude-profiles/picked/projects"
git -C "$SHARED" init -q
printf 'x\n' >"$SHARED/file"; printf 'keep\n' >"$SHARED/src/kept.txt"
git -C "$SHARED" add -A; git -C "$SHARED" -c user.name=x -c user.email=x@y commit -qm init
TOGGLE="$HOME/.claude/worker-model"
printf 'light_edit=claudeb:sonnet\n' >"$TOGGLE"

cat >"$BIN/worker-pick" <<'PICK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PICK_LOG"
printf 'picked\n'
PICK
# The worker: it writes in the directory the supervisor put it in, and names each write in its
# transcript, which is the only evidence worker-run accepts for "this run's files".
cat >"$BIN/claudeb" <<'CLAUDEB'
#!/usr/bin/env bash
input=$(cat)
transcript_dir="$CLAUDEB_PROFILES_ROOT/picked/projects/fixture"
mkdir -p "$transcript_dir"
jq -cn --arg t "$input" '{type:"user",message:{role:"user",content:$t}}' >"$transcript_dir/$STUB_SESSION.jsonl"
for path in ${STUB_WRITE:-}; do
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "${STUB_CONTENT:-worker}" >"$path"
  jq -cn --arg path "$path" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{timestamp:$ts,type:"assistant",message:{content:[{type:"tool_use",name:"Edit",input:{file_path:$path}}]}}' \
    >>"$transcript_dir/$STUB_SESSION.jsonl"
done
# The floor every vendor shares: a write through the shell, named nowhere in the transcript.
for path in ${STUB_SHELL_WRITE:-}; do
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "${STUB_CONTENT:-worker}" >"$path"
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{timestamp:$ts,type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:"sed -i \"\" s/x/y/ a-file"}}]}}' \
    >>"$transcript_dir/$STUB_SESSION.jsonl"
done
if [ -n "${STUB_RENAME:-}" ]; then
  git mv src/kept.txt src/renamed-kept.txt
fi
if [ -n "${STUB_DROP_BASE:-}" ]; then
  jq 'del(.light_base)' "$WORKER_RUN_RECORD/meta.json" >"$WORKER_RUN_RECORD/meta.tmp"
  mv "$WORKER_RUN_RECORD/meta.tmp" "$WORKER_RUN_RECORD/meta.json"
  [ "$STUB_DROP_BASE" != all ] || rm -f "$WORKER_RUN_RECORD/head-before"
fi
if [ -n "${STUB_COMMIT:-}" ]; then
  git add -A >/dev/null 2>&1
  git -c user.name=w -c user.email=w@y commit -qm 'worker change' >/dev/null 2>&1
fi
printf '{"result":"light edit done","session_id":"%s"}\n' "$STUB_SESSION"
exit "${STUB_RC:-0}"
CLAUDEB
cat >"$BIN/codex" <<'CODEX'
#!/usr/bin/env bash
cat >/dev/null
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then printf 'codex research answer\n' >"$2"; fi
  shift
done
CODEX
chmod +x "$BIN"/*

session=0
wr(){ session=$((session + 1))
  env HOME="$HOME" PATH="$BIN:/usr/bin:/bin" TMPDIR="$WORK" WORKER_RUN_DIR="$RUNS" WORKER_RUN_IDLE_S=0 \
    WORKER_RUN_ALLOW_DUPLICATE=1 WORKER_RUN_VERIFY_TIMEOUT_S=60 \
    CLAUDEB_DIR="$HOME/.claude-profiles/.claudeb" CLAUDEB_PROFILES_ROOT="$HOME/.claude-profiles" \
    CODEX_PROFILES_DIR="$HOME/.codex-profiles" \
    WORKER_RUN_WORKER_PICK="$BIN/worker-pick" PICK_LOG="$WORK/picks" \
    WORKER_RUN_CLAUDEB="$BIN/claudeb" WORKER_RUN_CODEX="$BIN/codex" \
    STUB_SESSION="light-session-$session" STUB_WRITE="${STUB_WRITE:-}" STUB_CONTENT="${STUB_CONTENT:-}" \
    STUB_DROP_BASE="${STUB_DROP_BASE:-}" STUB_RENAME="${STUB_RENAME:-}" \
    STUB_SHELL_WRITE="${STUB_SHELL_WRITE:-}" STUB_RC="${STUB_RC:-0}" STUB_COMMIT="${STUB_COMMIT:-}" \
    "$ROOT/bin/worker-run" "$@" >"$WORK/out" 2>"$WORK/err"; }

start(){ STUB_WRITE="${STUB_WRITE:-}" STUB_CONTENT="${STUB_CONTENT:-}" STUB_SHELL_WRITE="${STUB_SHELL_WRITE:-}" \
  STUB_RC="${STUB_RC:-0}" STUB_COMMIT="${STUB_COMMIT:-}" wr start "$@" || return $?
  RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/out"); RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/out"); }
await(){ local index
  for index in $(seq 1 200); do
    wr wait "$RUN_ID" --max 0
    grep -q '^STATUS: done\|^STATUS: failed' "$WORK/out" && return 0
    sleep 0.05
  done
  return 1; }
report(){ wr report "$RUN_ID"; cat "$WORK/out"; }
# Tracked and untracked content of the shared checkout, with its own .git and the throwaway
# worktrees under .claude left out: what "byte-identical after a red run" is measured on.
tree_digest(){ (cd "$1" && find . -path ./.git -prune -o -path ./.claude -prune -o -type f -print0 |
  sort -z | xargs -0 shasum -a 256) | shasum -a 256 | awk '{print $1}'; }
run_dirs(){ find "$RUNS" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '; }

# --- green: the diff reaches the shared checkout and the worktree is gone ---------------------
printf 'SCOPE: src/*\nVERIFY: test -f src/new.txt\n\nWrite src/new.txt.\n' >"$WORK/brief"
STUB_WRITE='src/new.txt' start light --brief "$WORK/brief" --workdir "$SHARED" || fail "green start: $(cat "$WORK/err")"
assert jq -e '.light == "edit" and (.light_worktree | test("/\\.claude/worktrees/light-")) and .light_shared_top == $top' \
  --arg top "$(cd "$SHARED" && pwd -P)" "$RUN_DIR/meta.json" >/dev/null
worktree=$(jq -r '.light_worktree' "$RUN_DIR/meta.json")
assert test -d "$worktree"
assert await
green=$(report)
assert test "$(head -n1 <<<"$green")" = 'VERIFIED: pass'
assert grep -qx 'SCOPE: ok' <<<"$green"
assert grep -qx 'LANDED: yes' <<<"$green"
assert grep -q "^WORKDIR: .*/\.claude/worktrees/light-" <<<"$green"
assert test "$(cat "$SHARED/src/new.txt")" = worker
assert test ! -e "$worktree"
assert test -z "$(git -C "$SHARED" branch --list "light-$RUN_ID")"
assert grep -qx '.claude/worktrees/' "$SHARED/.git/info/exclude"
git -C "$SHARED" add -A; git -C "$SHARED" -c user.name=x -c user.email=x@y commit -qm landed

# A brief may carry SCOPE without VERIFY: nothing to run, and the diff still lands.
printf 'SCOPE: src/*\n\nWrite src/unverified.txt.\n' >"$WORK/brief"
STUB_WRITE='src/unverified.txt' start light --brief "$WORK/brief" --workdir "$SHARED" || fail 'no-verify start'
assert await
noverify=$(report)
assert grep -qx 'VERIFIED: none' <<<"$noverify"
assert grep -qx 'LANDED: yes' <<<"$noverify"
assert test -f "$SHARED/src/unverified.txt"
git -C "$SHARED" add -A; git -C "$SHARED" -c user.name=x -c user.email=x@y commit -qm unverified

# --- out of scope: nothing lands, and the shared tree is untouched to the byte ----------------
before=$(tree_digest "$SHARED")
printf 'SCOPE: src/*\nVERIFY: true\n\nWrite one file under src.\n' >"$WORK/brief"
STUB_WRITE='other/stray.txt' start light --brief "$WORK/brief" --workdir "$SHARED" || fail 'escape start'
assert await
escaped=$(report)
assert grep -qx 'SCOPE: escaped other/stray.txt' <<<"$escaped"
assert grep -qx 'LANDED: no' <<<"$escaped"
assert test "$(tree_digest "$SHARED")" = "$before"
assert test ! -e "$SHARED/other/stray.txt"
kept=$(sed -n 's/^LIGHT-WORKTREE: //p' <<<"$escaped")
assert test -f "$kept/other/stray.txt"

# --- red VERIFY: in scope, still nothing lands ------------------------------------------------
before=$(tree_digest "$SHARED")
printf 'SCOPE: src/*\nVERIFY: grep -q absent src/red.txt\n\nWrite src/red.txt.\n' >"$WORK/brief"
STUB_WRITE='src/red.txt' start light --brief "$WORK/brief" --workdir "$SHARED" || fail 'red-verify start'
assert await
red=$(report)
assert grep -qx 'VERIFIED: fail' <<<"$red"
assert grep -qx 'SCOPE: ok' <<<"$red"
assert grep -qx 'LANDED: no' <<<"$red"
assert test "$(tree_digest "$SHARED")" = "$before"
assert test ! -e "$SHARED/src/red.txt"
kept=$(sed -n 's/^LIGHT-WORKTREE: //p' <<<"$red")
assert test -f "$kept/src/red.txt"

# --- the shared tree moved under the run: the patch is kept, nothing is forced ----------------
printf 'moved by another agent\n' >"$SHARED/src/kept.txt"
before=$(tree_digest "$SHARED")
printf 'SCOPE: src/*\nVERIFY: true\n\nRewrite src/kept.txt.\n' >"$WORK/brief"
STUB_WRITE='src/kept.txt' STUB_CONTENT='worker rewrite' start light --brief "$WORK/brief" --workdir "$SHARED" ||
  fail 'conflict start'
assert await
conflict=$(report)
assert grep -qx 'SCOPE: ok' <<<"$conflict"
assert grep -qx 'LANDED: conflict' <<<"$conflict"
assert test "$(tree_digest "$SHARED")" = "$before"
assert test "$(cat "$SHARED/src/kept.txt")" = 'moved by another agent'
patch=$(sed -n 's/^LIGHT-PATCH: //p' <<<"$conflict")
assert test -s "$patch"
assert test -n "$(sed -n 's/^LIGHT-WORKTREE: //p' <<<"$conflict")"
git -C "$SHARED" checkout -q -- src/kept.txt

# --- the contract is a launch condition, not a report line ------------------------------------
before_runs=$(run_dirs)
printf 'Rewrite whatever you like.\n' >"$WORK/brief"
wr start light --brief "$WORK/brief" --workdir "$SHARED"; rc=$?
assert test "$rc" -eq 4
assert grep -q "needs a 'SCOPE: <glob>" "$WORK/err"
assert test "$(run_dirs)" = "$before_runs"
assert test -z "$(find "$SHARED/.claude/worktrees" -mindepth 1 -maxdepth 1 -newer "$WORK/brief" 2>/dev/null)"

# --- recipes: the brief the orchestrator did not have to write ---------------------------------
STUB_WRITE='src/renamed.txt' STUB_CONTENT=beta start light --recipe rename \
  --set from=alpha --set to=beta --set 'paths=src/*' --workdir "$SHARED" || fail "recipe start: $(cat "$WORK/err")"
assert test "$(head -n1 "$RUN_DIR/brief")" = 'SCOPE: src/*'
assert test "$(sed -n 2p "$RUN_DIR/brief")" = "VERIFY: ! grep -rlF 'alpha' src/*"
assert grep -qF 'Rename `alpha` to `beta` in src/*' "$RUN_DIR/brief"
assert test "$(grep -c '{{' "$RUN_DIR/brief")" = 0
assert test "$(cat "$RUN_DIR/light-scope")" = 'src/*'
assert await
recipe=$(report)
assert grep -qx 'VERIFIED: pass' <<<"$recipe"
assert grep -qx 'LANDED: yes' <<<"$recipe"
assert test "$(cat "$SHARED/src/renamed.txt")" = beta

wr start light --recipe no-such-recipe --set from=a --workdir "$SHARED"; rc=$?
assert test "$rc" -eq 4
assert grep -q 'unknown recipe: no-such-recipe' "$WORK/err"
wr start light --recipe rename --set from=alpha --set to=beta --workdir "$SHARED"; rc=$?
assert test "$rc" -eq 4
assert grep -q 'recipe rename still needs {{paths}}' "$WORK/err"
wr start light --recipe rename --brief "$WORK/brief" --workdir "$SHARED"; rc=$?
assert test "$rc" -eq 4
assert grep -q 'pass one of --recipe and --brief' "$WORK/err"

# --- the fence is the WORKTREE's own state, not the run's transcript listing ------------------
# A vendor that wrote through the shell leaves the listing `PARTIAL:` and shrunken; fenced on that,
# an out-of-scope file matched nothing and `git add -A` landed it anyway.
before=$(tree_digest "$SHARED")
printf 'SCOPE: src/*\nVERIFY: true\n\nWrite one file under src.\n' >"$WORK/brief"
STUB_SHELL_WRITE='other/shell-stray.txt' start light --brief "$WORK/brief" --workdir "$SHARED" ||
  fail 'shell-write start'
STUB_SHELL_WRITE=''
assert await
shell=$(report)
assert grep -q '^PARTIAL: ' "$RUN_DIR/files"
assert grep -qx 'SCOPE: escaped other/shell-stray.txt' <<<"$shell"
assert grep -qx 'LANDED: no' <<<"$shell"
assert test "$(tree_digest "$SHARED")" = "$before"
assert test ! -e "$SHARED/other/shell-stray.txt"

# --- a run that ended failed lands nothing, even with no VERIFY to fail -----------------------
before=$(tree_digest "$SHARED")
printf 'SCOPE: src/*\n\nWrite src/half.txt.\n' >"$WORK/brief"
STUB_RC=1 STUB_WRITE='src/half.txt' start light --brief "$WORK/brief" --workdir "$SHARED" || fail 'failed-run start'
STUB_RC=0
assert await
half=$(report)
assert grep -qx 'STATUS: failed' <<<"$half"
assert grep -qx 'VERIFIED: none' <<<"$half"
assert grep -qx 'SCOPE: ok' <<<"$half"
assert grep -qx 'LANDED: no' <<<"$half"
assert grep -qx 'LIGHT-RUN: failed' <<<"$half"
assert test "$(tree_digest "$SHARED")" = "$before"
assert test ! -e "$SHARED/src/half.txt"
kept=$(sed -n 's/^LIGHT-WORKTREE: //p' <<<"$half")
assert test -f "$kept/src/half.txt"

# --- VERIFY runs in the worktree and may write there: the fence is taken again after it -------
before=$(tree_digest "$SHARED")
printf 'SCOPE: src/*\nVERIFY: : >verify-made.txt\n\nWrite src/checked.txt.\n' >"$WORK/brief"
STUB_WRITE='src/checked.txt' start light --brief "$WORK/brief" --workdir "$SHARED" || fail 'verify-write start'
assert await
late=$(report)
assert grep -qx 'VERIFIED: pass' <<<"$late"
assert grep -qx 'SCOPE: escaped verify-made.txt' <<<"$late"
assert grep -qx 'LANDED: no' <<<"$late"
assert test "$(tree_digest "$SHARED")" = "$before"
assert test ! -e "$SHARED/verify-made.txt"
assert test ! -e "$SHARED/src/checked.txt"

# --- a worker that committed inside its worktree: the diff is base..worktree, never empty -----
printf 'SCOPE: src/*\nVERIFY: test -f src/kept-by-worker.txt\n\nWrite src/kept-by-worker.txt.\n' >"$WORK/brief"
STUB_COMMIT=1 STUB_WRITE='src/kept-by-worker.txt' STUB_CONTENT='written by the worker' \
  start light --brief "$WORK/brief" --workdir "$SHARED" || fail 'worker-vcs start'
STUB_COMMIT='' STUB_CONTENT=''
assert await
vcs=$(report)
assert grep -qx 'SCOPE: ok' <<<"$vcs"
assert grep -qx 'LANDED: yes' <<<"$vcs"
assert test "$(cat "$SHARED/src/kept-by-worker.txt")" = 'written by the worker'
git -C "$SHARED" add -A; git -C "$SHARED" -c user.name=x -c user.email=x@y commit -qm worker-vcs

# --- the caller's subdirectory is kept: a brief written against it resolves where it was written
printf 'SCOPE: in-subdir.txt\nVERIFY: test -f in-subdir.txt\n\nWrite in-subdir.txt here.\n' >"$WORK/brief"
STUB_WRITE='in-subdir.txt' start light --brief "$WORK/brief" --workdir "$SHARED/src" || fail 'subdir start'
assert jq -e '.workdir | endswith("/src")' "$RUN_DIR/meta.json" >/dev/null
assert jq -e '. as $m | $m.workdir | startswith($m.light_worktree + "/")' "$RUN_DIR/meta.json" >/dev/null
assert await
subdir=$(report)
assert grep -qx 'SCOPE: ok' <<<"$subdir"
assert grep -qx 'LANDED: yes' <<<"$subdir"
assert test -f "$SHARED/src/in-subdir.txt"
git -C "$SHARED" add -A; git -C "$SHARED" -c user.name=x -c user.email=x@y commit -qm subdir

printf 'SCOPE: src/*\nVERIFY: true\n' >"$WORK/brief"
STUB_DROP_BASE=meta STUB_COMMIT=1 STUB_WRITE=src/legacy.txt start light --brief "$WORK/brief" --workdir "$SHARED" || fail 'legacy start'
assert await
legacy=$(report)
assert grep -qx 'LANDED: yes' <<<"$legacy"
assert test -f "$SHARED/src/legacy.txt"
git -C "$SHARED" add -A; git -C "$SHARED" -c user.name=x -c user.email=x@y commit -qm legacy
STUB_DROP_BASE=all STUB_COMMIT=1 STUB_WRITE=src/preserved.txt start light --brief "$WORK/brief" --workdir "$SHARED" || fail 'missing base start'
assert await
missing=$(report)
assert grep -qx 'SCOPE: unknown base' <<<"$missing"
assert grep -qx 'LANDED: no' <<<"$missing"
kept=$(sed -n 's/^LIGHT-WORKTREE: //p' <<<"$missing")
assert test -f "$kept/src/preserved.txt"
assert test -n "$(git -C "$SHARED" branch --list "light-$RUN_ID")"

printf 'SCOPE: src/renamed-kept.txt\nVERIFY: true\n' >"$WORK/brief"
STUB_RENAME=1 start light --brief "$WORK/brief" --workdir "$SHARED" || fail 'rename start'
assert await
renamed=$(report)
assert grep -qx 'SCOPE: escaped src/kept.txt' <<<"$renamed"
assert grep -qx 'LANDED: no' <<<"$renamed"
assert test -f "$SHARED/src/kept.txt"

printf 'protected\n' >"$HOME/.claude/protected"
ln -s "$HOME/.claude/protected" "$SHARED/src/outside-link"
git -C "$SHARED" add src/outside-link; git -C "$SHARED" -c user.name=x -c user.email=x@y commit -qm link
printf 'SCOPE: src/*\nVERIFY: true\n' >"$WORK/brief"
before=$(tree_digest "$SHARED")
STUB_WRITE="$SHARED/src/kept.txt $HOME/.claude/protected src/outside-link" start light --brief "$WORK/brief" --workdir "$SHARED" || fail 'external write start'
assert await
assert test "$(cat "$HOME/.claude/protected")" = protected
assert test "$(tree_digest "$SHARED")" = "$before"
assert grep -q 'Operation not permitted' "$RUN_DIR/err"
printf 'SCOPE: src/*\nVERIFY: echo changed > %s\n' "$HOME/.claude/protected" >"$WORK/brief"
start light --brief "$WORK/brief" --workdir "$SHARED" || fail 'external verify start'
assert await
assert grep -qx 'VERIFIED: fail' < <(report)
assert test "$(cat "$HOME/.claude/protected")" = protected

# --- launch refusals: a Light edit is one repository, and it is not resumable ------------------
before_runs=$(run_dirs)
printf 'SCOPE: src/*\n\nCarry on.\n' >"$WORK/brief"
wr start light --brief "$WORK/brief" --workdir "$SHARED" --resume light-session-1; rc=$?
assert test "$rc" -eq 4
assert grep -q 'a Light edit is not resumable' "$WORK/err"
assert test "$(run_dirs)" = "$before_runs"
wr start light --brief "$WORK/brief" --workdir "$SHARED" --add-dir "$WORK"; rc=$?
assert test "$rc" -eq 4
assert grep -q -- '--add-dir grants a second one no fence covers' "$WORK/err"
assert test "$(run_dirs)" = "$before_runs"

# --- a refusal below the allocation leaves no worktree, no branch and no empty run directory ---
branches_before=$(git -C "$SHARED" branch --list 'light-*' | sort)
worktrees_before=$(git -C "$SHARED" worktree list | sort)
before_runs=$(run_dirs)
printf 'light_edit=gemini:flash38\n' >"$TOGGLE"
wr start light --brief "$WORK/brief" --workdir "$SHARED"; rc=$?
assert test "$rc" -eq 4
assert test "$(git -C "$SHARED" branch --list 'light-*' | sort)" = "$branches_before"
assert test "$(git -C "$SHARED" worktree list | sort)" = "$worktrees_before"
assert test "$(run_dirs)" = "$before_runs"
printf 'light_edit=claudeb:sonnet\n' >"$TOGGLE"

mkdir -p "$WORK/abandoned"
printf 'owner\n' >"$WORK/abandoned/launcher"
assert env LIGHT_ABANDON="$(printf '%s\t%s\t%s' "$SHARED" "$WORK/unused-tree" "$WORK/abandoned")" \
  bash -c '
    source <(sed -n "/^light_start_abandon() {/,/^}/p" "$1/bin/worker-run")
    complete_run() { printf "%s\n" "$2" >"$1/completed"; }
    light_worktree_remove() { exit 99; }
    light_start_abandon
  ' _ "$ROOT"
assert test -d "$WORK/abandoned"
assert test "$(cat "$WORK/abandoned/exit_code")" = 4
assert test "$(cat "$WORK/abandoned/completed")" = 4

# --- G7: off the light row's vendor, a light run must be told which model to use ---------------
printf 'light_research=gemini\nlight_edit=claudeb:sonnet\n' >"$TOGGLE"
printf 'SCOPE: src/*\n\nLook around.\n' >"$WORK/brief"
wr start codex --role research --brief "$WORK/brief" --workdir "$SHARED"; rc=$?
assert test "$rc" -eq 4
assert grep -qx 'OUTCOME: MODEL_REFUSED' "$WORK/out"
assert grep -q 'the light_research row names gemini, not codex' "$WORK/err"
wr start codex --role research --model astra --brief "$WORK/brief" --workdir "$SHARED"; rc=$?
assert test "$rc" -eq 0
assert jq -e '.vendor == "codex" and .role == "research" and .model == "astra" and .model_id == "gpt-6.1-astra" and .light == "research"' \
  "$RUNS/$(sed -n 's/^RUN: //p' "$WORK/out")/meta.json" >/dev/null

printf 'PASS: %s asserts; Light edit SCOPE/VERIFY contract (refused at launch without SCOPE, with --resume or with --add-dir), the throwaway worktree fenced on its own git state, land-on-green with conflict, red-run and failed-run byte-identity, the fence retaken after VERIFY, a worker that used git inside the worktree, the caller subdirectory kept, cleanup after a refusal below the allocation, recipe composition and refusals, and the off-row light vendor refusal\n' "$asserts"
