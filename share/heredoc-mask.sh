#!/usr/bin/env bash
# The heredoc body masker every door that reads a command as syntax shares (worker-launch-gate,
# worker-git-guard). A heredoc body is text a command is FED, so it is blanked while the line
# structure that says where the body ends is still intact. The `<<` has to be a REAL heredoc before
# anything is blanked: outside quotes, and with its delimiter line actually present later. A `<<`
# inside quotes is text — `echo '<<X'; worker-run wait id` is a run — and one whose delimiter never
# arrives opens no body at all, so blanking from it would swallow every command that follows. The
# one heredoc whose body is not text is the one fed to a SHELL, which runs those lines: the caller
# says what that looks like, $1 matched against the text before the `<<`, $2 against the text after.

heredoc_mask() { # shell-fed-before-re shell-fed-after-re < command → command, bodies blanked
  awk -v shellfed="$1" -v postshell="$2" '
       # Everything a heredoc body still EXECUTES when its delimiter is unquoted: the shell expands
       # such a body, so `$( … )` and a backtick span inside it are command lines, and masking them
       # with the text around them would blank a run the shell is about to make. Their contents are
       # kept, chained with `;`, and everything else on the line goes.
       function subst_only(s,   i, c, out, buf) {
         out = ""; buf = ""
         for (i = 1; i <= length(s); i++) {
           c = substr(s, i, 1)
           if (c == "\\") { if (SD > 0 || BT) buf = buf c substr(s, i + 1, 1); i++; continue }
           if (SD > 0) {
             if (c == "(") SD++
             else if (c == ")" && --SD == 0) { out = out buf ";"; buf = ""; continue }
             buf = buf c
             continue
           }
           if (BT) {
             if (c == "`") { BT = 0; out = out buf ";"; buf = ""; continue }
             buf = buf c
             continue
           }
           if (c == "$" && substr(s, i + 1, 1) == "(") { SD = 1; i++ }
           else if (c == "`") BT = 1
         }
         if (buf != "") out = out buf ";"
         return out
       }
       function find_heredoc(line,   i, c, q, rest) {
         q = ""
         for (i = 1; i <= length(line); i++) {
           c = substr(line, i, 1)
           # A backslash escapes inside DOUBLE quotes and outside them, never inside single ones.
           # Missing that, `echo "a\"b <<EOF"` closes the quote a character early and the rest of
           # the line reads as bare text, so the `<<EOF` inside the string is taken for a real
           # heredoc and blanks the commands that follow it.
           if (q != "") {
             if (q == "\"" && c == "\\") { i++; continue }
             if (c == q) q = ""
             continue
           }
           if (c == "\\") { i++; continue }
           if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[[:space:];&|(]/)) return 0
           if (c == "\047" || c == "\"") { q = c; continue }
           if (c != "<") continue
           # A herestring is not a heredoc, and its word would read as a delimiter that never closes.
           if (substr(line, i, 3) == "<<<") { i += 2; continue }
           if (substr(line, i + 1, 1) != "<") continue
           rest = substr(line, i)
           if (match(rest, /^<<-?[[:space:]]*("[^"]*"|\047[^\047]*\047|\\?[A-Za-z_][A-Za-z0-9_.-]*)/)) {
             HD_TOK = substr(rest, RSTART, RLENGTH)
             HD_PRE = substr(line, 1, i - 1)
             HD_POST = substr(line, i + RLENGTH)
             return 1
           }
           i++
         }
         return 0
       }
       { line[NR] = $0 }
       END {
         for (i = 1; i <= NR; i++) {
           if (!find_heredoc(line[i])) continue
           dash = (substr(HD_TOK, 3, 1) == "-")
           delim = HD_TOK
           sub(/^<<-?[[:space:]]*/, "", delim)
           # A quoted or backslashed delimiter is the one spelling that turns expansion OFF, so an
           # unexpanded body is inert text all the way down.
           expand = (delim !~ /^["\047\\]/)
           gsub(/["\047\\]/, "", delim)
           end = 0; SD = 0; BT = 0
           for (j = i + 1; j <= NR; j++) {
             probe = line[j]
             if (dash) sub(/^\t+/, "", probe)
             if (probe == delim) { end = j; break }
           }
           if (!end) continue
           mask[end] = 1
           if (HD_PRE !~ shellfed && HD_POST !~ postshell)
             for (k = i + 1; k < end; k++) {
               mask[k] = 1
               if (expand) keep[k] = subst_only(line[k])
             }
           i = end
         }
         for (i = 1; i <= NR; i++) print (i in mask) ? ((i in keep) ? keep[i] : "") : line[i]
       }'
}
