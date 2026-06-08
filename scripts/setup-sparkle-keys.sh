#!/usr/bin/env bash
#
# One-time setup for Sparkle auto-update signing.
#
# Generates an EdDSA (Ed25519) key pair, stores the PRIVATE key in your login
# keychain (account "ed25519"), and writes the PUBLIC key into the app's
# Info.plist (SUPublicEDKey). The app ships the public key; releases are signed
# with the private key. Sparkle accepts an update only if its signature verifies
# against the embedded public key.
#
# Idempotent: re-running just re-reads the existing key and refreshes Info.plist.
#
# ⚠️  Back up the private key. If you lose it, you can no longer ship updates that
#     existing installs will trust — export it with:
#         .sparkle/bin/generate_keys -x sparkle_private_key.pem
#     and store that file somewhere safe (NOT in the repo).

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
# shellcheck source=scripts/lib-sparkle.sh
source scripts/lib-sparkle.sh
ensure_sparkle_tools "$ROOT"

INFO="Sources/TridentApp/Info.plist"

# Create the key pair if none exists yet (no-op if one is already in the keychain).
"$SPARKLE_BIN/generate_keys" >/dev/null 2>&1 || true

# Read back the public key (44-char base64, ends in '=').
PUBKEY="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null | grep -oE '[A-Za-z0-9+/]{43}=' | head -1)"
if [ -z "$PUBKEY" ]; then
  echo "error: could not read the Sparkle public key from the keychain" >&2
  exit 1
fi

# Write it into Info.plist, whether the placeholder or a prior value is there.
if /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$INFO" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $PUBKEY" "$INFO"
else
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $PUBKEY" "$INFO"
fi

echo "==> Sparkle public key written to $INFO"
echo "    SUPublicEDKey = $PUBKEY"
echo
echo "    The private key is in your login keychain (account: ed25519)."
echo "    Back it up now:  .sparkle/bin/generate_keys -x sparkle_private_key.pem"
echo "    Keep that file safe and OUT of git."
