#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build --product LocateAppCoreChecks
BIN_DIR="$(swift build --show-bin-path)"
CHECKS_BIN="$BIN_DIR/LocateAppCoreChecks"

if [[ ! -x "$CHECKS_BIN" ]]; then
  echo "Missing built LocateAppCoreChecks executable: $CHECKS_BIN" >&2
  exit 1
fi

if command -v otool >/dev/null; then
  otool -L "$CHECKS_BIN"
fi

if command -v codesign >/dev/null; then
  codesign --verify --strict --verbose=2 "$CHECKS_BIN" || true
  codesign --force --sign - "$CHECKS_BIN"
  codesign --verify --strict --verbose=2 "$CHECKS_BIN"
fi

"$CHECKS_BIN"
