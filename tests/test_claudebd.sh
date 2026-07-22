#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/claudebd-test.XXXXXX")
DAEMON_PID=""
cleanup() {
  if [ -n "$DAEMON_PID" ]; then kill "$DAEMON_PID" 2>/dev/null || true; fi
  wait 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/store"
printf '{"vendors":{"claude":{"accounts":[]}}}\n' >"$WORK/llm-limits.json"
OUTPUT=$(CLAUDEB_DIR="$WORK/store" LLM_LIMITS_FILE="$WORK/llm-limits.json" node "$ROOT/tests/claudebd_harness.js")
printf '%s\n' "$OUTPUT"
[[ "$OUTPUT" == "PASS: claudebd decision logic (108 assertions)" ]]

# Startup seeding of the fable-scope current from .claudeb-state-fable runs
# after the harness bootstrap boundary, so it needs a real daemon boot on an
# ephemeral port; the status endpoint never contacts the upstream.
free_port() {
  node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{const p=s.address().port;s.close(()=>process.stdout.write(String(p)))})'
}
jget() {
  node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{const o=JSON.parse(d);const v=process.argv[1].split(".").reduce((a,k)=>a==null?a:a[k],o);process.stdout.write(v===undefined?"":String(v))}catch{process.stdout.write("ERR")}})' "$1"
}
boot_daemon() {
  PORT=$(free_port)
  case "$PORT" in ''|*[!0-9]*|45789) echo "FATAL: unsafe test port '$PORT'"; exit 1 ;; esac
  CLAUDEB_DIR="$1" LLM_LIMITS_FILE="$WORK/llm-limits.json" CLAUDEBD_PORT="$PORT" CLAUDEBD_UPSTREAM="http://127.0.0.1:9" node "$ROOT/bin/claudebd" &
  DAEMON_PID=$!
  for _ in $(seq 1 40); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/claudebd/status" 2>/dev/null || true)" = "200" ] && return 0
    sleep 0.1
  done
  echo "FATAL: test daemon did not start"
  exit 1
}
stop_daemon() {
  kill "$DAEMON_PID" 2>/dev/null || true
  wait "$DAEMON_PID" 2>/dev/null || true
  DAEMON_PID=""
}

SEED_STORE="$WORK/seed-store"
mkdir -p "$SEED_STORE/tokens"
printf 'tok-a\n' >"$SEED_STORE/tokens/alpha"
printf 'tok-b\n' >"$SEED_STORE/tokens/beta"
printf 'beta\n' >"$SEED_STORE/.claudeb-state-fable"
boot_daemon "$SEED_STORE"
FABLE=$(curl -s "http://127.0.0.1:$PORT/claudebd/status" | jget scopes.fable)
stop_daemon
[[ "$FABLE" == "beta" ]]
[[ "$(cat "$SEED_STORE/.claudeb-state-fable")" == "beta" ]]

printf 'ghost\n' >"$SEED_STORE/.claudeb-state-fable"
boot_daemon "$SEED_STORE"
FABLE=$(curl -s "http://127.0.0.1:$PORT/claudebd/status" | jget scopes.fable)
stop_daemon
[[ "$FABLE" == "alpha" ]]
[[ "$(cat "$SEED_STORE/.claudeb-state-fable")" == "alpha" ]]

echo "PASS: claudebd fable-scope state seeding"
