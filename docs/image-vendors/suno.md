# Suno music and speech in the hidden Chrome

Verified on 2026-10-23 on the free plan (accounts `com`, `notcom`, `locomthebest`), every mode live. The
runtime contract is [suno.json](../../share/image-caps/suno.json); the engine
[`share/suno_music.py`](../../share/suno_music.py) drives suno.com/create in the gemini-web hidden Chrome
(`share/gemini_web.py`: profiles, locks, ledger, failure shots) and reads Suno's own JSON replies from the
page. `bin/suno-music` (kind `music`) and its symlink `bin/suno-speech` (kind `speech`) are the wrappers;
`media-run music|speech --vendor suno` is the only door. Gemini stays the default for both kinds.

## The free plan

| What | Free | Pro / Premier |
| --- | --- | --- |
| Model | v6-mini (`chirp-goose`) only | v6, v6-wild |
| Credits | 50 renewed daily on a UTC clock ([help](https://help.suno.com/en/articles/2418177)); `billing/info` reports `monthly_limit` (com 100, notcom 50; locomthebest, signed up 2026-10-22, 300 that day and 100 the next) and `total_credits_left` | monthly pools, top-ups |
| Rate | `credit_rate_limit`: at most 50 credits at once (200 on a new account), +20 every 600 s | |
| Price | 10 credits a generation = two songs; Speech, cover, mashup, sample, extend the same; crop, remove, reverse, speed 0 | |
| Files | mp3, m4a; **one download unlock per new song**: up to 7 for life on an account made before 2026-09-03, none promised on a later one ([help](https://help.suno.com/en/articles/13876865); `download_usage.additional_download_remaining`: com 6, notcom 6, locomthebest 0; Earn Credits gives none; packs are paid). Downloading an unlocked song again, any format, is free | wav, video, stems & MIDI |
| Rights | no commercial use | commercial |

So a free account makes songs freely but downloads only a handful ever. A take is Suno's own file while the
song is unlocked or the account holds an unlock; with none left it is **recorded as the page plays it** (Egor
2026-10-23: the harness must hear what Suno made): every `<audio>` is routed into a `MediaRecorder` before
anything plays, so nothing reaches the speakers, the song plays once from 0 in real time (its length), and
ffmpeg encodes it to the asked format; the footer says `file=download|recorded`. Measured against the official
mp3 of the same song: correlation 0.999, gain 0.999, 10 ms offset. Suno's terms forbid recording (an account
ban is the risk, which Egor took); the encrypted stream itself is never read or decrypted, and no song is
published to get around the unlock. `--takes` (default 1) is how many of the two songs become files; `--takes 0`
keeps both in the library (`library=` lines), and `--fetch <clip> --account <a> --dest …` saves one later.

## Calls

| Kind | Call |
| --- | --- |
| song | `--dest <abs .mp3\|.m4a> --prompt <styles> [--lyrics <text> \| --instrumental] [--title] [--gender male\|female] [--duration 10-360, step 5] [--weirdness 0-100] [--style-influence 0-100] [--variety 0-4]` |
| describe | `--describe <idea> [--video <abs mp4>] [--image <abs png\|jpg>]`: Suno writes lyrics and styles (the Simple tab); a video or image is scored by Suno |
| edit | `--source <a saved file \| library clip + --account \| abs audio 6-480 s to upload> --mode <mode>` |
| speech | `suno-speech --dest … --text <script> \| --text-file <abs> [--tone …] [--gender] [--no-music] [--variety 0-4]`: a voiced script, background music on by default |
| other | `--fetch`, `--accounts` (from meta), `--status --account` (live), `--login --account [--hand]` |

| Mode | Window | Credits | Endpoint (the page's) |
| --- | --- | --- | --- |
| cover | — | 10 | `generate/v2-web/` task `cover` |
| mashup `--with <clip>` | — | 10 | `generate/v2-web/` |
| sample | `--from --to` (Selection) | 10 | `generate/v2-web/` |
| extend | `--from` (Extend from) | 10 | `generate/v2-web/` |
| crop | `--from --to` (Crop to) | 0 | `edit/crop/<id>/` → `action_clip_id` |
| remove | `--from --to` (Remove Section) | 0 | `edit/crop/<id>/` with `is_crop_remove` |
| reverse | — | 0 | `clips/reverse-clip/` → the clip; title `<source> (Reversed)` |
| speed | `--speed 0.25-4 [--keep-pitch]` | 0 | `clips/adjust-speed/`; snaps to semitones, 1.25 → 1.26x |

An uploaded file lands in the library (`uploads/audio/…/initialize-clip/`) but is never attached to the form
by itself: the engine attaches it through its song page (More options → Remix → Cover), like any clip. Pro-only
(`pro_modes`): Inspo, Edit instruments/vocals, Replace section, Fades, Add stem, Max Mode, WAV, stems. Not
wired: Voice/personas (3 free v6 vox generations an account), playlist inspiration, the lyrics Cowriter.

## Prompting

Community tests on v6 (HookGenius, 2026-10; not Suno's docs, v6-mini itself untested there):

- `--prompt` (Styles, ≤ 1000 chars) is sound only: genre first, then BPM (and key), each instrument's role,
  the vocal (texture, range), the mood's arc, production (era, mix). 250-600 chars of short phrases, or
  sentences saying what each instrument does; a five-tag list drifts generic. No story, no lyrics.
- No artist names: Suno swaps them out (a guitar "capo" was read as an artist and became "German Rap").
  Describe the era, the vocal texture and the instruments instead.
- A negative typed into Styles («no drums») can add the very thing; keep Styles positive (the free form has no
  Exclude Styles field, checked 2026-10-23).
- A tempo word must agree with the BPM: «slow jazz, 140 BPM» fights itself.
- `--lyrics` (≤ 5000 chars): section tags `[Intro] [Verse] [Pre-Chorus] [Chorus] [Bridge] [Outro]`,
  `[Instrumental]` or `[Interlude]` for parts without voice; delivery goes inside the tag of its section,
  `[Verse | whispered, close-mic]`, `[Chorus | belted]`. Keep tags short, or their words get sung. A full song
  is 30-40 lines (under 15 comes out short, over 60 rushed). Spell hard words as they sound, space acronyms.
- `--variety 0` keeps the Styles text as written (52 of 54 takes); the default rewrites it every take. Raise
  `--style-influence` to ~70-75 when the style is half ignored (default 50); `--weirdness` 20-30 for a
  conventional song. The engine already turns "Personalize style prompt" off.
- Two takes of one generation differ more than one prompt edit: judge a prompt over several takes, never one.

## Accounts

The engine rotates the accounts whose meta says `suno_signed_in` and have the credits (a reading under 6 h
old), oldest `suno_started_at` first; a spent account walls 30 min (`suno-walls.json`). Signed in
(2026-10-23): every gemini pool account but abel, whose Google sign-in needs its passkey (`suno-music --login
--account abel --hand`, Egor's step); only com and notcom hold unlocks, the rest get files by recording. A new
account starts with 300 credits for its first day, then 100 a day. The upload terms («Agree to Terms») are
accepted per `~/.gemini-web/notices.json` `agreed_suno` (every Suno account, owner 2026-10-22); upload only
our own tracks.

## Menu

`hammerspoon/llm-limits.lua` `appendSuno`, right after ElevenLabs: one `1d` row per signed-in account from
the account meta (`suno_credits`, `suno_credits_limit`, `suno_at`), the reset column holding the credits
left; red when the account cannot make a song (a wall, credits under one generation). Unlocks are not shown:
a song with none left is recorded, so they no longer decide whether a file comes. A run or
`--status` refreshes the meta; the menu never launches Chrome.

## Traps

- Suno keeps the create form across visits: every run clears it (Advanced → Clear all) and removes Simple's
  attached media chips; Speech has no Clear, so every control is set.
- The pills (Vocal Gender, Background music, Duration) are outside the accessibility tree: matched by text.
  More Options' header carries a summary of what is set; open state is its `aria-expanded`.
- The first generation on an account may ask hCaptcha; it passed by itself so far, else exit 4 with
  `--login --hand`.
- `caps=stale` means the condition menu, the More options menu or the model list differ from the manifest.
