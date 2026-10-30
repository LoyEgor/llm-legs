"""Tool mining: the scripts models keep writing for themselves. A deterministic scan of 24 h of chat, subagent and
worker transcripts (Claude Code and codex) for ad-hoc Bash calls (python/node/perl inline scripts, heredocs, long
jq/awk pipelines), each put in the first CLUSTERS row its text matches. A cluster costs the time to write its scripts
(characters at the measured write rate) plus calls times their median exec; the writing is what a tool removes.
Clusters over the floor become Speed's `adhoc/<key>` opportunities: a new tool plus its hint, or only the hint where
`covered_by` names a tool that already does the job. Proof is net (`net`): the job's whole cost per 1000 Bash calls,
minutes and Opus-eq tokens, before the fix against after: the cluster's residual calls, substitutes (ad-hoc calls an
earlier cluster took that match this one's pattern), the tool's own calls (its bench's `command`) and the hint's
always-loaded bytes once a session. A fix lands only with a bench (`bench_faults`). Adoption (`adoption`): each
command and skill of the tool index (share/tool_index.py, what `tools` searches) and its model calls a day over
USE_DAYS, night automation's left out; one under NEAR_UNUSED a day, or with none in its last RECENT_DAYS, is near-unused
with its likely cause (`cause`), Speed's `opportunity:tool/...`: a review that deletes it or fixes the cause.
Hung calls (`hung_findings`): Claude Code Bash calls that sat to their timeout with no output (a stdin read, a lost
heredoc), their wall per command head a day, Speed's `opportunity:hung-bash/<head>` over the floor.
A cluster recurring in fewer than FLOOR_PROJECTS projects is that project's job (`home`): its tool and hint go there.
A job no single script shows rides the same pass, costed, floored and proven like a cluster: a chain (`chain/<heads>`),
the same command heads run by hand as separate short Bash calls in FLOOR_SESSIONS sessions (`chain_rows`). A chain a
tool already does (COVERED_CHAINS) is a bypass of it: each run a substitute in the tool's net (`adhoc/chain/<tool>`).

  tool_mining.py [--to T] [--calls]   T in epoch seconds; --calls prints each matched call
"""

import argparse
import collections
import datetime
import glob
import json
import os
import re
import statistics
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import chat_names  # noqa: E402
import handoffs  # noqa: E402
import time_budget  # noqa: E402
import tool_index  # noqa: E402

WINDOW_S = 86400
HOUR_S = 3600
HISTORY_D = 35
BUILD_H, PAYBACK_D = 1.0, 7
FLOOR_MIN_DAY = round(60.0 * BUILD_H / PAYBACK_D, 1)
FLOOR_SESSIONS = 3
FLOOR_PROJECTS = 3
NET_DAYS = 7
OUTPUT_EQ, CHARS_PER_TOKEN = 5.0, 3.2
BENCH = ("command", "hint_b", "calls", "adhoc_wall_s", "adhoc_out_b", "tool_wall_s", "tool_out_b")
ADHOC = re.compile(r"\b(?:python3?|node|perl|ruby)\s+(?:-\w+\s+)*-(?:c|e)\b|\b(?:python3?|node)\s+(?:-\w+\s+)*-\s*<<"
                   r"|<<-?\s*['\"]?[A-Z]+")
PIPE = re.compile(r"\b(?:jq|awk)\b")
NOT_A_SCRIPT = re.compile(r"git commit[^\n]*<<|^\s*cat\s*>>?\s*\S+\s*<<|gh (?:pr|issue) (?:create|comment|edit)[^\n]*<<"
                          r"|\bworker-run\b[^\n]*<<|\breport-bus\b[^\n]*<<")
WRITES = r"(?:write_text|json\.dump\(|\.write\(|open\([^)]*['\"][wa]|\bsponge\b|>\s*\S*\.json\b)"
# A recursive grep, rg, ag or find whose path walks every transcript: a profiles root, one profile or a projects dir.
TRANSCRIPT_ROOT = r"\.claude(?:-profiles(?:/[^/\s'\"]+)?/?(?=[\s'\")]|$)|[\w-]*/(?:[^/\s'\"]+/)?projects/?(?=[\s'\")]|$))"
TRANSCRIPT_WALK = re.compile(r"(?:\bgrep\s+(?:\S+\s+)*?-[a-zA-Z]*[rR]|\b(?:rg|ag|find)\s)[^|;&\n]*?" + TRANSCRIPT_ROOT)
# (key, job, covered_by, pattern): first match wins; covered_by names the tool that already does the job.
CLUSTERS = (
    ("file-edit", "edit a file by string replace", "the Edit tool",
     r"\.replace\([\s\S]*(?:write_text|\.write\()|\bsed -i\b|\bperl -\w*i\b"),
    ("ledger-patch", "patch a doctor ledger row", "bin/doctor-fix close",
     r"(?:harness|spend|doctor|code|system|updater)-ledger\.json[\s\S]*" + WRITES),
    ("ledger-query", "read doctor ledger rows", None, r"(?:harness|spend|doctor|code|system|updater)-ledger\.json"),
    ("suite-history", "read suite run history", None, r"run-suites/(?:runs\.jsonl|times\.tsv)"),
    ("night-record", "read a night record", "bin/night-run report", r"doctors/nights|night-run|nights/\w+\.json"),
    ("doctor-state", "read a doctor's cache (latest, state, days, journals)", None,
     r"\.cache/(?:[\w-]+-doctor|doctors)\b|-doctor/(?:latest|state)\.json"),
    ("worker-runs", "read worker run history", None, r"worker-stats|runs\.jsonl|legs\.jsonl"),
    ("tokenmap", "query token-map spend", None, r"tokenmap|spend-(?:7d|24h|3d)\.json|\.sqlite3?\b"),
    ("transcript-scan", "scan chat transcripts", None,
     r"projects/[^\s'\"]*\.jsonl|\.claude/projects|tool_use|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
     r"\.jsonl|rollout-[\w-]+\.jsonl|" + TRANSCRIPT_WALK.pattern),
    ("logo-verdict", "append a judge verdict to a logo-bench verdicts.csv", None,
     r"verdicts\.csv[\s\S]*(?:open\([^)]*['\"]a|writerow|\.write\()|>>\s*\S*verdicts\.csv"),
    ("logo-bench", "read logo-bench lane results and verdicts", None,
     r"verdicts\.(?:csv|jsonl)|defects\.csv|key\.json|manifest\.json|judge-(?:answer|input)|logo-vectorizer-bench"
     r"|results/(?:lanes|ab)|tracers/|\.venv/bin/python"),
    ("review-bench", "read review-bench meta and findings", None,
     r"review-bench|findings[\w-]*\.json|panel\.log|meta\.json"),
    ("image-probe", "measure image pixels", None, r"from PIL|import numpy|import cv2|Image\.open"),
    ("settings", "inspect Claude settings", None, r"settings(?:\.local)?\.json|\.claude\.json"),
    ("limits", "inspect account limits", "llm-limits --table --no-write", r"llm-limits|limits\.json|\.claudeb/"),
    ("experiments", "read EXPERIMENTS.json", None, r"EXPERIMENTS\.json"),
    ("module-probe", "import a harness module to probe it", None,
     r"sys\.path\.(?:insert|append)|importlib|SourceFileLoader"),
    ("hook-replay", "replay a hook on a JSON payload", None, r"tool_input|hook_event_name|payloads?\.jsonl?\b"),
    ("file-read", "print part of a text file", "the Read and Grep tools",
     r"open\([^)]*\.(?:md|sh|py|lua|txt|tsv)['\"]?\)\.read\(\)|read_text\(\)\.split|\.split\(['\"]\\n['\"]\)\["),
    ("json-other", "read some other JSON", None, r"json\.load|JSON\.parse|\bjq\b"),
    ("text-other", "other text processing", None, r""),
)
CATCH_ALL = ("json-other", "text-other")
ROW_SKIP = ("file-edit", "file-read")
CANDIDATE_ROWS = 5
USE_DAYS, RECENT_DAYS = 30, 7
# Near-unused: under one model call a week. 30 days to 2026-10-29, night calls out, the 50 indexed commands and skills
# older than the window ranked by calls: 0 1 1 3 3 4 4 | 7 8 8 10 ...; the floor (4.3) sits in the one gap of the tail.
# A tool no model called in its last RECENT_DAYS is flagged too (`recent`): a doctrine may have retired it, or its occasion is rare (a usage reset), which doctor-fix settles from the tool's own log.
NEAR_UNUSED = 1.0 / 7
USES_V = 2
UNUSED = "🗑"
HINT_OFF = "○"
NO_TOOL = "–"
COMMAND = (r"(?:^|[;&|(`\n]|\$\()\s*(?:[A-Za-z_]\w*=\S*\s+)*(?:(?:sudo|env|command|exec|time|nohup|timeout\s+\S+"
           r"|nice(?:\s+-n\s*-?\d+)?)\s+)*(?:[\w.~/-]*/)?(%s)(?![\w./-])")
