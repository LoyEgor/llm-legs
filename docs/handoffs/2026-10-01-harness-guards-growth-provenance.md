# Guard growth provenance: vendor syncs into ~/.claude

Status: open

For «Harness Doctor» (`share/harness-ledger.json` `owner`). Written by run
harness-guards-20261001T020645Z-3cf8, cut to its open part by harness-guards-20261003T042540Z-6416:
the film-lab, llm-legs docs, hyperframes, media-use and tripwire-rejournal sections are settled
(rows `fixed`), image-gen moved to `2026-10-02-harness-guards-gate-scope.md`.

## Settled: plugins/marketplaces

The six math-proof rows and `growth-ungated:…/security-guidance/README.md` (2026-10-02T21:27:54Z,
+639 B) were no vendor weather: llm-legs 2267da0 pruned `plugins/marketplaces` from the list, but the
Hammerspoon watcher keeps every row of its persisted `watcher/snapshot.tsv` watched, and the live one
still held 240 marketplace rows. Fixed in `hammerspoon/instruction-watch.lua` (the loaded snapshot
drops rows under `INSTRUCTION_HOME_UNLOADED_ERE`); the rows read `fixed-pending`.

## Open: org skill and plugin sync

`guards-synced-skills-vendor-sync` (`~/.claude/skills/synced/…`) and, since 2026-10-02T09:31:02Z,
`guards-synced-plugins-vendor-sync` (`~/.claude/plugins/synced/<org>_<account>/cowork-plugin-management/skills/…`,
+9698/+13350 B, a `~g2` staging copy deleted at 10:45:58Z): Claude Code writes them beside
`manifest.json` and `.last-complete-round`, no tool call, so no gate can see them. Latest skills
sync: pptx SKILL.md into all three dirs at 2026-10-02T22:14-22:22Z. Proposal unchanged from
`2026-09-30-harness-guards-vendor-sync-and-probe-sids.md` §1, now for both trees: (a) one exact
`weather` row per sync, or (b) growth-ungated leaves out `skills/synced/` and `plugins/synced/`.
(b) loosens the judge, so the fixers only narrowed `open` rows.
