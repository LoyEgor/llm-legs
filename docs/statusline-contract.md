# Statusline freshness contract

For `claudegpt` launches, the account label is bare `<name>` from the launcher's
`CLAUDEGPT_ACCOUNT` environment variable. It is read on every render, changes on
account relaunch, and stays unchanged across model switches, resume, rename,
compaction and directory changes. It is a selected gateway profile label, not a
Claude login or a worker prediction. Other processes cannot change this process's
selection. The ordinary Claude account label is restored when the variable is absent.

The iron rule: **every** statusline element declares (a) its source of truth,
(b) what triggers an update, (c) its staleness/dim policy, and (d) when it is
removed. "Render once and forget" is forbidden — a segment must always reflect
current reality or dim/disappear.

Any change to the statusline (`bin/statusline.sh` or a `statusline-*` hook/probe)
MUST keep this table exhaustive and update `tests/test_statusline_hooks.sh` to
match. The `statusline-freshness-gate.sh` PostToolUse hook reminds you of this
whenever you edit a `statusline*` file.

## Before adding ANY new segment (mandatory checklist)

1. **Enumerate every event that can change the value.** Walk the full list, not
   just the happy path: user slash-commands (`/rename`, `/branch`, `/clear`,
   `/compact`, `/model`, `/resume`), account/profile switches, `cd`/worktree
   moves, OTHER sessions/agents/humans mutating the same repo or shared state,
   background daemons, and plain passage of time.
2. **For each event, name the mechanism** by which the segment learns about it:
   per-render recompute from the source of truth (preferred), a hook that
   writes per-session state, a background probe with a declared cache TTL.
   "The cache will probably still be right" is not a mechanism.
3. **If even one event cannot be detected**, the segment must visibly dim/hide
   in that situation — or must not ship at all. Segments that froze in practice
   get REMOVED, not patched around (see Removed segments below).
4. **Prove each mechanism with a test** in `tests/test_statusline_hooks.sh` and
   add the row to the table here in the same change.

Render budget: warm p95 ≤150ms. Anything slower than that lives in a background
refresher (a hook, or the fire-and-forget probe pattern), never the render path.

## Line 1 — identity / work

