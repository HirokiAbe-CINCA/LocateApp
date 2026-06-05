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

    try check(Shell.quote("abc") == "'abc'", "simple shell quote mismatch")
    try check(Shell.quote("a'b") == "'a'\\''b'", "single quote escaping mismatch")
    try check(AppleScript.quote("echo hi") == "\"echo hi\"", "simple AppleScript quote mismatch")
    try check(AppleScript.quote("echo \"hi\"") == "\"echo \\\"hi\\\"\"", "AppleScript double quote escaping mismatch")
    try check(AppleScript.quote("c:\\tmp") == "\"c:\\\\tmp\"", "AppleScript backslash escaping mismatch")

    let files = SessionFiles(directory: URL(fileURLWithPath: "/repo/.locateapp"))
    let sessionCommands = LocateSessionCommands(paths: paths, files: files)
    let adminScript = sessionCommands.adminTunnelScript(device: device)
    try check(
        adminScript.script.contains("&& (nohup '/repo/.venv/bin/pymobiledevice3'"),
        "admin tunnel script should background inside a grouped shell command"
    )
    try check(
        adminScript.script.contains("nohup '/repo/.venv/bin/pymobiledevice3' 'lockdown' 'start-tunnel'"),
        "admin tunnel script is missing nohup tunnel command"
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
        !ProcessMatcher.isTunnelCommand("/repo/.venv/bin/pymobiledevice3 lockdown stop-tunnel --script-mode --udid id"),
        "tunnel process matcher matched unrelated lockdown command"
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
}

do {
    try runChecks()
    print("LocateAppCoreChecks passed")
} catch {
    fputs("LocateAppCoreChecks failed: \(error)\n", stderr)
    exit(1)
}
