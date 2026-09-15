# Hand-off: a dead away run pins the statusline block and hides home debt

Author: chat «Debt hardening handoff» (943eaaa1, claude-setup). Written 2026-09-15 for the chat that
designed how the block moves between the home and away trees — Egor's choice, not the chat that
merely added the `dead` state (af014fe, «clean and complite phase 1 for review banch»). The two
candidates by their commits: «Статус-лайн: адаптивное уменьшение текста» (b75b611, 2026-08-27: the
middle block is atomic and follows this chat's review, with the priority rules between trees) and
«Workers и review bench унификация отображения» (4eadb42, 2026-09-01: review progress documents in
the statusline, the `ph`/`pa` slots). Nothing here is implemented; the debt chat does not touch
the statusline.

## Symptom (Egor's screenshot, 2026-09-15)

Chat bd9bd9c2 sits in review-bench with thousands of unread lines and its statusline shows a bare
`●` — the autonomy dot with verdict `off`, as if nothing were owed.

## Cause (verified by rendering `bin/statusline.sh` for that session)

1. The progress scan (`bin/statusline.sh` ~940–1130) ranks one document into the home slot `ph`
   (a run over the shown tree) or the away slot `pa` (this session's own run over another tree).
   A document whose `state` is `dead` is kept only for its own session (~1042), so the session's own
   dead run stays a candidate for `pa`.
2. The slot decision (~1131) goes `ph` → `pa` → `home_probe`. A `pa` hit wins BEFORE `home_probe`
   ever runs, so home debt, home status and home unpushed are never computed; the block is pinned to
   the away tree and its verdict is asked for that tree only.
3. bd9bd9c2 owns progress document `transcriptions-gpt__8a2eb87f-74830.json`: `state: dead`,
   started 2026-09-14T17:19Z, 3/6 cells, never consumed. Finished documents are no longer unlinked
   and survive for a day, so the away tree transcriptions-gpt held the block for that whole day,
   and transcriptions-gpt owes nothing → `off` → bare dot.

The comment above the decision says the opposite of what the code does: «any work or debt at home
outranks a review that is already over, so an away tree holds the block only while home is clean,
idle and owing nothing». That guard exists only in the `else` branch (the unanswered-round anchor),
not for `pa`.

## What the owner decides

- Whether a dead (or done) away run should hold the block at all, or only a live/wedged one; the
  comment's intent says home work and debt outrank any run that is already over.
- Where the home guard belongs: probing home before `pa` costs one `home_probe` per render for
  every session with an away run.
- Related and bigger, decided by Egor the same day (see
  `review-bench/docs/handoffs/2026-09-15-debt-semantics-and-closure.md` §1): the verdict must be
  session-wide (sum over every repository the session owes), independent of the shown tree. Once
  that lands, which tree the block shows stops changing the debt number — but the pinning above
  still hides home status/unpushed and still needs its own fix.

## Reproduce

```
progress=~/.claude-profiles/.claudeb/worker-stats/progress/transcriptions-gpt__8a2eb87f-74830.json
jq '{state,started,session,done:(.done|length),cells:(.cells|length)}' "$progress"
```
Then render the statusline for session bd9bd9c2 in review-bench and watch `progress_slot=away`,
`away_top=/Volumes/Work/Projects/transcriptions-gpt`, verdict `off`.
