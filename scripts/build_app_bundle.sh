#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/LocateApp.app"
EXECUTABLE="$APP/Contents/MacOS/LocateApp"
CONFIGURATION="${CONFIGURATION:-debug}"
BUNDLE_HELPER="${BUNDLE_HELPER:-0}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-${APPLE_SIGNING_IDENTITY:--}}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="-"
fi
if [[ -z "${APP_VERSION:-}" ]]; then
  if VERSION_TAG="$(git describe --tags --abbrev=0 2>/dev/null)"; then
    APP_VERSION="${VERSION_TAG#v}"
  else
    APP_VERSION="0.1.0"
  fi
fi
APP_BUILD="${APP_BUILD:-${GITHUB_RUN_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}}"

is_developer_id_signing() {
  [[ "$SIGNING_IDENTITY" != "-" ]]
}

sign_target() {
  local target="$1"
  local args=(--force --sign "$SIGNING_IDENTITY")
  if is_developer_id_signing; then
    args+=(--timestamp --options runtime)
  fi
  codesign "${args[@]}" "$target"
}

is_macho_file() {
  local path="$1"
  file "$path" | grep -Eq 'Mach-O'
}

sign_nested_macho_files() {
  local resources="$APP/Contents/Resources"
  if [[ ! -d "$resources" ]]; then
    return
  fi

  while IFS= read -r -d '' path; do
    if is_macho_file "$path"; then
      sign_target "$path"
    fi
  done < <(find "$resources" -type f \( -perm -111 -o -name '*.dylib' -o -name '*.so' \) -print0)
}

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
command -v iconutil >/dev/null

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

"$ROOT/.venv/bin/python" "$ROOT/scripts/generate_app_icon.py" \
  --output "$APP/Contents/Resources/AppIcon.icns" \
  --preview "$APP/Contents/Resources/AppIcon.png"

case "$BUNDLE_HELPER" in
  0|false|no)
    ;;
  1|true|yes)
    "$ROOT/scripts/build_helper.sh"
    HELPER_DIR="${HELPER_DIST_DIR:-$ROOT/build/helper-dist}/pymobiledevice3-helper"
    rm -rf "$APP/Contents/Resources/pymobiledevice3-helper"
    cp -R "$HELPER_DIR" "$APP/Contents/Resources/pymobiledevice3-helper"
    ;;
  *)
    echo "BUNDLE_HELPER must be 0 or 1" >&2
    exit 1
    ;;
esac

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
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleShortVersionString</key>
  <string>__APP_VERSION__</string>
  <key>CFBundleVersion</key>
  <string>__APP_BUILD__</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

perl -0pi -e "s/__APP_VERSION__/$APP_VERSION/g" "$APP/Contents/Info.plist"
perl -0pi -e "s/__APP_BUILD__/$APP_BUILD/g" "$APP/Contents/Info.plist"

plutil -lint "$APP/Contents/Info.plist"
if is_developer_id_signing; then
  sign_nested_macho_files
fi
sign_target "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "$APP"
