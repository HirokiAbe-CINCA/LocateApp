#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

rm -rf \
  .build \
  .pytest_cache \
  locateapp.egg-info \
  src/locateapp.egg-info

find . \
  -path './.venv' -prune -o \
  -path './dist' -prune -o \
  -type d -name '__pycache__' -prune -exec rm -rf {} +

echo "Removed generated build/test caches. Kept .venv and dist."
