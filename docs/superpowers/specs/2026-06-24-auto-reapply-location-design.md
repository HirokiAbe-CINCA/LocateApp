# Auto Reapply Location Design

## Goal

LocateApp should automatically recover a moved iPhone location when the active
RSD tunnel or set-location helper process disappears briefly. Recovery should
reuse the last active coordinate, avoid unnecessary work while the connection is
healthy, and fall back to the current "may have been cleared" state when the app
cannot recover.

## User Experience

When a moved location is active, LocateApp continues its existing continuity
monitoring. If monitoring detects a closed tunnel or stopped set-location
process, the app starts an automatic recovery sequence instead of immediately
marking the location as uncertain.

The first recovery attempt starts immediately. If it fails, the app waits 10
seconds and tries again, up to three total attempts. Status text shows progress
such as `自動再接続中です... 1/3` so the user can tell that the app is actively
working. If recovery succeeds, the app keeps the previous coordinate active,
refreshes the Mac sleep assertion, and shows that the location was restored.

If all three attempts fail, LocateApp returns to the current uncertain state:
the previous coordinate remains visible, `前回の場所へ再移動` is available, the
cached tunnel endpoint is cleared, and sleep prevention stops. If the user
cancels the administrator authorization prompt, LocateApp treats that as an
intentional stop and falls back immediately without retrying.

## Architecture

The existing `AppModel.startLocationContinuityMonitoring()` loop remains the
entry point. `checkActiveLocationContinuity()` still asks
`LocationSessionController` whether the stored tunnel and set-location process
are running, then delegates unhealthy assessments to a new recovery path.

The recovery path reuses the same operations as manual reapply:

1. Keep the current `activeCoordinate` as the target coordinate.
2. Rebuild the RSD tunnel with `ensureTunnel(forceRestart: true)`.
3. Run `session.prepare(endpoint:)`.
4. Run `session.setLocation(endpoint:coordinate:)`.
5. Reacquire sleep prevention and clear any recovery state.

To keep retry behavior testable, retry constants and decision logic live in
small pure Swift types in `LocateAppCore`. `AppModel` owns the async execution,
UI status updates, and cancellation checks because it already owns session,
device, endpoint, sleep, and user-facing error state.

## Recovery Policy

- Maximum attempts: 3.
- Delay before retry attempts 2 and 3: 10 seconds.
- Attempt 1 runs immediately after an unhealthy continuity assessment.
- No concurrent recovery sequences are allowed. If the 10-second monitor fires
  again while recovery is running, it does nothing.
- Recovery only starts when `activeCoordinate != nil`, `activeLocationMayRemain`
  is false, and the app is not busy.
- User-cancelled administrator authorization is non-retryable.
- Other errors are retryable until the attempt limit is reached.
- Reset and manual reapply should not race with auto recovery; existing busy
  checks and a recovery task flag block duplicate work.

## Error Handling

On retryable failure, LocateApp keeps the active coordinate displayed and updates
status with the attempt count and the user-facing error. The app does not mark
the location uncertain until the final failure.

On final failure or administrator cancellation, LocateApp calls the same
uncertain-state path used today. That path clears the cached RSD endpoint,
stops sleep prevention, and preserves the active coordinate for manual reapply.

## Testing

Core checks should cover:

- The retry policy returns attempt numbers 1, 2, and 3.
- Retry delay is 0 seconds before attempt 1 and 10 seconds before attempts 2
  and 3.
- Attempt 4 is not allowed.
- User-cancelled errors are classified as non-retryable.

App-level checks are constrained by SwiftUI and real device dependencies, so the
implementation should keep most policy behavior pure and covered by
`LocateAppCoreChecks`. Manual and E2E smoke verification should confirm that the
main UI still launches, displays connection and movement controls, and does not
attempt a real iPhone location change during smoke tests.

Local SwiftPM verification may be blocked by the existing Command Line Tools
`PackageDescription` link error documented in the Sparkle auto-update work. When
that happens, record the exact failure and rely on CI Swift checks after opening
the PR.

## Out Of Scope

- Background recovery while LocateApp is not running.
- Changing iOS or pymobiledevice3 behavior.
- Reapplying coordinates on a timer while the connection is healthy.
- Adding a user preference for retry count or retry interval.
- Retrying after the user cancels administrator authorization.
