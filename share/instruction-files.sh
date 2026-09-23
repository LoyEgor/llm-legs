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
#
# `.claude/review-debt-ignore` is here for the opposite reason: not a file every session re-reads,
# but the ONE way a path leaves review debt (review-bench docs/review-contract.md). A model that
# can append to it can retire its own unreviewed work by writing a line, which is why it is the
# project's answer and never the model's. It carries no `.md` suffix on purpose — the bloat gate
# prices markdown by the byte and has nothing to say about a two-line ignore file.
# Letter case spelled out because the volume folds it: `claude.md` opens `CLAUDE.md`, and a name
# matched case-sensitively is a write that reaches the file under a spelling no door recognises.
# SKILL.md is here because a skill is loaded wherever it sits, so the name alone says what it is.
INSTRUCTION_GUARDED_BASENAMES='([Cc][Ll][Aa][Uu][Dd][Ee]\.[Mm][Dd]|[Cc][Ll][Aa][Uu][Dd][Ee]\.[Ll][Oo][Cc][Aa][Ll]\.[Mm][Dd]|[Ss][Kk][Ii][Ll][Ll]\.[Mm][Dd]|[Rr][Ee][Vv][Ii][Ee][Ww]-[Dd][Ee][Bb][Tt]-[Ii][Gg][Nn][Oo][Rr][Ee])'

# Every consumer of these lists reads them a line and a field at a time, so a name carrying a
# newline or a tab would arrive as two names. It is emitted with each of those characters turned
# into `?` rather than dropped: a dropped name is a file no door ever sees, while this spelling
# stats as missing and the tripwire reports it as a name it cannot watch.
_instruction_emit() {
  local p=$1
  p=${p//"$_instruction_nl"/?}
  p=${p//"$_instruction_tab"/?}
  printf '%s\n' "$p"
}
_instruction_nl='
'
_instruction_tab='	'

# The class directories, one list for every consumer. A directory the gate refuses writes to and
# the tripwire does not watch is the one hole neither half can report, and that is exactly how
# ~/.claude/commands came to be priced by the bloat gate and ungated by the write gate. Names with
# nothing behind them yet are listed too, so a symlink Egor adds later is guarded the moment it
# appears rather than the moment somebody remembers this list.
_instruction_class_dirs() {
  local home=${1:-$HOME}
  printf '%s\n' \
    "$home/.claude/docs" "$home/.claude/agents" "$home/.claude/instructions" \
    "$home/.claude/skills" "$home/.claude/skills-on-demand" "$home/.claude/rules" \
    "$home/.claude/commands"
}

_instruction_class_rate() { # class-dir-name
  case "$1" in
    agents) printf 2500 ;;
    docs|instructions|rules) printf 160 ;;
    skills|skills-on-demand|commands) printf 90 ;;
  esac
}

# The markdown extensions, spelled once. The class table below and this enumerator disagreeing is
# the one hole neither half can report: a `.markdown` the gate speaks for that the tripwire never
# watched, or the reverse.
INSTRUCTION_MD_EXTENSIONS='md markdown'

instruction_md_ere() {
  local e out=''
  for e in $INSTRUCTION_MD_EXTENSIONS; do out="${out:+$out|}$e"; done
  printf '\\.(%s)' "$out"
}

instruction_is_md() {
  local e
  for e in $INSTRUCTION_MD_EXTENSIONS; do
    case "$1" in *".$e") return 0 ;; esac
  done
  return 1
}

# EVERY markdown file under ~/.claude, at any depth and whatever directory holds it: a list of
# selected directories is a list somebody forgets to extend, and `~/.claude/hooks/policy.md` sat
# outside every door for exactly that reason. -L because docs/, agents/, hooks/ and skills/ are
# symlinks into the config repository and the tree below them is the point; -print0 so a name
# carrying a newline arrives whole. Pruned: VCS internals, dependency trees, worktree copies, and
# `projects/`, which holds transcripts and the memory files the model writes by design (see the
# MEMORY.md note above). The review-debt list rides in the same walk.
_instruction_class_files() {
  local home=${1:-$HOME} p e
  local -a name_args=(-name review-debt-ignore)
  for e in $INSTRUCTION_MD_EXTENSIONS; do name_args+=(-o -iname "*.$e"); done
  [ -d "$home/.claude" ] || return 0
  while IFS= read -r -d '' p; do
    _instruction_emit "$p"
  done < <(find -L "$home/.claude" \( -name .git -o -name node_modules -o -name worktrees \
             -o -path "$home/.claude/projects" \) -prune -o -type f \( "${name_args[@]}" \) \
             -print0 2>/dev/null)
}

instruction_repo_root() { # cwd
  [ -n "${1:-}" ] && [ -d "$1" ] || return 1
  git -C "$1" rev-parse --show-toplevel 2>/dev/null
}

instruction_repo_files() { # repo-root
  local root=${1:-} p e
  local -a md_args=(-name review-debt-ignore)
  [ -n "$root" ] && [ -d "$root" ] || return 0
  for e in $INSTRUCTION_MD_EXTENSIONS; do md_args+=(-o -iname "*.$e"); done
  while IFS= read -r -d '' p; do
    _instruction_emit "$p"
  done < <(find "$root" \( -name .git -o -name node_modules -o -name worktrees \) -prune -o \
             -type f \( -iname CLAUDE.md -o -iname CLAUDE.local.md -o -iname SKILL.md -o \
             \( -path '*/.claude/*' \( "${md_args[@]}" \) \) \) -print0 2>/dev/null)
}

