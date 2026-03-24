#!/usr/bin/env bash
# generate-icons.sh — Generate all required PWA icon sizes from a source image
#
# Usage: ./generate-icons.sh <source-image> [output-dir]
#   source-image  Path to source PNG/SVG (recommended: 1024x1024 or larger)
#   output-dir    Output directory (default: ./icons)
#
# Requires: ImageMagick (convert) or GraphicsMagick (gm convert)
# Install: sudo apt install imagemagick  OR  brew install imagemagick
#
# Generates icons for: PWA manifest, Apple touch, favicon, Windows tiles, maskable

set -euo pipefail

SOURCE="${1:-}"
OUTPUT_DIR="${2:-./icons}"

if [ -z "$SOURCE" ]; then
  echo "Usage: $0 <source-image> [output-dir]"
  echo ""
  echo "Example: $0 logo.png ./public/icons"
  echo ""
  echo "Source should be square, at least 1024x1024 pixels."
  exit 1
fi

if [ ! -f "$SOURCE" ]; then
  echo "❌ Source file not found: $SOURCE"
  exit 1
fi

# Detect image tool
CONVERT=""
if command -v magick &>/dev/null; then
  CONVERT="magick"
elif command -v convert &>/dev/null; then
  CONVERT="convert"
elif command -v gm &>/dev/null; then
  CONVERT="gm convert"
else
  echo "❌ ImageMagick or GraphicsMagick is required."
  echo "   Install: sudo apt install imagemagick  OR  brew install imagemagick"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
echo "🎨 Generating PWA icons from: $SOURCE"
echo "   Output: $OUTPUT_DIR/"
echo "   Tool: $CONVERT"

# Standard PWA icon sizes
SIZES=(16 32 48 72 96 128 144 152 167 180 192 256 384 512 1024)

for size in "${SIZES[@]}"; do
  out="$OUTPUT_DIR/icon-${size}.png"
  $CONVERT "$SOURCE" -resize "${size}x${size}" -gravity center -extent "${size}x${size}" "$out"
  echo "  ✅ ${size}x${size} → $out"
done

# Maskable icon (with 10% padding for safe area)
echo ""
echo "🎭 Generating maskable icons..."
for size in 192 512; do
  out="$OUTPUT_DIR/icon-maskable-${size}.png"
  inner=$((size * 80 / 100))
  $CONVERT "$SOURCE" \
    -resize "${inner}x${inner}" \
    -gravity center \
    -background white \
    -extent "${size}x${size}" \
    "$out"
  echo "  ✅ ${size}x${size} maskable → $out"
done

# Favicon ICO (multi-size)
echo ""
echo "🌐 Generating favicon..."
$CONVERT "$SOURCE" \
  -resize 16x16 -gravity center -extent 16x16 \
  "$OUTPUT_DIR/favicon-16.png"
$CONVERT "$SOURCE" \
  -resize 32x32 -gravity center -extent 32x32 \
  "$OUTPUT_DIR/favicon-32.png"
$CONVERT "$OUTPUT_DIR/favicon-16.png" "$OUTPUT_DIR/favicon-32.png" \
  "$OUTPUT_DIR/favicon.ico" 2>/dev/null || \
  cp "$OUTPUT_DIR/favicon-32.png" "$OUTPUT_DIR/favicon.ico"
echo "  ✅ favicon.ico"
rm -f "$OUTPUT_DIR/favicon-16.png" "$OUTPUT_DIR/favicon-32.png"

# Apple touch icon
echo ""
echo "🍎 Generating Apple touch icon..."
$CONVERT "$SOURCE" -resize 180x180 -gravity center -extent 180x180 \
  "$OUTPUT_DIR/apple-touch-icon.png"
echo "  ✅ apple-touch-icon.png (180x180)"

# Summary
COUNT=$(find "$OUTPUT_DIR" -name "*.png" -o -name "*.ico" | wc -l)
echo ""
echo "🎉 Generated $COUNT icon files in $OUTPUT_DIR/"
echo ""
echo "Add to your HTML <head>:"
echo '  <link rel="icon" type="image/png" sizes="32x32" href="/icons/icon-32.png">'
echo '  <link rel="icon" type="image/png" sizes="16x16" href="/icons/icon-16.png">'
echo '  <link rel="apple-touch-icon" href="/icons/apple-touch-icon.png">'
echo ""
echo "Manifest icons (add to manifest.json):"
cat << 'MANIFEST_HINT'
  "icons": [
    { "src": "/icons/icon-192.png", "sizes": "192x192", "type": "image/png" },
    { "src": "/icons/icon-512.png", "sizes": "512x512", "type": "image/png" },
    { "src": "/icons/icon-maskable-192.png", "sizes": "192x192", "type": "image/png", "purpose": "maskable" },
    { "src": "/icons/icon-maskable-512.png", "sizes": "512x512", "type": "image/png", "purpose": "maskable" }
  ]
MANIFEST_HINT
