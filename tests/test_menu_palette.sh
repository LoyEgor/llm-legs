#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# hammerspoon/menu-style.lua is the only palette: no other menu module builds a colour, and every
# palette is exactly PALETTE: RED and GREEN opaque, DIM_RED and DIM_GREEN each at one shared alpha,
# and the only other colour literals are the calibrated per-theme LOOK (DIM_ and INACTIVE_). A row
# takes those through M.tone(color, inactive): every module with disabled rows passes its tree through
# M.mono, which retones them, and a module whose titles skip that walk (M.toned) sends every RED and
# DIM_RED through tone(). GREEN and DIM_GREEN go through tone() everywhere.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

STYLE="$ROOT/hammerspoon/menu-style.lua"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
modules=()
for file in "$ROOT"/hammerspoon/*.lua; do
  [ "${file##*/}" = menu-style.lua ] || modules+=("$file")
done
printf 'local x = { red = 0.13, green = 0.55, blue = 0.25 }\nlocal y = "#ff0000"\n-- { alpha = 0.5 } in a comment\nlocal z = hs.drawing.color.x11.red\nlocal g = { color = style.GREEN }\nlocal h = style.tone(style.GREEN, true)\n' >"$WORK/rogue.lua"
printf 'local items = { { title = t, disabled = true } }\nreturn items\n' >"$WORK/unwalked.lua"
printf 'local a = { color = style.RED }\nlocal b = style.tone(style.DIM_RED, true)\nreturn style.mono({ { title = style.toned(a), disabled = true } }, f)\n' >"$WORK/skipping.lua"
printf 'local a = { color = style.RED }\nreturn style.mono({ { title = a, disabled = true } }, f)\n' >"$WORK/walked.lua"
printf 'local g = { color = style.DIM_GREEN }\nlocal h = style.tone(style.DIM_GREEN, false)\n' >"$WORK/dimgreen.lua"
grep -v '^function M.tone' "$STYLE" >"$WORK/style-untoned.lua"
{ cat "$STYLE"; printf 'M.TEAL = { red = 0.1, green = 0.6, blue = 0.6 }\n'; } >"$WORK/style-added.lua"
sed 's/^M.GREEN = .*/M.GREEN = { red = 0.13, green = 0.55, blue = 0.25, alpha = 0.3 }/' "$STYLE" >"$WORK/style-green.lua"
sed 's/^M.DIM_GREEN = .*/M.DIM_GREEN = { red = 0.13, green = 0.55, blue = 0.25, alpha = 0.3 }/' "$STYLE" >"$WORK/style-dimgreen.lua"
{ cat "$STYLE"; printf 'local SOFT_RED = { red = 0.95, green = 0.4, blue = 0.35 }\n'; } >"$WORK/style-stray.lua"
{
  printf 'found\t%s' "$STYLE"; printf '\t%s' "${modules[@]}"; printf '\n'
  printf 'rogue\t%s\t%s\n' "$STYLE" "$WORK/rogue.lua"
  printf 'reds\t%s\t%s\t%s\t%s\n' "$STYLE" "$WORK/unwalked.lua" "$WORK/skipping.lua" "$WORK/walked.lua"
  printf 'untoned\t%s\n' "$WORK/style-untoned.lua"
  printf 'added\t%s\n' "$WORK/style-added.lua"
  printf 'shade\t%s\n' "$WORK/style-green.lua"
  printf 'dimshade\t%s\n' "$WORK/style-dimgreen.lua"
  printf 'stray\t%s\n' "$WORK/style-stray.lua"
  printf 'dimgreen\t%s\t%s\n' "$STYLE" "$WORK/dimgreen.lua"
} >"$WORK/cases"
python3 -S - "$WORK" <<'PY' || fail "the palette check threw"
import os
import re
import sys

HOME = "take the colour from hammerspoon/menu-style.lua"
PALETTE = {"RED", "DIM_RED", "GREEN", "DIM_GREEN", "DIM"}
COLOR = [
    (re.compile(r"\b(red|green|blue|hue|saturation|brightness|white)\s*=\s*[-+]?[0-9.]"), "a colour component"),
    (re.compile(r"\balpha\s*="), "an alpha"),
    (re.compile(r"[\"']#[0-9a-fA-F]{3,8}[\"']"), "a hex colour"),
    (re.compile(r"\blist\s*=\s*[\"']"), "a named colour"),
    (re.compile(r"hs\.drawing\.color\.(?!asRGB\b|asHSB\b)\w+"), "an hs.drawing.color name"),
]


def raw(body, names):
    if not any(name in body for name in names):
        return False

    def count(prefix):
        return sum(len(re.findall(prefix + rf"(?:\.{name}\b|\[\s*[\"']{name}[\"']\s*\])", body)) for name in names)
    return count("") > count(r"\btone\(\s*[\w.]*")


def code(line):
    if "--" not in line:
        return line
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


