# Sourced by every tests/test_light_research*.sh: each suite builds its own $WORK of stubs from here.
set -u
# worker-run opens start and wait outside Claude Code only; its relay door is tested with CLAUDECODE set.
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDEB_WORKER WORKER_RUN_RELAY
unset WORKER_PICK_CONFIG_FILE WORKER_RUN_CONFIG_FILE
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
export WORKER_STATS_DIR="$WORK/worker-stats"
export WORKER_RUN_WAIT_POLL_S=1
# Every `worker_model_*` call shells `grokb models`: the fixture list answers it, and the
# `grok` CLI behind it can never be reached (row `cu`).
export GROKB_CACHE_DIR="$WORK/grokb-cache"
. "$ROOT/tests/fixtures/grokb-models.sh"
. "$ROOT/tests/fixtures/codexb-models.sh"
fail(){ echo "FAIL: $*" >&2; [ ! -f "$WORK/out" ] || cat "$WORK/out" >&2; [ ! -f "$WORK/err" ] || cat "$WORK/err" >&2; exit 1; }
asserts=0
assert(){ asserts=$((asserts + 1)); "$@" || fail "$*"; }
HOME="$WORK/home"; BIN="$WORK/bin"; REPO="$WORK/repo"; RUNS="$WORK/runs"
mkdir -p "$HOME/.gemini-profiles/researcher" "$HOME/.gemini" "$HOME/.claude" "$BIN" "$REPO" "$RUNS"
git -C "$REPO" init -q; printf 'x\n' >"$REPO/file"; git -C "$REPO" add file; git -C "$REPO" -c user.name=x -c user.email=x@y commit -qm init
TOGGLE="$HOME/.claude/worker-model"

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
account=$2
printf 'profile=%s\n' "$account" >>"$GEMINI_LOG"
log=''; brief=''
while [ "$#" -gt 1 ]; do
  case $1 in --log-file) log=$2 ;; --print) brief=$2 ;; esac
  shift
done
if [ -n "${FAKE_EDIT:-}" ]; then printf 'Operation not permitted: %s\n' "$FAKE_EDIT" >&2; exit 5; fi
case $brief in
  *QUOTA-Q*) [ -z "$log" ] || printf 'RESOURCE_EXHAUSTED\n' >"$log"; exit 1 ;;
  *CREDITS-Q*) printf 'AGY_ERROR: {"short_error":"Your AI credits balance is too low to continue."}\n' >&2; exit 3 ;;
  *UNAVAIL-Q*) exit 1 ;;
  *APIERR-Q*) printf 'AGY_ERROR: {"short_error":"INTERNAL (code 500): backend error"}
' >&2; exit 3 ;;
esac
if [ -n "${FAKE_LOG_QUOTA:-}" ] && [ "$account" = researcher ]; then
  [ -z "$log" ] || printf 'RESOURCE_EXHAUSTED\n' >"$log"
  exit 1
fi
answer=$(sed -n 's/^ANSWER-FILE: //p' <<<"$brief" | head -n1)
if [ -n "$answer" ] && [ -r "$answer" ]; then cat "$answer"; else printf 'tracked Gemini answer\n'; fi
GEMINI
cat >"$BIN/sandbox-exec" <<'SANDBOX'
#!/usr/bin/env bash
shift 2
exec "$@"
SANDBOX
cat >"$BIN/claudeb" <<'CLAUDEB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$VENDOR_LOG"
cat >/dev/null
printf '{"type":"result","result":"claude research answer"}\n'
CLAUDEB
cat >"$BIN/codex" <<'CODEX'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$VENDOR_LOG"
cat >/dev/null
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then printf 'codex research answer\n' >"$2"; fi
  shift
done
CODEX
cat >"$BIN/grokb" <<'GROKB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$VENDOR_LOG"
[ -z "${FAKE_GROK_EDIT:-}" ] || printf 'written\n' >>"$FAKE_GROK_EDIT"
if [ -n "${FAKE_GROK_CITATION:-}" ]; then
  jq -cn --arg text "$FAKE_GROK_CITATION" '{type:"text",data:$text}'
  printf '{"type":"end","modelUsage":{"grok-4.7-build":{}}}\n'
  exit 0
fi
printf '{"type":"text","data":"grok research answer"}\n{"type":"end","modelUsage":{"grok-4.7-build":{}}}\n'
GROKB
chmod +x "$BIN"/*
printf 'Research the repository.\n' >"$WORK/prompt"
run(){ env HOME="$HOME" PATH="$BIN:/usr/bin:/bin" TMPDIR="$WORK" WORKER_RUN_DIR="$RUNS" WORKER_RUN_IDLE_S=0 \
  GEMINIB_PROFILES_DIR="$HOME/.gemini-profiles" WORKER_RUN_WORKER_PICK="$BIN/worker-pick" PICK_LOG="$WORK/picks" \
  GEMINI_RESEARCH_SANDBOX_EXEC="$BIN/sandbox-exec" GEMINI_LOG="$WORK/gemini.log" FAKE_EDIT="${FAKE_EDIT:-}" \
  FAKE_LOG_QUOTA="${FAKE_LOG_QUOTA:-}" PICK_QUEUE="${PICK_QUEUE:-}" VENDOR_LOG="$WORK/vendor.log" \
  WORKER_RUN_CLAUDEB="$BIN/claudeb" WORKER_RUN_CODEX="$BIN/codex" WORKER_RUN_GROKB="$BIN/grokb" \
  FAKE_GROK_EDIT="${FAKE_GROK_EDIT:-}" FAKE_GROK_CITATION="${FAKE_GROK_CITATION:-}" \
  "$ROOT/bin/light-research" --prompt-file "$WORK/prompt" --out "$WORK/answer" --repo "$REPO" "$@" >"$WORK/out" 2>"$WORK/err"; }
wr(){ env HOME="$HOME" PATH="$BIN:/usr/bin:/bin" TMPDIR="$WORK" WORKER_RUN_DIR="$RUNS" WORKER_RUN_IDLE_S=0 \
  WORKER_RUN_WORKER_PICK="$BIN/worker-pick" PICK_LOG="$WORK/picks" VENDOR_LOG="$HOME/.claude-profiles/researcher/vendor.log" \
  WORKER_RUN_CLAUDEB="$BIN/claudeb" WORKER_RUN_CODEX="$BIN/codex" WORKER_RUN_GROKB="$BIN/grokb" \
  "$ROOT/bin/worker-run" "$@" >"$WORK/out" 2>"$WORK/err"; }
attach(){ env HOME="$HOME" PATH="$BIN:/usr/bin:/bin" TMPDIR="$WORK" WORKER_RUN_DIR="$RUNS" LIGHT_RESEARCH_WAIT_MAX="${LIGHT_RESEARCH_WAIT_MAX:-540}" \
  "$ROOT/bin/light-research" "$@" >"$WORK/out" 2>"$WORK/err"; }
