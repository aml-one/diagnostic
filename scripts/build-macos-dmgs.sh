#!/usr/bin/env bash
# Build Intel + Apple Silicon AOW Diagnostic DMGs on Nova.
# The .app, the volume, and the .dmg file itself all use the Diagnostic icon.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT/version"
DIST="$ROOT/dist"

[[ "$(uname -s)" == "Darwin" ]] || { echo "Diagnostic macOS builds require macOS." >&2; exit 1; }
[[ -f "$ROOT/pubspec.yaml" ]] || { echo "Missing Diagnostic pubspec." >&2; exit 1; }
[[ -f "$VERSION_FILE" ]] || { echo "Missing Diagnostic version: $VERSION_FILE" >&2; exit 1; }

export PATH="${HOME}/flutter/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"
if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x "${HOME}/homebrew/bin/brew" ]]; then
  eval "$("${HOME}/homebrew/bin/brew" shellenv)"
fi
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  elif command -v xcode-select >/dev/null; then
    DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
    export DEVELOPER_DIR
  fi
fi
if [[ -n "${DEVELOPER_DIR:-}" && -d "$DEVELOPER_DIR/usr/bin" ]]; then
  export PATH="$DEVELOPER_DIR/usr/bin:$PATH"
fi
command -v flutter >/dev/null || { echo "flutter not found on PATH." >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "xcodebuild not found; set DEVELOPER_DIR." >&2; exit 1; }
command -v hdiutil >/dev/null || { echo "hdiutil not found." >&2; exit 1; }

