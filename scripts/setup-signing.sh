#!/usr/bin/env bash
#
# Create a stable self-signed code-signing certificate ("Trident Dev") in your
# login keychain. Signing Trident with a fixed identity gives it a stable code
# requirement, so the macOS Accessibility grant survives rebuilds (an ad-hoc
# signature changes identity every build and loses the grant).
#
# Idempotent: does nothing if the identity already exists. Reversible: delete the
# "Trident Dev" certificate in Keychain Access (or `security delete-certificate
# -c "Trident Dev"`) to undo.

set -euo pipefail

IDENTITY="Trident Dev"

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "'$IDENTITY' already exists — nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = Trident Dev
[ v3 ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

echo "==> Generating self-signed code-signing certificate"
# Use the system LibreSSL explicitly: Homebrew's OpenSSL 3 writes a PKCS12 MAC
# that macOS `security import` can't verify.
SSL=/usr/bin/openssl
"$SSL" req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -config "$TMP/cert.cnf"

"$SSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout pass:trident -name "$IDENTITY"

echo "==> Importing into the login keychain"
# -A lets local tools (codesign) use the key. A one-time keychain dialog may still
# appear on the first build — click "Always Allow".
security import "$TMP/cert.p12" -P trident -A

echo "==> Done. '$IDENTITY' is ready; ./build.sh will sign with it automatically."
