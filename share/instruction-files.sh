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
INSTRUCTION_GUARDED_BASENAMES='(CLAUDE\.md|CLAUDE\.local\.md|review-debt-ignore)'

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

# Depth-unbounded, because the write gate's directory rule and the bloat gate's ancestor walk
# both are: a doc at docs/topic/sub/note.md is denied a shell write and priced per month, and a
# glob that stopped one level down left exactly those files guarded but unwatched. -L because
# docs/ and agents/ are symlinks into the config repository and the tree below them is the point.
# -print0 so a name carrying a newline arrives whole and is refused by _instruction_emit rather
# than arriving as two names.
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

_instruction_class_files() {
  local home=${1:-$HOME} p e
  local -a dirs=() name_args=()
  while IFS= read -r p; do dirs+=("$p"); done < <(_instruction_class_dirs "$home")
  for e in $INSTRUCTION_MD_EXTENSIONS; do
    [ "${#name_args[@]}" -eq 0 ] || name_args+=(-o)
    name_args+=(-name "*.$e")
  done
  while IFS= read -r -d '' p; do
    _instruction_emit "$p"
  done < <(find -L "${dirs[@]}" -type f \( "${name_args[@]}" \) -print0 2>/dev/null)
}

# What the TRIPWIRE watches: the guarded set plus settings.json, which no gate speaks for.
# settings.json is not an instruction file — nothing re-reads it into a context window — and the
# harness rewrites it whenever Egor switches model or permission mode, so denying writes to it
# cost him a tactical "ok" and caught nothing. What it does hold is these very hooks, and it is
# the one watched file git cannot give back, so it stays reported and its bytes stay kept.
instruction_visible_paths() {
  local home=${1:-$HOME}
  [ -f "$home/.claude/settings.json" ] && _instruction_emit "$home/.claude/settings.json"
  instruction_guarded_paths "$home"
}

# What the write GATE guards.
instruction_guarded_paths() {
  local home=${1:-$HOME} p
  for p in "$home"/.claude/CLAUDE.md "$home"/.claude/CLAUDE.local.md; do
    [ -f "$p" ] && _instruction_emit "$p"
  done
  _instruction_class_files "$home"
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
    review-debt-ignore) printf debt ;;
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
    { cmd = cmd (nread++ ? "\n" : "") $0 }
    END {
      hdre = "<<-?[ \t]*(" dq "[^" dq "]*" dq "|" sq "[^" sq "]*" sq "|[A-Za-z_][A-Za-z_0-9]*)"
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
        while (match(rest, hdre)) {
          tok = substr(rest, RSTART, RLENGTH)
          rest = substr(rest, RSTART + RLENGTH)
          strip = (tok ~ /^<<-/)
          d = tok
          sub(/^<<-?[ \t]*/, "", d)
          sub("^[" dq sq "]", "", d)
          sub("[" dq sq "]$", "", d)
          if (d == "") continue
          ndel++
          DEL[ndel] = d
          STRIP[ndel] = strip
        }
        i++
        for (k = 1; k <= ndel; k++) {
          while (i <= nl) {
            b = L[i]
            i++
            if (STRIP[k]) sub(/^[ \t]+/, "", b)
            if (b == DEL[k]) break
          }
        }
      }
      out = ""
      n = length(text)
      i = 1
      while (i <= n) {
        c = substr(text, i, 1)
        if (c == "\\") { out = out "Q"; i += 2; continue }
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
          if (live) out = out body
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

# A word that hands quoted TEXT to a shell parser. Once one of these stands in a command the
# quoted runs are a program rather than data, and reading them as data hides the write they
# perform — an interpreter handed a quoted program that redirects into a guarded file — so the
# caller reads the raw command instead. Only names that re-parse text belong here: env, nohup and
# setsid execute argv and unquote nothing, and python/perl/node hand their payload to a language
# the write gate reads with a rule of its own.
INSTRUCTION_INTERPRETER_RE='(^|[[:space:]|;&(])([^[:space:]|;&()<>]*/)?(bash|sh|zsh|ksh|dash|eval|xargs|ssh|osascript)([[:space:]]|$)'
# A word in COMMAND position this scan cannot resolve — a collapsed quoted run, a `$(...)`, a bare
# variable — is an executable it cannot name, and one of the names above is exactly what it may be.
INSTRUCTION_CMD_POSITION_RE='(^|[;|&(])[[:space:]]*(Q|\$\(|\$\{?[A-Za-z_][A-Za-z_0-9]*\}?([[:space:]]|$))'
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
  set -- "($1)" "$2" "$3"
  printf '%s' "${_INSTRUCTION_IW}(open\([[:space:]]*${_INSTRUCTION_Q}${1}${_INSTRUCTION_Q}[[:space:]]*,[[:space:]]*(mode[[:space:]]*=[[:space:]]*)?$2|open\([^()]*,[[:space:]]*$2[[:space:]]*,[[:space:]]*${_INSTRUCTION_Q}${1}|Path\([[:space:]]*${_INSTRUCTION_Q}${1}${_INSTRUCTION_Q}[[:space:]]*\)[[:space:]]*\.(write_text|write_bytes|open\([[:space:]]*$2)|$3\([[:space:]]*${_INSTRUCTION_Q}${1}|(shutil\.copy[a-z_0-9]*|copyfile)\([^()]*,[[:space:]]*${_INSTRUCTION_Q}${1}|File\.write\([[:space:]]*${_INSTRUCTION_Q}${1})"
}

