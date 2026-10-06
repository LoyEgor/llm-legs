#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export WORKER_RUN_DIR=$(mktemp -d)
trap 'rm -rf "$WORKER_RUN_DIR"' EXIT
run=$("$ROOT/bin/worker-run" start | sed -n 's/^RUN: //p')
( sleep 0.3; WORKER_RUN_ID=$run "$ROOT/bin/worker-inbox-hook.sh" >"$WORKER_RUN_DIR/context" ) &
"$ROOT/bin/worker-run" say "$run" 'use the cache' | grep -q '^delivered at ' || { echo FAIL: not delivered; exit 1; }
wait
grep -q 'use the cache' "$WORKER_RUN_DIR/context" || { echo FAIL: the worker never saw it; exit 1; }
echo PASS
