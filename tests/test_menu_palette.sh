#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# hammerspoon/menu-style.lua is the only palette: no other menu module builds a colour, and every
# palette is exactly PALETTE, each colour opaque or at DIM_RED's alpha.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

check() {
python3 - "$@" <<'PY'
import re
import sys

style_path, *modules = sys.argv[1:]
HOME = "take the colour from hammerspoon/menu-style.lua"
PALETTE = {"RED", "DIM_RED", "GREEN", "DIM"}
COLOR = [
    (re.compile(r"\b(red|green|blue|hue|saturation|brightness|white)\s*=\s*[-+]?[0-9.]"), "a colour component"),
    (re.compile(r"\balpha\s*="), "an alpha"),
    (re.compile(r"[\"']#[0-9a-fA-F]{3,8}[\"']"), "a hex colour"),
    (re.compile(r"\blist\s*=\s*[\"']"), "a named colour"),
    (re.compile(r"hs\.drawing\.color\.(?!asRGB\b|asHSB\b)\w+"), "an hs.drawing.color name"),
]


def code(line):
    quote = None
    for i, ch in enumerate(line):
        if quote:
            if ch == quote and line[i - 1] != "\\":
                quote = None
        elif ch in "\"'":
            quote = ch
        elif line.startswith("--", i):
            return line[:i]
    return line


problems = []
for path in modules:
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            body = code(line)
            for pattern, what in COLOR:
                if pattern.search(body):
                    problems.append(f"{path}:{number}: {what} outside menu-style.lua ({line.strip()}); {HOME}")

with open(style_path, encoding="utf-8") as handle:
    style = handle.read()
palette = {}
for name, body in re.findall(r"^M\.([A-Z_]+)\s*=\s*\{([^}]*)\}", style, re.M):
    fields = dict(re.findall(r"(\w+)\s*=\s*(\"[^\"]*\"|[-0-9.]+)", body))
    if "size" not in fields:
        palette[name] = fields

for name, fields in palette.items():
    if "list" in fields:
        if fields["list"] != '"System"':
            problems.append(f"menu-style.lua: {name} names a colour outside the System list")
if set(palette) != PALETTE:
    problems.append(f"menu-style.lua: the palette is {sorted(palette)}, expected {sorted(PALETTE)};"
                    " a new or changed colour is Egor's call, then update PALETTE here")
if not problems:
    rgb = lambda f: tuple(float(f[k]) for k in ("red", "green", "blue"))  # noqa: E731
    dim_alpha = float(palette["DIM_RED"].get("alpha", 1))
    if "alpha" in palette["RED"] or rgb(palette["DIM_RED"]) != rgb(palette["RED"]) or dim_alpha >= 1:
        problems.append("menu-style.lua: RED must be opaque and DIM_RED be RED at an alpha below 1")
    for name, fields in palette.items():
        alpha = float(fields.get("alpha", 1))
        if "list" not in fields and alpha not in (1.0, dim_alpha):
            problems.append(f"menu-style.lua: {name}'s alpha {alpha:g} is neither opaque nor DIM_RED's {dim_alpha:g}")
print("\n".join(problems))
PY
}

modules=()
for file in "$ROOT"/hammerspoon/*.lua; do
  [ "${file##*/}" = menu-style.lua ] || modules+=("$file")
done
found=$(check "$ROOT/hammerspoon/menu-style.lua" "${modules[@]}") || fail "the palette check threw"
[ -z "$found" ] || fail "$found"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
printf 'local x = { red = 0.13, green = 0.55, blue = 0.25 }\nlocal y = "#ff0000"\n-- { alpha = 0.5 } in a comment\nlocal z = hs.drawing.color.x11.red\n' >"$WORK/rogue.lua"
rogue=$(check "$ROOT/hammerspoon/menu-style.lua" "$WORK/rogue.lua")
[ "$(printf '%s\n' "$rogue" | grep -c 'menu-style.lua')" = 3 ] || fail "a colour built outside menu-style.lua passed: $rogue"
{ cat "$ROOT/hammerspoon/menu-style.lua"; printf 'M.TEAL = { red = 0.1, green = 0.6, blue = 0.6 }\n'; } >"$WORK/menu-style.lua"
added=$(check "$WORK/menu-style.lua")
case "$added" in *"Egor's call"*) ;; *) fail "an invented palette colour passed: $added" ;; esac
sed 's/^M.GREEN = .*/M.GREEN = { red = 0.13, green = 0.55, blue = 0.25, alpha = 0.3 }/' "$ROOT/hammerspoon/menu-style.lua" >"$WORK/menu-style.lua"
shade=$(check "$WORK/menu-style.lua")
case "$shade" in *"GREEN's alpha 0.3"*) ;; *) fail "an invented alpha passed: $shade" ;; esac
echo "OK: menu-style.lua is the only palette"
