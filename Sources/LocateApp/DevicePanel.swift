import LocateAppCore
import SwiftUI

struct DevicePanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("LocateApp")
                        .font(.title2.weight(.semibold))

                    GroupBox("Search") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                TextField("Search near selected area", text: $model.searchQuery)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit {
                                        model.searchPlaces()
                                    }

                                Button("Search") {
                                    model.searchPlaces()
                                }
                                .disabled(model.isSearching || model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }

                            if model.isSearching {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            ForEach(model.searchResults) { result in
                                Button {
                                    model.useSearchResult(result)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.title)
                                            .lineLimit(1)
                                        Text(result.subtitle.isEmpty ? result.coordinateText : result.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(4)
                    }

                    GroupBox("iPhone") {
                        VStack(alignment: .leading, spacing: 10) {
                            if model.devices.isEmpty {
                                Text("No device visible")
                                    .foregroundStyle(.secondary)
                            } else {
                                Picker("Device", selection: Binding(
                                    get: { model.selectedDeviceID ?? model.devices.first?.identifier ?? "" },
                                    set: { model.selectDevice($0) }
                                )) {
                                    ForEach(model.devices) { device in
                                        Text("\(device.name) (\(device.productVersion))")
                                            .tag(device.identifier)
                                    }
                                }
                            }

                            Button("Refresh") {
                                model.refreshDevices()
                            }
                            .disabled(model.isBusy)
                        }
                        .padding(4)
                    }

                    GroupBox("Location") {
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Selected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(model.selectedCoordinateText)
                                    .font(.system(.body, design: .monospaced))
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Fixed")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(model.activeCoordinateText)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(model.activeCoordinate == nil ? Color.secondary : (model.activeLocationMayRemain ? Color.orange : Color.primary))
                                    .lineLimit(3)
                            }

                            HStack(spacing: 8) {
                                TextField("Latitude, longitude", text: $model.coordinateInputText)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit {
                                        model.applyCoordinateInput()
                                    }

                                Button("Use") {
                                    model.applyCoordinateInput()
                                }
                                .disabled(model.isBusy)
                            }

                            Button("Move iPhone Here") {
                                model.moveToSelectedLocation()
                            }
                            .keyboardShortcut(.return, modifiers: [.command])
                            .disabled(model.isBusy || model.selectedDevice == nil)

                            Button("Reset Location") {
                                model.resetLocation()
                            }
                            .disabled(model.isBusy)
                        }
                        .padding(4)
                    }

                    GroupBox("Presets") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.presets) { preset in
                                Button {
                                    model.usePreset(preset)
                                } label: {
                                    HStack {
                                        Text(preset.title)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(preset.coordinateText)
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(4)
                    }

                    GroupBox("Tunnel") {
                        VStack(alignment: .leading, spacing: 10) {
                            if let endpoint = model.rsdEndpoint {
                                Text("\(endpoint.host) \(endpoint.port)")
                                    .font(.system(.caption, design: .monospaced))
                            } else {
                                Text("Not started")
                                    .foregroundStyle(.secondary)
                            }
                            Button("Start Tunnel") {
                                model.startTunnel()
                            }
                            .disabled(model.isBusy || model.selectedDevice == nil)

                            Button("Open Logs") {
                                model.openStateDirectory()
                            }
                        }
                        .padding(4)
                    }
                }
                .padding(18)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .textSelection(.enabled)

                Text(model.stateDirectoryPath)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}
