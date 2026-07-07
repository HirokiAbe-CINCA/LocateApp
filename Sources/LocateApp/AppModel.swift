import AppKit
import Combine
import CoreLocation
import Foundation
import LocateAppCore
import ServiceManagement
@preconcurrency import UserNotifications

private final class PowerEventObserverBag {
    private var observers: [NSObjectProtocol] = []

    var isEmpty: Bool {
        observers.isEmpty
    }

    func replace(with observers: [NSObjectProtocol]) {
        for observer in self.observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        self.observers = observers
    }

    deinit {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}

enum ConnectionStateKind {
    case unavailable
    case detected
    case preparing
    case ready
    case failed
}

enum PrivilegedTunneldStatusKind: Equatable {
    case unknown
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case failed(String)
}

struct LocationEventLogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let message: String

    var timeText: String {
        Self.timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [DeviceInfo] = []
    @Published var selectedDeviceID: String?
    @Published var selectedMapCoordinate = CLLocationCoordinate2D(latitude: 35.681236, longitude: 139.767125)
    @Published var status: String = "移動先を選んで「この場所に移動」を押してください。"
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
    @Published var isPreventingSleep = false
    @Published var activeLocationStartedAt: Date?
    @Published var isLocationContinuityMonitoring = false
    @Published var lastContinuityCheckAt: Date?
    @Published var lastContinuityHealthyAt: Date?
    @Published var monitoringNow = Date()
    @Published var locationEventLog: [LocationEventLogEntry] = []
    @Published var keepsTryingAutoRecovery = true
    @Published var autoRecoveryRetryDelaySeconds: Double = 10
    @Published var autoRecoveryMaximumDelaySeconds: Double = 120
    @Published var autoReapplyAfterWake = true
    @Published var hasDetectedDeviceReconnect = false
    @Published var privilegedTunneldStatusText = "特権tunneld: 状態を確認中"
    @Published var privilegedTunneldHelpText = "無人の自動再接続にはSMAppServiceで登録したtunneldが必要です。"
    @Published var canRegisterPrivilegedTunneld = false
    @Published var canOpenPrivilegedTunneldSettings = false
    private var activeDeviceID: String?
    private var rsdDeviceID: String?
    private var privilegedTunneldStatusKind: PrivilegedTunneldStatusKind = .unknown
    @Published private var isPreparingConnection = false
    @Published private var connectionFailureMessage: String?

    private let paths: LocatePaths
    private let session: LocationSessionController
    private let sleepPreventer = SleepPreventer()
    private let appNapPreventer = AppNapPreventer()
    private let searchService = LocationSearchService()
    private var searchRequestSerial = 0
    private var locationContinuityTask: Task<Void, Never>?
    private var autoRecoveryTask: Task<Void, Never>?
    private var autoRecoveryGeneration = 0
    private var tunnelPreparationGeneration = 0
    private var continuityCheckCount = 0
    private var observedSetErrorOutputSize: UInt64 = 0
    private var monitoringClockTask: Task<Void, Never>?
    private var processExitSources: [DispatchSourceProcess] = []
    private var processWatcherGeneration = 0
    private let powerEventObserverBag = PowerEventObserverBag()
    private static let privilegedTunneldPlistName = "jp.cinca.LocateApp.tunneld.plist"

    deinit {
        locationContinuityTask?.cancel()
        autoRecoveryTask?.cancel()
        monitoringClockTask?.cancel()
        processExitSources.forEach { $0.cancel() }
    }

    var selectedDevice: DeviceInfo? {
        devices.first { $0.identifier == selectedDeviceID } ?? devices.first
    }

    var connectionStateKind: ConnectionStateKind {
        if connectionFailureMessage != nil {
            return .failed
        }
        if isPreparingConnection {
            return .preparing
        }
        guard selectedDevice != nil else {
            return .unavailable
        }
        if rsdEndpoint != nil {
            return .ready
        }
        return .detected
    }

    var connectionStateTitle: String {
        switch connectionStateKind {
        case .failed:
            return "接続失敗"
        case .preparing:
            return "通信準備中"
        case .unavailable:
            return "iPhone未接続"
        case .ready:
            return "通信準備完了"
        case .detected:
            return "iPhone検出済み"
        }
    }

    var connectionStateDetail: String {
        if let connectionFailureMessage {
            return connectionFailureMessage
        }
        if isPreparingConnection {
            return "特権tunneldでiPhone接続を準備しています。"
        }
        guard let selectedDevice else {
            return "USB接続、ロック解除、信頼設定を確認してください。"
        }

        var detail = "\(selectedDevice.name) / iOS \(selectedDevice.productVersion)"
        if let rsdEndpoint {
            detail += " / \(rsdEndpoint.host) \(rsdEndpoint.port)"
        }
        return detail
    }

    var selectedCoordinateText: String {
        let coordinateText = String(format: "%.6f, %.6f", selectedMapCoordinate.latitude, selectedMapCoordinate.longitude)
        if let selectedLocationName {
            return "\(selectedLocationName) (\(coordinateText))"
        }
        return coordinateText
    }

    var activeLocationTitle: String {
        guard activeCoordinate != nil else {
            return "未移動"
        }
        return activeLocationName ?? "名称なし"
    }

    var activeCoordinateDetail: String {
        guard let activeCoordinate else {
            return "iPhoneは通常の位置情報を使っています。"
        }
        let coordinateText = "\(activeCoordinate.latitudeText), \(activeCoordinate.longitudeText)"
        return activeLocationMayRemain ? "前回の移動先の可能性: \(coordinateText)" : coordinateText
    }

    var activeLocationCaution: String? {
        guard activeCoordinate != nil else {
            return nil
        }
        if activeLocationMayRemain {
            return "USB接続、蓋閉じ、Macのスリープ状態により、すでに解除されている可能性があります。"
        }
        if isPreventingSleep {
            return "Macの自動スリープを止めています。USBを抜く、蓋を閉じる、Macをスリープ/終了すると解除されることがあります。"
        }
        return "USBを抜く、蓋を閉じる、Macをスリープ/終了すると解除されることがあります。"
    }

    var continuityRuntimeText: String? {
        guard activeCoordinate != nil,
              !activeLocationMayRemain,
              let activeLocationStartedAt else {
            return nil
        }
        return "移動中 \(Self.durationText(monitoringNow.timeIntervalSince(activeLocationStartedAt)))"
    }

    var continuityMonitorText: String {
        guard activeCoordinate != nil else {
            return "監視停止"
        }

        let phase: String
        if autoRecoveryTask != nil {
            phase = "自動再接続中"
        } else if activeLocationMayRemain {
            phase = "不確実"
        } else if isLocationContinuityMonitoring {
            phase = "監視中"
        } else {
            phase = "監視停止"
        }

        guard let lastContinuityCheckAt else {
            return phase
        }
        let elapsed = max(0, monitoringNow.timeIntervalSince(lastContinuityCheckAt))
        return "\(phase) (最終確認 \(Self.relativeSecondsText(elapsed)))"
    }

    var autoRecoveryPolicySummary: String {
        if keepsTryingAutoRecovery {
            return "復旧を諦めず、\(Int(autoRecoveryRetryDelaySeconds))秒から最大\(Int(autoRecoveryMaximumDelaySeconds))秒まで指数バックオフします。"
        }
        return "最大3回、\(Int(autoRecoveryRetryDelaySeconds))秒から最大\(Int(autoRecoveryMaximumDelaySeconds))秒まで再試行します。"
    }

    var privilegedTunneldIsEnabled: Bool {
        privilegedTunneldStatusKind == .enabled
    }

    var shouldHighlightReapplyAction: Bool {
        canReapplyActiveLocation && hasDetectedDeviceReconnect
    }

    var canReapplyActiveLocation: Bool {
        LocationReapplyPrompt.isAvailable(
            hasActiveCoordinate: activeCoordinate != nil,
            activeLocationMayRemain: activeLocationMayRemain
        )
    }

    var stateDirectoryPath: String {
        paths.stateDirectory.path
    }

    var stateDirectoryURL: URL {
        paths.stateDirectory
    }

    var currentVersionText: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    private var currentAutoRecoveryPolicy: LocationAutoRecoveryPolicy {
        LocationAutoRecoveryPolicy(
            maxAttempts: keepsTryingAutoRecovery ? nil : 3,
            retryDelaySeconds: autoRecoveryRetryDelaySeconds,
            maximumRetryDelaySeconds: autoRecoveryMaximumDelaySeconds
        )
    }

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
        updatePrivilegedTunneldStatus()
    }

