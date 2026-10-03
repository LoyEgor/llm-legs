# Image triage, 2026-10-01..03

Status: open

To: LLM doctor owner and image block owner (share/doctor-ledger.json owner/owners.image; the image routes are
the chat «Google video generation integration»).

Folds the 2026-10-01 and 2026-10-02 image handoffs (night runs llm-image-20261001T020640Z-64e9,
llm-image-20261002T093025Z-0782) and adds llm-image-20261003T042531Z-13d3. Each row's `note` carries the evidence;
no judge change was written.

## Proposed dismissals (owner's call)

- weather: I9 (Flow audio filter), I11 (Gemini app music tool errors), I15 (Flow Music vocals region policy),
  I17 (agy answered without opening the media), I26 (chatgpt.com load stall), I30 (ChatGPT content filter),
  I32 (Flow PUBLIC_ERROR_UNSAFE_GENERATION).
- not-a-bug: I10 (one development-time missing title field), I13 and I34 (per-account lock waits under caller
  fan-out), I1 and I23 (callers' argument errors refused before spend; I23 suggests gemini-image name the
  unknown argument or the missing destination folder instead of bare usage).
- I17 and I31 read `unclassified`/`browser other` only because IMAGE_REASONS/BROWSER_REASONS lack their
  pattern: a judge change, yours.

## Open, cause unknown

- I16 (a Flow frame upload left no trace), I18 (gemini-music engine SIGTERM, blind spot
  image-engine-signal-sender), I28 (composer settings click on loiyehor; a free dry-run passed).
- I22: a worker's mutation check broke bin/gemini-image in the shared checkout; a gate against that is the
  Harness doctor's.
- I3, I4, I5: no recurrence since 2026-10-01; no gemini-music/sfx/listen leg has run since.
