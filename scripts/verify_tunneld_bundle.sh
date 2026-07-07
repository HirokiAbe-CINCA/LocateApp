#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${APP:-$ROOT/dist/LocateApp.app}"
PLIST="$APP/Contents/Library/LaunchDaemons/jp.cinca.LocateApp.tunneld.plist"
DAEMON="$APP/Contents/MacOS/LocateTunneldDaemon"
HELPER="$APP/Contents/Resources/pymobiledevice3-helper/pymobiledevice3-helper"
DAEMON_SOURCE="$ROOT/Sources/LocateTunneldDaemon/main.swift"

cd "$ROOT"

if [[ "${VERIFY_BUILD:-0}" =~ ^(1|true|yes)$ ]]; then
  BUNDLE_HELPER=1 ENABLE_TUNNELD=1 "$ROOT/scripts/build_app_bundle.sh" >/dev/null
fi

if [[ ! -d "$APP" ]]; then
  echo "Missing app bundle: $APP" >&2
  exit 1
fi
if [[ ! -f "$PLIST" ]]; then
  echo "Missing tunneld LaunchDaemon plist: $PLIST" >&2
  exit 1
fi
if [[ ! -x "$DAEMON" ]]; then
  echo "Missing LocateTunneldDaemon executable: $DAEMON" >&2
  exit 1
fi
if [[ ! -x "$HELPER" ]]; then
  echo "Missing pymobiledevice3 helper executable: $HELPER" >&2
  exit 1
fi

plutil -lint "$PLIST"
test "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$PLIST")" = "jp.cinca.LocateApp.tunneld"
test "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$PLIST")" = "Contents/MacOS/LocateTunneldDaemon"
if /usr/libexec/PlistBuddy -c 'Print :Program' "$PLIST" >/dev/null 2>&1; then
  echo "LaunchDaemon plist must not use Program" >&2
  exit 1
fi
if ! /usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$PLIST" | grep -Fq "LocateTunneldDaemon"; then
  echo "LaunchDaemon plist does not start LocateTunneldDaemon" >&2
  exit 1
fi
if /usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$PLIST" | grep -Eq "remote|--daemonize"; then
  echo "LaunchDaemon plist must not expose pymobiledevice3 remote tunneld directly" >&2
  exit 1
fi
grep -Fq '"lockdown"' "$DAEMON_SOURCE"
grep -Fq '"start-tunnel"' "$DAEMON_SOURCE"
grep -Fq '"--script-mode"' "$DAEMON_SOURCE"
if grep -Eq '"remote"|--daemonize' "$DAEMON_SOURCE"; then
  echo "LocateTunneldDaemon must not spawn pymobiledevice3 remote tunneld" >&2
  exit 1
fi

codesign --verify --strict --verbose=2 "$DAEMON"
codesign --verify --strict --verbose=2 "$HELPER"
codesign --verify --deep --strict --verbose=2 "$APP"
"$HELPER" --help >/dev/null

echo "LocateApp tunneld bundle verification passed"
