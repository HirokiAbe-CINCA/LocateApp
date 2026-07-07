#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${VERSION:-}" ]]; then
  if VERSION_TAG="$(git describe --tags --abbrev=0 2>/dev/null)"; then
    VERSION="${VERSION_TAG#v}"
  else
    VERSION="0.1.0"
  fi
fi
RELEASE_DIR="${RELEASE_DIR:-$ROOT/release}"
ARCHIVE_BASE="LocateApp-$VERSION-mac-arm64"
ZIP="$RELEASE_DIR/$ARCHIVE_BASE.zip"
DMG="$RELEASE_DIR/$ARCHIVE_BASE.dmg"
SUMS="$RELEASE_DIR/SHA256SUMS.txt"
APPCAST="$RELEASE_DIR/appcast.xml"
EXPECT_NOTARIZED="${EXPECT_NOTARIZED:-0}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://hirokiabe-cinca.github.io/LocateApp/appcast.xml}"
REQUIRE_SPARKLE_APPCAST="${REQUIRE_SPARKLE_APPCAST:-0}"

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "Missing required artifact: $1" >&2
    exit 1
  fi
}

verify_app() {
  local app="$1"
  local daemon="$app/Contents/MacOS/LocateTunneldDaemon"
  local helper="$app/Contents/Resources/pymobiledevice3-helper/pymobiledevice3-helper"
  local icon="$app/Contents/Resources/AppIcon.icns"
  local sparkle_framework="$app/Contents/Frameworks/Sparkle.framework"
  local sparkle_executable="$sparkle_framework/Sparkle"
  local autoupdate="$sparkle_framework/Versions/B/Autoupdate"
  local version

  test -x "$app/Contents/MacOS/LocateApp"
  test -x "$daemon"
  test -x "$helper"
  test -f "$icon"
  test -x "$sparkle_executable"
  otool -l "$app/Contents/MacOS/LocateApp" | grep -Fq "@executable_path/../Frameworks"
  otool -L "$app/Contents/MacOS/LocateApp" | grep -Fq "@rpath/Sparkle.framework"
  codesign --verify --strict --verbose=2 "$autoupdate"
  codesign -d --entitlements :- "$autoupdate" 2>/dev/null |
    grep -q "<key>com.apple.application-identifier</key>"
  codesign --verify --strict --verbose=2 "$sparkle_framework/Versions/B/XPCServices/Downloader.xpc"
  codesign --verify --strict --verbose=2 "$sparkle_framework/Versions/B/XPCServices/Installer.xpc"
  codesign --verify --strict --verbose=2 "$sparkle_framework/Versions/B/Updater.app"
  codesign --verify --strict --verbose=2 "$sparkle_framework"
  codesign --verify --deep --strict --verbose=2 "$app"
  APP="$app" "$ROOT/scripts/verify_tunneld_bundle.sh"
  if [[ "$EXPECT_NOTARIZED" == "1" ]]; then
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=2 "$app"
  fi

  version="$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")"
  if [[ "$version" != "$VERSION" ]]; then
    echo "Expected app version $VERSION, got $version" >&2
    exit 1
  fi

  if [[ -f "$APPCAST" ]]; then
    verify_sparkle_plist "$app"
  fi

  "$helper" usbmux list >/dev/null

  if [[ "$ARCHIVE_BASE" == *mac-arm64 ]]; then
    file "$app/Contents/MacOS/LocateApp" | grep -q "arm64"
  fi
}