SEMVER="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ "$SEMVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid Diagnostic semver: $SEMVER" >&2; exit 1; }
IFS=. read -r MAJOR MINOR PATCH <<< "$SEMVER"
BUILD_NUMBER=$((10#$MAJOR * 10000 + 10#$MINOR * 100 + 10#$PATCH))
BUILD_DATE="$(date -u +%y%m%d)"
LABEL="v$SEMVER-$BUILD_DATE"

ADB_DIR="$ROOT/third_party/platform-tools/darwin"
if [[ ! -x "$ADB_DIR/adb" ]]; then
  echo "==> Fetching Darwin platform-tools"
  bash "$ROOT/scripts/fetch-platform-tools.sh" darwin
fi

cd "$ROOT"
flutter config --no-enable-swift-package-manager >/dev/null 2>&1 || true
flutter pub get
dart run flutter_launcher_icons
flutter build macos --config-only --release --build-name "$SEMVER" --build-number "$BUILD_NUMBER" \
  --dart-define="APP_VERSION=$SEMVER" --dart-define="APP_BUILD_DATE=$BUILD_DATE"

WORKSPACE="$ROOT/macos/Runner.xcworkspace"
[[ -d "$WORKSPACE" ]] || { echo "Missing $WORKSPACE" >&2; exit 1; }

thin_to_arch() {
  local app="$1"
  local arch="$2"
  python3 - "$app" "$arch" <<'PY'
import os
import subprocess
import sys

app, arch = sys.argv[1], sys.argv[2]
for root, _dirs, files in os.walk(app):
    for name in files:
        path = os.path.join(root, name)
        try:
            info = subprocess.check_output(["file", "-b", path], text=True)
        except subprocess.CalledProcessError:
            continue
        if "Mach-O" not in info:
            continue
        try:
            arches = subprocess.check_output(["lipo", "-archs", path], text=True).split()
        except subprocess.CalledProcessError:
            continue
        if arch not in arches:
            sys.exit(f"{path} has no {arch} slice ({' '.join(arches)})")
        if len(arches) == 1:
            continue
        tmp = path + ".thin"
        subprocess.check_call(["lipo", "-thin", arch, path, "-output", tmp])
        os.replace(tmp, path)
PY
}

find_app() {
  local products="$1"
  if [[ -d "$products/diagnostic.app" ]]; then
    echo "$products/diagnostic.app"
    return
  fi
  local apps=()
  shopt -s nullglob
  apps=("$products"/*.app)
  shopt -u nullglob
  [[ ${#apps[@]} -gt 0 ]] || return 1
  echo "${apps[0]}"
}

apply_finder_icon() {
  local target="$1"
  local icns="$2"
  [[ -f "$icns" ]] || return 0
  python3 - "$target" "$icns" <<'PY'
import sys
from pathlib import Path
try:
    from AppKit import NSImage, NSWorkspace
except ImportError:
    sys.exit(0)
target, icns = sys.argv[1], sys.argv[2]
img = NSImage.alloc().initWithContentsOfFile_(icns)
if img is None:
    sys.exit(0)
NSWorkspace.sharedWorkspace().setIcon_forFile_options_(img, target, 0)
PY
  if command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "$target" 2>/dev/null || true
  fi
}

package_dmg() {
  local app="$1"
  local volname="$2"
  local artifact="$3"
  local icns="$4"
  local stage
  stage="$(mktemp -d /tmp/aow-diag-dmg.XXXXXX)"
  ditto "$app" "$stage/AOW Diagnostic.app"
  ln -s /Applications "$stage/Applications"
  if [[ -f "$icns" ]]; then
    cp -f "$icns" "$stage/.VolumeIcon.icns"
    if command -v SetFile >/dev/null 2>&1; then
      SetFile -c icnC "$stage/.VolumeIcon.icns" 2>/dev/null || true
    fi
  fi
  local rw
  rw="$(mktemp /tmp/aow-diag-rw.XXXXXX).dmg"
  rm -f "$artifact" "$rw"
  hdiutil create \
    -volname "$volname" \
    -srcfolder "$stage" \
    -ov -format UDRW \
    "$rw" >/dev/null
  local mount
  mount="$(mktemp -d /tmp/aow-diag-mnt.XXXXXX)"
  hdiutil attach -readwrite -noverify -noautoopen -mountpoint "$mount" "$rw" >/dev/null
  if command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "$mount" 2>/dev/null || true
  fi
  sync
  hdiutil detach "$mount" -force >/dev/null
  rmdir "$mount" 2>/dev/null || true
  rm -rf "$stage"
  hdiutil convert "$rw" -format UDZO -imagekey zlib-level=9 -o "$artifact" >/dev/null
  rm -f "$rw"
  apply_finder_icon "$artifact" "$icns"
}

build_one() {
  local arch="$1"
  local slug="$2"
  local volname="$3"
  local other
  if [[ "$arch" == "arm64" ]]; then
    other=x86_64
  else
    other=arm64
  fi
  local dd="$ROOT/build/macos-dd-$slug"
  rm -rf "$dd"
  echo "==> xcodebuild Diagnostic ($arch / $slug)"
  xcodebuild \
    -workspace "$WORKSPACE" \
    -scheme Runner \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$dd" \
    ARCHS="$arch" \
    ONLY_ACTIVE_ARCH=YES \
    EXCLUDED_ARCHS="$other" \
    CODE_SIGNING_ALLOWED=NO \
    build
  local products="$dd/Build/Products/Release"
  local app
  app="$(find_app "$products")"
  [[ -n "$app" && -d "$app" ]] || { echo "Diagnostic .app not found under $products" >&2; exit 1; }
  thin_to_arch "$app" "$arch"
  local executable_name
  executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
  local executable="$app/Contents/MacOS/$executable_name"
  [[ -f "$executable" ]] || { echo "Missing executable: $executable" >&2; exit 1; }
  local got
  got="$(lipo -archs "$executable")"
  [[ "$got" == "$arch" ]] || { echo "Expected $arch, got: $got ($executable)" >&2; exit 1; }
  local icns="$app/Contents/Resources/AppIcon.icns"
  [[ -f "$icns" ]] || { echo "ERROR: AppIcon.icns missing from $app" >&2; exit 1; }
  codesign --force --deep --sign - "$app" 2>/dev/null || true
  mkdir -p "$DIST"
  local artifact="$DIST/diagnostic-macos-$slug-$LABEL.dmg"
  echo "==> DMG $artifact"
  package_dmg "$app" "$volname" "$artifact" "$icns"
  echo "Diagnostic $slug ($arch): $artifact"
}

build_one arm64 silicon "AOW Diagnostic"
build_one x86_64 intel "AOW Diagnostic"
echo "Diagnostic macOS disk images: $DIST/diagnostic-macos-{silicon,intel}-$LABEL.dmg"
