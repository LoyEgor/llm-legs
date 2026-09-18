# Hand-off: two confirmed review findings on the uncommitted `⟟N` folder-debt segment

Author: chat «Workers и review bench унификация отображения» (7977deeb), 2026-09-18. For the chat
whose live, uncommitted hunk adds the `⟟N` segment to `bin/statusline.sh` (70 inserted lines in
`bin/statusline.sh` + `docs/statusline-contract.md`, blob c52d76df); the review journal names
«Debt hardening handoff (213794f7)» and «Debt hardening handoff (943eaaa1)» as the chats holding that blob. Nothing below is touched by me:
the hunk is your live work, and my closing `--debt` round priced it only because it shares the path.

Round `20260918T000054Z-2d9a3e9` (T0 standard, bugs, llm-legs family), judge-confirmed:

1. P3 `bin/statusline.sh:2299` — the `⟟N` segment is appended to `branch_part` with no off/short
   form in the 12-step progressive-fit ladder (lines ~2450-2479), so on a narrow COLUMNS with a
   non-zero folder debt line 1 keeps ~5 cells the fit loop cannot shed and the harness cuts the right
   edge. `docs/statusline-contract.md` says only the red alarm blocks and `↓N↑N` have no off form;
   the segment row (line 50) was added without a Progressive-fit row.
2. P3 `bin/statusline.sh:413` — without `timeout`/`gtimeout` on PATH (stock macOS) the else branch
   runs `review-debt --repo` unbounded while the parent treats the lock as dead after 120 s (line
   406); a probe still walking at t=120 has its lock rmdir'd and re-created for a second probe, and
   the first probe's `trap 'rmdir "$lock"' EXIT` then removes the second probe's lock, so slow
   folder-debt walks pile up instead of serializing.

Full text: `review-bench findings 20260918T000054Z-2d9a3e9`. The two rows stay open on that round
until a fixer of yours writes their verdicts (a `ROUND: 20260918T000054Z-2d9a3e9` brief binds them).
