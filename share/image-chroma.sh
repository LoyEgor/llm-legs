#!/usr/bin/env bash

chroma_key_to_png() { # src tmp-dir dest (tmp-dir unused since the steps stay in memory)
  local src="$1" dest="$3" key

  # The model never hits #00FF00 exactly; keying on a corner sample plus a green
  # despill kills the fringe that a fixed key color leaves on anti-aliased edges.
  # The despill is masked to a 2px inner edge band: applied globally it would
  # dull every legitimately green object in the image. The keyed image stays in memory (mpr:), one
  # decode for the despill, the edge band and the composite; the pixels match the PNG round trips.
  key=$(magick "$src" -format '%[pixel:p{2,2}]' info:)
  magick "$src" -fuzz 12% -transparent "$key" -write mpr:keyed +delete \
    mpr:keyed \( mpr:keyed -channel G -fx 'min(g,max(r,b))' +channel \) \
    \( mpr:keyed -alpha extract -morphology EdgeIn Octagon:2 \) -composite "PNG:$dest"
}

has_usable_alpha() { # path
  local flag minima
  flag=$(magick identify -format '%A' "$1" 2>/dev/null) || return 1
  case "$flag" in Undefined|undefined|False|false) return 1 ;; esac
  minima=$(magick "$1" -alpha extract -format '%[fx:minima]' info: 2>/dev/null) || return 1
  awk -v value="$minima" 'BEGIN { exit !(value + 0 < 0.99) }'
}
