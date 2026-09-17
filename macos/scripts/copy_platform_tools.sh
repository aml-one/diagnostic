#!/bin/sh
# Copies bundled platform-tools into the macOS .app next to the runner binary.
# Invoked from the Xcode "Thin Binary" / embed build phase.
set -e
SRC="${PROJECT_DIR}/../third_party/platform-tools/darwin"
DST="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/MacOS/platform-tools"
if [ ! -f "${SRC}/adb" ]; then
  echo "warning: bundled adb missing at ${SRC} — run scripts/fetch-platform-tools.ps1"
  exit 0
fi
mkdir -p "${DST}"
# Only embed the binary — NOTICE/source.properties break Xcode CodeSign
# ("code object is not signed at all" on non-Mach-O files in MacOS/).
rm -rf "${DST}"
mkdir -p "${DST}"
cp -f "${SRC}/adb" "${DST}/adb"
chmod +x "${DST}/adb"
# Ad-hoc sign so the subsequent app CodeSign phase accepts the nested binary.
codesign --force --sign - --timestamp=none "${DST}/adb" 2>/dev/null || true
echo "Bundled platform-tools -> ${DST}"
