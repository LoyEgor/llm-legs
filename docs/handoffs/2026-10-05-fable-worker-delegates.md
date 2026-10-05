# Hand-off: Fable workers delegate the brief they were chosen for

Status: open

For the chat «Harness Doctor». Written 2026-10-05 by night fixer
harness-stop-hooks-20261005T061339Z-2a70 (ledger row `hook-held-backstop-nested-run`).

The one `held` line in the stop journal (2026-10-04T07:02:23Z, chat 2ddedf36): the Fable judging
workers claudeb-1791096545-79782-35c7 and -75758-5171 (locomthebest) handed their judging briefs to
two Opus runs on com through their own relays. A nested launch names the root chat as `launcher`
(`bin/worker-run` start_run) while its relay's tag sits in the worker's cache, so
`bin/worker-run-backstop.sh` rightly held a live run the root showed no row for. The chat attached
both, saw the com misroute and killed them (exit 143). The backstop is not the defect.

The cause: the global «On Fable act as a pure orchestrator» reaches headless workers. Of the three
Fable parents of nested runs this week two delegated (also claudeb-1791036587-51829-244d, a
read-only research brief), each swapping Fable for Opus, which only Egor chooses.

Decide: scope that rule to chats (an MD-PROPOSAL for the global CLAUDE.md), or have `worker-run`
refuse `start` inside a Fable worker unless its brief allows delegation. Then the row closes; no
not-a-bug dismissal, since a hold remains the evidence of such a misroute.
