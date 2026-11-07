# Hand-off: the GPT cut-out without defects (ChatGPT Remove BG and GPT asked in words, laid back onto the source)

Status: open

To: a new chat, opened for this on Egor's word, 2026-11-07. Egor drives it and talks to you directly, in Russian,
in plain words.
From: «CorridorKey keyer установка и тесты»
(`cd '/Volumes/Work/Projects/llm-legs' && claudeb profile locomthebest --resume c15cc64c-0cc7-43d6-aa81-bd39b7f6aa49`).
That chat keeps CorridorKey (CK) and the shadow layer. This hand-off splits the GPT side off it.

## Goal

Egor keeps both engines: CK (local keyer) and the GPT cut-out (ChatGPT re-renders the picture without a background).
He wants:
- the GPT version free of the defects below;
- defects caught by the tool itself, because a calling LLM does not notice them;
- at the end, clear zones of use (when CK, when GPT). These are written together with the CK chat on one comparison
  page over the shared test set.

## Defects Egor marked (2026-11-07, page `ck-shadow-gpt-exjfpg`)

Page: http://127.0.0.1:4791/p/ck-shadow-gpt-exjfpg/ (`page state ck-shadow-gpt-exjfpg`). Each pin image is a sheet:
the region he boxed in magenta, on every variant, with the variant letters as labelled in that sheet.

1. **Green fringe on fur**, GPT Remove BG, item `real-dog-green`: the tail and paws carry the green screen.
   - `/Users/egorloy/Pages/ck-shadow-gpt-exjfpg/files/img5.png` (tail)
   - `/Users/egorloy/Pages/ck-shadow-gpt-exjfpg/files/img6.png` (paws)
2. **Doubling**, item `car-nissan-frontier-pro-4x-white` (the pickup sprite on white). Both "GPT: стёкла словами" and
   GPT Remove BG show the rear and the tail-light twice.
   - `/Users/egorloy/Pages/ck-shadow-gpt-exjfpg/files/img7.png`
   - `/Users/egorloy/Pages/ck-shadow-gpt-exjfpg/files/img8.png`
   - Egor's reading: two renders of the car from different masks, summed. Whatever the cause, it is a reject.

Not yours: "GPT, тень из кадра" (GPT object plus the shadow measured from the frame). The shadow is the CK chat's
code, and so are its defects (img4, img9, img10).

## Where it comes from (read in code, not yet proven)

- `share/image_matte.py` (llm-legs; `tests/test_image_matte.sh`; called by codex-image `--remove-bg --composite`)
  lays ChatGPT's cut-out back onto the input:
  - one global SIFT + RANSAC similarity registers the re-render onto the input;
  - the delivery is the cut-out's alpha, the input's pixels inside the subject, and the cut-out's own pixels with
    tone corrected to the input in an edge band.
- **Doubling, likely.** GPT redraws parts of the car slightly displaced. One global transform cannot align a local
  redraw, so GPT's alpha edge and the input's pixel edge disagree, and both show.
- **Green fringe, likely.** Where GPT's alpha covers fur, the input's pixels (or the tone target) are the green
  screen. Nothing removes the screen's colour there.
- Hypotheses to test, not decisions:
  - a local warp in the edge band (dense flow or piecewise);
  - screen-colour suppression where the input shows the backdrop;
  - an automatic check that flags a ghost edge or screen-colour residue and refuses or repairs the delivery.

## What exists

- **Bench:** `/Volumes/Work/tmp/corridorkey/`.
  - Page builder: `scripts/gpt_page.py`, which writes `view-gpt/<case>/<engine>.png` and `view-gpt/spec.json`.
  - Older layout script: `scripts/convert_gpt.py`.
  - GPT runs: `runs/gpt-*` (`gpt-matte`, `gpt-prompt`, `gpt-glass-words` and their `-matte` lays).
  - Inputs: `testset/still/<case>/` and `testset/real/`.
  - Truth alpha: `testset/still/<case>/alpha.png` for sprites, logos and the Blender renders.
- **Earlier results** live in `docs/handoffs/2026-11-05-corridorkey-keyer.md`:
  - the stills tables (GPT + image_matte page error 3.9–10.8);
  - colour change 7.5 % where α > 0.98;
  - 34–89 s per still;
  - its usage map, which lists GPT Remove BG as "none".
  - Your fixes are what may move that verdict.
- **The 13 page items:**
  - real SUV on green and on grey;
  - Blender car with glass on grey and on green;
  - a glass bottle on white;
  - Rentiva sprites on white, on green and the pickup on white;
  - curls on white and on green;
  - fine blonde hair on grey with a shadow;
  - chiffon and hair on white with a shadow;
  - a fluffy dog on green.

## Done (2026-11-07, this chat)

Both defects reproduced and fixed in `share/image_matte.py`, proven on the bench and on one fresh web route run:
- **Green fur:** GPT's solid alpha covered the input's screen above the tail; the tone match learnt "greener" there
  and painted GPT's clean fur. Tone is now learnt only where input and cut-out agree; input pixels a coloured screen
  leaks into (between strands, through glass) come from the cut-out; a replicated soft edge past GPT's frame is cut
  where the input shows the screen.
- **Doubling:** GPT redrew the rear 20-25 px off. A local flow (part scale, kept only where it lowers the mismatch)
  moves the cut-out onto the input.
- **Self-check:** `ghost=` (displacement left across edges) and `residue=` (screen colour, densest window) on the
  line; over `GHOST_LIMIT`/`RESIDUE_LIMIT` the cut-out is delivered as is (`reason=ghost|residue`). The old
  deliveries would have been refused (pickup 16 px, dog 52 %).
- Left: GPT's own green in an SUV window it drew green (only see-through glass fixes it), paws GPT drew shorter;
  the zones of use with the CK chat.

## The seam with the CK chat

- You deliver the object as RGBA in the input's frame.
- The shadow is a separate multiply layer, owned by the CK chat. Do not build a shadow into the GPT object; a
  variant that needs one takes the CK chat's layer.
- Questions for that chat go by SendMessage to «CorridorKey keyer установка и тесты».

## Rules that bind here

- **Media calls go through `media-run`** only. Read the media skill first.
  - The ChatGPT browser route is free, any number of times.
  - A CLI or API run needs Egor's yes each time.
- **`image_matte.py` is a shared tool** (every codex-image `--remove-bg --composite`). A change is proven on the
  general route as well as on this bench, and `tests/test_image_matte.sh` stays green.
- **Hands off Rentiva:** never touch the Rentiva repo, `/Volumes/Work/tmp/rentiva-*` or ports 3200–3205.
- **No verdict from a metric alone.** Every image claim gets a look at aligned crops.
- **Commits:** on main by explicit paths, never `git add -A`. Uncommitted files you did not author are someone's
  live work.
