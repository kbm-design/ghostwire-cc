#!/usr/bin/env bash
#
# release.sh — cut a Ghostwire release locally (no GitHub Actions / $0).
# Mirrors .github/workflows/release.yml, run on your own Mac.
#
# Usage:   ./release.sh 0.1.1          (or  ./release.sh v0.1.1)
#
# One-time setup:
#   1. Notary profile (like iOS — Apple ID + app-specific password from appleid.apple.com):
#        xcrun notarytool store-credentials "ghostwire-notary" \
#          --apple-id "you@example.com" --team-id "K7A26693A4" --password "abcd-efgh-ijkl-mnop"
#   2. Bump MARKETING_VERSION + CURRENT_PROJECT_VERSION in Xcode (tag must match MARKETING_VERSION,
#      build must be > last published) and commit to main BEFORE running this.
#
set -euo pipefail

# ---- config ---------------------------------------------------------------
SCHEME="Ghostwire"
TEAM_ID="K7A26693A4"                       # Developer ID Application team
SIGNING_IDENTITY="Developer ID Application"
NOTARY_PROFILE="ghostwire-notary"          # keychain profile from store-credentials
REPO="kbm-design/ghostwire-cc"
APPCAST="Updates/appcast.xml"
# ---------------------------------------------------------------------------

VERSION="${1:?usage: ./release.sh <version>  e.g. 0.1.1}"
VERSION="${VERSION#v}"                      # accept v0.1.1 or 0.1.1
TAG="v${VERSION}"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
say() { printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ---- preflight ------------------------------------------------------------
say "Preflight checks"
security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY" \
  || die "No '$SIGNING_IDENTITY' cert in keychain."
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || die "Notary profile '$NOTARY_PROFILE' not found. Run the store-credentials command in this script's header."
gh auth status >/dev/null 2>&1 || die "gh not authenticated (run: gh auth login)."
SPARKLE_BIN="$(find ~/Library/Developer/Xcode/DerivedData -path '*/Sparkle/bin' -type d 2>/dev/null | head -1)"
[ -n "$SPARKLE_BIN" ] || { xcodebuild -resolvePackageDependencies -scheme "$SCHEME" >/dev/null; \
  SPARKLE_BIN="$(find ~/Library/Developer/Xcode/DerivedData -path '*/Sparkle/bin' -type d 2>/dev/null | head -1)"; }
[ -n "$SPARKLE_BIN" ] || die "Sparkle tools not found."

# version must match the built MARKETING_VERSION; build must be > last published
SETTINGS="$(xcodebuild -showBuildSettings -scheme "$SCHEME" 2>/dev/null)"
MKT="$(awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}' <<<"$SETTINGS")"
BUILD="$(awk -F' = ' '/ CURRENT_PROJECT_VERSION /{print $2; exit}' <<<"$SETTINGS")"
[ "$MKT" = "$VERSION" ] || die "Tag $TAG != MARKETING_VERSION $MKT — bump the version in Xcode first."
LAST_BUILD="$(grep -oE '<sparkle:version>[0-9]+' "$APPCAST" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)"
if [ -n "$LAST_BUILD" ] && [ "$BUILD" -le "$LAST_BUILD" ]; then
  die "Build $BUILD must be > last published $LAST_BUILD."
fi
echo "✓ v$VERSION (build $BUILD)"

# ---- archive + export (Developer ID) --------------------------------------
say "Archiving (Release, Developer ID)"
rm -f mediaremote-adapter/MediaRemoteAdapterTestClient 2>/dev/null || true
xcodebuild archive -scheme "$SCHEME" -configuration Release \
  -archivePath "$BUILD_DIR/Ghostwire.xcarchive" \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"

say "Exporting"
/usr/libexec/PlistBuddy -c "Add :method string developer-id" "$BUILD_DIR/export.plist"
/usr/libexec/PlistBuddy -c "Add :teamID string $TEAM_ID" "$BUILD_DIR/export.plist"
xcodebuild -exportArchive -archivePath "$BUILD_DIR/Ghostwire.xcarchive" \
  -exportOptionsPlist "$BUILD_DIR/export.plist" -exportPath "$BUILD_DIR/export"
APP="$BUILD_DIR/export/Ghostwire.app"

# ---- notarize + staple (free; waits as long as Apple needs) ---------------
say "Notarizing (this can take a while — Apple-side; it's free locally)"
ditto -c -k --keepParent "$APP" "$BUILD_DIR/submit.zip"
xcrun notarytool submit "$BUILD_DIR/submit.zip" \
  --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

# ---- dmg ------------------------------------------------------------------
say "Building DMG"
DMG="$BUILD_DIR/ghostwire-${VERSION}.dmg"
STAGING="$BUILD_DIR/dmg-staging"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Ghostwire $VERSION" -srcfolder "$STAGING" \
  -ov -format UDZO "$DMG"
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
printf '%s\n' "$SHA" > "$BUILD_DIR/ghostwire-${VERSION}.sha256"
echo "SHA-256: $SHA"

# ---- appcast (Sparkle key auto-found in keychain) -------------------------
say "Updating appcast"
APPCAST_STAGING="$BUILD_DIR/appcast-staging"
mkdir -p "$APPCAST_STAGING"
cp "$DMG" "$APPCAST_STAGING/"
[ -f "$APPCAST" ] && cp "$APPCAST" "$APPCAST_STAGING/" || true
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  -o "$APPCAST" "$APPCAST_STAGING"

# ---- publish --------------------------------------------------------------
say "Creating GitHub release $TAG"
git tag -f "$TAG" >/dev/null 2>&1 || true
git push origin "$TAG" 2>/dev/null || true
gh release create "$TAG" "$DMG" "$BUILD_DIR/ghostwire-${VERSION}.sha256" \
  --title "$TAG" --notes "Ghostwire $TAG. SHA-256: $SHA" \
  || gh release upload "$TAG" "$DMG" "$BUILD_DIR/ghostwire-${VERSION}.sha256" --clobber

say "Committing appcast"
git add "$APPCAST"
git diff --cached --quiet && echo "(appcast unchanged)" || {
  git commit -m "chore: update appcast for $TAG"
  git push origin HEAD
}

say "Done — $TAG published. Installed apps will auto-update via Sparkle. 🎉"
echo "DMG: github.com/$REPO/releases/tag/$TAG"
