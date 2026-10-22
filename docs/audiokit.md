# audiokit — music loops and joins, by Egor's ear

`bin/audiokit` (`~/.local/bin/audiokit`) is the only way to loop a music track or judge a join in this setup: local,
free, no account. Do not write your own ffmpeg/numpy loop or seam script; every one before it shipped a click. Its
limits come from 55 joins Egor marked by ear on the listen-bench (`/Volumes/Work/Projects/listen-bench`, `loops.html`,
README "Editing defects"). No listening model is the answer key: Gemini Flash called 28 of 29 made defects "none".

```text
audiokit loop <in> <out .m4a|.wav|.flac> [--min 30] [--max <s>] [--at <start>,<end>] [--lufs -20] [--clip <out .wav>]
audiokit points <in> [--top 10] [--min 30] [--max <s>]
audiokit check <file> [--loop] [--at <s>,<s>...]
```

- **loop** picks the start and end itself (whole bars of the take's own beat), joins them with a 10 ms
  correlation-aware crossfade, sets one linear gain to `--lufs`, writes the file, decodes it back through ffmpeg
  and Apple's decoder, and prints `loop <start>-<end> s …`, `share=`, the measures, `verdict=`. `--at` takes points
  from `points`; `--clip` writes the 6 s before and after the wrap for a listen.
- **points** lists candidate pairs with every measure and `clean|borderline|heard`.
- **check** reads any file for digital silence inside the music, beat-grid jumps, and with `--loop` (the wrap) or
  `--at` (your joins) the waveform step and level dip there. A grid jump where nobody cut is `listen`, not a verdict.
- Exit 0 answered (read `verdict=`), 2 usage, 4 `uv` or `ffmpeg` missing.

## Reading the verdict

`share` is the worst of four measures as a share of its limit. Under 0.85 Egor heard 20 of 21 joins clean; 0.85-1,
3 of 5 heard; 1 and over, all heard but one. So:

| verdict | do |
|---|---|
| `clean` | use it as written |
| `borderline: …` | the best this take has sits near a limit: try `--min/--max`, another take, or ask Egor to listen to `--clip` |
| `audible: …` | the take has no clean loop (Flow songs whose sections never repeat): another take, a fade, or regenerate |

The four measures (the module docstring holds the calibration):
- **voice cut** — a tone held through the end falls after the wrap («у гитары тянущийся звук обрывается»), from 10 dB;
- **stems** — a whole part drops out or comes in (Demucs drums/bass/other/vocals; «инструмент явно исчез»), 8 dB
  over 1 s or 15 dB over 2 s;
- **notes** — an instrument plays other notes in the 0.2 s after the wrap («пианино играет одно, резко перестаёт и
  начинает играть другое»), from 0.30;
- **likeness** — the music around the start is not the music around the end, the lead lands elsewhere in its phrase,
  at 0.30 and under; above that it only ranks.

## Playing and shipping a loop

- Ship the file byte for byte: no re-encode, loudnorm, resample, trim, fade or limiter after `audiokit loop`.
- In a page, `<audio loop>` restarts with the browser's own gap. Use Web Audio: fetch → `decodeAudioData` →
  `AudioBufferSourceNode` with `loop = true` (sample-exact: audiokit's m4a decodes to its exact length in Chrome and
  Safari). A loop made elsewhere: `check --loop` names the `loopEnd` its tail needs.
- A loop to 0.1 s is a slice of the take, not a new performance: it inherits the take's own slips (`check` on the
  take shows them as `listen`).

## Bugs it exists for

| bug | what the ear gets |
|---|---|
| ffmpeg decodes ~20 ms of AAC end padding past the container length | a gap and a grid shift at the wrap; read to the ffprobe duration |
| Apple's encoders (`afconvert`, `aac_at`) pad ~600-700 samples | a gap ffmpeg (Chrome) plays |
| Chrome's `decodeAudioData` skips the edit list's end, decoding to the last AAC frame's edge | up to 1023 samples of the loop's start past its end: a click every wrap |
| ffmpeg's default mp4 timescale (1000) | up to 1 ms cut off: a click |
| a loop ending on silence (ElevenLabs loop-mode takes: 17-19 ms) or with its last samples pulled to zero | a click every pass |
| a crossfade of two parts whose beat grids sit apart (old decks: 190-250 ms) | two near-identical beats, a doubled rhythm |
| a hard cut | a click; any crossfade from 1 ms hides it |
| a jump to another bar of a varied phrase (generators vary a phrase's 2nd bar) | a held note leaps, a part vanishes or the lead restarts its phrase |

## Setup and cost

- `uv` provisions numpy on the first run, and Demucs (`share/audiokit_stems.py`, torch 2.14.1) on the first file
  that needs stems: about 30 s and 2.6 GB per 2-minute track on Apple's GPU, then cached by the file's content
  under `~/.cache/audiokit` (`AUDIOKIT_CACHE`).
- `AUDIOKIT_STEMS=off` skips Demucs: the stems and notes go unchecked and the output says so. Use it only for a
  quick look, never for a verdict you ship.
- A loop of a 2-minute track takes about 25 s with cached stems.

## Known misses and re-tuning

- One guitar note change he heard faintly reads clean on every measure (listen-bench card 12).
- Demucs puts a quiet part in different stems from run to run; the 2 s stem window carries it.
- A new limit is tuned only against his marks: the listen-bench's `defects.py loops` builds a round page,
  `serve.py` saves his marks to `dataset/loop-marks.json`, and each fit is checked on a held-out round first.