BACKTICK = re.compile(r"`([^`\n]+)`")
SLASH = re.compile(r"<command-name>/?([\w:.-]+)</command-name>")
HEREDOC = re.compile(r"""(?ms)^[ \t]*cat\s*>\s*(['"]?)(\S+?)\1\s*<<-?\s*['"]?(\w+)['"]?[^\n]*\n(.*?)\n[ \t]*\3[ \t]*$""")
SCRATCH = re.compile(r"^(?:(?:/private)?/tmp/|/var/folders/|\$\{?TMPDIR\}?/|~/\.cache/|/Users/[^/]+/\.cache/)|/scratchpad/")
SCRATCH_WRITE = re.compile(rb'"file_path":"(?:(?:/private)?/tmp/|/var/folders/|/Users/[^/"]+/\.cache/|[^"]*/scratchpad/)')
SLASH_LINE_B = 20000
SCRIPT = re.compile(r"\.(?:py|sh|bash|zsh|js|mjs|cjs|pl|rb|jq|awk|lua)$")
RULES = [(key, job, tool, re.compile(pattern)) for key, job, tool, pattern in CLUSTERS]
TS = re.compile(rb'"timestamp":"([0-9T:.+-]+Z?)"')
MSG = re.compile(rb'"message":\{[^{]*?"id":"(msg_\w+)"')
RESULT = re.compile(rb'"tool_use_id":"(\w+)"')
CWD = re.compile(rb'"cwd":"([^"]+)"')
REPOS = {}
# An empty-output result's toolUseResult is short, so its key sits in the line's tail.
TIMED_OUT, TIMED_OUT_TAIL_B = b'"timedOutAfterMs"', 2048
IS_ERROR = b'"is_error":true'
ON_DEMAND = re.compile(r"skills-on-demand/([\w:-]+)/SKILL\.md")
SEGMENT = re.compile(r"&&|\|\||[;\n]")
SET_UP = re.compile(r"^\s*(?:cd\b|[A-Za-z_]\w*=(?:\$\([^)]*\)|\S)*\s*$)")
HEAD = re.compile(r"^\s*(?:[A-Za-z_]\w*=\S*\s+)*(?:(?:sudo|env|command|exec|time|nohup|timeout\s+\S+"
                  r"|nice(?:\s+-n\s*-?\d+)?)\s+)*([^\s;&|()<>]+)")
CODEX_CMD = re.compile(r"""exec_command\(\{\s*cmd:\s*("(?:[^"\\]|\\.)*")""")
# A chain: CHAIN_MIN to CHAIN_MAX heads in order inside CHAIN_SPAN calls of its first, the CHAIN_KEEP costliest whose
# calls are mostly their own. LOOK heads read or glue: a chain is made of the calls that act.
CHAIN_MIN, CHAIN_MAX, CHAIN_SPAN, CHAIN_KEEP = 3, 5, 5, 20
MINED = "chain/"
# (heads, covered_by, since): a chain a tool already does, from the local day it landed; its runs are tracked at any
# count and priced as substitutes in the tool's net, `adhoc/chain/<tool>`, beside the tool's own calls.
COVERED_CHAINS = ((("affected", "run-all", "git merge", "git worktree", "git branch"), "land", "2026-10-30"),
                  (("git commit", "git rebase", "git merge", "git worktree", "git branch"), "land", "2026-10-30"))
LOOK = frozenset("cat ls head tail grep egrep fgrep rg sed awk jq wc sort uniq cut tr echo printf pwd true false sleep "
                 "test [ [[ date ps pgrep which type stat file find du df diff cmp basename dirname realpath readlink "
                 "xargs tee less column nl od xxd shasum md5 export set source . exit wait read local unset trap "
                 "command".split()) | {"git " + verb for verb in "status log diff show rev-parse ls-files merge-base "
                                       "rev-list blame grep cat-file describe shortlog".split()}
BODY = re.compile(r"<<-?\s*(['\"]?)(\w+)\1[^\n]*\n.*?(?:\n[ \t]*\2[ \t]*(?=\n|$)|\Z)", re.S)
QUOTED = re.compile(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"")
PARTS = re.compile(r"&&|\|\||[;\n|()`]|\$\(")
KEYWORD = re.compile(r"^\s*(?:(?:if|then|else|elif|do|while|until|!|\{)\s+)+")
NOT_A_COMMAND = re.compile(r"^\s*(?:for|case|done|fi|esac|\}|function)\b")
WORD = re.compile(r"""(?:[^\s'"]|'[^']*'|"(?:[^"\\]|\\.)*")+""")
VERB = re.compile(r"^[a-z][a-z0-9-]*$")
PROGRAM = re.compile(r"^[A-Za-z][\w.-]*$")


def projects_dir():
    return time_budget.env_path("CLAUDE_PROJECTS_DIR", ".claude", "projects")


def projects_roots():
    """CLAUDE_PROJECTS_DIR alone where set (a fixture), else every Claude transcript root: claudeb profiles' too."""
    if os.environ.get("CLAUDE_PROJECTS_DIR"):
        return [projects_dir()]
    roots = {}
    for root in chat_names.transcript_roots():
        roots.setdefault(os.path.realpath(root), str(root))
    return list(roots.values())


def codex_dir():
    return os.environ.get("CODEXB_PROFILES_DIR") or time_budget.home(".codex-profiles")


def cache_path():
    return os.path.join(os.environ.get("SPEED_DOCTOR_DIR") or time_budget.home(".cache", "speed-doctor"),
                        "tool-mining.json")


def claude_dir():
    return tool_index.claude_dir()


def hint_texts():
    """The texts a session reads only when they fire: Claude Code's hooks and the worker preamble."""
    hooks = glob.glob(os.path.join(claude_dir(), "hooks", "**", "*"), recursive=True)
    return sorted(p for p in hooks if os.path.isfile(p)) + [
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "worker-run-texts.sh")]


def command_re(names):
    return re.compile(COMMAND % "|".join(map(re.escape, sorted(names, key=len, reverse=True)))) if names else None


def used(cmd, names):
    return {m.group(1) for m in names.finditer(cmd)} if names else set()


def on_demand(text):
    """The on-demand skills whose SKILL.md a Read or Bash call reads: a model's use of the skill."""
    return sorted({"skill/" + m for m in ON_DEMAND.findall(text)})


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""


