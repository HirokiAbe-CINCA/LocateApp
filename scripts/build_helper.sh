#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER_NAME="pymobiledevice3-helper"
DIST_DIR="${HELPER_DIST_DIR:-$ROOT/build/helper-dist}"
WORK_DIR="${HELPER_WORK_DIR:-$ROOT/build/helper-build}"
SPEC_DIR="${HELPER_SPEC_DIR:-$ROOT/build/helper-spec}"

cd "$ROOT"

if [[ ! -x "$ROOT/.venv/bin/pyinstaller" ]]; then
  cat >&2 <<'MESSAGE'
Missing .venv/bin/pyinstaller.

Run:
  python3.13 -m venv .venv
  .venv/bin/python -m pip install -e '.[dev]'
MESSAGE
  exit 1
fi

if [[ ! -x "$ROOT/.venv/bin/pymobiledevice3" ]]; then
  cat >&2 <<'MESSAGE'
Missing .venv/bin/pymobiledevice3.

Run:
  python3.13 -m venv .venv
  .venv/bin/python -m pip install -e '.[dev]'
MESSAGE
  exit 1
fi

rm -rf "$DIST_DIR/$HELPER_NAME" "$WORK_DIR/$HELPER_NAME" "$SPEC_DIR/$HELPER_NAME.spec"
mkdir -p "$DIST_DIR" "$WORK_DIR" "$SPEC_DIR"

"$ROOT/.venv/bin/pyinstaller" \
  --onedir \
  --name "$HELPER_NAME" \
  --recursive-copy-metadata pymobiledevice3 \
  --collect-submodules pymobiledevice3 \
  --collect-data pymobiledevice3 \
  --distpath "$DIST_DIR" \
  --workpath "$WORK_DIR" \
  --specpath "$SPEC_DIR" \
  "$ROOT/.venv/bin/pymobiledevice3"

codesign --force --sign - "$DIST_DIR/$HELPER_NAME/$HELPER_NAME"
codesign --verify --verbose=2 "$DIST_DIR/$HELPER_NAME/$HELPER_NAME"

echo "$DIST_DIR/$HELPER_NAME"
