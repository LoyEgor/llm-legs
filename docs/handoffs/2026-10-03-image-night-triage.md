# Image triage, 2026-10-01..04

Status: done 2026-10-04

To: LLM doctor owner and image block owner (share/doctor-ledger.json owner/owners.image; the image routes are
the chat «Google video generation integration»). Evidence is in each row's `note`; no judge change was written.

## Proposed dismissals (owner's call)

- weather: I9, I11, I15, I17, I26, I30, I32 (vendor filters, tool errors, region policy, load stall).
- not-a-bug: I10 (one development run), I13 and I34 (lock waits under caller fan-out), I1, I23, I35
  (callers' argument errors refused before spend), I36 (your own CLI ref-cap probe; the cap now refuses).
- I17 and I31 read `unclassified`/`browser other` only because IMAGE_REASONS/BROWSER_REASONS lack their
  pattern: a judge change, yours.

## Asked of the image routes chat

- I35: two chats ran `media-run image --vendor gemini -- … --dry-run`; gemini-image refuses it. The media
  skill (claude-setup) says «Run `--dry-run` first» meaning image-fanout. Name fanout there, or pass
  `--dry-run` to the Flow engine, which has one.

## Open, cause unknown

- I16 (Flow frame upload left no trace), I18 (gemini-music SIGTERM, blind spot image-engine-signal-sender),
  I28 (composer settings click on loiyehor; the reason now names the locator).
- I22: a gate against mutation checks in the shared checkout is the Harness doctor's.
- I3, I4, I5: no gemini-music/sfx/listen leg since 2026-10-01.

## Settled 2026-10-04 («LLM Doctor меню refactoring», image block owner)

- Dismissed as proposed: weather I9, I11, I15, I17, I26, I30, I32; not-a-bug I1, I10, I13, I23, I34, I35, I36.
- Judge changes (branch `fix/llm-doctor-handoffs-20261004`): IMAGE_REASONS reads `answered without opening` as `ungrounded`, the vendor
  model's (weather); BROWSER_REASONS reads `images came back within` as `browser no output`, and row I31 now
  matches by that word. Both are pinned in `tests/test_llm_doctor.sh` and red on main.
- I35: claude-setup `skills/media/SKILL.md` names `image-fanout … --dry-run` and says `codex-image` and
  `gemini-image` refuse the flag.
- Still open as ledger rows, each with its evidence: I3, I4, I5, I16, I18, I22 (the Harness doctor's gate),
  I28. The nightly image fixer works them from the ledger; this note adds nothing to them.
