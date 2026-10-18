#!/bin/zsh
# Creates (once) a local, self-signed code-signing identity "MacCleaner Local Signing" in your
# login keychain. build.sh signs with it, so macOS keeps Full Disk Access across updates
# (an ad-hoc signature changes on every build and macOS forgets the permission).
# The key is made on your Mac, never leaves it, is not exportable, and is only usable by codesign.
# It is not added to any trust settings, so it can't vouch for anything except your own build.
set -eu
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
NAME="MacCleaner Local Signing"
KC="$HOME/Library/Keychains/login.keychain-db"

security find-certificate -c "$NAME" "$KC" >/dev/null 2>&1 && exit 0

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
chmod 700 "$T"
cat > "$T/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 -config "$T/cert.cnf" \
  -keyout "$T/key.pem" -out "$T/cert.pem" 2>/dev/null
PASS=$(openssl rand -hex 24)
openssl pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -name "$NAME" \
  -passout "pass:$PASS" -out "$T/id.p12"
# -x: private key not extractable; -T: only codesign may use it without asking.
security import "$T/id.p12" -k "$KC" -f pkcs12 -P "$PASS" -x -T /usr/bin/codesign >/dev/null
echo "Created the local signing identity \"$NAME\" in your login keychain."
