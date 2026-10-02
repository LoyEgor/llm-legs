# Loose objects in a repository nobody commits to

Status: open

To: Harness Doctor (owner of `share/harness-ledger.json`) and the claude-setup review-journal owner.
From: night fixer harness-growth-20261002T093034Z-140d. Ledger row `loose-objects-logo-vectorizer-bench`.

## Finding

`loose_objects:loose-git-objects-logo-vectorizer-bench` read 14 137 at launch (limit 13 400) and
16 075 at 13:08Z on 2026-10-02 (`git count-objects -v`: 1.2 GB loose, `prune-packable` 5 839).

- Writer: every loose object written since the 2026-09-29 cruft pack is a blob: bench outputs
  (PNG, SVG, JSON, logs) of the untracked working tree. Per local day: 1 230 (09-30), 3 037 (10-01),
  11 769 (10-02 by 13:08Z, 9 296 of them 12:52-12:56Z). That burst lines up with the live chats
  whose review-journal `.repos` name the repository (touched at 09:56Z and 13:07Z). The
  claude-setup `hooks/lib/review-journal.sh` `rj_hash_paths` runs `git hash-object -w` on dirty
  paths on every tool call. `-w` is load-bearing there (the comment above `rj_hash_paths`).
- No worker run used this repository after 09-30 (`~/.cache/claude-worker-runs/*/meta.json`
  `workdir`), so llm-legs `bin/worker-run` `snapshot_workdir` is not today's writer. It writes
  the same way (`hash-object -w`) wherever workers run.
- Why nothing packs them: git runs `gc --auto` only after commit, merge, rebase, am, fetch and
  receive. `hash-object` never triggers it. This repository has one commit, the initial one (its
  reflog has one entry), so auto gc never ran. `objects/17` holds 65 files, about 16 600 by git's
  estimate, well over `gc.auto` 6 700, so one `git gc --auto` would fire now. The 09-29 cruft pack
  (`pack-0eae…`, with `.mtimes`) was a manual one-off.

Ruled out: a `gc.log` blocking auto gc (none), `gc.auto=0` (unset), stashes or worktrees
(none), night-run base snapshots (this is not a sweep repository and has no `refs/night/*`).

## Proposal (claude-setup; this night run had no worktree there)

After a snapshot that wrote blobs, start `git -C <top> gc --auto --quiet` detached and niced. Git
does the same after a commit. Under the threshold it only reads `objects/17`. Over it, git 2.49
packs unreachable objects into a cruft pack (`gc.cruftPacks` default) and prunes nothing younger
than `gc.pruneExpire` (2 weeks), so the journal still reads back the blobs it wrote. A
repository whose `gc.pid` is held skips the run on its own. Put it in one shared place that both
writers call: review-journal and llm-legs `worker-run` `workdir_dirty_shas`. The handoff
`2026-09-28-harness-performance-fix.md` item 4 (writing fewer blobs) still stands. This proposal
covers the objects that must be written.

Done when `loose_objects` for logo-vectorizer-bench stays under 6 700 over a working day with a
chat producing bench outputs.
