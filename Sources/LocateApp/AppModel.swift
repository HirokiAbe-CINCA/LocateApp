import AppKit
import Combine
import CoreLocation
import Foundation
import LocateAppCore

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
    private var activeDeviceID: String?
    private var rsdDeviceID: String?
    @Published private var isPreparingConnection = false
    @Published private var connectionFailureMessage: String?

    private let paths: LocatePaths
    private let session: LocationSessionController
    private let sleepPreventer = SleepPreventer()
    private let searchService = LocationSearchService()
    private var searchRequestSerial = 0
    private var locationContinuityTask: Task<Void, Never>?
    private let autoRecoveryPolicy = LocationAutoRecoveryPolicy()
    private var autoRecoveryTask: Task<Void, Never>?
    private var autoRecoveryGeneration = 0
    private var tunnelPreparationGeneration = 0
    private let powerEventObserverBag = PowerEventObserverBag()

    deinit {
        locationContinuityTask?.cancel()
        autoRecoveryTask?.cancel()
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
            return "管理者認証が表示されたら承認してください。"
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
                status = "前回の移動先が残っている可能性があります。iPhoneを接続・ロック解除して「前回の場所へ再移動」または「移動を解除」を選んでください。"
            }
        }
    }

    func startLocationContinuityMonitoring() {
        installPowerEventObserversIfNeeded()
        guard locationContinuityTask == nil else {
            return
        }

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
                self.status = "移動しました。Macが起きていてUSB接続が続く間、この場所が使われます。\(self.startSleepPreventionStatus())"
            } catch {
                self.rsdEndpoint = nil
                self.rsdDeviceID = nil
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
                let operationDeviceID = try self.targetDeviceIDForCurrentOperation()
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
                self.status = "前回の移動先へ再移動しました。Macが起きていてUSB接続が続く間、この場所が使われます。\(self.startSleepPreventionStatus())"
            } catch {
                self.rsdEndpoint = nil
                self.rsdDeviceID = nil
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
                let endpoint = try await self.ensureTunnel(forceRestart: true)
                try await self.session.clearLocation(endpoint: endpoint)
                try? await self.session.stopTunnel()
                self.rsdEndpoint = nil
                self.rsdDeviceID = nil
                self.activeCoordinate = nil
                self.activeDeviceID = nil
                self.activeLocationName = nil
                self.activeLocationMayRemain = false
                self.status = "移動を解除しました。iPhoneは通常の位置情報に戻ります。"
            } catch {
                self.activeLocationMayRemain = self.activeCoordinate != nil
                self.status = "Mac側の移動処理は止めましたが、iPhoneへの解除コマンドが届きませんでした: \(self.userFacingMessage(for: error))"
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
        connectionFailureMessage = nil
        if selectedDeviceID == nil || !devices.contains(where: { $0.identifier == selectedDeviceID }) {
            selectedDeviceID = devices.first?.identifier
        }
        if let rsdDeviceID, !devices.contains(where: { $0.identifier == rsdDeviceID }) {
            rsdEndpoint = nil
            self.rsdDeviceID = nil
        }
        status = devices.isEmpty ? "iPhoneが見つかりません。ケーブル接続、ロック解除、信頼設定を確認してください。" : "\(devices.count)台のiPhoneを検出しました。移動先を選んでください。"
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
            let tunnelRunning = await session.isTunnelRunning()
            try checkContinuation()
            if tunnelRunning {
                return rsdEndpoint
            }
        }
        try checkContinuation()

        if !forceRestart,
           rsdDeviceID == selectedDevice.identifier {
            let tunnelRunning = await session.isTunnelRunning()
            try checkContinuation()
            if tunnelRunning, let endpoint = try? await session.readTunnelEndpoint() {
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
            status = "管理者認証が表示されたら承認してください。iPhone接続の準備に使います。"
            try await session.startTunnel(device: selectedDevice)
            try checkContinuation()
            status = "iPhone接続の準備完了を待っています..."

            for _ in 0..<30 {
                try checkContinuation()
                if let endpoint = try? await session.readTunnelEndpoint() {
                    try checkContinuation()
                    rsdEndpoint = endpoint
                    rsdDeviceID = selectedDevice.identifier
                    endTunnelPreparation(tunnelPreparationGeneration)
                    if self.tunnelPreparationGeneration == tunnelPreparationGeneration {
                        connectionFailureMessage = nil
                    }
                    return endpoint
                }
                try await Task.sleep(nanoseconds: 500_000_000)
                try checkContinuation()
            }

            try checkContinuation()
            rsdEndpoint = nil
            rsdDeviceID = nil
            try? await session.stopTunnel()
            try checkContinuation()
            throw LocateError.invalidRSDOutput("15秒以内にiPhone接続を準備できませんでした。iPhoneの接続・ロック解除・管理者認証の承認を確認して、もう一度試してください。急いで解除したい場合はiPhoneを再起動してください。")
        } catch {
            if let shouldContinue, !shouldContinue() {
                endTunnelPreparation(tunnelPreparationGeneration)
                throw CancellationError()
            }
            failTunnelPreparation(tunnelPreparationGeneration, error: error)
            throw error
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
                    self?.markActiveLocationUncertain(
                        reason: "Macがスリープまたは蓋閉じに入ったため、位置情報が解除された可能性があります。iPhone接続後に「前回の場所へ再移動」または「移動を解除」を選んでください。"
                    )
                }
            },
            notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.markActiveLocationUncertain(
                        reason: "Macのスリープ復帰を検出しました。iPhone側の位置情報は解除済みの可能性があります。iPhone接続後に「前回の場所へ再移動」または「移動を解除」を選んでください。"
                    )
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

        let tunnelRunning = await session.isTunnelRunning()
        let setProcessRunning = await session.isSetProcessRunning()
        let assessment = LocationContinuityAssessment.assess(
            tunnelRunning: tunnelRunning,
            setProcessRunning: setProcessRunning
        )
        switch assessment {
        case .active:
            break
        case .uncertain(let issue):
            startAutoRecovery(issue: issue)
        }
    }

    private func startAutoRecovery(issue: LocationContinuityIssue) {
        guard autoRecoveryTask == nil,
              let coordinate = activeCoordinate,
              let activeDeviceID,
              selectedDevice?.identifier == activeDeviceID,
              !activeLocationMayRemain,
              !isBusy else {
            return
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

        for attempt in autoRecoveryPolicy.attempts {
            guard canContinueAutoRecovery(coordinate: coordinate, deviceID: deviceID, generation: generation) else {
                return
            }

            if let delay = autoRecoveryPolicy.delayBeforeAttempt(attempt.number), delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            guard canContinueAutoRecovery(coordinate: coordinate, deviceID: deviceID, generation: generation) else {
                return
            }

            status = autoRecoveryPolicy.progressText(for: attempt)

            do {
                let endpoint = try await ensureTunnel(forceRestart: true) {
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
                guard canContinueAutoRecovery(coordinate: coordinate, deviceID: deviceID, generation: generation) else {
                    return
                }
                status = "自動再接続しました。Macが起きていてUSB接続が続く間、この場所が使われます。\(startSleepPreventionStatus())"
                return
            } catch {
                guard canContinueAutoRecovery(coordinate: coordinate, deviceID: deviceID, generation: generation) else {
                    return
                }
                rsdEndpoint = nil
                rsdDeviceID = nil
                let message = userFacingMessage(for: error)
                if LocationAutoRecoveryErrorClassifier.isUserCancellation(message) {
                    guard canContinueAutoRecovery(coordinate: coordinate, deviceID: deviceID, generation: generation) else {
                        return
                    }
                    markActiveLocationUncertain(reason: message)
                    return
                }
                if attempt.number == autoRecoveryPolicy.maxAttempts {
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
        }
    }

    private func canContinueAutoRecovery(coordinate: Coordinate, deviceID: String, generation: Int) -> Bool {
        !Task.isCancelled &&
            autoRecoveryGeneration == generation &&
            activeCoordinate == coordinate &&
            activeDeviceID == deviceID &&
            selectedDevice?.identifier == deviceID &&
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
        status = reason
    }

    private func userFacingMessage(for error: Error) -> String {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("User canceled") ||
            message.localizedCaseInsensitiveContains("(-128)") {
            return "管理者認証がキャンセルされました。もう一度実行し、表示された認証を承認してください。"
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
