#!/bin/bash
# Builds build/MotionRecord.app (release, ad-hoc signed). Usage: scripts/build_app.sh [--run]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="MotionRecord"
BUNDLE_ID="com.zena.MotionRecord"
APP="$ROOT/build/$APP_NAME.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # "-" = ad-hoc

RUN=0
for arg in "$@"; do
  [[ "$arg" == "--run" ]] && RUN=1
done

echo "==> swift build -c release"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# SwiftPM resource bundles, if any
for b in "$BIN_DIR"/*.bundle; do
  [[ -e "$b" ]] && cp -R "$b" "$APP/Contents/Resources/"
done
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
[[ -d "$ROOT/Resources/Sounds" ]] && cp -R "$ROOT/Resources/Sounds" "$APP/Contents/Resources/Sounds"

echo "==> codesign (identity: $SIGN_IDENTITY)"
# The explicit designated requirement is based on the bundle identifier only, so the Screen
# Recording (TCC) permission survives rebuilds even with an ad-hoc signature.
codesign --force --deep --sign "$SIGN_IDENTITY" \
  --identifier "$BUNDLE_ID" \
  --requirements "=designated => identifier \"$BUNDLE_ID\"" \
  "$APP"
codesign --verify --verbose=1 "$APP" || true

echo "==> done: $APP"
if [[ $RUN -eq 1 ]]; then
  open "$APP"
fi
