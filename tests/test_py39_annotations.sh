#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

# launchd jobs run /usr/bin/python3 (3.9): `list[str] | None` in a def evaluates at import there and kills the
# whole collector (llm-doctor 'failed' 2026-10-10 via share/caps_checks.py), so such a file needs the future import.
cat >"$WORK/scan.py" <<'EOF'
import ast, os, sys

def modern(node):
    for n in ast.walk(node):
        if isinstance(n, ast.BinOp) and isinstance(n.op, ast.BitOr):
            return True
        if isinstance(n, ast.Subscript) and isinstance(n.value, ast.Name) and n.value.id in ("list", "dict", "tuple", "set", "frozenset", "type"):
            return True
    return False

def bad(path):
    try:
        tree = ast.parse(open(path, encoding="utf-8").read())
    except (SyntaxError, UnicodeDecodeError):
        return False
    if any(isinstance(n, ast.ImportFrom) and n.module == "__future__" and any(a.name == "annotations" for a in n.names)
           for n in tree.body):
        return False
    for n in ast.walk(tree):
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
            args = n.args.posonlyargs + n.args.args + n.args.kwonlyargs + [a for a in (n.args.vararg, n.args.kwarg) if a]
            if any(a.annotation is not None and modern(a.annotation) for a in args) or (n.returns is not None and modern(n.returns)):
                return True
    scopes = [tree.body] + [n.body for n in ast.walk(tree) if isinstance(n, ast.ClassDef)]
    return any(isinstance(s, ast.AnnAssign) and modern(s.annotation) for body in scopes for s in body)

def python(path):
    if path.endswith(".py"):
        return True
    try:
        with open(path, "rb") as handle:
            return b"python" in handle.readline()
    except OSError:
        return False

root = sys.argv[1]
files = [os.path.join(root, d, f) for d in ("share", "bin") for f in sorted(os.listdir(os.path.join(root, d)))]
hits = [os.path.relpath(p, root) for p in files if os.path.isfile(p) and python(p) and bad(p)]
print("\n".join(hits))
EOF

asserts=0
assert() { asserts=$((asserts + 1)); "$@" || { printf 'FAIL: assert %s: %s\n' "$asserts" "$*"; exit 1; }; }

mkdir -p "$WORK/fx/share" "$WORK/fx/bin"
printf 'def f(x: list[str] | None) -> None:\n    pass\n' >"$WORK/fx/share/old.py"
printf 'from __future__ import annotations\ndef f(x: list[str] | None) -> None:\n    pass\n' >"$WORK/fx/share/ok.py"
printf '#!/usr/bin/env python3\ndef f() -> tuple[int, int]:\n    pass\n' >"$WORK/fx/bin/tool"
printf 'def f(x: "list[str] | None"):\n    pass\n' >"$WORK/fx/share/quoted.py"
fx=$(python3 "$WORK/scan.py" "$WORK/fx")
assert [ "$fx" = "$(printf 'share/old.py\nbin/tool')" ] || [ "$fx" = "$(printf 'bin/tool\nshare/old.py')" ]

live=$(python3 "$WORK/scan.py" "$ROOT")
[ -z "$live" ] || printf 'needs `from __future__ import annotations` (launchd runs Python 3.9):\n%s\n' "$live"
assert [ -z "$live" ]

echo "PASS: $asserts asserts; every share/ and bin/ Python file with 3.10+ annotations imports under Python 3.9"
