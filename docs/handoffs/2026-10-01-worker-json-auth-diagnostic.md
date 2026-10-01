# Claude JSON authentication error reported as no output

Status: open

To: `share/doctor-ledger.json` `owners.workers` and the review-bench failure-vocabulary owner.

Purpose: `bin/worker-run` `supervise_claudeb` preserves the vendor result for the caller; the doctor should identify why the worker failed without discarding that evidence.

Run `claudeb-1790757454-79915-4251` (account com) exited 1. Its `err` is empty, but `out` contains a JSON result with `is_error: true`, `subtype: success`, and result `Failed to authenticate: OAuth session expired and could not be refreshed`. The extracted `result` contains the same message. It is not an empty-output run. The subtype alone cannot identify success.

`bin/llm-doctor` `classify_worker` reads result for wall detection but passes only stderr to `classify_failure_text` for the final failure. A fixture reproduces `failed / no output / no output · exit 1`. A second fixture shows that passing the real error text alone still returns `unclassified`: the shared auth vocabulary matches `session has expired`, not this wording. The initial probe expecting auth failed; this rules out an evidence-source-only fix.

Hand off the coordinated correction: consume the structured failed Claude result as diagnostic evidence, preserve stderr and existing kill/wall precedence, and update the auth wording in review-bench `share/rbench/panel.py` and its llm-legs copies together under invariant cq. Test the exact envelope, misleading success subtype, ordinary successful answers quoting errors, empty output, stderr errors, and existing wall/kill outcomes. Do not simply classify arbitrary successful result prose as a failure. Do not forward every result into stderr, retry OAuth automatically, or dismiss no-output failures wholesale.

This run authorizes no review-bench worktree; changing its shared vocabulary needs an owner handoff. No classifier or dismissal was changed. The narrower ledger row stays open. Root cause of the failed OAuth refresh is unconfirmed: the retained out/result/err contain no refresh response or reason beyond the message. No credential stores were opened and no refresh was attempted. Exit 1 and no kill marker rule out a recorded watchdog or memory-guard kill; the result rules out a missing vendor answer. Existing launcher output capture is doing its job and is not obsolete.