# What the TRIPWIRE watches: the guarded set plus settings.json, which no gate speaks for.
# settings.json is not an instruction file — nothing re-reads it into a context window — and the
# harness rewrites it whenever Egor switches model or permission mode, so denying writes to it
# cost him a tactical "ok" and caught nothing. What it does hold is these very hooks, and it is
# the one watched file git cannot give back, so it stays reported and its bytes stay kept.
# $2, when given, is the ranked cache below: the watch set is then the enumeration PLUS the few
# project files the ranking speaks for. Called without it — the rebuild does, and so does anything
# that wants the enumeration alone — the answer is what ~/.claude reaches and nothing else.
# $3 is the repository root the session works in, whose files join the set whatever they rank. A
# path reached twice — the ranking naming the current repository's CLAUDE.md, or that repository
# being the config repository ~/.claude links into — is listed once, by resolved target, or every
# change to it is reported twice.
instruction_visible_paths() {
  local home=${1:-$HOME} cache=${2:-} root=${3:-} link real
  local -a linked=()
  for link in "$home"/.claude/*; do
    [ -L "$link" ] || continue
    real=$(realpath "$link" 2>/dev/null) && linked+=("$real")
  done
  {
    [ -f "$home/.claude/settings.json" ] && _instruction_emit "$home/.claude/settings.json"
    instruction_guarded_paths "$home"
    [ -z "$cache" ] || instruction_ranked_paths "$cache"
    instruction_repo_files "$root" | while IFS= read -r real; do
      for link in ${linked[@]+"${linked[@]}"}; do
        case "$real" in "$link"|"$link"/*) continue 2 ;; esac
      done
      printf '%s\n' "$real"
    done
  } | awk '!seen[$0]++'
}

# The enumeration above is what `~/.claude` REACHES, and the gate's `always` class is wider than
# that: any project `CLAUDE.md` and any `CLAUDE.local.md` answers to it, wherever the project sits.
# Those are the dearest files Egor owns — a project `CLAUDE.md` rides in every session of that
# project — and the tripwire watched none of them, which is the hole `_instruction_class_dirs`
# warns about in the other direction: guarded by one door, invisible to the other.
# "Every project Egor might open" is not a set that can be enumerated, so the ranking already on
# disk stands in for it: tokenmap's `read-rates.json`, the same index both gates quote prices from,
# ordered by monthly reads and cut at a fixed count. That bounds the watch set — it cannot grow
# with the number of repositories on the disk — and spends the budget on the files whose silent
# change costs the most.
# MEMORY.md and the memory directory are deliberately out, though they rank just as high: the
# model writes them by design, and an alarm that fires on every save it was told to make is an
# alarm Egor learns to ignore. A worktree's copy is out for the opposite reason — it is the
# repository's own CLAUDE.md under a path that is deleted when the task ends, so it would spend a
# slot on a duplicate and then report the ordinary removal of a branch as a DELETED instruction file.
INSTRUCTION_RANKED_MAX=${INSTRUCTION_RANKED_MAX:-10}
# Stamped into the cache's first line. The cache is otherwise only re-cut when the index moves, so
# without this a change to the rules above — a new exclusion, a different count — would not reach
# the watch set until tokenmap happened to regenerate.
INSTRUCTION_RANKED_VERSION=1

instruction_ranked_rates() {
  local home=${1:-$HOME}
  printf '%s' "${TOKENMAP_RATES:-$home/.local/share/tokenmap/read-rates.json}"
}

# The cache's lines as RECORDED, without asking the disk whether they still exist. A caller
# deciding whether the ranking still speaks for a path may not be told "no" merely because the
# file is the one that vanished — that is the very case it is asking about.
instruction_ranked_names() { # cache
  local p
  [ -f "$1" ] || return 0
  while IFS= read -r p; do
    case "$p" in ''|'#'*) continue ;; esac
    _instruction_emit "$p"
  done <"$1"
}

instruction_ranked_paths() { # cache
  local p
  while IFS= read -r p; do
    [ -f "$p" ] && printf '%s\n' "$p"
  done < <(instruction_ranked_names "$1")
}

# Rebuilt at session start alone, never on the hot path: this is a jq over a 200 KB index plus a
# realpath per candidate, against the three milliseconds the whole quiet check is allowed.
# A path the enumeration already reaches is dropped HERE, by resolved target rather than by name:
# `~/.claude/CLAUDE.md` is a symlink onto the config repository's copy, which is also the ranking's
# first row, and watching one file under two names reports every change to it twice.
instruction_ranked_rebuild() { # home cache
  local home=${1:-$HOME} cache=$2 rates tmp p real known=''
  rates=$(instruction_ranked_rates "$home")
  [ -f "$rates" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  while IFS= read -r p; do
    real=$(realpath "$p" 2>/dev/null) || real=$p
    known="$known$real$_instruction_nl"
  done < <(instruction_visible_paths "$home")
  tmp="$cache.$$"
  mkdir -p "$(dirname "$cache")" 2>/dev/null || return 1
  printf '#%s\n' "$INSTRUCTION_RANKED_VERSION" >"$tmp" || return 1
  while IFS= read -r p; do
    [ -n "$p" ] && [ -f "$p" ] || continue
    real=$(realpath "$p" 2>/dev/null) || real=$p
    case "$_instruction_nl$known" in *"$_instruction_nl$real$_instruction_nl"*) continue ;; esac
    known="$known$real$_instruction_nl"
    _instruction_emit "$p" >>"$tmp"
  done < <(jq -r --argjson n "$INSTRUCTION_RANKED_MAX" '
      (.paths.entries // {}) | to_entries
      | map(select(.key | test("/(CLAUDE\\.md|CLAUDE\\.local\\.md)$")))
      | map(select(.key | test("/\\.claude/worktrees/") | not))
      | sort_by(-(.value.monthly.reads // 0)) | .[:$n] | .[].key' "$rates" 2>/dev/null)
  mv "$tmp" "$cache" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# Stale means the ranking has moved since the cache was cut, or there is no cache at all. A rates
# file that never appears leaves the cache absent and the watch set at the enumeration, which is
# the behaviour before any of this existed.
instruction_ranked_refresh() { # home cache
  local home=${1:-$HOME} cache=$2 rates stamp=''
  rates=$(instruction_ranked_rates "$home")
  [ -f "$rates" ] || return 0
  if [ -f "$cache" ] && [ ! "$cache" -ot "$rates" ]; then
    IFS= read -r stamp <"$cache"
    [ "$stamp" = "#$INSTRUCTION_RANKED_VERSION" ] && return 0
  fi
  instruction_ranked_rebuild "$home" "$cache"
}

# What the write GATE guards: the enumeration of ~/.claude, the global CLAUDE files and the
# review-debt list included, plus the current repository's files when its root is given.
instruction_guarded_paths() {
  local home=${1:-$HOME} root=${2:-}
  _instruction_class_files "$home"
  instruction_repo_files "$root"
}

# Which rule a guarded target answers to, from its name alone.
#   always — the every-session class: the global CLAUDE.md, any project CLAUDE.md, CLAUDE.local.md.
#            Denied whatever the byte delta and whatever Egor's autonomy span says: these ride in
#            the prefix of every session, and no cleanup of them is a model's own call.
#   debt   — the review-debt ignore list. Not always-on content at all: it is the ONE way a path
#            leaves review debt, so a model that may append to it retires its own unreviewed work.
#   span   — the on-demand instruction markdown: docs, agents, skills, commands. Guarded, except
#            that a write which cannot grow the file is work Egor left the model while he is away.
# An empty answer means no gate speaks for the path, which is settings.json above all.
instruction_write_class() {
  case "${1##*/}" in
    CLAUDE.md|CLAUDE.local.md) printf always ;;
    [Cc][Ll][Aa][Uu][Dd][Ee].[Mm][Dd]|[Cc][Ll][Aa][Uu][Dd][Ee].[Ll][Oo][Cc][Aa][Ll].[Mm][Dd]) printf always ;;
    review-debt-ignore) printf debt ;;
    [Rr][Ee][Vv][Ii][Ee][Ww]-[Dd][Ee][Bb][Tt]-[Ii][Gg][Nn][Oo][Rr][Ee]) printf debt ;;
    settings.json) ;;
    *)
      if instruction_is_md "${1##*/}"; then printf span; fi
      ;;
  esac
}

# Egor's autonomy span, from the one place that defines it: `rj_autonomous` in claude-setup
# hooks/lib/review-journal.sh, which owns the phrase, what counts as a turn of his and what ends
# the span. A second definition here would be a door answering differently from the one beside it.
# Sourced in a subshell at the moment of a denial and never on the hot path — the library is 90 KB
# and its reader walks the whole transcript. An unreadable library, a missing transcript or no jq
# answers "no span", which is the stricter side.
instruction_autonomous() {
  local sid=${1:-} transcript=${2:-} lib="${HOME:-}/.claude/hooks/lib/review-journal.sh"
  [ -r "$lib" ] || return 1
  ( . "$lib" || exit 1; rj_autonomous "$sid" "$transcript" ) >/dev/null 2>&1
}

# Whether this process is a relay worker rather than the chat Egor negotiated with. His rule: an
# instruction file is edited by the orchestrating model, after that model's audit — a worker
# proposes and never writes. The audit-then-retry protocol both gates run on is honour-based and a
# worker spends it by simply asking twice, which is how the global CLAUDE.md grew twice in one day
# with nobody looking for the cuts that would pay for it.
# CLAUDEB_WORKER is the load-bearing member: `claudeb` sets it for every HEADLESS run, which is the
# only shape in which these hooks execute inside a worker at all, and it holds whoever launched
# that run. GROK_WORKER is its twin, set by `grokb` for the same reason — the same pair
# `rj_in_relay` reads. CLAUDE_LAUNCHER_SESSION rides along because `worker-run` exports it into the
# run and into nothing else: a relay CLI launched some other way still carries it, and no
# interactive chat of Egor's ever does, since the export dies with the process that made it.
instruction_in_relay() {
  [ "${CLAUDEB_WORKER:-}" = 1 ] || [ "${GROK_WORKER:-}" = 1 ] ||
    [ -n "${CLAUDE_LAUNCHER_SESSION:-}" ]
}

# What every door tells a relay worker, spelled once: two doors refusing the same write in two
# wordings teach their reader that one of them is negotiable.
instruction_relay_refusal() { # path
  printf "Instruction files are the orchestrator's to edit (Egor's rule): do not write %s; put the exact proposed text and its byte delta under MD-PROPOSAL in your RETURN, with the cut you suggest to pay for it.\n" "$1"
}

