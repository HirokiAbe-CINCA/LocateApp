# Launch Update Check Design

## Goal

LocateApp should check for newer signed releases when a local release build is
launched, without interrupting users when the installed app is already current.

## Scope

This change uses the existing Sparkle 2 integration. It does not add a custom
update UI, forced update gate, GitHub Releases polling, or release-channel
switching.

## Behavior

When Sparkle is configured and automatic update checks are enabled, LocateApp
starts a single background update check during app initialization. Sparkle keeps
its normal behavior for presenting, downloading, and installing an available
update. If no update is available, no user-facing UI is shown.

The manual "Check for Updates..." menu item remains available and continues to
use Sparkle's foreground check.

## Architecture

The app keeps owning `SPUStandardUpdaterController` from `LocateAppMain`. A small
pure Swift policy type in `LocateAppCore` decides whether a launch check should
run. `LocateAppMain` calls Sparkle's `checkForUpdatesInBackground()` only
immediately after creating the updater controller and only when that policy
allows it.

The policy is in core code so it can be exercised by the existing
`LocateAppCoreChecks` executable without needing the Sparkle framework.

## Error Handling

Local debug builds without `SUFeedURL` or `SUPublicEDKey` continue to disable
Sparkle. If Sparkle is not configured or automatic checks are disabled by user
defaults/launch arguments, no launch check is triggered.

Sparkle owns network errors, skipped versions, active update sessions, downloads,
and install prompts.

## Testing

Core checks cover that launch checks are allowed only when automatic update
checks are enabled. App integration is verified with a local Sparkle stub module
that typechecks the new `LocateAppMain` call site. Existing Python release-script
tests remain unchanged and should continue passing.