instruction_interp_write_re() { # names-alternation → ERE matching a write to one of them
  _instruction_interp_rule "$1" "$_INSTRUCTION_MODE" "(write|append)File(Sync)?"
}

instruction_interp_trunc_re() { # names-alternation → ERE matching a write that can shrink one
  _instruction_interp_rule "$1" "$_INSTRUCTION_TRUNC_MODE" "writeFile(Sync)?"
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
  IWT_TARGET=$2 IWT_NAME_START=$INSTRUCTION_NAME_START IWT_NAME_END=$INSTRUCTION_NAME_END \
  awk -v sq="'" -v bq='`' '
    function addword() {
      if (word != "") { W[++nw] = word; word = "" }
    }
    # One word from position p, quotes dropped and escapes taken literally, stopping where the
    # shell would: at blank, at a separator, at the next redirection.
    function readword(code,   w, c) {
      w = ""
      while (p <= length(code)) {
        c = substr(code, p, 1)
        if (c == "\\") { p++; w = w substr(code, p, 1); p++; continue }
        if (c == "\"" || c == sq) { p++; continue }
        if (c ~ blank || c == ";" || c == "|" || c == "&" || c == "(" || c == ")" ||
            c == bq || c == ">" || c == "<") break
        w = w c
        p++
      }
      return w
    }
    function emit(kind, mode, verb, name, whole) {
      if (name == "") return
      if (whole && name !~ exact) return
      printf "%s\t%s\t%s\t%s\n", kind, mode, verb, name
    }
    # An option carrying this letter anywhere in the run: an in-place editor and an appending tee
    # are as often folded into a bundle as they are typed alone.
    function flagged(from, letter, long,   j) {
      for (j = from + 1; j <= nw; j++) {
        if (W[j] == long) return 1
        if (W[j] ~ "^-[A-Za-z]*" letter) return 1
      }
      return 0
    }
    function scan_loose(text, verb,   s, m, name, at, len) {
      s = text
      while (match(s, bounded)) {
        # The inner match overwrites RSTART/RLENGTH, so where this one stood is remembered first
        # or the scan re-reads the same name until the text runs out.
        at = RSTART; len = RLENGTH
        m = substr(s, at, len)
        name = m
        if (match(m, target)) name = substr(m, RSTART, RLENGTH)
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
        else if (base ~ /^(perl|python[0-9.]*|ruby|node|bun|deno)$/) vkind = "loose"
        else if (base ~ /^(truncate|dd|patch|ed|ex)$/) vkind = "dest"
        else if (base == "sed" && flagged(j, "i", "--in-place")) vkind = "dest"
        else if (base ~ /^(cp|mv|ln|install)$/) vkind = "copy"
      }
      if (vkind == "tee" || vkind == "dest") {
        mode = (vkind == "tee" && flagged(vi, "a", "--append")) ? "append" : "trunc"
        for (j = vi + 1; j <= nw; j++) {
          if (W[j] ~ /^-/) continue
          emit("verb", mode, verb, W[j], 1)
          # dd names its destination in an operand of its own.
          if (W[j] ~ /^of=/) {
            dest = W[j]
            sub(/^of=/, "", dest)
            emit("verb", mode, verb, dest, 1)
          }
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
            if (dest == "" || dest == ".") {
              emit("copy", "trunc", verb, src, 1)
              emit("copy", "trunc", verb, "./" src, 1)
            } else emit("copy", "trunc", verb, dest "/" src, 1)
          }
        }
      } else if (vkind == "loose") {
        scan_loose(rawtext " " body, verb)
      }
      nw = 0; word = ""
    }
    function tokenize(code, body,   n, c, prev, op, c2, dest, cstart) {
      nw = 0; word = ""
      n = length(code)
      p = 1
      cstart = 1
      while (p <= n) {
        c = substr(code, p, 1)
        prev = (p > 1) ? substr(code, p - 1, 1) : ""
        if (c == "#" && word == "" && (p == 1 || prev ~ blank)) break
        if (c == "\\") { p++; word = word substr(code, p, 1); p++; continue }
        if (c == "\"" || c == sq) { p++; continue }
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
          else if (c2 == "&") { p++; readword(code); continue }
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
          else if (c2 == "&" || c2 == ">") p++
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
      target = ENVIRON["IWT_TARGET"]
      exact = "^(" target ")$"
      bounded = ENVIRON["IWT_NAME_START"] "(" target ")" ENVIRON["IWT_NAME_END"]
      blank = "[ \t]"
      nl = 0
      while ((getline line) > 0) L[++nl] = line
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
          gsub("[\"" sq "]", "", d)
          if (d == "") continue
          ndel++
          DEL[ndel] = d
          STRIP[ndel] = (tok ~ /^<<-/)
        }
        body = ""
        for (k = 1; k <= ndel; k++) {
          stop = 0
          for (j = i; j <= nl; j++) {
            b = L[j]
            if (STRIP[k]) sub(/^[ \t]+/, "", b)
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
  while IFS= read -r p; do
    [ -d "$p" ] && _instruction_emit "$p"
  done < <(_instruction_class_dirs "$home")
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