# The nearest ancestor of a path that exists, resolved through every symlink in it. A Write creates
# the file and may be creating its directory too, so the walk goes up: a new subdirectory of docs/
# is still under docs/. CDPATH makes cd print where it landed, which would ride along in the
# captured path.
instruction_resolved_dir() { # path
  local probe out=''
  probe=$(dirname "$1")
  while [ -n "$probe" ] && [ "$probe" != / ] && [ "$probe" != . ]; do
    out=$(CDPATH= cd -- "$probe" 2>/dev/null && pwd -P) && [ -n "$out" ] && break
    out=''
    probe=$(dirname "$probe")
  done
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# Whether a path is one of the always-loaded instruction files, asked of an ARBITRARY path rather
# than of a name already matched against the guarded set: the Edit/Write door has no spelling match
# to lean on. The basename settles the every-session class; past it the name says only "markdown"
# and the resolved DIRECTORY decides, because the class directories are symlinks into the config
# repository and the repository spelling is the one anybody editing that repo actually types.
# A memory file answers no, and deliberately: appending a pointer line to a project's memory index
# is the workflow every agent is told to follow, and a memory is not always-on content. So does the
# review-debt list, which keeps its own refusal — what it guards is a review, not a context window.
instruction_always_loaded() { # path [home] -> prints always|span
  local path=$1 home=${2:-$HOME} dir probe guarded
  case "$(instruction_write_class "$path")" in
    always) printf always; return 0 ;;
    span) ;;
    *) return 1 ;;
  esac
  dir=$(instruction_resolved_dir "$path") || return 1
  while IFS= read -r probe; do
    guarded=$(CDPATH= cd -- "$probe" 2>/dev/null && pwd -P) || continue
    [ -n "$guarded" ] || continue
    case "$dir" in "$guarded"|"$guarded"/*) printf span; return 0 ;; esac
  done < <(_instruction_class_dirs "$home")
  return 1
}

# A shell command with its DATA taken out, so what is left can be read as syntax. Two passes,
# both about the same distinction:
#   - a heredoc BODY is data handed to a command, so a redirection or a guarded name inside one is
#     text: `cat <<EOF` into a scratch file writes that file and nothing the body names. `<<<`
#     declares no body at all.
#   - a quoted RUN is one word. A run with no whitespace is a path and keeps everything but its
#     quotes, so a redirection whose target is quoted still reads as a redirection to that file; a
#     run carrying whitespace is prose or a program and collapses to one placeholder, so a note
#     appended to a scratchpad reads as the write to the scratchpad that it is, however many
#     guarded names and operators the note itself spells.
# A double-quoted run holding `$(` or a backtick is neither, because the shell runs it: it is
# emitted verbatim and whatever it carries reads as syntax, which is the conservative side.
# The same reason bin/worker-pin-gate.sh strips quotes before it looks for a redirect; that door
# collapses every run and finds its file by name instead, which this one cannot do because it must
# report WHICH file a command writes. Callers must fall back to the raw command when an
# INSTRUCTION_INTERPRETER_RE name stands in it: there the quoted text is a program, not data.
instruction_shell_scan() {
  awk -v sq="'" -v dq='"' '
    function feedsshell(line,   at, pre, post) {
      at = index(line, "<<")
      if (!at) return 0
      pre = substr(line, 1, at - 1)
      post = substr(line, at)
      sub(/.*(;|&)/, "", pre)
      sub(/(;|&|\|\|).*/, "", post)
      return (pre post) ~ shellre
    }
    { cmd = cmd (nread++ ? "\n" : "") $0 }
    END {
      shellre = "(^|[ \t|;&(])([^ \t|;&()<>]*/)?(bash|sh|zsh|ksh|dash)([ \t]|$)"
      # `<<\EOF` is the backslash spelling of a literal heredoc, as ordinary as the quoted one:
      # unrecognised, its body is never dropped and the rules it quotes read as commands.
      hdre = "<<-?[ \t]*\\\\?(" dq "[^" dq "]*" dq "|" sq "[^" sq "]*" sq "|[A-Za-z_][A-Za-z_0-9]*)"
      nl = split(cmd, L, "\n")
      text = ""
      i = 1
      first = 1
      while (i <= nl) {
        text = text (first ? "" : "\n") L[i]
        first = 0
        ndel = 0
        rest = L[i]
        gsub(/<<</, "\001", rest)
        # `$((1<<n))` is a shift, not a redirection, and its operand is not a delimiter: read as
        # one it swallowed every command after this line.
        while (sub(/\$\(\([^)]*\)\)/, "\002", rest)) continue
        while (match(rest, hdre)) {
          tok = substr(rest, RSTART, RLENGTH)
          rest = substr(rest, RSTART + RLENGTH)
          strip = (tok ~ /^<<-/)
          d = tok
          sub(/^<<-?[ \t]*/, "", d)
          sub(/^\\/, "", d)
          sub("^[" dq sq "]", "", d)
          sub("[" dq sq "]$", "", d)
          if (d == "") continue
          ndel++
          DEL[ndel] = d
          STRIP[ndel] = strip
        }
        # A heredoc fed to a shell is a program: its body stays in the text as commands.
        if (feedsshell(L[i])) ndel = 0
        i++
        for (k = 1; k <= ndel; k++) {
          start = i
          found = 0
          while (i <= nl) {
            b = L[i]
            i++
            # `<<-` strips TABS and no spaces: a space-indented word is not the terminator, and
            # stopping on it leaves the rest of the body read as commands.
            if (STRIP[k]) sub(/^\t+/, "", b)
            if (b == DEL[k]) { found = 1; break }
          }
          # A terminator that never appears means there was no heredoc — a `<<` inside a quoted
          # sentence or an arithmetic shift — and the lines consumed for it are commands.
          if (!found) { i = start; break }
        }
      }
      out = ""
      n = length(text)
      i = 1
      while (i <= n) {
        c = substr(text, i, 1)
        # Outside quotes a backslash escapes ONE character and nothing more: collapsing it to a
        # placeholder erased the name of the binary it stood inside (`gi\t push`) and left that
        # word resolvable to neither a name nor command position.
        if (c == "\\") { out = out substr(text, i + 1, 1); i += 2; continue }
        # ANSI-C quoting, a dollar in front of a single-quoted body: the body is escape sequences
        # this parse does not resolve, so the word is an executable it cannot name and has to
        # stand in command position as one, whatever the body spells.
        if (c == "$" && substr(text, i + 1, 1) == sq) {
          j = i + 2
          while (j <= n && substr(text, j, 1) != sq) {
            if (substr(text, j, 1) == "\\") j += 2
            else j++
          }
          out = out "Q"
          i = j + 1
          continue
        }
        if (c == sq || c == dq) {
          q = c; j = i + 1; body = ""; live = 0; closed = 0
          while (j <= n) {
            d = substr(text, j, 1)
            if (q == dq && d == "\\") { body = body substr(text, j + 1, 1); j += 2; continue }
            if (q == dq && (d == "`" || (d == "$" && substr(text, j + 1, 1) == "("))) live = 1
            if (d == q) { closed = 1; break }
            body = body d
            j++
          }
          if (!closed) { out = out substr(text, i); break }
          # A run whose body opens with `!` is a git alias: git hands the rest of it to a shell,
          # so it is a program like a `$(` run is — and the shell runs it as a command line of its
          # own, which is where this parse has to put it or the command word it carries
          # (`git -c alias.zz=!git push zz`) stands in no command position at all.
          if (body ~ /^!/) out = out "\n" substr(body, 2)
          else if (live) out = out body
          else if (body ~ /[ \t\n]/) out = out "Q"
          else out = out body
          i = j + 1
          continue
        }
        out = out c
        i++
      }
      printf "%s", out
    }'
}

# A word that hands quoted TEXT to a parser. Once one of these stands in a command the quoted runs
# are a program rather than data, and reading them as data hides what the program does — a write
# into a guarded file, a `git push`, a review launch — so the caller reads the raw command instead.
# Two halves because the write gate reads the second one with a rule of its own as well
# (`instruction_interp_write_re`), never instead of this one; every door asks the union. env, nohup
# and setsid stay out: they execute argv and unquote nothing.
INSTRUCTION_SHELL_INTERPRETER_RE='(^|[[:space:]|;&({])([^[:space:]|;&()<>]*/)?(bash|sh|zsh|ksh|dash|fish|csh|tcsh|eval|xargs|ssh|osascript|su|flock)([[:space:]]|$)'
# A language runtime re-parses its payload exactly as a shell does, and what it runs from there is
# any command at all: `python3 -c` and `awk BEGIN{system(...)}` reach git and review-bench through a
# payload no door reads.
INSTRUCTION_LANG_INTERPRETER_RE='(^|[[:space:]|;&({])([^[:space:]|;&()<>]*/)?(python[0-9.]*|perl|ruby|node|deno|bun|php|lua|awk|gawk)([[:space:]]|$)'
INSTRUCTION_INTERPRETER_RE="$INSTRUCTION_SHELL_INTERPRETER_RE|$INSTRUCTION_LANG_INTERPRETER_RE"
# A word in COMMAND position this scan cannot resolve — a collapsed quoted run, any expansion
# (`$(...)`, a backtick, `${VAR}`, `$1`) — is an executable it cannot name, and one of the names
# above is exactly what it may be. A dollar or a backtick counts whatever follows it: `$VAR` glued
# to a quoted word and `$1` are as unresolvable as `$VAR ` is, and a class that asked for trailing
# whitespace let both stand. The start class carries `{` and an env-assignment prefix because
# `{ $GIT push; }` and `GIT_DIR=/tmp/r.git $GIT push` are that same word typed two other ways; `^`
# restarts per LINE, so every consumer matches this with grep -E rather than a whole-string `=~`.
INSTRUCTION_CMD_POSITION_RE='(^|[;|&({])[[:space:]]*([A-Za-z_][A-Za-z_0-9]*=[^[:space:]]*[[:space:]]+)*(Q|`|\$)'
# The boundary classes a guarded name has to stand between, spelled once for every door. BOTH
# ends: `CLAUDE.md.bak` and `dummyCLAUDE.md` are not the file, and this repository keeps exactly
# such backups. The backslash belongs in both — a path inside an escaped quote, which is how an
# interpreter one-liner is actually written, has \" pressed against it. No pipe in the start
# class: a guarded name pressed against one is a delimiter inside a script far more often than it
# is a target, and reading it as one denied ordinary rewrites.
INSTRUCTION_NAME_START="(^|[[:space:]>;&(=,\"'/\`\\\\])"
INSTRUCTION_NAME_END="($|[[:space:]>|;&),}\"'\`\\\\])"

