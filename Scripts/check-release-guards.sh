#!/usr/bin/env bash
# Release guard: the public release build must not couple Peeknook to Noru.
#
# Peeknook consumes Noru only as an opt-in loopback sidecar (CLAUDE.md invariant 6):
# it talks to Noru over a versioned host API and never links Noru's code. The shared
# App Group is a first-party convenience that must never be required and must never ship
# in the default release without a deliberate decision. This guard enforces that:
#
#   1. App/Peeknook.entitlements (the default release entitlements) declares no App Group
#      and names no noruflow identifier.
#   2. No Swift source links a Noru module (import Noru...).
#   3. Package.swift declares no SwiftPM dependency on Noru.
#
# A first-party convenience build may re-add the App Group via a SEPARATE entitlements
# variant (e.g. App/Peeknook.FirstParty.entitlements) gated behind PEEKNOOK_FIRST_PARTY_NORU.
# That variant is intentionally NOT checked here; only the default release file is.
#
# Runs in CI (release-guards job) and as a release.sh pre-flight. Pure bash + grep:
# no Xcode, no toolchain, no network.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
note() { printf 'FAIL: %s\n' "$1" >&2; fail=1; }

ENT="$ROOT/App/Peeknook.entitlements"
if [[ -f "$ENT" ]]; then
  if grep -q "application-groups" "$ENT"; then
    note "App/Peeknook.entitlements declares com.apple.security.application-groups. The Noru App Group must not ship in the default release; gate it behind a first-party entitlements variant (PEEKNOOK_FIRST_PARTY_NORU) instead. See CLAUDE.md invariant 6."
  fi
  if grep -qi "noruflow" "$ENT"; then
    note "App/Peeknook.entitlements references a noruflow identifier. Remove it from the default release entitlements."
  fi
else
  echo "note: $ENT not found; skipping entitlements check." >&2
fi

if grep -rnE "^[[:space:]]*import[[:space:]]+Noru" --include="*.swift" "$ROOT/Sources" >/dev/null 2>&1; then
  note "A Swift source imports a Noru module. Peeknook must not link Noru's code; consume it over the loopback host API only."
fi

if [[ -f "$ROOT/Package.swift" ]] && grep -iqE "\.package\([^)]*noru" "$ROOT/Package.swift"; then
  note "Package.swift declares a dependency on Noru. Peeknook must not have a SwiftPM dependency on Noru."
fi

if [[ "$fail" -ne 0 ]]; then
  echo "release-guards: FAILED (Noru coupling detected in the default release build)." >&2
  exit 1
fi
echo "release-guards: passed (no Noru coupling in the default release build)."
