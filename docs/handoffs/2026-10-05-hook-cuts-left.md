# Hand-off: hook cuts left by night fixer harness-hooks-20261005T061324Z-2ae0

Status: trade for Egor
Cost: `statusLine.refreshInterval` 3 → 10 s, one value in `~/.claude/settings.json` and the three
profile copies; the clock and limits cells lag up to 10 s.
Loss: at 3 s the renders keep about 0.76 of a core: 216k renders and 1089 CPU-min on 2026-10-05,
302 ms CPU each, half of them in idle chats; that load stretches every hook's wall clock.
Recommendation: 10 s.

Settled by night 20261006T032009Z-f253:

1. review-anchors store of logo-vectorizer-bench (17 MB, 79 804 legacy `base` anchors): a write now
   drops the anchors of paths every checkout of the family ignores (review-bench@bbcb6b0); that
   store falls to 334 KB on its next write, and edit-conflict-notice's jq read of it from 0.93 s
   CPU to tens of ms. `touch` is a no-op and commit-journal.sh is gone (claude-setup@6e4b1ac).
2. Snapshot fork floor: `rj_snapshot_content` is gone (claude-setup@6e4b1ac); a landing call's
   snapshot is one `rev-parse` per repository.
3. `hook-p50-stop-dispatch` and `hook_sync:context-nudge.sh` are not flagged by the 2026-10-06
   06:26 doctor run; the judge stays. Memoizing statusline segments needs a per-segment profile
   of live renders, which no fixture reproduces, so the interval above is the lever.
