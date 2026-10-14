# Is Egor away from the Mac? hammerspoon/presence.lua keeps presence/away ("<last input epoch>\t<written
# epoch>") while HID input has been idle 10 min and drops it within seconds of his return. A mark not
# rewritten for PRESENCE_MARK_FRESH_S reads as present: a stopped Hammerspoon must never leave anything
# slowed down. Builtins only — the statusline asks on every render.
PRESENCE_MARK_FRESH_S=180

# presence_away <now epoch>: status 0 while away.
presence_away() {
  local left written
  { IFS=$'\t' read -r left written <"${SPEED_DOCTOR_DIR:-$HOME/.cache/speed-doctor}/presence/away"; } 2>/dev/null ||
    return 1
  [[ "$left" =~ ^[0-9]+$ && "$written" =~ ^[0-9]+$ ]] || return 1
  [ $(($1 - written)) -le "$PRESENCE_MARK_FRESH_S" ] || return 1
}
