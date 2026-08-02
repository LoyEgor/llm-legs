# The instruction files an LLM re-reads in every session, shared by the write gate and the
# tripwire so the protected set is defined once.
#
# One path set for both consumers. The write gate guards more than this list, but the extra is
# never a path: per-project CLAUDE.md and MEMORY.md are matched by name rather than enumerated,
# since there is no list of every repository, and a not-yet-created file is matched by the
# directory it lands in. A path the gate refuses a write to and the tripwire does not watch is
# the one hole neither half can report, so the enumerated set is the same for both.

# MEMORY.md is deliberately absent. A project's memory index is not always-on content — it is
# read in that project's sessions only — and appending one pointer line to it is the memory
# workflow every agent is told to follow, not a way around a denied edit. Guarding it here bought
# nothing and denied 47 legitimate appends in a measured month, more than any other single shape.
# Growth of those files is still priced by the bloat gate, at the per-project rate.
INSTRUCTION_GUARDED_BASENAMES='(CLAUDE\.md|CLAUDE\.local\.md)'

# Every consumer of these lists reads them a line and a field at a time, so a name carrying a
# newline or a tab is refused here rather than downstream: by the time `read` has seen it the
# name is already two names, and no check further along can put it back together.
_instruction_emit() {
  case "$1" in *"$_instruction_nl"*|*"$_instruction_tab"*) return 0 ;; esac
  printf '%s\n' "$1"
}
_instruction_nl='
'
_instruction_tab='	'

# Depth-unbounded, because the write gate's directory rule and the bloat gate's ancestor walk
# both are: a doc at docs/topic/sub/note.md is denied a shell write and priced per month, and a
# glob that stopped one level down left exactly those files guarded but unwatched. -L because
# docs/ and agents/ are symlinks into the config repository and the tree below them is the point.
# -print0 so a name carrying a newline arrives whole and is refused by _instruction_emit rather
# than arriving as two names.
instruction_visible_paths() {
  local home=${1:-$HOME} p
  for p in "$home"/.claude/CLAUDE.md "$home"/.claude/CLAUDE.local.md \
           "$home"/.claude/settings.json; do
    [ -f "$p" ] && _instruction_emit "$p"
  done
  while IFS= read -r -d '' p; do
    _instruction_emit "$p"
  done < <(find -L "$home"/.claude/docs "$home"/.claude/agents \
                    "$home"/.claude/instructions "$home"/.claude/skills \
                -type f -name '*.md' -print0 2>/dev/null)
}

instruction_guarded_paths() {
  instruction_visible_paths "${1:-$HOME}"
}

