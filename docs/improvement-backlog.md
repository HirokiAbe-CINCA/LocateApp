# LocateApp Improvement Backlog

## Product View

- Search a destination by name, choose from results, and move the map pin there.
- Show selected destination, current moved location, iPhone connection state, and state/log folder separately.
- Offer direct coordinate entry for users who already know latitude/longitude.
- Make reset a reliable safety action even after relaunch, cable reconnect, or stale tunnel state.
- Make every destructive or privileged action explain what will happen before macOS asks for approval.

## UX Designer View

- The first screen should be the usable tool: map on the left, compact control surface on the right.
- Primary action should be singular and obvious: `Move iPhone Here`.
- Search should sit above the map controls, not hidden in settings.
- The UI should distinguish selected destination from current moved location to avoid accidental changes.
- Busy states should say what the app is waiting for: device, SMAppService approval, tunnel, DDI, or set process.
- Raw technical logs should be available but not dominate the panel.

## CTO View

- Treat the Xcode-less route as a backend adapter, not as the product contract.
- Preserve an adapter boundary so an official Xcode/DeveloperDiskImage route can be added if iOS breaks `pymobiledevice3`.
- Never kill a PID unless the command line matches the app-managed process.
- Store session state on disk so app relaunch does not hide active spoof state.
- Keep CLI PoC tests and Swift command checks green before every release.
- Add E2E smoke coverage that launches the `.app` and verifies the user-facing controls are reachable.

## Deferred Decisions

- Whether the GitHub repository should be public or private. Default is private for now.
- Whether to keep producing lightweight repo-local debug app bundles, or make
  helper/tunneld bundling the default for all local app builds.
- Harden the bundled `LocateTunneldDaemon` IPC further with an app-owned XPC
  protocol and code-signing checks. The current LaunchDaemon already avoids the
  generic `pymobiledevice3 remote tunneld` HTTP API and exposes only a
  root/admin Unix-domain socket with limited start/list/stop commands.
- Whether to implement the official Xcode route as a fallback now or only after a compatibility break.
