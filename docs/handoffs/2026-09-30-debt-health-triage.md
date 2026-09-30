# Hand-off: eight Debt-row problems, triaged; none is an llm-doctor bug

Status: open

For «LLM Doctor меню refactoring» (`share/doctor-ledger.json` `owner`). Written 2026-09-30 by night
fixer run llm-health-20260930T001639Z-73c9. `debt_health` (`bin/llm-doctor`) reported each of them
correctly: every item is a real open gap in `review-anchors gaps --days 7` or a real row of
`~/.cache/claude/review-debt/losses.jsonl`. The causes sit in the recording side (claude-setup
`hooks/commit-journal.sh`), review-bench `review-anchors run-fold`, ad-hoc probes and unclosed
rounds. Each is now an `open` ledger row H1–H8 narrowed to its key; nothing was dismissed and no
live store was edited. Please route each item to its owner and decide the dismissals.

## H1 `debt-gap:fixer-missing` — three unclosed rounds (handoff)

Open gaps: rounds `20260923T143320Z-c52158a` (chat «Review-bench improvements phase 4»),
`20260924T222306Z-8877b05` («LLM Doctor меню refactoring»), `20260925T152101Z-06f549b` («Дизайн-система
настройка клиентов»): a fixer run folded with no fixer rows. The gap store shows the kind almost daily
from 2026-09-16 to 2026-09-27 and none since; llm-legs 605191f (2026-09-28, a relay that rewrites its
brief no longer drops the round) is the likely end of it, unconfirmed. Remedy per round
(review-bench `share/rbench/debt.py` remedy text): the owning chat runs `review-bench close <round>
--nofix` or reruns the fixer. Closing with `--nofix` settles debt, so it is the owning chat's call.

## H2 `debt-gap:hash-cap/logo-vectorizer-bench` — the cap doing its job (ruled out)

Chats «Vector Magic macOS ARM migration» and «ТОС запускает много парниров» work in a tree with more than
500 dirty paths (untracked `results/`, `tracers/*` research output). commit-journal hashes up to
`RJ_HASH_CAP` 500 and writes a gap when a capped path changes (claude-setup b2e1a91), which is what
the latest lines say (`N capped paths changed, first …`). The debt there is truly unrecorded. Caps are
caps: raising it is not a fixer's move. Options for that project's owner: gitignore the result
output, or commit the tree. Proposed: keep open until that tree shrinks, or dismiss as the cap's
known cost.

## H3, H5 `debt-gap:pre-missing/{gilbarbara-logos,logo-vectorizer-bench}` — calls that created the checkout (handoff)

Both are from 2026-09-25 in «Vector Magic macOS ARM migration», one each: `toolu_01TccPjY…` ran
`mkdir -p $P/... && git -C $P init -q` (cwd `/Users/egorloy`), `toolu_019LXU…` ran `(cd $P/tools/src
&& git clone -q --depth 1 --filter=blob:none --sparse …)`. Both checkouts were born inside the call,
which `created_by_call` (commit-journal, since 184a2a9) should exempt; claude-setup
`tests/test_commit_journal.sh` covers `git init <dir>` and `worktree add`, but not `git -C <existing
dir> init` with no commit, nor a sparse partial clone inside a `( cd … )` subshell. Not reproduced
here (another repository's hook, recording-side owner «Debt hardening handoff»). Worth one fixture
test each; if both pass, dismiss as a pre-2026-09-28 artifact.

## H4 `debt-gap:pre-missing/llm-legs` — fake tool ids from probes (ruled out)

`toolu_probe_timing` (session of «Harness Doctor», 2026-09-28) and `toolu_perf_big` (session
`perf-big-93348`, no real chat, 2026-09-29) are ids nobody's model issued: hand-run commit-journal
timing probes against the live `$HOME` gap store during the hook-latency work (llm-legs c85ff90,
claude-setup 48bfc77). No code path writes them. Proposed: dismiss; ask that chat to run such probes
under a fixture `HOME`.

## H6, H7 `debt-gap:touch-failed/{egorloy,logo-vectorizer-bench}` — commit-journal killed (handoff)

Both in «Vector Magic macOS ARM migration» on 2026-09-29, before claude-setup 48bfc77 (18:52).
`toolu_01GVuJcS…` (a python edit in `logo-vectorizer-bench/bench`, started 02:41:27Z) got the TERM
trap's gap at 02:43:09Z: the PostToolUse hook ran into its 60 s timeout, plausibly the lstat stamping
of the >500-path tree b2e1a91 added. `toolu_01KsrAub…` was `worker-run wait … --max 540` from cwd
`/Users/egorloy` (no repository) in a subagent; its result came at 02:31:31Z, its gap at 03:37:26Z,
an hour later — a TERM at teardown of a hook left running, not a timeout. Since 48bfc77 a provably
read-only call like that skips the heavy hooks. For the hook's owner (Harness doctor's hook-latency
area): measure commit-journal Post on a >500-dirty-path fixture against the 60 s timeout.

## H8 `debt-loss:run-fold-skip` — co-tenant skips logged as losses (handoff)

20 drops in 24 h, all `a co-tenant touched it during the run`: e.g. run claudeb-1790719710-14760-0263
(launched by «Harness Doctor», workdir llm-legs) logged 75 `results/ab*` paths of
logo-vectorizer-bench that the live Vector Magic chat wrote while the worker had that family
snapshotted for its two edits there. `review-anchors run-fold` (review-bench `bin/review-anchors`
`cmd_run_fold`) correctly gives such a path no anchor, and `docs/review-anchors-contract.md` lists
the skip as a loss kind — but the co-tenant's touch stays in the store, so those lines are still
owed by the co-tenant, not dropped unreviewed. The Debt row thus counts every concurrent edit in any
family a worker touched. Deciding whether a co-tenant skip is a loss is review-bench's contract
(owner «Review-bench improvements phase 4»); filtering it in `debt_health` would loosen the judge.
Proposed: review-anchors logs a co-tenant skip only where the run itself changed the path's content
(its after-snapshot differs from its base), or with `lines` 0 and a distinct kind.

## Also seen

The Debt problem title says `×N in 24 h` while an open gap counts for up to `DEBT_GAP_DAYS`
(H1's newest event is five days old). The count is right; the label understates the age.
