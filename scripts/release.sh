#!/usr/bin/env bash
# Cuts a Bezl release end to end:
#   scripts/release.sh 0.2.0            bump version, test, build DMG, commit, tag, push, publish
#   scripts/release.sh 0.2.0 --dry-run  everything except committing, pushing and publishing
#
# Signs with Developer ID + notarizes automatically when BEZL_SIGN_IDENTITY and BEZL_NOTARY_PROFILE
# are set (see scripts/make-dmg.sh); otherwise publishes an ad-hoc signed build.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
DRY_RUN=false
[ "${2:-}" = "--dry-run" ] && DRY_RUN=true
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Usage: scripts/release.sh X.Y.Z [--dry-run]" >&2; exit 1; }
TAG="v$VERSION"

git fetch -q --tags origin   # release tags are created on GitHub; make sure we know about them
for tool in gh xcodegen; do command -v $tool >/dev/null || { echo "Missing $tool (brew install $tool)" >&2; exit 1; }; done
if ! $DRY_RUN; then
  [ "$(git branch --show-current)" = "main" ] || { echo "Release from main." >&2; exit 1; }
  [ -z "$(git status --porcelain)" ] || { echo "Working tree not clean; commit or stash first." >&2; exit 1; }
  git rev-parse "$TAG" >/dev/null 2>&1 && { echo "Tag $TAG already exists." >&2; exit 1; }
  git fetch -q origin main
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "main is not in sync with origin." >&2; exit 1; }
fi

CURRENT=$(awk '/MARKETING_VERSION:/ {print $2; exit}' project.yml)
BUILD=$(awk '/CURRENT_PROJECT_VERSION:/ {print $2; exit}' project.yml)
echo "==> $CURRENT (build $BUILD) -> $VERSION (build $((BUILD + 1)))"
if ! $DRY_RUN; then
  sed -i '' "s/MARKETING_VERSION: $CURRENT/MARKETING_VERSION: $VERSION/" project.yml
  sed -i '' "s/CURRENT_PROJECT_VERSION: $BUILD/CURRENT_PROJECT_VERSION: $((BUILD + 1))/" project.yml
fi

echo "==> Tests"
swift test --package-path Packages/BezlCore 2>&1 | grep -E "✘|Test run" | tail -3
swift test --package-path Packages/BezlCore >/dev/null 2>&1 || { echo "Tests failed." >&2; exit 1; }

scripts/make-dmg.sh
BUILT=$(awk '/MARKETING_VERSION:/ {print $2; exit}' project.yml)
DMG="build/Bezl-$BUILT.dmg"
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)

if [ -n "${BEZL_NOTARY_PROFILE:-}" ]; then
  INSTALL_NOTE="Open the DMG and drag Bezl into Applications."
else
  INSTALL_NOTE="Open the DMG and drag Bezl into Applications. Bezl isn't notarized yet, so on first launch go to **System Settings → Privacy & Security → Open Anyway** (or run \`xattr -dr com.apple.quarantine /Applications/Bezl.app\`)."
fi
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
CHANGES=$(git log --pretty='- %s' ${LAST_TAG:+$LAST_TAG..HEAD} | grep -v '^- Release v' || true)
NOTES="### Changes
${CHANGES:-- Maintenance release}

### Install
$INSTALL_NOTE

Requires macOS 14.2 or later (Apple silicon or Intel).

SHA-256: \`$SHA\`"

if $DRY_RUN; then
  echo "==> Dry run: would commit, tag $TAG, push, and publish $DMG with these notes:"
  echo "$NOTES"
  exit 0
fi

echo "==> Committing and tagging $TAG"
git add project.yml
git commit -q -m "Release $TAG"
git tag -a "$TAG" -m "Bezl $VERSION"
git push -q origin main "$TAG"

echo "==> Publishing GitHub release"
gh release create "$TAG" "$DMG" --title "Bezl $VERSION" --notes "$NOTES"
echo "==> Released: $(gh release view "$TAG" --json url --jq .url)"
