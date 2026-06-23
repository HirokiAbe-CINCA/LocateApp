# Launch Update Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run a Sparkle silent update check once when a configured release build launches.

**Architecture:** Add a small testable launch-check policy to `LocateAppCore`, exercise it from `LocateAppCoreChecks`, then have `LocateAppMain` call `checkForUpdatesInBackground()` after creating the `SPUStandardUpdaterController` when Sparkle reports automatic checks are enabled. Documentation notes that release builds check silently at launch.

**Tech Stack:** Swift 6, SwiftUI, Sparkle 2.9.3, Swift command checks, pytest.

---

### Task 1: Add Launch Update Check Policy

**Files:**
- Modify: `Sources/LocateAppCore/LocationContinuity.swift`
- Modify: `Sources/LocateAppCoreChecks/main.swift`

- [ ] **Step 1: Write the failing core check**

Add a helper check to `Sources/LocateAppCoreChecks/main.swift`:

```swift
private func checkLaunchUpdateCheckPolicy() throws {
    try check(
        AppLaunchUpdateCheckPolicy.shouldCheckOnLaunch(automaticallyChecksForUpdates: true),
        "launch update check should run when automatic checks are enabled"
    )
    try check(
        !AppLaunchUpdateCheckPolicy.shouldCheckOnLaunch(automaticallyChecksForUpdates: false),
        "launch update check should not run when automatic checks are disabled"
    )
}
```

Call it from the top-level check list before the final success print:

```swift
try checkLaunchUpdateCheckPolicy()
```

- [ ] **Step 2: Run the check to verify it fails**

Run:

```bash
rm -rf /tmp/LocateAppCoreChecksBuild && mkdir -p /tmp/LocateAppCoreChecksBuild
swiftc -emit-module -emit-library -module-name LocateAppCore Sources/LocateAppCore/LocationContinuity.swift Sources/LocateAppCore/SleepPrevention.swift Sources/LocateAppCore/LocateCore.swift Sources/LocateAppCore/LocateProcess.swift -emit-module-path /tmp/LocateAppCoreChecksBuild/LocateAppCore.swiftmodule -o /tmp/LocateAppCoreChecksBuild/libLocateAppCore.dylib
swiftc -I /tmp/LocateAppCoreChecksBuild -L /tmp/LocateAppCoreChecksBuild -lLocateAppCore -o /tmp/LocateAppCoreChecksBuild/LocateAppCoreChecks Sources/LocateAppCoreChecks/main.swift
DYLD_LIBRARY_PATH=/tmp/LocateAppCoreChecksBuild /tmp/LocateAppCoreChecksBuild/LocateAppCoreChecks
```

Expected: compile failure because `AppLaunchUpdateCheckPolicy` is not defined.

- [ ] **Step 3: Add minimal policy implementation**

Add to `Sources/LocateAppCore/LocationContinuity.swift`:

```swift
public struct AppLaunchUpdateCheckPolicy: Equatable, Sendable {
    public init() {}

    public static func shouldCheckOnLaunch(automaticallyChecksForUpdates: Bool) -> Bool {
        automaticallyChecksForUpdates
    }
}
```

- [ ] **Step 4: Run the check to verify it passes**

Run:

```bash
rm -rf /tmp/LocateAppCoreChecksBuild && mkdir -p /tmp/LocateAppCoreChecksBuild
swiftc -emit-module -emit-library -module-name LocateAppCore Sources/LocateAppCore/LocationContinuity.swift Sources/LocateAppCore/SleepPrevention.swift Sources/LocateAppCore/LocateCore.swift Sources/LocateAppCore/LocateProcess.swift -emit-module-path /tmp/LocateAppCoreChecksBuild/LocateAppCore.swiftmodule -o /tmp/LocateAppCoreChecksBuild/libLocateAppCore.dylib
swiftc -I /tmp/LocateAppCoreChecksBuild -L /tmp/LocateAppCoreChecksBuild -lLocateAppCore -o /tmp/LocateAppCoreChecksBuild/LocateAppCoreChecks Sources/LocateAppCoreChecks/main.swift
DYLD_LIBRARY_PATH=/tmp/LocateAppCoreChecksBuild /tmp/LocateAppCoreChecksBuild/LocateAppCoreChecks
```

Expected: `LocateAppCoreChecks passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/LocateAppCore/LocationContinuity.swift Sources/LocateAppCoreChecks/main.swift
git commit -m "feat: add launch update check policy"
```

### Task 2: Trigger Silent Sparkle Check At Launch

**Files:**
- Modify: `Sources/LocateApp/LocateApp.swift`
- Modify: `README.md`

- [ ] **Step 1: Write the failing app integration check**

Run this source check before changing `LocateApp.swift`:

```bash
rg -n "checkForUpdatesInBackground|AppLaunchUpdateCheckPolicy" Sources/LocateApp/LocateApp.swift
```

Expected: no matches for `checkForUpdatesInBackground` and no app-side reference to `AppLaunchUpdateCheckPolicy`.

- [ ] **Step 2: Implement the launch check**

Update `LocateAppMain.init()` so the configured updater path reads:

```swift
let controller = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: nil,
    userDriverDelegate: nil
)
updaterController = controller
if AppLaunchUpdateCheckPolicy.shouldCheckOnLaunch(
    automaticallyChecksForUpdates: controller.updater.automaticallyChecksForUpdates
) {
    controller.updater.checkForUpdatesInBackground()
}
```

Keep the existing `updaterController = nil` path unchanged for local builds
without Sparkle configuration.

- [ ] **Step 3: Document the behavior**

Update the Sparkle paragraph in `README.md` to say release builds perform a
silent update check at launch and only surface Sparkle UI when an update needs
attention.

