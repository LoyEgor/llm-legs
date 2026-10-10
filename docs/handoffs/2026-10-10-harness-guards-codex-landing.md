# Guards: a Codex worker's instruction write lands through a chat's merge

Status: open — To: «Harness Doctor» (`share/harness-ledger.json` `owner`), carried by the next night

Rows `guards-growth-claude-setup-night-sweep-skill` and `guards-ungated-docs-worktree-shell-write`,
written 2026-10-10 by night fixer harness-guards-20261010T031900Z-5315. A gate-scope decision.

Event 2026-10-09T19:29:23Z: `review-tiers.md` +247, `worktrees.md` +222, night-sweep `SKILL.md`
+396 B, the `git merge --ff-only feat/landing-overlap` (66cbc49) by chat «Чистка night run
20261009T023738Z-817e». Codex worker codex-1791571148-71493-0a04 (borodatch) wrote the bytes at
18:41:46Z in the claude-setup worktree, in a python heredoc `r=Path('<worktree>');
p=r/'global/docs/review-tiers.md'; p.write_text(s)`. Its brief ordered the edits against its MD-GUARD.
No Codex profile wires a hook (codex-cli 0.162.1 lists `hooks` stable), and the 2026-10-04 landing
credit (option b) needs a gate pass in the worktree. So every non-Claude worker's instruction edit
reads `growth-ungated` at landing. The Claude gate's miss of that heredoc shape is fixed (literal joins).
Your pick:
(a) the write gate judges merge, rebase, cherry-pick and pull landings in a guarded checkout: one
choke point for every vendor and copy script, and the landing chat pays the denial;
(c) wire `bin/instruction-write-gate.sh` as a PreToolUse hook into the codexb, geminib and grokb
homes, after proving it fires for Codex code-mode `exec` and `apply_patch`.
Recommendation: (a).
