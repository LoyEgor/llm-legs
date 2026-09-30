# Hand-off: night vendor-release workers run without the `open=all` chat pin

For the owner of the night sweep (`docs/night-run.md`, claude-setup `skills-on-demand/night-sweep`)
and `bin/vendor-fingerprint request --night`. Written 2026-09-30 by the night vendor worker for
event claude-20260926T203455Z; nothing here was changed by it.

## What happened

`docs/vendor-release.md` §1 says every vendor is open for an integration chat (chat pin `open=all`),
and §6 keeps the day procedure at night except for the listed points. A day chat gets the pin from
`share/chat-open.sh` at launch. A night worker is dispatched by the sweep as a headless relay run and
gets no pin: this run's session had no file under `~/.cache/claude-chat-pins/`.

Effect on this run:

- Step 4 (blind cross-check on another vendor) could not start: codex and grok are `off for workers`
  (`worker-limit-gate.sh` refused codex-worker), every gemini account was walled.
- `bin/chat-pin all` from the worker refused: "no fresh grant for 'all' … it opens when he says
  «workers on all»". That refusal is correct for a chat; the gap is that the night launch never
  writes the pin the procedure promises.
- The `--role research` relay path is also closed at night: `worker-run` gives the research role to
  the light-research Agent, and Light is off; the research leg ran as a plain claudeb worker with
  `--web-search` instead.

## The ask

Make a night vendor worker start with the same `open=all` the day chat gets (the dispatcher knows the
worker's session only after launch, so either `worker-run` accepts a pin for the run it starts, or the
brief carries a machine-read grant), or change §6 to say which of steps 4 and 10 are `blocked` at night
by design. Until then every night vendor event decides its cross-check `blocked`.