| Segment | Source of truth | Update trigger | Staleness / dim policy | Removal condition |
|---|---|---|---|---|
| model + effort | statusline JSON stdin (`.model.display_name`, `.effort.level`) | Every render (harness re-sends JSON, 5s) | Model and effort render; worker Fast Mode is deliberately omitted because this shared line cannot distinguish worker launches from ordinary chat/CCR. | model always shown; effort suffix only if present; Full words (`Fable 5 high`) at full width; fit step 5 abbreviates model and effort (`FB5 hi`, see Progressive fit) |
| `<account>` (magenta, no `cb:` prefix) | `CLAUDEGPT_ACCOUNT` for gateway launches; otherwise `CLAUDE_LIMITS_ACCOUNT` / `CLAUDE_CONFIG_DIR` basename | Every render | Not dimmed | Absent when `acct=main` (plain non-claudeb session); gateway `main` stays visible; keeps its first 7, then 4, then 3 characters at fit steps 4, 7 and 12, never dropped |
| `dir` + `» <repo>` foreign repository + `⧉ <worktree>` | JSON `.workspace.project_dir`/`.current_dir` + the place journal `place-<sid>` (section "Shown tree") + `git rev-parse`. `dir` is the project basename, except when the project dir is itself a linked worktree — then `repo_dirs` names the owning repository (`REPO_ROOT` from `worktree list`, basenamed) so the project never becomes invisible. `»` compares repository identity (`--git-common-dir`), NOT toplevels, so worktrees of the project are not foreign. `⧉` when the active dir is a linked worktree (`--absolute-git-dir` ≠ `--git-common-dir`), labelled by the active toplevel's basename. **The whole middle block is ATOMIC and renders ONE working tree — the shown tree** (Egor, 2026-08-27, superseding 2026-08-26): `dir`/`»`/`⧉`, the `⎇` branch, the diff and file counters, `↓N↑N`, the rev counter, the gate's verdict and `unpushed` are all about that one tree, and a review elsewhere MOVES the block there instead of being named beside the session's own folder — one folder next to a number about another place named neither (which is what 2026-08-26's never-moves rule and its `rev <name>` labels tried to solve). Which tree that is: the last journal line's, section "Shown tree" below | Every render re-reads the journal; its writers are the hook, `worker-run` and `review-bench` (section "Shown tree") | A last line whose tree is gone falls back to the newest line that resolves, then to its main checkout, then to the session project, silently — no breadcrumb is recorded and none is rendered (see Removed segments). Never dimmed | `»` only when the active repository identity ≠ the project's — the same repository, worktree or not, renders ONE name; `⧉` only for a linked worktree. `⧉` is red when the worktree sits outside `.claude/worktrees/` of either the repository's own main checkout (from `worktree list`) or the session's checkout — the second root is needed because git reports the git dir, not the checkout, as the main worktree under `--separate-git-dir` — nothing else in the setup reports where a worktree physically lives |
| branch `⎇` + uncommitted `+A/-D` + `↓`behind `↑`ahead, or `@sha` | `git` in the active dir (`GIT_OPTIONAL_LOCKS=0`). `+A/-D` = the WHOLE uncommitted volume in the active repo right now, whoever wrote it: `git diff --numstat --summary HEAD` (staged+unstaged; unborn HEAD diffs the worktree against the repo's empty tree instead — no double count of staged intermediates) plus untracked text-file lines (`ls-files --others --exclude-standard` → `grep -cI`, binaries count 0 lines). The dim `+N~M-Kf` files block is NOT rendered beside the numbers (Egor, 2026-09-18) — only the files-only form below uses the same pass: `+` created (`--summary` create + untracked, binaries included), `~` modified (remaining numstat entries — renames and mode changes land here), `-` deleted (`--summary` delete); zero components hidden. NOT the harness's `.cost.total_lines_*` — that was a session-lifetime tool-edit counter across all repos and never matched the actual diff | Every render recomputes from live git — branch switches, commits, edits, or cleanups by ANY session/agent/human show on the next render; the tree asked is the SHOWN tree (section "Shown tree"): home, which follows the workdir hook (cd/EnterWorktree), unless a review of this chat's has moved the block elsewhere | Live git each render; no cache to go stale | Inside a linked worktree there is NO branch segment at all — not the name, not `@sha`: the `⧉` label is the identity, and branch names are policed nowhere on the strip (no fold rule, no divergence colour, no auto-slug alarm). Outside a worktree the branch always shows, blue, whatever it is called. The diff/arrows block is gated on HEAD resolving, never on the branch label being printed; No branch → nothing; detached HEAD outside a worktree → `@sha` (diff shown either way); `+A/-D` hidden when 0/0 — dirty with zero countable lines (binary/mode/rename-only) shows the dim file counts alone, the only form in which they render at all; arrows hidden at 0 |
| live ports `⇢ :PORT` (bright = the shown tree, dim = another tree of the project) | `ports-<sid>` cache written by `statusline-ports-probe.sh` (fired from render, given the project dir's toplevel as its third argument — else the shown tree's — which is all the probe needs to enumerate the project). **Cache format: one record per line, `<port>\t<tree>`** — the port, a tab, and the absolute path of the working tree its process working directory sits in, or `-` for none; a tab because a tree path may carry spaces and a port cannot, and one record per line because the render is the only reader. **What is shown and in what colour is decided by the SHOWN tree** (the middle block's tree — see "Shown tree"; the segment renders inside that block, so it answers for the same one place): shown a linked WORKTREE → only that worktree's ports, bright green, and a sibling tree's are not shown at all; shown the MAIN checkout → every port of the project, the main checkout's own bright green and every worktree's dim, so the root is the one place everything that is up can be seen. Captions saying which tree are refused — the colour is the whole answer, and a label beside each port widens the strip (Egor, 2026-09-04, replacing "every port of the session's own workdir root is green"). A `-` record is a port this session PARENTS whose directory no tree of the project holds; it has no tree to disagree with and stays bright in every view of this project, as does a record with no tree field at all (a cache the previous probe wrote, at most 15s old). Own-tree ports are rendered first, so the three-port cap can never spend itself on siblings and hide the port that is Egor's here. A listener belongs to this session when the walk up its parents reaches the session's own `claude` before any other one — a sibling chat keeps its own servers — or, when that walk reaches launchd instead, when the process working directory is inside one of the project's working trees (`git worktree list --porcelain` from the given root, main checkout first; exact match or under a tree, on the directory boundary, so a sibling checkout with a longer name is not read as being inside, and the LONGEST matching tree wins, since Egor's worktrees live at `<repo>/.claude/worktrees/<branch>` — inside the root, which would otherwise claim every one of their ports; a working directory under `<root>/.claude/worktrees/<name>` that no listed tree holds is a REMOVED worktree's and is recorded as that gone path, not the root, so the main checkout renders it dim and a worktree view hides it) **and** the port is below 49152 — a directory is weaker evidence than a parent, and every language server, debug adapter and editor RPC socket started from the repository shares it, three of which would fill the segment and push the dev server out of it. The orphan case is the normal one, not an edge: a server backgrounded from a tool call is reparented the moment that call returns, and ancestry alone therefore used to lose almost every dev server a session started, leaving the segment permanently empty once the LLM tool sockets were filtered out. Blind spot: a repository reached through a symlink whose real path git does not print, since the tree list is compared against lsof's working directories unresolved (git resolves what it prints, and lsof reports the physical path, which is why the two normally meet). The segment answers "where do I go to look at the work", so the probe then keeps only listeners a human could open: `mcp`/`figma`/`chrome-devtools` matches, the session's own `claude`, and every LLM tool the session drives — `agy`, `opencode`, `opencode-go`, `codex`, `grok`, matched on the last path segment of argv[0], so a dev server is never classified by its own arguments (`node serve.js --dir /srv/agy` stays) at the cost of a tool whose own path carries a space, the same blind spot the `claude` check has — are dropped. Below such a tool only ephemeral ports (49152+) go, which is where every RPC socket and no dev server binds: a dev server a worker started IS the work and keeps its place | Render fires the probe in the background when the cache is >15s stale | Cache mtime >60s → hidden (probe presumed dead) | Cache absent → hidden; cache empty (probed, no servers) → hidden; server death shows within ~15–20s as the next probe writes an empty cache; max 3 ports. A port of a tree other than the shown one is dropped while a worktree is shown, so the segment is empty when the block sits in a worktree with nothing up; when the shown tree belongs to another repository the whole segment is hidden |
| pin — vendor word (`claude`/`codex`/`gemini`/`grok`) or account name, magenta | THIS session's chat pin file only: `${CHAT_PINS_DIR:-$HOME/.cache/claude-chat-pins}/<session_id>`, session id from stdin JSON `.session_id` (already sanitised to `[A-Za-z0-9_-]`). The file holds one line `<vendor>_profile=<name>\|*` (`claudeb`/`codex`/`gemini`/`grok`). `*` renders the vendor word (`claude` for `claudeb_profile`, else the vendor key as written); any other value renders as the account name. The global pin in `~/.claude/worker-model` is never shown (the menu shows it). Read with `sed` on each render; `share/worker-model.sh` is not sourced for this | Every render rereads the file. Events that change it — `chat-pin` write/delete, a wall-lapse clearing the chat file, a new session id — are all visible on the next tick because the file is the source of truth | Live file; no cache to go stale; never dimmed | Absent when there is no session id, the file is missing or empty, or its first line is not a recognised `<vendor>_profile=` line. Dropped whole by fit step 9 |
| repository debt `∑N` | `review-debt --repo <shown toplevel>` (review-bench `bin/`, contract `../review-bench/docs/review-anchors-contract.md`) prints `LINES=<n> FILES=<n>`: what the whole git FAMILY owes, whoever wrote it — every path any chat touched, everything dirty and everything an anchor stands on, each priced by its cheapest anchor. Beside the `+A/-D` counters because it is about the same tree; the `rev` segment below stays this chat's alone | The command is run off the render path under a 120s lock, cached per shown TOPLEVEL on `<top>\|<mtime of the family's review-anchors.json>` with a 15s TTL, so an anchor written by ANY chat or worker run in any checkout of the family moves the key. Switching folder (`dir_foreign`, `cd`, a worktree, a review moving the block) switches the cache file with it, the file being named after the toplevel. Edits landing between two anchor writes are bounded by that TTL, and by `review-debt`'s own cache, which is keyed on HEAD, the index and every dirty path's mtime+size — a render that finds nothing moved costs no diff | Never dimmed into a wrong digit: only a whole `LINES=… FILES=…` line becomes a number, and an unparsable answer, a missing or non-executable `review-debt`, a `timeout` kill and an answer older than 120s all render NOTHING — a folder debt is not a number anybody acts on within the second, so no answer beats a stale one | Hidden at `N=0`, hidden when no answer stands, hidden where there is no active toplevel, shortened to the bare dim number `N` by fit step 1 — once `+A/-D` has lost its signs the debt is the only dim number on the strip and reads as its own block without the mark (Egor, 2026-09-18) — and dropped whole by fit step 8, after every name has already been abbreviated. It rides with the branch block and goes wherever that block goes |
| review debt `N` / autonomy `● N` | `review-flow-gate.sh verdict <shown-repo> <chat>` prints ONE line of the debt protocol (`../review-bench/docs/review-anchors-contract.md`): `STATUS=closed\|open\|unknown LINES=<n> FILES=<n> FIX=<n> WHY=<token> [BOUND=<n>]`, or `off`. The numbers are the session's own, summed over every repository it owes (the shown tree plus the session's `.repos` list), and the segment shows them in the block whatever tree it renders — the block's other counters stay per shown tree; `autonomous <chat>` supplies the mark | Verdict cache follows shown-tree identity, Git state and the journal/review-clock changes of the shown tree and of every `.repos` repository; background refresh at 15s, same TTL for autonomy | ONE parser turns that line into the rendered form and nothing on the render path decides a class of its own: `closed` → empty; `open` with `LINES>0` → `N`; `open` with `LINES=0` and `FIX>0` → dim `fix N` (lines first — open findings are shown only where nothing is owed); `unknown` is a number with a flag, never a replacement of it: the known form above followed by a dim `?<why>` (`N ?gap`, dim `fix N ?gap`, `?gap` alone when both are zero), and `WHY=ledger` with a bound → `~BOUND ?ledger`, the dirty-tree bound of a store nobody could read. `?gap` = a hook could not record a change of this chat; `?run` = a worker run of this chat died without folding (a live run flags nothing); `?nobase`, `?ledger`, `?err` likewise. Egor brings the word to that chat, which runs `review-debt <session> --list` and `review-anchors check` to name the cause. A flag is shown only for a state to act on; normal or transient states render nothing. A line that does not open with `STATUS=`, one missing a field of the protocol and one whose field is not the shape it promises are all dim `?err`: a number invented over an answer nobody could read is the silent zero this protocol exists to end. A verdict older than 120s is the render's own dim `?`, reasonless because the reason died with the answer; stale autonomy loses its mark. No session total and no other chat's count | The autonomy mark never hides with the segment; the mark alone is `●` when there is no verdict to carry it, and every form above takes the dot in front of it (`● 29`, `● 29 ?gap`, `● ~120 ?ledger`, `● fix 3`). `off` hides the verdict, and so does `closed`. NO word is printed in this slot at all — a bare number is the debt (Egor, 2026-09-16); narrow fit closes the space after the dot (`●29`) |
| review run `[T<N> [max]] [✓\|✗] <done>/<total>` + dim ` +N` for this chat's other runs | `<state_dir>/progress/<repoName>__<repoHash>-<pid>.json`, written by `review-bench`'s own `cmd_run` — the one process that knows when a run ends (0cc5eed retired the hook that tried to know from outside). **Every review-bench-derived run is on its launching chat's line from launch until its result is consumed** (Egor): the document is no longer unlinked at the end, so what the run IS comes from the writer's own `state` (`running` \| `done` \| `dead` \| `cancelled`), `heartbeat_epoch` (integer unix seconds, refreshed at least every 30s while the process lives) and `finished_epoch` (integer, written with `done`/`dead`), while what it LOOKS like is that state crossed with what this render can still verify about the pid. A merged review of several `--repo` writes one such document per repository it reads, identical but for the recorded `repo`, so the run renders in each of their statuslines rather than in one; the reader is unchanged, since it already matches on the recorded `repo` and renders the newest. `<total>` is the cell list the run actually launched, after affordability and skips, so a vendor disabled in LLM Limits shrinks it; `<done>` grows as each cell returns; `T<N>` is absent for an untiered `run`. `max` names the wider panel the tier's `--max` variant runs at the same time budget, from the document's boolean `max`; a run started before that key existed, or one recording it without a tier, renders as the tier alone, since `--max` is refused without `--tier`. `expected` maps each exact launched cell name (including `#N`) with history to its base cell's median milliseconds; `started_epoch` is the integer wall clock. Both are written once at run start. Scope is the working tree OR the chat that launched the run, never the repository: a review a worker or another chat started on THIS tree is this tree's news, while one running in a linked worktree belongs to the chat sitting there — matching on `--git-common-dir` could not tell them apart, since every worktree of a repository shares one — and a review of ANOTHER repository still renders for the chat that started it, which is otherwise the one statusline it is invisible in. Which chat that is, review-bench resolves ONCE at run start and records as the document's `session` string, written with `expected` and `started_epoch` and never rewritten: it walks its own pid up its parents (`ps -o ppid=`, ≤15 hops, stopping at pid 1) to the first with a `<registry>/<pid>.json` entry whose `.sessionId` is a string (`~/.claude/sessions`, overridable with `REVIEW_BENCH_SESSION_DIR` for tests) and omits the key where no chat can be named. At run start because that is the only moment the chain exists — a backgrounded run outlives its launcher and reparents to pid 1 — which demotes the reader's own copy of the walk (`review_run_session`) to a fallback for documents written before the writer recorded one. A run started from a subdirectory still resolves to the tree it belongs to, which is why the match reads the recorded `repo` rather than the file name. It is its own segment, always rendered BEFORE the verdict and never in place of it: a review in flight used to blank that verdict on the same tree, so any run over this tree — this chat's or another chat's — hid the debt the reader acts on (Egor, 2026-08-24). **The counter is NEVER named** (Egor, 2026-08-27): a run over another tree moves the whole block there (section "Shown tree"), so the folder beside the count is the one the count is about and a repository name in this slot would be the second answer the move exists to remove. The scan keeps ONE candidate, this chat's newest run over the shown tree. A run ANOTHER chat launched is dropped whole wherever it is — its review is that chat's line to read and is not shown here at all (Egor, 2026-09-16, retiring the dim `+N` that used to count them) — and a document declaring `state: cancelled` is dropped the moment it is read, `review-bench cancel` being Egor's decision that the run answers for nothing. A `done` or `dead` document whose `<state_dir>/benches/<run_id>/reported.json` exists is consumed and dropped the same way: review-bench keeps it (phase `report`) for the task row after the report is taken. Whose a run is is the RECORDED `session`, with the parent walk as the fallback for a document written before review-bench recorded one; a run whose launcher cannot be named at all stays this chat's, since hiding a review this chat may well have started is the worse error. This chat's OTHER unconsumed runs of the same repository — sibling worktrees included, a run there being this repository's news without being this tree's — are the dim ` +N` after the counter, a count and never a name; with no counter to ride on it is not rendered at all, a number about no tree and no progress being no news. The order is by CLASS and only then by `started`: live, then wedged, then finished (`done`/`dead`), newest within a class and never across one — a leftover `✓ 12/12` of this chat's own outranked its own live run of the same tree, finished documents surviving for a day. The away candidate, this chat's newest run elsewhere, is ordered by the same rule. A recorded repo that no longer resolves to a working tree is dropped WHOLE, counter included: the block is one tree's rendering, and there is no tree left to render such a run with (asking git about an empty path answers for the render process's own directory, which used to pass a vanished repository off as the session's own). Neither slot carries a word: this one is a tier, a mark and a counter, and the verdict beside it is a number or a mark of its own (row above). **A finished round of this chat's elsewhere** has no live document to read, and it is `review-bench review-anchor --session <sid> --cwd <home dir>` that says a review is out there and where. It prints the run's own repository from its meta (`repo`, or the `repos` members of a merged panel) as `<repo>` or `<repo> +N` — the statusline never reads bench dirs itself (binary next to `statusline.sh`, else `review-bench` on PATH; `STATUSLINE_REVIEW_BENCH` overrides), takes only the path and ignores the member count, and a merged panel anchors to the member equal to the home dir's repository, else to the FIRST member; several runs from one chat → one ordering rule: a run in flight outranks any merely-pending one, and within each standing the newest run id wins. That path is the away tree of last resort in the priority list (section "Shown tree") and nothing else: it renders NO segment of its own — the dim `<repo>` marker it used to feed is gone with every other name in this slot — and it is consulted only where its answer can decide something, which is a home that is clean, idle and owing nothing | Every render reads each file in the progress directory (a second glob covers a dotted repository name) and matches on the `repo` recorded inside it, never on the file name. Resolving that `repo` to a tree is the pass's one git call per document, and it is remembered by PATH in `<cache dir>/run-trees` (`<path>\t<toplevel>\t<common dir>`, last line for a path wins, dropped whole past 300 lines): a finished document survives for a day across every repository, and one fork each on every 5s tick is the render's whole budget spent on runs that are already over. An entry whose recorded toplevel or common dir no longer exists is skipped and the path resolved again, which is the only event that can change the answer — review-bench keys the name on the path it was handed, so a run started from a subdirectory writes a name no render can predict; the pid likewise comes from the payload. The writer rewrites the file from its main thread as each cell returns, so the counter moves on the next render, and refreshes `heartbeat_epoch` at least every 30s for as long as the process lives, so a wedge crosses the 120s window within one render of it. Nothing about a document is cached: every render re-reads every file, so a `state` that flips to `done`/`dead` under the reader — by the run finishing, by review-bench's reaper, or by another chat's `wait`/`report`/`record` consuming it — is seen on the next tick. The pending marker's anchor is cached per session in `review-anchor-<sid>` — keyed on the session alone, since the active dir only picks a merged panel's member and the TTL bounds that, while a cwd key voided a valid anchor at every cd — with a 15s TTL and refreshed off the render path (same lock/TTL/120s fallback as the verdict cache, the bench call under the same `timeout 10`); the `review-anchor-*` files and their `.lock` dirs age out after a day with the sibling cache prunes | Liveness is derived by the reader, never declared by the writer: the pid must be alive (cheap gate) **and** the process holding it must have started no later than the file's last write — a recycled pid necessarily started after the dead run's final write. That pair, crossed with the declared `state`, is the whole rendering: `running` + pid held + heartbeat ≤120s = the live counter (bright, and red when late by the rule below); `running` + pid held + heartbeat >120s = the same counter DIMMED and unmarked, the wedge nobody should read as news; `running` + pid gone or recycled, and `dead` (the reaper's own word), = dim `✗ <done>/<total>`, the run that has to be finished or cancelled before it stops asking, until that chat acts and review-bench consumes or retires the document. `done` = dim `✓ <done>/<total>`, including a non-zero panel exit with failed cells: cell failures are report rows and do not change the run label. **Compatibility path** — a document with no `state`/`heartbeat_epoch` is one an older review-bench wrote and keeps exactly the rule it shipped with (live pid, unrecycled, mtime under 2h, no marks). The recorded `repo` must resolve to a working tree at all (`--show-toplevel`, not `--git-common-dir`, which every linked worktree shares — identity here is the WORKING TREE, so a run in a sibling worktree is a tree of its own and never this one's), and that tree must be either HOME or, for a run anywhere else, one this render's own session owns — the document's `session` where it has one, the walk where it does not — so a run over a foreign tree that another chat started renders nowhere here, `done` must not exceed `cells`, and — **on the compatibility path only** — the file's mtime must be under 2h, which is the wall against a wedged process, NOT a staleness window: a run whose slowest cell is still out writes nothing for as long as that cell takes, and must keep rendering. A document that declares a `state` is not walled by mtime at all: the heartbeat already separates a slow cell from a wedge, a finished run writes nothing more, and its lifetime belongs to review-bench's reaper (>24h). Any pending cell with history is late when elapsed run time exceeds both 3 × its median and 120s; completed cells and cells without history are exempt. Elapsed is measured from the run's start deliberately, not per cell: a cell held that long by the OpenCode admission gate is the same news as a slow one, and the 120s floor absorbs ordinary queueing. A live late segment is red — but only for the chat that started it, by the same session comparison the display predicate makes. A run attributed to another live chat renders dim and never red: its lateness is that chat's to see, not this one's. A live run whose launcher cannot be named (daemon launch, stale registry, a walk that runs out of hops) stays bright, since hiding a review this chat may well have started is the worse error. Missing or malformed `expected`/`started_epoch` disables late coloring without invalidating older documents. Any file failing any liveness check is ignored, never rendered stale | Absent, corrupt or unparseable file, a dead or recycled pid on the compatibility path, or one naming another chat → the gate's verdict has the slot back, and where that is `off` the segment is empty; an unanswered round of this chat's elsewhere leaves no segment behind — it holds the BLOCK instead, and hands it back the moment `review-anchor` exits 1 (no run live or pending for the chat), its tree stops resolving, or home starts working or owing a review. The document, and with it the segment, goes when review-bench removes it and at no other moment: the chat consuming the result (`review-bench wait\|report\|record`), a new run for the same repo+session replacing it, or the reaper taking it away after 24h — the same reaper that marks `dead` where the pid is gone. Teardown no longer unlinks anything, so a `done` run, or a `dead` run for its launching chat, keeps its slot with its mark until one of those happens; on the compatibility path the old rule stands (a `kill -9` leftover renders nothing and is pruned by the next run in that repository). Two live runs in one repository → the newest `started` renders, one segment |
| `unpushed` marker | **The review gate's own answer**, `review-flow-gate.sh unpushed <asked toplevel> <session_id>` — the short sha of every commit of THIS chat its branch's upstream does not contain, oldest first; the marker is "it printed anything". Ownership is the gate's (a naming record in either journal, or a worker run this chat launched), never this render's, so the marker and the Stop ask that says «commit X not pushed — push now» are one answer. The asked toplevel is the same one the `rev` verdict is asked about | Cached per session and per asked tree (same `-<cksum>` suffix as the verdict) on `<toplevel>\|HEAD\|upstream sha\|commit-journal mtime\|debt-journal mtime`, 15s TTL; refreshed off the render path under a `mkdir` lock, as `rev` is. A branch with no upstream, or HEAD equal to it, answers without calling the gate at all | Last answer stands until 120s, then the marker goes rather than outliving the tree it was read from; never dimmed — an unpushed commit is this chat's own to act on | Absent while the upstream contains every own commit, while the branch has no upstream, while the session id is unknown, and while the gate is not executable |

### Shown tree (line 1 middle block)

The middle block — `dir`/`»`/`⧉`, the `⎇` branch, the diff and file counters, `↓N↑N`, the rev
counter, the gate's verdict, `unpushed` — is ATOMIC: every part of it is computed from ONE working
tree, and no repository name is ever printed inside the counter slot (Egor, 2026-08-27, superseding
the 2026-08-26 rule that the folder never moves and a review elsewhere is named beside it). One
folder next to a number about another place named neither.

2026-09-15 (Egor, «куда изменения, туда и папка»): the shown tree is the last journal line; no
priorities, no stickiness, no liveness. This retires the home/away priority list, the sticky
worktree home, the three-consecutive-writes run, read-grade evidence, the `workdir-<sid>` state
file and `review-bench review-anchor`.

**The place journal** `~/.cache/claude-statusline/place-<sid>` (`STATUSLINE_CACHE_DIR` moves the
directory) holds one line per event, `<epoch>\t<kind>\t<tree>\t<main>`, appended by
`bin/statusline-place add --session <sid> --kind <kind> --path <dir-or-file>` in one `printf >>`, so
parallel writers never lose a line. `tree` is the physical toplevel of the working tree the path is
in; `main` is the physical checkout owning its `--git-common-dir` (equal to `tree` in a main
checkout). A path under `/tmp`, `/private/tmp`, `$TMPDIR`, `$HOME/.cache` or any `node_modules`, or
outside every git work tree, writes nothing. `$HOME/.claude/*` is NOT excluded: a file is resolved
through its own symlink first, so an edit of `~/.claude/hooks/x.sh` journals the repository that
physically holds it. `add` exits 0 when it wrote a line and 3 when it wrote none, so a caller
trying candidates in turn moves on past an excluded one. The journal is `0600` (umask 077). Past
400 lines the writer keeps the last 200, rewriting the file under a `place-<sid>.lock` directory
that every append past 350 lines also takes, so a trim loses a line only if 50 others land between
one writer's line count and its own append. Kinds are informational; no reader branches on them.

| Writer | Kind | Path |
|---|---|---|
| `statusline-workdir-hook` SessionStart, only while the journal is missing or empty | `seed` | the session cwd — unless the first line of `transcript_path` names `forkedFrom.sessionId` (a `/branch` fork) whose `place-<parent>` is non-empty: that journal is copied whole (tmp + rename, `0600`) and nothing is appended |
| Edit/Write/NotebookEdit PostToolUse — the chat's own and its subagents' alike | `edit` | the file |
| Bash PostToolUse, a persistent `cd X`/`pushd X` | `cd` | X |
| Bash PostToolUse, `(cd X && …)` or a mutating `git -C X`, when the command as a whole is not read-only | `git` | X |
| Bash PostToolUse, a write verb (`sed -i`, `tee`, `cp`, `mv`, `rm`, `touch`, `mkdir`, `ln`, `truncate`) or a `>`/`>>`/`1>` redirect not to `/dev/*`, also inside `if`/`for`/`while` bodies, when no row above matched | `edit` | the first absolute argument — for `cp`/`mv`/`ln` only the last operand — or redirect target (after the command's own `NAME=value` words expand `$NAME`/`${NAME}`; a value that cannot be expanded unbinds the name; `\ ` is a literal space) whose nearest existing ancestor is in a work tree |
| Bash PostToolUse, `git worktree add`/`git worktree move` | `enter-worktree` | the new path from the PreToolUse/PostToolUse worktree-list diff, else the parsed token when it is its own toplevel |
| Task/Agent PreToolUse, main session only | `dispatch` | the first `/`-rooted token of the brief that is a directory `add` writes a line for |
| EnterWorktree / ExitWorktree PostToolUse | `enter-worktree` / `exit-worktree` | the worktree / `CLAUDE_PROJECT_DIR`, else the session cwd |
| `worker-run start`, when `CLAUDE_CODE_SESSION_ID` names a chat | `worker-start` | the run's workdir |
| `worker-run`'s terminal outcome, for the run's recorded launcher, once per run (a `.place-end` directory in the run dir), with or without `report-bus` | `worker-end` | the run's workdir |
| `review-bench`, a progress document created `running` | `review-start` | its `repo`, for its `session` |
| `review-bench`, the run itself stamping its document `done`/`dead` as it ends (never the reaper retiring a run nobody ended) | `review-end` | the same |

Nothing else writes: a `Read`, a read-only command (`(cd /x && git status)`, `git -C /x log`,
`grep`/`sed -n` over a worktree), a write with no cd, no `-C` and no absolute target, `git worktree remove`, and a subagent's Bash or dispatch move nothing.
Read-only is decided over the WHOLE command string exactly as before (`share/statusline-workdir.jq`
`command_read_only`): discard-only redirects are neutralised and any surviving `>` or backtick is
work; then every simple command must be a reading tool, `git` only with a read subcommand. The
worktree add/move diff snapshots the worktree lists of the `-C` dir, the session cwd and the last
journal tree at PreToolUse into `place-<sid>.snap[.<tool_use_id>]` (which is why the hook's
PreToolUse matcher carries `Bash`); exactly one new path is the answer, and a named path that exists
and is not that one moves nothing. The hook prunes `place-*` older than 7 days once an hour, and an
unconsumed snapshot after an hour.

**The reader** walks the journal from the end: the first line whose tree is an existing directory is
the shown tree. When no line's tree exists, the LAST line's `main` is shown if it exists; else, as
with a missing or empty journal, the session project dir. The tree then goes through `repo_dirs`
exactly as the project dir does, and `»`/`⧉` render as for any tree. Nothing is ranked, held,
debounced or checked for liveness; a hold-down, if one is ever wanted, belongs in the reader alone,
since the journal keeps every line. `statusline-place why --session <sid>` prints the shown tree,
the line that chose it, any fallback taken and the last 10 lines.

Everything in the block asks that one tree: branch, diff and `git status` from `git -C <tree>`, the
run counter from a progress document over it — whoever started it, this chat's own outranking
another's, WORKING over OVER — the `+N` from other chats' documents over its repository, and the
verdict and `unpushed` from the gate for it, each cached in one file per session keyed on the tree:
while a refresh runs, the verdict serves a stale answer only when it was asked about this same tree,
and `unpushed` only under its exact key — an answer about the previously shown tree is never shown.
An empty journal costs the render one `[ -s ]` test; a non-empty one adds a file read and a `-d` per
line walked, and one `repo_dirs` when the tree differs from the project's.

Worked examples:

1. A chat in claude-setup runs `worker-run start … --workdir llm-legs` → llm-legs at once; the
   worker ends → still llm-legs; an Edit in claude-setup → claude-setup.
2. Worker A starts in A, worker B starts in B, A ends, B ends → A, B, A, B.
3. A Read, `(cd /x && git status)` and `git -C /x log` → nothing moves.
4. An edit of `~/.claude/hooks/foo.sh` from a chat in llm-legs → the repository that physically
   holds the file.
5. A deleted worktree → the newest line that still resolves, else the deleted worktree's main
   checkout, else the project dir.
6. Another chat's review over the shown tree → the dim counter or `+N`; the folder does not move.
7. A chat working in worktree W is `/branch`-ed → the fork opens on W, not on the launch dir: it
   starts with a copy of the parent's journal.
8. `W=/r/.claude/worktrees/x; sed -i '' 's/a/b/' $W/f.ts` → W, like an Edit of `$W/f.ts`.

### Progressive fit (both lines)

Each line is composed, measured and re-composed until it fits the budget `$COLUMNS −
STATUSLINE_FIT_MARGIN`; the harness exports `COLUMNS` fresh on every invocation. Claude Code cuts a
status line row at the right edge (it no longer wraps), and the usable width is a few cells short of
`COLUMNS` — the interface's built-in spacing, which the docs do not number; a 77-column window was
measured to cut about 3 cells early. The margin defaults to `3` and is overridden by the environment
variable of the same name (tests, a one-time calibration); a non-integer value falls back to `3`.
Notifications that shorten the row further are not fitted. With `COLUMNS` unset or empty **nothing
shrinks** — every segment of both lines renders its full form.

Measurement is visible cells: the colour escapes are stripped as the literal strings that produced
them (bash patterns have no quantifier, so no regex is available in-process) and the remainder is
two columns (`⎇ │ · ✓ » ↓ ↑ ⇢ ⧉ ▶ ⏸` are all single-cell, and a fast-mode line measured as exactly
`$COLUMNS` used to wrap). In
a non-UTF-8 locale the count over-reads and the line shrinks earlier than it must — conservative by
construction, never an overflow.

Segments carry full / short / off forms; the steps below are applied in order, re-measuring after
each, and the first order that fits wins. Line 1:

| # | Step | Effect |
|---|---|---|
| 1 | diff signs and the folder debt's mark | `+A/-D` → `A/D`, same green/red, slash kept; `∑N` → a bare dim `N`, the only dim number left beside them |
| 2 | branch glyph | drop `⎇` |
| 3 | branch name | ticket prefix only (`^[A-Za-z]+-[0-9]+`), otherwise 7 characters |
| 4 | account and directory names | the account first keeps its first 7 characters (`locomthebest` → `locomth`) — Egor reads his own accounts by their first letters, and it shrinks together with the folders; a name already no longer than that is left alone. Then one shared cut for every name on the line — both sides of `»` and the `⧉` worktree label: starting from the longest name, the cut shrinks one character at a time, re-measuring, and stops at the first length that fits or at the floor of 8, so a name shorter than the cut is untouched and the cut is the smallest the line needs. A ticket-named one (`^[A-Za-z]+[-_][0-9]+`, the worktree convention) is never cut below that prefix: `WUT-12345-fix-header` → `WUT-12345-fix` → … → `WUT-12345`, `WUT_1234-fix` → `WUT_1234`, separator as written. The digits are the identity the owner reads, so no cut may reach into them (Egor, 2026-08-27) |
| 5 | head model+effort | abbreviated (`Fable 5 high` → `FB5 hi`) |
| 6 | the verdict's autonomous dot | The dot loses the space after it (`● 7` → `●7`) and nothing else on the strip has a word left to shorten here: neither the run counter nor the verdict carries one, and their marks (`✓`, `✗`, `~`, `?<why>`) are the state rather than decoration. The gate's own numbers are never rewritten |
| 7 | account and directory names | the account keeps its first 4 characters (`loco`), in the same step, then initials: split on `-`/`_`, first letter of each word (`claude-setup`→`cs`); one word → 3 characters; the `»` pair loses its spaces (`cs»ll`). Initials that are not shorter than the cut step 4 stopped at are not used at all (`a-b-c-d-e-f-g-h-i-j` stays `a-b-c-d-`) — this step may only shrink the line. A ticket-named directory skips this step entirely and stays at its ticket prefix (`wut-25-portal` holds `wut-25` while the plain name beside it goes to initials); step 11 dropping the cluster is the only thing that takes it off the line |
| 8 | folder debt | drop `∑N` — the repository's debt outlives every name abbreviation and goes only once the names are already initials |
| 9 | pin | drop the pin whole; `unpushed` shortens to a red `↑!` |
| 10 | `»` pair | keep the active side only |
| 11 | directory | drop the cluster, worktree label included |
| 12 | account | first 3 characters (`loc`), the floor |

Shared abbreviation rule (head model only from step 5): model = first letter
plus the first consonant after it, uppercased, with the version digits glued on — `Fable 5`→`FB5`,
`Opus`→`OP`, `Sonnet 5`→`SN5`, `Haiku 4.5`→`HK4.5`, `astra`→`AS`, `pro`→`PR`; a name yielding no two
such letters is printed whole. Effort = `low` / `med` / `hi` / `xhi` / `max`.

Never dropped at any width: the red alarm blocks (the gate's `loud` verdict, commit/push asks,
`unpushed` even as `↑!`, a red review counter) and `↓N↑N`. A line that still overflows after step 12
is left overflowing — a cut row is the lesser failure.

Line 2, fitted separately to the same budget:

| # | Step | Effect |
|---|---|---|
| 1 | cost | drop the `$<cost>` suffix |
| 2 | ctx tokens part | drop `→HH:MM`, `<n>k`, `? <n>k` and a lone `?`; the yellow `↓5m` then stands after the ctx percentage, space-separated (`ctx 20% ↓5m`) |
| 3 | reset labels short | on `5h`, `wk` and `fb` alike: a weekday+time label → the weekday (`Fri 22:00` → `Fri`), a time-of-day label → its hour (`23:30` → `23h`); `<n>h` / `<n>m` stay as written |
| 4 | reset labels | dropped whole, `fb`'s included |
| 5 | separators | ` │ ` → one space |

Floor: `ctx N% 5h N% wk N% fb N%`, left as is when it still overflows. Never touched by any step:
`↓5m` (an alarm), staleness dimming, colours and the `?` unknown forms of the percentages.

## Line 2 — usage

The `1800`s / `21600`s staleness thresholds below are cross-implementation invariants; their canonical values and every other site live in `docs/shared-invariants.md` (guarded by `tests/test_consistency.sh`).

| Segment | Source of truth | Update trigger | Staleness / dim policy | Removal condition |
|---|---|---|---|---|
| `ctx <pct> →HH:MM` (warm), `ctx <pct> <n>k` (cold), or `ctx <pct> ? <n>k` (unknown) | `%` is `.current_usage` sum / `.context_window_size` when both exist, else `.used_percentage`; `<n>k` is `.current_usage`. After a `compact_boundary` the payload is not trusted for size: the harness keeps replaying the pre-reset usage until the first request of the new context completes, so the transcript wins — the newest non-sidechain, non-`<synthetic>` assistant `usage` (`input` + `cache_creation` + `cache_read`) stamped strictly after the boundary replaces the payload value whenever the two differ by more than 10%, and until such a response exists the size is 0. Any `usage` object with a positive total sizes the context, cache tokens or not — an input-only response is a real size even though it is not warmth. The boundary itself is not limited to what the window reached: the newest `compact_boundary` timestamp ever seen is persisted per session as `<state>/<session>.bnd` (`<scanned bytes> <ISO ts or ->`, both fields monotonic, last writer wins) under `${CONTEXT_NUDGE_STATE_DIR:-~/.cache/claude-context-nudge}` and shared with the context-nudge hook, which maintains it under the same rules. Warmth comes only from the session transcript's newest qualifying assistant response for the payload `.model.id` with any `[...]` context-window suffix stripped (the harness sends `claude-opus-5[1m]`, the transcript records the bare id): non-sidechain, non-`<synthetic>`, positive server-reported `message.usage.cache_read_input_tokens` or `cache_creation_input_tokens`, plus the response's positive `usage.cache_creation.ephemeral_*` TTL bucket. Account identity comes from a positive per-session/per-model account stamp and transcript-order cursor; an absent/legacy stamp cannot self-attribute a meaningful response. Transcript mtime, payload cache counters, user/system/tool entries, shell execution, open/resume events, and learned/seed TTL guesses are never warmth sources | Every render first advances the `.bnd` sidecar over whatever the transcript grew by since its recorded size (re-reading the last 4 KiB so a boundary line cut at the previous end of file is not lost) and seeds the scan with the timestamp it holds, so a `/branch` or `/compact` whose re-emitted burst buries the boundary deeper than the window still resets the size. It then reads the live payload and checks the newest 256 KiB first. On a miss it jumps to the persisted per-model depth, then grows 4× only while no current-model response is found, capped at 8 MiB; a base-window hit resets the persisted depth to 256 KiB. A new qualifying response after the current-account cursor updates the account/model stamp; `/compact`, model/profile changes, forks, `/clear`, transcript append/removal, and TTL passage are therefore reflected on the next render. Parent-fork ancestry is cached with the resolved transcript identity and rechecked when its size or mtime changes; the event matrix below names each mechanism | `%` is dim while the number is INHERITED rather than measured: until a non-forked qualifying response exists strictly after the last `compact_boundary`, unless the transcript corroborates the payload — a fork-copied tail has no own response yet its copies ARE this session's context, so a post-boundary size measurement agreeing with the payload within the same 10% the size override uses proves the payload describes THIS context and un-dims it. A freshly compacted session has no such measurement until its first response, an unreadable tail yields none, a payload the transcript contradicts is the inherited case itself, and a payload carrying no size at all leaves its percentage with nothing to corroborate it — all four keep dimming. Display forms are mutually exclusive: warm shows only dim `→HH:MM` (Europe/Kyiv), never `<n>k`; known cold shows only restart price `<n>k`; unknown shows `? <n>k`, never an arrow. Cold and unknown share the warning scale: dim only below 90k where little is at stake, yellow 90–299k, red ≥300k — a just-reset context therefore renders as an ordinary `0%`/`0k`, with no placeholder wording of its own. A payload percentage that describes the discarded usage is dropped when there is no `.context_window_size` to recompute it from. A shortest TTL below 1h adds yellow `↓5m` to the warm time. Missing/unreadable transcript, missing model id, missing TTL bucket, absent/legacy account proof for a meaningful response, unprovable parent/account ancestry, mid-chat fork, or an assistant hidden beyond the 8 MiB bound is unknown. Malformed/in-progress, sidechain, synthetic, and zero-usage assistant entries are skipped and cannot extinguish earlier evidence | Warm time disappears at TTL expiry, account mismatch, a current-session `compact_boundary` at/after the response, a parent `compact_boundary` at/after an inherited fork anchor, or until the current model has a qualifying response. Token count disappears only when warm; a known-zero usage still renders `0k`, and `?` remains without a count when usage is unavailable. Line-2 fit step 2 drops the time/count part, never `↓5m` |
| `5h <pct>` + reset time | For `claudegpt`, read-only `$LLM_LIMITS_FILE` `vendors.codex.accounts[]` matched by `CLAUDEGPT_ACCOUNT`, never Claude payload limits or caches; that store is what the Codex quota kick below refreshes, since a gateway payload carries no `rate_limits` to merge. Otherwise merged rate-limit cache (`statusline-cache-rl` for main, `limits/<acct>.json` for claudeb) — live headers merged under lock each render | Every render merges newer headers, plus one liveness case: when the payload's `cost.total_cost_usd` is strictly greater than the value recorded at this session's last accepted merge (per session in `<statusline-cache>/rl-cost-<session_id>`, written only when a merge accepted something), a window whose `resets_at` and rounded percentage equal the cached ones is re-stamped `as_of: now, origin: session` — a session still calling the API is reading a window that has simply not moved, not replaying. A lower percentage or an older window is still rejected, and the re-stamp is not login evidence; a merge that accepts a newer `five_hour` whose `resets_at` is later than the account's `auth_checked_at` also stamps `auth: {status: "ok"}` and deletes `auth_needed`/`auth_cause`/`auth_checked_at` — a live session is proof the human logged in, and nothing else in the background clears the flag. An idle session replays its last readings, so a window that opened before the logged-out verdict is not that proof and leaves the flag standing. A `claudegpt` render merges nothing: it reads the store the Codex quota kick refreshes, so its update trigger is that kick's cadence, never a header | Judged by `share/limits-view.sh` (shared-invariants y), the bucket's raw snapshot fed to `limits_bucket_expired`/`limits_bucket_stale`/`limits_effective_pct`: dimmed when expired (a real reset epoch ≤ now) or stale (`auth=expired`, `origin=cached`, `as_of` >1800s — the shared `LIMITS_STALE_FIVE_HOUR`), or when the `llm-limits.json` `stale` flag is set; an expired window shows its EFFECTIVE value `0%`, a placeholder reset below the epoch floor is neither expired nor a time, and a reset over a day past drops its time but not the verdict | Removed, separator included, when the account has no five-hour window at all (`limits_window_absent` in `share/limits-view.sh`: bucket null, or `used_pct` and `resets_at` both null — a Codex plan without the window, grok); `?` when the window exists but is unknown. Its reset time is shortened by line-2 fit step 3 and dropped by step 4 |
| `wk <pct>` + reset | For `claudegpt`, the same Codex account’s `weekly` bucket; otherwise same cache (`seven_day`), which the render stamps `origin: "session"` because the harness payload is a real server-side reading of both windows; a `seven_day` stamped `origin: "headers"` is unmeasurable by construction (shared-invariants n) and every reader discards it | Every render; for `claudegpt` the value itself moves on the Codex quota kick's cadence, like `5h` | Same shared view as `5h` with `LIMITS_STALE_WEEKLY` (21600s): dim when expired or stale, effective `0%` when expired | Never removed; `?` when unknown — including a discarded header-origin bucket, which renders `?` rather than a fabricated number. Reset label: line-2 fit steps 3 and 4 |
| `fb <pct>` + reset | `~/.llm-limits.json` `vendors.claude.accounts[].fable` | Every render reads the file; the store is written by the `llm-limits` collector (menu collect-on-open) and kept fresh by the statusline **store merge-kick** below | The collector's own fields, as the menubar renders them: value = `effective_pct`, dim when `stale` or `expired`; the file mtime >`LIMITS_STALE_FABLE` (21600s) is the backstop against a frozen store | Only for a non-`main` Claude account that has a `fable` bucket; absent for `claudegpt`. Reset label: line-2 fit steps 3 and 4 |
| `$<cost>` | JSON `.cost.total_cost_usd` | Every render | Live each render (`LC_ALL=C` for the decimal point) | Absent when cost is null; dropped by line-2 fit step 1 |

`claudegpt` uses that same `ctx` renderer. Bridge `cache_creation.ephemeral_*` buckets are present but zero, so warmth is unknown (`? <n>k`) rather than a fabricated TTL arrow, and there is no separate used/window/cached layout.

Codex quota buckets use the shared limits view and recheck resets and `as_of` on
every render; stored stale/expired flags and file age also dim readings. Missing
accounts or buckets render `?`, never a Claude fallback or invented zero. No
render performs network requests or writes either vendor’s quota store — the store
behind those two cells is refreshed off the render path by the Codex quota kick
below. Gateway profile names must match the corresponding Codex account labels in
llm-legs.

No documented retention window authorizes a warm `ctx` arrow on this transport, so
the unknown form is the end state rather than a gap waiting for a timer: the bridge
deletes `prompt_cache_options`/`prompt_cache_retention` from every Codex-bound
request and emits no `cache_creation.ephemeral_*` bucket, and OpenAI publishes no
response field or header that reports when a cache entry expires. The evidence and
the URLs behind that decision are in `docs/claudegpt.md`.

### Prompt-cache event/update matrix

| Event | Named update mechanism | Result |
|---|---|---|
| Normal model response | Bounded backward transcript scanner selects the newest qualifying response for the current payload model and reads its exact usage + TTL buckets | Warm when timestamp, account, model, compact, and TTL gates pass; a new response refreshes expiry |
| Tool-heavy response tail | Scanner checks 256 KiB, jumps directly to the current model's persisted depth on a miss, then grows 4× up to 8 MiB only while no current-model response is found | Response inside the bound remains discoverable; deep depth is retained only while needed and shrinks to 256 KiB after a base-window hit; exceeding the bound renders unknown |
| Shell command, tool result, user message, chat open, or resume without a model response | Scanner ignores non-assistant entries; no mtime or execution hook participates | Existing expiry is unchanged |
| Assistant error, synthetic response, zero cache usage, or sidechain/subagent response | Qualification filter rejects the entry | Earlier main-context evidence remains authoritative |
| TTL passage | Every-render epoch comparison uses strict `now - response_ts < bucket_ttl` | Warm time becomes cold restart-cost form |
| `/compact` | `system/compact_boundary` comparison against the selected response; the same scan pass zeroes the context size at each new-maximum boundary and re-takes it only from a later response; boundaries are ranked by timestamp, never by file position, because re-emitted older boundaries trail the newest one, and a size already taken from a response newer than a newly-maximal boundary survives it for the same reason | Cold until the first qualifying current-model response strictly after the boundary; size reads `0%`/`0k` until then |
| `/branch` of an uncompacted chat | Every copied entry carries `forkedFrom`, so the branch has no response of its own until it answers once; the size scan does not care — it reads the copied responses' usage, which is the context the branch was handed, and compares it with the payload | Bright from the first render while the two agree within 10% — dimming a corroborated number would report a live context as lost; a payload that disagrees stays dim as an inherited one |
| `/branch` of a compacted chat | The branch's boundary line is followed by re-emitted pre-compact entries that keep their old timestamps and their old `usage` totals, so a size is taken only from a response stamped strictly after the newest boundary — strictly, because second-resolution timestamps let an auto-compact boundary tie with the last pre-compact response and a tie would resurrect its total; a transient `0k` is the cheaper error | Size reads `0%`/`0k` instead of the inherited 200k+, and the payload's stale percentage never survives the reset |
| A boundary buried deeper than the scan window (a re-emission burst larger than 256 KiB) | The window stops growing at the first current-model response it finds, which after such a burst is a re-emitted pre-compact one, so the boundary is never seen in-window; the `.bnd` sidecar carries it in from earlier renders and seeds the scan, and a seeded boundary is treated exactly like one found inside the window | Size still reads `0%`/`0k` rather than the buried context's stale total |
| `/model` switch, including the compact Sonnet ritual | Current-model selector plus per-model account stamp | Uses that model's newest qualifying response only; missing current-model evidence is cold/unknown, never borrowed from another model |
| Profile/account switch | `CLAUDE_LIMITS_ACCOUNT` / `CLAUDE_CONFIG_DIR` compared with the response's session/model account stamp | Existing response becomes cold on mismatch; the first later qualifying response re-stamps the new account |
| Resume/reboot with an absent optimization track | Transcript response timestamp/model/TTL are rescanned; an existing positive account cursor is required, while an empty/new transcript seeds the current-account cursor for later responses | Warm when the response is still inside its reported TTL and account/model proof survives; a meaningful response with no account proof is unknown |
| Tail branch | Copied `forkedFrom.messageUuid` is compared with the parent's last UUID at the branch's first own timestamp; the resolved parent scan records the fork anchor timestamp, newest current-model usage, and compact boundary, then the parent model stamp supplies account proof. The verdict is cached until parent size/mtime changes | Warm while the proven shared prefix remains inside TTL, even if the parent later advanced; any parent compact boundary at/after the fork anchor makes inherited evidence cold |
| Mid-chat branch or missing parent proof | Parent contains an omitted UUID before the branch's first own event, or ancestry/account evidence is unavailable | Unknown `? <n>k`, colored by restart cost |
| Model/window change (`/model`, a 1M-window session) | The payload's `.context_window.context_window_size` is published to `~/.cache/claude-context-nudge/<sid>.window` on every render, atomically and only when the value changed | The `context-nudge` PostToolUse hook — whose own payload carries no window size — scales its compact thresholds (80%/90%, re-arm 50%) to the live window instead of a hard-coded 300k; an absent file falls back to 300000, and an unchanged file keeps its mtime so staleness stays visible. Statusline does not sweep the directory: the `context-nudge` hook itself (claude-setup `hooks/context-nudge.sh`) deletes its own top-level files older than 3 days once a day, name-scoped for the same overridable-`CONTEXT_NUDGE_STATE_DIR` reason |
| `/clear` or new empty chat | Complete transcript scan finds no qualifying response | Known cold until the first response |
| Transcript missing/unreadable or current model id absent | Read/model gate fails | Unknown `? <n>k` |

## Task rows (subagentStatusLine, `bin/subagent-statusline.sh`)

The harness hands the renderer only `local_agent` tasks (never background Bash or Monitor) and lets it
rewrite the body of each id it received. A row exists only while the harness lists the task as
`running`: a completed, failed, killed or otherwise finished task produces no row whatever its run
files say (the harness keeps finished agents listed for hours; the rows show only what is going on),
so there is no `✓ done` / `✗ failed` / `⏸ checkpoint` / `cancelled` row state. Every running task is painted:
`<tag> — <title> · <state> · <elapsed>[ · ↓ tok]` — tag magenta, state dim with `✓` green and `✗` red;
review, fix and image rows carry no title: `<tag> · <state> · <elapsed>[ · ↓ tok]`, except a
review of lens `task` (a hunt), which keeps its title without the `WAIT|ATTACH <run-id>: ` prefix. A
fix row is `fix: <tag> · <hash> · <state> · <elapsed>[ · ↓ tok]` (`fix: locomthebest · opus · high ·
7aebd92 · wait 1 · 24m`): `fix: ` leads the magenta tag, the round's short hash is its own dim field,
never part of a title and never the state. A number always
stands right of its element (`wait 2`, `agy 2/4`, `✗1`; only `↓ 12k tok` leads), spaces
separate groups inside a field and ` · ` only separates fields.
The tag comes from `~/.cache/claude-worker-tags/<sid>/<task-id>` line 1, else the tag prefix of the
hook-rewritten description, else `agent · <model-short> · <account>` from the harness `model` and the
session account (`CLAUDE_LIMITS_ACCOUNT`, else the `CLAUDE_CONFIG_DIR` basename, else `main`). The
model shown is always the model doing the work, never a relay agent's shell model. The title is the
task's `description` with its tag prefix (`<tag>: ` or `<tag> — `) stripped; the harness `label` (the
agent's momentary activity) is never read, so concurrent workers stay distinguishable.

| kind | tag (writer) | state (source) |
|---|---|---|
| relay worker run, ATTACH | `<acct> · <model> · <effort>` (`worker-spawn-hook` seed, `worker-tag-hook`, `worker-run` claim) | tag line `run=<id>` → `$WORKER_RUN_DIR/<id>/state.json` `phase`: `start`, `wait N` (`round`); no state once the run has an `exit_code` |
| fix run of a review round | `fix: ` + the worker tag | the hash field (last 7 of `state.json` `round_id`), then as a relay worker run |
| review-bench run (`review-waiter`) | `<tier> · <composition> · <lens>` from the progress doc's `tier`, `composition` (default `standard`), `lens` (`task` for a hunt); `review · <last 7 of run id>` while no doc names the run; never `rev`, never task text (`worker-spawn-hook` seed, `worker-tag-hook` on `review-bench wait <run-id>`, re-read by the renderer) | `review=<run-id>` (or `WAIT`/`ATTACH <run-id>` in the description) → progress doc `$(state dir)/progress/*.json` (`run_id`): `all n/m` (finished/`cells`; a cell in `done` or `failed_cells` is finished) + one group per label in first-appearance order: `label done/total`, `label ✓` when all finished and none failed, ` ✗N` after the fraction for N failed (`✗N` alone when all failed): `all 5/8 agy 2/4 ✗1 opus 1/2 sol ✓` (label = the short model name, the first cell segment with a `claude-`/`codex-`/`oc-`/`opencode-`/`gemini-` prefix dropped, no account; a group with any `chunks` entry `[read, total]` of total > 1 counts chunk passes instead, a finished cell as total/total and one without an entry as 1/1 or 0/1: `all 3/8 agy 7/20 opus ✓ sol 3/10`; a group with a cell in the doc's `verifying` map (`{cell: "running"\|"done"}`, review-bench's opencode/agy verifiers) at `running` says `verify` after its fraction, `agy 4/4 verify`, and gets `✓` only when every cell is finished and none is verifying — a doc without `verifying` renders as before, and the panel phase `verify` shows the groups, no word of its own), then `phase` `report`, while `judge` leaves the panel row's cells in place and adds a judge row below it (see "The judge row"); `state` `done` → `✓ report <confirmed>`, `dead` (legacy `failed`) → `✗ dead`, `cancelled` → no state |
| image-gen | `<acct> · <short>` (`short.<kind>` of `share/image-caps/<vendor>.json`: `notcom · gpt-image-2`); `image-fanout` → `fanout · image` or `fanout · video` | `media=gen` (`edit` with `--ref`/`--resume`) while the script runs, no state once `exit=N` is stamped (`statusline-workdir-hook` PostToolUse Bash → 0, PostToolUseFailure `Exit code N` → N); fan-out: `image=<dest-dir>` → `<dest-dir>/fanout.state.json` `{kind, cells: [{vendor, account, status, exit}]}` (`image-fanout` rewrites it on every cell change, none on `--dry-run`; `status` is `waiting` while the cell holds for a `--max-parallel` slot with no process of its own, then `running`, then `done`/`failed` — the renderer counts anything but `done`/`failed` as pending, so a queued account is never read as work in flight) through the review cell code, label = vendor: `all 2/3 codex ✓ gemini 0/1 grok ✗1` |
| light-research | `light research · <model> · <acct>` from the `light_research` row (`3.8-flash` from `flash38`); the seed carries `light=research`, and a run tag written over line 1 is recast by the renderer | as a relay worker run |
| light-worker | `light edit · <model> · <acct>` from the `light_edit` row, seed key `light=edit`; a gemini-worker spawn is a plain worker row | as a relay worker run |
| fork | `fork · <model> · <account>` (tool model, else the parent transcript's; the renderer shows the harness model) | `explore`, then `edit N` from the tag line `edit=N` (`statusline-workdir-hook` PostToolUse Edit/Write/NotebookEdit of that agent) |
| Workflow agent, teammate, anything untagged | `agent · <model> · <account>` | `edit N` when counted, else none |

State files: `worker-run` rewrites `state.json` (tmp + rename) on start, on every `wait` (round + 1)
and at the end: `{phase, round, exit_code, agent_task_id, session, account, model, effort, round_id,
started_epoch, ts}`; `session` is the launching chat (`CLAUDE_LAUNCHER_SESSION`, else
`CLAUDE_CODE_SESSION_ID`). `worker-tag-hook` marks `start=<epoch>` on the agent's tag file before a
`worker-run start`; the run swaps the freshest mark (≤120s), or the `CLAUDE_AGENT_ID` file, for
`run=<id>` and its resolved tag, keeping every other key line. Spawn seeds are
`pending-<type>-<tool_use_id or epoch-pid-rand>`, one per spawn, carrying `spawn=<key>` (the first 16
hex of the SHA-256 of the brief's first line), claimed by the agent's first Bash call: the seed whose
key matches the first prompt line of the agent's own transcript (`<parent>/subagents/agent-<id>.jsonl`),
else — no key on either side — the oldest seed no older than `WORKER_TAG_SEED_MAX_AGE_S` (600), so a
denied or cancelled spawn's seed is never another spawn's tag; `spawn=` never reaches the tag file.
Every tag-file rewrite — `worker-tag-hook`, the `edit=N` count, the `exit=N` stamp, `worker-run`'s claim — holds the
session directory's `.claim.lock` (mkdir lock; one older than a minute is broken once, a live one
outwaited ~3 s and the write skipped). A `review-waiter`'s `review-bench wait <run-id>` is rewritten (`updatedInput`) to carry
`--waiter <agent id>` — the id the tag cache is keyed on — so review-bench records the doc's
`waiter {session, task_id}`. `light-research` waits one `worker-run wait --max 540` round per call:
a run still going prints `RUN: <id>` and `STATUS: running` and exits 0, and
`light-research --attach <run-id> --out <answer>` waits the next round (allowed only inside the
`light-research` agent).

Fit: budget = `columns − SUBAGENT_ROW_RESERVE` (default 3, the same margin as the top statusline's
`STATUSLINE_FIT_MARGIN`, pinned equal by `tests/test_statusline_hooks.sh`; the harness passes `columns: 67` for an
~80-column chat). Over budget a row drops, in order: the title tail (`…`) down to `TITLE_FLOOR` (20)
characters, then the title tail to nothing (the `—` with it); the token count; the elapsed time; a fix
row's hash; the per-group detail, last (the `all n/m` total stays). A judge row fits on its own, dropping
the hash, then the effort, the model and the elapsed; its `judge:` prefix and the account always stay. The tag and the state are never dropped, and a state word never
loses its number: `wait 1` stays `wait 1` (never `start`) at any width.

The judge row: from the moment the progress doc's `phase` is `judge` until the task ends, a review task's
`content` holds TWO rows joined by a single `"\n"` — the panel row, then the judge row:

```
T0 · double · bugs · all 8/8 agy ✓ opus ✓ · ✓ done · 4m
judge: locomthebest · opus · high · 7aebd92 · 1m
```

The panel row keeps its cells, its state becomes `✓ done` and its elapsed FREEZES at the phase change:
the judge-phase start is the doc's `phase_at` (epoch seconds or an ISO timestamp), else `judge.ts`, else
the moment the renderer first saw the phase, cached per task in `<tag cache file>.judge`. The words
`judge` and `verify` never appear on the panel row; `✓ report <confirmed>` replaces the cells from the
report phase on and the judge row stays under it (finished sub-rows of a live task stay; a task the
harness no longer lists as running has no rows at all). The judge row is `judge: ` and then the doc's
`judge` `{account, model, effort}` as `·` fields in the shape of a worker tag, the round's short hash
(last 7 of the run id) as a dim field, and the judge's own elapsed; a document without `judge` degrades
to `judge: 7aebd92 · 1m`, never to empty fields. A judge row is never rendered before the judge phase.

`SUBAGENT_JUDGE_ROW=inline` is the fallback for a harness that renders only the first line of a
multi-line `content`: one row, the judge's fields replacing the cells —
`T0 · double · bugs · judge: locomthebest · opus · high · 7aebd92 · 1m`.

Late groups: a review group (`agy 2/4`) holding at least one pending cell that is late by the top
statusline's rule (review run segment above; shared-invariants row `u`: elapsed since the doc's
`started_epoch` over both 3 × the cell's `expected` median and 120 s) renders that group token plain
red (`\033[31m`), and only in the chat that launched the run — the row's `session_id` equals the doc's
`session` or its `waiter.session`; every other chat's row stays uncoloured. A group with no `expected`
entry for its pending cells is never red; a missing or malformed `started_epoch` disables it. Fan-out
rows are never red: `fanout.state.json` carries no expected timings.

Gates bound to these rows: `worker-spawn-hook` is the one owner of the native-type policy and denies
(`permissionDecision: "deny"`) every type outside `RELAY_TYPES` and `NATIVE_ALLOWLIST` (`fork`,
`review-waiter`, `light-research`, `image-gen`) — `Explore`, `Plan`, `general-purpose`,
`claude-code-guide` included; a Workflow call is untouched; `worker-limit-gate` judges no native type
(shared-invariants row `bt`). `worker-launch-gate` reads a Monitor's command through the same masked
scan as a Bash call: a Monitor on `worker-run wait` or `review-bench wait` in command position is
denied, and every owned spelling behind it (`worker-run start`, the image scripts, `light-research`)
meets the same checks a Bash call does; a `review-bench wait` from any Bash but a `review-waiter`'s (a
headless `CLAUDEB_WORKER=1` process excepted) is denied with the brief to spawn instead — `WAIT
<run-id>: <what>`, or `ATTACH <run-id>: --relaunch` / `--finish-partial` for a recovery, which the
review-waiter passes to its first wait (the Stop ask names the same spawns); `light-research` is
denied outside its own agent. A running `light-research` round prints `RUN:`, `STATUS: running` and
`OUT: <answer path>` for the next `--attach` call, and `--attach` refuses an `--out` inside the run's
workdir or add-dirs as the launch does. Foreign runs
(another chat's review) have no task here and stay in the line 1 review segment, which drops a
`done`/`dead` document once `benches/<run_id>/reported.json` exists: review-bench keeps the document
(phase `report`) for the task row after the report is taken.

## Store merge-kick (background, not a rendered segment)

`bin/statusline.sh` already merges live `rate_limits` headers into the per-account
caches every render, but it never used to touch the central store
`~/.llm-limits.json` — that only updated on a menu open, so the menubar and other
sessions' store-derived data (`fb`, the `stale` flags) lagged until someone
opened the menu. After a render that captured fresh headers (the write branch),
the statusline now nudges the store so fresh data propagates passively.

| Property | Value |
|---|---|
| Source of truth | the per-account rate-limit caches the render just wrote |
| Update trigger | fires only on a render that captured fresh headers; runs the same zero-network collector the menu's collect-on-open uses (bare `llm-limits.sh`, **never** `--refresh`) |
| Debounce | ≤ once / 60s across **all** sessions via the shared stamp `~/.cache/claude-statusline/store-merge-kick` |
| Single-flight | the `store-merge-kick.lock` mkdir lock (stale-reclaimed at 120s) via the same `snapshot_lock_acquire` helper the cache write uses; the stamp is written in the foreground under the lock so a near-simultaneous second render sees the debounce and skips |
| Non-blocking | the collector runs in a detached background subshell with its own fds; render latency is never affected |
| Failure policy | fully silent — a failed nudge never breaks or slows the render |
| Consumer | the Hammerspoon menubar reacts to the store write via an `hs.pathwatcher` (2s throttle) that re-renders the title without a menu open; overridable/neutralizable in tests via `STATUSLINE_STORE_MERGE_CMD` |

## Codex quota kick (background, not a rendered segment)

A Claude account rides its own usage in every render payload, so `5h`/`wk` are live at the
harness's 5s cadence and the merge-kick only has to propagate them. A `claudegpt` launch has
no such ride-along: the gateway payload carries no `rate_limits`, and its two cells read
`vendors.codex.accounts[]` out of `~/.llm-limits.json`, whose only other writer is the
`llm-refresh` heartbeat — a per-vendor ladder starting at 30 min, i.e. at or past the 1800s
`LIMITS_STALE_FIVE_HOUR` threshold, so the `5h` cell dims by construction between ticks. The
kick is the equivalent soft per-session mechanism: while a gateway chat is open, that account's
own rows are re-read often enough to stay bright, and when no gateway chat is open nothing fires.

| Property | Value |
|---|---|
| Source of truth | `~/.llm-limits.json` `vendors.codex.accounts[]` — the same rows the two cells render; the kick refreshes them, it never renders anything of its own |
| Update trigger | every render of a launch with `CLAUDEGPT_ACCOUNT` set calls it; it fires only once the account's next-probe deadline has passed. An Anthropic-model session never calls it |
| Work performed | `llm-limits.sh --refresh-account codex/<account>` — the existing per-account verb the heartbeat tick and the menu's Hard refresh already use, no new button and no second code path. It reaches the account through `codex-quota.py` → `share/codex_appserver.py` `account/rateLimits/read`, a usage read on `~/.codex-profiles/<account>`: zero token spend, never a completion |
| Cadence | one deadline stamp per account, `<statusline-cache>/codex-quota-kick-<account>`, holding the epoch the next probe may fire at. A probe that ran sets it to +600s — comfortably inside `LIMITS_STALE_FIVE_HOUR`, so the cell never dims while a chat is open; roughly 6 reads an hour per account no matter how many sessions or renders (shared-invariants cb) |
| Pushback | a refresher that exits non-zero rewrites its own deadline to +1800s, so a walled, paused or logged-out account thins to the heartbeat's own cadence instead of being retried every ten minutes. Nothing else interprets the failure — the collector owns the 429 taxonomy |
| Single-flight | the `codex-quota-kick-<account>.lock` mkdir lock (stale-reclaimed at 120s) via the same `snapshot_lock_acquire` helper the cache write uses; the deadline is written in the foreground under the lock, so a near-simultaneous render on the same account sees it and skips |
| Account gate | Two refusals, both before any stamp is written. `CLAUDEGPT_ACCOUNT` is an environment variable the render does not own and it reaches both a filename and a `codex/<name>` argument, so a name outside the launcher's own `^[a-z0-9][a-z0-9._-]*$` pattern fires nothing. And a gateway label need not name a Codex profile at all: with no `~/.codex-profiles/<account>` (`~/.codex` for `main`) nothing fires either, because the collector only WARNS about a missing home and still exits 0 — the pushback backoff cannot see that failure, so every deadline would otherwise spend an app-server launch that dies immediately. Such an account renders `?` and costs nothing |
| Store safety | every write to `~/.llm-limits.json` happens inside the collector, under `share/store-lock.sh`; the render itself still writes no quota store |
| Non-blocking | the refresher runs in a detached background subshell with its own fds; render latency is unaffected (warm p95 ≤150ms holds) |
| Failure policy | fully silent — a failed or missing refresher never breaks, slows or writes onto the render |
| Consumer | the two Codex cells on the next render, and the menubar through the store write like any other collector pass; overridable/neutralizable in tests via `STATUSLINE_CODEX_REFRESH_CMD` |

## Server TTL evidence and learned bounds

The statusline stdin exposes no TTL field, but the transcript does: every
response's `message.usage.cache_creation` names its bucket
(`ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens`) — **the API's own
TTL declaration**. The bucket is parsed generically from the field name
(`ephemeral_<n><m|h>_`), so a new bucket (e.g. `2h`) would be picked up without
a code change. Learned bounds remain diagnostics only; they never authorize a
warm arrow.

| Property | Value |
|---|---|
| Resolution | The newest qualifying current-model response's own positive buckets are authoritative. Mixed buckets use the minimum TTL. No bucket → unknown; `~/.claude/statusline-cache-ttl` and learned bounds cannot supply display expiry |
| Floor / ceiling source | learned from transcript evidence: the newest turn's first response after idle gap G (extracted by the same jq pass). A large `cache_read` proves the cache survived G → `floor = max(floor, G)`, and a survival past the believed ceiling clears that ceiling (self-healing); a full rebuild (near-zero `cache_read`, `cache_creation ≥ 20k`) after G ≥ 120s proves it died within G → `ceiling = min(ceiling, G)`. **Non-evidence guards**: sub-120s rebuilds (prefix invalidations — edited CLAUDE.md, new reminders), a model switch across the gap, a compact boundary inside the gap, and an account switch across the gap (track stamp ≠ current) never move a bound |
| Persistence | Shared `cache-ttl-learned` = `{observed_floor_s, observed_ceiling_s, updated_at}`. Per-session `cache-ttl-track-<sid>` keeps the compatible `v2 <assist_ts> <acct> <learned_upto>` prefix and appends `<ttl> <model> <uuid> <scan_bytes> <account_seen_upto> <account_seen>`; `cache-ttl-track-<sid>.model-<model>` preserves exact per-model account evidence and the depth still needed after a base-window probe. `cache-ttl-track-<sid>.fork` caches fork ancestry, resolved parent identity, fork anchor timestamp, parent compact boundary, and parent current-model candidate, invalidated by parent size/mtime. Tracks are optimization/account stamps, never substitutes for transcript usage |
| Concurrency | Learned bounds use a retrying mkdir lock; every writer re-reads and merges under the lock, then writes with tmp+rename. Per-session tracks remain independent |
| Staleness / decay | bounds with `updated_at` older than 7 days are reset (`floor=0`, `ceiling=∞`) on the next render — Anthropic can change the real TTL |
| Cost | Steady state is one jq pass over the newest 256 KiB. If that misses, the scanner jumps to the persisted per-model depth before further growth; 8 MiB is the hard per-render bound. A later base-window hit shrinks the persisted depth back to 256 KiB. Parent ancestry is one cached scan plus cheap identity checks until the parent changes. Learned writes fire only on new evidence or 7-day decay |
| Failure policy | Malformed/in-progress lines are ignored. Transcript/model/TTL/ancestry uncertainty renders `?`; state-write failure never creates a warm result |

## Known limitations

- **Ports probe misses servers with no parent and no tree.** A listener the
  session no longer parents is shown only when its working directory sits in a
  project tree and the port is below 49152; a double-forked server outside every
  tree of the project (`setsid` into another directory, a launchd unit) is still
  invisible.
- **Ports filter is command-pattern based.** Infra noise is dropped by matching
  `mcp|figma|codex|chrome-devtools|chrome_crashpad` and the `claude` binary in
  the listener's command line. A user dev server whose command contains one of
  those tokens would be filtered out.
- **Uncommitted diff counts text lines only.** Untracked binaries and binary
  edits contribute 0 lines (`grep -cI` / numstat `-`) but still appear in the
  dim file counts; a tree dirty with ONLY such changes shows the file counts
  alone. A huge untracked text file (an unignored log/dataset) inflates `+A`
  honestly — gitignore it.
- **Cache scan is bounded.** An assistant response hidden behind more than
  8 MiB of later transcript data renders unknown until a newer qualifying
  response appears; the renderer never performs an unbounded full scan.

## Removed segments (do not re-add without solving the freshness failure)

- **Worker candidate** (removed 2026-09-15). Rendered `[@]<account>·<MO>·<eff>` / dim `⏸off` from worker-pick's per-account cache line (its writer removed with it) as a forecast of the next dispatch. Replaced by the `pin` segment, which names only this session's chat pin (vendor word or account, magenta) and is silent without a chat file. The global pin stays on the menu. Do not restore a dispatch forecast onto this line.
- **Chat title** (removed 2026-07-21). Rendered the transcript's newest
  `aiTitle` entry, but `/rename` and `/branch` do not write a fresh `aiTitle`
  where the tail scan sees it, so the label froze on stale names — an iron-rule
  violation with no reliable update trigger available. The haiku topic
  summarizer before it died the same way (removed 2026-07-21). Any successor
  needs a harness-provided title field in the render JSON, not transcript
  archaeology. Orphaned `title-*`/`topic-*` caches are still pruned by the
  ports probe.
- **Receipt `review` badge** (removed 2026-08-15). Filled the gap where the
  gate answered `off` by reading `review-bench`'s per-repository receipt and
  dimming a `review` when a real share of the recorded panel had errored. The
  receipt is keyed on the repository and its tree, and a chat is not: the badge
  lit for reviews other chats had run and for trees this chat never touched,
  while the question the label asks is per session. The gate's verdict (row 44)
  answers that question properly, so the badge was deleted rather than
  narrowed; the receipt itself stays, read only by `review-bench receipt`.
- **Folder-follows-review anchor** (removed 2026-08-26, owner decision). The
  `dir`/branch/diff cluster adopted the repository of this chat's in-flight or
  unanswered review, with a `+N` merged-member suffix and a bare dim `rev`
  marker: a chat sitting in one project then read `search » llm-legs ⧉ main |
  rev | rev 113` — the folder was one repository and the number beside it its
  own, two repositories on one line. Superseded on 2026-08-27 (owner decision): the block
  moves again, but ATOMICALLY — every part of it renders the one shown tree, so
  the folder and the number are never about two places — and the naming that
  replaced it in between (`rev <repo>` counters, the dim pending marker) is gone
  with it. Section "Shown tree" is the live rule; `review-anchor` and its cache
  went with that section's priority list on 2026-09-15.
- **`rev ok` / `rev none <n>` / `rev stale <pct>%`** (removed 2026-08-18, owner
  decision). The verdict's old vocabulary priced coverage as a drift percentage
  of a reviewed line total and called anything under 25% covered, which read as
  `ok` over files the run never held and diluted a small rewrite under a large
  reviewed base. Debt replaced the arithmetic outright: a path is in debt or it
  is not, the count is of paths, and a percentage no longer exists to render.
  `rev none <n>` went with it — a count of pending paths said nothing about
  whether anything had read them.
- **Vanished-worktree breadcrumb `⧉ <name> ✗`** and the **branch-name alarms**
  (removed 2026-08-17, owner decision). The cluster carried three judgements
  about names — a yellow branch when the worktree directory's words were not
  carried by the branch, a red one for `claude/*`/`worktree-*` auto-slugs, and a
  dim breadcrumb naming a tracked directory that had stopped resolving. All
  three fired on names rather than on state, and the word-matching behind the
  first was a rule nobody could predict from the strip. A worktree now renders
  `⧉ <dirname>` alone, a main checkout `⎇ <branch>` alone, and a dangling
  pointer falls back to the session project in silence; the `workdir-<sid>.gone`
  marker that fed the breadcrumb is no longer written. The one alarm kept is
  `⧉` in red for a worktree outside `<repo>/.claude/worktrees/`, which is a fact
  about where the tree physically lives, not about what it is called.
- **Session lines counter `+N/-M`** (removed 2026-07-21). Showed
  `.cost.total_lines_added/removed` — a session-lifetime counter of every tool
  edit across all repos (rewrites double-count; other agents' work invisible).
  It never answered "how much is uncommitted", which is what the branch
  segment's `+A/-D` now measures from live git.
