# The away trigger (Egor away from the Mac): chats subscribe in claude-setup hooks/away.d/, the Mac with Presence.subscribe.
# One trigger for every consumer (shared-invariants row em): a chat-side subscriber is a drop-in file in claude-setup
# hooks/away.d/ (hooks/away-dispatch.sh, the one settings entry); a Mac-side one registers Presence.subscribe(fn) in
# hammerspoon/presence.lua; a script reads presence_away below. presence.lua keeps presence/away ("<last input
# epoch>\t<written epoch>") while HID input has been idle 10 min and drops it within seconds of his return. A mark not
# rewritten for PRESENCE_MARK_FRESH_S reads as present: a stopped Hammerspoon must never leave anything
# slowed down. Builtins only — the statusline asks on every render.
PRESENCE_MARK_FRESH_S=180

# presence_away <now epoch>: status 0 while away, PRESENCE_SINCE then his last input epoch.
presence_away() {
  local written
  { IFS=$'\t' read -r PRESENCE_SINCE written <"${SPEED_DOCTOR_DIR:-$HOME/.cache/speed-doctor}/presence/away"; } 2>/dev/null ||
    return 1
  [[ "$PRESENCE_SINCE" =~ ^[0-9]+$ && "$written" =~ ^[0-9]+$ ]] || return 1
  [ $(($1 - written)) -le "$PRESENCE_MARK_FRESH_S" ] || return 1
}

# presence_unseen <session id> <now epoch>: status 0 while nobody sees that chat. The Chats app's server
# (chats-app app.py unseen_watch) keeps presence/unseen: "<written epoch>\n", then one session id a line for
# each live chat in a tmux pane with no viewer that no page or app shows; rewritten every 10 s and as a page
# opens or closes. A file of another shape, or one not rewritten for PRESENCE_MARK_FRESH_S, names nobody.
presence_unseen() {
  local u='' shape=$'^[1-9][0-9]{0,11}\n([A-Za-z0-9-]+\n)*$'
  { IFS= read -r -d '' u <"${SPEED_DOCTOR_DIR:-$HOME/.cache/speed-doctor}/presence/unseen"; } 2>/dev/null
  [[ $u =~ $shape ]] || return 1
  [ $(($2 - ${u%%$'\n'*})) -le "$PRESENCE_MARK_FRESH_S" ] || return 1
  [[ $'\n'${u#*$'\n'} == *$'\n'"$1"$'\n'* ]]
}
