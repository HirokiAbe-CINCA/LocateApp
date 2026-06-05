# LocateApp macOS Design

## Goal

Build a small macOS app that lets the user pick a location on a map and set the connected iPhone's simulated location there without relying on Xcode as the runtime mechanism.

## User Workflow

1. Open LocateApp.
2. Confirm the connected iPhone is visible.
3. Click a place on the map.
4. Press "Move iPhone Here".
5. The app starts or reuses an RSD tunnel, runs the DVT location simulation command, and keeps the simulation process alive.
6. The iPhone stays fixed at that coordinate until the user presses "Reset Location", stops the helper processes, or restarts the iPhone.

## Architecture

The app is a SwiftPM macOS executable with a pure Swift core library and a SwiftUI app target. The core library builds commands and parses CLI output. The app target owns UI state, process lifecycle, and MapKit interaction.

The existing Python environment remains the device-control backend:

- `.venv/bin/pymobiledevice3` lists devices, starts RSD tunnel, mounts DDI, sets location, and clears location.
- The app runs tunnel startup through `osascript ... with administrator privileges` because iOS 17+ tunnel creation requires root.
- The app stores tunnel and set process state under `.locateapp/`.

## Components

- `LocateAppCore`
  - Finds the project root and helper binaries.
  - Builds device, tunnel, set, and clear commands.
  - Parses `usbmux list`, RSD `HOST PORT`, and process state files.
  - Validates coordinates.

- `LocateApp`
  - SwiftUI window with an `MKMapView` bridge.
  - Device status panel.
  - Buttons for refresh, start tunnel, move, and reset.
  - Long-running process management for the active set-location process.

## Error Handling

The UI exposes short actionable states:

- No device visible: ask user to connect/unlock/trust iPhone.
- Developer Mode disabled: ask user to enable it.
- Tunnel requires password: macOS admin prompt appears.
- Tunnel output missing: show recent tunnel log.
- Set location fails: show stderr and keep prior state unchanged.

## Testing

Automated tests cover command construction, parsing, validation, root discovery, and state-file parsing. UI behavior is verified by building/running the app locally because MapKit UI is not reliable to unit-test in this environment.

## Constraints

This version assumes the repository-local `.venv` exists and includes `pymobiledevice3`. It creates a usable local app prototype, not a signed standalone installer. Packaging Python and notarizing are later work.
