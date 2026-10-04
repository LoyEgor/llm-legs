# Worker grants still omitted by cross-repository briefs

Status: open (W3 and W5 fixed-pending in llm-legs; the relay half below waits for claude-setup)

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
