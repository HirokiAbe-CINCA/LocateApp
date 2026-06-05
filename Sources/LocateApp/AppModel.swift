import AppKit
import Combine
import CoreLocation
import Foundation
import LocateAppCore

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [DeviceInfo] = []
    @Published var selectedDeviceID: String?
    @Published var selectedMapCoordinate = CLLocationCoordinate2D(latitude: 35.681236, longitude: 139.767125)
    @Published var status: String = "Ready"
    @Published var isBusy = false
    @Published var isSearching = false
    @Published var rsdEndpoint: RSDEndpoint?
    @Published var activeCoordinate: Coordinate?
    @Published var activeLocationMayRemain = false
    @Published var searchQuery: String = ""
    @Published var searchResults: [LocationSearchResult] = []
    @Published var coordinateInputText: String = "35.681236, 139.767125"
    @Published var selectedLocationName: String?
    @Published var activeLocationName: String?
    private var rsdDeviceID: String?

    private let paths: LocatePaths
    private let session: LocationSessionController
    private let searchService = LocationSearchService()
    private var searchRequestSerial = 0

    var selectedDevice: DeviceInfo? {
        devices.first { $0.identifier == selectedDeviceID } ?? devices.first
    }

    var selectedCoordinateText: String {
        let coordinateText = String(format: "%.6f, %.6f", selectedMapCoordinate.latitude, selectedMapCoordinate.longitude)
        if let selectedLocationName {
            return "\(selectedLocationName) (\(coordinateText))"
        }
        return coordinateText
    }

    var activeCoordinateText: String {
        guard let activeCoordinate else {
            return "Not fixed"
        }
        let prefix = activeLocationMayRemain ? "May still be active: " : ""
        if let activeLocationName {
            return "\(prefix)\(activeLocationName) (\(activeCoordinate.latitudeText), \(activeCoordinate.longitudeText))"
        }
        return "\(prefix)\(activeCoordinate.latitudeText), \(activeCoordinate.longitudeText)"
    }

    var stateDirectoryPath: String {
        paths.stateDirectory.path
    }

    var stateDirectoryURL: URL {
        paths.stateDirectory
    }

    let presets = LocationPreset.defaults

    init() {
        do {
            let paths = try LocatePaths.discover()
            self.paths = paths
            self.session = LocationSessionController(commands: LocateSessionCommands(paths: paths))
        } catch {
            let fallbackRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let fallbackHelper = fallbackRoot.appendingPathComponent(".venv/bin/pymobiledevice3")
            self.paths = LocatePaths(root: fallbackRoot, pymobiledevicePath: fallbackHelper)
            self.session = LocationSessionController(commands: LocateSessionCommands(paths: self.paths))
            self.status = "Helper not found: \(error.localizedDescription)"
        }
    }

    func refreshDevices() {
        runBusy("Refreshing devices...") {
            try await self.refreshDeviceList()
        }
    }

    func selectDevice(_ identifier: String) {
        selectedDeviceID = identifier
        if rsdDeviceID != identifier {
            rsdEndpoint = nil
            rsdDeviceID = nil
        }
    }

    func selectCoordinate(_ coordinate: CLLocationCoordinate2D) {
        selectedMapCoordinate = coordinate
        coordinateInputText = String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
        selectedLocationName = nil
    }

    func searchPlaces() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            status = "Enter a place name to search."
            return
        }
        guard !isSearching else {
            return
        }

        searchRequestSerial += 1
        let requestSerial = searchRequestSerial
        Task {
            isSearching = true
            status = "Searching for \(query)..."
            do {
                let results = try await searchService.search(query: query, near: selectedMapCoordinate)
                guard requestSerial == searchRequestSerial else {
                    return
                }
                searchResults = results
                status = results.isEmpty ? "No places found for \(query)" : "Found \(results.count) place(s)"
            } catch {
                guard requestSerial == searchRequestSerial else {
                    return
                }
                searchResults = []
                status = "Search failed: \(userFacingMessage(for: error))"
            }
            if requestSerial == searchRequestSerial {
                isSearching = false
            }
        }
    }

    func useSearchResult(_ result: LocationSearchResult) {
        selectCoordinate(result.coordinate)
        searchQuery = result.title
        selectedLocationName = result.title
        searchResults = []
        status = "Selected \(result.title)"
    }

    func usePreset(_ preset: LocationPreset) {
        selectCoordinate(preset.coordinate)
        searchQuery = preset.title
        selectedLocationName = preset.title
        searchResults = []
        status = "Selected \(preset.title)"
    }

    func applyCoordinateInput() {
        do {
            let coordinate = try Coordinate.parsePair(coordinateInputText)
            selectCoordinate(CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude))
            status = "Selected \(coordinate.latitudeText), \(coordinate.longitudeText)"
        } catch {
            status = userFacingMessage(for: error)
        }
    }

    func openStateDirectory() {
        do {
            try FileManager.default.createDirectory(
                at: stateDirectoryURL,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.activateFileViewerSelecting([stateDirectoryURL])
        } catch {
            status = userFacingMessage(for: error)
        }
    }

    func restorePreviousSession() {
        Task {
            if let coordinate = try? await session.readActiveCoordinate() {
                activeCoordinate = coordinate
                activeLocationMayRemain = true
                status = "Previous location session found"
            }
        }
    }

    func startTunnel() {
        runBusy("Starting tunnel...") {
            _ = try await self.ensureTunnel(forceRestart: true)
            self.status = "Tunnel ready"
        }
    }

    func moveToSelectedLocation() {
        runBusy("Moving iPhone...") {
            do {
                let coordinate = try Coordinate(
                    latitude: self.selectedMapCoordinate.latitude,
                    longitude: self.selectedMapCoordinate.longitude
                )
                let endpoint = try await self.ensureTunnel()
                try await self.session.prepare(endpoint: endpoint)
                try await self.session.setLocation(endpoint: endpoint, coordinate: coordinate)
                self.activeCoordinate = coordinate
                self.activeLocationName = self.selectedLocationName
                self.activeLocationMayRemain = false
                self.status = "Location fixed at \(coordinate.latitudeText), \(coordinate.longitudeText)"
            } catch {
                self.rsdEndpoint = nil
                self.rsdDeviceID = nil
                throw error
            }
        }
    }

    func resetLocation() {
        runBusy("Resetting location...") {
            try await self.session.stopSetProcess()

            do {
                let endpoint = try await self.ensureTunnel(forceRestart: true)
                try await self.session.clearLocation(endpoint: endpoint)
                try? await self.session.stopTunnel()
                self.rsdEndpoint = nil
                self.rsdDeviceID = nil
                self.activeCoordinate = nil
                self.activeLocationName = nil
                self.activeLocationMayRemain = false
                self.status = "Location reset"
            } catch {
                self.activeLocationMayRemain = self.activeCoordinate != nil
                self.status = "Local location process stopped. Clear command could not reach the iPhone: \(self.userFacingMessage(for: error))"
            }
        }
    }

    private func refreshDeviceList() async throws {
        let command = paths.listDevicesCommand
        let output = try await runDetached {
            try ProcessRunner().run(command)
        }
        let devices = try DeviceInfo.parseList(output)
        self.devices = devices
        if selectedDeviceID == nil || !devices.contains(where: { $0.identifier == selectedDeviceID }) {
            selectedDeviceID = devices.first?.identifier
        }
        if let rsdDeviceID, !devices.contains(where: { $0.identifier == rsdDeviceID }) {
            rsdEndpoint = nil
            self.rsdDeviceID = nil
        }
        status = devices.isEmpty ? "No iPhone visible. Connect, unlock, and trust the iPhone." : "Found \(devices.count) device(s)"
    }

    private func ensureSelectedDevice() async throws -> DeviceInfo {
        if let selectedDevice {
            return selectedDevice
        }

        try await refreshDeviceList()
        guard let selectedDevice else {
            throw LocateError.invalidDeviceList("No iPhone visible. Connect, unlock, and trust the iPhone, then try again.")
        }
        return selectedDevice
    }

    private func ensureTunnel(forceRestart: Bool = false) async throws -> RSDEndpoint {
        let selectedDevice = try await ensureSelectedDevice()

        if !forceRestart, let rsdEndpoint, rsdDeviceID == selectedDevice.identifier {
            return rsdEndpoint
        }

        if !forceRestart, rsdDeviceID == selectedDevice.identifier, let endpoint = try? await session.readTunnelEndpoint() {
            rsdEndpoint = endpoint
            return endpoint
        }

        status = "Approve the macOS administrator prompt to start the iPhone tunnel."
        try await session.startTunnel(device: selectedDevice)
        status = "Waiting for the iPhone tunnel..."

        for _ in 0..<30 {
            if let endpoint = try? await session.readTunnelEndpoint() {
                rsdEndpoint = endpoint
                rsdDeviceID = selectedDevice.identifier
                return endpoint
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        throw LocateError.invalidRSDOutput("Tunnel did not start within 15 seconds. Confirm the iPhone is connected and unlocked, approve the macOS administrator prompt, then try again. If you need immediate recovery, restart the iPhone.")
    }

    private func runBusy(_ busyStatus: String, operation: @escaping () async throws -> Void) {
        Task {
            isBusy = true
            status = busyStatus
            do {
                try await operation()
            } catch {
                status = userFacingMessage(for: error)
            }
            isBusy = false
        }
    }

    private func runDetached<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached {
            try operation()
        }.value
    }

    private func userFacingMessage(for error: Error) -> String {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("User canceled") ||
            message.localizedCaseInsensitiveContains("(-128)") {
            return "The administrator prompt was canceled. Try again and approve it to start the iPhone tunnel."
        }
        if message.localizedCaseInsensitiveContains("No route to host") ||
            message.localizedCaseInsensitiveContains("Connection refused") {
            return "The iPhone tunnel is not reachable. Connect and unlock the iPhone, then use Reset Location again. Restarting the iPhone also clears the simulated location."
        }
        if message.localizedCaseInsensitiveContains("pymobiledevice3 was not found") {
            return "pymobiledevice3 is missing. Run the setup command in README.md, then reopen the app."
        }
        return message
    }
}
