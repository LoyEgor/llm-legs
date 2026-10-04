# Worker grants still omitted by cross-repository briefs

Status: done 2026-10-04 (ledger W7 fixed-pending)

To: `share/doctor-ledger.json` `owners.workers`, with the claude-setup relay owner.

Purpose: `bin/worker-run` `brief_add_dirs` and `snapshot_other_families` grant and baseline the
repositories a run may write; `share/worker-policy.md` states that contract.

Fixed in llm-legs `bin/worker-run` (ledger W3, W5; the contract is `share/worker-policy.md`).
Night and fixer briefs name main checkouts in order to forbid writes there, so worker-run still
never infers a main-checkout grant from prose.

Open (ledger W7) for the claude-setup relay owner (`agents/*-worker.md`): `--workdir <dir>` is the relay's guess
from the brief; a brief that works in a main checkout should carry it as the workdir or as `ADD-DIR:`.
The relays' "pass `--resume` for a RESUME brief" step is now redundant (worker-run reads the line)
and can go. A worktree created after launch stays ungranted.

## Settled 2026-10-04 («LLM Doctor меню refactoring», night sweep 20261004T003925Z-4646)

- claude-setup `agents/{claudeb,codex,gemini,grok,light}-worker.md` (branch `fix/llm-doctor-handoffs-20261004`): no relay passes `--resume`
  any more (worker-run reads a `RESUME <id>:` first line and the `ADD-DIR:` lines itself), and `--workdir` is
  the directory the brief works in, its worktree or the checkout it names to write. `tests/test_consistency.sh`
  pins both; red on main's agents.
- claude-setup `hooks/worker-edit-guard.sh`: a worker's shell write that crosses a symlink into another checkout is
  denied unless an `ADD-DIR:` grant covers it (see `2026-10-03-path-shape-tilde.md` item 2).
- A worktree created after launch stays ungranted by design: the brief names it as `ADD-DIR:` up front, or
  the run edits only its own worktree.
