#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE_VERSION="${SPARKLE_VERSION:-2.9.3}"
SPARKLE_TOOLS_SHA256="${SPARKLE_TOOLS_SHA256:-74a07da821f92b79310009954c0e15f350173374a3abe39095b4fc5096916be6}"
SPARKLE_TOOLS_URL="${SPARKLE_TOOLS_URL:-https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz}"

if [[ -z "${VERSION:-}" ]]; then
  if VERSION_TAG="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null)"; then
    VERSION="${VERSION_TAG#v}"
  else
    VERSION="0.1.0"
  fi
fi

RELEASE_DIR="${RELEASE_DIR:-$ROOT/release}"
ARCHIVE_BASE="LocateApp-$VERSION-mac-arm64"
ZIP="$RELEASE_DIR/$ARCHIVE_BASE.zip"
APPCAST="$RELEASE_DIR/appcast.xml"
APPCAST_STAGING_DIR="${APPCAST_STAGING_DIR:-$(cd "$(dirname "$RELEASE_DIR")" && pwd)/build/sparkle-appcast}"
SPARKLE_TOOLS_DIR="${SPARKLE_TOOLS_DIR:-$ROOT/build/sparkle-tools/Sparkle-$SPARKLE_VERSION}"
DOWNLOAD_URL_PREFIX="${SPARKLE_DOWNLOAD_URL_PREFIX:-https://github.com/HirokiAbe-CINCA/LocateApp/releases/download/v$VERSION/}"

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "$name is required to generate a Sparkle appcast." >&2
    exit 1
  fi
}

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "Missing required file: $1" >&2
    exit 1
  fi
}

ensure_sparkle_tools() {
  if [[ -x "$SPARKLE_TOOLS_DIR/bin/generate_appcast" ]]; then
    return
  fi

  command -v curl >/dev/null
  command -v shasum >/dev/null
  command -v tar >/dev/null

  local work_dir archive actual_sha
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/LocateAppSparkleTools.XXXXXX")"
  archive="$work_dir/Sparkle-$SPARKLE_VERSION.tar.xz"
  curl -L --fail -o "$archive" "$SPARKLE_TOOLS_URL"
  actual_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
  if [[ "$actual_sha" != "$SPARKLE_TOOLS_SHA256" ]]; then
    echo "Sparkle tools checksum mismatch: expected $SPARKLE_TOOLS_SHA256, got $actual_sha" >&2
    exit 1
  fi

  rm -rf "$SPARKLE_TOOLS_DIR"
  mkdir -p "$SPARKLE_TOOLS_DIR"
  tar -xJf "$archive" -C "$SPARKLE_TOOLS_DIR"
}

require_env SPARKLE_ED_PRIVATE_KEY
require_file "$ZIP"
ensure_sparkle_tools

GENERATE_APPCAST="$SPARKLE_TOOLS_DIR/bin/generate_appcast"
require_file "$GENERATE_APPCAST"

rm -rf "$APPCAST_STAGING_DIR"
mkdir -p "$APPCAST_STAGING_DIR"
cp "$ZIP" "$APPCAST_STAGING_DIR/$ARCHIVE_BASE.zip"
if [[ -f "$RELEASE_DIR/RELEASE_NOTES.md" ]]; then
  cp "$RELEASE_DIR/RELEASE_NOTES.md" "$APPCAST_STAGING_DIR/$ARCHIVE_BASE.md"
else
  cat > "$APPCAST_STAGING_DIR/$ARCHIVE_BASE.md" <<NOTES
# LocateApp $VERSION

See the GitHub Release for details.
NOTES
fi

printf '%s' "$SPARKLE_ED_PRIVATE_KEY" |
  "$GENERATE_APPCAST" \
    --ed-key-file - \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    -o "$APPCAST" \
    "$APPCAST_STAGING_DIR"

if command -v xmllint >/dev/null; then
  xmllint --noout "$APPCAST"
fi

echo "$APPCAST"
