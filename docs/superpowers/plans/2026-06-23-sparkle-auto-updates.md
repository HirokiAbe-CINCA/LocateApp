# Sparkle Auto Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Sparkle 2 automatic updates to LocateApp without forced update blocking.

**Architecture:** The SwiftUI app owns a long-lived Sparkle updater controller and exposes a standard update menu item. The custom GitHub update banner is removed. Release automation signs and publishes a Sparkle appcast for the GitHub Release ZIP artifact and deploys it to GitHub Pages.

**Tech Stack:** SwiftPM, SwiftUI, Sparkle 2.9.3, bash release scripts, GitHub Actions, GitHub Releases, GitHub Pages.

---

### Task 1: App-Side Sparkle Integration

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/LocateApp/LocateApp.swift`
- Modify: `Sources/LocateApp/AppModel.swift`
- Modify: `Sources/LocateApp/DevicePanel.swift`
- Modify: `Sources/LocateAppCore/LocateCore.swift`
- Modify: `Sources/LocateAppCoreChecks/main.swift`
- Modify: `scripts/build_app_bundle.sh`
- Modify: `scripts/verify_release_artifacts.sh`

- [ ] **Step 1: Add Sparkle dependency**

Update `Package.swift` to add:

```swift
dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.3")
],
```

and add `.product(name: "Sparkle", package: "Sparkle")` to the `LocateApp` executable target dependencies.

- [ ] **Step 2: Add app lifetime updater**

Update `Sources/LocateApp/LocateApp.swift` to import Sparkle, create `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)`, and add a SwiftUI `CheckForUpdatesView` command using `updaterController.updater`.

- [ ] **Step 3: Remove old GitHub update UI**

Remove `availableUpdate`, `isCheckingForUpdates`, `updateStatus`, `checkForUpdates()`, and `openAvailableUpdate()` from `AppModel`. Remove the `updateBanner` section from `DevicePanel`. Remove the startup `model.checkForUpdates()` call from `LocateApp.swift`.

- [ ] **Step 4: Remove old release parsing code**

Remove `ReleaseUpdate` from `Sources/LocateAppCore/LocateCore.swift` and remove the corresponding checks from `Sources/LocateAppCoreChecks/main.swift`.

- [ ] **Step 5: Embed Sparkle framework**

Update `scripts/build_app_bundle.sh` to create `Contents/Frameworks`, locate `Sparkle.framework` from SwiftPM artifacts, copy it with `ditto`, inject Sparkle `Info.plist` keys when `SPARKLE_PUBLIC_ED_KEY` is present, and sign embedded frameworks before the outer app.

- [ ] **Step 6: Verify release artifacts include Sparkle**

Update `scripts/verify_release_artifacts.sh` to require `Contents/Frameworks/Sparkle.framework/Sparkle` and run `codesign --verify --strict --verbose=2` on the embedded framework.

### Task 2: Sparkle Appcast Release Automation

**Files:**
- Create: `scripts/generate_sparkle_appcast.sh`
- Modify: `scripts/package_release.sh`
- Modify: `scripts/verify_release_artifacts.sh`
- Modify: `.github/workflows/release.yml`
- Modify: `README.md`
- Modify: `docs/notarization.md`

- [ ] **Step 1: Create appcast generation script**

Create `scripts/generate_sparkle_appcast.sh` that downloads Sparkle 2.9.3 tools, verifies the tarball SHA-256, stages `LocateApp-$VERSION-mac-arm64.zip`, writes matching markdown release notes, and runs:

```bash
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" |
  "$SPARKLE_TOOLS_DIR/bin/generate_appcast" \
    --ed-key-file - \
    --download-url-prefix "https://github.com/HirokiAbe-CINCA/LocateApp/releases/download/v$VERSION/" \
    -o "$RELEASE_DIR/appcast.xml" \
    "$APPCAST_STAGING_DIR"
```

- [ ] **Step 2: Add appcast verification**

Extend `scripts/verify_release_artifacts.sh` to validate `release/appcast.xml` when present: XML parses, enclosure URL points to the release ZIP, `sparkle:edSignature` exists, `length` matches ZIP byte size, no `sparkle:criticalUpdate`, and no `sparkle:minimumUpdateVersion`.

- [ ] **Step 3: Wire release packaging**

Update `scripts/package_release.sh` to call `scripts/generate_sparkle_appcast.sh` only when `SPARKLE_ED_PRIVATE_KEY` is set and notarization is active. Skip appcast generation for ad-hoc release artifacts.

- [ ] **Step 4: Update GitHub Actions**

Update `.github/workflows/release.yml` to pass `SPARKLE_PUBLIC_ED_KEY` and `SPARKLE_ED_PRIVATE_KEY`, upload `release/appcast.xml` to the GitHub Release, and deploy `appcast.xml` to GitHub Pages after the Release is created.

- [ ] **Step 5: Document release setup**

Update README and notarization docs with Sparkle setup, required secrets, and the GitHub Pages feed URL.

### Task 3: Verification, Review, PR, Merge, Deploy

**Files:**
- No planned source edits unless reviewers find issues.

- [ ] **Step 1: Run local verification**

Run:

```bash
.venv/bin/python -m pytest
bash -n scripts/build_app_bundle.sh scripts/build_helper.sh scripts/clean_generated.sh scripts/e2e_smoke.sh scripts/import_apple_certificate.sh scripts/package_release.sh scripts/verify_release_artifacts.sh scripts/generate_sparkle_appcast.sh
```

Attempt:

```bash
swift run LocateAppCoreChecks
swift build
```

Record the known local SwiftPM Command Line Tools failure if it persists.

- [ ] **Step 2: Run generated appcast script smoke test**

If a temporary Sparkle key is available, run the appcast script against a placeholder ZIP. Otherwise verify script syntax and static behavior only.

- [ ] **Step 3: High-rigor review**

Use a high-capability reviewer to inspect app integration, signing order, release security, GitHub Actions, and docs.

- [ ] **Step 4: Push PR**

Push `codex/sparkle-auto-update` and open a draft PR. Include verification results and any blocked local SwiftPM evidence.

- [ ] **Step 5: Merge and deploy if unblocked**

Merge only if CI passes and required Sparkle/Apple secrets and GitHub Pages are configured. Deploy by pushing a version tag only after the release workflow can sign, notarize, generate appcast, and publish the feed.

- [ ] **Step 6: Clean worktree**

After merge/deploy or if blocked, remove temporary Sparkle downloads and the isolated worktree if no longer needed.
