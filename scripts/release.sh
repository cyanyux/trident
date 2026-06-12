#!/usr/bin/env bash
#
# Cut a Trident release and publish it for auto-update.
#
#   build → sign → package (DMG for humans + ZIP for Sparkle) → EdDSA-sign the
#   update → regenerate appcast.xml → push → create the GitHub Release.
#
# Usage:  ./scripts/release.sh <version>        e.g.  ./scripts/release.sh 1.1
#
# Prereqs (one-time):
#   • ./scripts/setup-signing.sh        (stable "Trident Dev" code-sign identity)
#   • ./scripts/setup-sparkle-keys.sh   (EdDSA update-signing key + public key in Info.plist)
#   • gh auth login                     (GitHub CLI authenticated)
#   • the repo must be PUBLIC so the appcast + assets are fetchable without auth.

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
# shellcheck source=scripts/lib-sparkle.sh
source scripts/lib-sparkle.sh

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "usage: $0 <version>   (e.g. 1.1)" >&2
  exit 1
fi

REPO="cyanyux/trident"
INFO="Sources/TridentApp/Info.plist"
TAG="v$VERSION"
APP="build/Build/Products/Release/Trident.app"
DIST="dist"
UPDATES="$DIST/updates"   # only the ZIP lives here — what generate_appcast scans

# --- preflight -------------------------------------------------------------
command -v gh >/dev/null 2>&1 || { echo "error: gh (GitHub CLI) not installed" >&2; exit 1; }
command -v create-dmg >/dev/null 2>&1 || { echo "error: create-dmg not installed — brew install create-dmg" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: run 'gh auth login' first" >&2; exit 1; }
if [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree is not clean — commit or stash before releasing" >&2
  exit 1
fi
# Exact commit to roll back to if the publish phase fails partway. Safe to hard-reset
# onto: the clean-tree check above guarantees there's no unrelated work to lose.
START_REF="$(git rev-parse HEAD)"
PLACEHOLDER="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO" 2>/dev/null || true)"
if [ "$PLACEHOLDER" = "__SPARKLE_PUBLIC_KEY__" ] || [ -z "$PLACEHOLDER" ]; then
  echo "error: SUPublicEDKey not set — run ./scripts/setup-sparkle-keys.sh first" >&2
  exit 1
fi
ensure_sparkle_tools "$ROOT"

# --- version bump (marketing version from arg; build number auto-increments) ---
OLD_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")"
NEW_BUILD=$((OLD_BUILD + 1))
# If anything between here and the commit fails (e.g. the build), restore Info.plist
# so a failed release doesn't leave a half-bumped version dirtying the tree — which
# the clean-tree preflight above would then block on the next attempt. Cleared once
# the bump is safely committed.
trap 'git checkout -- "$INFO" 2>/dev/null || true' ERR
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$INFO"
echo "==> Releasing Trident $VERSION (build $NEW_BUILD)"

# --- build (re-signs with the stable identity, incl. embedded Sparkle) ------
./build.sh Release

# --- package ---------------------------------------------------------------
rm -rf "$DIST"
mkdir -p "$UPDATES"
ZIP="$UPDATES/Trident-$VERSION.zip"
DMG="$DIST/Trident-$VERSION.dmg"

# ZIP: what Sparkle downloads to self-update. ditto preserves the bundle + signature.
ditto -c -k --keepParent "$APP" "$ZIP"

# DMG: friendly first-time install — a designed window (branded background,
# drag-to-Applications arrow, fixed layout) built with create-dmg. The icon
# coordinates here must match the arrow baked into assets/dmg-background.tiff
# (regenerate via scripts/render-dmg-background.sh if you move things).
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/Trident.app"
create-dmg \
  --volname "Trident" \
  --volicon "$APP/Contents/Resources/AppIcon.icns" \
  --background assets/dmg-background.tiff \
  --window-pos 200 160 \
  --window-size 660 400 \
  --icon-size 128 \
  --text-size 13 \
  --icon "Trident.app" 165 195 \
  --hide-extension "Trident.app" \
  --app-drop-link 495 195 \
  "$DMG" "$STAGE"
rm -rf "$STAGE"

# --- appcast ---------------------------------------------------------------
# generate_appcast reads the version from the app inside the ZIP, signs the ZIP
# with the keychain private key, and writes the feed. Enclosure URLs point at the
# GitHub Release asset (URL is predictable from the tag + filename).
"$SPARKLE_BIN/generate_appcast" "$UPDATES" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --link "https://github.com/$REPO" \
  -o appcast.xml
echo "==> appcast.xml regenerated"

# --- publish ---------------------------------------------------------------
git add "$INFO" appcast.xml
git commit -m "Release $VERSION"
git tag "$TAG"

# The publish phase touches REMOTE state in three network steps, any of which can
# fail (auth lapse, non-fast-forward, dropped connection). A failure between them
# leaves a partial release: a dangling remote tag, or a public GitHub Release whose
# new appcast (served from main) never went live — so clients never see the update,
# and a naive re-run trips the clean-tree / existing-tag preflights. This trap rolls
# the remote AND local state back to exactly where we started, so a re-run is clean.
publish_failed() {
  local rc=$?
  echo >&2
  echo "error: release publish failed (exit $rc) — rolling back to the pre-release state." >&2
  gh release delete "$TAG" --repo "$REPO" --yes 2>/dev/null || true  # remove a created Release
  git push origin ":refs/tags/$TAG" 2>/dev/null || true             # remove a pushed tag
  git tag -d "$TAG" 2>/dev/null || true                             # remove the local tag
  git reset --hard "$START_REF" 2>/dev/null || true                 # undo the release commit + bump
  echo "Rolled back. Fix the cause (gh auth / network / 'git pull' for fast-forward)," >&2
  echo "then re-run: ./scripts/release.sh $VERSION" >&2
  exit 1
}
trap publish_failed ERR   # supersedes the Info.plist-restore trap; the bump is committed now

# Publish in an order that never advertises a download before it exists. The live
# feed is SUFeedURL → raw.githubusercontent.com/.../main/appcast.xml, i.e. served
# from the main branch — so pushing main is what makes the new version visible to
# clients. Therefore: push only the TAG first (so the Release can attach to it),
# upload the assets, and push main LAST. Pushing main first (the old order) would
# expose an appcast whose enclosure URLs 404 until the assets finished uploading.
git push origin "$TAG"
gh release create "$TAG" "$DMG" "$ZIP" \
  --repo "$REPO" \
  --title "Trident $VERSION" \
  --generate-notes
git push origin HEAD
trap - ERR   # fully published — nothing left to roll back

echo
echo "==> Released $TAG."
echo "    Existing installs auto-update within a day, or now via 'Check for Updates…'."
echo "    New users download: https://github.com/$REPO/releases/latest"
