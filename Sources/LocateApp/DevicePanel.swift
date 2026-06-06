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

                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. 場所を選ぶ")
                            .font(.headline)
                        Text("地図をクリックするか、場所名で検索します。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    GroupBox("場所検索") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                TextField("駅名・住所・施設名で検索", text: $model.searchQuery)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit {
                                        model.searchPlaces()
                                    }

                                Button("検索") {
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
                                    HStack(spacing: 8) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(result.title)
                                                .lineLimit(1)
                                            Text(result.subtitle.isEmpty ? result.coordinateText : result.subtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                        Spacer()
                                        Text("選択")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.tint)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(result.title)を選択")
                            }
                        }
                        .padding(4)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("2. iPhoneに固定")
                            .font(.headline)
                        Text("接続中のiPhoneを選んで、選択場所を反映します。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    GroupBox("iPhone") {
                        VStack(alignment: .leading, spacing: 10) {
                            if model.devices.isEmpty {
                                Text("iPhone未検出")
                                    .foregroundStyle(.secondary)
                            } else {
                                Picker("対象", selection: Binding(
                                    get: { model.selectedDeviceID ?? model.devices.first?.identifier ?? "" },
                                    set: { model.selectDevice($0) }
                                )) {
                                    ForEach(model.devices) { device in
                                        Text("\(device.name) (\(device.productVersion))")
                                            .tag(device.identifier)
                                    }
                                }
                            }

                            Button("再検出") {
                                model.refreshDevices()
                            }
                            .disabled(model.isBusy)
                            .accessibilityLabel("iPhoneを再検出")
                        }
                        .padding(4)
                    }

                    GroupBox("位置") {
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("選択中")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(model.selectedCoordinateText)
                                    .font(.system(.body, design: .monospaced))
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("固定中")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(model.activeCoordinateText)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(model.activeCoordinate == nil ? Color.secondary : (model.activeLocationMayRemain ? Color.orange : Color.primary))
                                    .lineLimit(3)
                            }

                            HStack(spacing: 8) {
                                TextField("緯度, 経度", text: $model.coordinateInputText)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit {
                                        model.applyCoordinateInput()
                                    }

                                Button("反映") {
                                    model.applyCoordinateInput()
                                }
                                .disabled(model.isBusy)
                            }

                            Button("この場所に固定") {
                                model.moveToSelectedLocation()
                            }
                            .keyboardShortcut(.return, modifiers: [.command])
                            .disabled(model.isBusy || model.selectedDevice == nil)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("この場所に固定")

                            Button("固定を解除") {
                                model.resetLocation()
                            }
                            .disabled(model.isBusy)
                            .accessibilityLabel("固定を解除")
                        }
                        .padding(4)
                    }

                    GroupBox("よく使う場所") {
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

                    GroupBox("接続") {
                        VStack(alignment: .leading, spacing: 10) {
                            if let endpoint = model.rsdEndpoint {
                                Text("\(endpoint.host) \(endpoint.port)")
                                    .font(.system(.caption, design: .monospaced))
                            } else {
                                Text("未準備")
                                    .foregroundStyle(.secondary)
                            }
                            Button("接続を準備") {
                                model.startTunnel()
                            }
                            .disabled(model.isBusy || model.selectedDevice == nil)
                            .accessibilityLabel("接続を準備")

                            Button("ログを開く") {
                                model.openStateDirectory()
                            }
                            .accessibilityLabel("ログを開く")
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
