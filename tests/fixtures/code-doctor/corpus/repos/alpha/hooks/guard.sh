#!/usr/bin/env bash
. "$HOME/.claude/hooks/lib/hook-time.sh" 2>/dev/null || true
. "$(dirname "$0")/mirror_b.sh"
staleness_window 3 >/dev/null
exit 0
