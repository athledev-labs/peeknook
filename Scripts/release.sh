#!/usr/bin/env bash
# Peeknook release pipeline: archive → export → notarize → staple.
#
# Prerequisites:
#   - XcodeGen (brew install xcodegen)
#   - Xcode command-line tools
#   - Apple Developer Program membership for signed/notarized releases
#
# Environment (Release signing):
#   PEEKNOOK_DEVELOPMENT_TEAM       Apple Developer Team ID (required for distribution)
#
# Environment (notarization — optional; skipped when profile is unset):
#   PEEKNOOK_NOTARY_KEYCHAIN_PROFILE   Keychain profile for xcrun notarytool
#
# Local ad-hoc build (no team):
#   ./Scripts/release.sh
#   Produces an unsigned Release archive/export suitable for smoke testing only.
#
# Signed + notarized release:
#   export PEEKNOOK_DEVELOPMENT_TEAM="XXXXXXXXXX"
#   export PEEKNOOK_NOTARY_KEYCHAIN_PROFILE="peeknook-notary"
#   ./Scripts/release.sh
#
# Verify entitlements after export:
#   codesign -d --entitlements :- build/export/Peeknook.app
#   codesign -dv --verbose=4 build/export/Peeknook.app
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Pre-flight: never cut a release that couples the default build to Noru (no shared App
# Group, no Noru source/package linkage). See Scripts/check-release-guards.sh / CLAUDE.md
# invariant 6. A first-party convenience build re-adds the App Group via a separate
# entitlements variant gated behind PEEKNOOK_FIRST_PARTY_NORU, which the guard does not check.
echo "==> Release guards (no Noru coupling)"
"$ROOT/Scripts/check-release-guards.sh"

BUILD_DIR="$ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/Peeknook.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
APP_PATH="$EXPORT_DIR/Peeknook.app"
ZIP_PATH="$BUILD_DIR/Peeknook.zip"
SCHEME="Peeknook"
PROJECT="Peeknook.xcodeproj"

TEAM_ID="${PEEKNOOK_DEVELOPMENT_TEAM:-}"
NOTARY_PROFILE="${PEEKNOOK_NOTARY_KEYCHAIN_PROFILE:-}"
DISTRIBUTION_BUILD=false
if [[ -n "$TEAM_ID" ]]; then
  DISTRIBUTION_BUILD=true
fi

echo "==> Peeknook release"
echo "    Team ID:        ${TEAM_ID:-<unset — ad-hoc>}"
if [[ "$DISTRIBUTION_BUILD" == true ]]; then
  echo "    Signing:        automatic (Developer ID export)"
else
  echo "    Signing:        ad-hoc"
fi
echo "    Notary profile: ${NOTARY_PROFILE:-<unset — skip notarization>}"

if [[ -n "${PEEKNOOK_CODE_SIGN_IDENTITY:-}" ]]; then
  echo "note: PEEKNOOK_CODE_SIGN_IDENTITY is ignored; use automatic signing + DEVELOPMENT_TEAM." >&2
fi

if [[ -n "$NOTARY_PROFILE" && "$DISTRIBUTION_BUILD" == false ]]; then
  cat >&2 <<'EOF'
error: PEEKNOOK_DEVELOPMENT_TEAM is required when notarization is enabled.

  export PEEKNOOK_DEVELOPMENT_TEAM="XXXXXXXXXX"
  export PEEKNOOK_NOTARY_KEYCHAIN_PROFILE="peeknook-notary"
  ./Scripts/release.sh
EOF
  exit 1
fi

if [[ "$DISTRIBUTION_BUILD" == true ]]; then
  if ! security find-identity -v -p codesigning 2>/dev/null | grep -q 'Developer ID Application'; then
    cat >&2 <<'EOF'
error: No "Developer ID Application" certificate in your keychain.

Direct download export needs Developer ID Application, not Apple Development.

Create one:
  developer.apple.com → Certificates, Identifiers & Profiles → Certificates → +
  → Developer ID Application → upload a CSR from Keychain Access

Or in Xcode:
  Settings → Accounts → your team → Manage Certificates → + → Developer ID Application

Then re-run ./Scripts/release.sh
EOF
    exit 1
  fi
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: Install XcodeGen: brew install xcodegen" >&2
  exit 1
fi

export PEEKNOOK_DEVELOPMENT_TEAM="$TEAM_ID"

echo "==> Regenerating Xcode project"
./Scripts/regenerate-xcodeproj.sh

mkdir -p "$BUILD_DIR" "$EXPORT_DIR"

echo "==> Archiving (Release)"
ARCHIVE_ARGS=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration Release
  -archivePath "$ARCHIVE_PATH"
  archive
)
if [[ "$DISTRIBUTION_BUILD" == true ]]; then
  ARCHIVE_ARGS+=(DEVELOPMENT_TEAM="$TEAM_ID" -allowProvisioningUpdates)
