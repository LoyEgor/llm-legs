#!/usr/bin/env bash
. "$(dirname "$0")/../lib/labels.sh"

fit_dir_part() {
  local dir_part=$1 wt_color=$2 fit_out=$3 RESET='\033[0m'
  if [ -n "$fit_out" ]; then
    dir_part="${dir_part} ${wt_color}⧉ ${fit_out}${RESET}"
  fi
  printf '%s' "$dir_part"
}

fit_dir_part "$@"
