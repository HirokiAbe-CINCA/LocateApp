#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/LocateApp.app"
EXECUTABLE="$APP/Contents/MacOS/LocateApp"
CONFIGURATION="${CONFIGURATION:-debug}"

cd "$ROOT"

if [[ ! -x "$ROOT/.venv/bin/pymobiledevice3" ]]; then
  cat >&2 <<'MESSAGE'
Missing .venv/bin/pymobiledevice3.

Run:
  python3.13 -m venv .venv
  .venv/bin/python -m pip install -e '.[dev]'
MESSAGE
  exit 1
fi

command -v swift >/dev/null
command -v plutil >/dev/null
command -v codesign >/dev/null

case "$CONFIGURATION" in
  debug|release)
    ;;
  *)
    echo "CONFIGURATION must be debug or release" >&2
    exit 1
    ;;
esac

echo "Building $CONFIGURATION app bundle..."
swift build -c "$CONFIGURATION" --product LocateApp
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/LocateApp" "$EXECUTABLE"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>LocateApp</string>
  <key>CFBundleIdentifier</key>
  <string>jp.cinca.LocateApp</string>
  <key>CFBundleName</key>
  <string>LocateApp</string>
  <key>CFBundleDisplayName</key>
  <string>LocateApp</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "$APP"
