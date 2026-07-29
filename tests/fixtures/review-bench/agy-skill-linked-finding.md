I will read the `code-review` skill documentation to understand the requirements and steps for performing a code review.
I will now read the `code-review-commons` skill instructions to ensure I adhere to the common guidelines, persona, and critical constraints for code review.
I will run the git diff command to retrieve the changes in the current branch relative to origin/HEAD, using the user's workspace directory.
I will run the git diff command again and output it to a file in the scratch directory so that I can view the entire contents without truncation.
I will view the first 800 lines of the saved diff.patch file to see all the changes.
I will search for `review_progress_document` in `bin/review-bench` to check all its usage sites and ensure they are all updated correctly.
I will view the `bin/review-bench` file around lines 475-505 and 3075-3105 to understand the surrounding context.
I will view lines 3070 to 3105 in `bin/review-bench` to check the context of `cmd_run`.
I will view the `bin/statusline-ports-probe.sh` file to thoroughly review its changes in their context.
I will view `bin/statusline.sh` around lines 1360-1435 to fully understand the context of the progress reporting logic.
I will run the tests to verify if the changes are correct and everything passes successfully.
I will check the git status and log to see the state of the repository.
I will run the tests individually to see which ones pass and which fail.
I will wait for the test_review_bench.sh execution to finish.
I will run the `test_statusline_hooks.sh` script to verify the statusline hook changes.
I will wait for the test_statusline_hooks.sh execution to finish.
I will search for the string `gemini-worker.md` in the `tests/test_consistency.sh` file to see why that assertion exists and why it failed.
I will view lines 160 to 195 of `tests/test_consistency.sh` to check the context of this test.
I will search for the definition of `active_top` in `bin/statusline.sh` to see if it can contain a trailing slash.
I will view the `bin/statusline.sh` file around lines 395-415 to see how `REPO_TOP` and `project_top` are initialized.
I will search for `project_top=` and `REPO_TOP=` in `bin/statusline.sh` to see where they are resolved.
I will run a quick check to see if `read` strips the trailing newline when `IFS` is set to a custom delimiter.
# Change summary: Propagate review run panel variants (like `--max`) to the statusline, and claim orphaned dev servers by their working directory.

## File: [statusline-ports-probe.sh](file:///private/var/folders/hh/q3xt7hzn7yvd37f9nrccw7ww0000gn/T/review-bench-seal-wimpcyj6/bin/statusline-ports-probe.sh)
### [L66](file:///private/var/folders/hh/q3xt7hzn7yvd37f9nrccw7ww0000gn/T/review-bench-seal-wimpcyj6/bin/statusline-ports-probe.sh#L66): [MEDIUM] Fallible PID parsing for numeric command names.

When parsing the `lsof` output to collect listener PIDs, searching for the first purely numeric column can mistakenly extract the command name as the PID if the command name itself consists entirely of digits (e.g., a binary or script named `1234`). Since the PID is guaranteed to be in the second column of the default `lsof` output, extracting column two directly is more robust and simplifies the logic.

Suggested change:
```
listener_pids=$(printf '%s\n' "$lsof_out" | awk '
  $0 == "" || /^COMMAND/ { next }
-  { for (j=1;j<=NF;j++) if ($j ~ /^[0-9]+$/) { print $j; break } }' | sort -u | tr '\n' ',')
+  { print $2 }' | sort -u | tr '\n' ',')
listener_pids=${listener_pids%,}
```
