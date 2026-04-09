#!/usr/bin/env bash
# Builds an UNSIGNED DMG containing Bitscope.app. Intended for local
# distribution and testing — not for notarization.
# Usage: ./build-dmg.sh [Debug|Release]  (default: Release)

set -euo pipefail

CONFIG=${1:-Release}
ROOT=$(cd "$(dirname "$0")" && pwd)
APP="$ROOT/build/Bitscope.app"
DMG_DIR="$ROOT/build/dmg"
DMG_OUT="$ROOT/build/Bitscope.dmg"
VOLNAME="Bitscope"

# 1. Ensure the app bundle exists / is up to date.
"$ROOT/build-app.sh" "$CONFIG"

if [ ! -d "$APP" ]; then
    echo "error: expected app bundle at $APP" >&2
    exit 1
fi

# 2. Stage a clean directory containing the app + an /Applications symlink
# so the user can drag-install directly from the mounted DMG.
echo "==> Staging DMG contents"
rm -rf "$DMG_DIR" "$DMG_OUT"
mkdir -p "$DMG_DIR"
cp -R "$APP" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"

# 3. Create the DMG via hdiutil. No signing, no notarization.
echo "==> Creating DMG"
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$DMG_DIR" \
    -ov \
    -format UDZO \
    "$DMG_OUT" >/dev/null

rm -rf "$DMG_DIR"

echo ""
echo "Built: $DMG_OUT"
echo "Note: this DMG is unsigned. On first launch, right-click Bitscope.app"
echo "      and choose Open to bypass Gatekeeper."
