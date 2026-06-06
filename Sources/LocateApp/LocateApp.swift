import SwiftUI

@main
struct LocateAppMain: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear {
                    model.startLocationContinuityMonitoring()
                    model.restorePreviousSession()
                    model.refreshDevices()
                    model.checkForUpdates()
                }
        }
        .windowStyle(.titleBar)
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