# WHETHER AN INTERPRETER MENTION IS A WRITE, and whether it can shrink the file. The parse below
# can only report that a python/node/perl call NAMED a guarded path: the path stands inside a
# payload it does not read, so a row of that kind means "mentioned here" and nothing more. These
# patterns are what turn it into a shape, and both doors ask them — the gate for the deny decision,
# the tripwire because a mention is not the evidence a REVERT may be taken on. Two spellings would
# be a one-liner denied at one door and put back by neither.
#
# The destination has to stand INSIDE the call that writes it, and that adjacency is the whole
# rule. A write mode plus the guarded name somewhere in the same pipeline stage was not:
# `open('/tmp/scratch','w').write('see CLAUDE.md')` writes a scratch file and mentions a guarded
# one, and the loose rule read that as a write to the guarded file. The path has to be quoted,
# which is how a one-liner is actually written and which also keeps a `.tmp` sibling out; a path
# held in a variable is out of scope here as it is everywhere else in these hooks.
# The verb boundary carries a slash because `/usr/bin/python3` is the same call typed another way,
# and a backtick and a brace because so are `` `…` `` and `{ …; }`.
_INSTRUCTION_IW="(^|[[:space:]|;&({\`/])(python[0-9.]*|perl|ruby|node|bun|deno)[[:space:]][^|]*"
# The quote around a path or a mode arrives escaped as often as bare: the one-liner is itself a
# double-quoted argument, so `open(\"x\",\"w\")` is the ordinary spelling.
_INSTRUCTION_Q="\\\\?['\"]"
# Every mode string that can write, letter order free: Python accepts 'bw' and '+rb' as readily
# as 'wb', so any string over rwaxbt+ counts once it carries a w, a, x or +. `r`, `rb` and their
# reorderings never reach one of those letters and stay out, which is the whole reason the modes
# are enumerated rather than matched loosely. Perl's spellings, `+>>` included, stand apart.
_INSTRUCTION_MODE="${_INSTRUCTION_Q}([rbt]*[wax+][rwaxbt+]*|>>?|\+[<>]>?)${_INSTRUCTION_Q}"
# The subset that REPLACES the file's bytes: a `w` or an `x`, never an `a` and never a bare `+`,
# since `r+` and `a+` both write past what is already there.
_INSTRUCTION_TRUNC_MODE="${_INSTRUCTION_Q}([rbt]*[wx][rwxbt+]*|>|\+>)${_INSTRUCTION_Q}"
# One template, both mode sets: $2 is the mode pattern, $3 the node verb — appendFile is a write
# like any other and is never a truncating one.
# The names arrive as a bare alternation, so they are parenthesised HERE: pasted raw, the first
# `|` in them ends the whole pattern and everything after it matches on its own.
_instruction_interp_rule() { # names-alternation mode-pattern node-verb
  printf '%s%s' "$_INSTRUCTION_IW" "$(_instruction_interp_construct "$1" "$2" "$3")"
}

# The construct ALONE, with no interpreter prefix: the prefix ends in `[^|]*`, so one match of
# the full rule spans from the interpreter to the LAST construct on the line and a caller that
# has to judge each write separately cannot cut it apart. Whoever uses this must first establish
# that an interpreter stands in the command (the full rule above), or a name inside ordinary
# prose reads as a write.
_instruction_interp_construct() { # names-alternation mode-pattern node-verb
  set -- "($1)" "$2" "$3"
  printf '%s' "(open\([[:space:]]*${_INSTRUCTION_Q}${1}${_INSTRUCTION_Q}[[:space:]]*,[[:space:]]*(mode[[:space:]]*=[[:space:]]*)?$2|open\([^()]*,[[:space:]]*$2[[:space:]]*,[[:space:]]*${_INSTRUCTION_Q}${1}${_INSTRUCTION_Q}|Path\([[:space:]]*${_INSTRUCTION_Q}${1}${_INSTRUCTION_Q}[[:space:]]*\)[[:space:]]*\.(write_text|write_bytes|open\([[:space:]]*$2)|$3\([[:space:]]*${_INSTRUCTION_Q}${1}${_INSTRUCTION_Q}|(shutil\.(copy[a-z_0-9]*|move)|copyfile|os\.replace|rename(Sync)?)\([^()]*,[[:space:]]*${_INSTRUCTION_Q}${1}${_INSTRUCTION_Q}|File\.write\([[:space:]]*${_INSTRUCTION_Q}${1}${_INSTRUCTION_Q})"
}

instruction_interp_write_re() { # names-alternation → ERE matching a write to one of them
  _instruction_interp_rule "$1" "$_INSTRUCTION_MODE" "(write|append)File(Sync)?"
}

instruction_interp_trunc_re() { # names-alternation → ERE matching a write that can shrink one
  _instruction_interp_rule "$1" "$_INSTRUCTION_TRUNC_MODE" "writeFile(Sync)?"
}

instruction_interp_write_construct_re() { # names-alternation → ERE matching ONE write construct
  _instruction_interp_construct "$1" "$_INSTRUCTION_MODE" "(write|append)File(Sync)?"
}

instruction_interp_trunc_construct_re() { # names-alternation → ERE matching one shrinking one
  _instruction_interp_construct "$1" "$_INSTRUCTION_TRUNC_MODE" "writeFile(Sync)?"
}