- [ ] **Step 4: Verify source integration**

Run:

```bash
rg -n "checkForUpdatesInBackground|AppLaunchUpdateCheckPolicy" Sources/LocateApp/LocateApp.swift README.md
```

Expected: matches in `LocateApp.swift` and README.

- [ ] **Step 5: Verify app typecheck with a Sparkle stub**

Create a temporary stub outside the repo and typecheck the app:

```bash
cat > /tmp/SparkleStub.swift <<'SWIFT'
public class SPUUpdater {
    public var automaticallyChecksForUpdates: Bool = true
    public init() {}
    public func checkForUpdates() {}
    public func checkForUpdatesInBackground() {}
}

public class SPUStandardUpdaterController {
    public let updater: SPUUpdater
    public init(startingUpdater: Bool, updaterDelegate: Any?, userDriverDelegate: Any?) {
        self.updater = SPUUpdater()
    }
}
SWIFT
rm -rf /tmp/LocateAppTypecheckBuild /tmp/LocateAppSparkleStubBuild /tmp/LocateAppModuleCache
mkdir -p /tmp/LocateAppTypecheckBuild /tmp/LocateAppSparkleStubBuild /tmp/LocateAppModuleCache
swiftc -swift-version 6 -emit-module -module-name Sparkle /tmp/SparkleStub.swift -emit-module-path /tmp/LocateAppSparkleStubBuild/Sparkle.swiftmodule -module-cache-path /tmp/LocateAppModuleCache
swiftc -emit-module -module-name LocateAppCore Sources/LocateAppCore/LocationContinuity.swift Sources/LocateAppCore/SleepPrevention.swift Sources/LocateAppCore/LocateCore.swift Sources/LocateAppCore/LocateProcess.swift -emit-module-path /tmp/LocateAppTypecheckBuild/LocateAppCore.swiftmodule
swiftc -swift-version 6 -typecheck -parse-as-library -module-name LocateAppManualTypecheck -I /tmp/LocateAppTypecheckBuild -I /tmp/LocateAppSparkleStubBuild -module-cache-path /tmp/LocateAppModuleCache Sources/LocateApp/LocateApp.swift Sources/LocateApp/AppModel.swift Sources/LocateApp/LocationSearchService.swift Sources/LocateApp/DevicePanel.swift Sources/LocateApp/MapPickerView.swift
```

Expected: typecheck succeeds, aside from any pre-existing deprecation warnings.

- [ ] **Step 6: Commit**

```bash
git add Sources/LocateApp/LocateApp.swift README.md
git commit -m "feat: check for updates silently at launch"
```

### Task 3: Verify, Review, PR, And Release Gate

**Files:**
- Read: `.github/workflows/release.yml`
- Read: `docs/notarization.md`

- [ ] **Step 1: Run full local verification**

Run:

```bash
.venv/bin/python -m pytest
rm -rf /tmp/LocateAppCoreChecksBuild && mkdir -p /tmp/LocateAppCoreChecksBuild
swiftc -emit-module -emit-library -module-name LocateAppCore Sources/LocateAppCore/LocationContinuity.swift Sources/LocateAppCore/SleepPrevention.swift Sources/LocateAppCore/LocateCore.swift Sources/LocateAppCore/LocateProcess.swift -emit-module-path /tmp/LocateAppCoreChecksBuild/LocateAppCore.swiftmodule -o /tmp/LocateAppCoreChecksBuild/libLocateAppCore.dylib
swiftc -I /tmp/LocateAppCoreChecksBuild -L /tmp/LocateAppCoreChecksBuild -lLocateAppCore -o /tmp/LocateAppCoreChecksBuild/LocateAppCoreChecks Sources/LocateAppCoreChecks/main.swift
DYLD_LIBRARY_PATH=/tmp/LocateAppCoreChecksBuild /tmp/LocateAppCoreChecksBuild/LocateAppCoreChecks
bash -n scripts/build_app_bundle.sh scripts/build_helper.sh scripts/clean_generated.sh scripts/e2e_smoke.sh scripts/import_apple_certificate.sh scripts/package_release.sh scripts/verify_release_artifacts.sh scripts/generate_sparkle_appcast.sh scripts/run_swift_core_checks.sh
```

Expected: all commands exit 0.

- [ ] **Step 2: Re-run app typecheck with Sparkle stub**

Run the stub typecheck command from Task 2 Step 5.

Expected: typecheck succeeds, aside from any pre-existing deprecation warnings.

- [ ] **Step 3: Inspect diff**

Run:

```bash
git diff --check main..HEAD
git diff --stat main..HEAD
```

Expected: no whitespace errors and a small diff limited to docs, core policy,
core checks, app launch code, and README.

- [ ] **Step 4: Create PR**

Push the branch and create a PR:

```bash
git push -u origin codex/launch-update-check
gh pr create --title "Check for updates silently at launch" --body-file /tmp/launch-update-check-pr.md
```

- [ ] **Step 5: Wait for CI and merge if green**

Run:

```bash
gh pr checks --watch --interval 10
gh pr merge --merge --delete-branch
```

Expected: CI passes and PR merges into `main`.

- [ ] **Step 6: Deploy only when release prerequisites are clear**

Check the latest releases and release workflow:

```bash
gh release list --limit 5
gh run list --workflow release.yml --limit 5
```

If the previous release workflow is still blocked by Apple notarization account
state or if no new version tag is confirmed, do not create a tag. Report the
deployment blocker. If a valid next version and release prerequisites are
confirmed, tag and push that version.

- [ ] **Step 7: Clean up**

After merge, pull `main`, remove the local worktree and local feature branch, run
`./scripts/clean_generated.sh`, and verify `git status --short --branch` is clean.
