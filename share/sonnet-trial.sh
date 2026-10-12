# TEMP-SONNET-TRIAL(fixers): the whole file; EXPERIMENTS.json entry `sonnet-fixes` removes it.

sonnet_trial_marker() {
  printf '%s\n' "${SONNET_TRIAL_MARKER:-${DOCTORS_DIR:-$HOME/.cache/doctors}/sonnet-trial.json}"
}

# Stricter than experiments_marker_live, which keeps announcing an unreadable marker: this one
# switches models, and only a readable future `until` switches anything.
sonnet_trial_live() {
  jq -e --argjson now "$(date +%s)" '(.until | type) == "number" and .until > $now' \
    "$(sonnet_trial_marker)" >/dev/null 2>&1
}

sonnet_trial_lens() { # bench-dir -> the round's fit/legacy lens while the trial is live; status 1 otherwise
  local lens
  sonnet_trial_live || return 1
  lens=$(jq -r '.lens // empty' "$1/meta.json" 2>/dev/null)
  case "$lens" in fit | legacy | legacy-*) printf '%s\n' "$lens" ;; *) return 1 ;; esac
}
