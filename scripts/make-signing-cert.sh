#!/usr/bin/env bash
# Creates the stable self-signed "MacTerminal Dev" code-signing identity.
#
# Why: macOS TCC (전체 디스크 접근 권한, 손쉬운 사용, 파일/폴더 접근 …) binds a
# grant to the app's bundle id + its code-signing identity. Ad-hoc signatures
# (`codesign -s -`) get a fresh cdhash every build, so every update looks like a
# different app and the user has to re-approve. A single long-lived certificate
# keeps the grant across installs: 승인은 최초 1회, 이후 업데이트는 그대로 유지.
#
# Run once per Mac. Safe to re-run — it no-ops if the identity already exists.
# (Deleting/re-creating the cert WOULD invalidate existing TCC grants.)
set -euo pipefail

IDENTITY="MacTerminal Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✓ '$IDENTITY' identity already exists — nothing to do."
    exit 0
fi

# Homebrew's OpenSSL 3 writes PKCS#12 files whose MAC macOS `security` can't
# verify ("MAC verification failed"). Pin the system LibreSSL, which round-trips.
OPENSSL=/usr/bin/openssl

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[dn]
CN = MacTerminal Dev

[ext]
keyUsage         = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:FALSE
subjectKeyIdentifier = hash
EOF

echo "→ Generating a 10-year self-signed code-signing certificate…"
"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf" 2>/dev/null

"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$IDENTITY" -passout pass:macterminal -out "$TMP/identity.p12" 2>/dev/null

echo "→ Importing into the login keychain (키체인 암호를 물어볼 수 있습니다)…"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P macterminal \
    -T /usr/bin/codesign -T /usr/bin/security -A

echo "→ Trusting it for code signing (사용자 도메인 — 관리자 권한 불필요)…"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✓ '$IDENTITY' is ready. Build with scripts/build.sh."
else
    echo "✗ identity not usable yet — open 키체인 접근 and set '$IDENTITY' →"
    echo "  신뢰 → 코드 서명: 항상 신뢰."
    exit 1
fi
