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
    @Published var status: String = "場所を選んで「この場所に固定」を押してください。"
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
            return "未固定"
        }
        let prefix = activeLocationMayRemain ? "前回の固定が残っている可能性: " : ""
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
            self.status = "補助ツールが見つかりません: \(error.localizedDescription)"
        }
    }

    func refreshDevices() {
        runBusy("iPhoneを確認しています...") {
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
            status = "検索したい場所の名前を入力してください。"
            return
        }
        guard !isSearching else {
            return
        }

        searchRequestSerial += 1
        let requestSerial = searchRequestSerial
        Task {
            isSearching = true
            status = "「\(query)」を検索しています..."
            defer {
                if requestSerial == searchRequestSerial {
                    isSearching = false
                }
            }
            do {
                let results = try await searchService.search(query: query, near: selectedMapCoordinate)
                guard requestSerial == searchRequestSerial else {
                    return
                }
                searchResults = results
                status = results.isEmpty ? "「\(query)」は見つかりませんでした。" : "\(results.count)件見つかりました。使う場所を選んでください。"
            } catch {
                guard requestSerial == searchRequestSerial else {
                    return
                }
                searchResults = []
                status = "検索に失敗しました: \(userFacingMessage(for: error))"
            }
        }
    }

    func useSearchResult(_ result: LocationSearchResult) {
        selectCoordinate(result.coordinate)
        searchQuery = result.title
        selectedLocationName = result.title
        searchResults = []
        status = "「\(result.title)」を選びました。「この場所に固定」を押してください。"
    }

    func usePreset(_ preset: LocationPreset) {
        selectCoordinate(preset.coordinate)
        searchQuery = preset.title
        selectedLocationName = preset.title
        searchResults = []
        status = "「\(preset.title)」を選びました。「この場所に固定」を押してください。"
    }

    func applyCoordinateInput() {
        do {
            let coordinate = try Coordinate.parsePair(coordinateInputText)
            selectCoordinate(CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude))
            status = "\(coordinate.latitudeText), \(coordinate.longitudeText) を選びました。「この場所に固定」を押してください。"
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
                status = "前回の固定位置が残っている可能性があります。解除する場合は「固定を解除」を押してください。"
            }
        }
    }

    func startTunnel() {
        runBusy("接続を準備しています...") {
            _ = try await self.ensureTunnel(forceRestart: true)
            self.status = "接続準備ができました。「この場所に固定」を押してください。"
        }
    }

    func moveToSelectedLocation() {
        runBusy("iPhoneの位置を固定しています...") {
            do {
                let coordinate = try Coordinate.parsePair(self.coordinateInputText)
                if abs(self.selectedMapCoordinate.latitude - coordinate.latitude) > 0.000_001 ||
                    abs(self.selectedMapCoordinate.longitude - coordinate.longitude) > 0.000_001 {
                    self.selectedLocationName = nil
                }
                self.selectedMapCoordinate = CLLocationCoordinate2D(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )
                let endpoint = try await self.ensureTunnel()
                try await self.session.prepare(endpoint: endpoint)
                try await self.session.setLocation(endpoint: endpoint, coordinate: coordinate)
                self.activeCoordinate = coordinate
                self.activeLocationName = self.selectedLocationName
                self.activeLocationMayRemain = false
                self.status = "固定しました。iPhoneを再起動するか「固定を解除」するまで、この位置が使われます。"
            } catch {
                self.rsdEndpoint = nil
                self.rsdDeviceID = nil
                throw error
            }
        }
    }

    func resetLocation() {
        runBusy("固定を解除しています...") {
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
                self.status = "固定を解除しました。iPhoneは通常の位置情報に戻ります。"
            } catch {
                self.activeLocationMayRemain = self.activeCoordinate != nil
                self.status = "Mac側の固定処理は止めましたが、iPhoneへの解除コマンドが届きませんでした: \(self.userFacingMessage(for: error))"
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
        status = devices.isEmpty ? "iPhoneが見つかりません。ケーブル接続、ロック解除、信頼設定を確認してください。" : "\(devices.count)台のiPhoneを検出しました。"
    }

    private func ensureSelectedDevice() async throws -> DeviceInfo {
        if let selectedDevice {
            return selectedDevice
        }

        try await refreshDeviceList()
        guard let selectedDevice else {
            throw LocateError.invalidDeviceList("iPhoneが見つかりません。ケーブル接続、ロック解除、信頼設定を確認してから再試行してください。")
        }
        return selectedDevice
    }

    private func ensureTunnel(forceRestart: Bool = false) async throws -> RSDEndpoint {
        let selectedDevice = try await ensureSelectedDevice()

        if !forceRestart,
           let rsdEndpoint,
           rsdDeviceID == selectedDevice.identifier,
           await session.isTunnelRunning() {
            return rsdEndpoint
        }

        if !forceRestart,
           rsdDeviceID == selectedDevice.identifier,
           await session.isTunnelRunning(),
           let endpoint = try? await session.readTunnelEndpoint() {
            rsdEndpoint = endpoint
            return endpoint
        }

        if forceRestart {
            rsdEndpoint = nil
            rsdDeviceID = nil
        }

        status = "管理者認証が表示されたら承認してください。iPhone接続の準備に使います。"
        try await session.startTunnel(device: selectedDevice)
        status = "iPhone接続の準備完了を待っています..."

        for _ in 0..<30 {
            if let endpoint = try? await session.readTunnelEndpoint() {
                rsdEndpoint = endpoint
                rsdDeviceID = selectedDevice.identifier
                return endpoint
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        rsdEndpoint = nil
        rsdDeviceID = nil
        try? await session.stopTunnel()
        throw LocateError.invalidRSDOutput("15秒以内にiPhone接続を準備できませんでした。iPhoneの接続・ロック解除・管理者認証の承認を確認して、もう一度試してください。急いで解除したい場合はiPhoneを再起動してください。")
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
            return "管理者認証がキャンセルされました。もう一度実行し、表示された認証を承認してください。"
        }
        if message.localizedCaseInsensitiveContains("No route to host") ||
            message.localizedCaseInsensitiveContains("Connection refused") {
            return "iPhoneに接続できません。ケーブル接続とロック解除を確認してください。iPhoneを再起動しても固定は解除されます。"
        }
        if message.localizedCaseInsensitiveContains("pymobiledevice3 was not found") {
            return "補助ツールが見つかりません。配布版を使うか、READMEのセットアップを実行してから開き直してください。"
        }
        return message
    }
}
