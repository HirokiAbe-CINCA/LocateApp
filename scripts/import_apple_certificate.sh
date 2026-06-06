#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${APPLE_DEVELOPER_ID_CERTIFICATE_P12_BASE64:-}" ]]; then
  echo "Apple Developer ID certificate secret is not set; using ad-hoc signing."
  exit 0
fi

: "${APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD:?APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD is required}"
: "${APPLE_KEYCHAIN_PASSWORD:?APPLE_KEYCHAIN_PASSWORD is required}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_ROOT="${RUNNER_TEMP:-$ROOT/build}"
KEYCHAIN_PATH="${APPLE_KEYCHAIN_PATH:-$TEMP_ROOT/locateapp-signing.keychain-db}"
P12_PATH="$TEMP_ROOT/locateapp-developer-id.p12"

mkdir -p "$(dirname "$P12_PATH")"
P12_PATH="$P12_PATH" python3 - <<'PY'
import base64
import os
from pathlib import Path

Path(os.environ["P12_PATH"]).write_bytes(
    base64.b64decode(os.environ["APPLE_DEVELOPER_ID_CERTIFICATE_P12_BASE64"])
)
PY

security create-keychain -p "$APPLE_KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$APPLE_KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$P12_PATH" \
  -P "$APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD" \
  -A \
  -t cert \
  -f pkcs12 \
  -k "$KEYCHAIN_PATH"
security list-keychains -d user -s "$KEYCHAIN_PATH" $(security list-keychains -d user | tr -d '"')
security set-key-partition-list -S apple-tool:,apple: -s -k "$APPLE_KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security find-identity -v -p codesigning "$KEYCHAIN_PATH"

rm -f "$P12_PATH"
