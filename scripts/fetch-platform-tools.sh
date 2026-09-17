#!/usr/bin/env bash
# Fetch Google platform-tools (adb) for linux and/or darwin.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/third_party/platform-tools"
mkdir -p "$OUT"
OS="${1:-}"
fetch_one() {
  local slug="$1" url="$2" bin="$3"
  local dest="$OUT/$slug"
  if [[ -x "$dest/$bin" ]]; then
    echo "OK  $slug already present"
    return
  fi
  echo "GET $url"
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL "$url" -o "$tmp/pt.zip"
  unzip -q "$tmp/pt.zip" -d "$tmp"
  mkdir -p "$dest"
  if [[ "$slug" == "windows" ]]; then
    cp -f "$tmp/platform-tools/adb.exe" "$dest/" || true
    cp -f "$tmp/platform-tools/AdbWinApi.dll" "$dest/" || true
    cp -f "$tmp/platform-tools/AdbWinUsbApi.dll" "$dest/" || true
  else
    cp -f "$tmp/platform-tools/adb" "$dest/"
    chmod +x "$dest/adb"
  fi
  cp -f "$tmp/platform-tools/NOTICE.txt" "$dest/" 2>/dev/null || true
  rm -rf "$tmp"
  echo "OK  $slug -> $dest"
}
case "$OS" in
  linux) fetch_one linux 'https://dl.google.com/android/repository/platform-tools-latest-linux.zip' adb ;;
  darwin) fetch_one darwin 'https://dl.google.com/android/repository/platform-tools-latest-darwin.zip' adb ;;
  *)
    fetch_one linux 'https://dl.google.com/android/repository/platform-tools-latest-linux.zip' adb
    fetch_one darwin 'https://dl.google.com/android/repository/platform-tools-latest-darwin.zip' adb
    ;;
esac
