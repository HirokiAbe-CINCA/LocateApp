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
            let executable = URL(fileURLWithPath: token).lastPathComponent
            return executable == "pymobiledevice3" ||
                executable == "pymobiledevice3-helper" ||
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

        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocateAppProcess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: outputDirectory)
        }
        let stdoutURL = outputDirectory.appendingPathComponent("stdout")
        let stderrURL = outputDirectory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                let terminationDeadline = Date().addingTimeInterval(0.75)
                while process.isRunning && Date() < terminationDeadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
                process.waitUntilExit()
                throw LocateError.processControlFailed("Command timed out after \(Int(timeout))s: \(command[0])")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        try? stdoutHandle.close()
        try? stderrHandle.close()
        let stdout = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""

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

public final class TunneldClient: @unchecked Sendable {
    private let socketPath: String

    public init(socketPath: String = TunneldProtocol.socketPath) {
        self.socketPath = socketPath
    }

    public func startTunnel(device: DeviceInfo) async throws -> RSDEndpoint {
        let text = try await send(command: "start-tunnel", deviceID: device.identifier)
        return try TunneldStartTunnelResponse.parse(text).endpoint
    }

    public func endpoint(device: DeviceInfo) async throws -> RSDEndpoint? {
        let text = try await send(command: "list-tunnels", deviceID: device.identifier)
        return try TunneldListResponse.parse(text).endpoint(for: device.identifier)
    }

    public func stopTunnel(device: DeviceInfo) async throws {
        let text = try await send(command: "stop-tunnel", deviceID: device.identifier)
        if let error = TunneldProtocol.errorMessage(from: text) {
            throw LocateError.processControlFailed(error)
        }
    }

    private func send(command: String, deviceID: String) async throws -> String {
        let socketPath = self.socketPath
        let requestData = try TunneldProtocol.requestData(command: command, deviceID: deviceID)
        return try await Task.detached {
            try Self.sendBlocking(requestData: requestData, socketPath: socketPath)
        }.value
    }

    private static func sendBlocking(requestData: Data, socketPath: String) throws -> String {
        let socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw LocateError.processControlFailed("tunneld socketを作成できませんでした: errno \(errno)")
        }
        defer {
            Darwin.close(socketFD)
        }
        try setSocketTimeouts(socketFD, seconds: 75)

        var address = try unixSocketAddress(path: socketPath)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw LocateError.processControlFailed("特権tunneldに接続できませんでした: errno \(errno)")
        }

        var payload = requestData
        payload.append(0x0a)
        try payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            var offset = 0
            while offset < payload.count {
                let written = Darwin.write(socketFD, baseAddress.advanced(by: offset), payload.count - offset)
                if written > 0 {
                    offset += written
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw LocateError.processControlFailed("特権tunneldへの送信がタイムアウトしました")
                } else if errno != EINTR {
                    throw LocateError.processControlFailed("特権tunneldへの送信に失敗しました: errno \(errno)")
                }
            }
        }
        Darwin.shutdown(socketFD, SHUT_WR)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(socketFD, &buffer, buffer.count)
            if count > 0 {
                response.append(buffer, count: count)
            } else if count == 0 {
                break
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                throw LocateError.processControlFailed("特権tunneldからの応答がタイムアウトしました")
            } else if errno != EINTR {
                throw LocateError.processControlFailed("特権tunneldからの応答受信に失敗しました: errno \(errno)")
            }
        }

        guard let text = String(data: response, encoding: .utf8) else {
            throw LocateError.invalidRSDOutput("tunneld response was not UTF-8")
        }
        if let error = TunneldProtocol.errorMessage(from: text) {
            throw LocateError.processControlFailed(error)
        }
        return text
    }

    private static func unixSocketAddress(path: String) throws -> sockaddr_un {
        let pathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard path.utf8.count < pathCapacity else {
            throw LocateError.processControlFailed("tunneld socket path is too long")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        #if os(macOS)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        _ = path.withCString { pathPointer in
            withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
                tuplePointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { buffer in
                    strncpy(buffer, pathPointer, pathCapacity - 1)
                }
            }
        }
        return address
    }

    private static func setSocketTimeouts(_ socketFD: Int32, seconds: Int) throws {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        let receiveResult = withUnsafePointer(to: &timeout) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<timeval>.size) { bytes in
                Darwin.setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, bytes, socklen_t(MemoryLayout<timeval>.size))
            }
        }
        guard receiveResult == 0 else {
            throw LocateError.processControlFailed("tunneld socket receive timeoutを設定できませんでした: errno \(errno)")
        }

        let sendResult = withUnsafePointer(to: &timeout) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<timeval>.size) { bytes in
                Darwin.setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, bytes, socklen_t(MemoryLayout<timeval>.size))
            }
        }
        guard sendResult == 0 else {
            throw LocateError.processControlFailed("tunneld socket send timeoutを設定できませんでした: errno \(errno)")
        }
    }
}