verify_sparkle_plist() {
  local app="$1"
  local plist="$app/Contents/Info.plist"
  local feed_url
  local public_key
  local enable_checks
  local automatically_update

  feed_url="$(plutil -extract SUFeedURL raw -o - "$plist")"
  public_key="$(plutil -extract SUPublicEDKey raw -o - "$plist")"
  enable_checks="$(plutil -extract SUEnableAutomaticChecks raw -o - "$plist")"
  automatically_update="$(plutil -extract SUAutomaticallyUpdate raw -o - "$plist")"

  if [[ "$feed_url" != "$SPARKLE_FEED_URL" ]]; then
    echo "Expected Sparkle feed $SPARKLE_FEED_URL, got $feed_url" >&2
    exit 1
  fi
  if [[ -z "$public_key" ]]; then
    echo "Sparkle public EdDSA key is missing from Info.plist" >&2
    exit 1
  fi
  if [[ "$enable_checks" != "1" && "$enable_checks" != "true" ]]; then
    echo "SUEnableAutomaticChecks must be true" >&2
    exit 1
  fi
  if [[ "$automatically_update" != "1" && "$automatically_update" != "true" ]]; then
    echo "SUAutomaticallyUpdate must be true" >&2
    exit 1
  fi
  if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
    if [[ ! -x "$ROOT/.venv/bin/python" ]]; then
      echo "Missing .venv/bin/python for Sparkle key verification." >&2
      exit 1
    fi
    SPARKLE_PUBLIC_ED_KEY="$public_key" \
      SPARKLE_ED_PRIVATE_KEY="$SPARKLE_ED_PRIVATE_KEY" \
      "$ROOT/.venv/bin/python" "$ROOT/scripts/verify_sparkle_keypair.py"
  fi
}

verify_appcast() {
  command -v python3 >/dev/null
  VERSION="$VERSION" ZIP="$ZIP" APPCAST="$APPCAST" python3 - <<'PY'
import os
import xml.etree.ElementTree as ET

version = os.environ["VERSION"]
zip_path = os.environ["ZIP"]
appcast_path = os.environ["APPCAST"]
expected_url = (
    "https://github.com/HirokiAbe-CINCA/LocateApp/releases/download/"
    f"v{version}/LocateApp-{version}-mac-arm64.zip"
)
sparkle_ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"

tree = ET.parse(appcast_path)
root = tree.getroot()

for element in root.iter():
    if element.tag in {f"{{{sparkle_ns}}}criticalUpdate", f"{{{sparkle_ns}}}minimumUpdateVersion"}:
        raise SystemExit(f"Appcast must not force updates: {element.tag}")

enclosures = list(root.iter("enclosure"))
if len(enclosures) != 1:
    raise SystemExit(f"Expected exactly one enclosure, got {len(enclosures)}")

enclosure = enclosures[0]
if enclosure.attrib.get("url") != expected_url:
    raise SystemExit(f"Unexpected appcast URL: {enclosure.attrib.get('url')}")
if not enclosure.attrib.get(f"{{{sparkle_ns}}}edSignature"):
    raise SystemExit("Missing Sparkle EdDSA signature")
if int(enclosure.attrib.get("length", "0")) != os.path.getsize(zip_path):
    raise SystemExit("Appcast length does not match ZIP size")

versions = [element.text for element in root.iter(f"{{{sparkle_ns}}}shortVersionString")]
if version not in versions:
    raise SystemExit(f"Missing sparkle:shortVersionString {version}")
PY
}

require_file "$ZIP"
require_file "$DMG"
require_file "$SUMS"
if [[ "$REQUIRE_SPARKLE_APPCAST" == "1" ]]; then
  require_file "$APPCAST"
fi

(
  cd "$RELEASE_DIR"
  shasum -a 256 -c "$(basename "$SUMS")"
)

if [[ -f "$APPCAST" ]]; then
  verify_appcast
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/LocateAppVerify.XXXXXX")"
MOUNT_DIR=""
cleanup() {
  if [[ -n "$MOUNT_DIR" ]]; then
    hdiutil detach "$MOUNT_DIR" -quiet || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

ditto -x -k "$ZIP" "$TMP_DIR/zip"
verify_app "$TMP_DIR/zip/LocateApp.app"

MOUNT_DIR="$(hdiutil attach "$DMG" -nobrowse -readonly | grep -o '/Volumes/.*' | head -n 1)"
if [[ -z "$MOUNT_DIR" ]]; then
  echo "Failed to mount $DMG" >&2
  exit 1
fi
verify_app "$MOUNT_DIR/LocateApp.app"
test -L "$MOUNT_DIR/Applications"
test -f "$MOUNT_DIR/.background/installer-background.png"
test -f "$MOUNT_DIR/.DS_Store"
if find "$MOUNT_DIR" -type f \( -name 'AuthKey_*.p8' -o -name 'notary-*.json' -o -name '*-app-notary.zip' \) | grep -q .; then
  echo "DMG contains signing or notarization work files" >&2
  exit 1
fi
if [[ "$EXPECT_NOTARIZED" == "1" ]]; then
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

echo "LocateApp release artifacts verified"
