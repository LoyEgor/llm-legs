import json
import os
import re
import subprocess
import sys

KNOBS = (
    ("settings model/effort/thinking", r"(^|/)settings(\.[\w-]+)?\.json$",
     r"\"(model|effortLevel|alwaysThinkingEnabled|MAX_THINKING_TOKENS|modelSettings)\"\s*:"),
    ("worker-model", r"(^|/)worker-model$", r"\S"),
    ("share/worker-model.sh table", r"(^|/)share/worker-model\.sh$", r"^(?!\s*#).*\b(low|medium|high|xhigh|max)\b"),
    ("share/worker-policy.md effort", r"(^|/)share/worker-policy\.md$", r"(?i)\beffort|^\|.*\b(low|medium|high|xhigh|max)\b"),
    ("review-bench tier effort/rater", r"(^|/)share/rbench/catalog\.py$",
     r"\"(low|medium|high|xhigh|max)\"|ROSTER|RATER|EFFORT|^\s*\(\"[\w.-]+\",\s*\d+\)"),
    ("agent model frontmatter", r"(^|/)agents/[^/]+\.md$", r"^(model|effort):"),
    ("claudeb default model", r"(^|/)(bin/claudeb|share/chat-open\.sh)$", r"CLAUDEB_CLAUDE_MODEL|--model|--effort"),
    ("brief-template EFFORT/MODEL", r"", r"^\s*(printf\s+[\x27\"])?(EFFORT|MODEL):\s*\S"),
)


def knob_site(path, text):
    return next((site for site, where, what in KNOBS if re.search(where, path) and re.search(what, text)), None)


def _git(tree, *args):
    try:
        out = subprocess.run(["git", "-C", tree] + list(args), capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return []
    return out.stdout.splitlines() if out.returncode == 0 else []


def changed_lines(tree, base, paths=()):
    """Untracked files count as added whole; with paths given, rows are spelled relative to the tree."""
    rows, path, old, new, header = [], "", 0, 0, False
    scope = ["--relative", "--"] + list(paths) if paths else []
    for line in _git(tree, "diff", "-U0", "--no-color", "--no-ext-diff", base, *scope):
        hunk = re.match(r"^@@ -(\d+)(?:,\d+)? \+(\d+)", line)
        if line.startswith("diff --git "):
            header = True
        elif header and line.startswith(("--- a/", "+++ b/")):
            path = line[6:]
        elif hunk:
            old, new, header = int(hunk.group(1)), int(hunk.group(2)), False
        elif not header and line.startswith("+"):
            rows.append((path, new, line))
            new += 1
        elif not header and line.startswith("-"):
            rows.append((path, old, line))
            old += 1
    for rel in _git(tree, "ls-files", "--others", "--exclude-standard", *(["--"] + list(paths) if paths else [])):
        try:
            with open(os.path.join(tree, rel), errors="replace") as handle:
                rows += [(rel, number, "+" + text.rstrip("\n")) for number, text in enumerate(handle, 1)]
        except OSError:
            pass
    return rows


def run_changes(directory):
    try:
        with open(os.path.join(directory, "files"), errors="replace") as handle:
            listed = [l.rstrip("\n") for l in handle if l.strip() and not re.match(r"^(WORKDIR|UNKNOWN|PARTIAL): ", l)]
        with open(os.path.join(directory, "head-before"), errors="replace") as handle:
            base = handle.read().strip()
        with open(os.path.join(directory, "meta.json")) as handle:
            workdir = json.load(handle).get("workdir") or ""
    except (OSError, ValueError):
        return []
    inside = [p for p in listed if not p.startswith("/")]
    hits = {}
    if workdir and base and inside:
        for path, number, line in changed_lines(workdir, base, inside):
            site = knob_site(path, line[1:])
            if site and path not in hits:
                hits[path] = "%s (line %d: %s)" % (site, number, line[:120])
    for path in listed:
        if path.startswith("/") and path not in hits:
            site = next((s for s, where, _ in KNOBS if where and re.search(where, path)), None)
            if site:
                hits[path] = "%s (outside the run's repository, not diffed)" % site
    return ["KNOBS CHANGED: %s: %s" % (path, what) for path, what in hits.items()]


if __name__ == "__main__" and len(sys.argv) == 3 and sys.argv[1] == "run":
    for row in run_changes(sys.argv[2]):
        print(row)
