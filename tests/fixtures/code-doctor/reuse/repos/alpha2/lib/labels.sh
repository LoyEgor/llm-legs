#!/usr/bin/env bash
trim_label() {
  local text=$1 width=$2
  [ "${#text}" -le "$width" ] && { printf '%s\n' "$text"; return; }
  printf '%s~\n' "${text:0:$((width - 1))}"
}
