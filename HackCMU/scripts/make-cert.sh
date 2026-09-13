#!/bin/bash
# Creates a self-signed code-signing identity so TCC grants survive rebuilds.
#
# WHY: TCC stores a code requirement per (service, client). Under ad-hoc
# signing that requirement is `cdhash H"..."` - the literal hash of the binary -
# so every recompile invalidates it. The failure mode is vicious: the checkbox
# in System Settings stays CHECKED while AXIsProcessTrusted() returns false.
# A stable Subject CN makes the requirement name-based instead.
set -euo pipefail

CN="${LOOPY_SIGN_ID:-Handoff Dev}"
KC="$HOME/Library/Keychains/login.keychain-db"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

if /usr/bin/security find-identity -v -p codesigning 2>/dev/null | grep -q "$CN"; then
  echo "==> identity '$CN' already exists:"
  /usr/bin/security find-identity -v -p codesigning | grep "$CN"
  exit 0
fi

echo "==> generating self-signed code-signing cert '$CN'"
cat > "$DIR/ext.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $CN
O  = HackCMU
[v3]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$DIR/key.pem" -out "$DIR/cert.pem" \
  -config "$DIR/ext.cnf" -extensions v3 2>/dev/null

# -legacy / explicit PBE algorithms are REQUIRED: OpenSSL 3 defaults to
# AES-256-CBC + PBKDF2, which Apple's Security framework cannot read. It fails
# as "MAC verification failed (wrong password?)", which is a misleading error.
openssl pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" \
  -name "$CN" -out "$DIR/id.p12" -passout pass:handoff \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null \
  || openssl pkcs12 -export -legacy -inkey "$DIR/key.pem" -in "$DIR/cert.pem" \
       -name "$CN" -out "$DIR/id.p12" -passout pass:handoff 2>/dev/null

echo "==> importing into login keychain (-T pre-authorizes codesign)"
/usr/bin/security import "$DIR/id.p12" -k "$KC" -P handoff \
  -T /usr/bin/codesign -T /usr/bin/security

echo "==> marking trusted for code signing"
# REQUIRED, not cosmetic: without this, find-identity -v -p codesigning
# reports "0 valid identities" and codesign refuses to use the cert.
/usr/bin/security add-trusted-cert -r trustRoot -p codeSign -k "$KC" "$DIR/cert.pem"

# NB: `security set-key-partition-list` is deliberately NOT run here. It
# prompts for the login keychain password on stdin and hangs forever in a
# non-interactive shell. The -T flags on `import` above already pre-authorize
# codesign, so it is unnecessary. If you ever DO get a repeated
# "codesign wants to sign using key ..." dialog, click Always Allow once.

echo
if /usr/bin/security find-identity -v -p codesigning | grep -q "$CN"; then
  echo "==> SUCCESS:"
  /usr/bin/security find-identity -v -p codesigning | grep "$CN"
else
  cat <<'FALLBACK'
==> FAILED to produce a valid identity.

Do it by hand instead - it takes two minutes and is more reliable:
  1. Keychain Access > Certificate Assistant > Create a Certificate...
  2. Name: Handoff Dev
  3. Identity Type: Self Signed Root
  4. Certificate Type: Code Signing
  5. Accept the defaults through to Create.
  6. Find "Handoff Dev" under login > My Certificates, double-click it,
     open Trust, set "When using this certificate" to Always Trust, close.
     ^^^ Skipping step 6 is the #1 failure: the identity exists but
         `security find-identity -v -p codesigning` will not list it.
  7. Verify: security find-identity -v -p codesigning
FALLBACK
  exit 1
fi