# WHERE A COMMAND LEAVES ITS BYTES: the one parse both doors on these files ask. Two parses of one
# line was the defect they were built with — the gate read the destination strictly while the
# tripwire re-derived it from a looser expression of its own, so a `.bak` sibling of a guarded
# name was a write to one half and not to the other, and a `mv` whose segment ended in whitespace
# was attributed to nobody. Each consumer filters the ROWS by what it speaks for instead: the gate
# takes the redirections and tee, whose target stands in a fixed place, and leaves the copy verbs
# and the interpreters to the tripwire, which measures bytes rather than guessing shapes.
#
# A row is `KIND<TAB>MODE<TAB>VERB<TAB>NAME`. KIND is `redirect`, `verb` or `copy`; MODE says
# whether the write can leave the file SMALLER (`trunc`) or only add to it (`append`), which is
# the whole distinction Egor's autonomy span rests on, and is `unknown` where the shape cannot
# say. NAME is the spelling the command used, so a caller can report it and resolve it.
#
# Quotes are read as syntax rather than as quoting, deliberately: the gate hands over text whose
# quoted runs are already resolved, and the tripwire hands over the raw command, where a quoted
# run reaching a shell is a program and not data. A `#` opening a word is a comment to the end of
# the line — `tee log # note about a rule` names its file in prose and writes nothing.
#
# A destination is matched WHOLE against the caller's names: a word merely ENDING in a guarded
# name is not that name, and a copy whose last operand is elsewhere reads OUT of the file. Only an
# interpreter is read loosely, because there the path stands inside the call rather than in an
# operand.
instruction_write_targets() { # command-text names-alternation → KIND MODE VERB NAME rows
  [ -n "${2:-}" ] || return 0
  # C locale: tolower() under UTF-8 aborts on a byte run it cannot decode, and a path is bytes.
  LC_ALL=C IWT_TARGET=$2 IWT_NAME_START=$INSTRUCTION_NAME_START IWT_NAME_END=$INSTRUCTION_NAME_END \
  awk -v sq="'" -v bq='`' '
    # Only the simple command that declares the heredoc decides whether a shell reads it, pipes kept:
    # `cat <<EOF | bash` runs the body, `bash -n x && cat > f <<EOF` does not.
    function feedsshell(line,   at, pre, post) {
      at = index(line, "<<")
      if (!at) return 0
      pre = substr(line, 1, at - 1)
      post = substr(line, at)
      sub(/.*(;|&)/, "", pre)
      sub(/(;|&|\|\|).*/, "", post)
      return (pre post) ~ shellre
    }
    function addword() {
      if (word != "") { W[++nw] = word; word = "" }
    }
    # ANSI-C quoting, `$'...'`, with p on the dollar: the body with its escapes resolved, so a name
    # spelled through one is the name the shell opens.
    function ansic(code,   out, c, d, n, k) {
      out = ""
      p += 2
      while (p <= length(code)) {
        c = substr(code, p, 1)
        if (c == sq) { p++; return out }
        if (c != "\\") { out = out c; p++; continue }
        d = substr(code, p + 1, 1)
        p += 2
        if (d == "n") out = out "\n"
        else if (d == "t") out = out "\t"
        else if (d == "r") out = out "\r"
        else if (d == "x") {
          n = 0
          for (k = 0; k < 2 && substr(code, p, 1) ~ /[0-9A-Fa-f]/; k++) {
            n = n * 16 + index("0123456789abcdef", tolower(substr(code, p, 1))) - 1
            p++
          }
          out = out sprintf("%c", n)
        } else if (d ~ /[0-7]/) {
          n = d + 0
          for (k = 0; k < 2 && substr(code, p, 1) ~ /[0-7]/; k++) { n = n * 8 + substr(code, p, 1); p++ }
          out = out sprintf("%c", n)
        } else out = out d
      }
      return out
    }
    function isinterp(   k, b) {
      for (k = 1; k <= nw; k++) {
        b = W[k]; sub(/^.*\//, "", b)
        if (b ~ /^(perl|python[0-9.]*|ruby|node|bun|deno)$/) return 1
      }
      b = word; sub(/^.*\//, "", b)
      return b ~ /^(perl|python[0-9.]*|ruby|node|bun|deno)$/
    }
    function trailing_bs(s,   i, c) {
      i = length(s); c = 0
      while (i > 0 && substr(s, i, 1) == "\\") { c++; i-- }
      return c
    }
    # One word from position p, quotes dropped and escapes taken literally, stopping where the
    # shell would: at blank, at a separator, at the next redirection.
    function readword(code,   w, c) {
      w = ""
      while (p <= length(code)) {
        c = substr(code, p, 1)
        if (c == "\\") { p++; w = w substr(code, p, 1); p++; continue }
        if (c == "$" && substr(code, p + 1, 1) == sq) { w = w ansic(code); continue }
        if (c == "\"" || c == sq) { p++; continue }
        if (c ~ blank || c == ";" || c == "|" || c == "&" || c == "(" || c == ")" ||
            c == bq || c == ">" || c == "<") break
        w = w c
        p++
      }
      return w
    }
    # Names are compared folded, because the volume folds them. One carrying a newline or a tab
    # cannot travel in a tab-separated row, so it goes out as a `refuse` row with `?` in their place.
    function emit(kind, mode, verb, name, whole) {
      if (name == "") return
      if (name ~ /[\t\n]/) { gsub(/[\t\n]/, "?", name); kind = "refuse" }
      if (whole && tolower(name) !~ exact) return
      printf "%s\t%s\t%s\t%s\n", kind, mode, verb, name
    }
    # Perl and ruby edit in place under a bundled `-i` (`-pi`, `-i.bak`, `-0777pi`), never under a
    # module or library switch that merely spells the letter (`-Mstrict`).
    function inplace(from,   j) {
      for (j = from + 1; j <= nw; j++) if (W[j] ~ /^-[0-9lnpawsx]*i/) return 1
      return 0
    }
    # `git checkout` and `git restore` rewrite the files they name; global options (`-C dir`,
    # `-c key=value`) stand between the binary and the subcommand. gsub_at is where it stood.
    function gitwrites(from,   j) {
      for (j = from + 1; j <= nw; j++) {
        if (W[j] == "-C" || W[j] == "-c") { j++; continue }
        if (W[j] ~ /^-/) continue
        gsub_at = j
        return W[j] == "checkout" || W[j] == "restore"
      }
      return 0
    }
    # An option carrying this letter anywhere in the run: an in-place editor and an appending tee
    # are as often folded into a bundle as they are typed alone.
    function flagged(from, letter, long,   j) {
      for (j = from + 1; j <= nw; j++) {
        if (W[j] == long) return 1
        # GNU spells the suffix onto the flag (`--in-place=.bak`), which the letter rule below
        # cannot see either: a `--` word never matches `^-[A-Za-z]*`.
        if (index(W[j], long "=") == 1) return 1
        if (W[j] ~ "^-[A-Za-z]*" letter) return 1
      }
      return 0
    }
    function scan_loose(text, verb,   s, m, name, at, len) {
      s = text
      while (match(tolower(s), bounded)) {
        # The inner match overwrites RSTART/RLENGTH, so where this one stood is remembered first
        # or the scan re-reads the same name until the text runs out.
        at = RSTART; len = RLENGTH
        m = substr(s, at, len)
        name = m
        if (match(tolower(m), target)) name = substr(m, RSTART, RLENGTH)
        emit("verb", "unknown", verb, name, 0)
        s = substr(s, at + len)
      }
    }
    # One simple command, decided. The verb is looked for among the words rather than in the
    # command position alone: `sudo tee`, `xargs tee` and `env python3` are the same write typed
    # with something in front of it.
    function finish(rawtext, body,   j, k, base, vi, vkind, verb, mode, nopt, dest, src) {
      vi = 0; vkind = ""; verb = ""
      for (j = 1; j <= nw && vkind == ""; j++) {
        base = W[j]
        sub(/^.*\//, "", base)
        vi = j
        verb = base
        # tee replaces every destination it names; truncate, dd, patch, ed, ex and an in-place
        # editor rewrite the file they are pointed at. `awk` is not here at all: what it writes
        # goes out through a redirection, which is read as a redirection.
        if (base ~ /^g?tee$/) vkind = "tee"
        else if (base ~ /^(perl|ruby)$/ && inplace(j)) vkind = "dest"
        else if (base ~ /^(perl|python[0-9.]*|ruby|node|bun|deno)$/) vkind = "loose"
        else if (base ~ /^(truncate|dd|patch|ed|ex)$/) vkind = "dest"
        else if (base ~ /^g?sed$/ && flagged(j, "i", "--in-place")) vkind = "dest"
        else if (base ~ /^(cp|mv|ln|install|rsync)$/) vkind = "copy"
        else if (base == "git" && gitwrites(j)) vkind = "git"
      }
      if (vkind == "git") {
        for (j = gsub_at + 1; j <= nw; j++) {
          if (W[j] ~ /^-/) continue
          emit("copy", "trunc", "git", W[j], 1)
        }
      }
      if (vkind == "tee" || vkind == "dest") {
        mode = (vkind == "tee" && flagged(vi, "a", "--append")) ? "append" : "trunc"
        for (j = vi + 1; j <= nw; j++) {
          if (W[j] ~ /^-/) continue
          # dd names its destination in an operand of its own, and every other `key=value`
          # operand is not a path at all: emitted verbatim, `of=<path>` matches the by-name
          # prefix whole, so the denial names a file that does not exist, and `if=` reports
          # what dd READS as a write.
          if (W[j] ~ /^[A-Za-z_][A-Za-z_0-9]*=/) {
            if (W[j] !~ /^of=/) continue
            dest = W[j]
            sub(/^of=/, "", dest)
            emit("verb", mode, verb, dest, 1)
            continue
          }
          emit("verb", mode, verb, W[j], 1)
        }
      } else if (vkind == "copy") {
        nopt = 0
        for (j = vi + 1; j <= nw; j++) if (W[j] !~ /^-/) OP[++nopt] = W[j]
        if (nopt >= 2) {
          dest = OP[nopt]
          emit("copy", "trunc", verb, dest, 1)
          sub(/\/+$/, "", dest)
          # A destination DIRECTORY takes each sources own name: a copy into `.` leaves its bytes
          # in a file the operand never spells.
          for (k = 1; k < nopt; k++) {
            src = OP[k]
            sub(/^.*\//, "", src)
            if (src == "") continue
            # The trailing slash on the verb marks the row as the directory reading, which only
            # holds when the destination IS a directory; a caller that can look decides.
            if (dest == "" || dest == ".") {
              emit("copy", "trunc", verb "/", src, 1)
              emit("copy", "trunc", verb "/", "./" src, 1)
            } else emit("copy", "trunc", verb "/", dest "/" src, 1)
          }
        }
      } else if (vkind == "loose") {
        scan_loose(rawtext " " body, verb)
      }
      nw = 0; word = ""
    }
    function tokenize(code, body,   n, c, prev, op, c2, dest, cstart, inq) {
      nw = 0; word = ""; inq = ""
      n = length(code)
      p = 1
      cstart = 1
      while (p <= n) {
        c = substr(code, p, 1)
        prev = (p > 1) ? substr(code, p - 1, 1) : ""
        if (c == "#" && word == "" && inq == "" && (p == 1 || prev ~ blank)) break
        if (c == "\\") { p++; word = word substr(code, p, 1); p++; continue }
        if (c == "$" && substr(code, p + 1, 1) == sq && inq == "") { word = word ansic(code); continue }
        if (c == "\"" || c == sq) {
          if (inq == "") inq = c
          else if (inq == c) inq = ""
          p++
          continue
        }
        # A quoted payload handed to a language runtime is one argument: a `;` between two of its
        # statements does not end the command that runs them.
        if (inq != "" && (c == ";" || c == "|" || c == "&" || c == bq || c == ">" || c == "<") &&
            isinterp()) {
          word = word c
          p++
          continue
        }
        # A paren ends a WORD and not the command: a name inside `open(...)` still belongs to the
        # interpreter that named it, and `$(...)` carries the verb of the command it runs.
        if (c ~ blank || c == "(" || c == ")") { addword(); p++; continue }
        if (c == ";" || c == "|" || c == "&" || c == bq) {
          addword()
          finish(substr(code, cstart, p - cstart), body)
          p++
          cstart = p
          continue
        }
        if (c == ">") {
          # A leading fd is part of the operator, not a word of its own, and a `>&` duplicates a
          # descriptor rather than opening a file.
          if (word ~ /^[0-9]+$/) word = ""
          addword()
          op = ">"
          p++
          c2 = substr(code, p, 1)
          if (c2 == ">") { op = ">>"; p++ }
          else if (c2 == "|") { op = ">|"; p++ }
          else if (c2 == "&") {
            # `>&` followed by a descriptor duplicates it; followed by anything else it opens that
            # word as a file, truncating it.
            p++
            while (p <= n && substr(code, p, 1) ~ blank) p++
            dest = readword(code)
            if (dest !~ /^([0-9]+-?|-)$/) emit("redirect", "trunc", ">&", dest, 1)
            continue
          }
          while (p <= n && substr(code, p, 1) ~ blank) p++
          dest = readword(code)
          emit("redirect", (op == ">>") ? "append" : "trunc", op, dest, 1)
          continue
        }
        if (c == "<") {
          # The operand of a `<` is what the command READS, however many write verbs stand beside
          # it.
          if (word ~ /^[0-9]+$/) word = ""
          addword()
          p++
          c2 = substr(code, p, 1)
          if (c2 == "<") { p++; c2 = substr(code, p, 1); if (c2 == "<" || c2 == "-") p++ }
          else if (c2 == "&") p++
          else if (c2 == ">") {
            # `<>` opens the word read-write without truncating: bytes written land in the file.
            p++
            while (p <= n && substr(code, p, 1) ~ blank) p++
            emit("redirect", "append", "<>", readword(code), 1)
            continue
          }
          while (p <= n && substr(code, p, 1) ~ blank) p++
          readword(code)
          continue
        }
        word = word c
        p++
      }
      addword()
      finish(substr(code, cstart, n - cstart + 1), body)
    }
    BEGIN {
      target = tolower(ENVIRON["IWT_TARGET"])
      exact = "^(" target ")$"
      bounded = tolower(ENVIRON["IWT_NAME_START"] "(" ENVIRON["IWT_TARGET"] ")" ENVIRON["IWT_NAME_END"])
      shellre = "(^|[ \t|;&(])([^ \t|;&()<>]*/)?(bash|sh|zsh|ksh|dash)([ \t]|$)"
      blank = "[ \t]"
      nl = 0
      # A continuation is one command to the shell and two lines to everything here, and the
      # tripwire hands over the raw command: unjoined, `cp src \` + newline + a guarded path is
      # a write nobody attributes. An even run of trailing backslashes is a literal one.
      while ((getline line) > 0) {
        if (nl > 0 && trailing_bs(L[nl]) % 2) {
          sub(/\\$/, "", L[nl])
          L[nl] = L[nl] line
          continue
        }
        L[++nl] = line
      }
      i = 1
      while (i <= nl) {
        code = L[i]
        i++
        # A heredoc BODY carries no verb of its own, so it is not a command: it belongs to the one
        # that declared it, where an interpreter reading it names its target inside the payload.
        # `<<<` declares no body at all.
        ndel = 0
        rest = code
        while (match(rest, "<<<|<<-?[ \t]*(\"[^\"]*\"|" sq "[^" sq "]*" sq "|[^ \t|;&<>()]+)")) {
          tok = substr(rest, RSTART, RLENGTH)
          rest = substr(rest, RSTART + RLENGTH)
          if (tok ~ /^<<</) continue
          d = tok
          sub(/^<<-?[ \t]*/, "", d)
          # `<<\EOF` quotes the body the way `<<"EOF"` does; kept, the terminator is never found
          # and the body reads as commands.
          sub(/^\\/, "", d)
          gsub("[\"" sq "]", "", d)
          if (d == "") continue
          ndel++
          DEL[ndel] = d
          STRIP[ndel] = (tok ~ /^<<-/)
        }
        body = ""
        # A heredoc fed to a shell is a program, so its lines are commands in their own right.
        if (feedsshell(code)) ndel = 0
        for (k = 1; k <= ndel; k++) {
          stop = 0
          for (j = i; j <= nl; j++) {
            b = L[j]
            if (STRIP[k]) sub(/^\t+/, "", b)
            if (b == DEL[k]) { stop = j; break }
          }
          # A terminator that is not in the text means the body was already dropped by the caller
          # (instruction_shell_scan): reading to the end would swallow the next command whole.
          if (!stop) break
          for (j = i; j < stop; j++) body = body " " L[j]
          i = stop + 1
        }
        tokenize(code, body)
      }
    }' <<<"$1"
}

# Full ERE metacharacter set: a skill directory or a home path is free to contain (), + or ?, and
# an unescaped one silently changes what the pattern means.
instruction_ere_escape() {
  printf '%s' "$1" | sed 's#[][\.*^$/+?(){}|#]#\\&#g'
}

# A command text cut into its simple commands, NUL between them, so a write verb and a file name
# standing in two different commands are not read as one write: `cat <doc>; printf x > notes.md`
# reads one file and writes another. Split on `;`, `|`, `&` and newlines standing OUTSIDE quotes —
# a quoted run is one argument however many separators it carries, and cutting it would lose the
# quote state for everything after. A segment may itself span lines, hence the NUL.
instruction_split_commands() {
  awk -v sq="'" -v dq='"' '
    BEGIN {
      cmd = ""
      while ((getline line) > 0) cmd = cmd (read_any++ ? "\n" : "") line
      quote = ""; seg = ""
      for (i = 1; i <= length(cmd); i++) {
        c = substr(cmd, i, 1)
        if (quote != "") {
          seg = seg c
          if (quote == dq && c == "\\") { i++; seg = seg substr(cmd, i, 1); continue }
          if (c == quote) quote = ""
          continue
        }
        if (c == "\\") { i++; seg = seg c substr(cmd, i, 1); continue }
        if (c == sq || c == dq) { quote = c; seg = seg c; continue }
        if (c == ";" || c == "|" || c == "&" || c == "\n") { printf "%s%c", seg, 0; seg = ""; continue }
        seg = seg c
      }
      printf "%s%c", seg, 0
    }' <<<"$1"
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
  local dir
  case "$path" in
    "$home"/.claude/CLAUDE.md) printf 15682; return 0 ;;       # every session, every project
    */MEMORY.md|*/[Cc][Ll][Aa][Uu][Dd][Ee].[Mm][Dd]|*/[Cc][Ll][Aa][Uu][Dd][Ee].[Ll][Oo][Cc][Aa][Ll].[Mm][Dd])
      printf 3131; return 0 ;;                                 # every session of one project
    */.claude/instructions/*) printf 160; return 0 ;;          # loaded on topic
    */[Ss][Kk][Ii][Ll][Ll].[Mm][Dd]|*/.claude/skills/*) printf 90; return 0 ;;  # loaded on trigger
    */projects/*/memory/*.md) printf 160; return 0 ;;          # recalled when its topic comes up
  esac
  while IFS= read -r dir; do
    case "$path" in "$dir"/*) _instruction_class_rate "${dir##*/}"; return 0 ;; esac
  done < <(_instruction_class_dirs "$home")
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
# ~/.claude itself, because every markdown file under it is guarded, plus each directory it links
# into another repository: that repository's spelling is the one anybody editing it types.
instruction_guarded_dirs() {
  local home=${1:-$HOME} p
  [ -d "$home/.claude" ] && _instruction_emit "$home/.claude"
  while IFS= read -r p; do
    [ -d "$p" ] && _instruction_emit "$p"
  done < <(_instruction_class_dirs "$home")
  for p in "$home"/.claude/*; do
    [ -L "$p" ] && [ -d "$p" ] && _instruction_emit "$p"
  done
}

# The two carve-outs from the directory rule, asked of an absolute path the gate already matched.
# A memory file under ~/.claude/projects is the model's to write (see the MEMORY.md note above),
# and an ordinary markdown file inside a worktree is repository work, not instruction content: a
# worktree's own CLAUDE files and `.claude/` tree stay guarded like the repository's.
instruction_carved_out() { # abs-path [home]
  local p=$1 home=${2:-$HOME} rest
  printf '%s' "${p##*/}" | grep -Eqx "$INSTRUCTION_GUARDED_BASENAMES" && return 1
  case "$p" in "$home"/.claude/projects/*) return 0 ;; esac
  case "$p" in
    */.claude/worktrees/*/*)
      rest=${p##*/.claude/worktrees/}
      rest=/${rest#*/}
      case "$rest" in */.claude/*) return 1 ;; esac
      return 0
      ;;
  esac
  return 1
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

# $4, when given, is the command text: a path none of whose spellings can stand in it is skipped
# before the realpath its spellings cost, which is what keeps a set of hundreds affordable ahead of
# every Bash call. Every spelling ends in the file's own name unless the file is itself a link.
instruction_all_paths() {
  local home=${1:-$HOME} cwd=${2:-} root=${3:-} text=${4:-} p
  instruction_guarded_paths "$home" "$root" | while IFS= read -r p; do
    if [ -n "$text" ] && [ ! -L "$p" ]; then
      case "$text" in *"${p##*/}"*) ;; *) continue ;; esac
    fi
    printf '%s\n' "$p"
  done | _instruction_spell_all "$home" "$cwd"
}

