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
DMG_STAGING_DIR="$ROOT/build/release-dmg"
NOTARY_WORK_DIR="$ROOT/build/notary-work"
ARCHIVE_BASE="$APP_NAME-$VERSION-mac-arm64"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARIZE="${NOTARIZE:-auto}"
NOTARIZE_ACTIVE=0
NOTARY_KEY_PATH=""
DMG_RW="$RELEASE_DIR/$ARCHIVE_BASE-rw.dmg"
DMG_FINAL="$RELEASE_DIR/$ARCHIVE_BASE.dmg"
MOUNT_DIR=""

cd "$ROOT"

command -v ditto >/dev/null
command -v hdiutil >/dev/null

notary_secrets_ready() {
  [[ -n "$SIGNING_IDENTITY" ]] &&
    [[ -n "${APPLE_NOTARY_KEY_ID:-}" ]] &&
    [[ -n "${APPLE_NOTARY_ISSUER_ID:-}" ]] &&
    { [[ -n "${APPLE_NOTARY_KEY_PATH:-}" ]] || [[ -n "${APPLE_NOTARY_KEY_P8_BASE64:-}" ]]; }
}

case "$NOTARIZE" in
  1|true|yes)
    if ! notary_secrets_ready; then
      echo "NOTARIZE is enabled, but signing identity or notary API key secrets are missing." >&2
      exit 1
    fi
    NOTARIZE_ACTIVE=1
    ;;
  0|false|no)
    NOTARIZE_ACTIVE=0
    ;;
  auto)
    if notary_secrets_ready; then
      NOTARIZE_ACTIVE=1
    fi
    ;;
  *)
    echo "NOTARIZE must be auto, 1, or 0" >&2
    exit 1
    ;;
esac

prepare_notary_key() {
  if [[ -n "${APPLE_NOTARY_KEY_PATH:-}" ]]; then
    NOTARY_KEY_PATH="$APPLE_NOTARY_KEY_PATH"
    return
  fi

  command -v python3 >/dev/null
  NOTARY_KEY_PATH="$NOTARY_WORK_DIR/AuthKey_${APPLE_NOTARY_KEY_ID}.p8"
  mkdir -p "$NOTARY_WORK_DIR"
  NOTARY_KEY_PATH="$NOTARY_KEY_PATH" python3 - <<'PY'
import base64
import os
from pathlib import Path

Path(os.environ["NOTARY_KEY_PATH"]).write_bytes(
    base64.b64decode(os.environ["APPLE_NOTARY_KEY_P8_BASE64"])
)
PY
  chmod 600 "$NOTARY_KEY_PATH"
}

submit_for_notarization() {
  local artifact="$1"
  local label="$2"
  local safe_label="${label//[^A-Za-z0-9]/-}"
  local result_json="$NOTARY_WORK_DIR/notary-$safe_label.json"
  local log_json="$NOTARY_WORK_DIR/notary-$safe_label-log.json"
  local submit_status
  set +e
  xcrun notarytool submit "$artifact" \
    --key "$NOTARY_KEY_PATH" \
    --key-id "$APPLE_NOTARY_KEY_ID" \
    --issuer "$APPLE_NOTARY_ISSUER_ID" \
    --wait \
    --output-format json >"$result_json"
  submit_status=$?
  set -e

  local submission_id
  submission_id="$(RESULT_JSON="$result_json" python3 - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["RESULT_JSON"])
if not path.exists() or not path.read_text().strip():
    raise SystemExit(0)
print(json.loads(path.read_text()).get("id", ""))
PY
)"
  if [[ "$submit_status" != "0" ]]; then
    if [[ -n "$submission_id" ]]; then
      xcrun notarytool log "$submission_id" \
        --key "$NOTARY_KEY_PATH" \
        --key-id "$APPLE_NOTARY_KEY_ID" \
        --issuer "$APPLE_NOTARY_ISSUER_ID" >"$log_json" || true
      echo "Notarization log written to $log_json" >&2
    fi
    cat "$result_json" >&2 || true
    return "$submit_status"
  fi
  echo "$label notarized"
}

staple_artifact() {
  local artifact="$1"
  xcrun stapler staple "$artifact"
  xcrun stapler validate "$artifact"
}

mount_dmg() {
  local dmg="$1"
  hdiutil attach "$dmg" -readwrite -noverify -noautoopen |
    awk '/\/Volumes\// {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^\/Volumes\//) {
          print substr($0, index($0, $i))
          exit
        }
      }
    }'
}

detach_mounted_dmg() {
  local mount_dir="$1"
  for _ in 1 2 3 4 5; do
    if hdiutil detach "$mount_dir" -quiet; then
      return 0
    fi
    sleep 1
  done
  hdiutil detach "$mount_dir"
}

