# ElevenLabs audio through its REST API

Verified on 2026-10-06 against the live OpenAPI spec (313 paths) and one live call per kind on the
`trimmed` account (Creator tier). Unlike the other vendors this is a paid API, not a subscription CLI or
browser: every call spends credits from the account's monthly pool. The runtime contract is
[elevenlabs.json](../../share/image-caps/elevenlabs.json); one stdlib module,
[`share/elevenlabs_media.py`](../../share/elevenlabs_media.py), serves every kind through a thin
`bin/elevenlabs-<kind>` wrapper, and `media-run <kind> --vendor elevenlabs` is the only door.

Scope (owner, 2026-10-06): everything audio. Images and ordinary video (GPT Image, Veo, Seedance through
ElevenLabs Flows) stay with codex/gemini/grok. The one Flows ability no other vendor has — a still face
speaking a given audio (creatify-aurora) — needs the Pro plan: both accounts are Creator and get
`402 paid_plan_required`, so it is recorded in `api_only`, not wired.

## Keys and accounts

`~/.config/elevenlabs/keys.txt` (0600), one `<key> <account> [label=<menubar name>] [reserve=N] [notes]` line each;
never print a key. Every key has every permission, so one order serves every kind: the line order. A spent quota, a
plan or key refusal (exit 4 class) or a voice the account lacks moves to the next line; any other failure stops.
A `reserve=N` account is skipped unless its balance is readable and above N — the same rule as the dictation pool
in transcriptions-gpt (`KeyPool`).

The file is the master. `share/elevenlabs_keys_sync.py` (run on every writing `llm-limits.sh` poll, inside `elevenlabs_balance.py --sync`) copies it over each
`accounts.mirrors` path — transcriptions-gpt `settings/elevenlabs_keys.txt` — so dictation spends the same keys in
the same order while reading only its own file. A key added by hand to a mirror alone stays there, at the end.

| Account | What | Order (2026-10-06) |
| --- | --- | --- |
| `trimmed` (label `alena`) | someone else's paid Creator account lent to the owner; `reserve=100000`: usable only while more than 100k credits are left (the key owner's hard floor) | 1 |
| `notcom`, `abel`, `rawilimo`, `locomthebest`, `egbor`, `tronjhon`, `jihan`, `egbogd`, `loiyehor` | the owner's free accounts, 10k credits a month each; a free account's output is non-commercial and needs attribution | 2-10, in this order |
| `full` (label `com`) | the owner's own paid Creator account | 11 |

