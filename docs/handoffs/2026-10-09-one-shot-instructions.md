# One-shot `claudeb -p` calls load CLAUDE.md + memory for nothing

Status: open 20261010T031219Z-4c4e: carried to a fresh night; no caller records its inputs (llm_gate's gate-cache keeps digest and verdict only), so the replay proof needs recording first, and transcriptions-gpt has no night base ref
From: spend audit `startup:CLAUDE.md + memory index`, night 20261009T023738Z-817e
To: next night (claude-setup worktree; usage-ai-report and transcriptions-gpt are outside the sweep repos)

Three headless one-shot callers launch `claudeb -p` from a repo cwd, so every call carries the global
CLAUDE.md, the project CLAUDE.md and the memory index (7 days to 2026-10-09, instruction chars):

| caller | calls | chars |
|---|---|---|
| `usage-ai-report/llm_gate.py` sanitization gate (JSON verdict on untrusted data) | 49 | 363k |
| `transcriptions-gpt/transcriber/judge_last.py` dictation judge | 22 | 327k |
| `claude-setup/skills-on-demand/end-report/compose.py` end-of-day report | 19 | 279k |

None made a tool call. Claude Code 2.1.295 reads `CLAUDE_CODE_DISABLE_CLAUDE_MDS` (no instruction files)
and `CLAUDE_CODE_DISABLE_AUTO_MEMORY` (no memory index or memory system-prompt section); `--bare` is out
(drops OAuth). Set both in the child env of each caller, after replaying a week of its recorded inputs
old vs new: identical verdicts → land it; any changed verdict → keep that caller and note why. The
gate first (its rules are all in its prompt); compose writes Egor's text, so check its language and
no-id rules live in its own prompt before cutting.

Not cut (a reader acts on Egor's rules): log-audit chunk/merge readers flag "a model ignoring an
instruction" against them (finding "Rebuilt a landing wrapper that Egor had already cut", night 817e).
