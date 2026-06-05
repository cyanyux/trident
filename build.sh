#!/usr/bin/env bash
#
# Build Trident. Generates the Xcode project from project.yml (XcodeGen), then
# builds the app, linking the private MultitouchSupport framework.
#
# Usage: ./build.sh [Debug|Release]   (default: Release)

set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-Release}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found. Install it with: brew install xcodegen" >&2
  exit 1
fi

echo "==> Generating Trident.xcodeproj"
xcodegen generate

echo "==> Building Trident ($CONFIG)"
xcodebuild \
  -project Trident.xcodeproj \
  -scheme Trident \
  -configuration "$CONFIG" \
  -derivedDataPath build \
  OTHER_LDFLAGS="-F/System/Library/PrivateFrameworks -framework MultitouchSupport" \
  FRAMEWORK_SEARCH_PATHS="/System/Library/PrivateFrameworks" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  build

APP="build/Build/Products/$CONFIG/Trident.app"

# Re-sign with the stable self-signed identity if present, so the Accessibility
# grant survives rebuilds (its code requirement is keyed to the cert, not the
# binary hash). Falls back to the ad-hoc signature otherwise.
IDENTITY="Trident Dev"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "==> Re-signing with '$IDENTITY' (stable identity — Accessibility grant persists)"
  codesign --force --timestamp=none --identifier com.trident.Trident \
    --entitlements Sources/TridentApp/Trident.entitlements \
    --sign "$IDENTITY" "$APP"
else
  echo "==> '$IDENTITY' not found — using ad-hoc signature."
  echo "    Run ./scripts/setup-signing.sh once so the Accessibility grant survives rebuilds."
fi

echo "==> Built: $APP"
echo "    Launch it, then grant Accessibility in System Settings > Privacy & Security > Accessibility."
