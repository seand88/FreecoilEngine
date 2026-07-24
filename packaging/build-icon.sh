#!/bin/bash
# build-icon.sh — regenerate the compiled app icon from source.
#
# Source of truth: packaging/AppIcon.icon (Icon Composer document; the layer
# image is the full-bleed 1024 master, also kept as BAR-icon-1024.png).
# Outputs (committed, so release builds need no Xcode):
#   packaging/Assets.car    — native macOS 26 icon (full-tile, system glass;
#                             without it Tahoe shrinks legacy .icns onto a
#                             white tray)
#   packaging/AppIcon.icns  — actool-generated legacy fallback
#
# Requires full Xcode (actool with .icon support); run only when the icon
# artwork changes.
set -euo pipefail

PKG="$(cd "$(dirname "$0")" && pwd)"
OUT=$(mktemp -d)

xcrun actool --output-format human-readable-text --notices --warnings \
  --output-partial-info-plist "$OUT/partial.plist" \
  --app-icon AppIcon \
  --include-all-app-icons \
  --compile "$OUT" \
  --platform macosx \
  --minimum-deployment-target 26.0 \
  "$PKG/AppIcon.icon"

[ -f "$OUT/Assets.car" ] && [ -f "$OUT/AppIcon.icns" ] || {
  echo "FATAL: actool did not produce Assets.car + AppIcon.icns"; exit 1; }
cp "$OUT/Assets.car" "$PKG/Assets.car"
cp "$OUT/AppIcon.icns" "$PKG/AppIcon.icns"
rm -rf "$OUT"
echo "icon compiled: packaging/Assets.car + packaging/AppIcon.icns"