def check(style_path, modules):
    problems = []
    for path in modules:
        with open(path, encoding="utf-8") as handle:
            bodies = [code(line) for line in handle]
        walked = any(".mono(" in body for body in bodies)
        skips = any(".toned(" in body for body in bodies)
        if not walked and any(re.search(r"\bdisabled\s*=\s*true\b", body) for body in bodies):
            problems.append(f"{path}: disabled rows but no menu-style.lua mono() over the tree; return the menu through"
                            " mono so a disabled row's red and green get tone(…, true)")
        for number, body in enumerate(bodies, 1):
            for pattern, what in COLOR:
                if pattern.search(body):
                    problems.append(f"{path}:{number}: {what} outside menu-style.lua ({body.strip()}); {HOME}")
            if raw(body, ["GREEN", "DIM_GREEN"]):
                problems.append(f"{path}:{number}: a raw GREEN ({body.strip()}); pass it through menu-style.lua"
                                " tone(GREEN, inactive) so a disabled row gets the calibrated green")
            if skips and raw(body, ["RED", "DIM_RED"]):
                problems.append(f"{path}:{number}: a raw RED in a module whose titles skip the retone walk (toned)"
                                f" ({body.strip()}); pass it through menu-style.lua tone(RED, inactive)")

    with open(style_path, encoding="utf-8") as handle:
        style = handle.read()
    if (not re.search(r"^function M\.tone\(color, inactive\)$", style, re.M) or "local LOOK = {" not in style
            or not re.search(r"^  dark = \{$", style, re.M) or "item.title = retoned(item.title" not in style):
        problems.append("menu-style.lua: M.tone(color, inactive), its per-theme LOOK or mono's retone are gone")
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
        if (rgb(palette["DIM_GREEN"]) != rgb(palette["GREEN"])
                or float(palette["DIM_GREEN"].get("alpha", 1)) != dim_alpha):
            problems.append("menu-style.lua: DIM_GREEN must be GREEN at DIM_RED's alpha")
        for number, line in enumerate(style.splitlines(), 1):
            if re.search(r"\{\s*red\s*=", line) and not re.match(
                    r"(M\.(%s)|    (DIM|INACTIVE)_(GREEN|RED)) = \{" % "|".join(PALETTE), line):
                problems.append(f"menu-style.lua:{number}: a colour outside the palette and its calibrated LOOK"
                                f" values ({line.strip()}); a new look is Egor's call and is measured on the real menu")
        for name, fields in palette.items():
            alpha = float(fields.get("alpha", 1))
            if "list" not in fields and alpha not in (1.0, dim_alpha):
                problems.append(f"menu-style.lua: {name}'s alpha {alpha:g} is neither opaque nor DIM_RED's {dim_alpha:g}")
    return problems


work = sys.argv[1]
for line in open(os.path.join(work, "cases"), encoding="utf-8").read().splitlines():
    name, style_path, *modules = line.split("\t")
    with open(os.path.join(work, "out." + name), "w", encoding="utf-8") as out:
        out.write("\n".join(check(style_path, modules)))
PY
for name in found rogue reds untoned added shade dimshade stray dimgreen; do
  printf -v "out_$name" '%s' "$(<"$WORK/out.$name")"
done
found=$out_found rogue=$out_rogue reds=$out_reds untoned=$out_untoned added=$out_added shade=$out_shade dimshade=$out_dimshade
stray=$out_stray dimgreen=$out_dimgreen
[ -z "$found" ] || fail "$found"

[ "$(printf '%s\n' "$rogue" | grep -c 'menu-style.lua')" = 4 ] || fail "a colour built outside menu-style.lua passed: $rogue"
case "$rogue" in *"rogue.lua:5: a raw GREEN"*) ;; *) fail "a raw GREEN outside tone() passed: $rogue" ;; esac
case "$rogue" in *"rogue.lua:6:"*) fail "GREEN through tone() was rejected: $rogue" ;; esac
case "$reds" in *"unwalked.lua: disabled rows but no menu-style.lua mono()"*) ;; *) fail "a disabled row outside mono passed: $reds" ;; esac
case "$reds" in *"skipping.lua:1: a raw RED"*) ;; *) fail "a raw RED in a toned module passed: $reds" ;; esac
case "$reds" in *"skipping.lua:2:"*|*"/walked.lua:"*) fail "a toned or walked red was rejected: $reds" ;; esac
case "$untoned" in *"M.tone(color, inactive)"*) ;; *) fail "a palette without M.tone passed: $untoned" ;; esac
case "$added" in *"Egor's call"*) ;; *) fail "an invented palette colour passed: $added" ;; esac
case "$shade" in *"GREEN's alpha 0.3"*) ;; *) fail "an invented alpha passed: $shade" ;; esac
case "$dimshade" in *"DIM_GREEN must be GREEN at DIM_RED's alpha"*) ;; *) fail "a DIM_GREEN off DIM_RED's alpha passed: $dimshade" ;; esac
case "$stray" in *"a colour outside the palette and its calibrated LOOK"*) ;; *) fail "an uncalibrated colour in menu-style.lua passed: $stray" ;; esac
case "$dimgreen" in *"dimgreen.lua:1: a raw GREEN"*) ;; *) fail "a raw DIM_GREEN outside tone() passed: $dimgreen" ;; esac
case "$dimgreen" in *"dimgreen.lua:2:"*) fail "DIM_GREEN through tone() was rejected: $dimgreen" ;; esac
echo "OK: menu-style.lua is the only palette"
