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
the first time a session edits a `statusline*` file of this repository.

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
| `<account>` (magenta, no `cb:` prefix) | `CLAUDEGPT_ACCOUNT` for gateway launches; otherwise `CLAUDE_LIMITS_ACCOUNT` / `CLAUDE_CONFIG_DIR` basename | Every render | Not dimmed | Absent when `acct=main` (plain non-claudeb session); gateway `main` stays visible; keeps its first 7, then 4, then 3 characters at fit steps 4, 6 and 11, never dropped |
| `dir` + `» <repo>` foreign repository + `⧉ <worktree>` | JSON `.workspace.project_dir`/`.current_dir` + the place journal `place-<sid>` (section "Shown tree") + `git rev-parse`. `dir` is the project basename, except when the project dir is itself a linked worktree — then `repo_dirs` names the owning repository (`REPO_ROOT` from `worktree list`, basenamed) so the project never becomes invisible. `»` compares repository identity (`--git-common-dir`), NOT toplevels, so worktrees of the project are not foreign. `⧉` when the active dir is a linked worktree (`--absolute-git-dir` ≠ `--git-common-dir`), labelled by the active toplevel's basename. **The whole middle block is ATOMIC and renders ONE working tree — the shown tree** (Egor, 2026-08-27, superseding 2026-08-26): `dir`/`»`/`⧉`, the `⎇` branch, the diff and file counters, `↓N↑N`, the debt `N` and `unpushed` are all about that one tree, and a review elsewhere MOVES the block there instead of being named beside the session's own folder — one folder next to a number about another place named neither (which is what 2026-08-26's never-moves rule and its `rev <name>` labels tried to solve). Which tree that is: the last journal line's, section "Shown tree" below | Every render re-reads the journal; its writers are the hook, `worker-run` and `review-bench` (section "Shown tree") | A last line whose tree is gone falls back to the newest line that resolves, then to its main checkout, then to the session project, silently — no breadcrumb is recorded and none is rendered (see Removed segments). Never dimmed | `»` only when the active repository identity ≠ the project's — the same repository, worktree or not, renders ONE name; `⧉` only for a linked worktree. `⧉` is red when the worktree sits outside `.claude/worktrees/` of either the repository's own main checkout (from `worktree list`) or the session's checkout — the second root is needed because git reports the git dir, not the checkout, as the main worktree under `--separate-git-dir` — nothing else in the setup reports where a worktree physically lives |
| branch `⎇` + uncommitted `+A/-D` + `↓`behind `↑`ahead, or `@sha` | `git` in the active dir (`GIT_OPTIONAL_LOCKS=0`). `+A/-D` = the WHOLE uncommitted volume in the active repo right now, whoever wrote it: `git diff --numstat --summary HEAD` (staged+unstaged; unborn HEAD diffs the worktree against the repo's empty tree instead — no double count of staged intermediates) plus untracked text-file lines (`ls-files --others --exclude-standard -z` → `grep -cI`, binaries count 0 lines). The dim `+N~M-Kf` files block is NOT rendered beside the numbers (Egor, 2026-09-18) — only the files-only form below uses the same pass: `+` created (`--summary` create + untracked, binaries included), `~` modified (remaining numstat entries — renames and mode changes land here), `-` deleted (`--summary` delete); zero components hidden. NOT the harness's `.cost.total_lines_*` — that was a session-lifetime tool-edit counter across all repos and never matched the actual diff | Every render recomputes from live git — branch switches, commits, edits, or cleanups by ANY session/agent/human show on the next render; the tree asked is the SHOWN tree (section "Shown tree"): home, which follows the workdir hook (cd/EnterWorktree), unless a review of this chat's has moved the block elsewhere | Live git each render: one `status --porcelain=v2 --branch` supplies branch, HEAD, upstream and ahead/behind, and the diff pass runs only when it lists an entry (`1`/`2`/`u`/`?`), so a clean tree costs no diff. No git state is cached. Only untracked file CONTENT is: past 32 untracked names, `share/statusline-untracked.py` reuses a file's `grep -cI` count while its device, inode, size, mtime and ctime (ns) all still match, from `$STATUSLINE_CACHE_DIR/untracked-lines/<crc32 of the toplevel>.cache` — pruned to the current listing, at most 50000 entries, replaced atomically without a lock, a count taken while the file changed never stored, cache files idle 7 days swept; a name starting with `-` or holding a newline sends the whole listing through the uncached xargs/grep pass | Inside a linked worktree there is NO branch segment at all — not the name, not `@sha`: the `⧉` label is the identity, and branch names are policed nowhere on the strip (no fold rule, no divergence colour, no auto-slug alarm). Outside a worktree the branch always shows, blue, whatever it is called. The diff/arrows block is gated on HEAD resolving, never on the branch label being printed; No branch → nothing; detached HEAD outside a worktree → `@sha` (diff shown either way); an unborn branch (no commit yet) → its name; `+A/-D` hidden when 0/0 — dirty with zero countable lines (binary/mode/rename-only) shows the dim file counts alone, the only form in which they render at all; arrows hidden at 0 |
| live ports `⇢ :PORT` (bright = the shown tree, dim = another tree of the project) | `ports-<sid>` cache written by `statusline-ports-probe.sh` (fired from render, given the project dir's toplevel as its third argument — else the shown tree's — which is all the probe needs to enumerate the project). **Cache format: one record per line, `<port>\t<tree>`** — the port, a tab, and the absolute path of the working tree its process working directory sits in, or `-` for none; a tab because a tree path may carry spaces and a port cannot, and one record per line because the render is the only reader. **What is shown and in what colour is decided by the SHOWN tree** (the middle block's tree — see "Shown tree"; the segment renders inside that block, so it answers for the same one place): shown a linked WORKTREE → only that worktree's ports, bright green, and a sibling tree's are not shown at all; shown the MAIN checkout → every port of the project, the main checkout's own bright green and every worktree's dim, so the root is the one place everything that is up can be seen. Captions saying which tree are refused — the colour is the whole answer, and a label beside each port widens the strip (Egor, 2026-09-04, replacing "every port of the session's own workdir root is green"). A `-` record is a port this session PARENTS whose directory no tree of the project holds; it has no tree to disagree with and stays bright in every view of this project, as does a record with no tree field at all (a cache the previous probe wrote, at most 15s old). Own-tree ports are rendered first, so the three-port cap can never spend itself on siblings and hide the port that is Egor's here. A listener belongs to this session when the walk up its parents reaches the session's own `claude` before any other one — a sibling chat keeps its own servers — or, when that walk reaches launchd instead, when the process working directory is inside one of the project's working trees (`git worktree list --porcelain` from the given root, main checkout first; exact match or under a tree, on the directory boundary, so a sibling checkout with a longer name is not read as being inside, and the LONGEST matching tree wins, since Egor's worktrees live at `<repo>/.claude/worktrees/<branch>` — inside the root, which would otherwise claim every one of their ports; a working directory under `<root>/.claude/worktrees/<name>` that no listed tree holds is a REMOVED worktree's and is recorded as that gone path, not the root, so the main checkout renders it dim and a worktree view hides it) **and** the port is below 49152 — a directory is weaker evidence than a parent, and every language server, debug adapter and editor RPC socket started from the repository shares it, three of which would fill the segment and push the dev server out of it. The orphan case is the normal one, not an edge: a server backgrounded from a tool call is reparented the moment that call returns, and ancestry alone therefore used to lose almost every dev server a session started, leaving the segment permanently empty once the LLM tool sockets were filtered out. Blind spot: a repository reached through a symlink whose real path git does not print, since the tree list is compared against lsof's working directories unresolved (git resolves what it prints, and lsof reports the physical path, which is why the two normally meet). The segment answers "where do I go to look at the work", so the probe then keeps only listeners a human could open: `mcp`/`figma`/`chrome-devtools` matches, the session's own `claude`, and every LLM tool the session drives — `agy`, `opencode`, `opencode-go`, `codex`, `grok`, matched on the last path segment of argv[0], so a dev server is never classified by its own arguments (`node serve.js --dir /srv/agy` stays) at the cost of a tool whose own path carries a space, the same blind spot the `claude` check has — are dropped. Below such a tool only ephemeral ports (49152+) go, which is where every RPC socket and no dev server binds: a dev server a worker started IS the work and keeps its place | Render fires the probe in the background when the cache is >15s stale; the probe reads the machine-wide process table and listener walk (section "Probe snapshots"), each at most 10s old, the table retaken when it is older than the walk — a listener it does not hold has no command or parent to be judged by — so only the root walk, `worktree list` and the attribution run per chat | Cache mtime >60s → hidden (probe presumed dead) | Cache absent → hidden; cache empty (probed, no servers) → hidden; no session ancestor skips lsof/git and an empty listener result skips cwd/tree lookups; server death shows within ~15–30s as a later probe writes an empty cache; max 3 ports. A port of a tree other than the shown one is dropped while a worktree is shown, so the segment is empty when the block sits in a worktree with nothing up; when the shown tree belongs to another repository the whole segment is hidden |
| pin — vendor word (`claude`/`codex`/`gemini`/`grok`) or account name, magenta | THIS session's chat pin file only: `${CHAT_PINS_DIR:-$HOME/.cache/claude-chat-pins}/<session_id>`, session id from stdin JSON `.session_id` (already sanitised to `[A-Za-z0-9_-]`). The file holds one line `<vendor>_profile=<name>\|*` (`claudeb`/`codex`/`gemini`/`grok`). `*` renders the vendor word (`claude` for `claudeb_profile`, else the vendor key as written); any other value renders as the account name. A second line `<vendor>_fast=on`, which only `chat-pin codex-fast`/`grok-fast` writes, appends `⚡` to that label (`grok⚡`, `codex⚡`) in the same colour; it is read off the same file on the same tick, so the pin that clears it clears the mark with it. The line `open=all` (`chat-pin all`, «воркер на все»: every vendor open, none pinned) renders `all`. The global pin in `~/.claude/worker-model` is never shown (the menu shows it). Read with shell builtins on each render; `share/worker-model.sh` is not sourced for this | Every render rereads the file. Events that change it — `chat-pin` write/delete, a wall-lapse clearing the chat file, a new session id — are all visible on the next tick because the file is the source of truth | Live file; no cache to go stale; never dimmed | Absent when there is no session id, the file is missing or empty, or its first line is not a recognised `<vendor>_profile=` line. Dropped whole by fit step 8 |
| repository debt `N` | `review-debt --repo <shown toplevel>` (review-bench `bin/`, contract `../review-bench/docs/review-anchors-contract.md`) prints `LINES=<n> FILES=<n>`: what the whole git FAMILY owes, whoever wrote it — every path any chat touched, everything dirty and everything an anchor stands on, each priced by its cheapest anchor. Beside the `+A/-D` counters because it is about the same tree; there is no per-chat debt segment | The command is run off the render path under a 120s lock, cached per shown TOPLEVEL on `<top>\|<mtime of the family's review-anchors.json>\|<HEAD>\|<+A>\|<-D>\|<file counts>` — the render's own branch oid and diff counters of the shown tree — so an anchor written by ANY chat or worker run in any checkout of the family, a commit or an edit of the shown tree moves the key. A moved key is asked again once the answer is 15s old, one that still holds only after 300s: the walk prices the whole family, about 0.2s of CPU even on its own cache hit. Switching folder (`dir_foreign`, `cd`, a worktree, a review moving the block) switches the cache file with it, the file being named after the toplevel. An edit in a SIBLING checkout of the family is in no key and reaches the number by the 300s, and by `review-debt`'s own cache, which is keyed on HEAD, the index and every dirty path's mtime+size — a render that finds nothing moved costs no diff | Never dimmed into a wrong digit: only a whole `LINES=… FILES=…` line becomes a number, and an unparsable answer, a missing or non-executable `review-debt`, a `timeout` kill and an answer older than 120s — 360s while its key still holds — all render NOTHING — a folder debt is not a number anybody acts on within the second, so no answer beats a stale one | Hidden at `N=0`, hidden when no answer stands, hidden where there is no active toplevel, always a bare dim number, never `∑N` — from afar the mark reads as a digit (Egor, 2026-10-05) — and dropped whole by fit step 7, after every name has already been abbreviated. It rides with the branch block and goes wherever that block goes |
| autonomy `●` | `review-flow-gate.sh autonomous <chat>` prints `yes` or `no` | Background refresh under a `mkdir` lock, 15s TTL, keyed per session — nothing a tree does moves it | An answer older than 120s loses the mark | Shown only on `yes`; nothing else is printed in this slot — the per-chat review debt `N` it used to carry is gone (Egor, 2026-10-05: debt is per repository, a dim `N`) |
| `unpushed` marker | **The review gate's own answer**, `review-flow-gate.sh unpushed <asked toplevel> <session_id>` — the short sha of every commit of THIS chat its branch's upstream does not contain, oldest first; the marker is "it printed anything". Ownership is the gate's (a record in either journal holding the committed blob — legacy blob-less rows: the naming record — or a worker run this chat launched), never this render's, so the marker and the Stop ask that says «commit X not pushed — push now» are one answer. The asked toplevel is the shown tree | Cached per session and per asked tree (a `-<cksum>` suffix) on `<toplevel>\|HEAD\|upstream sha\|commit-journal mtime\|debt-journal mtime`, 15s TTL; refreshed off the render path under a `mkdir` lock, as the debt is. A branch with no upstream, or HEAD equal to it, answers without calling the gate at all | Last answer stands until 120s, then the marker goes rather than outliving the tree it was read from; never dimmed — an unpushed commit is this chat's own to act on | Absent while the upstream contains every own commit, while the branch has no upstream, while the session id is unknown, and while the gate is not executable |

### Shown tree (line 1 middle block)

The middle block — `dir`/`»`/`⧉`, the `⎇` branch, the diff and file counters, `↓N↑N`, the rev
counter, `unpushed` — is ATOMIC: every part of it is computed from ONE working
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
| Bash PostToolUse, a persistent `cd X`/`pushd X` | `cd` | X, relative to this command's own earlier `cd` |
| Bash PostToolUse, `(cd X && …)` or a mutating `git -C X`, when the command as a whole is not read-only | `git` | X — and a mutating `git` with no `-C` names that same earlier `cd`, else the tool's cwd |
| Bash PostToolUse, a write verb (`sed -i`, `tee`, `cp`, `mv`, `rm`, `touch`, `mkdir`, `ln`, `truncate`, `install`, `rsync`, `patch`, `git apply`) or a `>`/`>>`/`1>`/`>|`/`&>`/`>&` redirect not to `/dev/*`, also inside `if`/`for`/`while` bodies | `edit` | the LAST absolute or `~`/`$HOME`-rooted argument — for `cp`/`mv`/`ln`/`rsync` only the last operand — or redirect target (after the command's own `NAME=value` words expand `$NAME`/`${NAME}`; a value that cannot be expanded unbinds the name; `\ ` is a literal space) whose nearest existing ancestor is in a work tree |
| Bash PostToolUse, `git worktree add`/`git worktree move` | `enter-worktree` | the new path from the PreToolUse/PostToolUse worktree-list diff, else the parsed token when it is its own toplevel |
| Task/Agent PreToolUse, main session only | `dispatch` | the first `/`-rooted token of the brief that is a directory `add` writes a line for |
| EnterWorktree / ExitWorktree PostToolUse | `enter-worktree` / `exit-worktree` | the worktree / `CLAUDE_PROJECT_DIR`, else the session cwd |
| `worker-run start`, when `CLAUDE_CODE_SESSION_ID` names a chat | `worker-start` | the run's workdir |
| `worker-run`'s terminal outcome, for the run's recorded launcher, once per run (a `.place-end` directory in the run dir) | `worker-end` | the run's workdir |
| `review-bench`, a progress document created `running` | `review-start` | its `repo`, for its `session` |
| `review-bench`, the run itself stamping its document `done`/`dead` as it ends (never the reaper retiring a run nobody ended) | `review-end` | the same |

Failed Bash commands leave the place journal unchanged: the exit status cannot identify which
segments ran. A worktree add may still journal a new tree proven by its before/after snapshot. A `cd` or `git` is found behind the wrappers and
keywords that open no segment of their own — `sudo`, `env NAME=v`, `timeout <n>`, `nohup`,
`command`, `time`, `then`, `do`, `else`, `elif`, `if`, `while`, `until`, `for`, `{`, `!` — and
behind git's own global options on either side of `-C` (`git -c k=v -C X commit`, `git -C X
--no-pager commit`); `--git-dir`/`--work-tree` consume their path arguments, and `bash -c '…'`
and `eval "…"` bodies are not parsed at all. The mutating subcommands are `checkout switch commit
merge rebase cherry-pick revert restore stash am reset pull push add apply fetch tag clean rm mv
branch`; branch/tag listing forms and `fetch --dry-run` are reads, but a `-d`/`-D`/`-m`/`-M`/`-c`/`-C`
(in a cluster too) or a `--delete`/`--move`/`--copy` anywhere in the arguments is a write whatever
listing flags stand beside it. Standalone `NAME=value` assignments expand the cd, `git -C` and worktree path tokens too
(`$W`, `${W}`, `"$W"`, `$W/sub`); a token left unexpanded, and `cd -`, name no tree and refuse any
relative path after them rather than resolve it against the tool's cwd — `$OLDPWD`, `$PWD`,
`$(pwd)` and the pushd/popd stack are not modelled. `#` comments outside quotes are blanked before any rule reads
the command, and an apostrophe inside double quotes is not a quote (`echo "it's"` pairs with
nothing lines away).

Within ONE command the strongest evidence wins, not the last hit: a mutating `git` or a
`git worktree add`/`move` outranks every `cd` after it — the read-only look at the tree just left,
the bootstrap of the worktree just made — while a later `git worktree add` or commit elsewhere
outranks an earlier one, and a write whose target comes after all of them outranks the lot.

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
debt from `review-debt` for it, and the `unpushed` from the gate for it, cached in one file per session keyed on the tree:
while a refresh runs, `unpushed` serves a stale answer only under its exact key — an answer about the previously shown tree is never shown.
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

Each line is re-composed until it fits `$COLUMNS − STATUSLINE_FIT_MARGIN` (`COLUMNS` exported fresh
per call). Claude Code cuts a row at the edge with its own `…`; its status box is padded two cells a
side (2.1.295 bundle), so `COLUMNS − 4` show, every line and row alike. The
margin defaults to `4`, set by the same-named env variable (tests, calibration); non-integer → `4`.
Notifications that shorten the row further are not fitted. With `COLUMNS` unset or empty **nothing
shrinks**.

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
| 1 | diff signs | `+A/-D` → `A/D`, same green/red, slash kept |
| 2 | branch glyph | drop `⎇` |
| 3 | branch name | ticket prefix only (`^[A-Za-z]+-[0-9]+`), otherwise 7 characters |
| 4 | account and directory names | the account first keeps its first 7 characters (`locomthebest` → `locomth`) — Egor reads his own accounts by their first letters, and it shrinks together with the folders; a name already no longer than that is left alone. Then one shared cut for every name on the line — both sides of `»` and the `⧉` worktree label: starting from the longest name, the cut shrinks one character at a time, re-measuring, and stops at the first length that fits or at the floor of 8, so a name shorter than the cut is untouched and the cut is the smallest the line needs. A ticket-named one (`^[A-Za-z]+[-_][0-9]+`, the worktree convention) is never cut below that prefix: `WUT-12345-fix-header` → `WUT-12345-fix` → … → `WUT-12345`, `WUT_1234-fix` → `WUT_1234`, separator as written. The digits are the identity the owner reads, so no cut may reach into them (Egor, 2026-08-27) |
| 5 | head model+effort | abbreviated (`Fable 5 high` → `FB5 hi`) |
| 6 | account and directory names | the account keeps its first 4 characters (`loco`), in the same step, then initials: split on `-`/`_`, first letter of each word (`claude-setup`→`cs`); one word → 3 characters; the `»` pair loses its spaces (`cs»ll`). Initials that are not shorter than the cut step 4 stopped at are not used at all (`a-b-c-d-e-f-g-h-i-j` stays `a-b-c-d-`) — this step may only shrink the line. A ticket-named directory skips this step entirely and stays at its ticket prefix (`wut-25-portal` holds `wut-25` while the plain name beside it goes to initials); step 10 dropping the cluster is the only thing that takes it off the line |
| 7 | folder debt | drop `N` — the repository's debt outlives every name abbreviation and goes only once the names are already initials |
| 8 | pin | drop the pin whole; `unpushed` shortens to a red `↑!` |
| 9 | `»` pair | keep the active side only |
| 10 | directory | drop the cluster, worktree label included |
| 11 | account | first 3 characters (`loc`), the floor |

Shared abbreviation rule (head model only from step 5): model = first letter
plus the first consonant after it, uppercased, with the version digits glued on — `Fable 5`→`FB5`,
`Opus`→`OP`, `Sonnet 5`→`SN5`, `Haiku 4.5`→`HK4.5`, `astra`→`AS`, `pro`→`PR`; a name yielding no two
such letters is printed whole. Effort = `low` / `med` / `hi` / `xhi` / `max`.

Never dropped at any width: the red alarm blocks (commit/push asks,
`unpushed` even as `↑!`) and `↓N↑N`. A line that still overflows after step 11
is left overflowing — a cut row is the lesser failure.

Line 2, fitted separately to the same budget:

| # | Step | Effect |
|---|---|---|
| 1 | cost | drop the `$<cost>` suffix |
| 2 | reset labels short | on `5h`, `wk` and `fb` alike: a weekday+time label → the weekday (`Fri 22:00` → `Fri`), a time-of-day label → its hour (`23:30` → `23h`); `<n>h` / `<n>m` stay as written |
| 3 | reset labels | dropped whole, `fb`'s included |
| 4 | separators | ` │ ` → one space |
| 5 | ctx percentage | drop the ctx `N%` while a tokens part (`→HH:MM`, `<n>k`, `? <n>k`, a lone `?`) stands in its place (`ctx 45k`); with no tokens part the percentage stays. The tokens part outlives every other cut: its colour is how Egor reads the cache state (Egor, 2026-10-05) |

Floor: `ctx <tokens> 5h N% wk N% fb N%`, left as is when it still overflows. Never touched by any
step: the ctx tokens part, `↓5m` (an alarm), staleness dimming, colours and the `?` unknown forms of
the percentages.

## Line 2 — usage

The `1800`s / `21600`s staleness thresholds below are cross-implementation invariants; their canonical values and every other site live in `docs/shared-invariants.md` (guarded by `tests/test_consistency.sh`).

| Segment | Source of truth | Update trigger | Staleness / dim policy | Removal condition |
|---|---|---|---|---|
| `ctx <pct> →HH:MM` (warm), `ctx <pct> <n>k` (cold), or `ctx <pct> ? <n>k` (unknown) | `%` is `.current_usage` sum / `.context_window_size` when both exist, else `.used_percentage`; `<n>k` is `.current_usage`. After a `compact_boundary` the payload is not trusted for size: the harness keeps replaying the pre-reset usage until the first request of the new context completes, so the transcript wins — the newest non-sidechain, non-`<synthetic>` assistant `usage` (`input` + `cache_creation` + `cache_read`) stamped strictly after the boundary replaces the payload value whenever the two differ by more than 10%, and until such a response exists the size is 0. Any `usage` object with a positive total sizes the context, cache tokens or not — an input-only response is a real size even though it is not warmth. The boundary itself is not limited to what the window reached: the newest `compact_boundary` timestamp ever seen is persisted per session as `<state>/<session>.bnd` (`<scanned bytes> <ISO ts or ->`, both fields monotonic, last writer wins) under `${CONTEXT_NUDGE_STATE_DIR:-~/.cache/claude-context-nudge}` and shared with the context-nudge hook, which maintains it under the same rules. Warmth comes only from the session transcript's newest qualifying assistant response for the payload `.model.id` with any `[...]` context-window suffix stripped (the harness sends `claude-opus-5[1m]`, the transcript records the bare id): non-sidechain, non-`<synthetic>`, positive server-reported `message.usage.cache_read_input_tokens` or `cache_creation_input_tokens`, plus the response's positive `usage.cache_creation.ephemeral_*` TTL bucket. Account identity comes from a positive per-session/per-model account stamp and transcript-order cursor; an absent/legacy stamp cannot self-attribute a meaningful response. Transcript mtime, payload cache counters, user/system/tool entries, shell execution, open/resume events, and learned/seed TTL guesses are never warmth sources | Every render first advances the `.bnd` sidecar over whatever the transcript grew by since its recorded size (re-reading the last 4 KiB so a boundary line cut at the previous end of file is not lost) and seeds the scan with the timestamp it holds, so a `/branch` or `/compact` whose re-emitted burst buries the boundary deeper than the window still resets the size. It then reads the live payload and checks the newest 256 KiB first. On a miss it jumps to the persisted per-model depth, then grows 4× only while no current-model response is found, capped at 8 MiB; a base-window hit resets the persisted depth to 256 KiB. A new qualifying response after the current-account cursor updates the account/model stamp; `/compact`, model/profile changes, forks, `/clear`, transcript append/removal, and TTL passage are therefore reflected on the next render. Parent-fork ancestry is cached with the resolved transcript identity and rechecked when its size or mtime changes; the event matrix below names each mechanism | `%` is dim while the number is INHERITED rather than measured: until a non-forked qualifying response exists strictly after the last `compact_boundary`, unless the transcript corroborates the payload — a fork-copied tail has no own response yet its copies ARE this session's context, so a post-boundary size measurement agreeing with the payload within the same 10% the size override uses proves the payload describes THIS context and un-dims it. A freshly compacted session has no such measurement until its first response, an unreadable tail yields none, a payload the transcript contradicts is the inherited case itself, and a payload carrying no size at all leaves its percentage with nothing to corroborate it — all four keep dimming. Display forms are mutually exclusive: warm shows only dim `→HH:MM` (Europe/Kyiv), never `<n>k`; known cold shows only restart price `<n>k`; unknown shows `? <n>k`, never an arrow. Cold and unknown share the warning scale: dim only below 90k where little is at stake, yellow 90–299k, red ≥300k — a just-reset context therefore renders as an ordinary `0%`/`0k`, with no placeholder wording of its own. A payload percentage that describes the discarded usage is dropped when there is no `.context_window_size` to recompute it from. A shortest TTL below 1h adds yellow `↓5m` to the warm time. Missing/unreadable transcript, missing model id, missing TTL bucket, absent/legacy account proof for a meaningful response, unprovable parent/account ancestry, mid-chat fork, or an assistant hidden beyond the 8 MiB bound is unknown. Malformed/in-progress, sidechain, synthetic, and zero-usage assistant entries are skipped and cannot extinguish earlier evidence | Warm time disappears at TTL expiry, account mismatch, a current-session `compact_boundary` at/after the response, a parent `compact_boundary` at/after an inherited fork anchor, or until the current model has a qualifying response. Token count disappears only when warm; a known-zero usage still renders `0k`, and `?` remains without a count when usage is unavailable. Never dropped by the fit; line-2 fit step 5 drops the percentage in its favour, never `↓5m` |
| `5h <pct>` + reset time | For `claudegpt`, read-only `$LLM_LIMITS_FILE` `vendors.codex.accounts[]` matched by `CLAUDEGPT_ACCOUNT`, never Claude payload limits or caches; that store is what the Codex quota kick below refreshes, since a gateway payload carries no `rate_limits` to merge. Otherwise merged rate-limit cache (`statusline-cache-rl` for main, `limits/<acct>.json` for claudeb) — live headers merged under lock each render | Every render merges newer headers, plus one liveness case: when the payload's `cost.total_cost_usd` is strictly greater than the value recorded at this session's last accepted merge (per session in `<statusline-cache>/rl-cost-<session_id>`, written only when a merge accepted something), a window whose `resets_at` and rounded percentage equal the cached ones is re-stamped `as_of: now, origin: session` — a session still calling the API is reading a window that has simply not moved, not replaying. A lower percentage or an older window is still rejected — except while a usage-reset marker `limits/<acct>.reset-at` (written by `bin/llm-reset-redeem`, honored for 8 days) stands: a reset lowers the week without moving `resets_at`, so then only a live render merges, any percentage of the same or a newer window, and a session whose `rl-cost` file predates the marker first has its spend re-based to now. The re-stamp is not login evidence; a merge that accepts a newer `five_hour` whose `resets_at` is later than the account's `auth_checked_at` also stamps `auth: {status: "ok"}` and deletes `auth_needed`/`auth_cause`/`auth_checked_at` — a live session is proof the human logged in, and nothing else in the background clears the flag. An idle session replays its last readings, so a window that opened before the logged-out verdict is not that proof and leaves the flag standing. A `claudegpt` render merges nothing: it reads the store the Codex quota kick refreshes, so its update trigger is that kick's cadence, never a header | Judged by `share/limits-view.sh` (shared-invariants y), the bucket's raw snapshot fed to `limits_bucket_expired`/`limits_bucket_stale`/`limits_effective_pct`: dimmed when expired (a real reset epoch ≤ now) or stale (`auth=expired`, `origin=cached`, `as_of` >1800s — the shared `LIMITS_STALE_FIVE_HOUR`), or when the `llm-limits.json` `stale` flag is set; an expired window shows its EFFECTIVE value `0%`, a placeholder reset below the epoch floor is neither expired nor a time, and a reset over a day past drops its time but not the verdict | Removed, separator included, when the account has no five-hour window at all (`limits_window_absent` in `share/limits-view.sh`: bucket null, or `used_pct` and `resets_at` both null — a Codex plan without the window, grok); `?` when the window exists but is unknown. Its reset time is shortened by line-2 fit step 2 and dropped by step 3 |
| `wk <pct>` + reset | For `claudegpt`, the same Codex account’s `weekly` bucket; otherwise same cache (`seven_day`), which the render stamps `origin: "session"` because the harness payload is a real server-side reading of both windows; a `seven_day` stamped `origin: "headers"` is unmeasurable by construction (shared-invariants n) and every reader discards it | Every render; for `claudegpt` the value itself moves on the Codex quota kick's cadence, like `5h` | Same shared view as `5h` with `LIMITS_STALE_WEEKLY` (21600s): dim when expired or stale, effective `0%` when expired | Never removed; `?` when unknown — including a discarded header-origin bucket, which renders `?` rather than a fabricated number. Reset label: line-2 fit steps 2 and 3 |
| `fb <pct>` + reset | `~/.llm-limits.json` `vendors.claude.accounts[].fable` | Every render reads the file; the store is written by the `llm-limits` collector (menu collect-on-open) and kept fresh by the statusline **store merge-kick** below | The collector's own fields, as the menubar renders them: value = `effective_pct`, dim when `stale` or `expired`; the file mtime >`LIMITS_STALE_FABLE` (21600s) is the backstop against a frozen store | Only for a non-`main` Claude account that has a `fable` bucket; absent for `claudegpt`. Reset label: line-2 fit steps 2 and 3 |
| `stale <age>` (red) | `~/.llm-limits.json` account row behind the store-backed cells: `vendors.codex.accounts[]` matched by `CLAUDEGPT_ACCOUNT`, else the non-`main` Claude account whose `fable` bucket renders `fb`; its account-level `as_of` (oldest measured bucket) | Every render reads the file | Shown when that age exceeds `LIMITS_STALE_ROUTING` (`7200`s, shared-invariants a/y) via `limits_store_stale_text`; age text is `limits_age_text`; never for an `auth_needed` account | Absent below the threshold, for `main`, and for a Claude account with no `fable` bucket; never dropped by the fit loop — it is an alarm |
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

## Work lines (below line 2)

The chat's own work, one line each under line 2. **Agent rows** (workers of any vendor, reviews,
media jobs, in that order, each oldest first) lead; **command rows** (`tests`, `shell`: the chat's
Bash calls, their tests, tests backgrounded out of them) follow, oldest first. A chat waits on a run
with a background `worker-run wait` / `review-bench wait` call, which no task row shows (handoff
`docs/handoffs/2026-10-08-relay-free-worker-rows.md`): the work line is the run's only drawing.

Layout (Egor approved the mock 2026-10-08):

```
com · opus · high — Speed up tracking r…  tests 1m 35s                       12m 36s  ↓ 184k
T1 · standard · bugs — llm-legs           all 5/7 opus ✓ gpt 2/4 pro ✗2 · ✓ done  16m 34s
judge: notcom · opus · high — abcdefg                                         1m 02s
media · pool · img·web — gen                                                  6m 54s
shell · token-map — pytest -q tests/test_track…                                  40s
+3 workers, 1 review, 1 media, 4 commands
```

- **Row:** `<head> — <title>` (no title, no `—`), then a right block. Head magenta on agent rows,
  cyan on command rows (logic, not LLM work — Egor, 2026-10-09); title bright on agent rows, dim on
  command rows, unaligned.
- **Right block:** columns shared by the visible rows — state (left, dim, `✓` green, `✗N` red, a
  late review group red), elapsed, tokens (right, dim), two spaces before each, an empty column
  takes none. It starts at `min(COLUMNS − STATUSLINE_FIT_MARGIN, widest row) − its width`.
- **Fit**, re-measured per step: titles shrink to `…`, then go; states take short forms; heads lose
  their tail to `…`, keeping the first word. Elapsed and tokens never shrink; past that floor rows
  overflow alike. Widths are cells (a non-UTF-8 locale switches to `C.UTF-8`/`en_US.UTF-8`).
- **Cap:** five rows, agent rows first; a judge row takes a slot, its pair hides whole as one review;
  the rest is ONE dim line, `+<n> workers, <n> reviews, <n> media, <n> commands`: nonzero kinds in
  that order, singular `1 worker`/`1 review`/`1 command`, `media` invariant, no "more", no total.
- **Values:** elapsed (and `tests <elapsed>`) from the start, every render: `45s`, `4m 05s`,
  `1h 02m`. Tokens, worker rows only: `↓ 900`,
  `↓ 37k`, `↓ 184k`, `↓ 1.2M` (floored); blank when unknown.

| Segment | Source of truth | Update trigger | Staleness / dim policy | Removal condition |
|---|---|---|---|---|
| command line `<class> · <repo> — <label>  [<n>/<m>[ ✗k]]  <elapsed>` (cyan head) | `work-<sid>` cache (`$STATUSLINE_CACHE_DIR`) written by `statusline-work-probe.sh` from the machine-wide `ps -axo pid=,ppid=,etime=,command=` snapshot (section "Probe snapshots"), at most 3s old; every start is the snapshot's own moment minus an etime, and so is the clock the probe judges pointers and journals ends by. An idle probe parses that snapshot once and skips lsof, git and jq; completed tests from the previous fresh cache still enter the test-history journal (`test-history.jsonl`: `{end, secs, who, repo, label}` plus `repo_root`, the main checkout off the same `git rev-parse` call that finds `<repo>` (`git_top` in `share/test-scope.sh`: the toplevel when `--git-dir` is the common dir — a main checkout, a submodule, a separate git dir — else the common dir's parent, so a linked worktree folds into its main checkout and a `.bare` layout into its project directory) (a worker row's off its workdir, once when it ends; absent outside git), so the Harness doctor folds a worktree's runs into their repository; a `suites` row adds `total`, `failed` and `ok`, `ok` read from the run's `.status` files once it is gone — `false` on any code 1–128 or 193+ (255 included), `true` when all `total` read 0, absent otherwise: short of its total, a code of 129–192 (a kill by signal), logs gone, no trusted log directory; no other row carries `ok`, the probe sees no exit code; every `suites` row with a trusted log directory, chat or worker, adds `suite_secs` `{<suite file>: seconds}` off the same `.status` files, which the Harness doctor's long pole and daily cost read). **Cache format: one tab-separated record per line**, `main <class> <start-epoch> <repo> <label> <done> <failed> <total> <logdir> <repo-root>` for a command line here (the agent records are in the rows below; the render reads fields 1–10) (`<logdir>` only for a `suites-<pid>` pointer stamped no earlier than its process started, and an old row and a new one naming different log directories are two runs; `<repo-root>` the journal's `repo_root`, empty outside git; the render ignores it; a `suites` or `suites queued` record adds its process pid as an eleventh field) and `run <run-id> <start-epoch> <label>` for a test under a worker run's setsid'd supervisor (`meta.json` `pid`), which makes that worker line's state `tests`, with `<logdir>` in the ninth field for a `suites` run under the same stamp rule and its pid in the eleventh; the probe sorts workers, reviews, media, `tests`, `shell`, each oldest first, and the render keeps that order with agent records ahead of the rest; readers split it on `\037`, since `read` folds an empty tab field (a repo `lsof` found no cwd for) into the next; a non-suites item with neither a repository nor a cwd whose process is gone (it ended between the snapshot and `lsof`) is dropped, so it is journaled once. **Whose:** a Bash tool call is a child of the chat's own `claude` (the walk from the render's `$PPID`) whose command runs the harness shell snapshot (`/shell-snapshots/snapshot-`), or a direct child that is itself a test (a call that `exec`s its runner replaces the snapshot shell) — so MCP servers and the statusline itself never count; a hook (a direct child running a script under a `/hooks/` directory) still going at 5s is a `shell` line labelled `hook <script name>`, since it holds the chat the way a call does; a test anywhere under one is the chat's; a test reparented to launchd (`&`, `nohup`) is the chat's when its environment (`ps -E`) carries `CLAUDE_PID=<that claude>` or `CLAUDE_CODE_SESSION_ID=<sid>`; a subtree under another `claude` is another chat's, and the orphan walk stops at `worker-run`, `review-bench`, `media-run`, `image-fanout` and the media scripts, whose rows carry what they run. **Which program:** argv[0], or for an interpreter or launcher (`bash`, `python3 -m`, `node`, `lua`, `env`, `nohup`, `time`, `timeout`, `nice`, `sudo`, `caffeinate`, `setsid`, `uv run`, `poetry run`, `npx`, each skipping its own option values) the script it runs — never the command text, so `sed -n 1p tests/test_x.sh` is no test. `tests` = `run-all`/`run-suites.sh` (label `suites`), `test_*.sh|.bash|.py|.lua` (label = its name), `pytest`, `vitest`, `jest`, `busted`, `bats`, `rspec`, `phpunit`, `ctest`, `python -m unittest`, `node --test`, `npm|pnpm|yarn|bun test` (past `-C`/`--dir`/`--filter`-style options and their values), `go|cargo|swift|mix|dotnet|deno test`, `playwright test`, `make test|check`, `xcodebuild test`; the top-most test wins, so a suite's own children fold into it. `shell` = any other Bash call of at least 10s, labelled by its oldest child's program plus the plain word right after it (`git push`; `curl --user x` is `curl`, an option's operand never shows), empty when the call runs builtins only. A call whose subtree runs `worker-run` or `review-bench` is not drawn: the run's own worker or review line carries it. One whose subtree runs `media-run`, `image-fanout` or a media script (`codex-image`, `gemini-image`, `grok-image`, `grok-video`, `gemini-video`, `gemini-music`, `gemini-sfx`, `gemini-listen`, `elevenlabs-<kind>`) — or a direct child of `claude` that is one, since `media-run` `exec`s its script under the same pid — is drawn as a `media` line (row below) and nothing else. `suites n/m ✗k` reads `suites-<pid>` (`<logdir>\t<total>\t<repo>\t<written-epoch>`, written by `share/run-suites.sh` for its own pid once it holds its machine-wide slot, renamed to `suites-<pid>.done` on exit, and deleted a minute later by a later run's start) and counts `<logdir>/*.status`, `✗k` those with a nonzero code, red; a `suites` process without a trusted pointer waits for its slot: its line reads `suites queued` from its process start, and its queueing never reaches the test journal: a run seen only queued that ended before the next probe is journaled off its `.done` pointer, timed from its stamp, and one killed while queued is not; a slotted run starts at the pointer's stamp, so queueing never counts as test time. `<repo>` is the basename of `git rev-parse --show-toplevel` from, first match wins: the directory of the test script a `test_*` run names (a relative path from its parent's working directory, so a test that `cd`s keeps its repository and its history row), the repository `run-suites.sh` was handed (its pointer), the process working directory (`lsof -d cwd`) — so `bash /r/review-bench/tests/run-all` from llm-legs is `review-bench`; `⧉ <name>` for a worktree under `.claude/worktrees/`, the directory's own basename outside git | Render fires the probe in the background when the cache is >4s stale (every other 3s refresh); `<elapsed>` is recomputed from the start column on every render. A `cd` inside a call moves `<repo>` on the next probe; `/clear` or `/resume` changes the session id and with it the cache, and the `CLAUDE_PID` claim keeps orphaned tests; model, account and rename events change nothing here | Cache mtime >15s → every work line hidden (probe presumed dead); a probe killed holding its lock loses it after 12s, inside that window | A finished process leaves on the next probe (≤~9s); cap, overflow line and fit as in Layout above |
| media line `media · <acct> · <what>·<where> — <gen\|edit>  <elapsed>`, fan-out `media · fanout · img\|vid — all  <done>/<total>[ ✗k]  <elapsed>` (magenta head) | `bin/media-run` writes `$STATUSLINE_CACHE_DIR/media-<its pid>` before it `exec`s, one tab-separated line `<start-epoch> <tag> <label> <state file> <job id>`: tag `<acct> · <what>·<where>` from `worker_media_tag` (`share/worker-model.sh`), never a model version — `img·web` / `img·cli` (codex-image by `--route`, else the manifest's first route), `img·gem`, `img·grok`, `vid·veo` / `vid·omni` (gemini-video, by `--model`), `vid·grok`, `mus·app` / `mus·flow` (gemini-music, `--route flow` or `--model lyria-3-pro`), `sfx`, `listen`; `<acct>` is the job's `--account`, else for a CLI image route `worker-pick --account <vendor> --role image`, else `pool` (the web, Flow and app routes rotate their own profiles); label `edit` with `--ref`/`--resume`/`--edit`/`--extend`/`--for-video`, else `gen`; a fan-out (several vendors, `--takes`, `--jobs`) writes tag `fanout · img\|vid`, label `all` and state `fanout.state.json` in the work store (`image_leg_work_file`, `{kind, cells: [{vendor, account, status, exit, job, take, request, dest}]}`, one cell per launch, so a packed Flow `--count` is one, rewritten by `image-fanout` on every cell change, none on `--dry-run`), counted as `<done>` = cells `done` or `failed`, `✗k` = `failed`, `<total>` = all cells but `spare-cancelled` (a spare ended once enough takes landed) — so a cell `waiting` for a `--max-parallel` slot is pending, never work in flight. The work probe turns a media process of this chat's into the record `main media <start> <tag> <label> <done> <failed> <total>` and sorts it after the worker and review records | Same probe cadence as every work line; the fan-out counts re-read the state file each probe | A pointer stamped earlier than its process started (3 s slack) belongs to a reused pid and draws nothing; a pointer with no tag, or none at all, draws nothing — the job then has no line rather than a wrong one; pointers older than a day are pruned by the next `media-run` | The process ends → off on the next probe. Head `media · <tag>` (the account it spends), the label the title |
| worker line `<acct> · <model> · <effort> — <title>  <start\|queued\|working\|tests <elapsed>>  <elapsed>  ↓ <tokens>` (magenta head) | Run dirs under `$WORKER_RUN_DIR` (default `~/.cache/claude-worker-runs`). Which runs: every dir with no `exit_code` whose `launcher` is this session id, plus every run a `worker-run wait <run-id>` in this chat's tree waits on; a run is live while `meta.json` `pid` is in the ps snapshot and started within 30 s of `pid_started_at` (`PID_START_SLACK`), one with no pid yet only for 300 s after its start. Record `main worker <start> <head> <title> <state> <tests-start> - <tokens>`: start = `started_epoch`, else `started_at`; head = `tag` line 1 (`worker · <last 7 of run id>` before it), a light run's (`meta.json` `light`) recast `light <role> · <model> · <acct>` (`flashNM` → `N.M-flash`, `gemini-<v>-<flash\|pro>[-<effort>]` → `<v>-<flash\|pro>`), `fix: <head>` with a `round_id`, whose last 7 are the title; title = `title` line 1, else the brief's first non-empty line past its `KEY:` header lines, a `RESUME <id>:` line contributing only its text; state `tests` (from `<tests-start>`) while a `run <run-id>` record exists, else `queued` while `meta.json` has `slot_at` and no `cli_pid`, else `start` in phase `start`, else `working`; tokens = the `tokens` integer (the worker's own total), blank when absent or not a number. Builtin reads only — no jq, no transcript | Same probe cadence; every field re-read each probe | Cache mtime >15s → hidden like every work line | `exit_code` written, the supervisor gone or recycled, or the waiting process gone for a run another chat launched → off on the next probe |
| review line `<tier> · <composition> · <lens> — <title>  <state>  <elapsed>`, in the judge phase plus `judge: <judge head> — <run id last 7>  <elapsed>` (magenta heads) | review-bench progress documents `${WORKER_STATS_DIR:-$CLAUDEB_DIR/worker-stats}/progress/*.json`. Runs: each `review-bench wait <run-id>` in this chat's tree, and each document whose `session` is this chat, `state` `running` and a `heartbeat_epoch` no older than 300 s (review-bench's `PROGRESS_STALE_AFTER_S`; a dead launcher's document stays `running`). Record `main review <start> <head> <title> <state> <short> <judge head> <judge since> <run id>`: start = `started_epoch`; head = `tier` (`T?`) · `composition` (`standard`) · `lens` (`task` for a hunt, else `review`); title = a hunt's `task` (or `title`) first line, else its `repo` basenames, `, `-joined. State: `✗ dead` (`failed`), `✓ report <confirmed>` (`done`), `report` (phase `report`), else `all <finished>/<cells>` (finished: `done` or `failed_cells`) plus per cell group in first-seen order (label: id cut at `#`, vendor prefix `claude\|codex\|oc\|opencode\|gemini-` dropped, cut at `-`) ` <label> ✓` all clean, ` ✗N` all failed, else ` <read>/<total>[ ✗N][ verify]` (`chunks` counted; `verify` while `verifying[cell]` runs); a group with a pending cell late by shared-invariants row `u` (since `started_epoch` or `chunk_started`, past 3 × `expected` median and 120 s) is `{…}`, red; short = `all <finished>/<cells>`. Phase `judge`/`report`, not failed/cancelled: both gain ` · ✓ done`; judge head `account · model · effort`; since = `phase_at`, else `judge.ts`, else the last cache's, else now; the review's elapsed stops there, the judge row below is timed from it. A waited run with no document reads `review · <last 7 of run id>` from the wait's start. One jq per matching document | Same probe cadence | Cache mtime >15s → hidden | The wait ends and the document leaves `running` or stops beating → off on the next probe |