# Full-price read equivalents per month, measured over the 31 days to 2026-07-31. One table for
# every gate: a denial that quotes a different number from the one the bloat gate prices the same
# file at teaches its reader that neither number is real. An empty answer means "not a class this
# table prices" — the caller decides whether that is a reason to stay quiet about cost.
instruction_read_rate() {
  local path=$1 home=${2:-$HOME}
  case "$path" in
    "$home"/.claude/CLAUDE.md) printf 15682 ;;                 # every session, every project
    */MEMORY.md|*/CLAUDE.md|*/CLAUDE.local.md) printf 3131 ;;  # every session of one project
    */.claude/instructions/*) printf 160 ;;                    # loaded on topic
    */SKILL.md|*/.claude/skills/*) printf 90 ;;                # loaded on trigger
    "$home"/.claude/docs/*) printf 160 ;;                      # protocol docs, read per task type
    "$home"/.claude/agents/*) printf 2500 ;;                   # per spawn of a busy worker
  esac
}

# The directories, not just the files in them. A doc that does not exist yet costs the same per
# month as one that does the moment it is created, and a set built by globbing existing files
# can only ever guard what is already there.
instruction_guarded_dirs() {
  local home=${1:-$HOME} p
  for p in "$home"/.claude/docs "$home"/.claude/agents \
           "$home"/.claude/instructions "$home"/.claude/skills; do
    [ -d "$p" ] && _instruction_emit "$p"
  done
}

# Every spelling a shell command can carry for the same bytes. A matcher that knows only the
# expanded form is worthless: `echo x >> ~/.claude/docs/foo.md` is how the write is actually
# typed, and it walked straight through the first version of the gate.
_instruction_spellings() {
  local q=$1 home=${2%/} cwd=${3:-}
  cwd=${cwd%/}
  printf '%s\n' "$q"
  case "$q" in
    "$home"/*)
      printf '~%s\n' "${q#"$home"}"
      printf '$HOME%s\n' "${q#"$home"}"
      printf '${HOME}%s\n' "${q#"$home"}"
      ;;
    # realpath expands the /tmp and /var symlinks to /private/...; a hand-written command
    # carries the short form, and both open the same file.
    /private/*) printf '%s\n' "${q#/private}" ;;
  esac
  # The likeliest bypass of all: standing in the config repository and writing the path
  # relative to it, which no absolute spelling matches. `./` is the same path typed the other
  # common way; `../` from a subdirectory is unbounded and stays the tripwire's job.
  case "${cwd:+$q}" in
    "$cwd"/*)
      printf '%s\n' "${q#"$cwd"/}"
      printf './%s\n' "${q#"$cwd"/}"
      ;;
  esac
}

_instruction_spell_all() {
  local home=$1 cwd=$2 p real
  while IFS= read -r p; do
    _instruction_spellings "$p" "$home" "$cwd"
    real=$(realpath "$p" 2>/dev/null) || continue
    [ "$real" = "$p" ] || _instruction_spellings "$real" "$home" "$cwd"
  done
}

instruction_all_paths() {
  local home=${1:-$HOME} cwd=${2:-}
  instruction_guarded_paths "$home" | _instruction_spell_all "$home" "$cwd"
}

instruction_all_dirs() {
  local home=${1:-$HOME} cwd=${2:-}
  instruction_guarded_dirs "$home" | _instruction_spell_all "$home" "$cwd"
}

# The one-shot retry stamp both gates run on. mkdir is the atomic claim: the creator denies, and
# the approved retry is consumed by whichever caller wins the rmdir — but only once the stamp has
# aged, because two identical commands dispatched in the same batch arrive milliseconds apart,
# and letting the second spend the first one's stamp both passed an unapproved write and left the
# real retry facing a fresh deny. Anything unreadable returns 1: a deny costs one round trip,
# and the alternative is a silent unguarded write.
# 0 = this caller may pass, 1 = deny.
instruction_claim_stamp() {
  local dir=$1 hash=$2 stamp now born age=''
  case "$hash" in [0-9a-f][0-9a-f]*) ;; *) return 1 ;; esac
  mkdir -p "$dir" 2>/dev/null || return 1
  # The sweep is aimed at exactly what a gate creates: an EMPTY DIRECTORY whose name is the
  # sixteen hex characters of a fingerprint. The directory is env-overridable and a misconfigured
  # one is somebody's real data — `rm -rf` on everything starting with a hex character would take
  # ~/.claude/agents with it. rmdir cannot recurse, so the worst a wrong path can cost is an
  # empty directory that happened to be named like a fingerprint.
  local h='[0-9a-f]'
  find "$dir" -mindepth 1 -maxdepth 1 -type d \
    -name "$h$h$h$h$h$h$h$h$h$h$h$h$h$h$h$h" -mmin +1440 -exec rmdir {} + 2>/dev/null
  stamp="$dir/$hash"
  mkdir "$stamp" 2>/dev/null && return 1
  [ -d "$stamp" ] || return 1
  now=$(date +%s 2>/dev/null)
  born=$(stat -f %m "$stamp" 2>/dev/null)
  if [ -n "$now" ] && [ -n "$born" ]; then
    case "$now$born" in *[!0-9]*) ;; *) age=$((now - born)) ;; esac
  fi
  [ -n "$age" ] && [ "$age" -ge 2 ] || return 1
  rmdir "$stamp" 2>/dev/null || return 1
  return 0
}
