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
APP_NAME="LocateApp"
APP="$ROOT/dist/$APP_NAME.app"
RELEASE_DIR="$ROOT/release"
STAGING_DIR="$ROOT/build/release-staging"
ARCHIVE_BASE="$APP_NAME-$VERSION-mac-arm64"

cd "$ROOT"

command -v ditto >/dev/null
command -v hdiutil >/dev/null

rm -rf "$RELEASE_DIR" "$STAGING_DIR"
mkdir -p "$RELEASE_DIR" "$STAGING_DIR"

APP_VERSION="$VERSION" CONFIGURATION="${CONFIGURATION:-release}" BUNDLE_HELPER=1 \
  "$ROOT/scripts/build_app_bundle.sh"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$RELEASE_DIR/$ARCHIVE_BASE.zip"

mkdir -p "$STAGING_DIR"
cp -R "$APP" "$STAGING_DIR/"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$RELEASE_DIR/$ARCHIVE_BASE.dmg"

cat > "$RELEASE_DIR/RELEASE_NOTES.md" <<NOTES
# LocateApp $VERSION

- Japanese low-step UI for choosing a place and fixing the connected iPhone location.
- Hardened tunnel/process handling and release artifact verification.
- Simplified geometric app icon and embedded pymobiledevice3 helper.
- Not notarized yet; on first launch, use right-click Open if macOS Gatekeeper blocks the app.
NOTES

(
  cd "$RELEASE_DIR"
  shasum -a 256 "$ARCHIVE_BASE.zip" "$ARCHIVE_BASE.dmg" > SHA256SUMS.txt
)

ls -lh "$RELEASE_DIR"
