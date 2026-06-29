#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "Install XcodeGen: brew install xcodegen" >&2
  exit 1
fi

SIBLING="${OPENNOOK_PACKAGE_PATH:-$ROOT/../opennook}"
if [[ ! -f "$SIBLING/Package.swift" ]]; then
  cat >&2 <<EOF
error: OpenNook not found at:
  $SIBLING

Peeknook.xcodeproj needs a local OpenNook checkout for XcodeGen (Package.swift can fall back to git for \`swift test\`).

Fix:
  git clone https://github.com/athledev-labs/opennook.git "$ROOT/../opennook"

Or point at an existing clone:
  export OPENNOOK_PACKAGE_PATH="/path/to/opennook"
  ./Scripts/regenerate-xcodeproj.sh
EOF
  exit 1
fi

export OPENNOOK_PACKAGE_PATH="$(cd "$SIBLING" && pwd)"
xcodegen generate
echo "Generated Peeknook.xcodeproj (OpenNook: $OPENNOOK_PACKAGE_PATH)"
