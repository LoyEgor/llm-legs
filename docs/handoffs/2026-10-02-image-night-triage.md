# Image failure triage, 2026-10-02

Status: open

To: LLM doctor owner and image block owner (share/doctor-ledger.json owner/owners.image).

Scope: night run llm-image-20261002T093025Z-0782, six image problems and quiet rows I1, I3-I6. Rows I8-I18 split
every incident of the launch window into one cause each; no judge change (no limit, `match` widening or
dismissal was written).

## Fixed on the branch

- I8 (bad command): 78 of 83 rc=2 legs were `<wrapper> --help` probes by image-gen agents and video chats (traced
  through Claude transcripts by time). `image_leg_help` in share/image-leg.sh makes `-h|--help` print usage on
  stdout, exit 0 and record no leg, in all eight wrappers.
- I6 (silent SFX): the take kept at 11:19Z was not silent (-40 LUFS untrimmed); the trim left 0.17 s and loudnorm's
  400 ms gate read -inf. bin/gemini-sfx pads the trimmed sound to 0.4 s before measuring.
- I12, I14 (Flow Music no-track and stalled upload): recorded as fixed by ffca51e (Google video generation
  integration), which landed after these development-time incidents; no gemini-music leg has run since.

## Proposed dismissals (owner's call)

- I9 weather: Flow's PUBLIC_ERROR_AUDIO_FILTERED on varied prompts, every take refused.
- I11 weather: the Gemini app's own music-tool errors, shown verbatim.
- I15 weather: Flow Music refuses reference audio with vocals in this region.
- I17 weather: agy's model answered without opening the media; gemini-listen refused it as designed. Its word is
  `unclassified` because IMAGE_REASONS has no pattern for it — a judge change, yours.
- I10 not-a-bug: one development-time "no title field" on com; the same locator filled 22 later titles.
- I13 not-a-bug: account lock waits of 900 s under caller fan-out and the owner's login window holding a profile.
- I1: its two non-probe refusals are callers' argument errors refused before spend.

## Open, cause unknown

- I16: one Flow frame upload (egbogd, 16:48Z) left no Uploading row or toast; upload() unchanged and served every
  other upload that day. Needs a capture of the next one.
- I18: the gemini-music engine died by SIGTERM (exit 143) with no record of the sender (blind spot
  image-engine-signal-sender).
- I3, I4, I5: no recurrence in the window; notes updated.
