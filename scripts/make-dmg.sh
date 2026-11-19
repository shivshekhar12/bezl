#!/usr/bin/env bash
# Builds a universal (Apple silicon + Intel) Release of Bezl and packages it as a drag-to-install DMG.
#
#   scripts/make-dmg.sh            -> build/Bezl-<version>.dmg
#
# Signing modes:
#   * Default: ad-hoc ("-"). Never a personal Apple Development certificate, which would embed its
#     owner's name and email. macOS then warns on first launch (README "Install" has the workaround).
#   * Developer ID + notarization, when both are set (see CLAUDE.md "Release process"):
#       BEZL_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#       BEZL_NOTARY_PROFILE=bezl     # created once with `xcrun notarytool store-credentials bezl`
#     Users then open Bezl with no warning.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen" >&2; exit 1; }
xcodegen generate >/dev/null

VERSION=$(awk '/MARKETING_VERSION:/ {print $2; exit}' project.yml)
DERIVED=build/DerivedData
APP="$DERIVED/Build/Products/Release/Bezl.app"
DMG="build/Bezl-$VERSION.dmg"
SIGN_ID="${BEZL_SIGN_IDENTITY:-}"
NOTARY="${BEZL_NOTARY_PROFILE:-}"

if [ -n "$SIGN_ID" ]; then
  security find-identity -v -p codesigning | grep -qF "$SIGN_ID" \
    || { echo "Signing identity not found in the keychain: $SIGN_ID" >&2; exit 1; }
  [ -n "$NOTARY" ] || { echo "BEZL_SIGN_IDENTITY is set but BEZL_NOTARY_PROFILE is not; refusing a signed-but-unnotarized build." >&2; exit 1; }
  MODE="Developer ID + notarized"
else
  MODE="ad-hoc signed"
fi

echo "==> Building Bezl $VERSION (Release, universal, $MODE)"
xcodebuild -project Bezl.xcodeproj -scheme Bezl -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  build | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
[ -d "$APP" ] || { echo "Build failed" >&2; exit 1; }

echo "==> Stripping debug symbols"
# The symbol table records absolute build paths (e.g. the builder's home folder).
strip -S -x "$APP/Contents/MacOS/Bezl" 2>/dev/null
if grep -aq "$HOME" "$APP/Contents/MacOS/Bezl"; then
  echo "Build still contains local paths from $HOME; refusing to package." >&2
  exit 1
fi

echo "==> Signing"
if [ -n "$SIGN_ID" ]; then
  # Notarization requires the hardened runtime and a secure timestamp.
  codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
    --entitlements App/Bezl.entitlements "$APP"
else
  codesign --force --sign - --options runtime --entitlements App/Bezl.entitlements "$APP"
fi

echo "==> Verifying"
codesign --verify --deep --strict "$APP"
echo "    architectures: $(lipo -archs "$APP/Contents/MacOS/Bezl")"
echo "    signature:     $(codesign -dv "$APP" 2>&1 | grep -E '^(Signature|Authority)' | head -1 || true)"

echo "==> Packaging $DMG"
STAGE=build/dmg-stage
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Bezl $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [ -n "$SIGN_ID" ]; then
  echo "==> Notarizing (Apple usually takes 1–5 minutes)"
  codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi

echo "==> Done: $DMG ($(du -h "$DMG" | cut -f1), $MODE)"
shasum -a 256 "$DMG"
