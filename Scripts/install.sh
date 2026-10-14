#!/bin/bash
# Build AmbeoCompanion, install it to /Applications, and re-register the two
# privacy grants that an ad-hoc signature invalidates:
#   - Accessibility — active CGEvent tap that consumes media keys
#   - ListenEvent   — observing those keys
#
# macOS does not allow a script to turn the switches on. This resets the stale
# TCC entries and launches the app's permission onboarding.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="AmbeoCompanion"
APP_BUNDLE="${ROOT}/${APP_NAME}.app"
DEST="/Applications/${APP_NAME}.app"

echo "==> [1/4] Build and sign"
swift Scripts/PackageApp.swift

echo "==> [2/4] Replace ${DEST}"
if pgrep -xq "$APP_NAME"; then
  killall "$APP_NAME" || true
  for _ in {1..25}; do
    pgrep -xq "$APP_NAME" || break
    sleep 0.2
  done
fi

if [[ ! -w /Applications ]] || { [[ -e "$DEST" ]] && [[ ! -w "$DEST" ]]; }; then
  sudo rm -rf "$DEST"
  sudo ditto "$APP_BUNDLE" "$DEST"
  sudo chown -R "$(id -un):$(id -gn)" "$DEST"
else
  rm -rf "$DEST"
  ditto "$APP_BUNDLE" "$DEST"
fi
xattr -cr "$DEST"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${DEST}/Contents/Info.plist")"

echo "==> [3/4] Reset privacy grants for ${BUNDLE_ID}"
# Clear the previous cdhash. A switch that still looks on is not valid after re-signing.
tccutil reset Accessibility "$BUNDLE_ID" || echo "Warning: Failed to reset Accessibility permissions."
tccutil reset ListenEvent "$BUNDLE_ID" || echo "Warning: Failed to reset Input Monitoring permissions."

echo "==> [4/4] Launch permission onboarding"
open "$DEST"
echo
echo "Installed: ${DEST}"
echo "Use the app's Media Key Permissions window to enable both permissions."