## Task rows (subagentStatusLine, `bin/subagent-statusline.sh`)

The harness hands the renderer only `local_agent` tasks (never background Bash or Monitor) and lets it
rewrite the body of each id it received. A row exists only while the harness lists the task as
`running`: a completed, failed, killed or otherwise finished task produces no row (the harness keeps
finished agents listed for hours; the rows show only what is going on). The renderer answers such a
task with `{"id": <id>, "content": ""}` — the harness draws its own native row for any listed id the
renderer says nothing about, and an empty content is the one answer that removes the row (Claude Code
2.1.283 filters rows on `content !== ""`; `completed`/`failed`/`killed` are its terminal statuses).
Worker, review and image runs have no task row: they are the chat's own background Bash calls and
are drawn as work lines (above).

Every running task is painted `<tag>[ — <title>][ · <state>] · <elapsed>[ · ↓ tok]` — tag magenta,
the rest dim but the title. A number always stands right of its element (`edit 3`; only `↓ 12k tok`
leads), and ` · ` only separates fields. The tag comes from `~/.cache/claude-worker-tags/<sid>/<task-id>`
line 1, else the tag prefix of the hook-rewritten description, else `agent · <model-short> · <account>`
from the harness `model` and the session account (`CLAUDE_LIMITS_ACCOUNT`, else the `CLAUDE_CONFIG_DIR`
basename, else `main`); a `fork · ` or `agent · ` tag always shows the harness model, the one doing the
work. The title is the task's `description` with its tag prefix (`<tag>: ` or `<tag> — `) stripped; the
harness `label` (the agent's momentary activity) is never read, so concurrent agents stay
distinguishable.

| kind | tag (writer) | state (source) |
|---|---|---|
| fork | `fork · <model> · <account>` (tool model, else the parent transcript's; the renderer shows the harness model) | `explore`, then `edit N` from the tag line `edit=N` (`statusline-workdir-hook` PostToolUse Edit/Write/NotebookEdit of that agent) |
| Workflow agent, teammate, anything else | the tag cache line, else `agent · <model> · <account>` | `edit N` when counted, else none |

Fit: budget = `columns − SUBAGENT_ROW_RESERVE` (default 4, the same margin as the top statusline's
`STATUSLINE_FIT_MARGIN`, pinned equal by `tests/test_statusline_hooks.sh`; the harness passes `columns: 67` for an
~80-column chat). Over budget a row drops, in order: the title tail (`…`) down to `TITLE_FLOOR` (20)
characters, then the title tail to nothing (the `—` with it); the token count; the elapsed time. The
tag and the state are never dropped.

State files: `worker-run` rewrites `state.json` (tmp + rename) on start, on every `wait` and at the
end: `{phase, exit_code, session, account, model, effort, round_id, started_epoch, ts}`; `session`
is the launching chat (`CLAUDE_LAUNCHER_SESSION`, else `CLAUDE_CODE_SESSION_ID`). At start it also
writes `title` (the brief's first non-header line, ≤100 characters) and, while a `wait` runs,
`tokens` (the worker's own total, rewritten when its session log changes); both feed the worker
work line. Every tag-file rewrite — `worker-tag-hook` and the `edit=N` count —
holds the session directory's `.claim.lock` (mkdir lock; one older than a minute is broken once, a
live one outwaited ~3 s — `WORKER_TAG_LOCK_TRIES` × 0.1 s, default 30 — and the write skipped).

Gates bound to these rows: `worker-spawn-hook` is the one owner of the native-type policy: it
admits `fork` alone and denies (`permissionDecision: "deny"`) every other type — the retired relays
with the direct command that replaces each, `Explore`, `Plan`, `general-purpose` and
`claude-code-guide` included; a Workflow call is untouched; `worker-limit-gate` judges no native
type (shared-invariants row `bt`). `worker-launch-gate` reads a Monitor's command through the same
masked scan as a Bash call: a Monitor on `worker-run wait` or `review-bench wait` in command position
is denied with the background-Bash spelling, and every owned spelling behind it (`worker-run start`,
the media scripts, `light-research`) meets the same checks a Bash call does. Foreign runs (another
chat's review) are drawn in no row or line of this chat.

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

## Render timing journal (background, not a rendered segment)

Every render appends `<start_us>\t<end_us>\t<session_id>\t<cpu_ms>` (`$EPOCHREALTIME`; cpu_ms = bash
`times` shell+children user+sys, `-` under bash < 5.3) to `${HARNESS_DOCTOR_DIR:-~/.cache/harness-doctor}/statusline/<local YYYY-MM-DD>.tsv`
for the Harness doctor, which owns pruning. One `printf` append, a `mkdir -p` only when it fails, no
lock; a failed write is silent and never changes the output or exit code.

## Probe snapshots (background, not a rendered segment)

Every chat's probes read one machine-wide copy of what the whole machine looks like, in
`$STATUSLINE_CACHE_DIR`, through `snapshot_take` in `share/statusline-probe.sh`: a header line
`<epoch>\t<meta>\t<key>`, then the body. `ps-snapshot` is `ps -axo pid=,ppid=,etime=,command=`
(key: the ps command, so a test's fake never meets the real table), read by the work probe at most
3s old and by the ports probe at most 10s old. `ports-snapshot` is the user's TCP listeners
(`lsof -a -u $UID -iTCP -sTCP:LISTEN -nP`, meta `1`, or `0` with no body when none listen) and,
before a `\036lsof` marker line, the `lsof -a -d cwd -Fn` working directory of each listening pid in
chunks of 40; key the lsof command, at most 10s old. A stale or differently keyed snapshot is rebuilt
by whichever probe asks first, into `<name>.tmp.<pid>` renamed over the old one, no lock: two probes
asking at once both build and the last rename wins — a duplicate run, never a torn file. An empty ps
answer is a failed ps and is never published.

## Probe journal (background, not a rendered segment)

Every background run of the statusline appends `<start_us>\t<wall_ms>\t<cpu_ms>\t<kind>` to
`${SPEED_DOCTOR_DIR:-~/.cache/speed-doctor}/statusline-probes/<local YYYY-MM-DD>.tsv` through
`probe_journal`: kinds `ports` and `work` (each probe run that took its session lock, from the probe's
EXIT trap), `debt`, `autonomy`, `unpushed` and `codex-kick` (each refresh that took its lock, at its
end). `cpu_ms` is that process's own CPU and its waited children's (bash `times`, `-` under bash < 5.3)
— the render's own `times` never sees it, the work having left the render. Builtins only: one `printf`
append, a `mkdir -p` only when it fails, no lock. The Speed doctor folds it into its Background line
(runs and CPU-min/day per kind, added to the statusline's background share) and prunes it with its
other journals past 35 days. The store merge-kick keeps its own `merge-kick/` journal.

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
- **Work lines see processes, not intent.** A test run a worker of a run with
  no task row here starts is drawn as this chat's work line when its environment
  still names this chat's `claude`; a live run whose wait ended has no line
  until the Stop ask's background wait; a runner outside the list above is
  `shell`, and a call faster than one probe (~6s) is never drawn. WebFetch,
  WebSearch, MCP calls and compaction run inside `claude` or a long-lived server
  with no process per call, so no line or row can show them: the harness
  spinner is their only surface.
- **Cache scan is bounded.** An assistant response hidden behind more than
  8 MiB of later transcript data renders unknown until a newer qualifying
  response appears; the renderer never performs an unbounded full scan.

## Removed segments (do not re-add without solving the freshness failure)

- **Review run counter `[T<N> [max]] [✓|✗] <done>/<total>` + dim ` +N`** (removed 2026-10-06, owner decision). Read every `review-bench` progress document of the shown tree's repository each render to draw a run's progress at the top of the line; the run's own row already drew the same run with its cells, so the top copy was the same news twice at a render-path cost. Do not restore it; the review work line is the review's one surface.

- **Per-chat review debt `N`** (removed 2026-10-05, owner decision). `review-flow-gate.sh verdict` summed this chat's debt over its `.repos` list; debt is per repository now, a dim `N` beside the diff. Do not restore a per-chat count.
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
  while the question the label asks is per session. Per-repository debt `N`
  answers it now, so the badge was deleted rather than
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
