#!/usr/bin/env bash
# Builds a universal (Apple silicon + Intel) Release of Bezl and packages it as a drag-to-install DMG.
#
#   scripts/make-dmg.sh            -> build/Bezl-<version>.dmg
#
# The app is ad-hoc signed ("-") on purpose: a personal Apple Development certificate would embed
# its owner's name and email in the signature. Without a paid Developer ID + notarization, macOS
# warns on first launch; see README "Install" for the one-time workaround.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen" >&2; exit 1; }
xcodegen generate >/dev/null

VERSION=$(awk '/MARKETING_VERSION:/ {print $2; exit}' project.yml)
DERIVED=build/DerivedData
APP="$DERIVED/Build/Products/Release/Bezl.app"
DMG="build/Bezl-$VERSION.dmg"

echo "==> Building Bezl $VERSION (Release, universal, ad-hoc signed)"
xcodebuild -project Bezl.xcodeproj -scheme Bezl -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  build | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
[ -d "$APP" ] || { echo "Build failed" >&2; exit 1; }

echo "==> Stripping debug symbols"
# The symbol table records absolute build paths (e.g. the builder's home folder). Strip it, then
# re-sign ad-hoc with the same entitlements and hardened runtime.
strip -S -x "$APP/Contents/MacOS/Bezl"
codesign --force --sign - --options runtime --entitlements App/Bezl.entitlements "$APP"
if grep -aq "$HOME" "$APP/Contents/MacOS/Bezl"; then
  echo "Build still contains local paths from $HOME; refusing to package." >&2
  exit 1
fi

echo "==> Verifying"
codesign --verify --deep --strict "$APP"
echo "    architectures: $(lipo -archs "$APP/Contents/MacOS/Bezl")"
echo "    signature:     $(codesign -dv "$APP" 2>&1 | grep -E '^Signature' || true)"

echo "==> Packaging $DMG"
STAGE=build/dmg-stage
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Bezl $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> Done: $DMG ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG"
