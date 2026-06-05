# LocateApp macOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a SwiftUI macOS app that changes a connected iPhone's simulated location from a map and can reset it.

**Architecture:** A SwiftPM package adds a testable `LocateAppCore` library and a SwiftUI `LocateApp` executable. The app wraps the proven `pymobiledevice3` route, manages RSD tunnel state in `.locateapp/`, and keeps the iOS 17+ location-set process alive until reset.

**Tech Stack:** Swift 6.3, SwiftPM, SwiftUI, AppKit MapKit bridge, Python `pymobiledevice3` helper.

---

### Task 1: Swift Package and Core Command Layer

**Files:**
- Create: `Package.swift`
- Create: `Sources/LocateAppCore/LocateCore.swift`
- Create: `Tests/LocateAppCoreTests/LocateCoreTests.swift`

- [ ] Add SwiftPM package with `LocateAppCore`, `LocateApp`, and tests.
- [ ] Implement project-root discovery, coordinate validation, RSD parsing, and command builders.
- [ ] Add tests for command arrays and parser failures.
- [ ] Run `swift test`.

### Task 2: Process Orchestration

**Files:**
- Modify: `Sources/LocateAppCore/LocateCore.swift`
- Create: `Sources/LocateAppCore/LocateProcess.swift`
- Create: `Tests/LocateAppCoreTests/LocateProcessTests.swift`

- [ ] Implement shell quoting, admin tunnel startup command generation, state paths, PID parsing, and a `DeviceController` facade.
- [ ] Add tests for safe quoting, state paths, stale output handling, and command sequencing.
- [ ] Run `swift test`.

### Task 3: SwiftUI Map App

**Files:**
- Create: `Sources/LocateApp/LocateApp.swift`
- Create: `Sources/LocateApp/AppModel.swift`
- Create: `Sources/LocateApp/MapPickerView.swift`
- Create: `Sources/LocateApp/DevicePanel.swift`

- [ ] Implement map click coordinate selection with `MKMapView`.
- [ ] Implement status panel and buttons.
- [ ] Wire refresh, tunnel start, move, and reset actions to `DeviceController`.
- [ ] Run `swift build`.

### Task 4: App Bundle and Documentation

**Files:**
- Create: `scripts/build_app_bundle.sh`
- Modify: `README.md`
- Modify: `.gitignore`

- [ ] Create a local `.app` bundle from the SwiftPM release executable.
- [ ] Document setup, running from SwiftPM, building the bundle, and reset behavior.
- [ ] Run Python tests, Swift tests, Swift build, and bundle script.

### Task 5: Review and Fix Loop

**Files:**
- Review all changed files.

- [ ] Dispatch code review for core/process layer.
- [ ] Dispatch code review for UI/app bundle layer.
- [ ] Fix critical and important findings.
- [ ] Re-run full verification.
