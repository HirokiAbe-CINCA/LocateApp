import Foundation
import LocateAppCore

enum CheckFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let message):
            return message
        }
    }
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw CheckFailure.message(message)
    }
}

func checkThrows(_ message: String, _ operation: () throws -> Void) throws {
    do {
        try operation()
    } catch {
        return
    }
    throw CheckFailure.message(message)
}

final class RecordingSleepAssertionClient: SleepAssertionClient, @unchecked Sendable {
    var createdReasons: [String] = []
    var releasedIDs: [UInt32] = []
    var nextID: UInt32 = 100

    func create(reason: String) throws -> UInt32 {
        createdReasons.append(reason)
        defer {
            nextID += 1
        }
        return nextID
    }

    func release(id: UInt32) {
        releasedIDs.append(id)
    }
}

func runChecks() throws {
    let json = """
    [
      {
        "ConnectionType": "USB",
        "DeviceClass": "iPhone",
        "DeviceName": "iPhone17",
        "Identifier": "00008150",
        "ProductVersion": "26.5.1"
      }
    ]
    """

    let devices = try DeviceInfo.parseList(json)
    try check(devices == [
        DeviceInfo(
            identifier: "00008150",
            name: "iPhone17",
            productVersion: "26.5.1",
            connectionType: "USB"
        )
    ], "device list did not parse")

    try checkThrows("missing Identifier did not throw") {
        _ = try DeviceInfo.parseList(#"[{"ConnectionType":"USB","DeviceName":"iPhone"}]"#)
    }

    let endpoint = try RSDEndpoint.parse("fd99:1792:87b6::1 54429\n")
    try check(endpoint.host == "fd99:1792:87b6::1", "RSD host mismatch")
    try check(endpoint.port == "54429", "RSD port mismatch")
    let endpointWithNoise = try RSDEndpoint.parse("Preparing tunnel\nfd99:1792:87b6::1 54429\n")
    try check(endpointWithNoise == endpoint, "RSD endpoint with leading output did not parse")
    try checkThrows("invalid RSD output did not throw") {
        _ = try RSDEndpoint.parse("not enough")
    }

    let coordinate = try Coordinate(latitude: 35.681236, longitude: 139.767125)
    let commaCoordinate = try Coordinate.parsePair("35.681236, 139.767125")
    let whitespaceCoordinate = try Coordinate.parsePair("35.681236 139.767125")
    try check(commaCoordinate == coordinate, "coordinate pair with comma did not parse")
    try check(whitespaceCoordinate == coordinate, "coordinate pair with whitespace did not parse")
    try checkThrows("invalid coordinate pair did not throw") {
        _ = try Coordinate.parsePair("35.681236")
    }
    try checkThrows("invalid latitude did not throw") {
        _ = try Coordinate(latitude: 91, longitude: 139.767125)
    }
    try checkThrows("non-finite longitude did not throw") {
        _ = try Coordinate(latitude: 35.681236, longitude: .infinity)
    }

    let developerModeOn = try DeveloperMode.isEnabled("true\n")
    let developerModeOff = try DeveloperMode.isEnabled("false\n")
    try check(developerModeOn, "Developer Mode true did not parse")
    try check(!developerModeOff, "Developer Mode false did not parse")
    try checkThrows("invalid Developer Mode status did not throw") {
        _ = try DeveloperMode.isEnabled("maybe")
    }

    let sleepClient = RecordingSleepAssertionClient()
    let sleepPreventer = SleepPreventer(client: sleepClient, reason: "LocateApp is moving an iPhone")
    try check(!sleepPreventer.isActive, "sleep preventer should start inactive")
    try sleepPreventer.acquire()
    try check(sleepPreventer.isActive, "sleep preventer should be active after acquire")
    try check(sleepClient.createdReasons == ["LocateApp is moving an iPhone"], "sleep preventer should create one assertion")
    try sleepPreventer.acquire()
    try check(sleepClient.createdReasons.count == 1, "sleep preventer should not duplicate assertions")
    sleepPreventer.release()
    try check(!sleepPreventer.isActive, "sleep preventer should be inactive after release")
    try check(sleepClient.releasedIDs == [100], "sleep preventer should release the active assertion")
    sleepPreventer.release()
    try check(sleepClient.releasedIDs == [100], "sleep preventer should ignore duplicate releases")

    let deinitSleepClient = RecordingSleepAssertionClient()
    do {
        let scopedPreventer = SleepPreventer(client: deinitSleepClient, reason: "Scoped movement")
        try scopedPreventer.acquire()
    }
    try check(deinitSleepClient.releasedIDs == [100], "sleep preventer should release on deinit")

    let paths = LocatePaths(
        root: URL(fileURLWithPath: "/repo"),
        pymobiledevicePath: URL(fileURLWithPath: "/repo/.venv/bin/pymobiledevice3")
    )
    let device = DeviceInfo(
        identifier: "00008150",
        name: "iPhone17",
        productVersion: "26.5.1",
        connectionType: "USB"
    )

    try check(paths.listDevicesCommand == [
        "/repo/.venv/bin/pymobiledevice3", "usbmux", "list"
    ], "list devices command mismatch")
    try check(paths.developerModeCommand(endpoint: endpoint) == [
        "/repo/.venv/bin/pymobiledevice3", "mounter", "query-developer-mode-status",
        "--rsd", "fd99:1792:87b6::1", "54429"
    ], "developer mode command mismatch")
    try check(paths.tunnelCommand(device: device) == [
        "/repo/.venv/bin/pymobiledevice3", "lockdown", "start-tunnel",
        "--script-mode", "--udid", "00008150"
    ], "tunnel command mismatch")
    try check(paths.setLocationCommand(endpoint: endpoint, coordinate: coordinate) == [
        "/repo/.venv/bin/pymobiledevice3", "developer", "dvt", "simulate-location",
        "set", "--rsd", "fd99:1792:87b6::1", "54429", "--", "35.681236", "139.767125"
    ], "set command mismatch")
    try check(paths.clearLocationCommand(endpoint: endpoint) == [
        "/repo/.venv/bin/pymobiledevice3", "developer", "dvt", "simulate-location",
        "clear", "--rsd", "fd99:1792:87b6::1", "54429"
    ], "clear command mismatch")
    try check(
        paths.stateDirectory.path == "/repo/.locateapp",
        "repo-local state directory mismatch"
    )

    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("LocateAppCoreChecks-\(UUID().uuidString)", isDirectory: true)
    let appResources = tempRoot
        .appendingPathComponent("LocateApp.app/Contents/Resources", isDirectory: true)
    let bundledHelperDirectory = appResources
        .appendingPathComponent("pymobiledevice3-helper", isDirectory: true)
    try FileManager.default.createDirectory(
        at: bundledHelperDirectory,
        withIntermediateDirectories: true
    )
    let bundledHelper = bundledHelperDirectory.appendingPathComponent("pymobiledevice3-helper")
    FileManager.default.createFile(atPath: bundledHelper.path, contents: Data("#!/bin/sh\n".utf8))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledHelper.path)
    defer {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    let bundledPaths = try LocatePaths.discover(
        startingAt: tempRoot.appendingPathComponent("LocateApp.app", isDirectory: true)
    )
    try check(
        bundledPaths.pymobiledevicePath.path == bundledHelper.path,
        "bundled helper path mismatch"
    )
    try check(
        bundledPaths.stateDirectory.path.contains("/Library/Application Support/LocateApp/.locateapp"),
        "bundled app should use Application Support for writable state"
    )

    try check(Shell.quote("abc") == "'abc'", "simple shell quote mismatch")
    try check(Shell.quote("a'b") == "'a'\\''b'", "single quote escaping mismatch")
    try check(AppleScript.quote("echo hi") == "\"echo hi\"", "simple AppleScript quote mismatch")
    try check(AppleScript.quote("echo \"hi\"") == "\"echo \\\"hi\\\"\"", "AppleScript double quote escaping mismatch")
    try check(AppleScript.quote("c:\\tmp") == "\"c:\\\\tmp\"", "AppleScript backslash escaping mismatch")

    let files = SessionFiles(directory: URL(fileURLWithPath: "/repo/.locateapp"))
    let sessionCommands = LocateSessionCommands(paths: paths, files: files)
    let adminScript = sessionCommands.adminTunnelScript(device: device)
    try check(
        adminScript.script.contains("&& ('/repo/.venv/bin/pymobiledevice3'"),
        "admin tunnel script should background inside a grouped shell command"
    )
    try check(
        adminScript.script.contains("'/repo/.venv/bin/pymobiledevice3' 'lockdown' 'start-tunnel'"),
        "admin tunnel script is missing tunnel command"
    )
    try check(
        !adminScript.script.contains("nohup"),
        "admin tunnel script should not use nohup because AppleScript administrator shells can reject console detach"
    )
    try check(
        adminScript.script.contains("echo $! > '/repo/.locateapp/tunnel.pid'"),
        "admin tunnel script is missing pid write"
    )
    try check(adminScript.osascriptCommand[0] == "/usr/bin/osascript", "osascript command mismatch")
    try check(adminScript.osascriptCommand[2].contains("administrator privileges"), "admin prompt missing")
    try check(adminScript.osascriptCommand[2].contains("do shell script \""), "AppleScript shell string should use double quotes")
    try check(!adminScript.osascriptCommand[2].contains("do shell script '"), "AppleScript shell string should not use shell quotes")

    let stopTunnel = sessionCommands.adminStopTunnelScript()
    try check(
        stopTunnel.script.contains("rm -f '/repo/.locateapp/tunnel.pid'"),
        "stop tunnel script should remove tunnel state"
    )

    let persistentSet = sessionCommands.persistentSetCommand(endpoint: endpoint, coordinate: coordinate)
    try check(persistentSet[0] == "/bin/sh", "persistent set should run through sh")
    try check(persistentSet[1] == "-c", "persistent set should use sh -c")
    try check(
        persistentSet[2].contains("nohup '/repo/.venv/bin/pymobiledevice3' 'developer' 'dvt' 'simulate-location' 'set'"),
        "persistent set command is missing simulated-location set"
    )
    try check(
        persistentSet[2].contains("echo $! > '/repo/.locateapp/set.pid'"),
        "persistent set command is missing pid write"
    )
    try check(
        ProcessMatcher.isSimulatedLocationSetCommand("/repo/.venv/bin/pymobiledevice3 developer dvt simulate-location set --rsd host 1 -- 1 2"),
        "set process matcher did not match set command"
    )
    try check(
        ProcessMatcher.isSimulatedLocationSetCommand("/Applications/LocateApp.app/Contents/Resources/pymobiledevice3-helper/pymobiledevice3-helper developer dvt simulate-location set --rsd host 1 -- 1 2"),
        "set process matcher did not match bundled helper command"
    )
    try check(
        !ProcessMatcher.isSimulatedLocationSetCommand("/repo/.venv/bin/pymobiledevice3 developer dvt simulate-location clear --rsd host 1"),
        "set process matcher matched clear command"
    )
    try check(
        !ProcessMatcher.isSimulatedLocationSetCommand("/repo/.venv/bin/pymobiledevice3 developer dvt simulate-location settings --rsd host 1"),
        "set process matcher matched command containing set as a substring"
    )
    try check(
        !ProcessMatcher.isSimulatedLocationSetCommand("/bin/sleep 100"),
        "set process matcher matched unrelated command"
    )
    try check(
        ProcessMatcher.isTunnelCommand("/repo/.venv/bin/pymobiledevice3 lockdown start-tunnel --script-mode --udid id"),
        "tunnel process matcher did not match tunnel command"
    )
    try check(
        ProcessMatcher.isTunnelCommand("/Applications/LocateApp.app/Contents/Resources/pymobiledevice3-helper/pymobiledevice3-helper lockdown start-tunnel --script-mode --udid id"),
        "tunnel process matcher did not match bundled helper tunnel command"
    )
    try check(
        !ProcessMatcher.isTunnelCommand("/repo/.venv/bin/pymobiledevice3 lockdown stop-tunnel --script-mode --udid id"),
        "tunnel process matcher matched unrelated lockdown command"
    )
    try check(
        LocationContinuityAssessment.assess(tunnelRunning: true, setProcessRunning: true) == .active,
        "continuity should be active when tunnel and set process are both running"
    )
    try check(
        LocationContinuityAssessment.assess(tunnelRunning: false, setProcessRunning: true) == .uncertain(.tunnelClosed),
        "continuity should be uncertain when the tunnel closes"
    )
    try check(
        LocationContinuityAssessment.assess(tunnelRunning: true, setProcessRunning: false) == .uncertain(.setProcessStopped),
        "continuity should be uncertain when the set process stops"
    )
    try check(
        LocationReapplyPrompt.isAvailable(hasActiveCoordinate: true, activeLocationMayRemain: true),
        "reapply prompt should be available when an active location is uncertain"
    )
    try check(
        !LocationReapplyPrompt.isAvailable(hasActiveCoordinate: true, activeLocationMayRemain: false),
        "reapply prompt should not be available while the active location is healthy"
    )
    try check(
        !LocationReapplyPrompt.isAvailable(hasActiveCoordinate: false, activeLocationMayRemain: true),
        "reapply prompt should not be available without a previous coordinate"
    )

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

    let parsedPID = try PIDFile.parse("1234\n")
    try check(parsedPID == 1234, "pid parse mismatch")
    try checkThrows("invalid pid did not throw") {
        _ = try PIDFile.parse("nope")
    }

    let runner = ProcessRunner()
    let quickOutput = try runner.run(["/bin/echo", "ok"], timeout: 1)
    try check(quickOutput == "ok\n", "process runner did not capture stdout")
    try checkThrows("timeout did not throw") {
        _ = try runner.run(["/bin/sh", "-c", "sleep 2"], timeout: 0.1)
    }
    let ignoredTerminationStart = Date()
    try checkThrows("ignored termination timeout did not throw") {
        _ = try runner.run(["/bin/sh", "-c", "trap '' TERM; sleep 3"], timeout: 0.1)
    }
    try check(
        Date().timeIntervalSince(ignoredTerminationStart) < 2,
        "timeout should not wait forever when a process ignores SIGTERM"
    )
    let largeOutput = try runner.run([
        "/usr/bin/perl",
        "-e",
        "print 'x' x 2000000; print STDERR 'y' x 2000000;"
    ], timeout: 5)
    try check(largeOutput.count == 2_000_000, "process runner did not drain large stdout")
}

do {
    try runChecks()
    print("LocateAppCoreChecks passed")
} catch {
    fputs("LocateAppCoreChecks failed: \(error)\n", stderr)
    exit(1)
}
