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
  # Sign INSIDE-OUT. Sparkle's helpers (the Autoupdate tool, Updater.app, and the
  # sandboxed Downloader/Installer XPC services) must be signed by the SAME identity
  # as the app — Sparkle refuses to launch its updater otherwise, and xcodebuild only
  # ad-hoc-signed them. But they must KEEP their own bundle identifiers and
  # entitlements (the XPC services are deliberately sandboxed with org.sparkle-project.*
  # identifiers). A single `--deep --identifier com.trident.Trident --entitlements …`
  # would force the APP's identifier and app-sandbox=false onto every nested binary —
  # the documented codesign footgun — which can break the updater while
  # `--verify --deep --strict` (integrity only) still passes, shipping it silently.
  #
  # So: re-sign the embedded Sparkle.framework first, swapping in our identity but
  # PRESERVING each nested component's identifier/entitlements/flags; then sign the app
  # shell with its own identifier + entitlements and NO --deep (the outer signature
  # still seals the freshly-signed nested code).
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
  if [ -d "$SPARKLE" ]; then
    echo "    re-signing embedded Sparkle (preserving its identifiers/entitlements)"
    codesign --force --timestamp=none \
      --preserve-metadata=identifier,entitlements,flags \
      --deep --sign "$IDENTITY" "$SPARKLE"
  fi
  codesign --force --timestamp=none --identifier com.trident.Trident \
    --entitlements Sources/TridentApp/Trident.entitlements \
    --sign "$IDENTITY" "$APP"
  # Gate the build on verification. A bare `verify && echo` would NOT abort under
  # `set -e` (the left side of an && list is exempt), so a mis-signed Sparkle helper
  # would ship silently and the updater would refuse to launch on users' Macs.
  if ! codesign --verify --deep --strict "$APP"; then
    echo "error: signature verification failed — embedded Sparkle helpers may be mis-signed; aborting." >&2
    exit 1
  fi
  echo "    signature OK (incl. Sparkle)"
else
  echo "==> '$IDENTITY' not found — using ad-hoc signature."
  echo "    Run ./scripts/setup-signing.sh once so the Accessibility grant survives rebuilds."
fi

echo "==> Built: $APP"
echo "    Launch it, then grant Accessibility in System Settings > Privacy & Security > Accessibility."