cleanup_mount() {
  if [[ -n "${MOUNT_DIR:-}" ]]; then
    hdiutil detach "$MOUNT_DIR" -quiet || true
  fi
}

style_dmg_window() {
  local mount_dir="$1"
  osascript - "$mount_dir" "$APP_NAME" >/dev/null <<'APPLESCRIPT'
on run argv
  set mountPath to item 1 of argv
  set appName to item 2 of argv
  set mountFolder to POSIX file mountPath as alias
tell application "Finder"
  open mountFolder
  set targetWindow to container window of mountFolder
  set current view of targetWindow to icon view
  set toolbar visible of targetWindow to false
  set statusbar visible of targetWindow to false
  set bounds of targetWindow to {120, 120, 1040, 540}
  set viewOptions to the icon view options of targetWindow
  set arrangement of viewOptions to not arranged
  set icon size of viewOptions to 96
  set background picture of viewOptions to file ".background:installer-background.png" of mountFolder
  set position of item (appName & ".app") of mountFolder to {300, 306}
  set position of item "Applications" of mountFolder to {620, 306}
  update mountFolder without registering applications
  delay 1
  close targetWindow
end tell
end run
APPLESCRIPT
  sync
  detach_mounted_dmg "$mount_dir"
}

rm -rf "$RELEASE_DIR" "$DMG_STAGING_DIR" "$NOTARY_WORK_DIR"
mkdir -p "$RELEASE_DIR" "$DMG_STAGING_DIR" "$NOTARY_WORK_DIR"

if [[ "$NOTARIZE_ACTIVE" == "1" ]]; then
  command -v xcrun >/dev/null
  command -v python3 >/dev/null
  prepare_notary_key
fi

build_env=(
  APP_VERSION="$VERSION"
  CONFIGURATION="${CONFIGURATION:-release}"
  BUNDLE_HELPER=1
)
if [[ -n "$SIGNING_IDENTITY" ]]; then
  build_env+=(SIGNING_IDENTITY="$SIGNING_IDENTITY")
fi
env "${build_env[@]}" "$ROOT/scripts/build_app_bundle.sh"

if [[ "$NOTARIZE_ACTIVE" == "1" ]]; then
  APP_NOTARY_ZIP="$NOTARY_WORK_DIR/$ARCHIVE_BASE-app-notary.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$APP_NOTARY_ZIP"
  submit_for_notarization "$APP_NOTARY_ZIP" "$APP_NAME app archive"
  staple_artifact "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP" "$RELEASE_DIR/$ARCHIVE_BASE.zip"

mkdir -p "$DMG_STAGING_DIR/.background"
cp -R "$APP" "$DMG_STAGING_DIR/"
ln -s /Applications "$DMG_STAGING_DIR/Applications"
"$ROOT/.venv/bin/python" "$ROOT/scripts/generate_dmg_background.py" \
  --output "$DMG_STAGING_DIR/.background/installer-background.png"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING_DIR" \
  -ov \
  -format UDRW \
  "$DMG_RW"

trap cleanup_mount EXIT
MOUNT_DIR="$(mount_dmg "$DMG_RW")"
if [[ -z "$MOUNT_DIR" ]]; then
  echo "Failed to mount temporary DMG for styling" >&2
  exit 1
fi
style_dmg_window "$MOUNT_DIR"
MOUNT_DIR=""
hdiutil convert "$DMG_RW" -format UDZO -imagekey zlib-level=9 -o "$DMG_FINAL"
rm -f "$DMG_RW"

if [[ "$NOTARIZE_ACTIVE" == "1" ]]; then
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_FINAL"
  submit_for_notarization "$DMG_FINAL" "$APP_NAME DMG"
  staple_artifact "$DMG_FINAL"
  NOTARIZATION_NOTE="- Developer ID signed, notarized, and stapled for Gatekeeper."
else
  NOTARIZATION_NOTE="- Ad-hoc signed and not notarized yet; set Apple signing/notary secrets to notarize release artifacts."
fi

cat > "$RELEASE_DIR/RELEASE_NOTES.md" <<NOTES
# LocateApp $VERSION

- Japanese low-step UI for choosing a place and moving the connected iPhone location.
- In-app update notice with a direct download button for newer GitHub Releases.
- Styled DMG installer with a LocateApp background and Applications shortcut.
- Hardened tunnel/process handling and release artifact verification.
- Simplified geometric app icon and embedded pymobiledevice3 helper.
$NOTARIZATION_NOTE
NOTES

(
  cd "$RELEASE_DIR"
  shasum -a 256 "$ARCHIVE_BASE.zip" "$ARCHIVE_BASE.dmg" > SHA256SUMS.txt
)

ls -lh "$RELEASE_DIR"
