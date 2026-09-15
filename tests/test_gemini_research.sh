#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
fail(){ echo "FAIL: $*" >&2; [ ! -f "$WORK/out" ] || cat "$WORK/out" >&2; [ ! -f "$WORK/err" ] || cat "$WORK/err" >&2; exit 1; }
assert(){ "$@" || fail "$*"; }
HOME="$WORK/home"; BIN="$WORK/bin"; REPO="$WORK/repo"; RUNS="$WORK/runs"
mkdir -p "$HOME/.gemini-profiles/researcher" "$HOME/.gemini" "$HOME/.claude" "$BIN" "$REPO" "$RUNS"
git -C "$REPO" init -q; printf 'x\n' >"$REPO/file"; git -C "$REPO" add file; git -C "$REPO" -c user.name=x -c user.email=x@y commit -qm init
cat >"$BIN/worker-pick" <<'PICK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PICK_LOG"
if [ -s "${PICK_QUEUE:-/dev/null}" ]; then
  head -n1 "$PICK_QUEUE"
  sed -i '' 1d "$PICK_QUEUE"
  exit 0
fi
printf 'researcher\n'
PICK
cat >"$BIN/geminib" <<'GEMINI'
#!/usr/bin/env bash
if [ "$1" = list ]; then printf 'researcher: ready\nrescuer: ready\n'; exit 0; fi
printf 'profile=%s\n' "$2" >>"$GEMINI_LOG"
if [ -n "${FAKE_EDIT:-}" ]; then printf 'Operation not permitted: %s\n' "$FAKE_EDIT" >&2; exit 5; fi
if [ -n "${FAKE_LOG_QUOTA:-}" ] && [ "$2" = researcher ]; then
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --log-file ]; then printf 'RESOURCE_EXHAUSTED\n' >"$2"; break; fi
    shift
  done
  exit 1
fi
printf 'tracked Gemini answer\n'
GEMINI
cat >"$BIN/sandbox-exec" <<'SANDBOX'
#!/usr/bin/env bash
shift 2
exec "$@"
SANDBOX
chmod +x "$BIN"/*
printf 'Research the repository.\n' >"$WORK/prompt"
run(){ env HOME="$HOME" PATH="$BIN:/usr/bin:/bin" TMPDIR="$WORK" WORKER_RUN_DIR="$RUNS" WORKER_RUN_IDLE_S=0 \
  GEMINIB_PROFILES_DIR="$HOME/.gemini-profiles" WORKER_RUN_WORKER_PICK="$BIN/worker-pick" PICK_LOG="$WORK/picks" \
  GEMINI_RESEARCH_SANDBOX_EXEC="$BIN/sandbox-exec" GEMINI_LOG="$WORK/gemini.log" FAKE_EDIT="${FAKE_EDIT:-}" \
  FAKE_LOG_QUOTA="${FAKE_LOG_QUOTA:-}" PICK_QUEUE="${PICK_QUEUE:-}" \
  "$ROOT/bin/gemini-research" --prompt-file "$WORK/prompt" --out "$WORK/answer" --repo "$REPO" "$@" >"$WORK/out" 2>"$WORK/err"; }
run
rc=$?; assert test "$rc" -eq 0; assert test "$(cat "$WORK/answer")" = 'tracked Gemini answer'
assert grep -q '^ACCOUNT: researcher (gemini)$' "$WORK/out"; assert grep -q '^RUN: gemini-' "$WORK/out"
run_id=$(sed -n 's/^RUN: //p' "$WORK/out" | head -1); assert test -d "$RUNS/$run_id"; assert test -f "$RUNS/$run_id/meta.json"
assert jq -e '.role == "research" and .account == "researcher" and .agy_model == "gemini-3.8-flash-high"' "$RUNS/$run_id/meta.json"
assert grep -q -- '--role research' "$WORK/picks"; assert grep -q '^profile=researcher$' "$WORK/gemini.log"
FAKE_EDIT="$REPO/blocked" run; rc=$?; assert test "$rc" -eq 5; assert grep -q 'GEMINI_RESEARCH_WRITE_DENIED' "$WORK/out"; assert test ! -e "$REPO/blocked"
# The compatibility entrypoint must never call itself: worker-run records geminib as the CLI.
assert jq -e --arg fake "$ROOT/bin/gemini-research" '.cli != $fake' "$RUNS/$run_id/meta.json"
# Direct runner role is available and retains the selected Gemini model.
assert grep -q 'supervise_gemini_research' "$ROOT/bin/worker-run"
# run_with_deadline installs the supervisor's TERM/INT traps in its CALLER's shell, so a subshell
# around the call orphans the sandboxed CLI when the run is signalled.
assert test "$(grep -cE '\(cd .*run_with_deadline' "$ROOT/share/gemini-research.sh")" = 0

mkdir -p "$HOME/.gemini-profiles/rescuer"
printf '%s\n' researcher rescuer >"$WORK/pick-queue"
FAKE_LOG_QUOTA=1 PICK_QUEUE="$WORK/pick-queue" run
rc=$?; assert test "$rc" -eq 0
assert test "$(cat "$WORK/answer")" = 'tracked Gemini answer'
run_id=$(sed -n 's/^RUN: //p' "$WORK/out" | head -1)
assert jq -e '.walled_accounts == ["researcher"] and .account == "rescuer"' "$RUNS/$run_id/meta.json"

printf 'PASS: tracked research runner, Gemini selection/model, sandbox denial, a log-only quota walling the account, outcomes and non-recursive CLI\n'