public actor LocationSessionController {
    private let commands: LocateSessionCommands
    private let runner: ProcessRunner
    private let tunneldClient: TunneldClient
    private let fileManager: FileManager

    public init(
        commands: LocateSessionCommands,
        runner: ProcessRunner = ProcessRunner(),
        tunneldClient: TunneldClient = TunneldClient(),
        fileManager: FileManager = .default
    ) {
        self.commands = commands
        self.runner = runner
        self.tunneldClient = tunneldClient
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

    public func startTunnelUsingTunneld(device: DeviceInfo) async throws -> RSDEndpoint {
        try ensureStateDirectory()
        try terminateStoredTunnelProcess()
        try? fileManager.removeItem(at: commands.files.tunnelOutput)
        try? fileManager.removeItem(at: commands.files.tunnelError)
        try? fileManager.removeItem(at: commands.files.tunnelPID)

        let endpoint = try await tunneldClient.startTunnel(device: device)
        try "\(endpoint.host) \(endpoint.port)\n"
            .write(to: commands.files.tunnelOutput, atomically: true, encoding: .utf8)
        return endpoint
    }

    public func currentTunneldEndpoint(device: DeviceInfo) async throws -> RSDEndpoint? {
        try await tunneldClient.endpoint(device: device)
    }

    public func stopTunneldTunnel(device: DeviceInfo) async throws {
        try await tunneldClient.stopTunnel(device: device)
        try? fileManager.removeItem(at: commands.files.tunnelOutput)
        try? fileManager.removeItem(at: commands.files.tunnelError)
        try? fileManager.removeItem(at: commands.files.tunnelPID)
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

    public func isTunnelHealthy(endpoint: RSDEndpoint) -> Bool {
        do {
            let developerModeOutput = try runner.run(
                commands.paths.developerModeCommand(endpoint: endpoint),
                timeout: 10
            )
            return try DeveloperMode.isEnabled(developerModeOutput)
        } catch {
            return false
        }
    }

    public func isTunnelRunning() -> Bool {
        guard let pid = try? readStoredPID(commands.files.tunnelPID),
              let commandLine = processCommandLine(pid: pid) else {
            return false
        }
        return ProcessMatcher.isTunnelCommand(commandLine)
    }

    public func isSetProcessRunning() -> Bool {
        guard let pid = try? readStoredPID(commands.files.setPID),
              let commandLine = processCommandLine(pid: pid) else {
            return false
        }
        return ProcessMatcher.isSimulatedLocationSetCommand(commandLine)
    }

    public func storedTunnelPID() -> Int32? {
        try? readStoredPID(commands.files.tunnelPID)
    }

    public func storedSetPID() -> Int32? {
        try? readStoredPID(commands.files.setPID)
    }

    public func setErrorOutputSize() -> UInt64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: commands.files.setError.path),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.uint64Value
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

    private func terminateStoredTunnelProcess() throws {
        guard let pid = try? readStoredPID(commands.files.tunnelPID) else {
            return
        }

        guard let commandLine = processCommandLine(pid: pid),
              ProcessMatcher.isTunnelCommand(commandLine) else {
            return
        }

        let result = Darwin.kill(pid, SIGTERM)
        if result != 0 && errno != ESRCH {
            throw LocateError.processControlFailed("Could not terminate tunnel process \(pid): errno \(errno)")
        }
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