def born(repo, paths):
    """{path: epoch of the commit that added it}, renames counted as adds."""
    try:
        text = subprocess.run(["git", "-C", repo, "log", "--no-renames", "--diff-filter=A", "--format=%x00%at",
                               "--name-only", "--"] + sorted(paths), capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    out, at = {}, None
    for line in text.splitlines():
        if line.startswith("\0"):
            at = int(line[1:])
        elif line and at:
            out[line] = at
    return out


def facing(now):
    """Every model-facing tool of the tool index (share/tool_index.py, what `tools` searches), {kind/name: {path,
    hint_b, hint_in, hinted, born}}: each command, and each skill a model may invoke or read on demand. Its hint bytes:
    the always-loaded CLAUDE.md lines whose backticked command starts it (a line naming several splits its bytes), a
    listed skill's name and description in every session's skill list. `hint_in` splits the bytes by who loads them:
    "*" every session, a repository path its sessions. `hinted`: some text tells models of it, those bytes or a hook's
    or worker preamble's (HINT_TEXTS). `born` is the commit that added its file, `now` while uncommitted."""
    repos = [os.path.realpath(r) for r in handoffs.sweep_repos()]
    owner = lambda path: next((r for r in repos if path.startswith(r + os.sep)), None)
    tools = {}
    for key, entry in tool_index.index().items():
        if entry["kind"] == "bin" and owner(entry["path"]):
            tools[key] = {"path": entry["path"], "hint_b": 0.0, "hint_in": collections.Counter()}
        elif entry["kind"] == "skill" and owner(entry["path"]) and (entry["listed"] or entry.get("demand")):
            tools[key] = {"path": entry["path"], "hint_b": float(entry["list_b"]),
                          "hint_in": {"*": float(entry["list_b"])} if entry["list_b"] else {}}
        if entry.get("broken") and key in tools:
            tools[key]["broken"] = True
    names = command_re([k[4:] for k in tools if k.startswith("bin/")])
    for where, path in [("*", os.path.join(claude_dir(), "CLAUDE.md"))] + [(r, os.path.join(r, "CLAUDE.md")) for r in repos]:
        try:
            with open(path, "rb") as handle:
                lines = handle.read().decode("utf-8", "replace").splitlines(True)
        except OSError:
            continue
        for line in lines:
            named = {n for span in BACKTICK.findall(line) for n in used(span, names)}
            for n in named:
                tools["bin/" + n]["hint_b"] += len(line.encode()) / len(named)
                tools["bin/" + n]["hint_in"][where] += len(line.encode()) / len(named)
    texts = "\n".join(read(p) for p in hint_texts())
    out = {k: dict(v, hint_b=round(v["hint_b"]), hint_in={w: round(b) for w, b in v["hint_in"].items()}, born=int(now),
                   hinted=bool(v["hint_b"]) or bool(k.startswith("bin/") and used(texts, command_re([k[4:]]))))
           for k, v in tools.items()}
    for repo in repos:
        mine = {os.path.relpath(v["path"], repo): v for v in out.values() if owner(v["path"]) == repo}
        for rel, at in born(repo, mine).items() if mine else ():
            if rel in mine:
                mine[rel]["born"] = at
    return out


def project(cwd):
    """The repository a session worked in, a worktree's main checkout; the directory itself outside any."""
    if cwd not in REPOS:
        top, at = None, cwd
        while not top and at != os.path.dirname(at):
            git = os.path.join(at, ".git")
            if os.path.isfile(git):
                try:
                    with open(git, errors="replace") as handle:
                        gitdir = handle.read().partition("gitdir:")[2].strip()
                except OSError:
                    gitdir = ""
                top = gitdir.split(os.sep + ".git" + os.sep)[0] if os.sep + ".git" + os.sep in gitdir else at
            elif os.path.isdir(git):
                top = at
            at = os.path.dirname(at)
        REPOS[cwd] = os.path.realpath(top or cwd)
    return REPOS[cwd]


def window(day, n):
    """The n local days ending at `day`, oldest first."""
    days = [day]
    while len(days) < n:
        days.append(time_budget.local_day(time_budget.day_bounds(days[-1])[0] - 1))
    return days[::-1]


def epoch(text):
    try:
        return datetime.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def adhoc(cmd):
    return bool(ADHOC.search(cmd) or cmd.count("|") >= 3 and PIPE.search(cmd) and len(cmd) > 150
                or ".claude" in cmd and TRANSCRIPT_WALK.search(cmd)) and not NOT_A_SCRIPT.search(cmd)


def cluster(cmd):
    return next(key for key, _, _, rule in RULES if rule.search(cmd))


def files(root, pattern, lo):
    out = []
    for path in glob.glob(os.path.join(root, pattern)):
        try:
            if os.path.getmtime(path) >= lo:
                out.append(path)
        except OSError:
            continue
    return out


def text_b(content):
    if isinstance(content, str):
        return len(content.encode())
    return sum(text_b(c.get("text", c.get("content"))) for c in content if isinstance(c, dict)) \
        if isinstance(content, list) else 0


def head(cmd):
    """A command's first program past its leading cd's and bare assignments, its own assignments and wrappers, by
    basename."""
    found = next((HEAD.match(s) for s in SEGMENT.split(cmd) if s.strip() and not SET_UP.match(s)), None)
    return os.path.basename(found.group(1)) if found else ""


def heads(cmd):
    """The acting programs a Bash call runs (LOOK aside), in order, a repeat of the one before dropped, each with its
    first word when that is a bare verb (`git merge`, `doctor-fix close`), past -C/-c and their argument; a $( ) counts,
    a heredoc body and quoted text without a $( are no commands."""
    text = QUOTED.sub(lambda m: m.group(0) if m.group(0)[0] == '"' and "$(" in m.group(0) else "''", BODY.sub("\n", cmd))
    out = []
    for part in PARTS.split(text):
        part = KEYWORD.sub("", part)
        if not part.strip() or NOT_A_COMMAND.match(part) or SET_UP.match(part):
            continue
        found = HEAD.match(part)
        name = os.path.basename(found.group(1)) if found else ""
        if name in LOOK or not PROGRAM.match(name):
            continue
        words = iter(WORD.findall(part[found.end():]))
        word = next(words, "")
        while word in ("-C", "-c"):
            next(words, None)
            word = next(words, "")
        token = name + " " + word if VERB.match(word) else name
        if token in LOOK:
            continue
        if not out or out[-1] != token:
            out.append(token)
    return tuple(out)


def kept(cmd, tools, at, session, worker, out, script=False):
    """The call of a benched tool (`tool`: its target) or an ad-hoc call, appended to `out`; None for any other."""
    tool = next((target for target, rule in tools.items() if rule.search(cmd)), None)
    if not tool and not script and not adhoc(cmd):
        return None
    call = {"session": session, "worker": worker, "ts": at, "cmd": cmd, "exec_s": 0.0, "out_b": 0}
    if tool:
        call["tool"] = tool
    out.append(call)
    return call


def count(uses, at, keys):
    for key in keys:
        uses[time_budget.local_day(at)][key] += 1


def claude_calls(path, lo, hi, out, rate, tools=None, names=None, uses=None, hung=None, chains=None, night=()):
    """Ad-hoc and benched-tool Bash calls of one Claude Code transcript: {session, worker, ts, cmd, exec_s, out_b}. A
    tool_use block written right after another block of the same message adds (chars, seconds) to the write rate.
    A script file written into a scratch place (a `cat >` heredoc or the Write tool) is ad hoc in the first Bash call
    naming its path outside that heredoc, its text that call's. `uses` counts per local day the `names` commands a Bash
    call runs (`err/` too where its result is an error), Skill calls, reads of an on-demand skill's SKILL.md and, apart
    (`slash/`), the user's slash commands; a session `night` holds (its id's first 8 characters, a subagent's by its
    parent's) is automation and counts none. A call's project is the repository of the
    session's launch cwd (`project`), the transcript's project directory without one. `hung` gets each Bash call whose
    result says it timed out (toolUseResult.timedOutAfterMs) with no stdout or stderr: {session, worker, head, cmd,
    wall_s}. `chains` gets every other Bash call that runs an acting head (`heads`), its exec from its result's
    timestamp."""
    session = os.path.splitext(os.path.basename(path))[0]
    worker, pending, prev, written, bashes, chained = "/subagents/" in path, {}, b"", {}, {}, {}
    where = os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(path))) if worker else os.path.dirname(path))
    launched, counted = False, {}
    if uses is not None and (os.path.basename(os.path.dirname(os.path.dirname(path))) if worker else session)[:8] in night:
        uses = None
    try:
        handle = open(path, "rb")
    except OSError:
        return
    with handle:
        for n, line in enumerate(handle):
            if n < 40 and b"RUN-TOKEN: " in line:
                worker = True
            if b'"tool_use"' in line and (b'"name":"Bash"' in line or uses is not None and (
                    b'"name":"Skill"' in line or b'"name":"Read"' in line and b"skills-on-demand/" in line)
                                          or b'"name":"Write"' in line and SCRATCH_WRITE.search(line)):
                try:
                    record = json.loads(line)
                except ValueError:
                    prev = line
                    continue
                at = epoch(record.get("timestamp") or "")
                if not launched and record.get("cwd"):
                    launched, where = True, project(record["cwd"])
                blocks = (record.get("message") or {}).get("content")
                for block in blocks if isinstance(blocks, list) else ():
                    if not isinstance(block, dict) or block.get("type") != "tool_use":
                        continue
                    if block.get("name") == "Skill" and uses is not None and at and lo <= at < hi:
                        count(uses, at, ["skill/" + str((block.get("input") or {}).get("skill") or "").lstrip("/")])
                    if block.get("name") == "Read" and uses is not None and at and lo <= at < hi:
                        count(uses, at, on_demand(str((block.get("input") or {}).get("file_path") or "")))
                    if block.get("name") == "Write":
                        target = str((block.get("input") or {}).get("file_path") or "")
                        if SCRATCH.search(target) and SCRIPT.search(target):
                            written[target] = str((block.get("input") or {}).get("content") or "")
                    if block.get("name") != "Bash":
                        continue
                    cmd = str((block.get("input") or {}).get("command") or "")
                    rest, own = cmd, set()
                    for _, target, _, body in HEREDOC.findall(cmd):
                        if SCRATCH.search(target) and SCRIPT.search(target):
                            written[target] = body
                            own.add(target)
                    if written and "<<" in cmd:
                        rest = HEREDOC.sub("", cmd)
                    runs = [t for t in written if t in rest]
                    bodies = [b for t, b in ((t, written.pop(t)) for t in runs) if t not in own]
                    same = MSG.search(prev)
                    if same and same.group(1) == ((record.get("message") or {}).get("id") or "").encode():
                        before = TS.search(prev)
                        start = epoch(before.group(1).decode()) if before else None
                        if at and start and 0 < at - start < 600:
                            rate[0] += len(cmd)
                            rate[1] += at - start
                    if at and lo <= at < hi:
                        if hung is not None:
                            bashes[block.get("id")] = (at, cmd)
                        rate[2] += 1
                        rate[3][session] = where
                        if uses is not None:
                            keys = ["bin/" + n for n in used(cmd, names)] + on_demand(cmd)
                            count(uses, at, keys)
                            if keys:
                                counted[block.get("id")] = (at, keys)
                        call = kept("\n".join([cmd] + bodies), tools or {}, at, session, worker, out, bool(runs))
                        if call:
                            call["project"] = where
                            pending[block.get("id")] = call
                        elif chains is not None:
                            acts = heads(cmd)
                            if acts:
                                chained[block.get("id")] = {"session": session, "worker": worker, "ts": at, "cmd": cmd,
                                                            "exec_s": 0.0, "out_b": 0, "heads": acts, "project": where}
                                chains.append(chained[block.get("id")])
            elif (pending or chained or counted or bashes and TIMED_OUT in line[-TIMED_OUT_TAIL_B:]) \
                    and b'"tool_use_id"' in line:
                found = [f.group(1).decode() for f in RESULT.finditer(line)]
                for ident in (i for i in found if i in counted):
                    at, keys = counted.pop(ident)
                    if IS_ERROR in line:
                        count(uses, at, ["err/" + k for k in keys])
                links = [i for i in found if i in chained]
                if links:
                    stamp = TS.search(line)
                    end = epoch(stamp.group(1).decode()) if stamp else None
                    for ident in links:
                        link = chained.pop(ident)
                        if end and end >= link["ts"]:
                            link["exec_s"] = end - link["ts"]
                ids = [i for i in found if i in pending]
                timed = [i for i in found if i in bashes] if bashes and TIMED_OUT in line[-TIMED_OUT_TAIL_B:] else []
                if not ids and not timed:
                    prev = line
                    continue
                stamp = TS.search(line)
                end = epoch(stamp.group(1).decode()) if stamp else None
                try:
                    record = json.loads(line)
                    blocks = (record.get("message") or {}).get("content")
                except (ValueError, AttributeError):
                    record, blocks = {}, None
                result = record.get("toolUseResult") if isinstance(record, dict) else None
                if timed and end and isinstance(result, dict) and isinstance(result.get("timedOutAfterMs"), (int, float)) \
                        and not str(result.get("stdout") or "").strip() and not str(result.get("stderr") or "").strip():
                    for ident in timed:
                        start, cmd = bashes.pop(ident)
                        hung.append({"session": session, "worker": worker, "head": head(cmd), "cmd": cmd,
                                     "wall_s": max(0.0, end - start)})
                sizes = {b.get("tool_use_id"): text_b(b.get("content")) for b in blocks if isinstance(b, dict)} \
                    if isinstance(blocks, list) else {}
                for ident in ids:
                    call = pending.pop(ident)
                    call["out_b"] = sizes.get(ident, 0)
                    if end and end >= call["ts"]:
                        call["exec_s"] = end - call["ts"]
            elif uses is not None and len(line) < SLASH_LINE_B and b"<command-name>" in line and b'"type":"user"' in line:
                try:
                    record = json.loads(line)
                except ValueError:
                    record = {}
                content = (record.get("message") or {}).get("content")
                at = epoch(record.get("timestamp") or "")
                slash = SLASH.search(content) if isinstance(content, str) else None
                if slash and at and lo <= at < hi:
                    count(uses, at, ["slash/" + slash.group(1)])
            prev = line


