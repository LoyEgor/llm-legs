# Hand-off: two Guards causes that are not bugs of ours, each proposed for dismissal

Status: open

For «Harness Doctor» (`share/harness-ledger.json` `owner`). Written 2026-09-30 by night fixer run
harness-guards-20260930T001642Z-7d95. Both are judge decisions, so the fixer loosened nothing and
only narrowed an `open` row to each cause.

## 1. `guards-synced-skills-vendor-sync`: growth-ungated on `~/.claude/skills/synced/…`

- What happened: on 2026-09-29 at 20:14, 20:20 and 20:33Z, Claude Code synced a newly published
  org skill, `google-workspace` (`SKILL.md` plus `references/{charts,docs,sheets,slides}.md`,
  13-47 kB each), into all three `skills/synced/<org>_<account>/` dirs. That gave 15 problem ids.
  The dir holds `manifest.json` and `.last-complete-round`, which the harness writes. It is
  gitignored in claude-setup (`.gitignore:13`). No tool call writes it, so no gate can ever see it.
- The rule does what it says: the growth is real, and it is always-on skill-listing content.
  It misses its goal, though, which is to catch a model's write that got past a gate. Nothing
  there can be closed.
- Proposal, your pick: (a) one `weather` row per exact ident as each sync arrives, which the
  ledger guards force, since a dismissal cannot be a pattern; or (b) the growth-ungated rule
  leaves out paths under `skills/synced/`, the same way `FIXTURE_PATH_RE` leaves out fixtures,
  and the cost of vendor skills goes wherever the bloat or token pricing lives. (b) loosens the
  judge, which is why the fixer did not apply it.

## 2. `guards-baseline-missing-probe-sids`: baseline-missing on `tripwire`

- What happened: every `baseline-missing` record since 2026-09-28T23:00Z names a sid that no
  chat owns: `perf-big-93348`, `perf-big-8746`, `perf-lvb` and `hlprof-a` (2026-09-29T15:05Z).
  Hook latency profiling ran `instruction-watch.sh check` with made-up session ids against the
  live `~/.cache/claude-instruction-watch` instead of an `INSTRUCTION_WATCH_STATE` fixture.
  No committed code produces those ids (searched llm-legs and claude-setup at HEAD and in all
  history). The last real one was `56cfc1dd` on 2026-09-28T19:23Z.
- Proposal: (a) count a `baseline-missing` record only when its sid has a transcript. That
  narrows the judge, so it is your call. Or (b) leave the row open and treat such records as
  operator noise. Either way, whoever profiles hooks should point `INSTRUCTION_WATCH_STATE` at a
  scratch dir. That habit belongs in the profiling tool, if one gets committed.
