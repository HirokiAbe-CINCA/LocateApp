# Auto Reapply Location Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically recover the active simulated iPhone location when the stored RSD tunnel or set-location process stops, retrying up to three times before falling back to the existing uncertain state.

**Architecture:** Add small, testable recovery policy helpers to `LocateAppCore`, then wire the existing `AppModel` continuity monitor to run one recovery task at a time. Recovery reuses the manual reapply path: rebuild tunnel, prepare developer services, set the previous coordinate, and reacquire sleep prevention.

**Tech Stack:** Swift 6 / SwiftPM, SwiftUI/AppKit app model, `LocateAppCoreChecks`, bash E2E smoke script, Python pytest for existing CLI checks.

---

## File Structure

- Modify `Sources/LocateAppCore/LocationContinuity.swift`: add pure retry policy, status text, and cancellation classification helpers next to existing continuity assessment types.
- Modify `Sources/LocateAppCoreChecks/main.swift`: add failing checks for retry attempt sequence, delay policy, retry limit, and non-retryable cancellation.
- Modify `Sources/LocateApp/AppModel.swift`: add one recovery task flag, cancel it on deinit, avoid duplicate recovery work, run the three-attempt recovery sequence, and keep reset/manual reapply from racing recovery.
- Modify `README.md`: update the behavior description so users know LocateApp now tries automatic recovery before showing the manual reapply state.
- Modify `scripts/e2e_smoke.sh`: assert the UI still exposes the existing controls and does not surface stale removed copy; keep it smoke-only with no real location change.

Local SwiftPM is currently blocked by the existing Command Line Tools `PackageDescription` link error. Run the Swift commands anyway and record the failure if it persists; rely on GitHub Actions Swift checks after PR creation.

---

### Task 1: Core Recovery Policy

**Model selection:** fast implementation model is acceptable; this task is isolated and mechanical. Use high-performance review afterward.

**Files:**
- Modify: `Sources/LocateAppCore/LocationContinuity.swift`
- Test: `Sources/LocateAppCoreChecks/main.swift`

- [ ] **Step 1: Write the failing core checks**

Add these checks after the existing `LocationReapplyPrompt` checks in `Sources/LocateAppCoreChecks/main.swift`:

```swift
    let recoveryPolicy = LocationAutoRecoveryPolicy()
    try check(
        recoveryPolicy.maxAttempts == 3,
        "auto recovery should allow three attempts"
    )
    try check(
        recoveryPolicy.attempts.map(\.number) == [1, 2, 3],
        "auto recovery attempts should be numbered 1 through 3"
    )
    try check(
        recoveryPolicy.delayBeforeAttempt(1) == 0,
        "first auto recovery attempt should run immediately"
    )
    try check(
        recoveryPolicy.delayBeforeAttempt(2) == 10,
        "second auto recovery attempt should wait 10 seconds"
    )
    try check(
        recoveryPolicy.delayBeforeAttempt(3) == 10,
        "third auto recovery attempt should wait 10 seconds"
    )
    try check(
        recoveryPolicy.delayBeforeAttempt(4) == nil,
        "fourth auto recovery attempt should not be allowed"
    )
    try check(
        recoveryPolicy.progressText(for: LocationAutoRecoveryAttempt(number: 2, total: 3)) == "自動再接続中です... 2/3",
        "auto recovery progress text mismatch"
    )
    try check(
        LocationAutoRecoveryErrorClassifier.isUserCancellation(
            "管理者認証がキャンセルされました。もう一度実行し、表示された認証を承認してください。"
        ),
        "Japanese administrator cancellation should be non-retryable"
    )
    try check(
        LocationAutoRecoveryErrorClassifier.isUserCancellation("User canceled."),
        "English user cancellation should be non-retryable"
    )
    try check(
        LocationAutoRecoveryErrorClassifier.isUserCancellation("osascript error -128"),
        "AppleScript -128 cancellation should be non-retryable"
    )
    try check(
        !LocationAutoRecoveryErrorClassifier.isUserCancellation("No route to host"),
        "ordinary connection errors should remain retryable"
    )
```

- [ ] **Step 2: Run the check and verify RED**

Run:

```bash
bash scripts/run_swift_core_checks.sh
```

Expected local result: either compile failure mentioning missing `LocationAutoRecoveryPolicy` / `LocationAutoRecoveryAttempt`, or the known local SwiftPM `PackageDescription` link error. If the known link error appears before compiling sources, record it and proceed with the TDD intent documented.

- [ ] **Step 3: Implement the minimal core policy**

Append these public types to `Sources/LocateAppCore/LocationContinuity.swift`:

