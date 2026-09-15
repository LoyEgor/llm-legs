def value: if . == null then "" else tostring end;
# `(` is a separator and is barred from unquoted tokens: the cd-guard hook steers persistent `cd`
# into `(cd /path && cmd)`, where the path token would otherwise swallow the closing paren.
def tok: "\"(?:\\\\.|[^\"])*\"|'[^']*'|[^[:space:];&|()]+";
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
# Every quoted span is matched, but only a multi-line one is blanked: pairing quotes left to right
# is the point, or the closing quote of a QUOTED heredoc delimiter opens a span of its own.
def mask_quoted_spans:
  gsub("(?<s>'[^']*')"; (.s | if test("\n") then gsub("[^\n]"; " ") else . end))
  | gsub("(?<s>\"[^\"]*\")"; (.s | if test("\n") then gsub("[^\n]"; " ") else . end));
def bash_hit:
  tok as $tok
  | ((.tool_input.command // "") | mask_heredocs | mask_quoted_spans)
  | [match("(^|[;&|(\\n])[[:space:]]*((cd|pushd)[[:space:]]+(?<cd>" + $tok + ")|git([[:space:]]+-C[[:space:]]+(?<wt_dir>" + $tok + "))?[[:space:]]+worktree[[:space:]]+(?<wt_verb>add|move)(?<wt_args>([ \\t]+(" + $tok + "))+)|git[[:space:]]+-C[[:space:]]+(?<dir>" + $tok + ")([ \\t]+(?<sub>[A-Za-z][A-Za-z-]*))?([ \\t]+(?<sub2>[A-Za-z][A-Za-z-]*))?)"; "g")]
  | map(
      ([.captures[] | select(.name == "cd" and .string != null) | .string][0] // "") as $cd
      | ([.captures[] | select(.name == "wt_dir" and .string != null) | .string][0] // "") as $wt_dir
      | ([.captures[] | select(.name == "wt_verb" and .string != null) | .string][0] // "") as $wt_verb
      | ([.captures[] | select(.name == "wt_args" and .string != null) | .string][0] // "") as $wt_args
      | ([.captures[] | select(.name == "dir" and .string != null) | .string][0] // "") as $dir
      | ([.captures[] | select(.name == "sub" and .string != null) | .string][0] // "") as $sub
      | ([.captures[] | select(.name == "sub2" and .string != null) | .string][0] // "") as $sub2
      | (.captures[0].string // "") as $sep
      | .offset as $at
      | if $wt_args != "" then
          ([$wt_args | match($tok; "g").string]
           | reduce .[] as $arg ({path: "", option_arg: false};
               if $wt_verb == "move" then
                 if ($arg | startswith("-")) then . else .path = $arg end
               elif .path != "" then .
               elif .option_arg then .option_arg = false
               elif (["-b", "-B", "--reason"] | index($arg) != null) then .option_arg = true
               elif ($arg | startswith("-")) then .
               else .path = $arg end)
           | {path: .path, sep: "", worktree: "1", worktree_base: $wt_dir, at: $at})
        elif $cd != "" then {path: $cd, sep: $sep, cd_hit: "1", worktree: "", worktree_base: "", at: $at}
        elif $dir != "" and (if $sub == "worktree"
                             then (["prune","repair","lock","unlock"] | index($sub2) != null)
                             else (["checkout","switch","commit","merge","rebase","cherry-pick","revert","restore","stash","am","reset","pull"] | index($sub) != null)
                             end) then {path: $dir, sep: "", worktree: "", worktree_base: "", at: $at}
        else empty end)
  | . as $hits
  # A worktree add/move outranks every cd and mutating `git -C` in the same command: the add is
  # followed by a bootstrap subshell (`(cd $W && pnpm install)`) often enough that the last hit
  # lost the new worktree entirely.
  | (([$hits[] | select(.worktree == "1")] | last)
     // last
     // {path: "", sep: "", worktree: "", worktree_base: ""}) as $last
  # Only a cd BEFORE the add: the bootstrap subshell after it cds into the new worktree itself,
  # and taking that one resolves a relative worktree path inside the tree that was just created.
  | if $last.worktree == "1" and $last.worktree_base == "" then
      $last + {worktree_base: ([$hits[] | select(.cd_hit == "1" and .at < $last.at) | .path] | last // "")}
    else $last end;
def read_tools: ["cd","pushd","popd","cat","head","tail","less","ls","wc","grep","rg","find","stat","file","du","df","jq","awk","cut","sort","uniq","tr","basename","dirname","realpath","pwd","echo","printf","test","[","which","type","date","diff","cmp","tree","nl","column","git"];
def read_git_subs: ["log","show","status","diff","blame","shortlog","describe","rev-parse","rev-list","ls-files","ls-tree","grep","reflog","cat-file"];
def git_read($t):
  if any($t[]; startswith("--output")) then false
  elif ($t | length) == 0 then false
  else $t[0] as $head
    | if $head == "-C" or $head == "-c" then git_read($t[2:])
      elif ($head | startswith("-")) then git_read($t[1:])
      else (read_git_subs | index($head)) != null
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
  | join("");
(if .tool_name == "Bash" then bash_hit else {path: "", sep: "", worktree: "", worktree_base: ""} end) as $bash
| [(.hook_event_name | value), (.tool_name | value), (.session_id | value | gsub("[^A-Za-z0-9_-]"; "")),
 (.cwd | value),
 (if (.agent_id | value) != "" or (.agent_type | value) != "" then "1" else "" end),
 (if .tool_name == "Edit" or .tool_name == "Write" then (.tool_input.file_path | value)
  elif .tool_name == "NotebookEdit" then (.tool_input.notebook_path | value)
  elif .tool_name == "Bash" then $bash.path
  elif .tool_name == "EnterWorktree" then worktree_path
  else "" end),
 (if $bash.sep == "(" then "1" else "" end),
 (if .tool_name == "Bash" and ((.tool_input.command // "") | command_read_only) then "1" else "" end),
 ($bash.worktree // ""),
 ($bash.worktree_base // ""),
 ($bash.cd_hit // ""),
 (.tool_use_id | value | gsub("[^A-Za-z0-9_-]"; "")),
 (if .tool_name == "Task" or .tool_name == "Agent" then dispatch_paths else "" end)]
| join("")