def codex_calls(path, lo, hi, out, rate, tools=None, names=None, uses=None, chains=None, night=()):
    """Ad-hoc and benched-tool commands of one codex rollout's exec calls, the others running an acting head into
    `chains`; codex runs only as a worker, in its session's cwd; a `night` worker's calls are no use."""
    session = os.path.basename(path)[-42:-6]
    pending, where = {}, "codex"
    uses = None if session[:8] in night else uses
    try:
        handle = open(path, "rb")
    except OSError:
        return
    with handle:
        for n, line in enumerate(handle):
            cwd = CWD.search(line) if n == 0 else None
            if cwd:
                where = project(cwd.group(1).decode("utf-8", "replace"))
            if b'"custom_tool_call"' in line and b"exec_command" in line:
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                at = epoch(record.get("timestamp") or "")
                payload = record.get("payload") or {}
                if not at or not lo <= at < hi:
                    continue
                literals = CODEX_CMD.findall(str(payload.get("input") or ""))
                for literal in literals:
                    try:
                        cmd = json.loads(literal.replace("\\'", "'"))
                    except ValueError:
                        continue
                    rate[2] += 1
                    rate[3][session] = where
                    if uses is not None:
                        count(uses, at, ["bin/" + n for n in used(cmd, names)])
                    call = kept(cmd, tools or {}, at, session, True, out)
                    acts = heads(cmd) if not call and chains is not None else ()
                    if acts:
                        call = {"session": session, "worker": True, "ts": at, "cmd": cmd, "exec_s": 0.0, "out_b": 0,
                                "heads": acts}
                        chains.append(call)
                    if call:
                        call.update(share=1.0 / len(literals), project=where)
                        pending.setdefault(payload.get("call_id"), []).append(call)
            elif pending and b'"custom_tool_call_output"' in line:
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                end = epoch(record.get("timestamp") or "")
                payload = record.get("payload") or {}
                for call in pending.pop(payload.get("call_id"), ()):
                    share = call.pop("share")
                    call["out_b"] = round(text_b(payload.get("output")) * share)
                    if end and end >= call["ts"]:
                        call["exec_s"] = (end - call["ts"]) * share


class Dropped(list):
    def append(self, item):
        pass


def night_sessions():
    """Night automation's sessions by their ids' first 8 characters: each night's hub sessions (`night_agents`) and
    every worker run one of them launched, a worker's own launches too."""
    out = set(time_budget.night_agents(0, time.time())[0])
    launchers = chat_names.worker_run_launchers()
    while True:
        more = {w[:8] for w, owners in launchers.items() if any(o[:8] in out for o in owners)} - out
        if not more:
            return frozenset(out)
        out |= more


def scan(lo, hi, tools=None, names=None, uses=None, keep=True, hung=None, chains=None):
    """(ad-hoc and benched-tool calls in [lo, hi), all Bash calls in it, write rate in chars a second or None, the
    sessions that made a Bash call per project); `tools` maps a target to the pattern of its tool's calls; `uses` (day -> Counter)
    gets the model-facing tools' calls, night automation's (`night_sessions`) left out; `keep` False drops the calls
    themselves; `hung` gets the hung Claude Code calls; `chains` the other calls running an acting head."""
    calls, rate = [] if keep else Dropped(), [0, 0.0, 0, {}]
    night = night_sessions() if uses is not None else frozenset()
    for root in projects_roots():
        for path in files(root, "*/*.jsonl", lo) + files(root, "*/*/subagents/*.jsonl", lo):
            claude_calls(path, lo, hi, calls, rate, tools, names, uses, hung, chains, night)
    for path in files(codex_dir(), "*/sessions/*/*/*/rollout-*.jsonl", lo):
        codex_calls(path, lo, hi, calls, rate, tools, names, uses, chains, night)
    return calls, rate[2], (rate[0] / rate[1] if rate[1] else None), collections.Counter(rate[3].values())


