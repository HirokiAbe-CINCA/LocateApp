import Darwin
import Foundation
import LocateAppCore

private final class ManagedTunnel {
    let deviceID: String
    let endpoint: RSDEndpoint
    let process: Process
    let stdoutPipe: Pipe
    let stderrPipe: Pipe

    init(deviceID: String, endpoint: RSDEndpoint, process: Process, stdoutPipe: Pipe, stderrPipe: Pipe) {
        self.deviceID = deviceID
        self.endpoint = endpoint
        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
    }

    func stop() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}

private final class TunnelStartupState: @unchecked Sendable {
    private let condition = NSCondition()
    private var outputText = ""
    private var stderrText = ""
    private var parsedEndpoint: RSDEndpoint?

    func appendOutput(_ text: String) {
        condition.lock()
        outputText += text
        if parsedEndpoint == nil {
            parsedEndpoint = try? RSDEndpoint.parse(outputText)
            if parsedEndpoint != nil {
                condition.signal()
            }
        }
        condition.unlock()
    }

    func appendError(_ text: String) {
        condition.lock()
        stderrText = String((stderrText + text).suffix(4_000))
        condition.unlock()
    }

    func waitForEndpoint(while process: Process, timeout: TimeInterval) -> (endpoint: RSDEndpoint?, stderr: String) {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        while parsedEndpoint == nil && process.isRunning && Date() < deadline {
            condition.wait(until: Date().addingTimeInterval(0.2))
        }
        let result = (parsedEndpoint, stderrText)
        condition.unlock()
        return result
    }
}

private final class LocateTunneldDaemon: @unchecked Sendable {
    private let socketPath = TunneldProtocol.socketPath
    private let lock = NSLock()
    private let tunnelOperationLock = NSLock()
    private var tunnelsByDeviceID: [String: ManagedTunnel] = [:]

    func run() throws -> Never {
        signal(SIGPIPE, SIG_IGN)
        let serverFD = try makeServerSocket()
        while true {
            let clientFD = Darwin.accept(serverFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR {
                    continue
                }
                throw LocateError.processControlFailed("accept failed: errno \(errno)")
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handle(clientFD: clientFD)
            }
        }
    }

    private func makeServerSocket() throws -> Int32 {
        try? FileManager.default.removeItem(atPath: socketPath)

        let serverFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw LocateError.processControlFailed("socket failed: errno \(errno)")
        }

        var address = try unixSocketAddress(path: socketPath)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(serverFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(serverFD)
            throw LocateError.processControlFailed("bind failed: errno \(errno)")
        }

        try enforceSocketPermissions()

