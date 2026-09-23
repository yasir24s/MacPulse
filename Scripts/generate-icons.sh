#!/bin/bash
# Generate MacPulse icon assets from one vector source.
#
# The mark is deliberately unlike Auscult's. Auscult is a horizontal pulse
# trace with radiating arcs -- a waveform being listened to. MacPulse is
# vertical columns: discrete samples stacking up over time, with a trend line
# riding their tops. Opposite silhouette, so the two never read as siblings
# in the Dock, and columns survive the 18px menu bar crush that would erase a
# thin trace.
#
# Two outputs, because they have different rules:
#   icns      -- full colour, macOS squircle drawn here with its ~10% margin
#                (nothing masks a Mac icon, so we draw the shape ourselves)
#   template  -- monochrome + alpha, named *Template.png so AppKit tints it
#                for light/dark menu bars and inverts it when highlighted
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/Resources"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"
command -v rsvg-convert >/dev/null || { echo "need rsvg-convert: brew install librsvg" >&2; exit 1; }

# Column geometry, shared by both variants so they stay in register.
# 6 bars, width 70, gap 36, centred in a 1024 field; baseline y=768.
BARS="220 380 160 300 500 260 340"
# index of the peak column, drawn hot to imply a live threshold breach
PEAK=4

emit_columns () {  # $1 = fill (paint server ref or colour)
  local fill="$1" hot="${2:-}" x=199 i=0 out=""
  for h in $BARS; do
    local y=$(( 768 - h ))
    local f="$fill"
    [ -n "$hot" ] && [ "$i" = "$PEAK" ] && f="$hot"
    out+="<rect x=\"$x\" y=\"$y\" width=\"62\" height=\"$h\" rx=\"24\" ry=\"24\" fill=\"$f\"/>"
    x=$(( x + 94 )); i=$(( i + 1 ))
  done
  printf '%s' "$out"
}


emit_svg () {  # $1 = colour|template
  local kind="$1"
  if [ "$kind" = "colour" ]; then
    cat <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="field" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0"    stop-color="#160F35"/>
      <stop offset="0.55" stop-color="#3B1E6E"/>
      <stop offset="1"    stop-color="#7C3AED"/>
    </linearGradient>
    <linearGradient id="cols" x1="0" y1="1" x2="0" y2="0">
      <stop offset="0"   stop-color="#8B7BD8"/>
      <stop offset="1"   stop-color="#D6CCFF"/>
    </linearGradient>
    <linearGradient id="hot" x1="0" y1="1" x2="0" y2="0">
      <stop offset="0"   stop-color="#F59E0B"/>
      <stop offset="1"   stop-color="#FDE68A"/>
    </linearGradient>
    <clipPath id="squircle">
      <rect x="100" y="100" width="824" height="824" rx="185" ry="185"/>
    </clipPath>
  </defs>
  <g clip-path="url(#squircle)">
    <rect x="100" y="100" width="824" height="824" fill="url(#field)"/>
    <g stroke="#C4B5FD" stroke-width="5" opacity="0.13">
      <line x1="160" y1="360" x2="864" y2="360"/>
      <line x1="160" y1="470" x2="864" y2="470"/>
      <line x1="160" y1="580" x2="864" y2="580"/>
      <line x1="160" y1="690" x2="864" y2="690"/>
    </g>
    $(emit_columns 'url(#cols)' 'url(#hot)')
    <line x1="160" y1="790" x2="864" y2="790" stroke="#C4B5FD" stroke-width="9"
          stroke-linecap="round" opacity="0.45"/>
  </g>
</svg>
SVG
  else
    # Template: pure black + alpha, no field, no margin -- AppKit tints it.
    cat <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  $(emit_columns '#000000')
  <line x1="180" y1="800" x2="844" y2="800" stroke="#000000" stroke-width="22"
        stroke-linecap="round" opacity="0.55"/>
</svg>
SVG
  fi
}

# --- colour icns -------------------------------------------------------------
emit_svg colour > "$WORK/colour.svg"
ICONSET="$WORK/MacPulse.iconset"; mkdir -p "$ICONSET"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
  set -- $spec
  rsvg-convert -w "$1" -h "$1" "$WORK/colour.svg" -o "$ICONSET/icon_$2.png"
done
iconutil -c icns "$ICONSET" -o "$OUT/MacPulse.icns"
echo "wrote $OUT/MacPulse.icns"

# --- monochrome menu bar template -------------------------------------------
emit_svg template > "$WORK/template.svg"
# 18pt logical; ship @1x/@2x/@3x. Name matters: *Template triggers AppKit tinting.
rsvg-convert -w 18 -h 18 "$WORK/template.svg" -o "$OUT/MenuBarTemplate.png"
rsvg-convert -w 36 -h 36 "$WORK/template.svg" -o "$OUT/MenuBarTemplate@2x.png"
rsvg-convert -w 54 -h 54 "$WORK/template.svg" -o "$OUT/MenuBarTemplate@3x.png"
echo "wrote $OUT/MenuBarTemplate{,@2x,@3x}.png"

# --- preview sheet -----------------------------------------------------------
rsvg-convert -w 512 -h 512 "$WORK/colour.svg" -o "$OUT/preview-icon.png"
echo "wrote $OUT/preview-icon.png"