```swift
public struct LocationAutoRecoveryAttempt: Equatable, Sendable {
    public let number: Int
    public let total: Int

    public init(number: Int, total: Int) {
        self.number = number
        self.total = total
    }
}

public struct LocationAutoRecoveryPolicy: Equatable, Sendable {
    public let maxAttempts: Int
    public let retryDelaySeconds: TimeInterval

    public init(maxAttempts: Int = 3, retryDelaySeconds: TimeInterval = 10) {
        self.maxAttempts = maxAttempts
        self.retryDelaySeconds = retryDelaySeconds
    }

    public var attempts: [LocationAutoRecoveryAttempt] {
        guard maxAttempts > 0 else {
            return []
        }
        return (1...maxAttempts).map { LocationAutoRecoveryAttempt(number: $0, total: maxAttempts) }
    }

    public func delayBeforeAttempt(_ attemptNumber: Int) -> TimeInterval? {
        guard attemptNumber >= 1, attemptNumber <= maxAttempts else {
            return nil
        }
        return attemptNumber == 1 ? 0 : retryDelaySeconds
    }

    public func progressText(for attempt: LocationAutoRecoveryAttempt) -> String {
        "自動再接続中です... \(attempt.number)/\(attempt.total)"
    }
}

public enum LocationAutoRecoveryErrorClassifier {
    public static func isUserCancellation(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("User canceled") ||
            message.localizedCaseInsensitiveContains("キャンセル") ||
            message.localizedCaseInsensitiveContains("(-128)") ||
            message.localizedCaseInsensitiveContains("-128")
    }
}
```

- [ ] **Step 4: Run the core check again**

Run:

```bash
bash scripts/run_swift_core_checks.sh
```

Expected: pass in a healthy SwiftPM environment. In this local environment, the known `PackageDescription` link error may persist before source compilation; record it exactly.

- [ ] **Step 5: Commit Task 1**

Run:

```bash
git add Sources/LocateAppCore/LocationContinuity.swift Sources/LocateAppCoreChecks/main.swift
git commit -m "feat: add automatic recovery policy"
```

---

### Task 2: AppModel Auto Recovery Integration

**Model selection:** standard or high-performance implementation model; this task coordinates async state, UI status, and process control. Use high-performance review afterward.

**Files:**
- Modify: `Sources/LocateApp/AppModel.swift`

- [ ] **Step 1: Add recovery state fields**

Add these properties near `locationContinuityTask`:

```swift
    private let autoRecoveryPolicy = LocationAutoRecoveryPolicy()
    private var autoRecoveryTask: Task<Void, Never>?
```

Update `deinit`:

```swift
    deinit {
        locationContinuityTask?.cancel()
        autoRecoveryTask?.cancel()
    }
```

- [ ] **Step 2: Prevent manual actions from racing recovery**

At the start of `reapplyActiveLocation()` and `resetLocation()`, before `runBusy`, add:

```swift
        cancelAutoRecovery()
```

- [ ] **Step 3: Route unhealthy continuity assessments into recovery**

Replace the `.uncertain` cases in `checkActiveLocationContinuity()` with:

```swift
        case .uncertain(let issue):
            startAutoRecovery(issue: issue)
```

Also extend the guard to avoid duplicate work:

```swift
              !isBusy,
              autoRecoveryTask == nil else {
            return
        }
```

- [ ] **Step 4: Add the recovery methods**

Add these private methods before `markActiveLocationUncertain(reason:)`:

```swift
    private func startAutoRecovery(issue: LocationContinuityIssue) {
        guard autoRecoveryTask == nil,
              let coordinate = activeCoordinate,
              !activeLocationMayRemain,
              !isBusy else {
            return
        }

        autoRecoveryTask = Task { [weak self] in
            await self?.runAutoRecovery(issue: issue, coordinate: coordinate)
        }
    }

    private func runAutoRecovery(issue: LocationContinuityIssue, coordinate: Coordinate) async {
        defer {
            autoRecoveryTask = nil
        }

        for attempt in autoRecoveryPolicy.attempts {
            guard !Task.isCancelled else {
                return
            }

            if let delay = autoRecoveryPolicy.delayBeforeAttempt(attempt.number), delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            guard !Task.isCancelled,
                  activeCoordinate == coordinate,
                  !activeLocationMayRemain else {
                return
            }

            status = autoRecoveryPolicy.progressText(for: attempt)

            do {
                let endpoint = try await ensureTunnel(forceRestart: true)
                try await session.prepare(endpoint: endpoint)
                try await session.setLocation(endpoint: endpoint, coordinate: coordinate)
                activeCoordinate = coordinate
                activeLocationMayRemain = false
                status = "自動再接続しました。Macが起きていてUSB接続が続く間、この場所が使われます。\(startSleepPreventionStatus())"
                return
            } catch {
                rsdEndpoint = nil
                rsdDeviceID = nil
                let message = userFacingMessage(for: error)
                if LocationAutoRecoveryErrorClassifier.isUserCancellation(message) {
                    markActiveLocationUncertain(reason: message)
                    return
                }
                if attempt.number == autoRecoveryPolicy.maxAttempts {
                    markActiveLocationUncertain(reason: uncertainReason(for: issue))
                    return
                }
                status = "\(autoRecoveryPolicy.progressText(for: attempt)) 失敗しました: \(message)"
            }
        }
    }

    private func cancelAutoRecovery() {
        autoRecoveryTask?.cancel()
        autoRecoveryTask = nil
    }

    private func uncertainReason(for issue: LocationContinuityIssue) -> String {
        switch issue {
        case .tunnelClosed:
            return "iPhoneとの通信トンネルが切れました。位置情報がすでに解除されている可能性があります。iPhone接続後に「前回の場所へ再移動」または「移動を解除」を選んでください。"
        case .setProcessStopped:
            return "Mac側の位置設定プロセスが停止しました。位置情報がすでに解除されている可能性があります。iPhone接続後に「前回の場所へ再移動」または「移動を解除」を選んでください。"
        }
    }
```

