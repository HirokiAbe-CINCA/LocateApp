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

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "Missing required artifact: $1" >&2
    exit 1
  fi
}

verify_app() {
  local app="$1"
  local helper="$app/Contents/Resources/pymobiledevice3-helper/pymobiledevice3-helper"
  local icon="$app/Contents/Resources/AppIcon.icns"
  local version

  test -x "$app/Contents/MacOS/LocateApp"
  test -x "$helper"
  test -f "$icon"
  codesign --verify --deep --strict --verbose=2 "$app"

  version="$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")"
  if [[ "$version" != "$VERSION" ]]; then
    echo "Expected app version $VERSION, got $version" >&2
    exit 1
  fi

  "$helper" usbmux list >/dev/null

  if [[ "$ARCHIVE_BASE" == *mac-arm64 ]]; then
    file "$app/Contents/MacOS/LocateApp" | grep -q "arm64"
  fi
}

require_file "$ZIP"
require_file "$DMG"
require_file "$SUMS"

(
  cd "$RELEASE_DIR"
  shasum -a 256 -c "$(basename "$SUMS")"
)

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

echo "LocateApp release artifacts verified"
