#!/bin/bash
# Creates a self-signed code-signing identity so macOS stops forgetting Visprflow's
# permissions every time the app is rebuilt.
#
# Why this is needed: an ad-hoc signed app ("codesign --sign -") has no stable identity.
# macOS records a permission grant against the exact bytes of the binary, so every rebuild
# looks like a brand new application and Microphone, Accessibility and the rest are wiped.
# A self-signed certificate gives the app a fixed identity, and grants then survive rebuilds
# for good.
#
# Run once:  ./scripts/create-signing-identity.sh
# Then:      make install
#
# You will be asked for your login password once, by macOS, to add the certificate to your
# own login keychain. Nothing is installed system-wide and nothing leaves this machine.

set -euo pipefail

NAME="Visprflow Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "A certificate named '$NAME' already exists."
  echo "Set CODE_SIGN_IDENTITY to \"$NAME\" in project.yml, then run: make install"
  exit 0
fi

echo "Creating a self-signed code-signing certificate called '$NAME'…"

# A certificate is only usable for signing code if it carries the code-signing extended key
# usage, which is what this extension section adds.
cat > "$WORK/openssl.cnf" <<'CONF'
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[ dn ]
CN = Visprflow Dev

[ ext ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
CONF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 3650 -config "$WORK/openssl.cnf" 2>/dev/null

openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout pass:visprflow -name "$NAME" 2>/dev/null

echo "Adding it to your login keychain (macOS will ask for your password)…"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P visprflow \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# Let codesign use the key without prompting on every build.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || \
  echo "  (could not set the partition list; codesign may ask for your password on each build)"

echo "Trusting it for code signing…"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" 2>/dev/null || \
  echo "  (trust settings were not applied; if signing fails, trust '$NAME' for Code Signing in Keychain Access)"

echo
echo "Done. Now set this in project.yml under settings.base:"
echo "    CODE_SIGN_IDENTITY: \"$NAME\""
echo "then run: make install"
echo
echo "You will grant the permissions once more after that first signed build, and then they"
echo "will stick across every rebuild from now on."
