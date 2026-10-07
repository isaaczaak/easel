#!/bin/bash
# Create a self-signed code-signing certificate in your login keychain, so
# every local build of OpenGallery has the same signature. macOS ties
# privacy permissions (Input Monitoring, for Force Click) to the signature;
# with the default ad-hoc signing each rebuild needs them granted again.
#
# Run once per Mac:  scripts/make_signing_cert.sh
# macOS asks for your password to trust the certificate for code signing.
# scripts/bundle.sh uses it automatically when it exists.
set -euo pipefail

NAME="OpenGallery Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "\"$NAME\" already exists."
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass="$(openssl rand -hex 16)"

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null

# Legacy encryption: the macOS keychain can't read OpenSSL 3's defaults.
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$NAME" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -passout "pass:$pass" -out "$work/identity.p12"

security import "$work/identity.p12" -k "$KEYCHAIN" -P "$pass" -T /usr/bin/codesign >/dev/null
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$work/cert.pem"

echo "Created \"$NAME\". Rebuild with scripts/bundle.sh --install."
