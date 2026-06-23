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

For a self-contained app bundle that can be copied to another Mac without a
repo-local `.venv`, bundle the helper:

```bash
BUNDLE_HELPER=1 CONFIGURATION=release ./scripts/build_app_bundle.sh
```

In the app:

1. Connect and unlock the iPhone.
2. Search for a place by name, enter `lat, lon`, or click a point on the map.
3. Click `この場所に移動`.
4. Approve the macOS administrator prompt if it appears.

Use `接続を確認` only when the iPhone status does not update after connecting or
unlocking the device. The app prepares the iPhone communication path
automatically when `この場所に移動` or `移動を解除` needs it.

`この場所に移動` detaches the location-setting process and writes PID/log
files under `.locateapp/`. While a moved location is active, the app asks macOS
to keep the system awake so the iPhone developer connection can continue. The
display may still dim or turn off. Closing a MacBook lid can still put the Mac
to sleep.

The simulated location depends on the Mac-side process, the USB cable, and the
iPhone developer connection. Unplugging the cable, closing a MacBook lid,
putting the Mac to sleep, quitting the app, shutting down the Mac, or restarting
the iPhone can clear the simulated location.

LocateApp monitors the stored tunnel and set-location process while a moved
location is active. If the tunnel closes or the helper process stops, the app
automatically tries to rebuild the developer connection and reapply the previous
coordinate up to three times, waiting 10 seconds between retries. If recovery
succeeds, the moved location remains active. If recovery fails or administrator
authorization is canceled, the app marks the current movement as uncertain
instead of continuing to present it as definitely active. When that happens,
reconnect and unlock the iPhone, then use `前回の場所へ再移動` to rebuild the
developer connection and apply the previous coordinate again.

`移動を解除` terminates the stored set-location process and sends the DVT
clear-location command through a recovered tunnel when needed. If the iPhone is
not reachable and the simulated location still appears active, restart the
iPhone to force iOS to clear the simulated location.

Use `診断情報` to inspect `.locateapp/tunnel.out`, `.locateapp/tunnel.err`,
`.locateapp/set.out`, and `.locateapp/set.err` when the tunnel or location set
command fails.

## After Relaunch, Sleep, or Reconnect

1. Open the app and check `現在の移動先`.
2. If it says `前回の移動先が残っている可能性`, assume the iPhone may still
   be using the simulated location, but it may also have been cleared when the
   Mac slept, the MacBook lid was closed, the cable was unplugged, or the helper
   process stopped.
3. To restore the same simulated location, connect and unlock the iPhone, then
   use `前回の場所へ再移動`.
4. To return to normal location, use `移動を解除` with the iPhone connected
   and unlocked.
5. If reset cannot reach the iPhone, restart the iPhone. iOS restart is the
   authoritative fallback for clearing simulated location.

Local debug builds are ad-hoc signed. Release packages embed the
`pymobiledevice3` helper inside the app bundle, so the app can run without a
repo-local `.venv`.

## Install from GitHub Releases

Download the latest `LocateApp-*-mac-arm64.dmg` or `.zip` from
[GitHub Releases](https://github.com/HirokiAbe-CINCA/LocateApp/releases).
Open the DMG or unzip the archive, then copy `LocateApp.app` to `/Applications`.
Signed release builds use Sparkle for automatic in-app updates. On launch,
LocateApp silently checks the published appcast feed and only surfaces Sparkle UI
when an update needs attention. Sparkle can download and install newer signed
ZIP updates in the background when macOS allows it.

Current release builds are Developer ID signed and notarized, so macOS should
allow normal first launch after copying `LocateApp.app` to `/Applications`.
Older pre-notarization builds may still require right-clicking `LocateApp.app`
and choosing `Open`. The embedded helper is intentionally self-contained;
commands such as Refresh or Reset can take longer than repo-local development
builds while the helper starts.

Release artifacts are produced by pushing a version tag:

```bash
git tag v0.1.0
git push origin v0.1.0
```

The Release workflow uploads the styled DMG, ZIP, `SHA256SUMS.txt`, and
`appcast.xml`. The appcast is also deployed to GitHub Pages for Sparkle:

```text
https://hirokiabe-cinca.github.io/LocateApp/appcast.xml
```

GitHub tag releases require Apple Developer ID/notarization secrets and Sparkle
EdDSA key secrets. They fail if notarization or automatic-update appcast
generation cannot complete. See `docs/notarization.md` for the required account
steps and secret names.

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
- Location simulation should be treated as active only while the Mac is awake,
  the app/helper process is running, and the iPhone remains connected by USB.
  On MacBooks, keep the lid open unless macOS is kept awake by clamshell mode.
- Reset may ask for administrator approval again while it cleans up the RSD
  tunnel process.
- If a future iOS or `pymobiledevice3` release changes this behavior, the app
  should fall back to the official Xcode route. See
  `docs/ios-compatibility-strategy.md`.

## Verification

```bash
bash scripts/run_swift_core_checks.sh
.venv/bin/python -m pytest
./scripts/build_app_bundle.sh
./scripts/e2e_smoke.sh
```

The E2E smoke test launches the local app and verifies the user-facing
connection and movement UI without changing a real iPhone location.