def part(group):
    return {"calls": len(group), "chars": sum(len(c["cmd"]) for c in group),
            "exec_s": round(sorted(c["exec_s"] for c in group)[len(group) // 2], 2) if group else 0.0,
            "out_b": sum(c.get("out_b") or 0 for c in group)}


def priced(group, chars_s, shown):
    """A group's row: its part, sessions, sessions per project, minutes (the writing plus calls times the median exec,
    as an edit and its suite run often share one call), worker minutes, the writing part and `shown` on one line each."""
    median = sorted(c["exec_s"] for c in group)[len(group) // 2]
    write = [len(c["cmd"]) / chars_s / 60.0 if chars_s else 0.0 for c in group]
    worker = [w + median / 60.0 for w, c in zip(write, group) if c["worker"]]
    return dict(part(group), sessions=len({c["session"] for c in group}),
                projects=dict(collections.Counter(p for _, p in {(c["session"], c.get("project", "")) for c in group})),
                min=round(sum(write) + len(group) * median / 60.0, 2), worker_min=round(sum(worker), 2),
                write_min=round(sum(write), 2), examples=[" ⏎ ".join(c.splitlines())[:200] for c in shown])


def runs_of(events, pattern):
    """The non-overlapping runs of `pattern` in one session's (call index, head) events, leftmost first, each inside
    CHAIN_SPAN calls of its first, gaps allowed: [call indexes]."""
    out, k = [], 0
    while k < len(events):
        if events[k][1] != pattern[0]:
            k += 1
            continue
        got, m = [events[k][0]], k + 1
        while len(got) < len(pattern) and m < len(events) and events[m][0] - got[0] < CHAIN_SPAN:
            if events[m][1] == pattern[len(got)]:
                got.append(events[m][0])
            m += 1
        if len(got) < len(pattern):
            k += 1
            continue
        out.append(sorted(set(got)))
        k = m
    return out


def grown(events, pattern):
    """Every head past a run of `pattern` inside CHAIN_SPAN calls of the run's first, not in it."""
    out = set()
    for k, (first, h) in enumerate(events):
        if h != pattern[0]:
            continue
        q, m = 1, k + 1
        while m < len(events) and events[m][0] - first < CHAIN_SPAN:
            if q < len(pattern):
                q += events[m][1] == pattern[q]
            elif events[m][1] not in pattern:
                out.add(events[m][1])
            m += 1
    return out


def chain_key(pattern):
    return "chain/" + "+".join(h.replace(" ", "-") for h in pattern)


def chain_rows(chains, chars_s, track=None):
    """{chain/<heads>: row} of the day's chains: CHAIN_MIN to CHAIN_MAX acting heads (`heads`) run in that order by one
    session's short Bash calls, gaps allowed, in FLOOR_SESSIONS sessions; level by level, a chain grown only from one
    already in that many. Each costs its runs' calls (`priced`); the costliest CHAIN_KEEP whose calls are mostly not a
    costlier one's are kept, and every `track` chain ({key: heads}, a landed fix's) and COVERED_CHAINS one at any count."""
    by = collections.defaultdict(list)
    for call in sorted(chains, key=lambda c: (c["session"], c["ts"])):
        by[call["session"]].append(call)
    track = dict({chain_key(p): p for p, _, _ in COVERED_CHAINS}, **{k: tuple(v) for k, v in (track or {}).items()})
    support = collections.Counter(h for group in by.values() for h in {h for c in group for h in c["heads"]})
    common = {h for h, n in support.items() if n >= FLOOR_SESSIONS} | {h for p in track.values() for h in p}
    events = {s: [(i, h) for i, c in enumerate(group) for h in dict.fromkeys(c["heads"]) if h in common]
              for s, group in by.items()}
    level = collections.defaultdict(set)
    for s, ev in events.items():
        for _, h in ev:
            level[(h,)].add(s)
    found = {p: set(events) for p in track.values()}
    for _ in range(CHAIN_MAX - 1):
        longer = collections.defaultdict(set)
        for pattern, sessions in level.items():
            for s in sessions:
                for h in grown(events[s], pattern):
                    longer[pattern + (h,)].add(s)
        level = {p: s for p, s in longer.items() if len(s) >= FLOOR_SESSIONS}
        found.update((p, s) for p, s in level.items() if len(p) >= CHAIN_MIN and p not in found)
    rows = []
    for pattern, sessions in found.items():
        runs = [(s, run) for s in sorted(sessions) for run in runs_of(events[s], pattern)]
        if not runs:
            continue
        group = [by[s][i] for s, run in runs for i in run]
        shown = sorted(("\n".join(by[s][i]["cmd"] for i in run) for s, run in runs), key=len)[:2]
        row = dict(priced(group, chars_s, shown), chain=list(pattern), runs=len(runs),
                   job="run %s by hand, a Bash call each" % " → ".join(pattern))
        rows.append((chain_key(pattern), row, {(s, i) for s, run in runs for i in run}))
    jobs, claimed = [], set()
    for key, row, own in sorted(rows, key=lambda r: (-len(r[1]["chain"]), -r[1]["write_min"], r[0])):
        if key in track or row["sessions"] >= FLOOR_SESSIONS and len(own & claimed) * 2 < len(own):
            jobs.append((key, row))
            claimed |= own
    kept = sorted((r for r in jobs if r[0] not in track), key=lambda r: (-r[1]["write_min"], r[0]))[:CHAIN_KEEP]
    return dict(kept + [r for r in jobs if r[0] in track])


def day_of(calls, bash, chars_s, hi, sessions=None, hung=(), chains=(), track=None):
    """One scanned window's numbers per cluster: calls, sessions, sessions per project, minutes (the scripts' writing plus calls times the
    median exec, as an edit and its suite run often share one call), worker minutes, the writing part, two examples,
    characters and output bytes; per cluster its substitutes (`shadow`: ad-hoc calls an earlier cluster took that
    match its pattern) and per benched target its tool's calls (`tools`); the day's sessions, also per project; the
    hung calls per command head (`hung`: calls, sessions, min, worker_min, two examples); the chains (`chain_rows`) as
    clusters, `track` the keys of landed fixes, and their mining's seconds."""
    out = {"bash_calls": bash, "chars_s": round(chars_s, 1) if chars_s else None, "to_s": int(hi), "clusters": {},
           "sessions": sum((sessions or {}).values()), "projects": dict(sessions or {}), "shadow": {}, "tools": {}}
    grouped, shadow, tools = (collections.defaultdict(list) for _ in range(3))
    order = [key for key, _, _, _ in RULES]
    for call in calls:
        if call.get("tool"):
            tools[call["tool"]].append(call)
            continue
        own = cluster(call["cmd"])
        grouped[own].append(call)
        for key, _, _, rule in RULES[order.index(own) + 1:]:
            if key not in CATCH_ALL and rule.search(call["cmd"]):
                shadow[key].append(call)
    for key, group in grouped.items():
        out["clusters"][key] = priced(group, chars_s, sorted((c["cmd"] for c in group if len(c["cmd"]) >= 40), key=len)[:2])
    started = time.monotonic()
    out["clusters"].update(chain_rows(chains, chars_s, track))
    out["chain_s"] = round(time.monotonic() - started, 2)
    by_head = collections.defaultdict(list)
    for call in hung:
        by_head[call["head"]].append(call)
    out["hung"] = {key: {"calls": len(group), "sessions": len({c["session"] for c in group}),
                         "min": round(sum(c["wall_s"] for c in group) / 60.0, 2),
                         "worker_min": round(sum(c["wall_s"] for c in group if c["worker"]) / 60.0, 2),
                         "examples": [" ⏎ ".join(c["cmd"].splitlines())[:200]
                                      for c in sorted(group, key=lambda c: -c["wall_s"])[:2]]}
                   for key, group in by_head.items()}
    out["shadow"] = {key: part(group) for key, group in shadow.items()}
    out["tools"] = {target: part(group) for target, group in tools.items()}
    return out


def per_1k(day, key):
    return 1000.0 * ((day["clusters"].get(key) or {}).get("calls") or 0) / max(1, day["bash_calls"])


def job_cost(d, key, hint_b, subs=()):
    """(writing min, exec min, Opus-eq tokens) per 1000 Bash calls of the job on one scanned day: the cluster's
    residual calls, its substitutes (and the `subs` clusters') and its tool's calls (characters written, calls times
    median exec, output read) plus the hint's bytes once a session."""
    parts = [d["clusters"].get(k) or {} for k in (key,) + tuple(subs)] + [d["shadow"].get(key) or {},
                                                                          d["tools"].get("adhoc/" + key) or {}]
    chars = sum(p.get("chars") or 0 for p in parts)
    scale = 1000.0 / max(1, d["bash_calls"])
    return (scale * chars / d["chars_s"] / 60.0, scale * sum((p.get("calls") or 0) * (p.get("exec_s") or 0.0)
                                                             for p in parts) / 60.0,
            scale * (OUTPUT_EQ * chars + sum(p.get("out_b") or 0 for p in parts) + hint_b * d["sessions"])
            / CHARS_PER_TOKEN)


def load_factor(before, after, key, subs=()):
    """How much slower the machine ran the other clusters' calls after the landing: the median over the clusters
    seen on both sides of their mean median exec after over before, 1 under time_budget's LOAD_CONTROLS of them."""
    ratios = []
    for other in sorted({k for d in after for k in d["clusters"]} - {key, *subs}):
        sides = [[d["clusters"][other]["exec_s"] for d in side if other in d["clusters"]] for side in (before, after)]
        if all(sides) and sum(sides[0]) > 0:
            ratios.append(sum(sides[1]) / len(sides[1]) / (sum(sides[0]) / len(sides[0])))
    return statistics.median(ratios) if len(ratios) >= time_budget.LOAD_CONTROLS else 1.0


def net(history, key, landed, bench=None, subs=()):
    """A landed fix's job cost, its last NET_DAYS scanned days before the landing against its last NET_DAYS after,
    per 1000 Bash calls, after's exec over the load factor, priced at the newest day's Bash calls: proven when the
    minutes and the tokens both fell, worse when either rose. `subs` are chains doing the job by hand, read only off
    days that mined chains."""
    days = sorted((d for d in history.values() if "shadow" in d and d.get("chars_s") and (not subs or "chain_s" in d)),
                  key=lambda d: d["to_s"])
    before = [d for d in days if d["to_s"] <= landed][-NET_DAYS:]
    after = [d for d in days if d["to_s"] - WINDOW_S >= landed][-NET_DAYS:]
    if not before or not after:
        return {"state": "pending", "days": [len(before), len(after)]}
    hint = (bench or {}).get("hint_b") or 0
    (bw, be, bt), (aw, ae, at) = ([sum(x) / len(side) for x in zip(*(job_cost(d, key, h, subs) for d in side))]
                                  for side, h in ((before, 0), (after, hint)))
    factor = load_factor(before, after, key, subs)
    was, now, volume = bw + be, aw + ae / factor, after[-1]["bash_calls"] / 1000.0
    state = "proven" if now < was and at < bt else "worse" if now > was or at > bt else "even"
    return {"state": state, "days": [len(before), len(after)], "min_before": round(was * volume, 2),
            "min_after": round(now * volume, 2), "saved_min_day": round((was - now) * volume, 2),
            "tok_before": round(bt * volume), "tok_after": round(at * volume),
            "cost": round(at / bt, 2) if bt else None, "load": round(factor, 2)}


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and value >= 0


def bench_faults(bench, hint_only=False):
    """Why an adhoc fix's bench keeps it from landing, [] when it lands. The bench runs the cluster's own example
    calls (`calls` names them and their inputs) and the tool on the same inputs: the tool's wall at most the ad-hoc
    median's plus `adhoc_write_s`, the model's writing of one example call (its characters at the day's write rate),
    its output bytes at most the median's, a longer output only with a `reason`; `command` matches the tool's Bash
    calls (empty only on a hint row whose tool is no Bash command), `hint_b` the hint's bytes loaded in every session."""
    if not isinstance(bench, dict):
        return ["no bench {%s}" % ", ".join(BENCH)]
    missing = [k for k in BENCH if k not in bench]
    if missing:
        return ["the bench lacks " + ", ".join(missing)]
    out = ["bench %s is no number >= 0" % k for k in BENCH[1:2] + BENCH[3:] if not number(bench[k])]
    write = bench.get("adhoc_write_s", 0)
    if not number(write):
        out.append("bench adhoc_write_s is no number >= 0")
    if not str(bench["calls"] or "").strip():
        out.append("the bench names no example calls and inputs")
    command = bench["command"]
    if not isinstance(command, str) or not command and not hint_only:
        out.append("the bench names no command matching the tool's Bash calls")
    else:
        try:
            re.compile(command)
        except re.error as exc:
            out.append("the bench command is no pattern: %s" % exc)
    if out:
        return out
    if bench["tool_wall_s"] > bench["adhoc_wall_s"] + write:
        out.append("the tool's wall %s s is over the ad-hoc median's %s s%s" % (
            bench["tool_wall_s"], bench["adhoc_wall_s"], " plus its writing %s s" % write if write else ""))
    if bench["tool_out_b"] > bench["adhoc_out_b"] and not str(bench.get("reason") or "").strip():
        out.append("the tool prints %s bytes, over the ad-hoc median's %s, with no reason"
                   % (bench["tool_out_b"], bench["adhoc_out_b"]))
    return out


def ledger_faults(ledger):
    """`(row id, index, fault)` of every fix on an `adhoc/<key>` opportunity row whose bench keeps it from landing."""
    covered = {key: tool for key, _, tool, _ in RULES}
    faults = []
    for row in (ledger.get("rows") if isinstance(ledger, dict) else None) or ():
        match = (row.get("match") or {}) if isinstance(row, dict) else {}
        ident = str(match.get("ident") or "")
        if match.get("rule") != "opportunity" or not ident.startswith("adhoc/"):
            continue
        for index, fix in enumerate(row.get("fixes") or ()):
            for fault in bench_faults((fix or {}).get("bench") if isinstance(fix, dict) else None,
                                      bool(covered.get(ident[6:]))):
                faults.append((row.get("id") or "?", index, fault))
    return faults


def over_floor(c):
    return c["write_min"] >= FLOOR_MIN_DAY and c["sessions"] >= FLOOR_SESSIONS


def recurs(c):
    return sorted(p for p, n in (c.get("projects") or {}).items() if n >= FLOOR_SESSIONS)


def home(c):
    """The project a cluster's job belongs to, its tool and hint there: the one with most of its sessions; None when it
    recurs (FLOOR_SESSIONS sessions) in FLOOR_PROJECTS projects, a harness tool's job."""
    projects = c.get("projects") or {}
    return None if len(recurs(c)) >= FLOOR_PROJECTS else max(sorted(projects), key=projects.get, default="")


def mined(days):
    """{key: newest row} of every chain the scanned days carry."""
    out = {}
    for d in sorted(days, key=lambda d: d.get("to_s") or 0):
        out.update((k, c) for k, c in (d.get("clusters") or {}).items() if k.startswith(MINED))
    return out


def covering():
    """{tool: (the start of the local day it landed, the keys of the chains it does)} of COVERED_CHAINS."""
    out = {}
    for heads, tool, day in COVERED_CHAINS:
        at, keys = out.get(tool, (0, []))
        out[tool] = (max(at, time_budget.day_bounds(day)[0]), keys + [chain_key(heads)])
    return out


def jobs(days):
    """(key, job, covered_by) of every CLUSTERS row, then of each chain the days carry."""
    rows, tools = mined(days), {chain_key(p): tool for p, tool, _ in COVERED_CHAINS}
    return [(key, job, tool) for key, job, tool, _ in RULES] + [(k, rows[k].get("job") or k, tools.get(k))
                                                                for k in sorted(rows)]


def findings(day, history, since=lambda target: None, bench=lambda target: None):
    """({target: net} of every cluster whose fix landed, the clusters over the floor worst writing minutes first, each
    with the project it belongs to, None for the harness's); a landed cluster is charged only on a window that began
    after its landing. Chains are clusters here; a covered one's runs are substitutes in its tool's net,
    `adhoc/chain/<tool>`, from the tool's landing or a later fix of one of them, once a day carries them or its calls."""
    out, nets = [], {}
    recent = [d for k, d in sorted(history.items()) if "clusters" in d][-7:]
    for tool, (at, keys) in sorted(covering().items()):
        target = "adhoc/chain/" + tool
        if not any(set(keys) & set(d.get("clusters") or {}) or target in (d.get("tools") or {}) for d in history.values()):
            continue
        landed = max([at] + [since(t) or 0 for t in [target] + ["adhoc/" + k for k in keys]])
        nets[target] = net(history, "chain/" + tool, landed, bench(target), keys)
    for key, job, tool in jobs(list(history.values()) + [day]):
        target = "adhoc/" + key
        landed = since(target)
        if landed and not (key.startswith(MINED) and tool):
            nets[target] = net(history, key, landed, bench(target))
        c = day["clusters"].get(key)
        if not c or key in CATCH_ALL or landed and day["to_s"] - WINDOW_S < landed:
            continue
        if over_floor(c):
            out.append({"key": key, "target": target, "job": job, "covered_by": tool, "calls": c["calls"],
                        "sessions": c["sessions"], "projects": len(recurs(c)), "project": home(c),
                        "min_day": c["min"], "worker_min_day": c["worker_min"],
                        "write_min_day": c["write_min"], "per_1k": round(per_1k(day, key), 1),
                        "days": sum(1 for d in recent if key in d["clusters"]), "examples": c["examples"],
                        **({"net": nets[target]} if target in nets else {})})
    return nets, sorted(out, key=lambda f: (-f["write_min_day"], f["key"]))


def hung_findings(day):
    """The command heads whose hung calls cost the floor's minutes on the scanned day, most minutes first."""
    return sorted((dict(c, head=key) for key, c in (day.get("hung") or {}).items() if c["min"] >= FLOOR_MIN_DAY),
                  key=lambda f: (-f["min"], f["head"]))


def tool_rules(bench, keys=None):
    """{target: pattern of its tool's Bash calls}: a covering tool's by its name first, so its calls count in its net,
    then each landed fix's bench command."""
    out = {"adhoc/chain/" + tool: command_re([tool]) for tool in covering()}
    for key in keys or [k for k, _, _, _ in RULES]:
        command = (bench("adhoc/" + key) or {}).get("command")
        try:
            if command and isinstance(command, str):
                out["adhoc/" + key] = re.compile(command)
        except re.error:
            continue
    return out


def backfill(history, day, names):
    """The model-facing tools' calls of the USE_DAYS - 1 days before `day`, once, in one pass: each day's `uses`."""
    days = window(day, USE_DAYS)[:-1]
    uses = collections.defaultdict(collections.Counter)
    scan(time_budget.day_bounds(days[0])[0], time_budget.day_bounds(day)[0], names=names, uses=uses, keep=False)
    for d in days:
        history.setdefault(d, {"to_s": int(time_budget.day_bounds(d)[1])})["uses"] = dict(uses.get(d) or {})
    return days[0]


def elsewhere(name, path):
    """Whether anything but a model runs the bin tool `name`: another code file of a sweep repository, a LaunchAgent,
    Hammerspoon or Egor's shell history."""
    word = re.compile(r"(?<![\w.-])%s(?![\w.-])" % re.escape(name))
    for repo in handoffs.sweep_repos():
        try:
            found = subprocess.run(["git", "-C", repo, "grep", "-l", "-I", "-F", "-e", name, "--", "."] + [
                ":!tests/", ":!docs/", ":!*.md", ":!*.json", ":!*.jsonl"], capture_output=True, text=True,
                timeout=20).stdout.split("\n")
        except (OSError, subprocess.SubprocessError):
            continue
        for rel in filter(None, found):
            full = os.path.join(repo, rel)
            if os.path.realpath(full) != os.path.realpath(path) and word.search(read(full)):
                return True
    files = glob.glob(time_budget.home("Library", "LaunchAgents", "*.plist")) + \
        glob.glob(time_budget.home(".hammerspoon", "**", "*.lua"), recursive=True) + [time_budget.home(".zsh_history")]
    return any(word.search(read(f)) for f in files)


def cause(tool, calls, errors):
    """The likely cause of a near-unused tool: `access` where its link is missing or most of its calls fail,
    `unknown` where no text tells models of it, else `obsolete`."""
    if tool.get("broken") or calls and errors * 2 >= calls:
        return "access"
    return "obsolete" if tool.get("hinted") else "unknown"


def adoption(history, day, tools, now):
    """Each model-facing tool's calls a day over the USE_DAYS days to `day` its history covers (a skill's typed slash
    uses apart: they need no hint), its age and hint; `unused` (near-unused) when the window is whole, the tool is
    older than it and its model calls stay under NEAR_UNUSED a day or none ran in its last RECENT_DAYS (a doctrine
    retired it), with its likely `cause`. Its hint, read once by each session that loads it (`hint_in`), is priced in
    Opus-eq tokens and as minutes at the write rate (an output character is OUTPUT_EQ input ones)."""
    days = [d for d in window(day, USE_DAYS) if "uses" in (history.get(d) or {})]
    seen = [history[d]["uses"] for d in days]
    calls, recent = collections.Counter(), collections.Counter()
    for d in days:
        calls.update(history[d]["uses"])
        recent.update(history[d]["uses"] if d >= window(day, RECENT_DAYS)[0] else {})
    last = history.get(day) or {}
    rate, projects = last.get("chars_s"), dict(last.get("projects") or {}, **{"*": last.get("sessions") or 0})
    out = {}
    for key, tool in sorted(tools.items()):
        age = (now - tool["born"]) / 86400.0
        loads = sum(b * projects.get(where, 0) for where, b in tool["hint_in"].items())
        slash = calls["slash/" + key[6:]] if key.startswith("skill/") else 0
        out[key] = {"calls_day": round(calls[key] / len(seen), 2) if seen else None, "days": len(seen),
                    "slash_day": round(slash / len(seen), 2) if seen else None,
                    "age_d": round(age, 1), "hint_b": tool["hint_b"], "path": tool["path"],
                    "hint_sessions": round(loads / tool["hint_b"]) if tool["hint_b"] else 0,
                    "hint_tok_day": round(loads / CHARS_PER_TOKEN),
                    "hint_min_day": round(loads / (OUTPUT_EQ * rate) / 60.0, 2) if rate else None,
                    "calls": calls[key], "recent": recent[key], "recent_days": RECENT_DAYS,
                    "unused": len(seen) >= USE_DAYS and age >= USE_DAYS
                    and (calls[key] < NEAR_UNUSED * len(seen) or not recent[key])}
        out[key]["cause"] = cause(tool, calls[key], calls["err/" + key]) if out[key]["unused"] else None
    return out


def minutes(c, rate):
    return (c.get("chars") or 0) / rate / 60.0 + (c.get("calls") or 0) * (c.get("exec_s") or 0.0) / 60.0 if rate else 0.0


def hours_of(cache, now, rules):
    """{hour start: {"clusters": {key: min}, "tools": {target: min}}} of the WINDOW_S of whole hours before `now`'s,
    each scanned once: one scan from the first hour missing, split by its calls' hour."""
    top = int(now // HOUR_S * HOUR_S)
    hours = {int(k): v for k, v in (cache.get("hours") or {}).items() if top - WINDOW_S <= int(k) < top}
    missing = [h for h in range(top - WINDOW_S, top, HOUR_S) if h not in hours]
    if missing:
        calls, _, chars_s, _ = scan(missing[0], top, rules)
        by = collections.defaultdict(list)
        for call in calls:
            by[int(call["ts"] // HOUR_S * HOUR_S)].append(call)
        for h in missing:
            d = day_of(by.get(h, []), 0, chars_s, h + HOUR_S)
            hours[h] = {"clusters": {k: round(c["min"], 2) for k, c in d["clusters"].items()},
                        "tools": {t: round(minutes(p, chars_s), 2) for t, p in d["tools"].items()}}
    return {str(h): hours[h] for h in sorted(hours)}


def menu_row(cache):
    """Lost time's model-written scripts row, beside the overhead, never in it: the clusters but the edits and reads
    the Edit and Read tools own, in min over the last 24 whole hours (`hours`, else the last scanned day), sorted as
    the last scanned day decides. Repeated jobs, the night's target: clusters over the floor not ruled out or handed
    off, and every cluster a built tool serves, as [tool min/day, cluster, [], residual min/day] (NO_TOOL while none
    is built), the heaviest CANDIDATE_ROWS of the unbuilt; one-off, never a target: each ruled-out or handed-off
    cluster, then the catch-alls and clusters under the floor as one row. A chain, no script, shows only
    built, parked or over the floor, at the last scanned day's minutes where the hours lack it; a key no CLUSTERS row
    or chain has (a cached day's removed one) shows nowhere."""
    history = cache.get("history") or {}
    scanned = [d for d in history if "clusters" in history[d]]
    if not scanned:
        return None
    last = history[max(scanned)]
    built, parked, shown = set(cache.get("built") or ()), set(cache.get("parked") or ()), 0.0
    hours = list((cache.get("hours") or {}).values())
    if hours:
        mins, tool_min = collections.Counter(), collections.Counter()
        for h in hours:
            mins.update(h.get("clusters") or {})
            tool_min.update(h.get("tools") or {})
    else:
        mins = {k: c.get("min") or 0 for k, c in last["clusters"].items()}
        tool_min = {t: minutes(p, last.get("chars_s")) for t, p in (last.get("tools") or {}).items()}
    repeated, candidates, oneoff, rest = [], [], [], 0.0
    gone = {k for k in set(last["clusters"]) | set(mins) if not k.startswith(MINED)} - {k for k, _, _, _ in RULES}
    for key in sorted(set(last["clusters"]) | set(mins) | {t[6:] for t in built}):
        c = last["clusters"].get(key) or {"write_min": 0, "sessions": 0}
        target, m = "adhoc/" + key, round(mins.get(key) or 0, 1)
        if key in ROW_SKIP or key in gone:
            continue
        if key.startswith(MINED):
            if target not in built | parked and not over_floor(c):
                continue
            m = round(mins[key] if key in mins else c.get("min") or 0, 1)
            shown += m
        if target in built:
            repeated.append([round(tool_min.get(target) or 0, 1), key, [], m])
        elif target in parked:
            oneoff.append([m, key, []])
        elif key not in CATCH_ALL and over_floor(c):
            candidates.append([NO_TOOL, key, [], m])
        else:
            rest += mins.get(key) or 0
    jobs = round(sum(r[3] for r in repeated + candidates), 1)
    repeated = sorted(repeated, key=lambda r: -r[3]) + sorted(candidates, key=lambda r: -r[3])[:CANDIDATE_ROWS]
    oneoff = sorted(oneoff, key=lambda r: -r[0]) + ([[round(rest, 1), "other", []]] if rest else [])
    groups = [[jobs, "repeated jobs", repeated],
              [round(sum(r[0] for r in oneoff), 1), "one-off", oneoff]]
    total = round(sum(v for k, v in mins.items() if k not in ROW_SKIP and k not in gone and not k.startswith(MINED))
                  + shown, 1)
    return [total, "model-written scripts", groups]


def unused_row(cache):
    """Every unused tool, [0, name, [], HINT_OFF] where its fix keeps the file (a skill, a bin tool something else
    runs: `elsewhere`), else [0, name, [], UNUSED], under a row counting them; None without one."""
    keeps = set(cache.get("kept") or ())
    unused = [[0, ("/" if key.startswith("skill/") else "") + key.split("/", 1)[1], [], HINT_OFF if key in keeps else UNUSED]
              for key in cache.get("unused") or ()]
    return [len(unused), "Unused tools", unused, {"count": True}] if unused else None


def collect(now, write=False, since=lambda target: None, bench=lambda target: None, parked=lambda target: False):
    """The `adhoc` section: the scan of the local day before `now`'s, done once a local day (the first Speed run after
    midnight, before the night starts), the per-day history with the model-facing tools' calls (backfilled once over
    USE_DAYS), the findings, each landed fix's net, each tool's adoption and the scan's own seconds; `bench` gives a
    target's last fix bench, whose command marks its tool's calls; `parked` a target ruled out or handed off. The
    cache keeps what the menu rows need (`menu_row`, `unused_row`), the last 24 hours' clusters (`hours_of`) too."""
    started = time.monotonic()
    cache = time_budget.read_json(cache_path(), {})
    cache = cache if isinstance(cache, dict) else {}
    history = cache.get("history") or {}
    hi = time_budget.day_bounds(time_budget.local_day(now))[0]
    day = time_budget.local_day(hi - 1)
    fresh = not {"shadow", "uses", "hung", "chain_s"} <= set(history.get(day) or {}) \
        or write and cache.get("uses_v") != USES_V
    if fresh:
        cache["facing"] = facing(now)
        names = command_re([k[4:] for k in cache["facing"] if k.startswith("bin/")])
        uses, hung, chains = collections.defaultdict(collections.Counter), [], []
        known = [k for k, _, _ in jobs(history.values())]
        calls, bash, chars_s, sessions = scan(hi - WINDOW_S, hi, tool_rules(bench, known), names, uses, hung=hung,
                                              chains=chains)
        track = {k: c.get("chain") for k, c in mined(history.values()).items() if since("adhoc/" + k)}
        history[day] = dict(day_of(calls, bash, chars_s, hi, sessions, hung, chains, track),
                            uses=dict(uses.get(day) or {}))
        cache["scan_s"] = round(time.monotonic() - started, 2)
        if write and cache.get("uses_v") != USES_V:
            cache["uses_from"], cache["uses_v"] = backfill(history, day, names), USES_V
        cache["history"] = {d: v for d, v in history.items() if d >= time_budget.local_day(hi - HISTORY_D * 86400)}
    tools = adoption(history, day, cache.get("facing") or {}, now)
    known = [k for k, _, _ in jobs(history.values())]
    hours = hours_of(cache, now, tool_rules(bench, known)) if write else cache.get("hours")
    marks = {"hours": hours, "built": sorted("adhoc/" + k for k in known if since("adhoc/" + k)
                             and (bench("adhoc/" + k) or {}).get("command")),
             "parked": sorted("adhoc/" + k for k in known if parked("adhoc/" + k)),
             "unused": sorted(k for k, t in tools.items() if t["unused"])}
    marks["kept"] = [k for k in marks["unused"] if k.startswith("skill/") or elsewhere(k[4:], tools[k]["path"])]
    if write and (fresh or any(cache.get(k) != v for k, v in marks.items())):
        cache.update(marks)
        time_budget.write_json(cache_path(), cache)
    nets, found = findings(history[day], history, since, bench)
    return {"day": day, "scan_s": cache.get("scan_s"), "bash_calls": history[day]["bash_calls"],
            "chars_s": history[day]["chars_s"], "floor_min_day": FLOOR_MIN_DAY, "findings": found, "net": nets,
            "tools": tools, "unused": [dict(tools[k], key=k) for k in marks["unused"]], "hung": hung_findings(history[day])}


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--to", type=float, default=None)
    parser.add_argument("--calls", action="store_true")
    args = parser.parse_args(argv)
    hi = args.to or time.time()
    started = time.monotonic()
    chains = []
    calls, bash, chars_s, sessions = scan(hi - WINDOW_S, hi, chains=chains)
    if args.calls:
        for call in calls:
            print(json.dumps(dict(call, cluster=cluster(call["cmd"])), ensure_ascii=False))
        return 0
    day = day_of(calls, bash, chars_s, hi, sessions, chains=chains)
    print("%d Bash calls, %d ad hoc, %d chain links, write rate %s chars/s, scan %.1f s, mining %.1f s"
          % (bash, len(calls), len(chains), round(chars_s or 0, 1), time.monotonic() - started, day["chain_s"]))
    for key, c in sorted(day["clusters"].items(), key=lambda kv: -kv[1]["write_min"]):
        print("%-16s %5d calls %4d sessions %3d projects %6.1f min/day (%5.1f writing, %5.1f worker)%s%s" % (
            key, c["calls"], c["sessions"], len(recurs(c)), c["min"], c["write_min"], c["worker_min"],
            " · " + home(c) if home(c) is not None else "", " · over the floor" if over_floor(c) else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
