#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/LocateApp.app"
EXECUTABLE="$APP/Contents/MacOS/LocateApp"
DAEMON_EXECUTABLE="$APP/Contents/MacOS/LocateTunneldDaemon"
CONFIGURATION="${CONFIGURATION:-debug}"
BUNDLE_HELPER="${BUNDLE_HELPER:-0}"
ENABLE_TUNNELD="${ENABLE_TUNNELD:-$BUNDLE_HELPER}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-${APPLE_SIGNING_IDENTITY:--}}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://hirokiabe-cinca.github.io/LocateApp/appcast.xml}"
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
TUNNELD_PLIST_SOURCE="$ROOT/packaging/LaunchDaemons/jp.cinca.LocateApp.tunneld.plist"

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

sign_target_preserving_entitlements() {
  local target="$1"
  local entitlements
  entitlements="$(mktemp "${TMPDIR:-/tmp}/LocateAppEntitlements.XXXXXX.plist")"
  if codesign -d --entitlements :- "$target" > "$entitlements" 2>/dev/null &&
      grep -q "<key>" "$entitlements"; then
    local args=(--force --sign "$SIGNING_IDENTITY" --entitlements "$entitlements")
    if is_developer_id_signing; then
      args+=(--timestamp --options runtime)
    fi
    codesign "${args[@]}" "$target"
  else
    sign_target "$target"
  fi
  rm -f "$entitlements"
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

find_sparkle_framework() {
  local candidate
  local fallback=""

  while IFS= read -r -d '' candidate; do
    [[ -x "$candidate/Sparkle" ]] || continue
    if [[ "$candidate" == *"/macos-"* ]]; then
      printf '%s\n' "$candidate"
      return
    fi
    if [[ -z "$fallback" ]]; then
      fallback="$candidate"
    fi
  done < <(find "$ROOT/.build" -type d -name 'Sparkle.framework' -print0)

  if [[ -n "$fallback" ]]; then
    printf '%s\n' "$fallback"
    return
  fi

  echo "Sparkle.framework was not found in SwiftPM build artifacts" >&2
  exit 1
}

copy_sparkle_framework() {
  local source="$1"
  local destination="$APP/Contents/Frameworks/Sparkle.framework"

  rm -rf "$destination"
  ditto "$source" "$destination"
}

sign_sparkle_framework() {
  local framework="$APP/Contents/Frameworks/Sparkle.framework"
  local version_dir="$framework/Versions/B"
  local target
  local targets=(
    "$version_dir/XPCServices/Downloader.xpc"
    "$version_dir/XPCServices/Installer.xpc"
    "$version_dir/Updater.app"
    "$framework"
  )

  if [[ -e "$version_dir/Autoupdate" ]]; then
    sign_target_preserving_entitlements "$version_dir/Autoupdate"
  fi

  for target in "${targets[@]}"; do
    if [[ -e "$target" ]]; then
      sign_target "$target"
    fi
  done
}

ensure_framework_rpath() {
  if ! otool -l "$EXECUTABLE" | grep -Fq "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXECUTABLE"
  fi
}

install_tunneld_launch_daemon_plist() {
  local destination_dir="$APP/Contents/Library/LaunchDaemons"
  local destination="$destination_dir/jp.cinca.LocateApp.tunneld.plist"

  if [[ ! -f "$TUNNELD_PLIST_SOURCE" ]]; then
    echo "Missing tunneld LaunchDaemon plist: $TUNNELD_PLIST_SOURCE" >&2
    exit 1
  fi

  mkdir -p "$destination_dir"
  cp "$TUNNELD_PLIST_SOURCE" "$destination"
  plutil -lint "$destination"
}

copy_tunneld_daemon() {
  swift build -c "$CONFIGURATION" --product LocateTunneldDaemon
  cp "$BIN_DIR/LocateTunneldDaemon" "$DAEMON_EXECUTABLE"
  sign_target "$DAEMON_EXECUTABLE"
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
command -v install_name_tool >/dev/null
command -v otool >/dev/null

case "$CONFIGURATION" in
  debug|release)
    ;;
  *)
    echo "CONFIGURATION must be debug or release" >&2
    exit 1
    ;;
esac

case "$ENABLE_TUNNELD" in
  1|true|yes)
    BUNDLE_HELPER=1
    ;;
  0|false|no)
    ;;
  *)
    echo "ENABLE_TUNNELD must be 0 or 1" >&2
    exit 1
    ;;
esac

echo "Building $CONFIGURATION app bundle..."
swift build -c "$CONFIGURATION" --product LocateApp
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
SPARKLE_FRAMEWORK="$(find_sparkle_framework)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/LocateApp" "$EXECUTABLE"
copy_sparkle_framework "$SPARKLE_FRAMEWORK"
ensure_framework_rpath

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
    case "$ENABLE_TUNNELD" in
      1|true|yes)
        copy_tunneld_daemon
        install_tunneld_launch_daemon_plist
        ;;
    esac
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

if [[ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
  plutil -insert SUFeedURL -string "$SPARKLE_FEED_URL" "$APP/Contents/Info.plist"
  plutil -insert SUPublicEDKey -string "$SPARKLE_PUBLIC_ED_KEY" "$APP/Contents/Info.plist"
  plutil -insert SUEnableAutomaticChecks -bool true "$APP/Contents/Info.plist"
  plutil -insert SUAutomaticallyUpdate -bool true "$APP/Contents/Info.plist"
else
  echo "SPARKLE_PUBLIC_ED_KEY is unset; building without Sparkle update feed configuration."
fi

plutil -lint "$APP/Contents/Info.plist"
if is_developer_id_signing; then
  sign_nested_macho_files
fi
sign_sparkle_framework
sign_target "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "$APP"
