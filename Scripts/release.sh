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

if [[ "$DISTRIBUTION_BUILD" == false ]]; then
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
