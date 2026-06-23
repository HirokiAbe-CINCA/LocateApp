# Sparkle Auto Updates Design

## Goal

LocateApp should use Sparkle 2 for normal macOS automatic updates, similar to Worklog-style app updates, without blocking normal app use when an update exists.

## Requirements

- Add Sparkle 2 as the app's updater.
- Start Sparkle from app lifetime state, not from a transient SwiftUI view.
- Enable automatic update checks and automatic download/install attempts by default for release builds.
- Keep user-initiated "Check for Updates..." available from the app menu.
- Remove the existing GitHub Releases polling banner so there is one update system.
- Do not add a forced update gate, critical update marker, or UI lock.
- Generate a Sparkle appcast for release ZIP updates.
- Keep GitHub Releases as the artifact host and use GitHub Pages as the stable appcast URL.
- Do not commit private Sparkle keys or Apple signing material.

## Architecture

The app imports Sparkle and owns a long-lived `SPUStandardUpdaterController` in `LocateAppMain`. A small SwiftUI command view exposes a standard "Check for Updates..." menu item and follows Sparkle's `canCheckForUpdates` state. Release builds inject Sparkle configuration into the generated `Info.plist` through environment variables in `scripts/build_app_bundle.sh`.

Release automation generates `release/appcast.xml` from the notarized ZIP archive using Sparkle 2.9.3's `generate_appcast`. The appcast enclosure points to the GitHub Release ZIP URL. The generated appcast is uploaded to the GitHub Release for audit and deployed to GitHub Pages as the stable feed.

## Configuration

- `SUFeedURL`: `https://hirokiabe-cinca.github.io/LocateApp/appcast.xml`
- `SUPublicEDKey`: provided by `SPARKLE_PUBLIC_ED_KEY` during release builds.
- `SUEnableAutomaticChecks`: true when Sparkle is configured.
- `SUAutomaticallyUpdate`: true when Sparkle is configured.

Sparkle remains disabled for local development builds when `SPARKLE_PUBLIC_ED_KEY` is absent, so developers can run the app without a release signing key.

## Release Secrets

- `SPARKLE_PUBLIC_ED_KEY`: public EdDSA key embedded in `Info.plist`.
- `SPARKLE_ED_PRIVATE_KEY`: private EdDSA key exported by Sparkle's `generate_keys -x` and stored as a GitHub secret. It is passed to Sparkle tooling through stdin, not command-line arguments.

## Verification

- Python unit tests continue to pass.
- Shell scripts pass `bash -n`.
- Swift build/core checks should pass in CI. Local SwiftPM verification may be blocked by the existing Command Line Tools `PackageDescription` link error.
- Release verification checks that `Sparkle.framework` is embedded, signed, and present in ZIP/DMG artifacts.
- Appcast verification checks XML validity and required Sparkle enclosure attributes.

## Non-Goals

- No forced update gate.
- No custom Sparkle UI.
- No feed signing in the first pass.
- No silent bypass of Sparkle security checks.