instruction_all_dirs() {
  local home=${1:-$HOME} cwd=${2:-}
  instruction_guarded_dirs "$home" | _instruction_spell_all "$home" "$cwd"
}

# `git apply` and `git stash pop|apply` write files their command text never names. What they
# write is read off the patch — the command text itself (a heredoc) and every file the command
# names — and off the stash, relative to the repository's top level (the directory outside one).
instruction_git_landing() { # command cwd → absolute paths, one per line
  local cmd=$1 cwd=${2:-$PWD} seg gcwd i n sub w ro real dir top ref f base strip next
  local apply='' stash='' gcwds='' files='' strips='' sh_cwd=$cwd
  local -a words
  case "$cmd" in *git*) ;; *) return 0 ;; esac
  while IFS= read -r -d '' seg; do
    words=()
    read -r -a words <<<"$(printf '%s' "$seg" | tr -d "\"'" | tr '\n()<>' '     ')"
    if [ "${words[0]:-}" = cd ]; then
      sh_cwd=$(cd "$sh_cwd" 2>/dev/null && cd "${words[1]:-$HOME}" 2>/dev/null && pwd) || sh_cwd=$cwd
      continue
    fi
    n=${#words[@]} i=0 gcwd=$sh_cwd
    while [ "$i" -lt "$n" ] && [ "${words[$i]##*/}" != git ]; do i=$((i + 1)); done
    [ "$i" -lt "$n" ] || continue
    i=$((i + 1))
    while [ "$i" -lt "$n" ]; do
      case "${words[$i]}" in
        -C) gcwd=$(cd "$gcwd" 2>/dev/null && cd "${words[$((i + 1))]:-.}" 2>/dev/null && pwd) || gcwd=$sh_cwd
            i=$((i + 2)) ;;
        -c) i=$((i + 2)) ;;
        -*) i=$((i + 1)) ;;
        *) break ;;
      esac
    done
    sub=${words[$i]:-}
    top=$(git -C "$gcwd" rev-parse --show-toplevel 2>/dev/null) || top=$gcwd
    case "$sub" in
      apply)
        ro='' real='' dir='' strip=1 next=''
        for w in "${words[@]:$((i + 1))}"; do
          [ -z "$next" ] || { strip=$w; next=''; continue; }
          case "$w" in
            --check|--stat|--numstat|--summary) ro=1 ;;
            --apply|--index|-3|--3way) real=1 ;;
            --directory=*) dir=${w#--directory=}/ ;;
            -p) next=1 ;;
            -p*) strip=${w#-p} ;;
          esac
        done
        [ -n "$ro" ] && [ -z "$real" ] && continue
        case "$strip" in ''|*[!0-9]*) strip=1 ;; esac
        apply="$apply$top/$dir"$'\n'
        gcwds="$gcwds$gcwd"$'\n'
        strips="$strips$strip"$'\n'
        ;;
      stash)
        case "${words[$((i + 1))]:-}" in pop|apply) ;; *) continue ;; esac
        ref=''
        for w in "${words[@]:$((i + 2))}"; do
          case "$w" in -*) ;; *) ref=$w; break ;; esac
        done
        stash="$stash$( { git -C "$gcwd" stash show --name-only --include-untracked ${ref:+"$ref"} 2>/dev/null ||
          git -C "$gcwd" stash show --name-only ${ref:+"$ref"} 2>/dev/null; } | sed "s#^#$top/#")"$'\n'
        ;;
    esac
  done < <(instruction_split_commands "$cmd")
  [ -z "$stash" ] || printf '%s' "$stash" | grep .
  [ -n "$apply" ] || return 0
  read -r -a words <<<"$(printf '%s' "$cmd" | tr -d "\"'" | tr '\n()<>;|&' '         ')"
  for w in ${words[@]+"${words[@]}"}; do
    while IFS= read -r base; do
      [ -n "$base" ] || continue
      case "$w" in /*) f=$w ;; *) f=$base/$w ;; esac
      [ -f "$f" ] && [ -r "$f" ] && { files="$files$f"$'\n'; break; }
    done <<<"$cwd"$'\n'"$gcwds"
  done
  { printf '%s\n' "$cmd"
    printf '%s' "$files" | while IFS= read -r f; do [ -z "$f" ] || head -c 20000000 "$f"; done
  } | sed -n -e 's#^+++ #P #p' -e 's#^--- #P #p' -e 's#^rename to #R #p' -e 's#^copy to #R #p' |
    cut -f1 | sort -u | while read -r kind f; do
      [ -n "$f" ] && [ "$f" != /dev/null ] || continue
      if [ "$kind" = R ]; then
        printf '%s\n' "$f"
      else
        printf '%s' "$strips" | sort -u | while IFS= read -r strip; do
          n=$strip w=$f
          while [ "$n" -gt 0 ]; do
            case "$w" in */*) w=${w#*/} ;; *) w=''; break ;; esac
            n=$((n - 1))
          done
          [ -z "$w" ] || printf '%s\n' "$w"
        done
      fi
    done | sort -u | while IFS= read -r f; do
      printf '%s' "$apply" | while IFS= read -r base; do [ -z "$base" ] || printf '%s%s\n' "$base" "$f"; done
    done
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
# 0 = a stamp of this caller's is there and old enough to spend; 3 = a stamp no denial of this
# session minted (`denied/<hash>` in the watch state is missing, names another session or is past
# the stamp's day, or the session's transcript holds no denial carrying the stamp's tag) —
# removed, and the caller refuses and journals it.
instruction_stamp_ready() { # dir hash session [transcript]
  local dir=$1 hash=$2 sid=${3:-} transcript=${4:-} stamp now born age=''
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
  if mkdir "$stamp" 2>/dev/null; then
    _instruction_deny_record "$hash" "$sid" || rmdir "$stamp" 2>/dev/null
    return 1
  fi
  [ -d "$stamp" ] || return 1
  if ! _instruction_deny_record_ok "$hash" "$sid"; then
    rmdir "$stamp" 2>/dev/null
    return 3
  fi
  now=$(date +%s 2>/dev/null)
  born=$(stat -f %m "$stamp" 2>/dev/null)
  if [ -n "$now" ] && [ -n "$born" ]; then
    case "$now$born" in *[!0-9]*) ;; *) age=$((now - born)) ;; esac
  fi
  [ -n "$age" ] && [ "$age" -ge 2 ] || return 1
  if ! _instruction_deny_witnessed "$hash" "$transcript"; then
    rmdir "$stamp" 2>/dev/null
    return 3
  fi
  return 0
}

