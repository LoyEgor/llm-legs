# Image triage, 2026-10-05..09

Status: settled 20261012T005404Z-e2f7: I22 I47 I48 I51 not-a-bug, bounded by `until`; rc 2 stays `bad command` (I8 and I57 were real contract bugs only rc-2 legs showed); I54 kept as is, a final beep miss reads weather (a ±1 tolerance on 2-4 beeps passes blind guesses); I3 I4 I5 I16 I18 I19 I28 I55 I56 retired as weather, `until` at their last leg, so a recurrence reads new
To: «LLM Doctor меню refactoring»; I54 «Google video generation integration»

- Not-a-bug with an `until` like I41: I48, I51 (callers' argv, landing probes, refused before
  spend), I22 (a worker's mutation broke the shared bin/gemini-image), I47 (a caller's xtrace).
- rc 2 (refused before spend) reads `bad command` · ours: `off` like a prelaunch MODEL_REFUSED?
- I54: exactly n beeps sent; Flash beeps off. Pro: 2 final fails in 110 legs, miscounts lean +1.
  Accept ~2 % false rejects, or change the canary?
- I3 I4 I5 I16 I18 I19 I28 I55 I56: one-offs, cause unknown, silent since; each night re-reads
  them for nothing. Retire (a recurrence reads new, with its capture)?
