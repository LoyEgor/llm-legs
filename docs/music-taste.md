# Egor's taste in background music

Read this before you generate or pick background music for his decks, sites or videos. It comes from his own
blind marks in 2026-10. The source data is in `/Volumes/Work/Projects/listen-bench` (README, `dataset/`). No model
shares his taste: Flash's background scores do not follow his, and Argon picks against him on "pleasant". So the
model shortlists and he decides.

## Vendors by his ear

- **Blind round "storm"** (one brief, ten takes, loudness matched, like 1-5):
  - Suno v6-mini: 3.8 (all four takes in his top four);
  - Gemini app (Lyria 3.5): 3.0;
  - ElevenLabs music_v2_5: 2.7 (its loop mode was his lowest);
  - Flow Music (Lyria 3 Pro): 2.5.
- **Deck fit set:** ElevenLabs beat Flow on four of five decks.

## Right

- Light, uplifting and even.
- Light purposefulness: a quiet call to action.
- An Interstellar feel without the hurry.
- Atmosphere and depth, and a non-classical instrument. These beat a merely pleasant sound when they differ.
- Light country or blues for a heritage brand.
- Weight and scale when the brand asks for "something big".

## Wrong

- Drama (his "Twin Peaks").
- A metronome or clock pulse that makes you anxious, or a loud heartbeat pulse.
- 1980s phone hold music.
- A relax room or sauna calm.
- A children's adventure, a fair, beach chill or "little mermaids".
- An organ: it ages the music.
- A harmony that plays notes you don't expect.
- A broken or irregular rhythm.
- Banal "classic" playing, musicians who just play.
- Drums, a lead or builds that pull attention.

## Background is a property of the whole take

Many takes change character midway, for example warm and calm until 0:32 and club after it. He picked one Suno
take for its first 0:50 and said the rest «испортила фоновость». Judge each part on its own and use only the part
that fits. `audiokit` (`docs/audiokit.md`) cuts and loops it. A development that loses the opening's atmosphere
is wrong too.

## Measures that follow him

- `audio-score --music <abs>…` gives Essentia `engagement`, where lower means more background. On his 16 marked
  deck takes it followed his background fit at +0.58 (Spearman). Argon reached +0.41 and Flash −0.11. Of six
  pairs, the take with the lower engagement was his pick in four, the same as Argon.
  It misses a calm take in the wrong mood. Its mood tags show that: his "sauna" take got relaxing, meditative.
- Abstract themes ("heritage, honest craft") are beyond the local models; a listen model judges theme.
- Defects at joins and loops: `audiokit check`, never a listen model.
