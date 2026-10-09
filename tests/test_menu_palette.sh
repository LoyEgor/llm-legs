#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# hammerspoon/menu-style.lua is the only palette: no other menu module builds a colour, and every
# palette colour is RED's saturation and lightness at its own hue, opaque or at DIM_RED's alpha.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

check() {
python3 - "$@" <<'PY'
import colorsys
import re
import sys

style_path, *modules = sys.argv[1:]
HOME = "add the colour to hammerspoon/menu-style.lua and use it from there"
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
for need in ("RED", "DIM_RED", "GREEN"):
    if need not in palette:
        problems.append(f"menu-style.lua has no {need}")
if not problems:
    rgb = lambda f: tuple(float(f[k]) for k in ("red", "green", "blue"))  # noqa: E731
    _, red_l, red_s = colorsys.rgb_to_hls(*rgb(palette["RED"]))
    dim_alpha = float(palette["DIM_RED"].get("alpha", 1))
    if "alpha" in palette["RED"] or rgb(palette["DIM_RED"]) != rgb(palette["RED"]) or dim_alpha >= 1:
        problems.append("menu-style.lua: RED must be opaque and DIM_RED be RED at an alpha below 1")
    for name, fields in palette.items():
        if "list" in fields:
            continue
        _, light, sat = colorsys.rgb_to_hls(*rgb(fields))
        alpha = float(fields.get("alpha", 1))
        if abs(light - red_l) > 0.01 or abs(sat - red_s) > 0.01:
            problems.append(f"menu-style.lua: {name} is not RED's saturation {red_s:.3f} and lightness {red_l:.3f}"
                            f" at another hue (has {sat:.3f}, {light:.3f})")
        if alpha not in (1.0, dim_alpha):
            problems.append(f"menu-style.lua: {name}'s alpha {alpha:g} is neither opaque nor DIM_RED's {dim_alpha:g}")
    if float(palette["GREEN"].get("alpha", 1)) != dim_alpha:
        problems.append("menu-style.lua: GREEN is not at DIM_RED's alpha")
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
sed 's/^M.GREEN = .*/M.GREEN = { red = 0.13, green = 0.55, blue = 0.25 }/' "$ROOT/hammerspoon/menu-style.lua" >"$WORK/menu-style.lua"
shade=$(check "$WORK/menu-style.lua")
case "$shade" in
  *"GREEN is not RED's saturation"*"GREEN is not at DIM_RED's alpha"*) ;;
  *) fail "an invented green shade passed: $shade" ;;
esac
echo "OK: menu-style.lua is the only palette"
