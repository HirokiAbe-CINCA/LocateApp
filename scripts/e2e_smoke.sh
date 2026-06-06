#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${SMOKE_APP:-$ROOT/dist/LocateApp.app}"

cd "$ROOT"

if [[ -z "${SMOKE_APP:-}" ]]; then
  ./scripts/build_app_bundle.sh >/dev/null
fi

osascript -e 'tell application "LocateApp" to quit' >/dev/null 2>&1 || true
sleep 1
open "$APP"

osascript <<'APPLESCRIPT'
on assertContains(valueText, expectedText)
  if valueText does not contain expectedText then
    error "Expected '" & valueText & "' to contain '" & expectedText & "'"
  end if
end assertContains

tell application "System Events"
  repeat 40 times
    if exists process "LocateApp" then exit repeat
    delay 0.25
  end repeat

  tell process "LocateApp"
    set frontmost to true
    repeat 40 times
      if exists window 1 then exit repeat
      delay 0.25
    end repeat
    delay 1

    if not (exists static text "1. 場所を選ぶ" of scroll area 1 of group 1 of window 1) then
      error "Expected the place selection step to be visible"
    end if
    if not (exists static text "2. iPhoneに固定" of scroll area 1 of group 1 of window 1) then
      error "Expected the iPhone fixing step to be visible"
    end if
    tell window 1
      set panel to scroll area 1 of group 1
      click button 1 of group 4 of panel
      delay 1
      set selectedAfterTokyo to value of static text 2 of group 3 of panel
      my assertContains(selectedAfterTokyo, "35.681236")

      click button 2 of group 4 of panel
      delay 1
      set selectedAfterPreset to value of static text 2 of group 3 of panel
      my assertContains(selectedAfterPreset, "35.659494")

      click button 4 of group 4 of panel
      delay 1
      set selectedAfterApplePark to value of static text 2 of group 3 of panel
      my assertContains(selectedAfterApplePark, "37.334900")
    end tell
  end tell
end tell

tell application "LocateApp" to quit
APPLESCRIPT

echo "LocateApp E2E smoke passed"
