# Loose objects in a repository nobody commits to

Status: open

To: the claude-setup review-journal owner. From: night fixers harness-growth (2026-10-02, 2026-10-03).
Ledger row `loose-objects-logo-vectorizer-bench` (its note holds the evidence).

`hash-object -w` snapshot blobs of untracked files are unreachable. Git packs them only on a manual
gc. `gc --auto` repacks reachable objects only and leaves unreachable ones younger than
`gc.pruneExpire` loose with a "too many unreachable loose objects" warning, which under autoDetach
becomes a `gc.log` that blocks auto gc for a day. The 2026-10-02 proposal (detached `gc --auto`) is
withdrawn for that reason.

llm-legs `bin/worker-run` `pack_loose_objects` (2026-10-03) now runs after every worker-run
after-snapshot:

    at=$(git -C "$top" config --get gc.auto) || at=6700
    nice -n 10 git -C "$top" -c maintenance.loose-objects.auto="$at" maintenance run --auto \
      --task=loose-objects --quiet && git -C "$top" prune-packed --quiet    # backgrounded

Proposal: `hooks/lib/review-journal.sh` runs the same command, backgrounded, after an
`rj_hash_paths` call that wrote blobs. It packs a repository where chats work and no worker runs.
Below the threshold the command only counts loose objects.

Done when `loose_objects` stays under 6 700 for a repository whose chats produce untracked outputs
and that sees no worker run.
