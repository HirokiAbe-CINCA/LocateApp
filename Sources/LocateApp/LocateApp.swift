import LocateAppCore
import Sparkle
import SwiftUI

struct CheckForUpdatesView: View {
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
    }

    var body: some View {
        Button("Check for Updates...") {
            updater.checkForUpdates()
        }
    }
}

@main
struct LocateAppMain: App {
    @StateObject private var model = AppModel()
    private let updaterController: SPUStandardUpdaterController?

    init() {
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
           Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil {
            let controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            updaterController = controller
            if AppLaunchUpdateCheckPolicy.shouldCheckOnLaunch(
                automaticallyChecksForUpdates: controller.updater.automaticallyChecksForUpdates
            ) {
                controller.updater.checkForUpdatesInBackground()
            }
        } else {
            updaterController = nil
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear {
                    model.startLocationContinuityMonitoring()
                    model.restorePreviousSession()
                    model.refreshPrivilegedTunneldStatus()
                    model.refreshDevices()
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                if let updater = updaterController?.updater {
                    CheckForUpdatesView(updater: updater)
                }
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            MapPickerView(coordinate: Binding(
                get: { model.selectedMapCoordinate },
                set: { model.selectCoordinate($0) }
            ), activeCoordinate: model.activeCoordinate)
            DevicePanel()
                .frame(width: 380)
                .background(.regularMaterial)
        }
    }
}
