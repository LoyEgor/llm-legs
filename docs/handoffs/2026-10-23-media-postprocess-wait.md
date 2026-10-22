# Hand-off: Flow 1080p post-processing is a media wait the Speed doctor does not split out

Status: open (Egor's go, 2026-10-23)
To: «Updater doctor», the Speed doctor's builder (`docs/speed-doctor-design.md`). From: «Google video generation
integration», which built the post-processing (llm-legs 7278ed28, `docs/video-jitter.md`).

## The wait

- Every Flow 1080p fetch (`gemini-video --resolution 1080p`, `gemini-web fetch … --resolution 1080p`) runs
  `video-jitter fix` after the account lock is released, inside the same process: steady and halo clamp, one decode,
  one encode. An 8 s clip on a quiet machine: 56 s steady, 75-94 s trembling; 2-4.5 min each on a loaded machine.
  A live re-fetch on 2026-10-22 23:41: 1:51 end to end, 94 s of it the fix.
- `media-run image|video` runs `video-jitter door` on every input image before the vendor script: 2-7 s an image.
- Both sit inside the `Bash:media` span, so Speed already counts them as media. Nothing splits them out: C9's phases
  (queue, prep, launch, render, download, recovery) have no post-process phase, and the C9 lever is still `unmeasured`.

## Sources

- The fix: `~/.gemini-web/jobs.jsonl` rows with `"event": "steady"`. Each row has `ts` (its end), `account`,
  `media_id`, `dest`, `secs`, `steadied`, `cleaned`, `clamped`, `colour_shift`, `sharpness` and `bytes`.
- The door: no journal yet, only its stderr lines in media-run (`swapped=`). Add one where C9 reads, in the format
  C9 wants.

## Ask

Make post-processing a C9 phase (fix and door), measured even when normal, and rank its levers there. Half of the
fix is dense optical flow.

Egor's constraint: never lose picture quality. A speed change must prove its output equivalent, either bytes
identical or `colour_shift`/`sharpness`/`clamped` unchanged on the same pairs. It never drops the clean or the steady.
