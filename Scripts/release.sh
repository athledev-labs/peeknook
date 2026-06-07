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
#   PEEKNOOK_CODE_SIGN_IDENTITY     Default: "Developer ID Application" when team is set, else "-"
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
#   export PEEKNOOK_CODE_SIGN_IDENTITY="Developer ID Application"
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

BUILD_DIR="$ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/Peeknook.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
APP_PATH="$EXPORT_DIR/Peeknook.app"
ZIP_PATH="$BUILD_DIR/Peeknook.zip"
SCHEME="PeeknookHostApp"
PROJECT="Peeknook.xcodeproj"

TEAM_ID="${PEEKNOOK_DEVELOPMENT_TEAM:-}"
SIGN_IDENTITY="${PEEKNOOK_CODE_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${PEEKNOOK_NOTARY_KEYCHAIN_PROFILE:-}"

if [[ -z "$SIGN_IDENTITY" ]]; then
  if [[ -n "$TEAM_ID" ]]; then
    SIGN_IDENTITY="Developer ID Application"
  else
    SIGN_IDENTITY="-"
  fi
fi

echo "==> Peeknook release"
echo "    Team ID:        ${TEAM_ID:-<unset — ad-hoc>}"
echo "    Sign identity:  $SIGN_IDENTITY"
echo "    Notary profile: ${NOTARY_PROFILE:-<unset — skip notarization>}"

if [[ "$SIGN_IDENTITY" != "-" && -z "$TEAM_ID" ]]; then
  cat >&2 <<'EOF'
error: PEEKNOOK_DEVELOPMENT_TEAM is required for Release signing.

Set your Apple Developer Team ID before running a distribution build:

  export PEEKNOOK_DEVELOPMENT_TEAM="XXXXXXXXXX"
  export PEEKNOOK_CODE_SIGN_IDENTITY="Developer ID Application"   # optional
  ./Scripts/release.sh

Find the Team ID in Apple Developer → Membership, or:

  xcodebuild -showBuildSettings -scheme PeeknookHostApp 2>/dev/null | grep DEVELOPMENT_TEAM

For local smoke tests without signing, omit the team (ad-hoc Release export).
EOF
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: Install XcodeGen: brew install xcodegen" >&2
  exit 1
fi

export PEEKNOOK_DEVELOPMENT_TEAM="$TEAM_ID"
export PEEKNOOK_CODE_SIGN_IDENTITY="$SIGN_IDENTITY"

echo "==> Regenerating Xcode project"
./Scripts/regenerate-xcodeproj.sh

mkdir -p "$BUILD_DIR" "$EXPORT_DIR"

echo "==> Archiving (Release)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  archive \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY"

echo "==> Writing export options"
EXPORT_METHOD="developer-id"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
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
codesign -dv --verbose=4 "$APP_PATH" 2>&1 | head -20

echo "==> Creating ZIP for notarization"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

if [[ -z "$NOTARY_PROFILE" ]]; then
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

Exported app: $APP_PATH
ZIP:          $ZIP_PATH
EOF
  exit 0
fi

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "warning: Skipping notarization for ad-hoc build." >&2
  echo "Exported app: $APP_PATH"
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

echo "==> Release complete"
echo "    App: $APP_PATH"
echo "    ZIP: $ZIP_PATH"
echo ""
echo "Optional DMG packaging:"
echo "  hdiutil create -volname Peeknook -srcfolder \"$APP_PATH\" -ov -format UDZO \"$BUILD_DIR/Peeknook.dmg\""
