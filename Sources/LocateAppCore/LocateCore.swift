import Foundation

public enum LocateError: Error, Equatable, LocalizedError, Sendable {
    case invalidDeviceList(String)
    case missingDeviceIdentifier
    case invalidRSDOutput(String)
    case invalidCoordinate(String)
    case helperMissing(String)
    case processControlFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDeviceList(let message):
            return "Invalid device list: \(message)"
        case .missingDeviceIdentifier:
            return "Device entry is missing Identifier"
        case .invalidRSDOutput(let output):
            return "Invalid RSD output: \(output)"
        case .invalidCoordinate(let message):
            return message
        case .helperMissing(let path):
            return "pymobiledevice3 was not found at \(path)"
        case .processControlFailed(let message):
            return message
        }
    }
}

public struct DeviceInfo: Equatable, Identifiable, Sendable {
    public let identifier: String
    public let name: String
    public let productVersion: String
    public let connectionType: String

    public var id: String { identifier }

    public init(
        identifier: String,
        name: String,
        productVersion: String,
        connectionType: String
    ) {
        self.identifier = identifier
        self.name = name
        self.productVersion = productVersion
        self.connectionType = connectionType
    }

    public static func parseList(_ jsonText: String) throws -> [DeviceInfo] {
        let data = Data(jsonText.utf8)
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LocateError.invalidDeviceList(error.localizedDescription)
        }

        guard let entries = raw as? [[String: Any]] else {
            throw LocateError.invalidDeviceList("expected a JSON array")
        }

        return try entries.map { entry in
            guard let identifier = entry["Identifier"] as? String, !identifier.isEmpty else {
                throw LocateError.missingDeviceIdentifier
            }

            return DeviceInfo(
                identifier: identifier,
                name: entry["DeviceName"] as? String ?? "iPhone",
                productVersion: entry["ProductVersion"] as? String ?? "unknown",
                connectionType: entry["ConnectionType"] as? String ?? "unknown"
            )
        }
    }
}

public struct RSDEndpoint: Equatable, Sendable {
    public let host: String
    public let port: String

    public init(host: String, port: String) {
        self.host = host
        self.port = port
    }

    public static func parse(_ output: String) throws -> RSDEndpoint {
        let parts = output
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)

        guard parts.count == 2, Int(parts[1]) != nil else {
            throw LocateError.invalidRSDOutput(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return RSDEndpoint(host: parts[0], port: parts[1])
    }
}

public struct Coordinate: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) throws {
        guard latitude.isFinite, longitude.isFinite else {
            throw LocateError.invalidCoordinate("Coordinates must be finite numbers")
        }
        guard (-90...90).contains(latitude) else {
            throw LocateError.invalidCoordinate("latitude must be between -90 and 90")
        }
        guard (-180...180).contains(longitude) else {
            throw LocateError.invalidCoordinate("longitude must be between -180 and 180")
        }

        self.latitude = latitude
        self.longitude = longitude
    }

    public static func parsePair(_ text: String) throws -> Coordinate {
        let parts = text
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
        guard parts.count == 2,
              let latitude = Double(parts[0]),
              let longitude = Double(parts[1]) else {
            throw LocateError.invalidCoordinate("Enter coordinates as latitude, longitude.")
        }

        return try Coordinate(latitude: latitude, longitude: longitude)
    }

    public var latitudeText: String {
        Coordinate.format(latitude)
    }

    public var longitudeText: String {
        Coordinate.format(longitude)
    }

    private static func format(_ value: Double) -> String {
        var text = String(format: "%.6f", value)
        while text.contains(".") && text.last == "0" {
            text.removeLast()
        }
        if text.last == "." {
            text.removeLast()
        }
        return text
    }
}

public enum DeveloperMode {
    public static func isEnabled(_ output: String) throws -> Bool {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch text {
        case "true", "1", "yes", "enabled":
            return true
        case "false", "0", "no", "disabled":
            return false
        default:
            throw LocateError.invalidDeviceList("unexpected Developer Mode status: \(output)")
        }
    }
}

public struct LocatePaths: Equatable, Sendable {
    public let root: URL
    public let pymobiledevicePath: URL

    public init(root: URL, pymobiledevicePath: URL) {
        self.root = root
        self.pymobiledevicePath = pymobiledevicePath
    }

    public static func discover(
        startingAt startURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) throws -> LocatePaths {
        var candidate = startURL
        if candidate.pathExtension == "app" {
            candidate.deleteLastPathComponent()
        }

        for _ in 0..<8 {
            let helper = candidate.appendingPathComponent(".venv/bin/pymobiledevice3")
            if fileManager.isExecutableFile(atPath: helper.path) {
                return LocatePaths(root: candidate, pymobiledevicePath: helper)
            }
            candidate.deleteLastPathComponent()
        }

        let fallback = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let helper = fallback.appendingPathComponent(".venv/bin/pymobiledevice3")
        if fileManager.isExecutableFile(atPath: helper.path) {
            return LocatePaths(root: fallback, pymobiledevicePath: helper)
        }

        throw LocateError.helperMissing(helper.path)
    }

    public var stateDirectory: URL {
        root.appendingPathComponent(".locateapp", isDirectory: true)
    }

    public var listDevicesCommand: [String] {
        [pymobiledevicePath.path, "usbmux", "list"]
    }

    public func developerModeCommand(endpoint: RSDEndpoint) -> [String] {
        [
            pymobiledevicePath.path,
            "mounter",
            "query-developer-mode-status",
            "--rsd",
            endpoint.host,
            endpoint.port
        ]
    }

    public func autoMountCommand(endpoint: RSDEndpoint) -> [String] {
        [
            pymobiledevicePath.path,
            "mounter",
            "auto-mount",
            "--rsd",
            endpoint.host,
            endpoint.port
        ]
    }

    public func tunnelCommand(device: DeviceInfo) -> [String] {
        [
            pymobiledevicePath.path,
            "lockdown",
            "start-tunnel",
            "--script-mode",
            "--udid",
            device.identifier
        ]
    }

    public func setLocationCommand(endpoint: RSDEndpoint, coordinate: Coordinate) -> [String] {
        [
            pymobiledevicePath.path,
            "developer",
            "dvt",
            "simulate-location",
            "set",
            "--rsd",
            endpoint.host,
            endpoint.port,
            "--",
            coordinate.latitudeText,
            coordinate.longitudeText
        ]
    }

    public func clearLocationCommand(endpoint: RSDEndpoint) -> [String] {
        [
            pymobiledevicePath.path,
            "developer",
            "dvt",
            "simulate-location",
            "clear",
            "--rsd",
            endpoint.host,
            endpoint.port
        ]
    }
}
