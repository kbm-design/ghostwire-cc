#!/usr/bin/env bash
#
# release.sh — cut a Ghostwire release locally (no GitHub Actions / $0).
#
# Usage:   ./release.sh 0.1.2              (full cut: build + notarize + tag + publish)
#          ./release.sh 0.1.2 --dry-run    (build + notarize + signed appcast; NO tag/push/release)
#          ./release.sh --clean-derived-data   (wipe ~18GB of Ghostwire DerivedData cache)
#
# Distribution model (GW-215): SOURCE stays private (kbm-design/ghostwire-cc);
# BINARIES + appcast are served from the PUBLIC repo (Ghostwire-Design/ghostwire-releases).
# Sparkle only needs the feed + DMG anonymously fetchable.
#
# One-time setup:
#   1. Notary profile (Apple ID + app-specific password from appleid.apple.com):
#        xcrun notarytool store-credentials "ghostwire-notary" \
#          --apple-id "you@example.com" --team-id "K7A26693A4" --password "abcd-efgh-ijkl-mnop"
#   2. Bump MARKETING_VERSION + CURRENT_PROJECT_VERSION in Xcode (tag must match MARKETING_VERSION,
#      build must be > last published) and commit to main BEFORE running this.
#
set -euo pipefail

# ---- config ---------------------------------------------------------------
SCHEME="Ghostwire"
TEAM_ID="K7A26693A4"                              # Developer ID Application team
SIGNING_IDENTITY="Developer ID Application"
NOTARY_PROFILE="ghostwire-notary"                 # keychain profile from store-credentials
REPO="kbm-design/ghostwire-cc"                    # PRIVATE source — receives the git tag only
RELEASE_REPO="Ghostwire-Design/ghostwire-releases" # PUBLIC — receives DMG + appcast
APPCAST_NAME="appcast.xml"                          # MUST match the SUFeedURL path in Info.plist
FEED_URL="https://raw.githubusercontent.com/${RELEASE_REPO}/main/${APPCAST_NAME}"
# ---------------------------------------------------------------------------

# ---- subcommand: derived-data cleanup -------------------------------------
if [ "${1:-}" = "--clean-derived-data" ]; then
  printf '\n\033[1;36m▸ Removing ~/Library/Developer/Xcode/DerivedData/Ghostwire-*\033[0m\n'
  rm -rf ~/Library/Developer/Xcode/DerivedData/Ghostwire-* 2>/dev/null || true
  echo "✓ Cleaned. Xcode will regenerate on next build."
  exit 0
fi

VERSION="${1:?usage: ./release.sh <version>  e.g. 0.1.2}"
VERSION="${VERSION#v}"                             # accept v0.1.2 or 0.1.2
TAG="v${VERSION}"
DRY_RUN=0
[ "${2:-}" = "--dry-run" ] && DRY_RUN=1            # build + signed appcast, stop before publish
BUILD_DIR="$(mktemp -d)"
DERIVED_DATA="$BUILD_DIR/DerivedData"              # clean, controlled, removed on exit
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
gh repo view "$RELEASE_REPO" >/dev/null 2>&1 \
  || die "Public release repo '$RELEASE_REPO' not found — create it first (GW-215 step 1)."

# resolve packages into a CLEAN, controlled DerivedData; self-heal a corrupted SPM artifact cache.
# (2026-06-10 root cause: stale SourcePackages/workspace-state.json -> resolve skips, xcframeworks
#  go missing. Deleting only artifacts/ is a no-op; the state file is the real blocker.)
say "Resolving packages into clean DerivedData"
xcodebuild -resolvePackageDependencies -scheme "$SCHEME" -derivedDataPath "$DERIVED_DATA" >/dev/null
SP="$DERIVED_DATA/SourcePackages"
artifacts_ok() {
  [ -d "$SP/artifacts/sparkle/Sparkle/Sparkle.xcframework" ] \
  && [ -d "$SP/artifacts/lottie-spm/Lottie/Lottie.xcframework" ]
}
if ! artifacts_ok; then
  say "SPM artifacts incomplete — healing (rm workspace-state.json + re-resolve)"
  rm -f "$SP/workspace-state.json"
  xcodebuild -resolvePackageDependencies -scheme "$SCHEME" -derivedDataPath "$DERIVED_DATA" >/dev/null
fi
artifacts_ok || die "Sparkle/Lottie xcframework still missing after heal — aborting."
SPARKLE_BIN="$SP/artifacts/sparkle/Sparkle/bin"
[ -x "$SPARKLE_BIN/generate_appcast" ] || die "generate_appcast not found in $SPARKLE_BIN."

# version must match the built MARKETING_VERSION; build must be > last PUBLISHED (read from public feed)
SETTINGS="$(xcodebuild -showBuildSettings -scheme "$SCHEME" -derivedDataPath "$DERIVED_DATA" 2>/dev/null)"
MKT="$(awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}' <<<"$SETTINGS")"
BUILD="$(awk -F' = ' '/ CURRENT_PROJECT_VERSION /{print $2; exit}' <<<"$SETTINGS")"
[ "$MKT" = "$VERSION" ] || die "Tag $TAG != MARKETING_VERSION $MKT — bump the version in Xcode first."
LAST_BUILD="$(curl -fsSL "$FEED_URL" 2>/dev/null | grep -oE '<sparkle:version>[0-9]+' | head -1 | grep -oE '[0-9]+' || true)"
if [ -n "$LAST_BUILD" ] && [ "$BUILD" -le "$LAST_BUILD" ]; then
  die "Build $BUILD must be > last published $LAST_BUILD."
