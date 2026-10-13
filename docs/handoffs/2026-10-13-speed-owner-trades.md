# Hand-off: Speed owner trades nobody settled

Status: open
To: next night, a harness fixer

The Speed design proposed three owner trades on 2026-10-02, priced on the 09-29..10-02 window, and none was
settled. Check in the code and journals whether each still stands; put each that does to Egor as a trade
(cost, loss, recommendation), close the rest.

1. Settings steps: drop Read from `statusline-workdir-hook`'s PostToolUse matcher; `claude mcp remove codex`
   in the three profiles. Gain ≈ 0.5 OM/d, loss none measured. The hook-dispatcher registration proposed
   with them is Egor's declined trade (2026-10-05, `share/harness-ledger.json`).
2. A foreground-poll deny in owner chats only (relays and headless exempt). Gain ≈ 1–2 OM/d of overshoot,
   loss a 5–10 s re-plan per false denial; only after a 14-day transcript replay shows zero denials of
   non-poll commands.
3. Night: split the debt round and commit/land per repository (changes `docs/night-run.md`'s one-round
   rule), keeping 5 slots. Gain ≈ 1 OM/d on nights inside his day, loss ≈ 0; 8 slots instead nets ≈ 0.
