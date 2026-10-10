# Guards: a python write whose guarded name arrives as a function argument

Status: settled 20261010T031219Z-4c4e: the write gate reads a script the same command writes by heredoc and runs by path, and judges a join handed the guarded name by a call; six new denies red on the old gate, row fixed-pending

Written 2026-10-09 by night fixer harness-guards-20261009T024729Z-7a2d. Row
`guards-ungated-llm-legs-claude-md-param-path`. A gate-scope decision, so no gate was changed. Same
class as the settled 2026-10-05 script-file handoff (llm-legs@3a3531d7, in git history).

## What happened

`llm-legs/CLAUDE.md` +145 B landed at 2026-10-08T18:55:46Z, when `feat/run-all-chat-gate` was
fast-forwarded (847c18ad). The bytes were written at 18:47:08Z in that worktree by chat «Updater
doctor». It used one Bash call: `cat > scratchpad/gate.py <<'PY' … PY; python3 gate.py $W`. The
script holds `def sub(path, …): p = w / path; p.write_text(…)` with `w = pathlib.Path(sys.argv[1])`,
and calls `sub("CLAUDE.md", …)`. There is no gate record. The gate does judge the heredoc body,
because `flat` keeps it. But no shape binds `p`: its value is a non-literal joined to a function
parameter. Replayed through `bin/instruction-write-gate.sh` in the test harness, the original
command passes. A literal `open('<repo>/CLAUDE.md','a')` in the same heredoc is denied.

## Proposal

Widening the gate is your call. Proposal: in one interpreter invocation, a quoted guarded name
(`INSTRUCTION_GUARDED_BASENAMES`, or a guarded path) plus a write construct whose target no shape
resolves (a bare identifier bound to no literal) reads as a write to that name. False catch: a
program that reads CLAUDE.md and writes another computed path. A chat pays one denial and the retry
passes; a relay worker is refused outright. Without the change, every landing of such a write fires
`growth-ungated`, once per landed file (twice in 3 days: this one and
`guards-ungated-claude-md-pathlib-assign`). Recommendation: widen, as on 2026-10-05.

## Leftovers in the live home (not this run's to delete)

At 2026-10-08T05:44:04Z a worker copied `tests/test_instruction_gate_bypasses.sh` to
`/tmp/iw-debug.sh` and ran it. The harness did not load, so HOME stayed real. The run left
`~/.claude/rules/r.md` (`x`, and `~/.claude/rules/` loads in every session),
`~/.claude/skills-on-demand/s/s.md` and `claude-setup/hooks/policy.md` (untracked in the main
checkout, through the `~/.claude/hooks` symlink). Delete all three. The cause is fixed: every
harness-sourcing suite now does `|| exit 1`, and `test_consistency` keeps it that way.