fi
echo "✓ v$VERSION (build $BUILD)"

# ---- archive + export (Developer ID) --------------------------------------
say "Archiving (Release, Developer ID)"
rm -f mediaremote-adapter/MediaRemoteAdapterTestClient 2>/dev/null || true
xcodebuild archive -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
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
SHA_FILE="$BUILD_DIR/ghostwire-${VERSION}.sha256"
printf '%s\n' "$SHA" > "$SHA_FILE"
echo "SHA-256: $SHA"

# ---- appcast (Sparkle EdDSA key auto-found in login keychain) -------------
# We do NOT regenerate keys; generate_appcast signs with the existing keychain private key
# whose public half is baked into SUPublicEDKey — required so v0.1.1 installs can verify.
say "Generating appcast (key reused from keychain)"
APPCAST_STAGING="$BUILD_DIR/appcast-staging"
mkdir -p "$APPCAST_STAGING"
cp "$DMG" "$APPCAST_STAGING/"
# seed from the live PUBLIC feed so prior items are preserved (empty placeholder => clean single item)
curl -fsSL "$FEED_URL" -o "$APPCAST_STAGING/$APPCAST_NAME" 2>/dev/null || true
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/${RELEASE_REPO}/releases/download/${TAG}/" \
  -o "$APPCAST_STAGING/$APPCAST_NAME" "$APPCAST_STAGING"

# CRITICAL: generate_appcast silently omits edSignature when it can't find the key (Sparkle #1605).
# Refuse to publish an unsigned/partly-signed feed — it would break auto-update silently.
say "Asserting appcast signature for $VERSION"
grep -q "<sparkle:shortVersionString>${VERSION}<" "$APPCAST_STAGING/$APPCAST_NAME" \
  || die "Appcast has no item for $VERSION — aborting."
ENCL=$(grep -c '<enclosure ' "$APPCAST_STAGING/$APPCAST_NAME" || true)
SIGS=$(grep -c 'sparkle:edSignature=' "$APPCAST_STAGING/$APPCAST_NAME" || true)
{ [ "${ENCL:-0}" -ge 1 ] && [ "$ENCL" = "$SIGS" ]; } \
  || die "Appcast: $SIGS signatures for $ENCL enclosures (Sparkle #1605 — EdDSA key not found). Aborting before publish."
echo "✓ $SIGS/$ENCL enclosures signed"

# ---- dry-run stop: leave artifacts for review, do NOT tag/push/publish -----
if [ "$DRY_RUN" = 1 ]; then
  OUT="$(mktemp -d -t ghostwire-dryrun-XXXX)"
  cp "$DMG" "$SHA_FILE" "$APPCAST_STAGING/$APPCAST_NAME" "$OUT/"
  say "DRY RUN — built + signed, but NOTHING tagged/pushed/published."
  echo "Artifacts: $OUT"
  echo "  DMG:     $(basename "$DMG")  (sha256 $SHA)"
  echo "  Appcast: $APPCAST_NAME"
  echo
  echo "Current live feed (anon): $(curl -sI "$FEED_URL" | head -1 | tr -d '\r')"
  echo
  echo "=== generated appcast (would be published) ==="
  cat "$OUT/$APPCAST_NAME"
  echo
  echo "Review, then run: ./release.sh $VERSION   (no --dry-run) to tag + publish."
  exit 0
fi

# ---- publish: tag -> PRIVATE source, DMG + appcast -> PUBLIC --------------
say "Tagging source on private repo ($REPO)"
git tag -f "$TAG" >/dev/null 2>&1 || true
git push origin "$TAG"

say "Uploading DMG to public release ($RELEASE_REPO $TAG)"
gh release create "$TAG" "$DMG" "$SHA_FILE" --repo "$RELEASE_REPO" \
  --title "$TAG" --notes "Ghostwire $TAG. SHA-256: $SHA" \
  || gh release upload "$TAG" "$DMG" "$SHA_FILE" --repo "$RELEASE_REPO" --clobber

say "Publishing appcast to $RELEASE_REPO:main/$APPCAST_NAME"
REL_CLONE="$BUILD_DIR/release-repo"
git clone --depth 1 "https://github.com/${RELEASE_REPO}.git" "$REL_CLONE"
cp "$APPCAST_STAGING/$APPCAST_NAME" "$REL_CLONE/$APPCAST_NAME"
git -C "$REL_CLONE" add "$APPCAST_NAME"
git -C "$REL_CLONE" diff --cached --quiet && echo "(appcast unchanged)" || {
  git -C "$REL_CLONE" commit -m "appcast: $TAG"
  git -C "$REL_CLONE" push origin HEAD
}

say "Done — $TAG published. Installed apps will auto-update via Sparkle. 🎉"
echo "Download: https://github.com/${RELEASE_REPO}/releases/tag/${TAG}"
echo "Feed:     $FEED_URL"