    func refreshPrivilegedTunneldStatus() {
        updatePrivilegedTunneldStatus()
        status = privilegedTunneldHelpText
    }

    func registerPrivilegedTunneld() {
        Task {
            isBusy = true
            status = "特権tunneldを登録しています..."
            do {
                try privilegedTunneldService.register()
                updatePrivilegedTunneldStatus()
                if canOpenPrivilegedTunneldSettings {
                    SMAppService.openSystemSettingsLoginItems()
                }
                status = privilegedTunneldHelpText
            } catch {
                updatePrivilegedTunneldStatus(error: error)
                status = userFacingMessage(for: error)
            }
            isBusy = false
        }
    }

    func openPrivilegedTunneldSettings() {
        SMAppService.openSystemSettingsLoginItems()
        updatePrivilegedTunneldStatus()
        status = privilegedTunneldHelpText
    }

    func refreshDevices() {
        runBusy("iPhoneを確認しています...") {
            do {
                try await self.refreshDeviceList()
            } catch {
                self.connectionFailureMessage = self.userFacingMessage(for: error)
                throw error
            }
        }
    }

    func selectDevice(_ identifier: String) {
        let selectionChanged = selectedDeviceID != identifier
        if selectionChanged {
            cancelAutoRecovery()
        }
        selectedDeviceID = identifier
        connectionFailureMessage = nil
        if rsdDeviceID != identifier {
            rsdEndpoint = nil
            rsdDeviceID = nil
        }
        if selectionChanged,
           activeCoordinate != nil,
           let activeDeviceID,
           activeDeviceID != identifier {
            markActiveLocationUncertain(
                reason: "対象iPhoneが変更されたため、自動再接続を停止しました。必要なiPhoneを選び直して「前回の場所へ再移動」を選んでください。"
            )
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
        status = "「\(result.title)」を選びました。「この場所に移動」を押してください。"
    }

    func applyCoordinateInput() {
        do {
            let coordinate = try Coordinate.parsePair(coordinateInputText)
            selectCoordinate(CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude))
            status = "\(coordinate.latitudeText), \(coordinate.longitudeText) を選びました。「この場所に移動」を押してください。"
        } catch {
            status = userFacingMessage(for: error)
        }
    }

