# Hand-off: catch glitches in generated video before a person sees them

Status: design agreed with Egor (2026-10-22), nothing built or tested. Start with the calibration round below.
To: a fresh chat Egor opens for it. From: the arbostar-logo chat, which keeps the logo work.

## What Egor wants

Video models often deliver rubbish, and the LLM that ordered the clip often misses it. He finds it by eye afterwards,
and that costs remakes and his time. He wants a system that reports what is wrong with a clip to the parent LLM, which
then decides whether to remake it. In his words: it should «надёжно срабатывать… лучше, чтобы она пропускала небольшие
глюки… и не жрала много токенов, но относительно надёжно отсеивала проблемы». So: miss small glitches rather than raise
false alarms, catch the big ones, and keep it cheap.

The defects he means:
- Bodies: a twisted limb in a single frame. `2026-10-22-video-glitch/twisted-arm.png`: the left arm holding the vial
  bends at an impossible angle. It comes from a project outside arbostar; ask Egor for the clip.
- Objects melting into each other. `2026-10-22-video-glitch/turning2-entrance-doors.png` is from the arbostar turning2
  entrance film: a revolving-door drum grown into a flat glass wall with a swing door's frame.
- Causality: the door opens before the man reaches it.
- Speed: a walk twice too fast.
- Physics direction: fire or smoke running the wrong way.

## Decided with him

- **No mechanical detector in front.** Egor: generated glitches are smooth deformations, not jumps, and a frame
  difference cannot tell a planned change from a bug. Pixel detectors also failed us on oversharp
  (`2026-10-21-flow-upscale-oversharp.md`).
- **Two tiers of LLM:**
  1. Single-frame defects (bodies, hands, melted objects, warped lettering or logos): a cheap model (Haiku) sees
     frames at 2-4 fps, large, not as thumbnails (a twisted arm does not show at 420 px).
  2. Defects in time (speed, direction, causality, objects popping): one strong call (Sol or Opus) on a timestamped
     contact sheet (`bin/frame-sheet`, 8 fps). It also gets the clip's prompt, so a planned change is not a defect,
     and it gets the tier-1 flags to confirm, which removes the cheap model's false alarms.
- Ask specific questions. A judge asked "any problems?" says fine. A judge asked to count steps per second on the
  sheet caught the fast walk.
- **Output to the parent LLM:** `ok`, or a list of `t=<s> <what> <noticeable at normal speed: yes/no>`. The parent
  decides. Only the "noticeable" items count as a defect.
- **Place:** after fetch in `media-run video`, like the jitter steadying and the oversharp clean, so it runs in every
  chat.

## Known, from arbostar (memory video-judging, 2026-10-21)

- Speed: Sol on a frame sheet at 8 fps, asked for foot strikes, said "3.2 steps/s, a calm walk is 1.6-2.0, 1.6x fast",
  which matches Egor. Opus was as good. Gemini Flash and Argon watching the video said "natural".
- Backwards motion: no judge is reliable. arbostar's `tools/deckkit.py` `reversed_video` stops a deck build whose film
  mirrors around a frame. Keep that mechanical; it is the one case where mechanics work.
- Gemini Pro is on no account any more.
- What exists to start from: `bin/frame-sheet` (the sheet) and the numbers in `docs/image-vendors/gemini.md`. Nothing
  else was built. The raw answers of that round are in `2026-10-22-video-glitch/judged-2026-10-21/` (`<clip>-<judge>.md`;
  the sheets are one `frame-sheet` call each, not kept). Clips, under `~/Arbostar/arbostar-logo/renders/night/`:
  - `round7_wall_wall-even` = `turning2/round7/wall/wall-even.mp4`, the walk retimed to about 2x. Opus: 1.9x fast;
    Flash and Argon: natural.
  - `round6_film_wall` = `turning2/round6/film/wall.mp4`, the untouched take. Opus: slow, 1.25 steps/s.
  - `fire_hover-loop` = `original/r17/films/hover/hover-loop.mp4`, the forward-and-back loop. Opus: "wrong" for a
    flame pop and sparks fading in mid-air, but it never named the reversal; Argon: reversed.
  - `fire_iron-hover` = `original/r17/films/iron-hover.mp4`, the forward take. Opus: ok; Flash: "frozen"; Argon:
    reversed (a false alarm).
  - `a-3-door.jpg`, `b-3-door.jpg`: door crops of two turning2 entrance takes (`round7c/wall/a-3`, `b-3`), where the
    man walks sideways along the doors instead of going in.

## Calibration first (one round, then decide)

- Known bad:
  - the turning2 entrance takes in `~/Arbostar/arbostar-logo/renders/night/turning2/round7c/wall/`, `round7d/wall/`
    and `round8/wall/` (the deck plays `round8/wall/d.mp4`, which has the door mush; ask Egor which takes are bad, in
    a short round, with only the open questions);
  - the turning2 entrance retimed to 6.1 s (walk twice too fast; arbostar git 3eb7201 and earlier);
  - original's forward-and-back iron loop (fire and smoke backwards; arbostar `renders/night/original/r17/films/`);
  - Egor's twisted-arm clip.
- Good controls: about ten deck films he accepted (`~/Arbostar/arbostar-logo/site/p/*/img/*.mp4`).
- Run the two tiers with Haiku, Sonnet, Sol and Opus. Build only if the setup catches most of the known bad with almost
  no false alarms on the controls. Otherwise tell Egor plainly and stop. Before spending, name the cost to him: runs
  and lines.

Egor's process rules: answer him in Russian, briefly; numbered cards; ask him only the open points.
