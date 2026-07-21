#!/usr/bin/env bash
# Builds MacTerminal.app (Release) signed with the stable "MacTerminal Dev"
# identity, then packages MacTerminal-v<version>.dmg with an /Applications
# symlink for drag-and-drop install.
#
# The stable identity is the whole point: macOS TCC ties 전체 디스크 접근 권한
# (and 손쉬운 사용 / 폴더 접근 / 자동화) to bundle-id + code-signing certificate.
# Ad-hoc signing changes the signature on every build, so each update looked
# like a brand-new app and the user had to re-grant permissions. With one
# long-lived cert the grant is given once and survives every future install.
#
# First time on a machine:  scripts/make-signing-cert.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="MacTerminal"
SIGN_IDENTITY="MacTerminal Dev"
DERIVED="$ROOT/build/ReleaseDD"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    SIGN_ARG="$SIGN_IDENTITY"
else
    echo "⚠ '$SIGN_IDENTITY' identity not found — falling back to ad-hoc."
    echo "  TCC 권한이 업데이트마다 초기화됩니다. scripts/make-signing-cert.sh 를 먼저 실행하세요."
    SIGN_ARG="-"
fi

echo "→ Building $APP_NAME (Release)…"
xcodebuild -project "$ROOT/$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" -configuration Release \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_ARG" \
    CODE_SIGNING_ALLOWED=YES \
    build | tail -5

APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "✗ app not found at $APP"; exit 1; }

# Re-sign the whole bundle so nested content picks up the same identity even if
# an incremental build left a stale signature behind.
echo "→ Signing with: $SIGN_ARG"
codesign --force --deep --sign "$SIGN_ARG" \
    --entitlements "$ROOT/$APP_NAME/$APP_NAME.entitlements" "$APP"
codesign --verify --verbose=1 "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/$APP_NAME-v$VERSION.dmg"

echo "→ Packaging $DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag-and-drop install target
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "✓ $APP"
echo "✓ $DMG"
echo
echo "설치 후 최초 1회만: 시스템 설정 → 개인정보 보호 및 보안 → 전체 디스크 접근 권한에서"
echo "$APP_NAME 을 추가/허용하세요. 이후 업데이트에서는 다시 설정할 필요가 없습니다."
