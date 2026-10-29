# worker-run, workdir snapshots and commit attribution; sourced by bin/worker-run in place, so an edit here
# runs its own suites rather than every suite of worker-run (Egor 2026-10-23, 2026-10-28).

# How many of those paths the line still spells out itself. Past it the reader is pointed at the
# record instead: the list is there to be pasted, and one nobody can read at the end of a report is
# not one anybody pastes.
UNNAMED_INLINE_MAX=${WORKER_RUN_UNNAMED_INLINE_MAX:-25}

persist_run_files() {
  local directory="$1" workdir snapshot reason top path nonrepo_named=''
  workdir=$(jq -r '.workdir' "$directory/meta.json" 2>/dev/null)
  if snapshot_workdir "$directory" "$workdir" after; then
    compute_snapshot_files "$directory" "$workdir"
  else
    RUN_FILES_LIST=''
    RUN_FILES_REASON='the workdir after snapshot could not be established'
  fi
  record_worker_session "$directory"
  record_bash_caps "$directory"
  if [ -z "$workdir" ] || [ "$workdir" = null ]; then
    RUN_FILES_LIST=''
    RUN_FILES_REASON='the run recorded no workdir to resolve its files against'
  fi
  snapshot=$RUN_FILES_LIST
  reason=$RUN_FILES_REASON
  # A snapshot detects change, never its author; an unreadable transcript names no owner.
  compute_transcript_files "$directory"
  RUN_LISTING_LIST=$(sort -u <(sed '/^$/d' <<<"$RUN_FILES_LIST") \
                             <([ -z "$workdir" ] || [ "$workdir" = null ] ||
                                 shell_write_rows "$directory" "$workdir" "$snapshot"))
  RUN_LISTING_REASON=$RUN_FILES_REASON
  RUN_LISTING_PARTIAL=$RUN_FILES_PARTIAL
  # This attempt's transcript names only its own calls: a reroute took a new session and restamped
  # started_at, so the walled attempt's listing comes from what its own pass kept.
  RUN_LISTING_LIST=$(sort -u <(sed '/^$/d' <<<"$RUN_LISTING_LIST") <(sed '/^$/d' "$directory/listed" 2>/dev/null) \
                             <(run_commit_paths "$directory" "$workdir" | sed '/^$/d'))
  [ -n "$RUN_LISTING_REASON$RUN_LISTING_PARTIAL" ] || RUN_LISTING_PARTIAL=$(cat "$directory/listed-partial" 2>/dev/null)
  printf '%s\n' "$RUN_LISTING_LIST" >"$directory/listed" 2>/dev/null || :
  [ -z "$RUN_LISTING_REASON$RUN_LISTING_PARTIAL" ] ||
    printf '%s\n' "${RUN_LISTING_REASON:-$RUN_LISTING_PARTIAL}" >"$directory/listed-partial" 2>/dev/null || :
  RUN_FILES_EXTERNAL=''
  top=$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null) || top=''
  while IFS= read -r path; do
    case "$path" in
      /*)
        [ -z "$top" ] || [[ "$path" != "$top"/* ]] || continue
        RUN_FILES_EXTERNAL+="$path"$'\n'
        ;;
      ?*)
        # A workdir that is no repository (the parent of several) folds only through its families,
        # which read the named paths from files-external. Kept out of RUN_FILES_EXTERNAL: its
        # PARTIAL line would let `claim` accept unchecked paths of a workdir that lost its .git.
        [ -n "$top" ] || [ -z "$workdir" ] || [ "$workdir" = null ] || nonrepo_named+="${workdir%/}/$path"$'\n'
        ;;
    esac
  done <<<"$RUN_LISTING_LIST"
  record_made_worktrees "$directory"
  record_workdir_escape "$directory"
  RUN_FILES_LIST=$snapshot
  RUN_FILES_REASON=$reason
  RUN_FILES_COTENANT=''
  RUN_FILES_UNNAMED=''
  RUN_OTHERS_NAMED=''
  if [ -z "$reason" ]; then
    RUN_FILES_LIST=$(comm -12 <(sed '/^$/d' <<<"$snapshot" | sort -u) \
                              <(sed '/^$/d' <<<"$RUN_LISTING_LIST" | sort -u))
    if [ -z "$RUN_LISTING_REASON" ] && [ -z "$RUN_LISTING_PARTIAL" ]; then
      RUN_FILES_COTENANT=$(comm -23 <(sed '/^$/d' <<<"$snapshot" | sort -u) \
                                    <(sed '/^$/d' <<<"$RUN_LISTING_LIST" | sort -u))
    else
      RUN_OTHERS_NAMED=$(others_named_paths "$directory" "$top" "${EPOCHSECONDS:-$(date +%s)}")
      RUN_FILES_UNNAMED=$(comm -23 <(sed '/^$/d' <<<"$snapshot" | sort -u) \
                                   <(sed '/^$/d' <<<"$RUN_LISTING_LIST" | sort -u) |
                          unowned_rows "$workdir" "$RUN_OTHERS_NAMED")
    fi
  fi
  {
    [ -z "$workdir" ] || [ "$workdir" = null ] || printf 'WORKDIR: %s\n' "$workdir"
    [ -z "$RUN_FILES_REASON" ] || printf 'UNKNOWN: %s\n' "$RUN_FILES_REASON"
    if [ -z "$RUN_FILES_REASON" ] && { [ -n "$RUN_LISTING_REASON" ] || [ -n "$RUN_LISTING_PARTIAL" ]; }; then
      printf 'PARTIAL: %s\n' "${RUN_LISTING_REASON:-$RUN_LISTING_PARTIAL}"
    fi
    [ -z "$RUN_FILES_EXTERNAL" ] ||
      printf 'PARTIAL: transcript names writes outside the snapshotted repository; see files-note\n'
    [ -z "$RUN_FILES_LIST" ] || printf '%s\n' "$RUN_FILES_LIST"
  } >"$directory/files.tmp.$$" 2>/dev/null &&
    mv -f "$directory/files.tmp.$$" "$directory/files" 2>/dev/null ||
    rm -f "$directory/files.tmp.$$" 2>/dev/null
  printf '%s' "$RUN_FILES_EXTERNAL$nonrepo_named" >"$directory/files-external" 2>/dev/null || :
  record_workdir_dirt "$directory" "$workdir"
  [ -n "$RUN_FILES_REASON" ] || split_foreign_commits "$directory" "$workdir"
  transcript_crosscheck "$directory"
  return 0
}

# The files of the commits this run made itself: HEAD moved in its window and the commit's subject
# stands in one of its own shell commands. A transcript names a `git commit`, never what it took, so
# a run that wrote through python and committed it all listed none of it.
run_commit_paths() { # directory workdir
  local directory="$1" workdir="$2" top rel before after sha subject needle path
  [ -n "${RUN_SHELL_COMMANDS:-}" ] || return 0
  before=$(cat "$directory/head-before" 2>/dev/null) && [ -n "$before" ] || return 0
  after=$(cat "$directory/head-after" 2>/dev/null) && [ -n "$after" ] && [ "$after" != "$before" ] || return 0
  top=$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null) || return 0
  rel=${workdir%/}
  case "$rel" in "$top"/*) rel=${rel#"$top"/} ;; *) rel='' ;; esac
  while IFS=$'\t' read -r sha subject; do
    [ "${#subject}" -ge 16 ] || continue
    needle=$(jq -Rr '@json' <<<"${subject:0:60}") || continue
    needle=${needle:1:${#needle}-2}
    grep -qF -- "$needle" <<<"$RUN_SHELL_COMMANDS" || continue
    git -C "$top" diff-tree --no-commit-id --no-renames --name-only -r "$sha" -- 2>/dev/null |
      while IFS= read -r path; do top_rel_spelling "$top" "$rel" "$path"; printf '\n'; done
  done < <(git -C "$top" log --format='%H%x09%s' "$before..$after" -- 2>/dev/null)
}

# A worktree the run made after launch is its own to write (ledger W3), granted only when the run's
# own `worktree add` names it and it did not exist at launch: absent from the floor's listing of the
# workdir's repository, or, in a repository the floor never listed, its git admin directory born
# after the run started. One another chat made meanwhile has no such command, so a write there still
# reads as escaped.
record_made_worktrees() { # directory
  local directory="$1" path root name tree admin born started made=''
  started=$(jq -r '.pid_started_at // .started_at // 0' "$directory/meta.json" 2>/dev/null)
  [[ "$started" =~ ^[0-9]+$ ]] || return 0
  while IFS= read -r path; do
    [[ "$path" =~ ^(/.+)/\.claude/worktrees/([A-Za-z0-9._-]+)/ ]] || continue
    root=${BASH_REMATCH[1]} name=${BASH_REMATCH[2]} tree=${BASH_REMATCH[1]}/.claude/worktrees/${BASH_REMATCH[2]}
    printf '%s\n' "${RUN_SHELL_COMMANDS:-}" | grep -F 'worktree add' |
      grep -qE "(^|[^A-Za-z0-9._-])\.claude/worktrees/${name//./\\.}([^A-Za-z0-9._-]|\$)" || continue
    if grep -qxF -- "$root" "$directory/worktrees-before" 2>/dev/null; then
      ! grep -qxF -- "$tree" "$directory/worktrees-before" || continue
    elif [ -e "$tree/.git" ]; then
      admin=$(git -C "$tree" rev-parse --absolute-git-dir 2>/dev/null) &&
        born=$(stat -c %W "$admin" 2>/dev/null || stat -f %B "$admin" 2>/dev/null) &&
        [[ "$born" =~ ^[0-9]+$ ]] && [ "$born" -ge "$started" ] || continue
    else
      [ -e "$root/.git" ] || continue
    fi
    made+="$tree"$'\n'
  done < <({ printf '%s\n' "${RUN_FILES_EXTERNAL:-}"; sed '/^$/d; s|$|/|' <<<"${RUN_FILES_OUTSIDE:-}"; } | sort -u)
  [ -n "$made" ] || return 0
  meta_update "$directory" '.worktrees_made = ((.worktrees_made // []) + $made | unique)' \
    --argjson made "$(printf '%s' "$made" | jq -Rn '[inputs | select(length > 0)]')" || :
}

# A run that worked somewhere other than the workdir it was given, kept beside the run so the two
# readers who care hear it: whoever prints a report, and whoever later wonders why the workdir is
# clean. agy did this SILENTLY (live 2026-08-24) — handed a directory it does not trust it moved
# into the first --add-dir and reported success — and a silent success over an untouched workdir is
# the one failure a launcher cannot see. One line per escaped destination, unioned across attempts.
record_workdir_escape() { # directory
  local directory="$1"
  [ -n "$RUN_FILES_ESCAPE" ] || return 0
  # A worktree the run made is its own grant (W3), whichever place it named first: a shell-only
  # codex run names the main checkout it ran `worktree add` from before the worktree itself.
  if jq -r '.worktrees_made[]? // empty' "$directory/meta.json" 2>/dev/null |
    awk 'NR == FNR { if ($0 != "") made[$0]; next }
         { for (tree in made) if ($0 == tree || index($0, tree "/") == 1) found = 1 }
         END { exit !found }' - <(printf '%s\n' "${RUN_FILES_OUTSIDE:-}"); then
    RUN_FILES_ESCAPE=''
    return 0
  fi
  grep -qxF -- "$RUN_FILES_ESCAPE" "$directory/workdir-escape" 2>/dev/null && return 0
  printf '%s\n' "$RUN_FILES_ESCAPE" >>"$directory/workdir-escape" 2>/dev/null || :
  return 0
}

# Off the live answer where one was just computed, off the record otherwise, so every report says it
# — the one `wait` prints the moment the run ends included, which computes no file list of its own.
workdir_escape_line() { # directory
  local escaped
  {
    [ -z "${RUN_FILES_ESCAPE:-}" ] || printf '%s\n' "$RUN_FILES_ESCAPE"
    [ ! -r "$1/workdir-escape" ] || sed '/^$/d' "$1/workdir-escape"
  } | awk '!seen[$0]++ {
    printf "WORKDIR-ESCAPE: the run named no path inside its own workdir; it worked in %s\n", $0
  }'
}

# Same arms as ../claude-setup/hooks/lib/review-journal.sh `rj_path_shape_ok`: a path the reader
# would skip must never land in `files` and then vanish from the ledger. It stays out of the
# listing and goes into the snapshot's `unshaped` digest instead: a run that changed one fails the
# snapshot closed, and one stray `-` file no longer blinds every run in its tree (logo-vectorizer-bench
# 2026-10-01: 47 runs a day folded as `snapshots unreadable`). NUL-terminated entries in, `skip`
# bytes cut off each; an empty unshaped-out fails on the first unshaped path instead.
path_shape_split() { # skip unshaped-out
  python3 -c '
import locale, re, sys

try:
    locale.setlocale(locale.LC_CTYPE, "")
except locale.Error:
    pass
cntrl = rb"[\x00-\x1f\x7f]"
if locale.nl_langinfo(locale.CODESET) == "UTF-8":
    cntrl += rb"|\xc2[\x80-\x9f]"
unshaped_re = re.compile(rb"\A(?:\.\.?\Z|[/~-]|\.\./)|/\.\./|/\.\.\Z|" + cntrl)
skip, out = int(sys.argv[1]), sys.argv[2]
shaped, unshaped = [], []
for entry in sys.stdin.buffer.read().split(b"\0")[:-1]:
    path = entry[skip:]
    if path:
        (unshaped if unshaped_re.search(path) else shaped).append(path)
if unshaped:
    if not out:
        sys.exit(1)
    with open(out, "ab") as fh:
        fh.write(b"".join(path + b"\0" for path in unshaped))
sys.stdout.buffer.write(b"".join(path + b"\n" for path in shaped))
' "$1" "$2"
}

# A symlink's git blob is the link text, never the target. `test -f` follows the link, so a
# symlink-to-dir or a dangling link hashed as `-` and read as a deletion.
# NUL-terminated top-relative paths in, `<sha>\t<path>` rows out; `-` where git cannot hash one.
hash_workdir_paths() { # top
  python3 -c '
import os, stat, subprocess, sys, tempfile

top = sys.argv[1]
paths = [path for path in sys.stdin.buffer.read().split(b"\0") if path]
shas = [b"-"] * len(paths)


def hash_into(indices, names, flags):
    git = ["git", "-C", top, "hash-object", "-w"] + flags

    def one(i):
        run = subprocess.run(git + ["--", names[i]], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        if run.returncode == 0 and run.stdout.strip():
            shas[i] = run.stdout.strip()

    # --stdin-paths unquotes a line opening with a double quote. A missing path stops the batch
    # with the shas before it printed, so the rest re-batches after that one path alone.
    pending = []
    for i in indices:
        if names[i].startswith(b"\"") or b"\n" in names[i]:
            one(i)
        else:
            pending.append(i)
    while pending:
        run = subprocess.run(git + ["--stdin-paths"], input=b"".join(names[i] + b"\n" for i in pending),
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        got = run.stdout.split()
        done = len(pending) if run.returncode == 0 and len(got) == len(pending) else min(len(got), len(pending) - 1)
        for i, sha in zip(pending[:done], got):
            shas[i] = sha
        if done < len(pending):
            one(pending[done])
        pending = pending[done + 1:]


root = os.fsencode(top) + b"/"
files, links = [], []
for i, path in enumerate(paths):
    try:
        mode = os.lstat(root + path).st_mode
    except OSError:
        continue
    if stat.S_ISLNK(mode):
        links.append(i)
    elif stat.S_ISREG(mode):
        files.append(i)
hash_into(files, paths, [])
if links:
    with tempfile.TemporaryDirectory() as tmp:
        texts = {}
        for i in links:
            try:
                text = os.readlink(root + paths[i])
            except OSError:
                text = b""
            texts[i] = os.path.join(os.fsencode(tmp), b"%d" % i)
            with open(texts[i], "wb") as fh:
                fh.write(text.rstrip(b"\n"))
        hash_into(links, texts, ["--no-filters"])
sys.stdout.buffer.write(b"".join(sha + b"\t" + path + b"\n" for sha, path in zip(shas, paths)))
' "$1"
}

hash_workdir_path() { # top path
  local row
  row=$(printf '%s\0' "$2" | hash_workdir_paths "$1" 2>/dev/null) || row=
  row=${row%%$'\t'*}
  printf '%s\n' "${row:--}"
}

# The uncommitted paths of the repository the workdir belongs to, one per line, spelled against
# that repository's top — which is what `--porcelain` answers in, whatever subdirectory the run was
# launched from. Untracked files are listed individually (`-uall`): a file the run created and
# nothing tracks is exactly the work that reaches no other record at all.
#
# Nonzero where git could not answer at all, never an empty answer: read as a clean tree, a status
# that failed at launch makes every file Egor already had open content this run gained.
workdir_dirty_paths() { # workdir [unshaped-list]
  local answer
  [ -n "${1:-}" ] && [ "$1" != null ] || return 1
  answer=$(git -C "$1" status --porcelain --no-renames -uall -z 2>/dev/null |
    path_shape_split 3 "${2:-/dev/null}"; status=("${PIPESTATUS[@]}");
    [ "${status[0]}" = 0 ] && [ "${status[1]}" = 0 ]) || return 1
  [ -z "$answer" ] || printf '%s\n' "$answer" | sort -u
}

# The content standing at each already-uncommitted path, as `<blob sha>\t<path>`, so the snapshot
# at the end can tell a file this run REWROTE from one it merely found dirty. Without it a worker
# whose vendor keeps no per-file record and whose fix pass edits files that were already dirty —
# which is every fixing pass over a review scope — reaches no store at all: the launching chat saw
# its own worker's fixes as debt owed by nobody, and a closed round covered none of them (live case
# 2026-08-22). A path git cannot hash (gone, a directory, a special file) records `-`, which
# compares equal only to itself.
# A paths-out file gets workdir_dirty_paths' answer whenever the status itself succeeded, even if
# the hashing after it fails.
workdir_dirty_shas() { # workdir [unshaped-digest-out] [paths-out]
  local top paths
  if [ -n "${2:-}" ]; then
    : >"$2.list" && paths=$(workdir_dirty_paths "$1" "$2.list") || { rm -f "$2.list"; return 1; }
  else
    paths=$(workdir_dirty_paths "$1") || return 1
  fi
  [ -z "${3:-}" ] || { [ -z "$paths" ] || printf '%s\n' "$paths"; } >"$3" 2>/dev/null || rm -f "$3"
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) && [ -n "$top" ] ||
    { [ -z "${2:-}" ] || rm -f "$2.list"; return 1; }
  if [ -n "${2:-}" ]; then
    unshaped_digest "$top" "$2.list" >"$2" || { rm -f "$2.list"; return 1; }
    rm -f "$2.list"
  fi
  [ -n "$paths" ] || return 0
  printf '%s\n' "$paths" | tr '\n' '\0' | hash_workdir_paths "$top"
}

unshaped_digest() { # top list
  local path
  [ -s "$2" ] || return 0
  while IFS= read -r -d '' path; do
    printf '%s\0' "$path"
    hash_workdir_path "$1" "$path"
  done <"$2" | git -C "$1" hash-object --stdin
}

snapshot_workdir() { # directory workdir side
  local directory="$1" workdir="$2" side="$3" shas head
  # A moved unshaped digest fails the after side itself: a claim reads an absent head-after as "no
  # snapshot" and takes the --complete/PARTIAL path, while a written one demands a diff never computed.
  shas=$(workdir_dirty_shas "$workdir" "$directory/unshaped-$side.tmp.$$") &&
    { [ "$side" != after ] ||
      [ "$(cat "$directory/unshaped-before" 2>/dev/null)" = "$(cat "$directory/unshaped-$side.tmp.$$")" ]; } &&
    mv -f "$directory/unshaped-$side.tmp.$$" "$directory/unshaped-$side" || {
    rm -f "$directory/unshaped-$side.tmp.$$"
    [ "$side" = after ] && rm -f "$directory/dirty"
    return 1
  }
  head=$(git -C "$workdir" rev-parse --verify --quiet HEAD 2>/dev/null) || head=''
  { [ -z "$shas" ] || printf '%s\n' "$shas"; } >"$directory/dirty-$side-shas.tmp.$$" &&
    mv -f "$directory/dirty-$side-shas.tmp.$$" "$directory/dirty-$side-shas" || return 1
  printf '%s\n' "$head" >"$directory/head-$side.tmp.$$" &&
    mv -f "$directory/head-$side.tmp.$$" "$directory/head-$side" || return 1
  [ "$side" != after ] || pack_loose_objects "$workdir"
}

# The snapshots' `hash-object -w` blobs are unreachable, and `gc --auto` leaves unreachable objects
# younger than gc.pruneExpire loose, so a repository nobody commits to never packs them. The
# loose-objects task packs any loose object; gc.auto keeps git's threshold, its 0 still means never.
pack_loose_objects() { # workdir
  local at
  at=$(git -C "$1" config --get gc.auto 2>/dev/null) || at=6700
  # Outlives the run on purpose: still carrying the run's id, end_run_orphans would end it mid-pack.
  (env -u WORKER_RUN_ID nice -n 10 sh -c 'git -C "$1" -c maintenance.loose-objects.auto="$2" maintenance run --auto \
    --task=loose-objects --quiet && git -C "$1" prune-packed --quiet' _ "$1" "$at" </dev/null >/dev/null 2>&1 &)
}

# `<before>\t<after>\t<path>` for each top-relative path on stdin, each side the path's first row in
# that side's dirty listing, else its blob in that side's HEAD, else `-`; with `changed`, the path
# alone and only where the two differ, with `changed-rows` the whole row. One pass: a lookup per path
# rescans the listing, and a checkout with thousands of dirty paths took minutes per fold.
snapshot_pairs() { # directory top [changed|changed-rows]
  python3 -c '
import subprocess, sys

directory, top = sys.argv[1], sys.argv[2]
mode = sys.argv[3] if len(sys.argv) > 3 else ""


def listing(side):
    rows = {}
    try:
        with open(directory + "/dirty-" + side + "-shas", "rb") as fh:
            data = fh.read()
    except OSError:
        return rows
    for line in data.split(b"\n"):
        cells = line.split(b"\t")
        if len(cells) == 2:
            rows.setdefault(cells[1], cells[0])
    return rows


def head_tree(side):
    try:
        with open(directory + "/head-" + side, "rb") as fh:
            head = b"".join(fh.read().split())
    except OSError:
        return {}
    if not head:
        return {}
    listed = subprocess.run(["git", "-C", top, "ls-tree", "-r", "-t", "-z", "--full-tree", head],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if listed.returncode:
        return {}
    entries = {}
    for record in listed.stdout.split(b"\0"):
        meta, tab, path = record.partition(b"\t")
        if tab:
            entries[path] = meta.split(b" ")[2]
    return entries


listings = {side: listing(side) for side in ("before", "after")}
trees = {}
out = []
for path in sys.stdin.buffer.read().split(b"\n"):
    if not path:
        continue
    shas = []
    for side in ("before", "after"):
        sha = listings[side].get(path, b"")
        if not sha:
            if side not in trees:
                trees[side] = head_tree(side)
            sha = trees[side].get(path, b"")
        shas.append(sha or b"-")
    if mode not in ("changed", "changed-rows"):
        out.append(b"\t".join(shas + [path]))
    elif shas[0] != shas[1]:
        out.append(b"\t".join(shas + [path]) if mode == "changed-rows" else path)
sys.stdout.buffer.write(b"".join(row + b"\n" for row in out))
' "$@"
}

snapshot_changed_paths() { # directory top [changed-rows]
  local directory="$1" top="$2" before after changed paths path
  [ -f "$directory/dirty-before-shas" ] && [ -f "$directory/dirty-after-shas" ] &&
    [ -f "$directory/head-after" ] || return 1
  before=$(cat "$directory/head-before" 2>/dev/null) || before=''
  after=$(cat "$directory/head-after" 2>/dev/null) || return 1
  changed=''
  if [ "$before" != "$after" ]; then
    [ -n "$before" ] || before=$(git -C "$top" hash-object -w -t tree --stdin </dev/null)
    [ -n "$after" ] || after=$(git -C "$top" hash-object -w -t tree --stdin </dev/null)
    changed=$(git -C "$top" diff --no-renames --name-only -z "$before" "$after" -- |
      path_shape_split 0 ''; status=("${PIPESTATUS[@]}");
      [ "${status[0]}" = 0 ] && [ "${status[1]}" = 0 ]) || return 1
  fi
  paths=$({ cut -f2- "$directory/dirty-before-shas" "$directory/dirty-after-shas"
    [ -z "$changed" ] || printf '%s\n' "$changed"; } | sort -u)
  snapshot_pairs "$directory" "$top" "${3:-changed}" <<<"$paths"
}

compute_snapshot_files() { # directory workdir
  local directory="$1" workdir="$2" top rel paths path
  RUN_FILES_LIST=''
  RUN_FILES_REASON=''
  top=$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null) || {
    RUN_FILES_REASON='the workdir is not a git working tree'; return 0;
  }
  if ! paths=$(snapshot_changed_paths "$directory" "$top"); then
    RUN_FILES_REASON='the workdir before/after snapshots could not be established'
    return 0
  fi
  rel=${workdir%/}
  case "$rel" in "$top"/*) rel=${rel#"$top"/} ;; *) rel='' ;; esac
  RUN_FILES_LIST=$(while IFS= read -r path; do
    [ -n "$path" ] || continue
    top_rel_spelling "$top" "$rel" "$path"
    printf '\n'
  done <<<"$paths" | sort -u)
}

# The paths whose content is not what `dirty-before` recorded for them: rewritten by this run, or
# gone. A floor written before the shas existed lists paths alone, and every one of them reads as
# unchanged — the old behaviour, which is what a record written by an older worker-run must keep.
workdir_rewritten_paths() { # directory workdir [its dirty shas, already hashed]
  local before="$1/dirty-before-shas"
  [ -s "$before" ] || return 0
  if [ "$#" -ge 3 ]; then [ -z "$3" ] || printf '%s\n' "$3"; else workdir_dirty_shas "$2" 2>/dev/null; fi |
    AWK_BEFORE=$before awk -F'\t' '
    BEGIN { while ((getline line < ENVIRON["AWK_BEFORE"]) > 0) { split(line, f, "\t"); was[f[2]] = f[1] } }
    NF == 2 && ($2 in was) && was[$2] != $1 { print $2 }
  '
}

# The paths this run's window put content at, top-relative: dirty now and not dirty at launch, or
# dirty at launch and holding different content since. Read twice over — by the dirt record at the
# end, and by the liveness row of a run still going — and one definition, or the two disagree about
# what this run has touched.
workdir_gained_paths() { # directory workdir [its dirty paths and shas, one pass already read]
  if [ "$#" -ge 4 ]; then
    { comm -23 <([ -z "$3" ] || printf '%s\n' "$3") <(sort -u "$1/dirty-before" 2>/dev/null)
      workdir_rewritten_paths "$1" "$2" "$4"; } | sort -u
    return
  fi
  { comm -23 <(workdir_dirty_paths "$2") \
             <(sort -u "$1/dirty-before" 2>/dev/null)
    workdir_rewritten_paths "$1" "$2"; } | sort -u
}

# The run's own listing, spelled against the repository TOP the way the dirt snapshot is. The
# listing answers in paths relative to the WORKDIR, so subtracted as it stands from a top-relative
# set it matches nothing at all for a run launched one directory in, and every path the run's own
# tracker named is recorded a second time as owed by nobody.
listing_top_paths() { # directory top workdir
  local rel=${3%/}
  case "$rel" in
    "$2"/*) rel=${rel#"$2"/} ;;
    *) rel='' ;;
  esac
  grep -v '^WORKDIR: \|^UNKNOWN: \|^PARTIAL: ' "$1/files" 2>/dev/null |
    AWK_REL=$rel AWK_TOP=$2/ awk '
      BEGIN { rel = ENVIRON["AWK_REL"]; top = ENVIRON["AWK_TOP"] }
      !NF { next }
      substr($0, 1, 1) == "/" { if (index($0, top) == 1) print substr($0, length(top) + 1); next }
      { print (rel == "" ? $0 : rel "/" $0) }' | sort -u
}

# The paths under top, absolute, that another run's own listing names in this run's window: that run
# was born before this one's listing was written and wrote its own since this one's floor. They are
# that run's, never this one's UNNAMED to claim (live 2026-10-29: a grok run offered a codex run's edit
# to its chat, and 289 of the 551 runs with dirt in the 30 days before held such a path). An UNKNOWN
# listing names nothing: its rows are the raw snapshot.
others_named_paths() { # directory top [end: the listing's own mtime, read where it is already written]
  local directory="$1" top="${2%/}" floor="$1/dirty-before-shas" end="${3:-}" other born
  local -a listings=()
  [ -n "$top" ] && [ -f "$floor" ] || return 0
  [ -n "$end" ] || { file_lstat "$directory/files" && end=$FILE_MTIME; } || end=${EPOCHSECONDS:-$(date +%s)}
  for other in "${directory%/*}"/*-*; do
    born=${other##*/} born=${born#*-} born=${born%%-*}
    [[ $born =~ ^[0-9]+$ ]] && [ "$born" -le "$end" ] && [ "$other" != "$directory" ] &&
      [ "$other/files" -nt "$floor" ] && listings+=("$other/files")
  done
  [ "${#listings[@]}" -gt 0 ] || return 0
  AWK_TOP=$top/ awk '
    FNR == 1 { base = ""; unknown = 0 }
    /^WORKDIR: / { base = substr($0, 10); sub(/\/+$/, "", base); next }
    /^UNKNOWN: / { unknown = 1; next }
    /^PARTIAL: / || !NF || unknown { next }
    { path = substr($0, 1, 1) == "/" ? $0 : (base == "" ? "" : base "/" $0) }
    path != "" && index(path, ENVIRON["AWK_TOP"]) == 1 { print path }' "${listings[@]}" 2>/dev/null | sort -u
}

