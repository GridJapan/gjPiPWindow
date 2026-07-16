#!/bin/bash
# Creates the self-signed code signing certificate that build.sh signs with.
#
# Why bother: TCC identifies an ad-hoc signed app by its cdhash, so every
# rebuild looks like a brand new app and Screen Recording / Accessibility have
# to be granted again. Signing with a certificate makes the designated
# requirement `identifier "..." and certificate leaf H"..."` instead, which
# survives rebuilds — grant the permissions once and keep them.
#
# Run once. The private key stays in the login keychain; nothing secret is
# written into the repo.
set -euo pipefail

CERT_NAME="gjPiP Self-Signed"

if security find-identity -v -p codesigning | grep -qF "$CERT_NAME"; then
    echo "already present: $CERT_NAME"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 7300 -nodes \
    -subj "/CN=$CERT_NAME/O=gjPiP" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# macOS cannot read OpenSSL 3's default PKCS#12 algorithms, hence the explicit
# legacy cipher/MAC choices.
openssl pkcs12 -export -out "$TMP/cert.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$CERT_NAME" -passout pass:gjpip \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

# -T scopes private key access to codesign rather than every app.
security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db \
    -P gjpip -T /usr/bin/codesign

# Without code signing trust the cert exists but `find-identity -p codesigning`
# won't offer it.
security add-trusted-cert -r trustRoot -p codeSign \
    -k ~/Library/Keychains/login.keychain-db "$TMP/cert.pem"

security find-identity -v -p codesigning | grep -F "$CERT_NAME"
echo "done — run ./build.sh"
