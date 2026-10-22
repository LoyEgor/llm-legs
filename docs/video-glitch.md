# Glitches in generated video

Goal (Egor, 2026-10-22, handoff `docs/handoffs/2026-10-22-video-glitch.md`): after every generation, tell the
ordering LLM what is visibly broken in the clip. Two hard rules: it never fails a good clip (missing a small
glitch is fine, a remake of a good take is not), and it stays cheap in tokens. Status: calibration. `bin/gemini-video` can run
the check on every delivered Flow take (all `--count` variants at once) and print its lines after the footer, but
it is off until the judge is settled on Egor's labels (2026-10-22: «не будем ничего добавлять в скилл, пока не
определимся»); `GEMINI_VIDEO_GLITCH=<path to bin/video-glitch>` turns it on, and a failed check prints
`glitch=unchecked … reason=…` and never fails the take.

## The check

`video-glitch check <video>` cuts 2 frames a second (at most 24, longer side 1280 px, each stamped `t=<s>`),
hands them to one Sol call through `worker-run run codex` with `share/video-glitch/judge.md`, and prints
`glitch=ok|defects` and one `t=<a>-<b> <object>: <what> noticeable=yes|no` line per defect; only `noticeable=yes`
makes `defects`. Every check is appended to `data/video-glitch/checks.jsonl`. About 20 s and 30k tokens a clip.

Calibration (2026-10-22, 25 known-bad and 35 accepted deck films, plus 67 pool takes):
- Sol, checklist prompt: 16 of 25 known-bad caught, 0 of 35 accepted films failed. Low, medium and high effort
  give the same verdicts; high costs 3.5x the tokens and 4x the time, so the default effort stays.
- Its misses: the 2x walk and the forward-and-back fire loop (no judge sees speed or reversal: those are
  mechanical, see below) and seven turning2 entrance takes whose fault may be the plan, not a glitch.
- Pool: 19 of 67 takes flagged, one of the 11 that went into the R7-A film (a mouse turning into a notebook).
- Haiku, Luna and Terra caught 0-1 of 2 in the first grid whatever the prompt: they see the door open by itself
  and explain it away ("a motion-activated door"). Opus and Sonnet catch as Sol does but cost several times more.
- Giving the judge the generation prompt with a "does not do what the prompt asks" item added false alarms on
  three takes that went into the film (a hand that stops short of the screen): dropped.
- A pose-based check (MediaPipe) counts steps per second well enough to catch the 2x walk (3.4 steps/s against
  1.2-1.5) but its limb-plausibility score does not separate broken bodies from good ones: speed only.

## The labelled set

`bin/video-glitch` (`share/video_glitch.py`) keeps the set that every judge, prompt and threshold is measured
against. Egor's labels are the ground truth; they live in git so they survive every chat and every rework
of the judges.

| File | What |
|---|---|
| `share/video-glitch/clips.jsonl` | one row per clip: `id`, `set` (known-bad, control, pool), `src`, `sha256`, size, fps, duration, `project`, the generation `prompt` when known, `note` |
| `share/video-glitch/labels.jsonl` | Egor's labels, append-only; the newest row per clip wins |
| `share/video-glitch/flags.jsonl` | judges' candidate defects (`clip`, `judge`, `t0`, `t1`, `object`, `what`, `id`, `ru` the Russian he reads), shown on the page for him to confirm or reject |
| `share/video-glitch/judge.md` | the judge prompt `check` sends |
| `data/video-glitch/clips/<id>.mp4` | a copy of each clip (gitignored), so a moved or cleaned render keeps its label usable |

A label row: `verdict` (`ok` clean, `minor` glitches he would let pass, `reject` a remake), `defects` (each `t0`,
`t1`, `kind` of body, object, text, causality, speed, physics, popping, other, `severity` reject or minor, and
his `words`), `flags` (his yes/no per judge flag id) and free `words`. His own words are kept verbatim
(Russian dictation) so later prompts can quote what he calls a glitch.

```
bin/video-glitch add <video>... --set known-bad|control|pool [--project P] [--prompt-file F] [--id ID] [--note N]
bin/video-glitch flags <clip> <judge> <reply.txt>   # a judge's `t=` lines become flags on the page
bin/video-glitch label [--port 8765]               # the page on 127.0.0.1; every change is saved at once
bin/video-glitch list
```

The page asks, not lists: Egor labels about 20 clips a sitting (2026-10-22), so the sidebar shows only the
open questions, most decisive first, capped at 20 a day; every clip is folded under «все клипы». Asked, in
order: a judge's flag on a take he accepted (a deck film, or a pool take that went into a film); a known-bad
take no Sol judge flagged; a flag on a take nobody judged; sibling takes of an asked shot last. Never asked: a
flagged known-bad take, an unflagged accepted film, and the clips marked `mechanical` (speed, reversal). Flags
of different judges on one moment show as one row. The clip opens half a second before the first flag.

The page: the clip loops muted; space plays and pauses, ←/→ step one frame, ½× and ¼× slow it down. Per clip
Egor gives a verdict (1/2/3), pauses on each glitch and presses ＋ (G), which stamps the time, then says what is
wrong into the field; judge flags on the timeline get ✓ or ✗. N opens the next unlabelled clip.

Sets: `known-bad` are takes he already called broken (the turning2 entrance takes, the 2x walk, the reversed
fire loop); `control` are deck films he accepted; `pool` is everything else (the R7-A takes of the video project,
whose Gemini reviews are in each clip's `.review.md` and whose calibration said they are right half the time).
