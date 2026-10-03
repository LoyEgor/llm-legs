#!/usr/bin/env bash

chroma_key_to_png() {
  local src="$1" tmp_dir="$2" dest="$3" key

  # The model never hits #00FF00 exactly; keying on a corner sample plus a green
  # despill kills the fringe that a fixed key color leaves on anti-aliased edges.
  # The despill is masked to a 2px inner edge band: applied globally it would
  # dull every legitimately green object in the image.
  key=$(magick "$src" -format '%[pixel:p{2,2}]' info:)
  magick "$src" -fuzz 12% -transparent "$key" "$tmp_dir/keyed.png"
  magick "$tmp_dir/keyed.png" -alpha extract -morphology EdgeIn Octagon:2 "$tmp_dir/edge.png"
  magick "$tmp_dir/keyed.png" -channel G -fx 'min(g,max(r,b))' +channel "$tmp_dir/despilled.png"
  magick "$tmp_dir/keyed.png" "$tmp_dir/despilled.png" "$tmp_dir/edge.png" -composite "PNG:$dest"
}

has_usable_alpha() { # path
  local flag minima
  flag=$(magick identify -format '%A' "$1" 2>/dev/null) || return 1
  case "$flag" in Undefined|undefined|False|false) return 1 ;; esac
  minima=$(magick "$1" -alpha extract -format '%[fx:minima]' info: 2>/dev/null) || return 1
  awk -v value="$minima" 'BEGIN { exit !(value + 0 < 0.99) }'
}