# The rows on stdin, spelled relative to base or absolute, that no absolute path in owned names.
unowned_rows() { # base owned
  AWK_BASE=${1%/}/ AWK_OWNED=<(printf '%s\n' "$2") awk '
    BEGIN { while ((getline line < ENVIRON["AWK_OWNED"]) > 0) if (line != "") owned[line] = 1 }
    !NF { next }
    !((substr($0, 1, 1) == "/" ? $0 : ENVIRON["AWK_BASE"] $0) in owned)'
}

# Spelled the way the LISTING spells its rows — relative to the workdir, absolute outside it.
top_rel_spelling() { # top rel path
  [ -n "$2" ] || { printf '%s' "$3"; return 0; }
  case "$3" in
    "$2"/*) printf '%s' "${3#"$2"/}" ;;
    *) printf '%s' "$1/$3" ;;
  esac
}

record_workdir_dirt() { # directory workdir
  local directory="$1" workdir="$2" top gained
  [ -z "$RUN_FILES_REASON" ] || return 0
  # A run answering to a chat records dirt for exactly what neither its own listing nor another run's
  # could answer for: the rest of its window is already that chat's by the listing, or that run's by
  # its own, and a run whose listing is whole leaves nothing here at all.
  if [ -s "$directory/launcher" ] && [ -z "${RUN_FILES_UNNAMED:-}" ]; then
    return 0
  fi
  top=$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null) || return 0
  gained=$(snapshot_changed_paths "$directory" "$top") || return 0
  if [ -s "$directory/launcher" ]; then
    gained=$(comm -23 <(sed '/^$/d' <<<"$gained" | sort -u) \
                      <(listing_top_paths "$directory" "$top" "$workdir") |
             unowned_rows "$top" "${RUN_OTHERS_NAMED:-}")
  fi
  [ -n "$gained" ] || [ -f "$directory/dirty" ] || return 0
  { printf 'WORKDIR: %s\n' "$top"; [ -z "$gained" ] || printf '%s\n' "$gained"; } \
    >"$directory/dirty.tmp.$$" 2>/dev/null &&
    mv -f "$directory/dirty.tmp.$$" "$directory/dirty" 2>/dev/null ||
    rm -f "$directory/dirty.tmp.$$" 2>/dev/null
  return 0
}

# The paths, spelled as the listing spells them, that commits landed outside the run's own window
# touched in head-before..head-after: another chat's work the snapshot pair cannot tell from this run's.
foreign_commit_paths() { # directory top rel head-before after
  local directory="$1" top="$2" rel="$3" head="$4" after="$5" since until dirty=/dev/null
  [ -n "$after" ] && [ "$after" != "$head" ] || return 0
  [ -f "$directory/dirty-before-shas" ] && dirty=$directory/dirty-before-shas
  since=$(jq -r '.pid_started_at // .started_at // empty' "$directory/meta.json" 2>/dev/null)
  [[ "$since" =~ ^[0-9]+$ ]] || return 0
  until=$(date +%s)
  # A HEAD that is no descendant of head-before has no commit window to read, so nothing is foreign.
  [ -n "$head" ] && git -C "$top" merge-base --is-ancestor "$head" "$after" 2>/dev/null || return 0
  git -C "$top" log --raw -m --no-renames --no-abbrev --reverse -z --format='%H %ct' "$head..$after" 2>/dev/null |
    tr '\0' '\n' |
    AWK_TOP=$top AWK_REL=$rel AWK_DIRTY=$dirty AWK_SINCE=$since AWK_UNTIL=$until awk '
      BEGIN {
        top = ENVIRON["AWK_TOP"]; rel = ENVIRON["AWK_REL"]
        since = ENVIRON["AWK_SINCE"]+0; until = ENVIRON["AWK_UNTIL"]+0
        in_window = 1
        while ((getline line < ENVIRON["AWK_DIRTY"]) > 0) {
          split(line, d, "\t")
          if (d[2] != "") predirty[d[2]] = 1
        }
      }
      !NF { next }
      pending != "" {
        pending = ""
        if (in_window || $0 in predirty) next
        path = $0
        if (rel != "") {
          if (index(path, rel "/") == 1) path = substr(path, length(rel) + 2)
          else path = top "/" path
        }
        print path
        next
      }
      /^:/ { pending = $0; next }
      {
        split($0, h, " ")
        ct = h[2]+0
        in_window = (ct >= since && ct <= until) ? 1 : 0
      }'
}

# Paths that commits outside the run window touched leave the listing: the snapshot pair cannot tell
# them from the run's own, and a listed one goes to the dirt record for the launching chat to claim.
split_foreign_commits() { # directory workdir
  local directory="$1" workdir="$2" top rel head after foreign
  RUN_FOREIGN_NOTE=''
  [ -s "$directory/launcher" ] || return 0
  top=$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null) || return 0
  [ -n "$top" ] || return 0
  rel=${workdir%/}
  case "$rel" in
    "$top"/*) rel=${rel#"$top"/} ;;
    *) rel='' ;;
  esac
  head=$(tr -d '[:space:]' <"$directory/head-before" 2>/dev/null)
  after=$(cat "$directory/head-after" 2>/dev/null)
  foreign="$directory/foreign.tmp.$$"
  foreign_commit_paths "$directory" "$top" "$rel" "$head" "$after" >"$foreign"
  if [ -s "$foreign" ]; then
    RUN_FOREIGN_NOTE='commits outside the run window landed in head-before..head-after; those paths are unattributed'
    sort -u "$foreign" | sed '/^$/d' >"$foreign.sorted"
    local listed stripped
    listed=$(listing_top_paths "$directory" "$top" "$workdir")
    grep -vxF -f "$foreign.sorted" "$directory/files" >"$directory/files.tmp.$$" 2>/dev/null &&
      mv -f "$directory/files.tmp.$$" "$directory/files" 2>/dev/null ||
      rm -f "$directory/files.tmp.$$" 2>/dev/null
    rm -f "$foreign.sorted"
    # The run's own rows went with them and now answer to nobody: the dirt record is what UNNAMED offers.
    stripped=$(comm -23 <(sed '/^$/d' <<<"$listed") <(listing_top_paths "$directory" "$top" "$workdir"))
    if [ -n "$stripped" ]; then
      { printf 'WORKDIR: %s\n' "$top"
        { grep -v '^WORKDIR: ' "$directory/dirty" 2>/dev/null; printf '%s\n' "$stripped"; } | sed '/^$/d' | sort -u
      } >"$directory/dirty.tmp.$$" && mv -f "$directory/dirty.tmp.$$" "$directory/dirty" 2>/dev/null ||
        rm -f "$directory/dirty.tmp.$$" 2>/dev/null
      grep -q '^PARTIAL: ' "$directory/files" ||
        { awk 'NR == 1 { print; print "PARTIAL: commits outside the run window touched paths this run listed"; next } 1' \
            "$directory/files" >"$directory/files.tmp.$$" && mv -f "$directory/files.tmp.$$" "$directory/files"; } 2>/dev/null
      RUN_FOREIGN_NOTE+="; $(grep -c '' <<<"$stripped") of them this run's listing named are in the dirt record to claim"
    fi
  fi
  rm -f "$foreign"
  return 0
}

# The paths a run's window changed that no record on this machine names, spelled absolutely so the
# claim below takes them exactly as they are printed. The `dirty` record is only ever written where
# the run itself says its own list cannot be complete, so its rows ARE the unowned set — printed at
# the end of `wait` because that is the one moment the launching chat is looking at this run and can
# still say which of them are its worker's (live case 2026-08-25: 887 lines nobody answered for).
unnamed_line() { # directory
  local directory="$1" top paths count listed path workdir missing_after=false
  if grep -q '^UNKNOWN: \|^PARTIAL: ' "$directory/files" 2>/dev/null; then
    :
  elif [ ! -f "$directory/files" ] && [ -f "$directory/exit_code" ] &&
       { [ -f "$directory/head-before" ] || [ -f "$directory/dirty-before-shas" ]; } &&
       { [ ! -f "$directory/head-after" ] || [ ! -f "$directory/dirty-after-shas" ]; }; then
    missing_after=true
  else
    return 0
  fi
  top=$(sed -n 's/^WORKDIR: //p' "$directory/dirty" 2>/dev/null | head -n1)
  paths=$(grep -v '^WORKDIR: ' "$directory/dirty" 2>/dev/null | sed '/^$/d')
  # A run that ended after this one wrote its record may name some of them by now.
  [ -z "$top" ] || [ -z "$paths" ] ||
    paths=$(unowned_rows "$top" "$(others_named_paths "$directory" "$top")" <<<"$paths")
  if [ -z "$top" ] || [ -z "$paths" ]; then
    grep -q '^UNKNOWN: ' "$directory/files" 2>/dev/null || [ "$missing_after" = true ] || return 0
    workdir=$(sed -n 's/^WORKDIR: //p' "$directory/files" 2>/dev/null | head -n1)
    [ -n "$workdir" ] || workdir=$(jq -r '.workdir // empty' "$directory/meta.json" 2>/dev/null)
    [ "$workdir" != null ] || workdir=''
    printf 'UNNAMED: this run'"'"'s files are UNKNOWN — claim yours: worker-run claim %s --paths %s/<path>...\n' \
      "${directory##*/}" "${workdir:-<workdir>}"
    return 0
  fi
  count=$(grep -c '' <<<"$paths")
  if [ "$count" -gt "$UNNAMED_INLINE_MAX" ]; then
    # The list is the record's, not this line's, past the point where it stops being readable: the
    # 887-path case above printed a multi-kilobyte shell-quoted line at the end of every wait,
    # crowding out the outcome and the result tail it is printed beside.
    # The rows are spelled against the repository TOP, and `claim` resolves a relative operand
    # against the run's WORKDIR: for a run launched in a subdirectory a row pasted as it stands
    # names a path this run never touched, so the prefix is part of the instruction.
    printf 'UNNAMED: %s path(s) changed in this run'"'"'s window that no record names, listed one per line in %s — claim yours: worker-run claim %s --paths %s/<row>...\n' \
      "$count" "$directory/dirty" "${directory##*/}" "$top"
    return 0
  fi
  # Quoted for the shell this line is pasted into: a path carrying a space arrives at `claim` as
  # two paths, and one carrying a metacharacter as whatever that shell makes of it.
  listed=$(while IFS= read -r path; do printf '%q ' "$top/$path"; done <<<"$paths")
  printf 'UNNAMED: %s path(s) changed in this run'"'"'s window that no record names — claim yours: worker-run claim %s --paths %s\n' \
    "$count" "${directory##*/}" "${listed% }"
}
