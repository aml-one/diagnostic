#!/usr/bin/env bash
# Build Intel (x86_64) AOW Diagnostic .app + .dmg on Nova (Apple Silicon host).
# App icon + DMG volume icon both use the AOW branding mark.
set -euo pipefail

export PATH="${HOME}/flutter/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="${DEVELOPER_DIR}/usr/bin:${PATH}"
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SEMVER="$(tr -d '[:space:]' < version)"
BUILD_DATE="$(date -u +%y%m%d)"
DIST="$ROOT/dist"
mkdir -p "$DIST"

echo "==> Flutter $(flutter --version 2>/dev/null | head -1)"
echo "==> Building diagnostic macOS x86_64 v${SEMVER}"

flutter config --no-enable-swift-package-manager >/dev/null 2>&1 || true
flutter pub get

# Replace Flutter default AppIcon with branding.
dart run flutter_launcher_icons

# Force Intel arch for the Mac Mini (host Nova is arm64).
XCCONFIG="$ROOT/macos/Flutter/Flutter-Release.xcconfig"
RESTORE_XCCONFIG=0
if [[ -f "$XCCONFIG" ]] && ! grep -q 'AML_FORCE_X86_64' "$XCCONFIG"; then
  RESTORE_XCCONFIG=1
  cp "$XCCONFIG" "${XCCONFIG}.amlbak"
  cat >> "$XCCONFIG" <<'EOF'

// AML_FORCE_X86_64 — Intel Mac Mini build (temporary)
ARCHS = x86_64
ONLY_ACTIVE_ARCH = YES
EXCLUDED_ARCHS = arm64
EOF
fi

cleanup() {
  if [[ "$RESTORE_XCCONFIG" -eq 1 && -f "${XCCONFIG}.amlbak" ]]; then
    mv "${XCCONFIG}.amlbak" "$XCCONFIG"
  fi
}
trap cleanup EXIT

flutter build macos --release --build-name "$SEMVER" --build-number 10000

APP="$ROOT/build/macos/Build/Products/Release/diagnostic.app"
if [[ ! -d "$APP" ]]; then
  shopt -s nullglob
  apps=("$ROOT"/build/macos/Build/Products/Release/*.app)
  APP="${apps[0]:-}"
fi
[[ -d "$APP" ]] || { echo "ERROR: .app not found"; exit 1; }

EXEC_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
EXEC="$APP/Contents/MacOS/$EXEC_NAME"
ARCHS="$(lipo -archs "$EXEC" 2>/dev/null || true)"
echo "==> Binary archs: $ARCHS"
echo "$ARCHS" | grep -q 'x86_64' || { echo "ERROR: expected x86_64, got: $ARCHS"; exit 1; }

ICNS="$APP/Contents/Resources/AppIcon.icns"
if [[ ! -f "$ICNS" ]]; then
  echo "ERROR: AppIcon.icns missing from built app"
  exit 1
fi
echo "==> AppIcon.icns: $(ls -lh "$ICNS" | awk '{print $5}')"

codesign --force --deep --sign - "$APP" 2>/dev/null || true

STAGE="$(mktemp -d /tmp/aow-diag-dmg.XXXXXX)"
cp -R "$APP" "$STAGE/AOW Diagnostic.app"
ln -s /Applications "$STAGE/Applications"

# Same branding mark as the volume icon in Finder / Desktop.
cp -f "$ICNS" "$STAGE/.VolumeIcon.icns"
if command -v SetFile >/dev/null 2>&1; then
  SetFile -c icnC "$STAGE/.VolumeIcon.icns" 2>/dev/null || true
fi

DMG_RW="$(mktemp /tmp/aow-diag-rw.XXXXXX).dmg"
DMG="$DIST/AOW-Diagnostic-macos-x86_64-v${SEMVER}-${BUILD_DATE}.dmg"
rm -f "$DMG" "$DMG_RW"

hdiutil create \
  -volname "AOW Diagnostic" \
  -srcfolder "$STAGE" \
  -ov -format UDRW \
  "$DMG_RW"

MOUNT_DIR="$(mktemp -d /tmp/aow-diag-mnt.XXXXXX)"
hdiutil attach -readwrite -noverify -noautoopen -mountpoint "$MOUNT_DIR" "$DMG_RW" >/dev/null
if command -v SetFile >/dev/null 2>&1; then
  # Custom-icon catalog flag so Finder shows .VolumeIcon.icns for the volume.
  SetFile -a C "$MOUNT_DIR" 2>/dev/null || true
fi
sync
hdiutil detach "$MOUNT_DIR" -force >/dev/null
rmdir "$MOUNT_DIR" 2>/dev/null || true
rm -rf "$STAGE"

hdiutil convert "$DMG_RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -f "$DMG_RW"

ls -lh "$DMG"
echo "DMG_PATH=$DMG"
