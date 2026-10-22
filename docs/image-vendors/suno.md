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
| Credits | 50 renewed daily on a UTC clock ([help](https://help.suno.com/en/articles/2418177)); `billing/info` reports `monthly_limit` (com 100, notcom 50, a 2026-10-22 sign-up 300) and `total_credits_left` | monthly pools, top-ups |
| Rate | `credit_rate_limit`: at most 50 credits at once (200 on a new account), +20 every 600 s | |
| Price | 10 credits a generation = two songs; Speech, cover, mashup, sample, extend the same; crop, remove, reverse, speed 0 | |
| Files | mp3, m4a; **one download unlock per new song** (`download_usage.additional_download_remaining`: com 6, notcom 7, a new account 0; Earn Credits gives none; packs are paid). Downloading an unlocked song again, any format, is free | wav, video, stems & MIDI |
| Rights | no commercial use | commercial |

So a free account makes songs freely but saves only a handful of files ever. `--takes` (default 1) is how
many of the two songs become files; `--takes 0` keeps both in the library (`library=` lines), and
`--fetch <clip> --account <a> --dest …` saves one later. Never capture the player's stream and never publish
a song to get around the unlock: the owner's rule (2026-10-22).

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
wired: Voice/personas (3 free v6 vox generations an account), playlist inspiration.

## Accounts

The engine rotates the accounts whose meta says `suno_signed_in`, have the credits (a reading under 6 h old)
and the unlocks `--takes` needs, oldest `suno_started_at` first; a spent account walls 30 min
(`suno-walls.json`). Signed in: com, notcom, locomthebest (0 unlocks: library-only). The owner allowed
every gemini pool account; the rest stay unsigned because a new account gets 0 unlocks:
`suno-music --login --account <name>` signs one in through «Continue with Google» on his word. abel needs
its passkey (`--hand`); egbogd stopped at Google's consent screen. The upload terms («Agree to Terms») are
accepted per `~/.gemini-web/notices.json` `agreed_suno` (every Suno account, owner 2026-10-22); upload only
our own tracks.

## Menu

`hammerspoon/llm-limits.lua` `appendSuno`, right after ElevenLabs: one `1d` row per signed-in account from
the account meta (`suno_credits`, `suno_credits_limit`, `suno_downloads`, `suno_at`), the reset column
holding the credits left and `↓N` the unlocks left; red when the account cannot deliver a file. A run or
`--status` refreshes the meta; the menu never launches Chrome.

## Traps

- Suno keeps the create form across visits: every run clears it (Advanced → Clear all) and removes Simple's
  attached media chips; Speech has no Clear, so every control is set.
- The pills (Vocal Gender, Background music, Duration) are outside the accessibility tree: matched by text.
  More Options' header carries a summary of what is set; open state is its `aria-expanded`.
- The first generation on an account may ask hCaptcha; it passed by itself so far, else exit 4 with
  `--login --hand`.
- `caps=stale` means the condition menu, the More options menu or the model list differ from the manifest.
