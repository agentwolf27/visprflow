#!/bin/bash
# Creates a self-signed code-signing identity so macOS stops forgetting Visprflow's
# permissions every time the app is rebuilt.
#
# Why this is needed: an ad-hoc signed app ("codesign --sign -") has no stable identity.
# macOS records a permission grant against the exact bytes of the binary, so every rebuild
# looks like a brand new application and Microphone, Accessibility and the rest are wiped.
# A self-signed certificate gives the app a fixed identity, and the grants then survive.
#
# Run once:  ./scripts/create-signing-identity.sh
# Then:      make install
#
# Everything stays in your own login keychain. Nothing is installed system-wide and nothing
# leaves this machine.

set -euo pipefail

NAME="Visprflow Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# macOS's own OpenSSL, deliberately not whatever is first on PATH. OpenSSL 3 writes PKCS#12
# files with a SHA-256 MAC that the macOS Security framework cannot read, and the import
# fails with "MAC verification failed (wrong password?)" even though the password is right.
# LibreSSL at this path produces a file macOS accepts.
OPENSSL=/usr/bin/openssl

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "'$NAME' already exists and is valid for code signing."
  echo "Set CODE_SIGN_IDENTITY to \"$NAME\" in project.yml, then run: make install"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Creating a self-signed code-signing certificate called '$NAME'…"

# A certificate is only usable for signing code if it carries the code-signing extended key
# usage, which is what this extension section adds.
cat > "$WORK/openssl.cnf" <<CONF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[ dn ]
CN = $NAME

[ ext ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
CONF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 3650 -config "$WORK/openssl.cnf" 2>/dev/null

"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout pass:visprflow -name "$NAME" 2>/dev/null

echo "Adding it to your login keychain…"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P visprflow \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# Let codesign use the private key without asking on every build.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || \
  echo "  (could not set the partition list; codesign may ask for your password on each build)"

echo "Trusting it for code signing…"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" >/dev/null

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo
  echo "Done. '$NAME' is ready to sign with."
  echo "Set this in project.yml under settings.base:"
  echo "    CODE_SIGN_IDENTITY: \"$NAME\""
  echo "then run: make install"
  echo
  echo "Grant the permissions once more after that first signed build. They will stick from"
  echo "then on, across every rebuild."
else
  echo
  echo "The certificate was created but is not showing as a valid signing identity." >&2
  echo "Open Keychain Access, find '$NAME', and set Trust > Code Signing to 'Always Trust'." >&2
  exit 1
fi