# The tag a stamp-minting denial carries in its reason, and the proof the retry looks for.
instruction_denial_tag() { # hash
  printf '(denial %s)' "$1"
}

# `denied/<hash>` lives in a cache the model can write and its name is computable, so the record
# alone proves nothing: the harness writes every denial reason into the transcript as an is_error
# tool_result behind its own `PreToolUse:<tool> hook error: ` prefix, a text no tool of the model's
# can start with. No readable transcript
# is no evidence either way, as for the audit read. Asked only of an aged stamp: a twin in the same
# batch arrives before the harness has written the first denial.
_instruction_deny_witnessed() { # hash transcript
  local tag
  [ -n "${2:-}" ] && [ -r "$2" ] && [ -s "$2" ] || return 0
  tag=$(instruction_denial_tag "$1")
  grep -F "$tag" "$2" 2>/dev/null | jq -eR --arg tag "$tag" '
    fromjson? | select(type == "object" and .type == "user")
    | .message.content? | arrays | .[]
    | select(type == "object" and .type == "tool_result" and .is_error == true)
    | (.content | if type == "string" then . else ([.[]? | objects | .text? | strings] | join("")) end)
    | select(test("^(PreToolUse:[A-Za-z]+ hook error: )?Instruction(-bloat)? gate: ") and contains($tag))' >/dev/null 2>&1
}

instruction_stamp_consume() {
  rmdir "$1/$2" 2>/dev/null || return 1
  rm -f "$(instruction_watch_state)/denied/$2" 2>/dev/null
  return 0
}

_instruction_deny_record() { # hash session
  local d
  d="$(instruction_watch_state)/denied"
  mkdir -p "$d" 2>/dev/null || return 1
  find "$d" -mindepth 1 -maxdepth 1 -type f -mmin +1440 -delete 2>/dev/null
  printf '%s %s\n' "${2:--}" "$(date +%s)" >"$d/$1" 2>/dev/null
}

_instruction_deny_record_ok() { # hash session
  local who='' at='' now
  read -r who at _ <"$(instruction_watch_state)/denied/$1" 2>/dev/null || return 1
  [ "$who" = "${2:--}" ] || return 1
  case "$at" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  [ $((now - at)) -ge 0 ] && [ $((now - at)) -lt 86400 ]
}

