# Hand-off: the log audit off the night's critical path

Status: open
To: next night, a harness fixer

Row `log_audit:night-run-serial-waits`. A pilot night's prep is serial (`bin/night-run` `PILOT_RULES`, docs/night-run.md
step 2), and `log-audit run --night R` is its longest step: `wall_s` 1029-2417 s over the last four nights
(`~/.cache/doctors/log-audit/runs.jsonl`), 1986 s at night 1c68, while no goal runs. Only `harness-doctor --quiet` and
the doctor fixers carry launches read its findings; the goals `nr carry R` records do not. Lever: start it as a
background Bash at prep's start, run the goals meanwhile, and refresh the harness doctor once it ends, before carry
reaches the doctor fixers; `tests/test_night_run.sh` pins the prep text. Also from that reading, unmeasured: the report
took ~18 min after the night ended and Close waited ~31 min on serial suites; time both before changing either.

Done when a night's first goal starts within prep's other steps, as its jobs' launch times show.
