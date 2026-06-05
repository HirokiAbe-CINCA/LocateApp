# iOS Compatibility Strategy

LocateApp should treat iPhone location control as a backend adapter, not as a
single permanent implementation.

## Current Adapter: Xcode-less pymobiledevice3

- Discovers USB devices through `pymobiledevice3 usbmux list`.
- Starts an iOS 17+ RSD tunnel through `lockdown start-tunnel --script-mode`.
- Uses DVT developer services to set and clear simulated location.
- Keeps the set-location process detached so the selected location survives
  closing the Mac app.

This adapter is the MVP path because the target iPhone/iOS combination already
accepted the CLI proof.

## Failure Signals

The app should assume the Xcode-less adapter may be broken when any of these
start appearing repeatedly:

- RSD tunnel cannot start even with Developer Mode enabled and the device trusted.
- Developer Disk Image auto-mount fails for a newly released iOS version.
- `simulate-location set` exits immediately after launch.
- DVT clear-location fails after a successful set on the same device.
- `pymobiledevice3` changes command names or RSD argument behavior.

## Product Behavior

- Keep `Reset Location` as the safety action. It must always stop the local
  set-location process before attempting network/device cleanup.
- If clear-location cannot reach the iPhone, tell the user that restarting the
  iPhone is the authoritative recovery path.
- Keep state and logs under `.locateapp/` so support/debugging can inspect the
  last tunnel and set-location attempts.
- Do not hide backend errors behind generic failure text; compatibility breaks
  need actionable logs.

## Future Adapter: Official Xcode Route

If the Xcode-less adapter breaks for supported users, add a second backend that
uses Apple's official developer tooling route. The UI contract should stay the
same:

1. Pick a place.
2. Move iPhone here.
3. Reset location.

Backend selection can later become:

- `Automatic`: try Xcode-less first, fall back to official route when available.
- `Xcode-less`: force the current `pymobiledevice3` route.
- `Official`: force the Apple tooling route.

For MVP, this remains a documented fallback rather than a visible setting.