instruction_user_turn_after_stamp() {
  local transcript=$1 stamp=$2 born
  [ -r "$transcript" ] && [ -d "$stamp" ] || return 1
  born=$(stat -f %Fm "$stamp" 2>/dev/null) || return 1
  jq -en --arg born "$born" '$born | tonumber' >/dev/null 2>&1 || return 1
  jq -eR --argjson born "$born" '
    def timestamp_epoch:
      . as $stamp
      | (($stamp | capture("\\.(?<fraction>[0-9]+)") // {fraction: "0"}).fraction)
        as $fraction
      | ($stamp | sub("\\.[0-9]+"; "") | sub("\\+00:?00$"; "Z") | fromdateiso8601?)
        + (("0." + $fraction) | tonumber);
    fromjson?
    | select(type == "object" and .type == "user")
    | select((.isMeta // false) != true and (.isSidechain // false) != true)
    | select(.message.role? == "user")
    | select(
        (.message.content? | type) == "string"
        or ((.message.content? | type) == "array"
            and any(.message.content[]?; type != "object" or .type? != "tool_result"))
      )
    | (.timestamp? | strings | timestamp_epoch) as $at
    | select($at > $born)
  ' "$transcript" >/dev/null 2>&1
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

instruction_watch_state() {
  printf '%s' "${INSTRUCTION_WATCH_STATE:-$HOME/.cache/claude-instruction-watch}"
}

# A session id that cannot name a file gets one per CALLER (the parent is the CLI that runs every
# hook of one session), never a name every such caller shares and never one per call.
instruction_sid_name() { # session
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) printf 'unknown-%s' "$PPID" ;;
    *) printf '%s' "$1" ;;
  esac
}

instruction_now() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    printf '%s' "${EPOCHREALTIME/,/.}"
    return 0
  fi
  perl -MTime::HiRes=time -e 'printf "%.6f", time' 2>/dev/null || date +%s
}

# Integer nanoseconds: a float loses the digits that separate two writes a millisecond apart.
instruction_ns() { # epoch[.fraction]
  local s=${1%%.*} f=''
  case "$1" in *.*) f=${1#*.} ;; esac
  case "$s" in ''|*[!0-9]*) return 1 ;; esac
  case "$f" in *[!0-9]*) return 1 ;; esac
  f="${f}000000000"
  printf '%s' "$((s * 1000000000 + 10#${f:0:9}))"
}

# PreToolUse marks the call in flight and PostToolUse `check` consumes the mark: bytes whose mtime
# lies between the two are this call's. One file per call, `inflight/<session>@<tool_use_id>`, one
# line `<start> <tool_use_id> <tool> <cwd>`: parallel calls of one session each keep their own
# window, and a deny takes back only the mark its own call wrote.
instruction_inflight_mark() { # session tool_use_id tool cwd
  local dir now id=${2:-} cwd=${4:--}
  INSTRUCTION_INFLIGHT_FILE=''
  dir="$(instruction_watch_state)/inflight"
  mkdir -p "$dir" 2>/dev/null || return 1
  now=$(instruction_now)
  [ -n "$id" ] || id="${now%%.*}-$$"
  id=${id//[^A-Za-z0-9._-]/_}
  cwd=${cwd//$'\n'/ }
  INSTRUCTION_INFLIGHT_FILE="$dir/$(instruction_sid_name "$1")@$id"
  printf '%s %s %s %s\n' "$now" "$id" "${3:--}" "$cwd" >"$INSTRUCTION_INFLIGHT_FILE" 2>/dev/null
}

instruction_inflight_clear() {
  [ -z "${INSTRUCTION_INFLIGHT_FILE:-}" ] || rm -f "$INSTRUCTION_INFLIGHT_FILE" 2>/dev/null
  return 0
}

instruction_chat_name() { # session
  local resolver=''
  [ -n "${1:-}" ] || return 1
  resolver=$(command -v chat-name 2>/dev/null) || resolver=''
  [ -n "$resolver" ] || { [ ! -x "$HOME/.local/bin/chat-name" ] || resolver=$HOME/.local/bin/chat-name; }
  [ -n "$resolver" ] || return 1
  "$resolver" "$1" 2>/dev/null
}

instruction_alert_sendable() {
  command -v "${INSTRUCTION_WATCH_ALERT:-hs}" >/dev/null 2>&1
}

# File names stay in the JSON journal, never in the Lua command.
instruction_alert_poke() {
  local alert=${INSTRUCTION_WATCH_ALERT:-hs}
  command -v "$alert" >/dev/null 2>&1 || return 1
  ( "$alert" -c 'local ok, m = pcall(require, "instruction-watch"); if ok then m.pump() end' \
      >/dev/null 2>&1 & ) &
  return 0
}

instruction_journal_line() { # kind session summary [count] [file]
  local sent=unsent chat='' id
  instruction_alert_sendable && sent=attempted
  [ -z "$2" ] || chat=$(instruction_chat_name "$2") || chat=''
  id=$(printf '%s\n%s\n%s\n%s\n' "$1" "$$" "$RANDOM" "$(instruction_now)" | shasum -a 256 | cut -c1-16)
  jq -cn --arg id "$id" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg sid "$2" --arg kind "$1" \
    --arg summary "$3" --arg sent "$sent" --arg count "${4:-}" --arg file "${5:-}" --arg chat "$chat" \
    '{id:$id,at:$at,sid:$sid,kind:$kind,summary:$summary,sent:$sent,
      files:(if $file == "" then [] else [$file] end),bytes:[],restores:[],reverted:[]} +
      (if $count != "" then {count:($count|tonumber)} else {} end) +
      (if $chat != "" then {chat:$chat} else {} end)' 2>/dev/null
}

instruction_stamp_forged() { # path session
  local line
  line=$(instruction_journal_line stamp-forged "$2" \
    "STAMP-FORGED $1 (a retry stamp no denial of this session minted)" '' "$1") || return 1
  [ -n "$line" ] && instruction_journal_append "$line" || return 1
  instruction_alert_poke || true
}

# The append and the trim share one short mkdir lock: a tail-then-mv drops a line another session
# appends between the two, after that session has already claimed its marker.
instruction_journal_append() { # json-line
  local state journal lock i=0 born now n max=${INSTRUCTION_WATCH_JOURNAL_MAX:-200}
  state=$(instruction_watch_state)
  journal="$state/events.jsonl"
  lock="$state/journal.lock"
  mkdir -p "$state" 2>/dev/null || return 1
  while ! mkdir "$lock" 2>/dev/null; do
    born=$(stat -f %m "$lock" 2>/dev/null) || born=
    now=$(date +%s)
    if [ -n "$born" ] && [ $((now - born)) -gt 30 ]; then
      rmdir "$lock" 2>/dev/null || true
    fi
    i=$((i + 1))
    [ "$i" -lt 50 ] || return 1
    sleep 0.02
  done
  printf '%s\n' "$1" >>"$journal" 2>/dev/null || { rmdir "$lock" 2>/dev/null; return 1; }
  n=$(wc -l <"$journal" 2>/dev/null) || n=0
  if [ "${n:-0}" -gt $((max * 2)) ] 2>/dev/null; then
    _instruction_journal_trim "$journal" "$state/receipts" "$max"
  fi
  rmdir "$lock" 2>/dev/null || true
  return 0
}

# Only a record Hammerspoon has receipted is trimmed. Unreceipted ones stay up to twice the cap;
# past it the oldest go and ONE `dropped` record carrying their count (and any earlier unreceipted
# `dropped` record's) is appended, so the bound reports itself instead of losing changes silently.
_instruction_journal_trim() { # journal receipts max
  local j=$1 rdir=$2 max=$3 line id kind count k carry=0 nu=0 nr=0 cut_r cut_u out need_d=''
  local -a lines=() cls=()
  while IFS= read -r line <&3 && IFS=$'\t' read -r id kind count <&4; do
    if [ -n "$id" ] && [ -e "$rdir/$id" ]; then
      cls+=(r); nr=$((nr + 1))
    elif [ "$kind" = dropped ]; then
      case "$count" in ''|*[!0-9]*) count=1 ;; esac
      cls+=(d); carry=$((carry + count))
    else
      cls+=(u); nu=$((nu + 1))
    fi
    lines+=("$line")
  done 3<"$j" 4< <(jq -R -r '(fromjson? // {}) | (if type == "object" then . else {} end)
      | [(.id // "" | tostring), (.kind // "" | tostring), (.count // 1 | tostring)] | @tsv' "$j" 2>/dev/null)
  [ "${#lines[@]}" -gt 0 ] || return 0
  cut_u=0
  if [ "$carry" -gt 0 ] || [ "$nu" -gt $((max * 2)) ]; then
    need_d=1
    [ "$nu" -le $((max * 2 - 1)) ] || cut_u=$((nu - (max * 2 - 1)))
  fi
  cut_r=$((nr + nu - cut_u - max))
  [ -z "$need_d" ] || cut_r=$((cut_r + 1))
  [ "$cut_r" -gt 0 ] || cut_r=0
  [ "$cut_r" -le "$nr" ] || cut_r=$nr
  out="$j.$$"
  : >"$out" 2>/dev/null || return 1
  for k in "${!lines[@]}"; do
    case "${cls[$k]}" in
      r) if [ "$cut_r" -gt 0 ]; then cut_r=$((cut_r - 1)); continue; fi ;;
      d) continue ;;
      u) if [ "$cut_u" -gt 0 ]; then cut_u=$((cut_u - 1)); carry=$((carry + 1)); continue; fi ;;
    esac
    printf '%s\n' "${lines[$k]}" >>"$out"
  done
  if [ -n "$need_d" ]; then
    instruction_journal_line dropped '' \
      "DROPPED $carry instruction-change records Hammerspoon never receipted (the journal bound)" \
      "$carry" >>"$out" || { rm -f "$out"; return 1; }
  fi
  mv "$out" "$j" 2>/dev/null || rm -f "$out" 2>/dev/null
}
