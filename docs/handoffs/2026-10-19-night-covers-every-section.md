# A full night covers every section: no pilot skips that wait for Egor's buttons

Status: open. To: the night owner (`bin/night-run`, `docs/directions`). From: «Workers и review bench унификация отображения», 2026-10-19.

## What Egor said (2026-10-19)
He did not know a night skips anything: «когда запускаю полную ночь, я подразумеваю, что она полная, то есть по всем параметрам». He wants the night to go through everything on its own: «сама ночь не должна зависеть от моих решений, она должна сама пройти и сама все решить». He asked for an explanation of which sections a night runs, which it skips and why, and of every button he must press.

## Facts
- Since 2026-10-15, every night has been a pilot (6a5f1c46, ff4f0ec9). `PILOT=${NIGHT_RUN_PILOT-breakages lost-time system spend legacy}` (`bin/night-run:31`), and an empty value is the only full night.
- `PILOT_RULES` (`:34`) forbids `doctor-fix launch`, `vendor-fingerprint`, leftovers, the `debt` job and the debt pass.
- So:
  - Vendor release events wait for the Updater's Fix button. `gemini-20261014T201301Z` (agy 1.3.4→1.4.2) has been open 5 days with `run: null`.
  - Every doctor's Fix item waits for its menu button.
  - Leftover branches and review debt never run at night.
- The pilot came from Egor's 2026-10-15 strategy: prove a result at the spend it needs, then scale. That strategy stands. What he rejects is a night that silently leaves sections to buttons he does not know about.

## Wanted
1. Settle with Egor how one night covers every section within the 10-15 strategy: what runs, at what spend, and what proves it.
2. At minimum, every night takes vendor events whose diff is only catalog, divergence or plans. These are a new model, a removed model, or an account's plan change, which the Gemini 4 Argon work in this chat makes detectable per account. Today's Argon case: notcom moved from Plus to Pro, and nothing noticed it.
3. Give Egor the short list he asked for: which sections a night runs and why, and which buttons remain and why each needs him. If none needs him, there are none.
