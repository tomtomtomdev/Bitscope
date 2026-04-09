#!/usr/bin/env bash
# Builds Bitscope.app using xcodebuild and stages it under ./build.
# Usage: ./build-app.sh [Debug|Release]  (default: Release)

set -euo pipefail

CONFIG=${1:-Release}
ROOT=$(cd "$(dirname "$0")" && pwd)
DERIVED="$ROOT/build/DerivedData"
OUT="$ROOT/build/Bitscope.app"

# Regenerate the Xcode project if XcodeGen is available and project.yml is
# newer than the xcodeproj. Safe to skip — the xcodeproj is committed.
if command -v xcodegen >/dev/null 2>&1; then
    PBX="$ROOT/Bitscope.xcodeproj/project.pbxproj"
    NEEDS_REGEN=0
    if [ ! -f "$PBX" ]; then
        NEEDS_REGEN=1
    elif [ "$ROOT/project.yml" -nt "$PBX" ]; then
        NEEDS_REGEN=1
    else
        # Regenerate if any source file is newer than the pbxproj — catches
        # newly added files that XcodeGen picks up via glob.
        if [ -n "$(find "$ROOT/Sources" -name '*.swift' -newer "$PBX" -print -quit)" ]; then
            NEEDS_REGEN=1
        fi
    fi
    if [ "$NEEDS_REGEN" = "1" ]; then
        echo "==> Regenerating Xcode project"
        (cd "$ROOT" && xcodegen generate >/dev/null)
    fi
fi

echo "==> xcodebuild ($CONFIG)"
xcodebuild \
    -project "$ROOT/Bitscope.xcodeproj" \
    -scheme Bitscope \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" \
    build \
    | xcbeautify 2>/dev/null || \
xcodebuild \
    -project "$ROOT/Bitscope.xcodeproj" \
    -scheme Bitscope \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" \
    build >/dev/null

BUILT_APP="$DERIVED/Build/Products/$CONFIG/Bitscope.app"
if [ ! -d "$BUILT_APP" ]; then
    echo "error: expected build output at $BUILT_APP" >&2
    exit 1
fi

echo "==> Copying to $OUT"
rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
cp -R "$BUILT_APP" "$OUT"

echo ""
echo "Built: $OUT"
echo "Run with: open \"$OUT\""
