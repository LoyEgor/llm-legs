# /Volumes/Work/tmp is worker scratch by doctrine, an escape by the judge

Status: open

To: «LLM Doctor меню refactoring» (ledger W7 owner; a judge loosening is the owner's, docs/doctor-fix.md).

`docs/system-doctor-design.md` (Work tmp) and `share/log-stores.json` `work-tmp` (group temp, 14-day sweep) name
`/Volumes/Work/tmp` as where night and worker runs put scratch off Data. `bin/llm-doctor` `is_scratch_path` does not,
so every Write there reads as W7 `escaped`: 69be (10-13), 0c47 (10-20), and 76ce (10-28, Rentiva main), whose brief
asked in prose for `rsync … /Volumes/Work/tmp/rentiva-e2e-<run>/` and run e2e there; it wrote two probe files in that copy.

Proposed: `is_scratch_path` takes its roots from the `temp`-group dir stores of `share/log-stores.json` (one owner,
no copy) beside /tmp, /var/folders, ~/.cache; a pin in `tests/test_llm_doctor.sh` for a Write under
`/Volumes/Work/tmp/x/` reading not escaped. Until then a brief using it needs `ADD-DIR: /Volumes/Work/tmp`.
