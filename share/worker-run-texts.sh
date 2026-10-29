# worker-run, the texts every launched brief carries (house rules, fences, the MD guard); sourced by
# bin/worker-run in place, so an edit here runs its own suites rather than every suite of worker-run (Egor
# 2026-10-23, 2026-10-28).

md_guard_text() {
  local files='any markdown file (CLAUDE.md, SKILL.md, docs, READMEs, memory) / anything under ~/.claude, even when one of them goes stale from your change' rule
  rule=$(. "$SCRIPT_DIRECTORY/../share/instruction-files.sh" 2>/dev/null && instruction_relay_refusal "$files") ||
    rule="Do not write $files; put the exact proposed text under MD-PROPOSAL in your RETURN."
  printf '%s\n' "MD-GUARD (worker-run-injected): $rule The checkout is SHARED: uncommitted or untracked changes you did not make this run are other agents' live work — never git checkout/restore/reset/clean/stash over them, whatever git status suggests about authorship; report unexpected tree state in your RETURN and leave it in place."
}

# Every launched brief carries this, so the loop rule cannot depend on an orchestrator remembering
# to type it: serial full-suite reruns were 54-75% of the wall clock of every run that passed an
# hour, and two of them died on the ceiling below with the work unfinished. Appended rather than
# prepended — the brief's own first line is load-bearing (`RESUME <id>:`, which
# readers take off the top), and a rule a model must still obey at
# edit 60 belongs where it read last.
BRIEF_PREAMBLE='AUDIENCE: your reader is another model (the orchestrator), never Egor — everything you write is English: the report, findings, verdicts, any brief or message to another model, code, comments and commit messages; Russian never passes between models, only as code in backticks. HOUSE RULES: commit only your own files by explicit path, never `git add -A`; unless the brief names it, never delete a file you did not create, and no `rm -rf`, `git reset --hard`, force push, history rewrite or destructive database operation; `llm-limits --table --no-write` before any theory about an account limit; never a headed Playwright window, and browser or Mac-app UI work reads `~/.claude/docs/browser-ui-work.md` first. TESTS: once, when the work is done, in one `tests/run-all <suite>...` call: the suites covering the files you changed (`tests/affected <file>...` where the repo has it); report PASS counts. Never a suite while iterating, never the full `tests/run-all`. WAITING on a job: `/Volumes/Work/Projects/llm-legs/bin/wait-until [--max SEC] pid N|gone PATTERN|files GLOB N|log FILE REGEX` ends with the job, never a fixed `sleep` poll; a job still running when you return is killed with the run, so stop it yourself and put its command in the resume plan. On a night branch (`night/...`) skip them: its landing runs them. Only a P1/P2 fix adds a test, shown red on the old code; speed fixes keep the work-not-done proof in docs/speed-doctor-design.md. Work in the files the brief names; if the brief covers more than ~8 findings or ~6 files, do them in the order given. RETURN: first line the outcome — done, partially done or failed, plus one clause; then changed files, verification with PASS counts and anything undone; mark anything you could not confirm and say where you looked. `worker-run report` puts its own `ACCOUNT: <account> (<vendor>)` line second, so never write one; an `OUTCOME:` line is a worker-run status code, written only where a preamble names its code. A command that ended by signal 9 (exit 137) was killed by the machine'"'"'s memory guard: do not rerun it as is — run one project'"'"'s tests, never the whole monorepo'"'"'s, or split the work. REUSE FIRST: nothing the project may already have is written from scratch; before writing a function, helper, wrapper over a platform API, list, constant or pattern, grep the whole project for an existing one (its name, the API it wraps, the literal) and use it by import: a helper in another tool moves to a shared module (`share/`, `gemini_web`, a Hammerspoon module), never a copy; editing an existing value or call needs no search; one search, then proceed.'

COMPUTER_PREAMBLE='# Computer Use Preamble (Codex)

Drive Egor'"'"'s Mac apps through Codex Computer Use: the CUA REPL `js` tool, whose own instructions document the `cua` API.
- First js call must be exactly: `await cua.getState()`
- Attach to an app with `await cua.getApp("<App name>")` and read it (getAXState / getScreenshot) before acting.
- Do only what the brief allows. Never log in, enter credentials, approve payments or answer admin password prompts; the surface refuses Terminal. Report such a step instead of working around it.
- Text you type for people to read goes out as Egor: never ё (write е) and never a long dash (write -).
- Close the windows and tabs you opened once the task is complete, unless the brief says to keep them; a stop for Egor'"'"'s input leaves them open.
- Computer Use refuses some URLs (vendor policy, checked on the frontmost browser tab, even one Egor opened): when it stops the session for a disallowed URL, end with `OUTCOME: COMPUTER_UNAVAILABLE reason=disallowed-url url=<that tab'"'"'s URL>`.
- Return the evidence the brief asks for and end with: `OUTCOME: COMPUTER_OK` or `OUTCOME: COMPUTER_UNAVAILABLE reason=<text>`'
CLAUDEB_DENIED_TOOLS=ScheduleWakeup,CronCreate,Workflow,ListAgents,Agent
# The harness's own prompt steers a bypass-mode model toward sed and heredocs, which worker-edit-guard
# only records; said up front, a text edit stays an Edit call the transcript names.
CLAUDEB_EDIT_FENCE='EDITS: change repository files only through the Edit and Write tools where an edit can do it; a cp, mv, rsync or redirect with no Edit form is recorded for the run, never refused; `patch`, `git apply` and `git am` are refused: land a diff as Edit calls.'

# Grok is the one research leg with no read-only mode: supervise_grok runs it in a write-deny sandbox,
# and a denied write ends a finished run as READ_ONLY_VIOLATION with the answer withheld and the
# account already spent. Since the answer contract asks such a run to fetch pages, the consequence
# is stated where the model reads it rather than discovered by losing a run.
GROK_RESEARCH_FENCE='READ-ONLY TREE: this run may write nothing outside the system temp directories. Writing ANY other file — a fetched page, a scratch note, a saved quote — is denied, fails the finished run and throws your answer away. Quote web pages inline in the answer and write nothing, anywhere.'