        guard Darwin.listen(serverFD, 16) == 0 else {
            Darwin.close(serverFD)
            throw LocateError.processControlFailed("listen failed: errno \(errno)")
        }
        return serverFD
    }

    private func enforceSocketPermissions() throws {
        guard Darwin.chown(socketPath, 0, 80) == 0 else {
            throw LocateError.processControlFailed("chown \(socketPath) failed: errno \(errno)")
        }
        guard Darwin.chmod(socketPath, 0o660) == 0 else {
            throw LocateError.processControlFailed("chmod \(socketPath) failed: errno \(errno)")
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: socketPath)
        let ownerID = (attributes[.ownerAccountID] as? NSNumber)?.intValue
        let groupID = (attributes[.groupOwnerAccountID] as? NSNumber)?.intValue
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue
        guard ownerID == 0,
              groupID == 80,
              mode == 0o660 else {
            throw LocateError.processControlFailed("unexpected socket permissions for \(socketPath)")
        }
    }

    private func handle(clientFD: Int32) {
        let handle = FileHandle(fileDescriptor: clientFD, closeOnDealloc: true)
        do {
            let data = handle.readDataToEndOfFile()
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: String],
                  let command = request["command"] else {
                try write(["error": "invalid request"], to: handle)
                return
            }

            switch command {
            case "start-tunnel":
                let deviceID = try validatedDeviceID(request["udid"])
                let tunnel = try startTunnel(deviceID: deviceID)
                try write([
                    "address": tunnel.endpoint.host,
                    "port": tunnel.endpoint.port
                ], to: handle)
            case "list-tunnels":
                let response = listTunnels()
                try write(response, to: handle)
            case "stop-tunnel":
                let deviceID = try validatedDeviceID(request["udid"])
                stopTunnel(deviceID: deviceID)
                try write(["ok": true], to: handle)
            default:
                try write(["error": "unknown command"], to: handle)
            }
        } catch {
            try? write(["error": error.localizedDescription], to: handle)
        }
    }

    private func startTunnel(deviceID: String) throws -> ManagedTunnel {
        tunnelOperationLock.lock()
        defer {
            tunnelOperationLock.unlock()
        }

        if let existing = runningTunnel(deviceID: deviceID) {
            return existing
        }
        stopTunnelUnlocked(deviceID: deviceID)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let startupState = TunnelStartupState()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            startupState.appendOutput(text)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            startupState.appendError(text)
        }

        let process = Process()
        process.executableURL = try helperURL()
        process.arguments = [
            "lockdown",
            "start-tunnel",
            "--script-mode",
            "--udid",
            deviceID
        ]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [weak self] process in
            self?.removeTunnel(deviceID: deviceID, processIdentifier: process.processIdentifier)
        }

        try process.run()

        let startupResult = startupState.waitForEndpoint(while: process, timeout: 60)

        guard let endpoint = startupResult.endpoint else {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            process.terminate()
            let detail = startupResult.stderr.isEmpty ? "no endpoint was printed" : startupResult.stderr
            throw LocateError.invalidRSDOutput("Could not start tunnel for \(deviceID): \(detail)")
        }

        let tunnel = ManagedTunnel(
            deviceID: deviceID,
            endpoint: endpoint,
            process: process,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe
        )
        lock.lock()
        tunnelsByDeviceID[deviceID] = tunnel
        lock.unlock()
        return tunnel
    }

    private func runningTunnel(deviceID: String) -> ManagedTunnel? {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard let tunnel = tunnelsByDeviceID[deviceID] else {
            return nil
        }
        if tunnel.process.isRunning {
            return tunnel
        }
        tunnelsByDeviceID[deviceID] = nil
        return nil
    }

    private func listTunnels() -> [String: Any] {
        lock.lock()
        let tunnels = tunnelsByDeviceID
        lock.unlock()

        var response: [String: Any] = [:]
        for (deviceID, tunnel) in tunnels where tunnel.process.isRunning {
            response[deviceID] = [[
                "tunnel-address": tunnel.endpoint.host,
                "tunnel-port": tunnel.endpoint.port,
                "interface": "usbmux"
            ]]
        }
        return response
    }

    private func stopTunnel(deviceID: String) {
        tunnelOperationLock.lock()
        defer {
            tunnelOperationLock.unlock()
        }

        stopTunnelUnlocked(deviceID: deviceID)
    }

    private func stopTunnelUnlocked(deviceID: String) {
        lock.lock()
        let tunnel = tunnelsByDeviceID.removeValue(forKey: deviceID)
        lock.unlock()
        tunnel?.stop()
    }

    private func removeTunnel(deviceID: String, processIdentifier: Int32) {
        lock.lock()
        if tunnelsByDeviceID[deviceID]?.process.processIdentifier == processIdentifier {
            tunnelsByDeviceID[deviceID] = nil
        }
        lock.unlock()
    }

    private func helperURL() throws -> URL {
        let executableURL = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath()
        let contentsURL = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let helperURL = contentsURL
            .appendingPathComponent("Resources/pymobiledevice3-helper/pymobiledevice3-helper")
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw LocateError.helperMissing(helperURL.path)
        }
        return helperURL
    }

    private func validatedDeviceID(_ rawDeviceID: String?) throws -> String {
        guard let deviceID = rawDeviceID,
              !deviceID.isEmpty,
              deviceID.count <= 128,
              deviceID.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil else {
            throw LocateError.invalidDeviceList("invalid device identifier")
        }
        return deviceID
    }

    private func write(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0a)
        try handle.write(contentsOf: data)
        try? handle.close()
    }

    private func unixSocketAddress(path: String) throws -> sockaddr_un {
        let pathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard path.utf8.count < pathCapacity else {
            throw LocateError.processControlFailed("socket path is too long")
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
}

do {
    let daemon = LocateTunneldDaemon()
    try daemon.run()
} catch {
    fputs("LocateTunneldDaemon failed: \(error)\n", stderr)
    exit(1)
}
