import Darwin
import Foundation

public struct SessionFiles: Equatable, Sendable {
    public let directory: URL
    public let tunnelOutput: URL
    public let tunnelError: URL
    public let tunnelPID: URL
    public let setOutput: URL
    public let setError: URL
    public let setPID: URL
    public let activeCoordinate: URL

    public init(directory: URL) {
        self.directory = directory
        self.tunnelOutput = directory.appendingPathComponent("tunnel.out")
        self.tunnelError = directory.appendingPathComponent("tunnel.err")
        self.tunnelPID = directory.appendingPathComponent("tunnel.pid")
        self.setOutput = directory.appendingPathComponent("set.out")
        self.setError = directory.appendingPathComponent("set.err")
        self.setPID = directory.appendingPathComponent("set.pid")
        self.activeCoordinate = directory.appendingPathComponent("active-coordinate.txt")
    }
}

public enum Shell {
    public static func quote(_ value: String) -> String {
        if value.isEmpty {
            return "''"
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func join(_ command: [String]) -> String {
        command.map(quote).joined(separator: " ")
    }
}

public enum AppleScript {
    public static func quote(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

public struct AdminTunnelScript: Equatable, Sendable {
    public let script: String
    public let osascriptCommand: [String]
}

public enum ProcessMatcher {
    public static func isSimulatedLocationSetCommand(_ commandLine: String) -> Bool {
        let tokens = commandLineTokens(commandLine)
        return hasPymobiledeviceExecutable(tokens) &&
            containsSequence(["developer", "dvt", "simulate-location", "set"], in: tokens)
    }

    public static func isTunnelCommand(_ commandLine: String) -> Bool {
        let tokens = commandLineTokens(commandLine)
        return hasPymobiledeviceExecutable(tokens) &&
            containsSequence(["lockdown", "start-tunnel"], in: tokens)
    }

    private static func commandLineTokens(_ commandLine: String) -> [String] {
        commandLine.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map { token in
                token.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            }
    }

    private static func hasPymobiledeviceExecutable(_ tokens: [String]) -> Bool {
        tokens.contains { token in
            URL(fileURLWithPath: token).lastPathComponent == "pymobiledevice3" ||
                token == "pymobiledevice3"
        }
    }

    private static func containsSequence(_ sequence: [String], in tokens: [String]) -> Bool {
        guard tokens.count >= sequence.count else {
            return false
        }

        for startIndex in 0...(tokens.count - sequence.count) {
            if Array(tokens[startIndex..<(startIndex + sequence.count)]) == sequence {
                return true
            }
        }
        return false
    }
}

public struct LocateSessionCommands: Sendable {
    public let paths: LocatePaths
    public let files: SessionFiles

    public init(paths: LocatePaths, files: SessionFiles? = nil) {
        self.paths = paths
        self.files = files ?? SessionFiles(directory: paths.stateDirectory)
    }

    public func adminTunnelScript(device: DeviceInfo) -> AdminTunnelScript {
        let command = paths.tunnelCommand(device: device)
        let background = [
            "nohup \(Shell.join(command)) > \(Shell.quote(files.tunnelOutput.path)) 2> \(Shell.quote(files.tunnelError.path)) &",
            "echo $! > \(Shell.quote(files.tunnelPID.path))"
        ].joined(separator: " ")
        let scriptParts = [
            "mkdir -p \(Shell.quote(files.directory.path))",
            tunnelCleanupScript,
            "cd \(Shell.quote(paths.root.path))",
            "(\(background))"
        ]
        let script = scriptParts.joined(separator: " && ")

        return AdminTunnelScript(
            script: script,
            osascriptCommand: [
                "/usr/bin/osascript",
                "-e",
                "do shell script \(AppleScript.quote(script)) with administrator privileges"
            ]
        )
    }

    public func adminStopTunnelScript() -> AdminTunnelScript {
        AdminTunnelScript(
            script: tunnelCleanupScript,
            osascriptCommand: [
                "/usr/bin/osascript",
                "-e",
                "do shell script \(AppleScript.quote(tunnelCleanupScript)) with administrator privileges"
            ]
        )
    }

    public func clearCommand(endpoint: RSDEndpoint) -> [String] {
        paths.clearLocationCommand(endpoint: endpoint)
    }

    public func setCommand(endpoint: RSDEndpoint, coordinate: Coordinate) -> [String] {
        paths.setLocationCommand(endpoint: endpoint, coordinate: coordinate)
    }

    public func persistentSetCommand(endpoint: RSDEndpoint, coordinate: Coordinate) -> [String] {
        let command = setCommand(endpoint: endpoint, coordinate: coordinate)
        let background = [
            "nohup \(Shell.join(command)) > \(Shell.quote(files.setOutput.path)) 2> \(Shell.quote(files.setError.path)) &",
            "echo $! > \(Shell.quote(files.setPID.path))"
        ].joined(separator: " ")
        let script = [
            "mkdir -p \(Shell.quote(files.directory.path))",
            "cd \(Shell.quote(paths.root.path))",
            "(\(background))"
        ].joined(separator: " && ")

        return ["/bin/sh", "-c", script]
    }

    private var tunnelCleanupScript: String {
        [
            "if [ -f \(Shell.quote(files.tunnelPID.path)) ]; then pid=$(cat \(Shell.quote(files.tunnelPID.path)) | tr -cd '0-9'); if [ -n \"$pid\" ]; then cmd=$(ps -p \"$pid\" -o command= 2>/dev/null || true); case \"$cmd\" in *pymobiledevice3*lockdown*start-tunnel*) kill \"$pid\" 2>/dev/null || true ;; esac; fi; fi",
            "rm -f \(Shell.quote(files.tunnelPID.path)) \(Shell.quote(files.tunnelOutput.path)) \(Shell.quote(files.tunnelError.path))"
        ].joined(separator: " && ")
    }
}

public struct PIDFile {
    public static func parse(_ text: String) throws -> Int32 {
        guard let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else {
            throw LocateError.invalidDeviceList("invalid pid file")
        }
        return pid
    }
}

public final class ProcessRunner: @unchecked Sendable {
    public init() {}

    @discardableResult
    public func run(_ command: [String], timeout: TimeInterval = 60) throws -> String {
        guard !command.isEmpty else {
            throw LocateError.processControlFailed("Cannot run an empty command")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                process.waitUntilExit()
                throw LocateError.processControlFailed("Command timed out after \(Int(timeout))s: \(command[0])")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw LocateError.invalidDeviceList(stderr.isEmpty ? stdout : stderr)
        }

        return stdout
    }

    public func spawnPersistent(_ command: [String], stdoutURL: URL, stderrURL: URL) throws -> Process {
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.standardOutput = try FileHandle(forWritingTo: stdoutURL)
        process.standardError = try FileHandle(forWritingTo: stderrURL)
        try process.run()
        return process
    }
}

public actor LocationSessionController {
    private let commands: LocateSessionCommands
    private let runner: ProcessRunner
    private let fileManager: FileManager

    public init(
        commands: LocateSessionCommands,
        runner: ProcessRunner = ProcessRunner(),
        fileManager: FileManager = .default
    ) {
        self.commands = commands
        self.runner = runner
        self.fileManager = fileManager
    }

    public func ensureStateDirectory() throws {
        try fileManager.createDirectory(
            at: commands.files.directory,
            withIntermediateDirectories: true
        )
    }

    public func readTunnelEndpoint() throws -> RSDEndpoint {
        let output = try String(contentsOf: commands.files.tunnelOutput, encoding: .utf8)
        return try RSDEndpoint.parse(output)
    }

    public func readActiveCoordinate() throws -> Coordinate? {
        guard fileManager.fileExists(atPath: commands.files.activeCoordinate.path) else {
            return nil
        }

        let text = try String(contentsOf: commands.files.activeCoordinate, encoding: .utf8)
        let parts = text
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "," })
            .compactMap { Double($0) }
        guard parts.count == 2 else {
            throw LocateError.invalidCoordinate("Stored active coordinate is invalid")
        }

        return try Coordinate(latitude: parts[0], longitude: parts[1])
    }

    public func startTunnel(device: DeviceInfo) throws {
        try ensureStateDirectory()
        let script = commands.adminTunnelScript(device: device)
        _ = try runner.run(script.osascriptCommand, timeout: 120)
    }

    public func prepare(endpoint: RSDEndpoint) throws {
        let developerModeOutput = try runner.run(commands.paths.developerModeCommand(endpoint: endpoint))
        guard try DeveloperMode.isEnabled(developerModeOutput) else {
            throw LocateError.invalidDeviceList("Developer Mode is disabled on the target iPhone")
        }
        _ = try runner.run(commands.paths.autoMountCommand(endpoint: endpoint))
    }

    public func setLocation(endpoint: RSDEndpoint, coordinate: Coordinate) throws {
        try ensureStateDirectory()
        try terminateStoredSetProcess()
        _ = try runner.run(commands.persistentSetCommand(endpoint: endpoint, coordinate: coordinate))
        try verifySetProcessStarted()
        try "\(coordinate.latitudeText) \(coordinate.longitudeText)\n"
            .write(to: commands.files.activeCoordinate, atomically: true, encoding: .utf8)
    }

    public func clearLocation(endpoint: RSDEndpoint) throws {
        var clearError: Error?
        do {
            _ = try runner.run(commands.clearCommand(endpoint: endpoint))
        } catch {
            clearError = error
        }

        try terminateStoredSetProcess()
        try? fileManager.removeItem(at: commands.files.setPID)

        if let clearError {
            throw clearError
        }

        try? fileManager.removeItem(at: commands.files.activeCoordinate)
    }

    public func stopSetProcess() throws {
        try terminateStoredSetProcess()
        try? fileManager.removeItem(at: commands.files.setPID)
    }

    public func stopTunnel() throws {
        let script = commands.adminStopTunnelScript()
        _ = try runner.run(script.osascriptCommand)
    }

    private func verifySetProcessStarted() throws {
        let pid = try readStoredPID(commands.files.setPID)
        for _ in 0..<10 {
            if let commandLine = processCommandLine(pid: pid),
               ProcessMatcher.isSimulatedLocationSetCommand(commandLine) {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        let errorText = (try? String(contentsOf: commands.files.setError, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try? fileManager.removeItem(at: commands.files.setPID)
        if let errorText, !errorText.isEmpty {
            throw LocateError.processControlFailed("simulate-location set exited early: \(errorText)")
        }
        throw LocateError.processControlFailed("simulate-location set did not stay running")
    }

    private func terminateStoredSetProcess() throws {
        guard let pid = try? readStoredPID(commands.files.setPID) else {
            try? fileManager.removeItem(at: commands.files.setPID)
            return
        }

        guard let commandLine = processCommandLine(pid: pid),
              ProcessMatcher.isSimulatedLocationSetCommand(commandLine) else {
            try? fileManager.removeItem(at: commands.files.setPID)
            return
        }

        let result = Darwin.kill(pid, SIGTERM)
        if result != 0 && errno != ESRCH {
            throw LocateError.processControlFailed("Could not terminate simulated location process \(pid): errno \(errno)")
        }

        try? fileManager.removeItem(at: commands.files.setPID)
    }

    private func readStoredPID(_ url: URL) throws -> Int32 {
        let pidText = try String(contentsOf: url, encoding: .utf8)
        return try PIDFile.parse(pidText)
    }

    private func processCommandLine(pid: Int32) -> String? {
        try? runner.run(["/bin/ps", "-p", String(pid), "-o", "command="])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