- [ ] **Step 5: Keep uncertain transition deterministic**

At the start of `markActiveLocationUncertain(reason:)`, add:

```swift
        cancelAutoRecovery()
```

Then verify the method still preserves `activeCoordinate`, clears `rsdEndpoint` and `rsdDeviceID`, stops sleep prevention, and sets `status`.

- [ ] **Step 6: Run verification**

Run:

```bash
bash scripts/run_swift_core_checks.sh
.venv/bin/python -m pytest
```

Expected: Python tests pass. Swift checks pass in a healthy SwiftPM environment or hit only the known local `PackageDescription` link error.

- [ ] **Step 7: Commit Task 2**

Run:

```bash
git add Sources/LocateApp/AppModel.swift
git commit -m "feat: automatically reapply active location"
```

---

### Task 3: Docs and Smoke Coverage

**Model selection:** fast implementation model for docs/script edits; high-performance review afterward.

**Files:**
- Modify: `README.md`
- Modify: `scripts/e2e_smoke.sh`

- [ ] **Step 1: Update README behavior copy**

Replace the paragraph at `README.md:64-69` with:

```markdown
LocateApp monitors the stored tunnel and set-location process while a moved
location is active. If the tunnel closes or the helper process stops, the app
automatically tries to rebuild the developer connection and reapply the previous
coordinate up to three times, waiting 10 seconds between retries. If recovery
succeeds, the moved location remains active. If recovery fails or administrator
authorization is canceled, the app marks the current movement as uncertain
instead of continuing to present it as definitely active. When that happens,
reconnect and unlock the iPhone, then use `前回の場所へ再移動` to rebuild the
developer connection and apply the previous coordinate again.
```

- [ ] **Step 2: Extend smoke assertions without changing real device state**

In `scripts/e2e_smoke.sh`, after the existing `assertNotContains(visibleText, "ログ")`, add:

```applescript
    my assertNotContains(visibleText, "自動再接続中です")
    my assertNotContains(visibleText, "自動再接続しました")
```

This confirms the app does not start recovery on a fresh launch with no active coordinate.

- [ ] **Step 3: Run docs/script verification**

Run:

```bash
bash -n scripts/e2e_smoke.sh
.venv/bin/python -m pytest
```

Expected: shell syntax check passes and Python tests pass.

- [ ] **Step 4: Run E2E smoke**

Run:

```bash
./scripts/e2e_smoke.sh
```

Expected: local app launches and the script prints `LocateApp E2E smoke passed`. If local SwiftPM build is blocked by the known `PackageDescription` error, record the failure and rely on CI E2E if available.

- [ ] **Step 5: Commit Task 3**

Run:

```bash
git add README.md scripts/e2e_smoke.sh
git commit -m "docs: describe automatic location recovery"
```

---

## Final Verification

- [ ] Run `.venv/bin/python -m pytest`.
- [ ] Run `bash -n scripts/build_app_bundle.sh scripts/build_helper.sh scripts/clean_generated.sh scripts/e2e_smoke.sh scripts/import_apple_certificate.sh scripts/package_release.sh scripts/verify_release_artifacts.sh scripts/generate_sparkle_appcast.sh scripts/run_swift_core_checks.sh`.
- [ ] Run `bash scripts/run_swift_core_checks.sh` and record whether it passes or is blocked by the known local `PackageDescription` link error.
- [ ] Run `./scripts/e2e_smoke.sh` and record whether it passes or is blocked by the same local SwiftPM issue.
- [ ] Dispatch high-performance final review across the complete diff before PR creation.
- [ ] Open a PR, wait for GitHub checks, fix failures if any, then merge.
- [ ] Deploy by creating and pushing the next version tag only if the user confirms the release version and required Apple/Sparkle secrets are available; otherwise record deployment as blocked by missing release confirmation/secrets.
- [ ] Clean local generated files with `./scripts/clean_generated.sh`, remove the worktree after merge, and prune stale worktrees.
