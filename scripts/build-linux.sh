#!/usr/bin/env bash
# Run on a Linux Flutter host (or WSL Ubuntu) from the Diagnostic repo root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT/version"
DIST="$ROOT/dist"

[[ "$(uname -s)" == "Linux" ]] || { echo "Diagnostic Linux builds require Linux." >&2; exit 1; }
[[ -f "$ROOT/pubspec.yaml" ]] || { echo "Missing Diagnostic pubspec." >&2; exit 1; }
[[ -f "$VERSION_FILE" ]] || { echo "Missing Diagnostic version: $VERSION_FILE" >&2; exit 1; }

export PATH="${HOME}/flutter/bin:${PATH}"
command -v flutter >/dev/null || { echo "flutter not found on PATH." >&2; exit 1; }
command -v cmake >/dev/null || { echo "cmake not found (install build-essential / clang / cmake / ninja / gtk)." >&2; exit 1; }

SEMVER="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ "$SEMVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid Diagnostic semver: $SEMVER" >&2; exit 1; }
IFS=. read -r MAJOR MINOR PATCH <<< "$SEMVER"
BUILD_NUMBER=$((10#$MAJOR * 10000 + 10#$MINOR * 100 + 10#$PATCH))
BUILD_DATE="$(date -u +%y%m%d)"
LABEL="v$SEMVER-$BUILD_DATE"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH_SLUG=x64 ;;
  aarch64|arm64) ARCH_SLUG=arm64 ;;
  *) ARCH_SLUG="$ARCH" ;;
esac

ADB_DIR="$ROOT/third_party/platform-tools/linux"
if [[ ! -x "$ADB_DIR/adb" ]]; then
  echo "==> Fetching Linux platform-tools"
  bash "$ROOT/scripts/fetch-platform-tools.sh" linux
fi
[[ -x "$ADB_DIR/adb" ]] || { echo "Bundled adb missing at $ADB_DIR" >&2; exit 1; }

cd "$ROOT"
flutter pub get
flutter build linux --release \
  --build-name "$SEMVER" \
  --build-number "$BUILD_NUMBER" \
  --dart-define="APP_VERSION=$SEMVER" \
  --dart-define="APP_BUILD_DATE=$BUILD_DATE"

BUNDLE="$ROOT/build/linux/$ARCH_SLUG/release/bundle"
[[ -d "$BUNDLE" ]] || { echo "Missing Flutter Linux bundle: $BUNDLE" >&2; exit 1; }
[[ -x "$BUNDLE/diagnostic" ]] || { echo "Missing diagnostic binary in $BUNDLE" >&2; exit 1; }

mkdir -p "$DIST"
ICON_SRC="$ROOT/assets/branding/app_icon_light.png"
[[ -f "$ICON_SRC" ]] || { echo "Missing $ICON_SRC" >&2; exit 1; }

if [[ "$ARCH_SLUG" == "x64" ]]; then
  command -v dpkg-deb >/dev/null || { echo "dpkg-deb not found; install dpkg-dev to emit the .deb." >&2; exit 1; }
  DEB_ROOT="$(mktemp -d)"
  mkdir -p \
    "$DEB_ROOT/DEBIAN" \
    "$DEB_ROOT/usr/lib/diagnostic" \
    "$DEB_ROOT/usr/share/applications" \
    "$DEB_ROOT/usr/share/icons/hicolor/256x256/apps"
  cp -a "$BUNDLE/." "$DEB_ROOT/usr/lib/diagnostic/"
  install -m 644 "$ICON_SRC" \
    "$DEB_ROOT/usr/share/icons/hicolor/256x256/apps/one.aml.diagnostic.png"
  cat > "$DEB_ROOT/usr/share/applications/one.aml.diagnostic.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=AOW Diagnostic
GenericName=Android diagnostics
Comment=Watch logcat, pull bugreports, and see nearby OneDrop from the desk
Exec=/usr/lib/diagnostic/diagnostic
Icon=one.aml.diagnostic
Terminal=false
Categories=Development;Utility;
StartupNotify=true
StartupWMClass=diagnostic
EOF
  cat > "$DEB_ROOT/DEBIAN/control" <<EOF
Package: aow-diagnostic
Version: $SEMVER
Section: devel
Priority: optional
Architecture: amd64
Maintainer: AmL <hello@aml.one>
Depends: libgtk-3-0
Description: AOW Diagnostic — Android ANR and performance from the desk
Homepage: https://aml.one
EOF
  chmod 644 "$DEB_ROOT/DEBIAN/control"
  DEB="$DIST/diagnostic-linux-x64-$LABEL.deb"
  rm -f "$DEB"
  dpkg-deb --root-owner-group --build "$DEB_ROOT" "$DEB"
  rm -rf "$DEB_ROOT"
  echo "Diagnostic Linux deb: $DEB"
fi
