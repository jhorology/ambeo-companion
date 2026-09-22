#!/bin/bash
# Build AmbeoCompanion, install it to /Applications, and re-register the two
# privacy grants that an ad-hoc signature invalidates:
#   - Accessibility (アクセシビリティ) — active CGEvent tap that consumes media keys
#   - ListenEvent  (入力監視)         — observing those keys
#
# macOS does not allow a script to turn the switches on. This resets the stale
# TCC entries and opens each pane so they can be enabled again.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="AmbeoCompanion"
APP_BUNDLE="${ROOT}/${APP_NAME}.app"
DEST="/Applications/${APP_NAME}.app"

open_privacy_pane() {
  local anchor="$1"
  open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?${anchor}" \
    || open "x-apple.systempreferences:com.apple.preference.security?${anchor}"
}

wait_for_toggle() {
  local title="$1"
  echo
  echo "システム設定の「${title}」を開きました。"
  echo "  Ambeo Companion をオンにしてください。"
  echo "  リストに無い場合は + から ${DEST} を追加してください。"
  if [[ -t 0 ]]; then
    read -r -p "終わったら Enter を押してください: "
  else
    echo "標準入力がターミナルではないため、スイッチの操作を待たずに続行します。"
  fi
}

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
tccutil reset Accessibility "$BUNDLE_ID" || echo "警告: アクセシビリティのリセットに失敗しました。"
tccutil reset ListenEvent "$BUNDLE_ID" || echo "警告: 入力監視のリセットに失敗しました。"

# One launch makes the new binary show up in both lists, then quit before the toggles.
open "$DEST"
sleep 1
if pgrep -xq "$APP_NAME"; then
  killall "$APP_NAME" || true
fi

echo "==> [4/4] Re-enable the two privacy panes"
open_privacy_pane "Privacy_Accessibility"
wait_for_toggle "プライバシーとセキュリティ > アクセシビリティ"
open_privacy_pane "Privacy_ListenEvent"
wait_for_toggle "プライバシーとセキュリティ > 入力監視"

open "$DEST"
echo
echo "インストールしました: ${DEST}"
echo "権限を変えたあとにアプリを起動し直しています。"
