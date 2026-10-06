#!/usr/bin/env bash
set -u
inbox="$WORKER_RUN_DIR/$WORKER_RUN_ID/inbox"
[ -s "$inbox" ] || exit 0
date -u +%H:%M:%S >"$WORKER_RUN_DIR/$WORKER_RUN_ID/delivered"
jq -Rs '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: .}}' "$inbox"
: >"$inbox"
