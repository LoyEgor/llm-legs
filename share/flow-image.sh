# Sourced by bin/gemini-image: the --route flow half, Google Flow images through share/flow_image.py in the
# hidden Chrome of gemini-web. Reads and sets bin/gemini-image's own variables.

flow_image_say() {
  image_leg_cause "$1"
  exit 2
}

flow_image_caps() { image_caps_get "$root" gemini ".flow_image$1"; }

# A --resume follows the records of the route that made it, never the id's shape: Flow and agy ids are both UUIDs.
flow_image_route() {
  local owner='' given=$route
  if [ -n "$resume" ]; then
    owner=$(image_leg_session_route gemini "$resume") || owner=''
    if [ -z "$owner" ] && [ -n "$account" ] && gemini_profile_name_valid "$account" &&
        [ -f "$(gemini_account_home "$account")/.gemini/antigravity-cli/conversations/$resume.db" ]; then
      owner=cli
    fi
  fi
  if [ -n "$owner" ] && [ -n "$given" ] && [ "$given" != "$owner" ]; then
    flow_image_say "--resume $resume was made on --route $owner and continues there; drop --route $given"
  fi
  route=${given:-${owner:-$(image_caps_get "$root" gemini '.routes[0]')}}
}

# Before anything is spent: what the chosen route cannot honour exits 2 with one line.
flow_image_flags() {
  if [ "$route" = cli ]; then
    [ -z "$model$upscale" ] && [ "$count" = 1 ] ||
      flow_image_say "--model, --count and --upscale run on --route flow (Google Flow)"
    return 0
  fi
  [ "$route" = flow ] || flow_image_say "--route is cli or flow"
  model=${model:-$(flow_image_caps .default_model)}
  [ -n "$(flow_image_caps ".models[\"$model\"] // empty")" ] ||
    flow_image_say "--model on --route flow is one of: $(flow_image_caps '.models | keys_unsorted | join(", ")')"
  [[ "$count" =~ ^[0-9]+$ ]] && [ -n "$(flow_image_caps ".counts | index($count) // empty")" ] ||
    flow_image_say "--count on --route flow is $(flow_image_caps '.counts | "\(min)-\(max)"')"
  aspect_asked=''
  if [ -n "$aspect" ] && { [ -z "$resume" ] || [ "$aspect_given" = true ]; }; then
    [[ "$aspect" =~ ^[1-9][0-9]*:[1-9][0-9]*$ ]] ||
      flow_image_say "--aspect is W:H; --route flow maps it to the nearest of: $(flow_image_caps '.aspects | join(" ")')"
    if [ -z "$(flow_image_caps ".aspects | index(\"$aspect\") // empty")" ]; then
      aspect_asked=$aspect
      aspect=$(image_caps_nearest_aspect "$aspect" "$(flow_image_caps '.aspects | join(",")')")
    fi
  fi
  [ "${#refs[@]}" -le "$(flow_image_caps .refs_max)" ] ||
    flow_image_say "--route flow takes at most $(flow_image_caps .refs_max) --ref images"
  [ -z "$upscale" ] || [ -n "$(flow_image_caps ".upscale[\"$upscale\"] // empty")" ] ||
    flow_image_say "--upscale is $(flow_image_caps '.upscale | keys | join("|")') (4K needs a higher Google plan)"
  [ -z "$resume" ] || { [ "$count" = 1 ] && [ "${#refs[@]}" -eq 0 ]; } ||
    flow_image_say "--resume on --route flow edits one image in its Flow editor; it takes no --count or --ref"
}

flow_tools_caps() { image_caps_get "$root" gemini ".flow_image.tools$1"; }

# --region/--point (inpaint), --remove-bg (cutout) and a prompt-less --aspect on one image (outpaint) run
# Flow's Image Editor tool on the image this machine holds, whatever account or route made it.
flow_image_tool_route() {
  [ -z "$route" ] || [ "$route" = flow ] ||
    flow_image_say "--region, --point, --remove-bg and a prompt-less --aspect edit run on --route flow (Flow's Image Editor)"
  route=flow
}

flow_image_tool_flags() {
  local point input_count=${#refs[@]}
  [ -z "$bg_model" ] || [ "$tool_op" = cutout ] || flow_image_say "--bg-model goes with --remove-bg"
  [ -n "$tool_op" ] || return 0
  [ -z "$resume" ] || input_count=$((input_count + 1))
  [ "$input_count" -eq 1 ] ||
    flow_image_say "the $tool_op edit takes one image: a single --ref, or --resume of a session this machine delivered"
  [ "$count" = 1 ] && [ -z "$upscale" ] && [ "$remove_green" = false ] ||
    flow_image_say "the $tool_op edit takes no --count, --upscale or --transparent"
  case $tool_op in
    cutout)
      [ -z "$prompt$region" ] && [ "${#points[@]}" -eq 0 ] && [ "$aspect_given" = false ] ||
        flow_image_say "--remove-bg runs alone: no --prompt, --aspect, --region or --point"
      bg_model=${bg_model:-$(flow_tools_caps .default_bg_model)}
      [ -z "$(flow_tools_caps ".bg_models_broken[\"$bg_model\"] // empty")" ] ||
        flow_image_say "--bg-model $bg_model: $(flow_tools_caps ".bg_models_broken[\"$bg_model\"]")"
      [ -n "$(flow_tools_caps ".bg_models[\"$bg_model\"] // empty")" ] ||
        flow_image_say "--bg-model is one of: $(flow_tools_caps '.bg_models | keys_unsorted | join(", ")')"
      [ "$extension" = png ] || flow_image_say "--remove-bg requires a .png destination"
      model=''
      ;;
    inpaint)
      [ "$aspect_given" = false ] || flow_image_say "an inpaint keeps the image's size: no --aspect"
      if [ -n "$region" ]; then
        [ "${#points[@]}" -eq 0 ] || flow_image_say "pass --region or --point, not both"
        [ -n "$prompt" ] || flow_image_say "--region needs a --prompt for the painted area"
        image_leg_region_ok "$region" ||
          flow_image_say "--region takes x,y,w,h as fractions of the image (0..1, inside it), not $region"
      else
        [ -z "$prompt" ] || flow_image_say "--point carries its own text (x,y=<text>): no --prompt"
        for point in "${points[@]}"; do
          python3 -c 'import sys; s, _, t = sys.argv[1].partition("="); x, y = (float(n) for n in s.split(",")); sys.exit(not (0 <= x <= 1 and 0 <= y <= 1 and t.strip()))' \
            "$point" 2>/dev/null ||
            flow_image_say "--point takes x,y=<text> with x,y fractions of the image (0..1), not $point"
        done
      fi
      ;;
  esac
  if [ "$tool_op" != cutout ]; then
    model=${model:-$(flow_image_caps .default_model)}
    [ -n "$(flow_tools_caps ".models | index(\"$model\") // empty")" ] ||
      flow_image_say "the Image Editor runs --model $(flow_tools_caps '.models | join("|")')"
  fi
  if [ "${#refs[@]}" -eq 1 ]; then
    tool_input=${refs[0]}
  else
    tool_input=$(image_leg_session_input gemini "$resume") ||
      flow_image_say "this machine delivered no image for session $resume; pass it as --ref"
  fi
  [[ "$tool_input" = /* ]] && [ -f "$tool_input" ] || flow_image_say "--ref $tool_input is not an absolute file path"
  tool_size=$(sips -g pixelWidth -g pixelHeight "$tool_input" 2>/dev/null |
    awk '/pixelWidth:/ {w = $2} /pixelHeight:/ {h = $2} END {if (w && h) print w "x" h}')
  [ -n "$tool_size" ] || flow_image_say "$tool_input is no image sips can read"
  if [ "$tool_op" = outpaint ]; then
    [ -z "$aspect_asked" ] && [ -n "$(flow_tools_caps ".aspects | index(\"$aspect\") // empty")" ] ||
      flow_image_say "outpaint takes --aspect $(flow_tools_caps '.aspects | join("|")'), not ${aspect_asked:-$aspect}"
    awk -v s="$tool_size" -v a="$aspect" 'BEGIN { split(s, d, "x"); split(a, r, ":"); q = d[1] / d[2] / (r[1] / r[2]);
      exit !(q > 0.98 && q < 1.02) }' && flow_image_say "the image is $tool_size, already $aspect: nothing to outpaint"
  else
    aspect='' aspect_asked=''
  fi
  resume='' refs=()
}

# The Image Editor half of flow_image_generate: same engine, result and failure shapes. A cutout comes back at
# most cutout_max_side wide, so its matte is laid over the full-size input.
flow_image_tool() {
  local engine_args point band side
  flow_image_temp
  engine_args=(tool --op "$tool_op" --image "$tool_input" --size "$tool_size" --out-dir "$tmp_dir")
  [ "$tool_op" = cutout ] && engine_args+=(--bg-model "$bg_model") || engine_args+=(--model "$model")
  [ -z "$prompt" ] || engine_args+=(--prompt "$prompt")
  if [ "${#points[@]}" -gt 0 ]; then
    engine_args+=(--prompt "$(for point in "${points[@]}"; do printf '%s; ' "${point#*=}"; done | sed 's/; $//')")
    for point in "${points[@]}"; do engine_args+=(--point "$point"); done
  fi
  [ -z "$region" ] || engine_args+=(--region "$region")
  [ "$tool_op" != outpaint ] || engine_args+=(--aspect "$aspect")
  flow_image_engine 1 "${engine_args[@]}"
  if [ "$tool_op" = outpaint ]; then
    while read -r side band; do
      [ "$(magick "$generated" -crop "$band" +repage -channel RGB -separate -evaluate-sequence max -threshold 4% \
        -format '%[fx:1-mean > 0.9]' info:)" = 0 ] || {
        printf 'gemini-image: Flow'"'"'s Outpaint left the %s band unfilled (black); nothing delivered\n' "$side" >&2
        exit 1
      }
    done < <(flow_image_outpaint_bands "$tool_size" "$aspect" "$(sips -g pixelWidth -g pixelHeight "$generated" |
      awk '/pixelWidth:/ {w = $2} /pixelHeight:/ {h = $2} END {print w "x" h}')")
  fi
  if [ "$tool_op" = cutout ]; then
    magick "$tool_input" \( "$generated" -alpha extract -resize "$tool_size!" \) -alpha off \
      -compose CopyOpacity -composite "PNG:$tmp_dir/cutout.png"
    generated=$tmp_dir/cutout.png
    has_usable_alpha "$generated" || {
      printf 'gemini-image: Flow'"'"'s Cutout returned no transparency; nothing delivered\n' >&2
      exit 1
    }
  fi
}

# The outer 16 px of each side an outpaint added (input WxH, aspect, output WxH) as "<side> <geometry>": Flow's
# unfilled canvas stays black from the edge in, and a partly filled side is still unfilled there.
flow_image_outpaint_bands() {
  awk -v input="$1" -v aspect="$2" -v output="$3" 'BEGIN {
    split(input, i, "x"); split(aspect, a, ":"); split(output, o, "x")
    if (i[1] * a[2] < i[2] * a[1]) { cw = i[2] * a[1] / a[2]; ch = i[2] } else { cw = i[1]; ch = i[1] * a[2] / a[1] }
    s = o[1] / cw
    if (ch > i[2]) { if ((ch - i[2]) / 2 * s > 20) printf "top %dx16+0+0\nbottom %dx16+0+%d\n", o[1], o[1], o[2] - 16 }
    else if ((cw - i[1]) / 2 * s > 20) printf "left 16x%d+0+0\nright 16x%d+%d+0\n", o[2], o[2], o[1] - 16
  }'
}

flow_image_generate() {
  local engine_args ref
  flow_image_temp
  engine_args=(generate --prompt "$content" --model "$model" --count "$count" --out-dir "$tmp_dir")
  [ -z "$aspect" ] || engine_args+=(--aspect "$aspect")
  for ref in ${refs[@]+"${refs[@]}"}; do engine_args+=(--ref "$ref"); done
  [ -z "$upscale" ] || engine_args+=(--upscale "$upscale")
  [ -z "$resume" ] || engine_args+=(--resume "$resume")
  flow_image_engine $((${#refs[@]} + 1)) "${engine_args[@]}"
}

flow_image_temp() {
  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/gemini-image.XXXXXX")
  trap 'image_leg_exit; rm -rf "$tmp_dir"' EXIT
}

# Runs the engine on "$@" after the image count image_leg_mark wants; sets account, generated, session,
# observed_model and flow_result.
flow_image_engine() {
  local marks=$1 rc=0 reason engine_args busy_account
  shift
  engine_args=("$@")
  [ -z "$account" ] || engine_args+=(--account "$account")
  [ -z "$IMAGE_LEG_LOCK_WAIT" ] || engine_args+=(--lock-wait "$IMAGE_LEG_LOCK_WAIT")
  image_leg_mark "$marks"
  if [ -n "${FLOW_IMAGE_ENGINE:-}" ]; then
    "$FLOW_IMAGE_ENGINE" "${engine_args[@]}" >"$tmp_dir/engine.out" 2>"$tmp_dir/engine.err" || rc=$?
  else
    "${GEMINI_WEB_UV:-$(command -v uv || printf /opt/homebrew/bin/uv)}" run -q --script "$root/share/flow_image.py" \
      "${engine_args[@]}" >"$tmp_dir/engine.out" 2>"$tmp_dir/engine.err" || rc=$?
  fi
  grep '^BROWSER_' "$tmp_dir/engine.err" >&2 || true
  flow_result=$(grep '^{' "$tmp_dir/engine.out" | tail -n 1 || true)
  if ! jq -e . >/dev/null 2>&1 <<<"$flow_result"; then
    tail -n 15 "$tmp_dir/engine.err" >&2
    printf 'gemini-image: the Flow engine printed no result (exit %s)\n' "$rc" >&2
    exit 1
  fi
  image_leg_engine_phases "$flow_result"
  if [ "$(jq -r '.ok' <<<"$flow_result")" != true ]; then
    reason=$(jq -r '.reason // "unknown failure"' <<<"$flow_result")
    printf 'gemini-image: %s\n' "$reason" >&2
    if image_leg_fallback "$rc" "$flow_result" "${fallback_next:-}"; then
      route=$IMAGE_LEG_ROUTE
      trap image_leg_exit EXIT
      rm -rf "$tmp_dir"
      return 0
    fi
    case "$rc" in
      3) image_leg_limit GEMINI "$flow_result" ;;
      5) busy_account=$(jq -r '.account // empty' <<<"$flow_result"); image_leg_busy "${busy_account:-$account}" ;;
      2 | 4) exit "$rc" ;;
      *) exit 1 ;;
    esac
  fi
  account=$(jq -r '.account' <<<"$flow_result")
  generated=$(jq -r '.takes[0].path // empty' <<<"$flow_result")
  [ -s "$generated" ] || { printf 'gemini-image: the Flow engine returned no image file\n' >&2; exit 1; }
  session=$(jq -r '.takes[0].id // "none"' <<<"$flow_result")
  observed_model=$(jq -r '.model // empty' <<<"$flow_result")
}

# After the shared dest/size/format/account/session lines.
flow_image_footer() {
  local index=1 take out vsize path
  [ -z "$aspect" ] || image_leg_aspect_fit "$aspect" "$width" "$height" "${aspect_asked:+ asked=$aspect_asked}" || true
  if [ "$tool_op" = cutout ]; then
    printf 'tool=cutout bg_model=%s on_device=true\n' "$bg_model"
  elif [ -z "$observed_model" ]; then
    printf 'model=unknown model_caps=unknown\n'
  elif jq -e --arg o "$observed_model" --arg m "$model" '.flow_image.models[$m].wire | any(. as $p | $o | test($p))' \
      "$(image_caps_file "$root" gemini)" >/dev/null; then
    printf 'model=%s model_caps=fresh\n' "$observed_model"
  else
    printf 'model=%s model_caps=stale verified=%s\n' "$observed_model" "$(flow_image_caps ".models[\"$model\"].wire | join(\",\") | if . == \"\" then \"none\" else . end")"
  fi
  printf 'caps=fresh surface=%s\n' "$(jq -r '.build // "unknown"' <<<"$flow_result")"
  if [ -n "$tool_op" ]; then
    image_leg_route_lines " tool=$tool_op${model:+ model=$model}"
  else
    image_leg_route_lines " model=$model upscale=${upscale:-none}"
  fi
  while IFS= read -r take; do
    index=$((index + 1))
    out="${dest%.*}-$index.${dest##*.}"
    path=$(jq -r '.path' <<<"$take")
    if [ "$remove_green" = true ]; then
      chroma_key_to_png "$path" "$tmp_dir" "$out"
    elif [ "$extension" != "$(actual_format "$path")" ]; then
      magick "$path" "$out"
    else
      cp "$path" "$out"
    fi
    vsize=$(sips -g pixelWidth -g pixelHeight "$out" | awk '/pixelWidth:/ {w = $2} /pixelHeight:/ {h = $2} END {print w "x" h}')
    printf 'variant=%s size=%s session=%s\n' "$out" "$vsize" "$(jq -r '.id // "none"' <<<"$take")"
    IMAGE_LEG_DELIVERED=$index
    image_leg_composite_take "$root" "$out" variant </dev/null
  done < <(jq -c '.takes[1:][]' <<<"$flow_result")
  jq -r '(.refused // [])[] | "refused=\(.media_id) \(.error)"' <<<"$flow_result"
  jq -r '.failed // 0 | select(. > 0) | "failed=\(.) reason=flow_generation_failed (not charged)"' <<<"$flow_result"
  jq -r '(.unsaved // [])[] | "unsaved=1 reason=\(.)"' <<<"$flow_result"
  jq -r '.seconds // empty | "seconds=\(.total) render=\(.render)"' <<<"$flow_result"
  jq -r '.credits_before // empty | "credits_before=\(.)"' <<<"$flow_result"
}