    func previewCoordinateInput() {
        guard let coordinate = try? Coordinate.parsePair(coordinateInputText) else {
            return
        }
        if abs(selectedMapCoordinate.latitude - coordinate.latitude) > 0.000_001 ||
            abs(selectedMapCoordinate.longitude - coordinate.longitude) > 0.000_001 {
            selectedMapCoordinate = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
            selectedLocationName = nil
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
                activeDeviceID = nil
                activeLocationMayRemain = true
                activeLocationStartedAt = nil
                hasDetectedDeviceReconnect = false
                recordLocationEvent("前回の移動先を検出しました。")
                status = "前回の移動先が残っている可能性があります。iPhoneを接続・ロック解除して「前回の場所へ再移動」または「移動を解除」を選んでください。"
            }
        }
    }

    func startLocationContinuityMonitoring() {
        installPowerEventObserversIfNeeded()
        startMonitoringClockIfNeeded()
        guard locationContinuityTask == nil else {
            return
        }

        isLocationContinuityMonitoring = true
        locationContinuityTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await self?.checkActiveLocationContinuity()
            }
        }
    }

    func startTunnel() {
        runBusy("接続を準備しています...") {
            _ = try await self.ensureTunnel(forceRestart: true)
            self.status = "接続準備ができました。「この場所に移動」を押してください。"
        }
    }

    func moveToSelectedLocation() {
        cancelAutoRecovery()
        runBusy("iPhoneの場所を移動しています...") {
            do {
                let coordinate = try Coordinate.parsePair(self.coordinateInputText)
                let operationDeviceID = try self.targetDeviceIDForCurrentOperation()
                if abs(self.selectedMapCoordinate.latitude - coordinate.latitude) > 0.000_001 ||
                    abs(self.selectedMapCoordinate.longitude - coordinate.longitude) > 0.000_001 {
                    self.selectedLocationName = nil
                }
                self.selectedMapCoordinate = CLLocationCoordinate2D(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )
                let endpoint = try await self.ensureTunnel()
                try self.ensureSelectedDeviceStillMatches(operationDeviceID)
                try await self.session.prepare(endpoint: endpoint)
                try self.ensureSelectedDeviceStillMatches(operationDeviceID)
                try await self.session.setLocation(endpoint: endpoint, coordinate: coordinate)
                try self.ensureSelectedDeviceStillMatches(operationDeviceID)
                self.activeCoordinate = coordinate
                self.activeDeviceID = operationDeviceID
                self.activeLocationName = self.selectedLocationName
                self.activeLocationMayRemain = false
                self.activeLocationStartedAt = Date()
                self.hasDetectedDeviceReconnect = false
                self.observedSetErrorOutputSize = await self.session.setErrorOutputSize()
                await self.refreshContinuityProcessWatchers()
                self.recordLocationEvent("移動を開始しました: \(coordinate.latitudeText), \(coordinate.longitudeText)")
                self.status = "移動しました。Macが起きていてUSB接続が続く間、この場所が使われます。\(self.startSleepPreventionStatus())"
            } catch {
                if TunnelStateInvalidationPolicy.shouldInvalidateTunnel(for: error) {
                    self.rsdEndpoint = nil
                    self.rsdDeviceID = nil
                }
                throw error
            }
        }
    }

    func reapplyActiveLocation() {
        cancelAutoRecovery()
        runBusy("前回の移動先へ再移動しています...") {
            guard let coordinate = self.activeCoordinate else {
                self.status = "再移動する前回の移動先がありません。"
                return
            }

            do {
                let operationDevice = try await self.ensureSelectedDevice()
                let operationDeviceID = operationDevice.identifier
                self.selectedMapCoordinate = CLLocationCoordinate2D(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )
                self.coordinateInputText = "\(coordinate.latitudeText), \(coordinate.longitudeText)"
                let endpoint = try await self.ensureTunnel(forceRestart: true)
                try self.ensureSelectedDeviceStillMatches(operationDeviceID)
                try await self.session.prepare(endpoint: endpoint)
                try self.ensureSelectedDeviceStillMatches(operationDeviceID)
                try await self.session.setLocation(endpoint: endpoint, coordinate: coordinate)
                try self.ensureSelectedDeviceStillMatches(operationDeviceID)
                self.activeCoordinate = coordinate
                self.activeDeviceID = operationDeviceID
                self.activeLocationMayRemain = false
                self.activeLocationStartedAt = Date()
                self.hasDetectedDeviceReconnect = false
                self.observedSetErrorOutputSize = await self.session.setErrorOutputSize()
                await self.refreshContinuityProcessWatchers()
                self.recordLocationEvent("前回の移動先へ再移動しました: \(coordinate.latitudeText), \(coordinate.longitudeText)")
                self.status = "前回の移動先へ再移動しました。Macが起きていてUSB接続が続く間、この場所が使われます。\(self.startSleepPreventionStatus())"
            } catch {
                if TunnelStateInvalidationPolicy.shouldInvalidateTunnel(for: error) {
                    self.rsdEndpoint = nil
                    self.rsdDeviceID = nil
                }
                throw error
            }
        }
    }

    func resetLocation() {
        cancelAutoRecovery()
        runBusy("移動を解除しています...") {
            try await self.session.stopSetProcess()
            self.stopSleepPrevention()

            do {
                let resetDevice = try await self.deviceForReset()
                let endpoint = try await self.ensureTunnel()
                try await self.session.clearLocation(endpoint: endpoint)
                await self.stopCachedTunneldTunnel(device: resetDevice)
                self.rsdEndpoint = nil
                self.rsdDeviceID = nil
                self.activeCoordinate = nil
                self.activeDeviceID = nil
                self.activeLocationName = nil
                self.activeLocationMayRemain = false
                self.activeLocationStartedAt = nil
                self.lastContinuityCheckAt = nil
                self.lastContinuityHealthyAt = nil
                self.hasDetectedDeviceReconnect = false
                self.clearContinuityProcessWatchers()
                self.recordLocationEvent("移動を解除しました。")
                self.status = "移動を解除しました。iPhoneは通常の位置情報に戻ります。"
            } catch {
                self.activeLocationMayRemain = self.activeCoordinate != nil
                let resetDevice = try? await self.deviceForReset()
                if let resetDevice {
                    await self.stopCachedTunneldTunnel(device: resetDevice)
                }
                self.rsdEndpoint = nil
                self.rsdDeviceID = nil
                self.clearContinuityProcessWatchers()
                self.recordLocationEvent("移動解除のiPhone側コマンドが失敗しました。")
                self.status = "Mac側の移動処理は止めましたが、iPhoneへの解除コマンドが届きませんでした: \(self.userFacingMessage(for: error))"
            }
        }
    }

    private func refreshDeviceList() async throws {
        let command = paths.listDevicesCommand
        let output = try await runDetached {
            try ProcessRunner().run(command)
        }
        let previouslyMissingActiveDevice = activeDeviceID.map { activeDeviceID in
            !self.devices.contains { $0.identifier == activeDeviceID }
        } ?? false
        let parsedDevices = try DeviceInfo.parseList(output)
        self.devices = parsedDevices
        connectionFailureMessage = nil
        if selectedDeviceID == nil || !parsedDevices.contains(where: { $0.identifier == selectedDeviceID }) {
            if autoRecoveryTask != nil, let activeDeviceID {
                selectedDeviceID = activeDeviceID
            } else {
                selectedDeviceID = parsedDevices.first?.identifier
            }
        }
        if let rsdDeviceID, !parsedDevices.contains(where: { $0.identifier == rsdDeviceID }) {
            rsdEndpoint = nil
            self.rsdDeviceID = nil
        }
        if let activeDeviceID,
           previouslyMissingActiveDevice,
           parsedDevices.contains(where: { $0.identifier == activeDeviceID }) {
            hasDetectedDeviceReconnect = true
            recordLocationEvent("対象iPhoneを再検出しました。")
            sendLocationNotification(
                title: "LocateApp: iPhoneを再検出しました",
                body: autoReapplyAfterWake || keepsTryingAutoRecovery
                    ? "前回の場所への再移動を自動で試みます。"
                    : "必要に応じて「前回の場所へ再移動」を実行してください。"
            )
            if activeCoordinate != nil, keepsTryingAutoRecovery || autoReapplyAfterWake {
                selectedDeviceID = activeDeviceID
                startAutoRecovery(issue: .deviceDisconnected, allowUncertain: true)
            }
        }
        status = parsedDevices.isEmpty ? "iPhoneが見つかりません。ケーブル接続、ロック解除、信頼設定を確認してください。" : "\(parsedDevices.count)台のiPhoneを検出しました。移動先を選んでください。"
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

    private func targetDeviceIDForCurrentOperation() throws -> String {
        guard let identifier = selectedDevice?.identifier else {
            throw LocateError.invalidDeviceList("iPhoneが見つかりません。ケーブル接続、ロック解除、信頼設定を確認してから再試行してください。")
        }
        return identifier
    }

    private func deviceForReset() async throws -> DeviceInfo {
        if let activeDeviceID,
           let device = devices.first(where: { $0.identifier == activeDeviceID }) {
            selectedDeviceID = activeDeviceID
            return device
        }
        if let activeDeviceID {
            try await refreshDeviceList()
            if let device = devices.first(where: { $0.identifier == activeDeviceID }) {
                selectedDeviceID = activeDeviceID
                return device
            }
        }
        return try await ensureSelectedDevice()
    }

    private func ensureSelectedDeviceStillMatches(_ identifier: String) throws {
        guard selectedDevice?.identifier == identifier else {
            throw LocateError.invalidDeviceList("対象iPhoneが変更されたため、移動を確定できませんでした。必要なiPhoneを選び直して「前回の場所へ再移動」を選んでください。")
        }
    }

    private func ensureTunnel(
        forceRestart: Bool = false,
        shouldContinue: (@MainActor () -> Bool)? = nil
    ) async throws -> RSDEndpoint {
        func checkContinuation() throws {
            if let shouldContinue, !shouldContinue() {
                throw CancellationError()
            }
        }

        try checkContinuation()
        let selectedDevice = try await ensureSelectedDevice()
        try checkContinuation()

        if !forceRestart,
           let rsdEndpoint,
           rsdDeviceID == selectedDevice.identifier {
            let tunnelUsable = await cachedTunnelIsUsable(endpoint: rsdEndpoint)
            try checkContinuation()
            if tunnelUsable {
                return rsdEndpoint
            }
        }
        try checkContinuation()

        if !forceRestart,
           rsdDeviceID == selectedDevice.identifier {
            try checkContinuation()
            if let endpoint = try? await session.readTunnelEndpoint(),
               await cachedTunnelIsUsable(endpoint: endpoint) {
                try checkContinuation()
                rsdEndpoint = endpoint
                return endpoint
            }
        }
        try checkContinuation()

        if forceRestart {
            try checkContinuation()
            rsdEndpoint = nil
            rsdDeviceID = nil
        }

        try checkContinuation()
        let tunnelPreparationGeneration = beginTunnelPreparation()
        do {
            try checkContinuation()
            updatePrivilegedTunneldStatus()
            guard privilegedTunneldIsEnabled else {
                throw LocateError.processControlFailed(privilegedTunneldUnavailableMessage())
            }

            status = "特権tunneldでiPhone接続を準備しています..."
            recordLocationEvent("特権tunneldでトンネルを準備しています。")
            if !forceRestart,
               let endpoint = try? await session.currentTunneldEndpoint(device: selectedDevice),
               await session.isTunnelHealthy(endpoint: endpoint) {
                try checkContinuation()
                rsdEndpoint = endpoint
                rsdDeviceID = selectedDevice.identifier
                endTunnelPreparation(tunnelPreparationGeneration)
                if self.tunnelPreparationGeneration == tunnelPreparationGeneration {
                    connectionFailureMessage = nil
                }
                return endpoint
            }

            try checkContinuation()
            status = "iPhone接続の準備完了を待っています..."
            let endpoint = try await session.startTunnelUsingTunneld(device: selectedDevice)
            try checkContinuation()
            rsdEndpoint = endpoint
            rsdDeviceID = selectedDevice.identifier
            endTunnelPreparation(tunnelPreparationGeneration)
            if self.tunnelPreparationGeneration == tunnelPreparationGeneration {
                connectionFailureMessage = nil
            }
            return endpoint
        } catch {
            if let shouldContinue, !shouldContinue() {
                endTunnelPreparation(tunnelPreparationGeneration)
                throw CancellationError()
            }
            failTunnelPreparation(tunnelPreparationGeneration, error: error)
            throw error
        }
    }

    private func cachedTunnelIsUsable(endpoint: RSDEndpoint) async -> Bool {
        if await session.isTunnelRunning() {
            return true
        }
        return await session.isTunnelHealthy(endpoint: endpoint)
    }

    private func stopCachedTunneldTunnel(device: DeviceInfo) async {
        do {
            try await session.stopTunneldTunnel(device: device)
            recordLocationEvent("特権tunneldのトンネルを停止しました。")
        } catch {
            recordLocationEvent("特権tunneldのトンネル停止に失敗しました: \(userFacingMessage(for: error))")
        }
    }

    private func beginTunnelPreparation() -> Int {
        tunnelPreparationGeneration += 1
        isPreparingConnection = true
        connectionFailureMessage = nil
        return tunnelPreparationGeneration
    }

    private func endTunnelPreparation(_ generation: Int) {
        if tunnelPreparationGeneration == generation {
            isPreparingConnection = false
        }
    }

    private func failTunnelPreparation(_ generation: Int, error: Error) {
        if tunnelPreparationGeneration == generation {
            isPreparingConnection = false
            connectionFailureMessage = userFacingMessage(for: error)
        }
    }

    private var privilegedTunneldService: SMAppService {
        SMAppService.daemon(plistName: Self.privilegedTunneldPlistName)
    }

    private func updatePrivilegedTunneldStatus(error: Error? = nil) {
        if let error {
            privilegedTunneldStatusKind = .failed(userFacingMessage(for: error))
            privilegedTunneldStatusText = "特権tunneld: 登録失敗"
            privilegedTunneldHelpText = userFacingMessage(for: error)
            canRegisterPrivilegedTunneld = true
            canOpenPrivilegedTunneldSettings = false
            return
        }

        switch privilegedTunneldService.status {
        case .notRegistered:
            privilegedTunneldStatusKind = .notRegistered
            privilegedTunneldStatusText = "特権tunneld: 未登録"
            privilegedTunneldHelpText = "無人の自動再接続には特権tunneldの登録が必要です。登録後、macOSの設定で承認してください。"
            canRegisterPrivilegedTunneld = true
            canOpenPrivilegedTunneldSettings = false
        case .enabled:
            privilegedTunneldStatusKind = .enabled
            privilegedTunneldStatusText = "特権tunneld: 有効"
            privilegedTunneldHelpText = "トンネル再構築とスリープ復帰後の再移動を管理者プロンプトなしで実行できます。"
            canRegisterPrivilegedTunneld = false
            canOpenPrivilegedTunneldSettings = false
        case .requiresApproval:
            privilegedTunneldStatusKind = .requiresApproval
            privilegedTunneldStatusText = "特権tunneld: 承認待ち"
            privilegedTunneldHelpText = "macOSのログイン項目設定でLocateAppの特権tunneldを許可してください。"
            canRegisterPrivilegedTunneld = false
            canOpenPrivilegedTunneldSettings = true
        case .notFound:
            privilegedTunneldStatusKind = .notFound
            privilegedTunneldStatusText = "特権tunneld: バンドル未同梱"
            privilegedTunneldHelpText = "BUNDLE_HELPER=1 ENABLE_TUNNELD=1でビルドした署名済みアプリにLaunchDaemon plistを同梱してください。"
            canRegisterPrivilegedTunneld = false
            canOpenPrivilegedTunneldSettings = false
        @unknown default:
            privilegedTunneldStatusKind = .failed("未対応のSMAppService状態です。")
            privilegedTunneldStatusText = "特権tunneld: 状態不明"
            privilegedTunneldHelpText = "macOSから未対応のSMAppService状態が返りました。"
            canRegisterPrivilegedTunneld = false
            canOpenPrivilegedTunneldSettings = false
        }
    }

    private func privilegedTunneldUnavailableMessage() -> String {
        updatePrivilegedTunneldStatus()
        switch privilegedTunneldStatusKind {
        case .enabled:
            return ""
        case .notRegistered:
            return "特権tunneldが未登録です。自動再接続の設定で登録し、macOSの設定で承認してください。"
        case .requiresApproval:
            return "特権tunneldは承認待ちです。macOSのログイン項目設定でLocateAppを許可してください。"
        case .notFound:
            return "特権tunneldがアプリに同梱されていません。BUNDLE_HELPER=1 ENABLE_TUNNELD=1でビルドした署名済みアプリを使ってください。"
        case .failed(let message):
            return "特権tunneldを利用できません: \(message)"
        case .unknown:
            return "特権tunneldの状態を確認できません。登録状態を更新してから再試行してください。"
        }
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

    private func startSleepPreventionStatus() -> String {
        appNapPreventer.acquire()
        do {
            try sleepPreventer.acquire()
            isPreventingSleep = sleepPreventer.isActive
            return "Macの自動スリープを止めています。"
        } catch {
            isPreventingSleep = false
            return "ただしMacのスリープ防止を開始できませんでした: \(userFacingMessage(for: error))"
        }
    }

    private func stopSleepPrevention() {
        sleepPreventer.release()
        appNapPreventer.release()
        isPreventingSleep = false
    }

    private func installPowerEventObserversIfNeeded() {
        guard powerEventObserverBag.isEmpty else {
            return
        }

        let notificationCenter = NSWorkspace.shared.notificationCenter
        powerEventObserverBag.replace(with: [
            notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else {
                        return
                    }
                    if self.autoReapplyAfterWake, self.activeCoordinate != nil {
                        self.recordLocationEvent("Macがスリープに入りました。復帰後に自動再移動を試みます。")
                        self.status = "Macがスリープに入ります。復帰後に自動で前回の場所へ再移動を試みます。"
                    } else {
                        self.markActiveLocationUncertain(
                            reason: "Macがスリープまたは蓋閉じに入ったため、位置情報が解除された可能性があります。iPhone接続後に「前回の場所へ再移動」または「移動を解除」を選んでください。"
                        )
                    }
                }
            },
            notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else {
                        return
                    }
                    if self.autoReapplyAfterWake, self.activeCoordinate != nil {
                        self.recordLocationEvent("Macのスリープ復帰を検出しました。")
                        self.startAutoRecovery(issue: .systemWake, allowUncertain: true)
                    } else {
                        self.markActiveLocationUncertain(
                            reason: "Macのスリープ復帰を検出しました。iPhone側の位置情報は解除済みの可能性があります。iPhone接続後に「前回の場所へ再移動」または「移動を解除」を選んでください。"
                        )
                    }
                }
            }
        ])
    }

    private func checkActiveLocationContinuity() async {
        guard activeCoordinate != nil,
              !activeLocationMayRemain,
              !isBusy,
              autoRecoveryTask == nil else {
            return
        }

        continuityCheckCount += 1
        lastContinuityCheckAt = Date()
        let localTunnelProcessRunning = await session.isTunnelRunning()
        let setProcessRunning = await session.isSetProcessRunning()
        let setErrorOutputSize = await session.setErrorOutputSize()
        let setErrorOutputAdvanced = setErrorOutputSize > observedSetErrorOutputSize
        observedSetErrorOutputSize = max(observedSetErrorOutputSize, setErrorOutputSize)
        var tunnelHealthCheckSucceeded = true
        var tunnelRunning = localTunnelProcessRunning
        if let rsdEndpoint,
           (continuityCheckCount % 3 == 0 || !localTunnelProcessRunning) {
            tunnelHealthCheckSucceeded = await session.isTunnelHealthy(endpoint: rsdEndpoint)
            if tunnelHealthCheckSucceeded {
                tunnelRunning = true
            }
        }
        let assessment = LocationContinuityAssessment.assess(
            tunnelRunning: tunnelRunning,
            setProcessRunning: setProcessRunning,
            tunnelHealthCheckSucceeded: tunnelHealthCheckSucceeded,
            setErrorOutputAdvanced: setErrorOutputAdvanced
        )
        switch assessment {
        case .active:
            lastContinuityHealthyAt = Date()
        case .uncertain(let issue):
            recordLocationEvent("継続性低下を検出しました: \(eventText(for: issue))")
            sendLocationNotification(
                title: "LocateApp: 位置情報の継続性が低下しました",
                body: eventText(for: issue)
            )
            startAutoRecovery(issue: issue)
        }
    }

    private func startAutoRecovery(issue: LocationContinuityIssue, allowUncertain: Bool = false) {
        guard autoRecoveryTask == nil,
              let coordinate = activeCoordinate,
              let activeDeviceID,
              (selectedDeviceID == nil || selectedDeviceID == activeDeviceID),
              (allowUncertain || !activeLocationMayRemain),
              !isBusy else {
            return
        }

        if allowUncertain {
            activeLocationMayRemain = false
        }
        autoRecoveryGeneration += 1
        let recoveryGeneration = autoRecoveryGeneration
        let deviceID = activeDeviceID
        autoRecoveryTask = Task { [weak self] in
            await self?.runAutoRecovery(
                issue: issue,
                coordinate: coordinate,
                deviceID: deviceID,
                generation: recoveryGeneration
            )
        }
    }

    private func runAutoRecovery(
        issue: LocationContinuityIssue,
        coordinate: Coordinate,
        deviceID: String,
        generation: Int
    ) async {
        defer {
            if autoRecoveryGeneration == generation {
                autoRecoveryTask = nil
            }
        }

        var attemptNumber = 1
        while true {
            let autoRecoveryPolicy = currentAutoRecoveryPolicy
            guard canContinueAutoRecovery(coordinate: coordinate, deviceID: deviceID, generation: generation) else {
                return
            }

            guard let delay = autoRecoveryPolicy.delayBeforeAttempt(attemptNumber) else {
                markActiveLocationUncertain(reason: uncertainReason(for: issue))
                return
            }

            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            guard canContinueAutoRecovery(coordinate: coordinate, deviceID: deviceID, generation: generation) else {
                return
            }

            try? await refreshDeviceList()
            guard devices.contains(where: { $0.identifier == deviceID }),
                  selectedDeviceID == deviceID else {
                status = "対象iPhoneの再接続を待っています。接続が戻り次第、前回の場所へ再移動します。"
                attemptNumber += 1
                continue
            }

            let attempt = LocationAutoRecoveryAttempt(number: attemptNumber, total: autoRecoveryPolicy.maxAttempts)
            status = autoRecoveryPolicy.progressText(for: attempt)
            let forceRestart = LocationAutoRecoveryTunnelPolicy.shouldForceRestart(for: issue)
            if forceRestart {
                status = "\(autoRecoveryPolicy.progressText(for: attempt)) 特権tunneldで再接続しています。"
            }

            do {
                let endpoint = try await ensureTunnel(forceRestart: forceRestart) {
                    self.canContinueAutoRecovery(coordinate: coordinate, deviceID: deviceID, generation: generation)
                }
                guard canContinueAutoRecovery(coordinate: coordinate, deviceID: deviceID, generation: generation) else {
                    return
                }
                try await session.prepare(endpoint: endpoint)
                guard canContinueAutoRecovery(coordinate: coordinate, deviceID: deviceID, generation: generation) else {
                    return
                }
                try await session.setLocation(endpoint: endpoint, coordinate: coordinate)
                guard canContinueAutoRecovery(coordinate: coordinate, deviceID: deviceID, generation: generation) else {
                    return
                }
                activeCoordinate = coordinate
                activeDeviceID = deviceID
                activeLocationMayRemain = false
                activeLocationStartedAt = Date()
                hasDetectedDeviceReconnect = false
                observedSetErrorOutputSize = await session.setErrorOutputSize()
                await refreshContinuityProcessWatchers()
                guard canContinueAutoRecovery(coordinate: coordinate, deviceID: deviceID, generation: generation) else {
                    return
                }
                lastContinuityHealthyAt = Date()
                recordLocationEvent("自動再接続しました。")
                sendLocationNotification(
                    title: "LocateApp: 自動再接続しました",
                    body: "前回の場所への移動を復元しました。"
                )
                status = "自動再接続しました。Macが起きていてUSB接続が続く間、この場所が使われます。\(startSleepPreventionStatus())"
                return
            } catch {
                guard canContinueAutoRecovery(coordinate: coordinate, deviceID: deviceID, generation: generation) else {
                    return
                }
                if TunnelStateInvalidationPolicy.shouldInvalidateTunnel(for: error) {
                    rsdEndpoint = nil
                    rsdDeviceID = nil
                }
                let message = userFacingMessage(for: error)
                if LocationAutoRecoveryErrorClassifier.isUserCancellation(message) {
                    guard canContinueAutoRecovery(coordinate: coordinate, deviceID: deviceID, generation: generation) else {
                        return
                    }
                    markActiveLocationUncertain(reason: message)
                    return
                }
                if message.localizedCaseInsensitiveContains("特権tunneld") {
                    guard canContinueAutoRecovery(coordinate: coordinate, deviceID: deviceID, generation: generation) else {
                        return
                    }
                    markActiveLocationUncertain(reason: message)
                    return
                }
                if let maxAttempts = autoRecoveryPolicy.maxAttempts,
                   attempt.number == maxAttempts {
                    guard canContinueAutoRecovery(coordinate: coordinate, deviceID: deviceID, generation: generation) else {
                        return
                    }
                    markActiveLocationUncertain(reason: uncertainReason(for: issue))
                    return
                }
                guard canContinueAutoRecovery(coordinate: coordinate, deviceID: deviceID, generation: generation) else {
                    return
                }
                status = "\(autoRecoveryPolicy.progressText(for: attempt)) 失敗しました: \(message)"
            }
            attemptNumber += 1
        }
    }

    private func canContinueAutoRecovery(coordinate: Coordinate, deviceID: String, generation: Int) -> Bool {
        !Task.isCancelled &&
            autoRecoveryGeneration == generation &&
            activeCoordinate == coordinate &&
            activeDeviceID == deviceID &&
            (selectedDeviceID == nil || selectedDeviceID == deviceID) &&
            !activeLocationMayRemain
    }

    private func cancelAutoRecovery() {
        autoRecoveryGeneration += 1
        autoRecoveryTask?.cancel()
        autoRecoveryTask = nil
    }

    private func uncertainReason(for issue: LocationContinuityIssue) -> String {
        switch issue {
        case .tunnelClosed:
            return "iPhoneとの通信トンネルが切れました。位置情報がすでに解除されている可能性があります。iPhone接続後に「前回の場所へ再移動」または「移動を解除」を選んでください。"
        case .setProcessStopped:
            return "Mac側の位置設定プロセスが停止しました。位置情報がすでに解除されている可能性があります。iPhone接続後に「前回の場所へ再移動」または「移動を解除」を選んでください。"
        case .healthCheckFailed:
            return "iPhoneとの実通信ヘルスチェックに失敗しました。トンネルが生きていても位置情報が解除されている可能性があります。"
        case .setProcessErrorOutput:
            return "位置設定プロセスのエラーログ更新を検出しました。位置情報が解除されている可能性があります。"
        case .deviceDisconnected:
            return "対象iPhoneの再接続を検出しました。前回の場所への再移動を試みます。"
        case .systemWake:
            return "Macのスリープ復帰を検出しました。前回の場所への再移動を試みます。"
        }
    }

    private func eventText(for issue: LocationContinuityIssue) -> String {
        switch issue {
        case .tunnelClosed:
            return "トンネル停止"
        case .setProcessStopped:
            return "位置設定プロセス停止"
        case .healthCheckFailed:
            return "ヘルスチェック失敗"
        case .setProcessErrorOutput:
            return "位置設定エラー出力"
        case .deviceDisconnected:
            return "iPhone再接続"
        case .systemWake:
            return "スリープ復帰"
        }
    }

    private func markActiveLocationUncertain(reason: String) {
        cancelAutoRecovery()
        guard activeCoordinate != nil else {
            return
        }
        activeLocationMayRemain = true
        rsdEndpoint = nil
        rsdDeviceID = nil
        stopSleepPrevention()
        clearContinuityProcessWatchers()
        recordLocationEvent("移動状態を不確実として記録しました。")
        sendLocationNotification(title: "LocateApp: 位置情報が不確実です", body: reason)
        status = reason
    }

    private func startMonitoringClockIfNeeded() {
        guard monitoringClockTask == nil else {
            return
        }
        monitoringClockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run {
                    self?.monitoringNow = Date()
                }
            }
        }
    }

    private func refreshContinuityProcessWatchers() async {
        clearContinuityProcessWatchers()
        processWatcherGeneration += 1
        let watcherGeneration = processWatcherGeneration
        let tunnelPID = await session.storedTunnelPID()
        let setPID = await session.storedSetPID()
        let watchedProcesses: [(pid: Int32, issue: LocationContinuityIssue)] = [
            tunnelPID.map { ($0, .tunnelClosed) },
            setPID.map { ($0, .setProcessStopped) }
        ].compactMap { $0 }
        for watchedProcess in watchedProcesses {
            let source = DispatchSource.makeProcessSource(
                identifier: pid_t(watchedProcess.pid),
                eventMask: .exit,
                queue: DispatchQueue.global(qos: .utility)
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    self?.handleContinuityProcessExit(
                        pid: watchedProcess.pid,
                        issue: watchedProcess.issue,
                        generation: watcherGeneration
                    )
                }
            }
            source.setCancelHandler {}
            processExitSources.append(source)
            source.resume()
        }
    }

    private func clearContinuityProcessWatchers() {
        processWatcherGeneration += 1
        processExitSources.forEach { $0.cancel() }
        processExitSources = []
    }

    private func handleContinuityProcessExit(
        pid: Int32,
        issue: LocationContinuityIssue,
        generation: Int
    ) {
        guard activeCoordinate != nil,
              !activeLocationMayRemain,
              autoRecoveryTask == nil,
              !isBusy,
              generation == processWatcherGeneration else {
            return
        }

        recordLocationEvent("プロセス終了を検出しました: \(eventText(for: issue))")
        startAutoRecovery(issue: issue)
    }

    private func recordLocationEvent(_ message: String) {
        locationEventLog.insert(LocationEventLogEntry(date: Date(), message: message), at: 0)
        if locationEventLog.count > 20 {
            locationEventLog.removeLast(locationEventLog.count - 20)
        }
    }

    private func sendLocationNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let deliver: @Sendable () -> Void = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "LocateApp-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request)
        }

        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                deliver()
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted {
                        deliver()
                    }
                }
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }

    private static func durationText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainingSeconds = seconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
    }

    private static func relativeSecondsText(_ interval: TimeInterval) -> String {
        "\(max(0, Int(interval.rounded(.down))))秒前"
    }

    private func userFacingMessage(for error: Error) -> String {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("User canceled") ||
            message.localizedCaseInsensitiveContains("(-128)") {
            return "操作がキャンセルされました。必要に応じて特権tunneldを登録し、macOSの設定で承認してから再試行してください。"
        }
        if message.localizedCaseInsensitiveContains("No route to host") ||
            message.localizedCaseInsensitiveContains("Connection refused") {
            return "iPhoneに接続できません。ケーブル接続とロック解除を確認してください。iPhoneを再起動しても移動状態は解除されます。"
        }
        if message.localizedCaseInsensitiveContains("pymobiledevice3 was not found") {
            return "補助ツールが見つかりません。配布版を使うか、READMEのセットアップを実行してから開き直してください。"
        }
        return message
    }
}
