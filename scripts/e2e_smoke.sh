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

on assertNotContains(valueText, unexpectedText)
  if valueText contains unexpectedText then
    error "Expected UI text not to contain '" & unexpectedText & "'"
  end if
end assertNotContains

on textDump(uiElement)
  set outputText to ""
  try
    tell application "System Events" to set elementName to name of uiElement
    if elementName is not equal to missing value then
      set outputText to outputText & (elementName as text) & linefeed
    end if
  end try
  try
    tell application "System Events" to set elementValue to value of uiElement
    if elementValue is not equal to missing value then
      set outputText to outputText & (elementValue as text) & linefeed
    end if
  end try
  try
    tell application "System Events" to set childElements to UI elements of uiElement
    repeat with childElement in childElements
      set outputText to outputText & my textDump(childElement)
    end repeat
  end try
  return outputText
end textDump

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

    set visibleText to my textDump(window 1)
    my assertContains(visibleText, "iPhone")
    my assertContains(visibleText, "現在の移動先")
    my assertContains(visibleText, "選択中の移動先")
    my assertContains(visibleText, "35.681236")
    my assertNotContains(visibleText, "固定")
    my assertNotContains(visibleText, "反映")
    my assertNotContains(visibleText, "よく使う場所")
    my assertNotContains(visibleText, "通信を準備")
    my assertNotContains(visibleText, "ログ")
    my assertNotContains(visibleText, "自動再接続中です")
    my assertNotContains(visibleText, "自動再接続しました")

    tell window 1
      set panel to scroll area 1 of group 1
      if (count of groups of panel) is not 2 then
        error "Expected separate iPhone connection and destination groups"
      end if
      if (count of buttons of group 1 of panel) is not 1 then
        error "Expected connection section to expose only refresh as the primary action"
      end if
      if (count of text fields of group 2 of panel) is not 2 then
        error "Expected search and coordinate fields in destination group"
      end if
      set destinationButtonCount to count of buttons of group 2 of panel
      set expectedDestinationButtonCount to 3
      if (my textDump(group 2 of panel)) contains "前回の移動先の可能性" then
        set expectedDestinationButtonCount to 4
      end if
      if destinationButtonCount is not expectedDestinationButtonCount then
        error "Expected destination group to expose " & expectedDestinationButtonCount & " actions, got " & destinationButtonCount
      end if

      set focused of text field 2 of group 2 of panel to true
      set value of text field 2 of group 2 of panel to "35.659494, 139.700550"
      key code 36
      delay 1
      set selectedAfterCoordinateInput to my textDump(group 2 of panel)
      my assertContains(selectedAfterCoordinateInput, "35.659494")
    end tell
  end tell
end tell

tell application "LocateApp" to quit
APPLESCRIPT

echo "LocateApp E2E smoke passed"
