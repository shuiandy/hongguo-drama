#!/usr/bin/env bash
# Creates a self-signed code signing identity "Hongguo Drama Local Signing" in the login
# keychain, so local builds keep the same signature and the keychain "Always Allow" survives
# rebuilds. Run once; build-app.sh picks it up automatically. Remove it later with:
#   security delete-identity -c "Hongguo Drama Local Signing" ~/Library/Keychains/login.keychain-db
set -euo pipefail
NAME="Hongguo Drama Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -qF "\"$NAME\""; then
  echo "already present: $NAME"; exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASS="$(openssl rand -hex 16)"
# -legacy keeps the PKCS#12 readable by `security` on OpenSSL 3; LibreSSL ignores it.
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/id.p12" -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
       -out "$WORK/id.p12" -passout "pass:$PASS"
security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
# Trust the certificate for code signing only (asks for the login password once).
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"
security find-identity -v -p codesigning | grep -F "\"$NAME\"" && echo "created: $NAME"
