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
