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
                    "$home"/.claude/commands \
                -type f -name '*.md' -print0 2>/dev/null)
}

instruction_guarded_paths() {
  instruction_visible_paths "${1:-$HOME}"
}

# Full-price read equivalents per month, measured over the 31 days to 2026-07-31. One table for
# every gate: a denial that quotes a different number from the one the bloat gate prices the same
# file at teaches its reader that neither number is real. An empty answer means "not a class this
# table prices" — the caller decides whether that is a reason to stay quiet about cost.
# These are the frozen fallback: both gates ask instruction_live_rates first and quote it when the
# local index still has a fresh answer, so a figure below one of these is the measured one, not a
# drifted copy. The tripwire still quotes the constants — it reports a whole set of files at once
# and prices the dearest class, not one path a live rate could be looked up for.
instruction_read_rate() {
  local path=$1 home=${2:-$HOME}
  case "$path" in
    "$home"/.claude/CLAUDE.md) printf 15682 ;;                 # every session, every project
    */MEMORY.md|*/CLAUDE.md|*/CLAUDE.local.md) printf 3131 ;;  # every session of one project
    */.claude/instructions/*) printf 160 ;;                    # loaded on topic
    */SKILL.md|*/.claude/skills/*) printf 90 ;;                # loaded on trigger
    */projects/*/memory/*.md) printf 160 ;;                    # recalled when its topic comes up
    "$home"/.claude/docs/*) printf 160 ;;                      # protocol docs, read per task type
    "$home"/.claude/commands/*) printf 90 ;;                   # loaded when the command is typed
    "$home"/.claude/agents/*) printf 2500 ;;                   # per spawn of a busy worker
  esac
}

# A recall names no path anywhere in the transcript: it hands over the memory's text and nothing
# else, so the read index can only ever see the odd hand-opened copy of a memory file. For this one
# class a measurement is a floor of unknown depth rather than a price, and taking it would gate the
# file at whatever it happened to be opened by hand — a memory nobody opened all month reads as
# free. Every other class is visible to the index: a skill by its invocation, an agent brief by its
# spawns, an always-on file by every session it rides in.
instruction_index_blind() {
  case "$1" in
    # The index of the set is not one of its entries: MEMORY.md rides in the prefix of every
    # session of its project and is measured there, like any other always-on file.
    */MEMORY.md) return 1 ;;
    */projects/*/memory/*.md) return 0 ;;
  esac
  return 1
}

# The global CLAUDE.md's own byte ceiling, in UTF-8 bytes of the prospective file. Not a price but
# a wall: that one file rides in every session of every project, so past this size growing it is
# refused outright rather than costed. Only growth is measured against it — an edit that shrinks an
# already-oversized file is the way back down and passes at any size.
INSTRUCTION_GLOBAL_HARD_BYTES=33000
INSTRUCTION_GLOBAL_WARN_BYTES=30000

# A current export answers in one of three useful forms: a measured path has weekly and monthly
# rates, an absent Markdown path is provably below the cheapest capped entry, and an old-contract
# export may still have the monthly always-on rate callers used before paths existed. No output
# means the export is missing, malformed, stale, or does not cover the file.
# Egor reads these numbers to decide whether a file may grow, so they have to hold still between
# one day and the next; an exact figure that drifts is worse than a coarse one that does not.
# Snapping to a 1-1.5-2-3-5-7 decade puts the shown value within ~29% of the measurement and
# absorbs the slow drift of the sliding window without ever pretending the rate is exact. Both
# gates share it: two gates quoting different numbers for one file teach a reader neither is real.
instruction_display_rate() {
  jq -nr --argjson n "$1" '
    [1, 1.5, 2, 3, 5, 7, 10] as $steps
    | if $n <= 0 then 0
      else
        ($n | log10 | floor) as $e
        | pow(10; $e) as $decade
        | ($n / $decade) as $mantissa
        | ($steps | map(select(. <= $mantissa)) | last) as $down
        | ($steps | map(select(. >= $mantissa)) | first) as $up
        | (if ($mantissa / $down) <= ($up / $mantissa) then $down else $up end) * $decade
      end
    # A rate that survives to here is positive, and printing it as 0 says the file is free to grow.
    # One decimal is all the ladder ever needs above 0.1; below it the number is rounded to two.
    | if . >= 10 then round
      elif . >= 0.1 then (. * 10 | round) / 10
      elif . > 0 then ((. * 100 | round) / 100 | if . == 0 then 0.01 else . end)
      else 0 end' 2>/dev/null
}

# Token totals reach seven figures, and a bare 1500000 is read wrong more often than right.
instruction_format_tokens() {
  jq -nr --argjson n "$1" '
    def trim: if . == floor then (floor | tostring) else tostring end;
    if $n >= 1000000 then (($n / 1000000 * 10 | round) / 10 | trim) + "M"
    elif $n >= 1000 then (($n / 1000 * 10 | round) / 10 | trim) + "k"
    else ($n | round | tostring) end' 2>/dev/null
}

# Re-read counts stay literal — "paid 2,000 times over" is the sentence that explains the cost,
# and "2k times" makes a reader do the expansion again. The last rung tracks the display ladder,
# which reaches 0.01: one decimal printed "~0 times a week" beside a cost that was not zero.
instruction_format_count() {
  jq -nr --argjson n "$1" '
    def commas:
      (tostring | split(".")) as $parts
      | ($parts[0] | explode | reverse) as $digits
      | ([range(0; $digits | length)
          | if . > 0 and . % 3 == 0 then [44, $digits[.]] else [$digits[.]] end]
         | flatten | reverse | implode)
        + (if ($parts | length) > 1 then "." + $parts[1] else "" end);
    ($n | if . >= 10 then round
          elif . >= 0.1 then (. * 10 | round) / 10
          else (. * 100 | round) / 100 end) | commas' 2>/dev/null
}

# A rate under one read a month still rounds up to 1, and "~1 times a month" in a message Egor
# reads is the kind of sloppiness that makes him doubt the number beside it.
instruction_times() {
  case "$1" in
    1) printf '1 time' ;;
    *) printf '%s times' "$1" ;;
  esac
}

instruction_live_rates() {
  local target_path=$1 home=${2:-$HOME} rates='' dir='' real='' path_real='' slug='' result=''
  local klass=other
  rates=${TOKENMAP_RATES:-$home/.local/share/tokenmap/read-rates.json}
  [ -f "$rates" ] || return 0
  case "$target_path" in
    "$home"/.claude/CLAUDE.md) klass=global ;;
    # A memory index is never in the directory tokenmap recorded: it sits at
    # <...>/projects/<encoded-cwd>/memory/MEMORY.md, so the project is named by that component,
    # which is the cwd with every non-alphanumeric character replaced by a dash.
    */projects/*/memory/MEMORY.md)
      klass=memory
      slug=${target_path%/memory/MEMORY.md}
      slug=${slug##*/}
      ;;
    */MEMORY.md|*/CLAUDE.md|*/CLAUDE.local.md)
      klass=project
      dir=$(dirname "$target_path")
      # The export is keyed by whatever cwd the sessions ran in, which is as often the /var
      # spelling as the /private/var one it resolves to, so both are tried.
      real=$(realpath "$dir" 2>/dev/null) || real=''
      [ "$real" = "$dir" ] && real=''
      ;;
    *)
      dir=$(dirname "$target_path")
      ;;
  esac
  path_real=$(realpath "$target_path" 2>/dev/null) || path_real=''
  [ "$path_real" = "$target_path" ] && path_real=''
  result=$(jq -r --arg path "$target_path" --arg path_real "$path_real" \
    --arg dir "$dir" --arg real "$real" --arg slug "$slug" --arg klass "$klass" '
    # fromdateiso8601 parses one spelling only. A producer that starts stamping fractional
    # seconds or +00:00 would otherwise read as unparseable and silently freeze every gate on
    # the constants, so the two benign drifts are normalized rather than rejected.
    def stamp: sub("\\.[0-9]+"; "") | sub("\\+00:?00$"; "Z");
    ((.generated_at | strings | stamp | fromdateiso8601?) // empty) as $gen
    # A future stamp is a broken clock or a broken export, not a fresher measurement; the small
    # tolerance is for ordinary skew between the writer and this reader.
    | select((now - $gen) <= 1209600 and ($gen - now) <= 300)
    | ((.paths.entries[$path]
        // (if $path_real == "" then null else .paths.entries[$path_real] end))) as $entry
    # limit_units is what the weekly usage limit actually charges, and that limit is the one
    # these gates exist to protect; `reads` prices the same growth in dollars, which is a
    # different and roughly twice larger number. An export written before limit_units existed
    # falls back to it rather than freezing every gate on the constants.
    | ($entry.weekly.limit_units // $entry.weekly.reads) as $weekly
    | ($entry.monthly.limit_units // $entry.monthly.reads) as $monthly
    # A project rate belongs to the instruction files that ride in every session of that
    # project, not to whatever else happens to sit in the same directory: a settings.json
    # beside them is not re-read into any prefix, and quoting it a rate measured from its
    # neighbours states a cost that was never paid.
    # A CLAUDE.md is loaded by every session at or below its own directory, so the sessions that
    # pay for it are the project keys the directory CONTAINS, not the one that spells it exactly:
    # a repository root file is read by every session in every subdirectory of that repository,
    # and asking only for the exact key priced the busiest instruction files at nothing.
    | def project_rate($d):
        if $d == "" then empty
        else ([.projects // {} | to_entries[]
               | select(.key == $d or (.key | startswith($d + "/")))
               | (.value.limit_units // .value.reads)
               | select(type == "number")] | add)
        end;
      (if $klass == "memory" then
         # A slug is a directory with every separator and every hyphen mapped to one character,
         # so the containment the project rate sums has to be asked of the PATH and only then
         # encoded: /work/repo-other and /work/repo/other encode alike, and comparing the encoded
         # strings by prefix hands the sessions of one repository to the index of its neighbour.
         ([.projects // {} | to_entries[]
           | (.key | split("/")) as $parts
           | select(any(range(1; ($parts | length) + 1);
                        ($parts[0:.] | join("/") | gsub("[^A-Za-z0-9]"; "-")) == $slug))
           | (.value.limit_units // .value.reads)
           | select(type == "number")] | add)
       elif $klass == "global" then (.global.limit_units // .global.reads)
       elif $klass == "project" then
         ((project_rate($dir) | select(. > 0)) // project_rate($real) // null)
       # `empty as $x` yields nothing at all, taking the measured and cheap branches below down
       # with it, so a class that has no rate has to answer null rather than decline to answer.
       else null end) as $class_monthly
    | if (($monthly | type) == "number" and $monthly > 0
          and ($weekly | type) == "number" and $weekly >= 0) then
        ["measured", ($weekly | tostring), ($monthly | tostring), ""] | join("|")
      elif ($class_monthly | type) == "number" and $class_monthly > 0 then
        ["legacy", "", ($class_monthly | tostring), ""] | join("|")
      # "Cheap" is a claim about a file nothing else in this export accounts for. An instruction
      # file that names a class — a CLAUDE.md, a memory index — is never that, even when the class
      # lookup above came back empty: it is a file whose price is not known yet, and it belongs to
      # the class constants of whichever gate asked. Answering "cheap" for one is how always-on files stopped
      # being gated at all.
      elif ($klass == "other"
            and (.paths.criteria.extensions | type) == "array"
            and (.paths.criteria.extensions | index(".md")) != null
            and (.paths.criteria.extensions | index(".markdown")) != null
            and (.paths.criteria.min_monthly_reads | type) == "number"
            and (.paths.criteria.limit | type) == "number"
            and (.paths.entries | type) == "object"
            and ($path | ascii_downcase | test("\\.(md|markdown)$"))) then
        # What a missing entry proves depends on why it is missing. Below the cap, every file
        # above min_monthly_reads is in the export, so an absent one is under that threshold.
        # At the cap the export is truncated by rank instead, and the only honest bound left is
        # the cheapest entry that survived the cut.
        # Both bounds are in `reads`, because that is the currency the export ranks and admits
        # entries by. The limit units of a file never exceed its reads, so the same number bounds
        # the currency the gates quote — loosely, the safe direction for a "not gated" claim.
        (if (.paths.entries | length) >= .paths.criteria.limit
         then ([.paths.entries[] | .monthly.reads | select(type == "number" and . > 0)] | min)
         else .paths.criteria.min_monthly_reads end) as $floor
        | if ($floor | type) == "number" then
            ["cheap", "", "", ($floor | tostring)] | join("|")
          else empty end
      else empty end
  ' "$rates" 2>/dev/null) || return 0
  [ -n "$result" ] && printf '%s' "$result"
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
  instruction_stamp_ready "$1" "$2" || return 1
  instruction_stamp_consume "$1" "$2"
}

# Unlike a retry stamp, a notice marker is retained for the session's lifetime: only the atomic
# creator speaks, and an unavailable cache returns silence.
# The retry sweep runs one level down from the stamp root and so never reaches these, which sit a
# level below that. The same age and the same name shape decide here, so a marker that outlived
# every session it could belong to goes too — a day, which is longer than a session lives.
instruction_mark_once() {
  local dir=$1 hash=$2 h='[0-9a-f]'
  case "$hash" in [0-9a-f][0-9a-f]*) ;; *) return 1 ;; esac
  mkdir -p "$dir" 2>/dev/null || return 1
  find "$dir" -mindepth 1 -maxdepth 1 -type d \
    -name "$h$h$h$h$h$h$h$h$h$h$h$h$h$h$h$h" -mmin +1440 -exec rmdir {} + 2>/dev/null
  mkdir "$dir/$hash" 2>/dev/null
}

# Finding the stamp and spending it are separate steps because a caller may have a condition of
# its own to put between them — one that, when it fails, has to leave the stamp for the next try.
# 0 = a stamp of this caller's is there and old enough to spend.
instruction_stamp_ready() {
  local dir=$1 hash=$2 stamp now born age=''
  case "$hash" in [0-9a-f][0-9a-f]*) ;; *) return 1 ;; esac
  mkdir -p "$dir" 2>/dev/null || return 1
  # The sweep is aimed at exactly what a gate creates: an EMPTY DIRECTORY whose name is the
  # sixteen hex characters of a fingerprint, and the note file a gate may park beside it under
  # that same name. The directory is env-overridable and a misconfigured one is somebody's real
  # data — `rm -rf` on everything starting with a hex character would take ~/.claude/agents with
  # it. rmdir cannot recurse and the note is deleted only once its bytes are the two lines this
  # code writes, so the worst a wrong path can cost is an empty directory and a file that both
  # were named like a fingerprint and held a fingerprint's contents.
  local h='[0-9a-f]' stale=''
  find "$dir" -mindepth 1 -maxdepth 1 -type d \
    -name "$h$h$h$h$h$h$h$h$h$h$h$h$h$h$h$h" -mmin +1440 -exec rmdir {} + 2>/dev/null
  while IFS= read -r stale; do
    [ -n "$stale" ] || continue
    _instruction_is_note "$stale" && rm -f "$stale" 2>/dev/null
  done <<SWEEP
$(find "$dir" -mindepth 1 -maxdepth 1 -type f \
    -name "$h$h$h$h$h$h$h$h$h$h$h$h$h$h$h$h.read" -mmin +1440 2>/dev/null)
SWEEP
  stamp="$dir/$hash"
  mkdir "$stamp" 2>/dev/null && return 1
  [ -d "$stamp" ] || return 1
  now=$(date +%s 2>/dev/null)
  born=$(stat -f %m "$stamp" 2>/dev/null)
  if [ -n "$now" ] && [ -n "$born" ]; then
    case "$now$born" in *[!0-9]*) ;; *) age=$((now - born)) ;; esac
  fi
  [ -n "$age" ] && [ "$age" -ge 2 ] || return 1
  return 0
}

instruction_stamp_consume() {
  rmdir "$1/$2" 2>/dev/null || return 1
  return 0
}

# The whole shape a gate's note has: a byte offset, the transcript it was measured against, and
# nothing else. Anything a hand or another program left under the same name fails one of the
# three and is not the sweep's to delete.
_instruction_is_note() {
  local first='' second='' extra=''
  {
    IFS= read -r first || return 1
    IFS= read -r second || return 1
    ! IFS= read -r extra || return 1
  } <"$1" 2>/dev/null || return 1
  case "$first" in ''|*[!0-9]*) return 1 ;; esac
  case "$second" in /*) return 0 ;; esac
  return 1
}
