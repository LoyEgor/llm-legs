# Guards: interpreter writes through a variable path, and git merge landings

Status: done 2026-10-04 — guards-growth-claude-agents-claudeb-worker-md, guards-growth-claude-agents-image-gen-md, guards-denied-claude-agents-image-gen-md, guards-growth-claude-setup-night-sweep-skill, guards-growth-claude-skills-media (§1 as proposed, §2 option b)

For «Harness Doctor» (`share/harness-ledger.json` `owner`). Written 2026-10-02 by night fixer run
harness-guards-20261002T093034Z-0c00. Both are gate-scope decisions, so the fixer changed no gate.

## 1. A path held in a variable walks past the write gate

Four growth events in one window share one shape: a Bash `python3 - <<'EOF'` heredoc that names a
guarded file as a whole string literal and writes it through a variable.

- `~/.claude/agents/claudeb-worker.md`, 2026-10-01T15:27:58Z, chat «Claude Sonnet 5.5 launch video»
  (7c93bbe2): `p='agents/claudeb-worker.md' … open(p,'w')`.
- `~/.claude/agents/image-gen.md` (deleted since, claude-setup 01f7357), the same chat.
- `claude-setup/skills-on-demand/night-sweep/SKILL.md`, 2026-10-02T01:06:15Z, chat «Updater doctor»
  (233cceb1), `p='skills-on-demand/night-sweep/SKILL.md'`.

`bin/instruction-write-gate.sh` and `share/instruction-files.sh` (`_instruction_interp_construct`)
leave a variable path out of scope on purpose, so only the tripwire sees these, and growth-ungated
reports them every time; a relay worker's refused MD-PROPOSAL applied this way reads
`growth-denied` (image-gen.md, 2026-10-02T10:34:40Z). Proposal: in an interpreter payload, a quoted literal that is WHOLLY a
guarded name, plus a write construct whose destination is a bare identifier (`open(p,'w')`,
`Path(p).write_text`, `p.write_text`, `writeFile(p`), reads as a write to that name. Its false
catch is the one the gate already accepts (an interpreter that reads a guarded file and writes
elsewhere): one denial, and the retry passes. Your call, because it widens what the gate denies.

## 2. `git merge` lands guarded bytes no gate sees

The night-sweep SKILL.md change was moved from main into the claude-setup `code-doctor` worktree
by patch (01:06:32Z) and came back by `git merge code-doctor` (fast-forward 8b7c744) at
2026-10-02T09:26:13Z, a second +268 B growth-ungated event. The changed-while-watcher-off record of
2026-10-01T12:51:14Z is the same shape: the `review-floor` merge (6413519, 12:40:33Z) landed +412 B
while the watcher was off. `instruction_git_landing` reads `git apply` and `git stash pop|apply`,
never merge, pull, rebase or cherry-pick. Proposal, your pick: (a) add merge-type landings to it,
read from `git diff --name-only HEAD MERGE_HEAD`-style ranges, so a landing gets a gate record
(span-pass inside the span, one denial outside it); or (b) keep merges out and treat a landing of
bytes already judged in a worktree as no new growth in the doctor. (b) loosens the judge.

Night 2026-10-04 adds a non-git landing (row `guards-growth-claude-skills-media`): chat «Google video
generation integration» (10896605) copied its claude-setup `media-media-run` worktree into main with
a scratchpad `python3 land.py … --apply` at 2026-10-03T17:33:37Z, landing `skills/media/SKILL.md`
+8080 B. Egor had granted those bytes in the worktree (bloat `granted`, 15:26:50Z), but a gate record
covers only its own path within 900 s. (a) cannot see a copy script; only (b) covers it.

