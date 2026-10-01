# Video prompting and chaining (gemini-video on Google Flow)

Read this before you write a `gemini-video` prompt or plan a sequence of clips. It combines Google's
official guidance (fetched 2026-10-01, sources at the end) with what we measured on Flow. Facts about
the harness itself (flags, credits, exits) are in `docs/image-vendors/gemini.md`.

## Pick the input

| You have | Flags | Model |
|---|---|---|
| only an idea | `--prompt` | auto: Veo Fast for 8 s, Omni for 4/6/10 s |
| a still to start from | `--first-frame` (a lone `--ref` is the same) | any |
| a start state and an end state | `--first-frame` + `--last-frame` | any |
| a character, object or style that must appear | `--ref` ×1–4 | Veo takes 3 (8 s only), Omni 4 |
| a finished video to change: restyle, add or remove a thing or a character | `--edit` (+ `--ref` for what to add) | Omni |
| a Flow Veo clip whose action must go on | `--extend` | Veo 3.1 Lite |

Frames and ingredients are separate Flow modes: `--first-frame`/`--last-frame` never combine with `--ref`/`--edit`.

## Writing the prompt

- **Structure (Veo):** subject + action + style, then camera, composition, lens and light. Say what kind
  of video it is first (realistic, animated, stop-motion). Describe people concretely ("a woman in her
  twenties with wavy brown hair and light freckles").
- **One focused moment per clip.** Google: chaining A, then B, then C "often leads to muddled or
  incomplete videos". Split a story into clips and chain them (below). Keep changes subtle in short clips.
- **Omni makes cuts on its own.** For one shot write "In a single continuous shot, no scene cuts." Omni
  takes timecodes (`[0-3s] … [3-6s] …`) or "after 3 seconds, …"; Veo has no documented timing syntax.
- **Audio in separate sentences:** dialogue, sound effects, ambience. Write dialogue as
  `The man says: we are late.` (no quotes) when the words must not appear as on-screen text.
- **Negatives:** Omni understands inline "No dialogue." / "No extra sound effects."; for Veo describe
  what you want instead ("an empty street", not "no cars"): the Flow composer has no negative field.
- **Text in the picture:** quote the exact wording (Omni).
- **Length:** the prompt limit is 1,024 tokens; a tight paragraph beats a page.

### Starting from images

- **First frame:** do not describe what the image already shows ("redundant prompts confuse the
  model"). Prompt the motion: camera, subject, environment. Refer to people as "the woman", "he".
- **First + last frame:** describe only the event or transition between them ("the car takes off from
  the cliff"). The same image as both frames makes a loop.
- Use a sharp, well-composed source image.

### Ingredients (`--ref`)

- Mention every ingredient in the prompt by what it is: "the woman", "the brass stopwatch from the
  reference image". `gemini-video` attaches the images as ingredient chips; plain words point at them.
  Flow's own `@name` mentions are a UI shortcut you do not need.
- One subject per reference, on a plain background; keep extra subjects out of location or style
  references; keep the references' look consistent so they blend.
- The prompt must complement the references, never contradict them.
- **The same character across clips:** pass the same reference images each time and paste the same
  verbatim character description (and voice description) into every prompt; change only the action or
  setting. Flow's reusable Characters (1–2 images + name + voice) are not wired into gemini-video.

### Editing a video (`--edit`)

- Any source video (a Grok clip too), up to 30 s; the result keeps the source's length. Our live edits
  used 8 s sources; Google says an edit works on a segment of up to 10 s, so trim a longer source to
  the part you need first (`ffmpeg -ss <start> -t <seconds> -i in.mp4 -c copy part.mp4`).
- One short instruction, then "Keep everything else the same." Over-described edit prompts change
  things you did not ask for. Good: "Make the phone invisible. Keep everything else the same."
- **Put a character or an object into a video:** `--edit clip.mp4 --ref thing.png` and say what it is,
  where it is and what it does: "Add the antique brass stopwatch from the reference image lying on the
  sand under the water, in the middle of the frame. Keep everything else the same." (Verified: the
  stopwatch sat on the sand with the water's light moving over it, 20 credits for an 8 s clip.)
- Editing uploaded videos is blocked in the EEA, UK and Switzerland (not our case).

## Chaining clips into a longer shot

Two ways to continue clip A:

1. **Frame chain:** `video-chain last-frame A.mp4 A-last.png`, then the next clip gets
   `--first-frame A-last.png`. Works with any model and any source, Grok clips too. But the new clip
   sees one still: speed and direction are gone. From one frame a ball in mid-air may be rising or
   falling, so the new clip may reverse, freeze or restart the motion, and the sound restarts.
2. **Extend:** `gemini-video --dest A-ext.mp4 --extend A.mp4 --prompt …` continues from A's last second
   (24 frames), so motion, speed and ambient sound carry over. Measured twice: a 7 s continuation at
   720p for 10 credits, seamless from A's last frame. Only for Veo clips that gemini-video saved from
   Flow (the job ledger remembers the account and project); it runs on that account. Omni, uploaded and
   Grok clips cannot be extended (Flow lists Omni extension as "coming soon"), and neither can an
   extension. The output is only the new part, at 720p; `video-chain join` puts them together.

**Choose by the ending of A:**

```
video-chain end-motion A.mp4 --strip A-tail.png
```

- `motion=still` (score under 4: the frame barely changes): a frame chain is safe. Pick the model for
  the next clip by its content.
- `motion=moving`: look at the strip (three frames across the last second) and decide whether that
  motion has to continue across the cut:
  - it has to continue (something falling or thrown, a pan or dolly, a turning part, a walk): Extend
    if A is a Flow Veo clip. Otherwise frame-chain and state the motion in the next prompt: direction,
    speed and what keeps going ("the ball keeps falling toward the floor as fast as before"), or fix the
    end state with `--last-frame` as well.
  - it may stop or change at the cut (a new beat, a cut to another angle): a frame chain or a plain
    cut is fine.
- The score measures how much the strongest region moves, not which way; the strip shows the way. For
  scale, last-second scores we measured: a stopwatch with a slowly moving hand 18, a slowly turning knob
  23, sunlit water ripples 29, a restyled clip with a moving camera 63.

**Plan for it.** If a shot will need to go on with its motion, make its first clip on Veo
(`--model fast` or `--model lite`, 8 s) so Extend stays possible; Omni 4/6/10 s clips cannot be
extended.

**Extend prompts:** describe how the action continues ("the knob keeps turning slowly clockwise, as
before") and repeat the original prompt's style, camera and light words. A voice continues only if
someone is speaking in the last second of A. One Extend per clip: past A + 7 s, continue with a frame
chain from the extension's last frame, or extend a new Veo clip.

**Join:** `video-chain join out.mp4 A.mp4 A-ext.mp4 B.mp4 …` re-encodes to the first clip's size and
frame rate with AAC stereo, silence where a clip has none. Extensions come only at 720p (Flow has no
upscaled download of an extension), so keep a chain that uses Extend at 720p; a 1080p first clip makes
the join scale the extension up. A frame chain repeats A's last frame once (1/24 s); it is invisible in
most shots.

## Variants (`--count`)

One clip per call is the default. `--count 2`–`4` renders takes in one send at that multiple of the
credits; use it only when choosing between takes is worth it (a hero shot whose motion often fails).
Files: the `--dest`, then `<stem>-2.mp4`, `<stem>-3.mp4`; the footer adds a `variant=` line per extra
take and a `refused=` line for a take Flow's filter blocked. Several calls work as well and let each
prompt differ.

## Aspect, length, resolution, credits

- Aspect: `--aspect 16:9` or `9:16` only; others exit 2. Crop or pad afterwards for another frame.
- Length: Veo 8 s; Omni 4, 6, 8 or 10 s; an edit keeps its source's length; an extension adds 7 s.
- Resolution: 360p (Omni drafts, about half the credits), 720p, 1080p (Flow's free upscale of 720p).
- Credits on PRO (1,000 a month per account): Omni 360p 4/6/8/10 s = 4/5/6/7; Omni 720p = 7/10/12/15;
  Omni edit at 720p = 20; Veo Lite/Fast/Quality 8 s = 10/20/100; Extend = 10; first + last frame adds
  nothing; `--count n` multiplies.

## Sources

- Gemini API: Veo https://ai.google.dev/gemini-api/docs/veo, Omni https://ai.google.dev/gemini-api/docs/omni
- Vertex AI: prompt guide https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/video/video-gen-prompt-guide,
  best practices https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/video/best-practice,
  extend https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/video/extend-videos
- DeepMind Veo prompt guide https://deepmind.google/models/veo/prompt-guide/
- Flow help: create https://support.google.com/flow/answer/16353334, edit https://support.google.com/flow/answer/16935718,
  models https://support.google.com/flow/answer/16352836, characters https://support.google.com/flow/answer/16935308
- Not published by Google: any rule for Extend versus a last-frame restart, failure modes of first/last
  frame generation, Flow's own reference caps. The chaining rules above are ours.
