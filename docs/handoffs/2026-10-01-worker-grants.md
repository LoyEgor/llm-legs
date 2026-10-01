# Worker grants still omitted by cross-repository briefs

Status: open

To: `share/doctor-ledger.json` `owners.workers`, with the claude-setup relay owner and Updater doctor.

Purpose: `bin/worker-run` `brief_add_dirs` and `snapshot_other_families` grant and baseline explicitly authorized repositories; `share/worker-policy.md:46` states that contract.

W3 remains open. The six launch-packet regressions are not evidence of a broken ADD-DIR parser:

- `claudeb-1790773594-44689-796d`, `claudeb-1790766135-4267-0d45`, `claudeb-1790745670-50144-1f58`, and `claudeb-1790740627-9087-25ea` wrote claude-setup files named in prose with empty `meta.json.add_dirs`.
- `claudeb-1790747191-62135-561d` resumed into review-bench edits with no grant.
- `claudeb-1790740653-41624-20de` did grant its review-bench worktree. Its remaining escape names llm-legs main-checkout files: the brief explicitly ordered a day-mode pour to main, but granted no main directory. The granted review-bench paths are already filtered by the doctor. This is a scope/accounting mismatch, not a lost sibling grant.

The fresh worktree doctor also counted `claudeb-1790736097-38111-56f7`, a resume with no grant and a review-bench write. Do not dismiss the entire escaped class: W3 also matches actual unauthorized writes.

Evidence: each run's `brief`, `meta.json`, `files-note`, and `result` under `~/.cache/claude-worker-runs`. Five fixture assertions passed: three cover fresh/resume explicit headers and prose exclusion; two reproduce the separate JSON diagnostic gap. Header grants are functioning. The nearby parser safeguard remains necessary: prose often names repositories only to read. No obsolete workaround was removed.

Current `bin/doctor-fix:480` and `bin/vendor-fingerprint:456` already emit sibling ADD-DIR headers. The current claude-setup night-sweep resume step already says to preserve them. Do not reimplement those fixes. The claude-setup `agents/claudeb-worker.md` launch contract does not mention extra-directory flags; investigate the orchestrator/relay boundary for hand-written and resume briefs and preserve explicit grants there. A mechanical check should use structured scope, never infer write permission from arbitrary paths in prose. For day-mode pours, represent the explicitly authorized destination in the launch scope or perform the pour outside the worker.

Acceptance: a fresh and resumed cross-repository brief carries the intended grant into metadata and snapshots; a read-only prose reference grants nothing; a genuinely ungranted main-checkout write remains escaped.

No claude-setup ADD-DIR worktree is authorized for this run, so changes there are handed off. Historical launcher revisions cannot be established from the run metadata (existing blind spot B3); timestamps alone do not prove which code ran. Context-nudge scratch files also appear in files-note, but the reported incidents name repository files, so scratch filtering does not explain W3.