A spent quota exits 3 (`ELEVENLABS_USAGE_LIMIT account=…`) after every line is tried; a key without the
needed permission, a plan refusal or an invalid key on the last line exits 4 (an owner's step in ElevenLabs → Developers → API keys).

## Kinds

| Kind | Endpoint | Call | Live result (2026-10-06) |
| --- | --- | --- | --- |
| `sfx` | `POST /v1/sound-generation` | `--dest <abs .mp3\|.wav> --prompt … [--duration 0.5-30] [--loop] [--influence 0-1] [--count 1-4]` | 1.5 s → 17 credits, ~5 s wall; wav is native 44.1 kHz **stereo** PCM; a 2 s `--loop` came back 2.25 s |
| `music` | `POST /v1/music/detailed` | `--dest <abs .mp3\|.wav> --prompt … [--length 3-600 s] [--instrumental] [--lyrics …] [--mode track\|loop\|ambience] [--model music_v1\|music_v2\|music_v2_5] [--seed n]` | exact length (10.00 s asked → 10.00 s); 10 s wav → 138 credits, 7 s wall; `<dest>.json` = composition plan (sections, styles, BPM), title, word timestamps |
| `music --for-video` | `POST /v1/music/video-to-music` | `--for-video <abs video>… [--prompt <description>] [--tag …]` | follows the cut's length: 5 s clip → 5.04 s, 69 credits |
| `stems` | `POST /v1/music/stem-separation` | `--in <abs audio> --dest-dir <abs> [--two]` | two stems (vocals, instrumental) or six (vocals, drums, bass, guitar, piano, other), files `<stem-of-in>.<stem>.mp3`: a 6 s track → 83 credits for two, 166 for six, ~5 s wall |
| `speech` | `POST /v1/text-to-speech/{voice}` | `--dest <abs .mp3\|.wav\|.opus> --text …\|--text-file … [--voice <name\|id>] [--model …] [--language ru] [--stability] [--speed] [--seed] [--timestamps]` | eleven_v3 39 chars → 18 credits, multilingual_v2 41 → 19, eleven_v4 43 → 5; Russian correct on all three; default eleven_v4 since 2026-10-07 (a blind listener preferred it to v3 in 10 of 11 valid pairs, at a quarter of the credits); `--timestamps` writes per-character timings to `<dest>.json` |
| `speech --line` | `POST /v1/text-to-dialogue` | `--line "<voice>: <text>"` repeated | two voices, eleven_v3 audio tags (`[laughs]`) performed; 40 chars → 22 credits |
| `speech --list-voices` | `GET /v2/voices` | — | 21 premade voices (Roger, Sarah, George, …), all multilingual |
| `revoice` | `POST /v1/speech-to-speech/{voice}` | `--in <abs audio> --dest … [--voice] [--denoise]` | keeps timing and intonation, swaps the voice: 2.77 s → 30 credits |
| `isolate` | `POST /v1/audio-isolation` | `--in <abs audio/video> --dest <abs .mp3\|.wav>` | speech out of rain noise: 6.92 s → 76 credits; inputs under **4.6 s** are refused (the script checks first) |
| `transcribe` | `POST /v1/speech-to-text` | `--in <abs>\|--url <YouTube/TikTok/http> --dest <abs .json\|.txt\|.srt> [--diarize] [--speakers n] [--language] [--keyterm …] [--no-verbatim] [--no-events]` | scribe_v2; two-speaker dialogue split right; 4 s → 1 credit; `.srt` forces diarization (the API refuses extra formats without it) |
| `align` | `POST /v1/forced-alignment` | `--in <abs audio> --text …\|--text-file … --dest <abs .json>` | exact word and character timings of a known text: 2.9 s → 1 credit — the timing source `listen` is not |
| `dub` | `POST /v1/dubbing` + poll | `--in <abs>\|--url … --to <lang> --dest <abs .mp4\|.mp3> [--from] [--speakers n] [--start s --end s] [--watermark] [--no-clone] [--drop-background]` | a 2.77 s Russian line → English with the cloned voice in 15 s, 125 credits; the job stays in the account's dubbing list (`dubbing-id=`) |
| `voice` | `POST /v1/text-to-voice/design` | `--description … --dest-dir <abs> [--text 100-1000 chars] [--model eleven_ttv_v3\|eleven_multilingual_ttv_v2]`; `--save <name> --generated-id <id> --description …` keeps one | three previews (`preview-N.mp3` + `previews.json` with each `generated_voice_id`); without `--text` the sample is ~40 s of English whatever the description says — pass a text in the target language (a 120-char Russian text → 111 credits, 10 s; the auto text ~350) |

Costs here are the `character-cost` / `x-character-count` response headers. Music, stems, voice design and
dubbing send none: the script prints `credits=unmetered`, and the subscription balance settles
about a minute later (the costs above for those were measured that way, one call at a time). The manifest's
`costs` holds the rates; name them when asking for a yes.

## Facts and traps

| Fact | Evidence |
| --- | --- |
| `pcm_44100` (wav) is allowed for sfx and music on Creator but refused for TTS (`output_format_not_allowed`, Pro tier); a speech `.wav` is decoded from mp3 192 kb/s | live 403 on eleven_v4 |
| Raw PCM channel count differs per endpoint (sfx and music stereo, TTS mono): `pcm_channels` in the manifest; reading stereo as mono doubles the duration | the first 2 s sfx wav read 4.5 s |
| The balance (`/v1/user/subscription`) lags the calls by up to a minute; header costs are immediate | 98 of 125 header credits visible right after the batch |
| A POST that times out is never resent: it may still be billed and delivered | design |
| Other models the account serves: eleven_v4 / eleven_v4_turbo (85 languages, 10k chars), eleven_v3_conversational, flash/turbo v2.5 (40k chars, low latency), eleven_english_sts_v2 | `GET /v1/models` |
| `api_only` lists what the API has and the scripts do not carry (voice cloning, pronunciation dictionaries, Studio/podcasts, agents, music inpainting and finetunes, realtime websockets, Flows image/video) | OpenAPI spec |

## Re-verify

Every run compares `GET /v1/models` (at most once a day, cached in `~/.config/elevenlabs/models-check.json`)
with the manifest's `served_models` and prints `model_caps=fresh|stale|unknown` (stale names `new=`, `newer=`
a generation past its kind's default, `gone=`; on stderr for dry runs and `--list-voices`).

`GET /v1/models` for the model list, the OpenAPI spec (`https://api.elevenlabs.io/openapi.json`) for
parameters and ranges; one `--dry-run` per kind prints the request without spending; one smallest live
call per changed kind; then bump `verified` in the manifest.