fi
xcodebuild "${ARCHIVE_ARGS[@]}"

echo "==> Writing export options"
EXPORT_METHOD="developer-id"
if [[ "$DISTRIBUTION_BUILD" == false ]]; then
  EXPORT_METHOD="development"
fi

cat >"$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>$EXPORT_METHOD</string>
    <key>signingStyle</key>
    <string>automatic</string>
PLIST

if [[ -n "$TEAM_ID" ]]; then
  cat >>"$EXPORT_OPTIONS" <<PLIST
    <key>teamID</key>
    <string>$TEAM_ID</string>
PLIST
fi

cat >>"$EXPORT_OPTIONS" <<'PLIST'
</dict>
</plist>
PLIST

rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"

echo "==> Exporting archive"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: Expected app at $APP_PATH" >&2
  exit 1
fi

echo "==> Verifying code signature"
codesign -dv --verbose=4 "$APP_PATH" 2>&1 | head -20 || true

echo "==> Creating ZIP for notarization"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

package_release_artifacts() {
  VERSION="$(
    /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist"
  )"
  DMG_VERSIONED="$BUILD_DIR/Peeknook-${VERSION}.dmg"
  DMG_LATEST="$BUILD_DIR/Peeknook.dmg"
  CHECKSUM_PATH="$BUILD_DIR/Peeknook.dmg.sha256"

  echo "==> Packaging DMG (v${VERSION})"
  rm -f "$DMG_VERSIONED" "$DMG_LATEST" "$CHECKSUM_PATH"
  hdiutil create -volname Peeknook -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_VERSIONED"

  # The app inside is already signed, notarized, and stapled, but the DMG is its own
  # distributable artifact that Gatekeeper assesses on mount. A stapled-but-unsigned
  # DMG still fails `spctl -t open` ("no usable signature"), so sign it with Developer
  # ID first, then notarize it in its own right and staple the ticket — a download then
  # opens cleanly and offline instead of tripping "Apple cannot check it".
  if [[ "$DISTRIBUTION_BUILD" == true && -n "$NOTARY_PROFILE" ]]; then
    DEVID_IDENTITY="$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')"
    if [[ -z "$DEVID_IDENTITY" ]]; then
      echo "error: no Developer ID Application identity found to sign the DMG." >&2
      exit 1
    fi
    echo "==> Signing, notarizing, and stapling DMG"
    codesign --force --sign "$DEVID_IDENTITY" --timestamp "$DMG_VERSIONED"
    xcrun notarytool submit "$DMG_VERSIONED" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_VERSIONED"
  fi

  cp -f "$DMG_VERSIONED" "$DMG_LATEST"
  shasum -a 256 "$DMG_LATEST" | awk '{print $1}' >"$CHECKSUM_PATH"

  echo "==> Release artifacts"
  echo "    App:      $APP_PATH"
  echo "    ZIP:      $ZIP_PATH"
  echo "    DMG:      $DMG_LATEST (stable name for /releases/latest/download/)"
  echo "    DMG:      $DMG_VERSIONED"
  echo "    SHA256:   $(cat "$CHECKSUM_PATH")"
  echo ""
  echo "Upload both DMGs plus Peeknook.zip to the GitHub release:"
  echo "  gh release upload \"v${VERSION}\" \\"
  echo "    \"$DMG_LATEST\" \"$DMG_VERSIONED\" \"$ZIP_PATH\" \\"
  echo "    --clobber"
  echo ""
  echo "GitHub attaches sha256 digests to release assets automatically."
}

if [[ -z "$NOTARY_PROFILE" ]]; then
  package_release_artifacts
  cat <<EOF

==> Notarization skipped (PEEKNOOK_NOTARY_KEYCHAIN_PROFILE not set)

To notarize after export:

  1. Store credentials (one-time):
       xcrun notarytool store-credentials "peeknook-notary" \\
         --apple-id "you@example.com" \\
         --team-id "$TEAM_ID" \\
         --password "<app-specific-password>"

  2. Re-run with:
       export PEEKNOOK_NOTARY_KEYCHAIN_PROFILE="peeknook-notary"
       ./Scripts/release.sh

Or submit manually:
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "<profile>" --wait
  xcrun stapler staple "$APP_PATH"
EOF
  exit 0
fi

if [[ "$DISTRIBUTION_BUILD" == false ]]; then
  echo "warning: Skipping notarization for ad-hoc build." >&2
  package_release_artifacts
  exit 0
fi

if ! xcrun notarytool --help >/dev/null 2>&1; then
  echo "error: xcrun notarytool not available; install Xcode command-line tools." >&2
  exit 1
fi

echo "==> Submitting to Apple notary service"
xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP_PATH"

package_release_artifacts
