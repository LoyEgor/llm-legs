def value: if . == null then "" else tostring end;
# `(` is a separator and is barred from unquoted tokens: the cd-guard hook steers persistent `cd`
# into `(cd /path && cmd)`, where the path token would otherwise swallow the closing paren.
def tok: "\"(?:\\\\.|[^\"])*\"|'[^']*'|[^[:space:];&|()]+";
# Wrappers, assignments and shell keywords a cd or git hides behind. Nothing added to `lead` or
# `gopt` may capture: `bash_hit` reads the separator as `.captures[0]`.
def lead: "(?:(?:sudo|nohup|command|env|time|then|do|else|elif|if|while|until|for|\\{|!)[ \\t]+|timeout[ \\t]+-?[0-9][^ \\t\\n]*[ \\t]+|[A-Za-z_][A-Za-z0-9_]*=(?:\"[^\"]*\"|'[^']*'|[^ \\t\\n;&|()]*)[ \\t]+)*";
# git's global options may sit on either side of `-C`, which is never one of them.
def gopt: "(?:[ \t]+(?:-c[ \t]+" + "(?:" + tok + ")|--(?:git-dir|work-tree|namespace|config-env)[ \t]+" + "(?:" + tok + ")|-(?!C(?:[ \t]|$))[^ \t\n]+))*";
def git_mutating: ["checkout","switch","commit","merge","rebase","cherry-pick","revert","restore","stash","am","reset","pull","push","add","apply","fetch","tag","clean","rm","mv","branch"];
# A `cd` inside a heredoc body or a multi-line quoted string is text a command is fed, not a
# command. Masking preserves the line structure, so it can only lose a cd, never invent one.
def mask_heredocs:
  reduce (split("\n")[]) as $line ({out: [], delim: null, dash: false};
    if .delim != null then
      (if (if .dash then ($line | sub("^\t+"; "")) else $line end) == .delim
       then .delim = null else . end)
      | .out += [""]
    else
      .out += [$line]
      | ([$line | match("(?<!<)<<(?<dash>-?)[ \t]*(?<d>\"[^\"]*\"|'[^']*'|[A-Za-z_][A-Za-z0-9_.-]*)"; "g")][0]) as $open
      | if $open == null then .
        else
          .dash = (([$open.captures[] | select(.name == "dash") | .string][0]) == "-")
          | .delim = ([$open.captures[] | select(.name == "d") | .string][0]
                      | sub("^[\"']"; "") | sub("[\"']$"; ""))
        end
    end)
  | .out | join("\n");
# An apostrophe inside a double-quoted string is not a quote: left it in, `echo "it's"` would pair
# with the next apostrophe lines away and blank every command between them.
def mask_apostrophes:
  gsub("(?<s>\"(?:\\\\.|[^\"])*\")"; (.s | gsub("'"; " ")));
# Every quoted span is matched, but only a multi-line one is blanked: pairing quotes left to right
# is the point, or the closing quote of a QUOTED heredoc delimiter opens a span of its own.
def mask_quoted_spans:
  gsub("(?<s>'[^']*')"; (.s | if test("\n") then gsub("[^\n]"; " ") else . end))
  | gsub("(?<s>\"[^\"]*\")"; (.s | if test("\n") then gsub("[^\n]"; " ") else . end));
# A trailing `# …` is prose: its `;` and `(` would otherwise open a segment later than the real one.
def mask_comments:
  gsub("(?<q>\"(?:\\\\.|[^\"])*\"|'[^']*'|\\\\.)|(?<h>(?:^|[[:space:];&|(])#)(?<c>[^\n]*)";
    if .q != null then .q else .h + (.c | gsub("[^\n]"; " ")) end);
def masked: mask_heredocs | mask_apostrophes | mask_quoted_spans | mask_comments;
def unquote_word:
  gsub("\"(?<d>(?:\\\\.|[^\"])*)\"|'(?<s>[^']*)'|\\\\(?<e>.)";
    if .d != null then (.d | gsub("\\\\(?<c>.)"; .c)) elif .s != null then .s else .e end);
