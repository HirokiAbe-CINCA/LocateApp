# LocateApp

Xcode-less Mac app for setting a connected iPhone's simulated location from a
simple map UI.

The backend is the same route proven by the CLI PoC: `pymobiledevice3` starts an
iOS RSD tunnel, checks Developer Mode, mounts developer services, then starts
`simulate-location set` for the chosen coordinate.

## Requirements

- macOS 14 or newer
- SwiftPM from the Command Line Tools toolchain
- Python 3.13 virtualenv with `pymobiledevice3`
- A USB-connected, trusted iPhone with Developer Mode enabled

Install the Python helper:

```bash
python3.13 -m venv .venv
.venv/bin/python -m pip install -e '.[dev]'
```

## Build and Run the Mac App

```bash
./scripts/build_app_bundle.sh
open dist/LocateApp.app
```

`build_app_bundle.sh` builds a debug app bundle by default to keep local
iteration light. Use `CONFIGURATION=release ./scripts/build_app_bundle.sh` when
you have enough free disk space and want a release build.

In the app:

1. Connect and unlock the iPhone.
2. Click `Refresh`.
3. Search for a place by name, choose a preset, enter `lat, lon`, or click a
   point on the map.
4. Click `Move iPhone Here`.
5. Approve the macOS administrator prompt when the RSD tunnel starts.

`Move iPhone Here` detaches the location-setting process and writes PID/log
files under `.locateapp/`. The simulated location is expected to remain active
after closing the Mac app, until the iPhone is restarted or `Reset Location` is
clicked in the app.

`Reset Location` terminates the stored set-location process and sends the DVT
clear-location command through a recovered tunnel when needed. If the iPhone is
not reachable and the simulated location still appears active, restart the
iPhone to force iOS to clear the simulated location.

Use `Open Logs` to inspect `.locateapp/tunnel.out`, `.locateapp/tunnel.err`,
`.locateapp/set.out`, and `.locateapp/set.err` when the tunnel or location set
command fails.

## After Relaunch, Sleep, or Reconnect

1. Open the app and check `Fixed`.
2. If it says `May still be active`, assume the iPhone may still be using the
   simulated location.
3. Use `Reset Location` with the iPhone connected and unlocked.
4. If reset cannot reach the iPhone, restart the iPhone. iOS restart is the
   authoritative fallback for clearing simulated location.

This `.app` is ad-hoc signed for local use. It is not notarized for distribution.
The app does not bundle `pymobiledevice3`; keep `dist/LocateApp.app` inside this
repository layout so it can find `.venv/bin/pymobiledevice3`.

## Cleanup

To recover local disk space without deleting the Python helper or the latest
local app bundle:

```bash
./scripts/clean_generated.sh
```

This removes SwiftPM and Python test/build caches, while keeping `.venv` and
`dist/LocateApp.app`.

## CLI Proof Tools

Check device visibility:

```bash
.venv/bin/locate-poc doctor
```

For iOS 17 and newer, keep a tunnel process running in another terminal. This
may require administrator approval:

```bash
sudo .venv/bin/pymobiledevice3 lockdown start-tunnel --script-mode --udid "$UDID"
```

The command prints:

```text
RSD_HOST RSD_PORT
```

Then dry-run the proof:

```bash
.venv/bin/locate-poc prove \
  --udid "$UDID" \
  --ios-major 17 \
  --rsd-host "$RSD_HOST" \
  --rsd-port "$RSD_PORT" \
  --lat 35.681236 \
  --lon 139.767125 \
  --dry-run
```

Run it for real:

```bash
.venv/bin/locate-poc prove \
  --udid "$UDID" \
  --ios-major 17 \
  --rsd-host "$RSD_HOST" \
  --rsd-port "$RSD_PORT" \
  --lat 35.681236 \
  --lon 139.767125
```

Use `--reset-after` during proof if you want to clear after setting. The default
hold is 5 seconds; pass `--hold-seconds` to change it:

```bash
.venv/bin/locate-poc prove \
  --udid "$UDID" \
  --ios-major 17 \
  --rsd-host "$RSD_HOST" \
  --rsd-port "$RSD_PORT" \
  --lat 35.681236 \
  --lon 139.767125 \
  --reset-after \
  --hold-seconds 10
```

## Known Limits

- The app currently targets the proven iOS 17+ RSD/DVT route.
- The RSD tunnel still requires macOS administrator approval.
- Reset may ask for administrator approval again while it cleans up the RSD
  tunnel process.
- If a future iOS or `pymobiledevice3` release changes this behavior, the app
  should fall back to the official Xcode route. See
  `docs/ios-compatibility-strategy.md`.

## Verification

```bash
swift run LocateAppCoreChecks
.venv/bin/python -m pytest
./scripts/build_app_bundle.sh
./scripts/e2e_smoke.sh
```

The E2E smoke test launches the local app and verifies the user-facing preset
selection flow without changing a real iPhone location.