def expand_vars($vars):
  reduce ($vars | reverse[]) as $v (.;
    if startswith("'") then . else gsub("\\$(?:\\{" + $v.n + "\\}|" + $v.n + "(?![A-Za-z0-9_]))"; $v.v) end);
def abs_word: test("^(/|~(/|$)|\\$HOME(/|$)|\\$\\{HOME\\}(/|$))");
def write_verbs: ["tee","rm","touch","mkdir","truncate","patch","install"];
def dest_verbs: ["cp","mv","ln","rsync"];
def end_command:
  (if (.dest | abs_word) then .paths += [{p: .dest, o: .dest_at}] else . end)
  | (if .cmd == null then
       reduce .pending[] as $a (.; .vars |= (map(select(.n != $a.n)) + [$a]))
     else . end)
  | .pending = []
  | .bindings += [{o: .end_at, vars: .vars}]
  | .cmd = null | .write = false | .redirect = "" | .dest = "" | .dest_at = 0;
# The command's own `NAME=value` words are expanded first: chats name a worktree once
# (`W=/…/worktrees/x; sed -i '' … $W/f`) and then write only through the variable. The bindings
# outlive the walk, since `bash_hit` expands its own path tokens with them.
def bash_write_state:
  masked
  | [match("[0-9]*>>?&[0-9-]+|&?[0-9]*>>?[&|]?|<<?-?|[;&|()\\n]|(?:\"(?:\\\\.|[^\"])*\"|'[^']*'|\\\\.|[^[:space:];&|()<>\"'\\\\])+"; "g") | {s: .string, o: .offset}]
  | reduce .[] as $t ({vars: [], pending: [], bindings: [], end_at: 0, stack: [], cmd: null, write: false, redirect: "", dest: "", dest_at: 0, paths: []};
      $t.s as $s
      | if ($s | test("^[;&|()\\n]$")) then
        .end_at = $t.o | end_command
        | if $s == "(" then .stack += [.vars]
          elif $s == ")" then .vars = (.stack[-1] // .vars) | .stack = .stack[:-1]
            | .bindings += [{o: $t.o, vars: .vars}]
          else . end
      elif ($s | test("^[0-9]*>>?&[0-9-]")) then .
      elif ($s | test("^&?[0-9]*>>?[&|]?$")) then .redirect = (if ($s | test("^[02-9]")) then "skip" else "take" end)
      elif ($s | startswith("<")) then .redirect = "skip"
      else
        .vars as $vs
        | ($s | expand_vars($vs) | unquote_word) as $w
        | if .redirect != "" then
            (if .redirect == "take" and ($w | abs_word) and ($w | startswith("/dev/") | not)
             then .paths += [{p: $w, o: $t.o}] else . end)
            | .redirect = ""
          elif .cmd == null then
            if ($w | test("^[A-Za-z_][A-Za-z0-9_]*=")) then
              ($w | capture("^(?<n>[A-Za-z_][A-Za-z0-9_]*)=(?<v>.*)$"; "s")) as $a
              | .pending += [$a]
            elif (["export","sudo","command","env","nohup","time","then","do","else","elif","{","}","!","fi","done","if","while","until"] | index($w)) != null then .
            elif (["for","case","select"] | index($w)) != null then .cmd = $w
            else ($w | sub(".*/"; "")) as $c | .cmd = $c | .write = ((write_verbs | index($c)) != null)
            end
          elif .cmd as $c | (dest_verbs | index($c)) != null then
            if $w | startswith("-") then . else .dest = $w | .dest_at = $t.o end
          else
            (if (.cmd == "sed" and ($w | test("^(-[A-Za-z]*i|--in-place)")))
             then .write = true else . end)
            | if .write and ($w | abs_word) then .paths += [{p: $w, o: $t.o}] else . end
          end
      end)
  | .end_at = 2147483647 | end_command;
# The LAST write is the one that moves the tree, so the cap trims the oldest targets, not the newest.
def bash_write_paths: .paths | reverse | .[0:10] | map(.p) | join("\u001e");
def git_listing($sub; $args):
  ($args | [match(tok; "g").string | unquote_word]) as $a
  | if $sub == "branch" or $sub == "tag" then
      ($a | length) == 0 or any($a[];
        test("^--(show-current|list|contains|no-contains|merged|no-merged|points-at)(=|$)") or
        test("^-l$") or
        (if $sub == "branch" then test("^(-[arv]+|--(all|remotes|verbose))$")
         else test("^-n[0-9]*$") end))
    elif $sub == "fetch" then any($a[]; . == "--dry-run")
    else false end;
def shell_scope($at):
  [match("\"(?:\\\\.|[^\"])*\"|'[^']*'|[()]"; "g") | select(.offset <= $at)]
  | reduce .[] as $t ([]; if $t.string == "(" then . + [$t.offset]
                         elif $t.string == ")" then .[:-1] else . end);
def bash_hit($bindings):
  tok as $tok
  | masked
  | . as $command
  | [match("(^|[;&|(\\n])[[:space:]]*" + lead + "(?:(?:cd|pushd)[ \\t]+(?:-[LP@][ \\t]+)*(?<cd>" + $tok + ")|git(?:[ \\t]+-C[ \\t]+(?<wt_dir>" + $tok + "))?[ \\t]+worktree[ \\t]+(?<wt_verb>add|move)(?<wt_args>([ \\t]+(" + $tok + "))+)|git" + gopt + "(?:[ \\t]+-C[ \\t]+(?<dir>" + $tok + "))?" + gopt + "[ \\t]+(?<sub>[A-Za-z][A-Za-z-]*)(?:[ \\t]+(?<sub2>[A-Za-z][A-Za-z-]*))?(?<args>(?:[ \t]+(?:" + $tok + "))*))"; "g")]
  | map(
      .offset as $offset
      | ([$bindings[] | select(.o <= $offset)] | last | .vars // []) as $vars
      | ([.captures[] | select(.name == "cd" and .string != null) | .string][0] // "") as $cd_raw
      | ([.captures[] | select(.name == "wt_dir" and .string != null) | .string][0] // "") as $wt_dir
      | ([.captures[] | select(.name == "wt_verb" and .string != null) | .string][0] // "") as $wt_verb
      | ([.captures[] | select(.name == "wt_args" and .string != null) | .string][0] // "") as $wt_args
      | ([.captures[] | select(.name == "dir" and .string != null) | .string][0] // "") as $dir_raw
      | ([.captures[] | select(.name == "sub" and .string != null) | .string][0] // "") as $sub
      | ([.captures[] | select(.name == "sub2" and .string != null) | .string][0] // "") as $sub2
      | (([.captures[] | select(.name == "sub2") | .string][0] // "") + " " +
         ([.captures[] | select(.name == "args") | .string][0] // "")) as $args
      | (.captures[0].string // "") as $sep
      | .offset as $at
      | if $wt_args != "" then
          ([$wt_args | match($tok; "g").string | expand_vars($vars)]
           | reduce .[] as $arg ({path: "", option_arg: false};
               if $wt_verb == "move" then
                 if ($arg | startswith("-")) then . else .path = $arg end
               elif .path != "" then .
               elif .option_arg then .option_arg = false
               elif (["-b", "-B", "--reason"] | index($arg) != null) then .option_arg = true
               elif ($arg | startswith("-")) then .
               else .path = $arg end)
           | {path: .path, sep: "", worktree: "1", worktree_base: ($wt_dir | expand_vars($vars)), at: $at})
        elif $cd_raw != "" then
          ($cd_raw | expand_vars($vars)) as $cd
          | ($cd | unquote_word) as $cdw
          # `cd -` and a variable nothing in the command binds leave the shell's directory unknown:
          # the hit is kept so a later relative path is refused, never resolved against the cwd.
          | if ($cdw | test("^-")) or (($cdw | test("\\$")) and ($cdw | abs_word | not)) then {path: "", sep: $sep, cd_hit: "1", unknown: "1", worktree: "", worktree_base: "", at: $at}
            else {path: $cd, sep: $sep, cd_hit: "1", worktree: "", worktree_base: "", at: $at} end
        elif $sub != "" and (git_listing($sub; $args) | not) and (if $sub == "worktree"
                             then (["prune","repair","lock","unlock"] | index($sub2) != null)
                             else (git_mutating | index($sub) != null)
                             end) then
          ($dir_raw | expand_vars($vars)) as $dir
          | if ($dir | unquote_word | test("\\$")) and ($dir | unquote_word | abs_word | not) then empty
            # A mutating git with no `-C` runs where the tool ran: `.` resolves to the payload cwd,
            # or to the command's own earlier cd.
            else {path: (if $dir == "" then "." else $dir end), sep: $sep, mut: "1", worktree: "", worktree_base: "", at: $at} end
        else empty end)
  | map(. as $hit | . + {scope: ($command | shell_scope($hit.at))})
  | . as $hits
  | [$hits[] | select(.unknown != "1")] as $pick
  # A commit, push or worktree add is the strongest evidence of where the changes go, so a cd after
  # it — the read-only check of the tree just left, the bootstrap of the worktree just made — loses.
  | ([$pick[] | select(.worktree == "1" or .mut == "1")] | last) as $strong
  | (([$pick[] | select($strong == null or .cd_hit != "1" or .at < $strong.at)] | last)
     // {path: "", sep: "", worktree: "", worktree_base: ""}) as $last
  # Only a cd BEFORE the add: the bootstrap subshell after it cds into the new worktree itself,
  # and taking that one resolves a relative worktree path inside the tree that was just created.
  | (if $last.worktree == "1" and $last.worktree_base == "" then
       $last + {worktree_base: ([$pick[] | select(.cd_hit == "1" and .at < $last.at and .scope == $last.scope[0:(.scope | length)]) | .path] | last // "")}
     else $last end) as $last
  # A relative path resolves against this command's own earlier cds, not against the tool's cwd.
  | (reduce ($hits[] | select(.cd_hit == "1" and .at < ($last.at // 0) and .scope == $last.scope[0:(.scope | length)])) as $h (".";
       if . == null or $h.unknown == "1" then null
       else ($h.path | unquote_word) as $p | (if $p | abs_word then $p else . + "/" + $p end) end)) as $base
  | if $base == null and (($last.path // "") | test("^$|^-") | not) and (($last.path | unquote_word | abs_word) | not)
    then {path: "", sep: "", worktree: "", worktree_base: ""}
    else $last + {rel_base: (if ($base // ".") == "." then "" else $base end)} end;
def read_tools: ["cd","pushd","popd","cat","head","tail","less","ls","wc","grep","rg","find","stat","file","du","df","jq","awk","cut","sort","uniq","tr","basename","dirname","realpath","pwd","echo","printf","test","[","which","type","date","diff","cmp","tree","nl","column","git"];
def read_git_subs: ["log","show","status","diff","blame","shortlog","describe","rev-parse","rev-list","ls-files","ls-tree","grep","reflog","cat-file"];
def git_read($t):
  if any($t[]; startswith("--output")) then false
  elif ($t | length) == 0 then false
  else $t[0] as $head
    | if (["-C","-c","--git-dir","--work-tree","--namespace","--config-env"] | index($head)) != null then git_read($t[2:])
      elif ($head | startswith("-")) then git_read($t[1:])
      else (read_git_subs | index($head)) != null or git_listing($head; ($t[1:] | join(" ")))
      end
  end;
def drop_env($t):
  if ($t | length) > 0 and ($t[0] | test("^[A-Za-z_][A-Za-z0-9_]*=")) then drop_env($t[1:]) else $t end;
def segment_read_only:
  drop_env([splits("[[:space:]]+")] | map(select(. != ""))) as $t
  | if ($t | length) == 0 then true
    else ($t[0] | sub(".*/"; "")) as $cmd
      | if (read_tools | index($cmd)) == null then false
        elif $cmd == "git" then git_read($t[1:])
        elif $cmd == "sort" then all($t[1:][]; test("^-[A-Za-z]*o|^--output") | not)
        elif $cmd == "find" then all($t[1:][]; . as $arg | (["-delete","-exec","-execdir","-ok","-okdir","-fprint","-fprint0","-fprintf","-fls"] | index($arg)) == null)
        else true
        end
    end;
# Redirects that only discard output are neutralised first, so any surviving `>` condemns the
# command: that catches a write performed BY a reading tool (`git log > out`). Over-splitting
# quoted text can only call a read "work", never the reverse; a backtick hides a command.
def command_read_only:
  if test("`") then false
  else
    gsub("[0-9]*>>?[[:space:]]*/dev/null(?=[[:space:];&|()]|$)"; " ")
    | gsub("[0-9]*>&[0-9]+"; " ")
    | if test(">") then false
      else all(splits("[;&|()\\n]+"); segment_read_only)
      end
  end;
def worktree_path:
  (.tool_response // "")
  | (if type == "string" then . elif type == "object" then ([.. | strings] | join("\n")) else "" end)
  | ([capture("worktree at (?<wt>/[^\\n]+?)(?= on branch |\\n|$)")] | (.[0].wt // ""))
  | gsub("[[:space:]]+$"; "");
# Every absolute-looking token of the brief, in order, capped: the hook takes the first that is a
# directory in a repository, since a brief names the checkout the worker runs in first.
def dispatch_paths:
  [(.tool_input.prompt // ""), (.tool_input.description // "")]
  | map(if type == "string" then . else "" end)
  | join("\n")
  | [match("/[A-Za-z0-9._~@+/-]+"; "g") | .string]
  | map(sub("[\"'`,.:)]+$"; ""))
  | map(select(. != "" and . != "/"))
  | .[0:10]
  | join("\u001e");
(if .tool_name == "Bash" then ((.tool_input.command // "") | bash_write_state) else null end) as $ws
| (if .tool_name == "Bash" then ((.tool_input.command // "") | bash_hit($ws.bindings))
   else {path: "", sep: "", worktree: "", worktree_base: ""} end) as $bash
| ($ws.paths // [] | last) as $last_write
# A write in another tree after the cd or commit this command also carries is the later, stronger
# evidence; a worktree add stays the answer to its own command.
| (if $last_write != null and ($bash.worktree // "") != "1"
      and (($bash.path // "") == "" or $last_write.o > ($bash.at // -1))
   then "1" else "" end) as $writes_win
| [(.hook_event_name | value), (.tool_name | value), (.session_id | value | gsub("[^A-Za-z0-9_-]"; "")),
 (.cwd | value),
 (if (.agent_id | value) != "" or (.agent_type | value) != "" then "1" else "" end),
 (if .tool_name == "Edit" or .tool_name == "Write" then (.tool_input.file_path | value)
  elif .tool_name == "NotebookEdit" then (.tool_input.notebook_path | value)
  elif .tool_name == "Bash" then $bash.path
  elif .tool_name == "EnterWorktree" then worktree_path
  else "" end),
 (if ($bash.scope // [] | length) > 0 then "1" else "" end),
 (if .tool_name == "Bash" and ((.tool_input.command // "") | command_read_only) then "1" else "" end),
 ($bash.worktree // ""),
 ($bash.worktree_base // ""),
 ($bash.cd_hit // ""),
 (.tool_use_id | value | gsub("[^A-Za-z0-9_-]"; "")),
 (if .tool_name == "Task" or .tool_name == "Agent" then dispatch_paths else "" end),
 (if $ws == null then "" else ($ws | bash_write_paths) end),
 (if .hook_event_name == "SessionStart" then (.transcript_path | value) else "" end),
 ($bash.rel_base // ""),
 $writes_win]
| join("\u001f")
