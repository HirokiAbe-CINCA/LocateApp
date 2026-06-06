import LocateAppCore
import SwiftUI

struct DevicePanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("LocateApp")
                            .font(.title2.weight(.semibold))
                        Spacer()
                        Text("v\(model.currentVersionText)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    updateBanner
                    connectionSection
                    destinationSection
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

                HStack {
                    Button {
                        model.openStateDirectory()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text.magnifyingglass")
                            Text("診断情報")
                        }
                    }
                    .controlSize(.small)
                    .accessibilityLabel("診断情報を開く")
                    .help("接続に失敗したときの詳細情報を開きます。")

                    Spacer()
                }

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

    @ViewBuilder
    private var updateBanner: some View {
        if let availableUpdate = model.availableUpdate {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("アップデートがあります")
                        .font(.headline)
                    Text("v\(availableUpdate.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    model.openAvailableUpdate()
                } label: {
                    Label("アップデート", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel("アップデートをダウンロード")
            }
            .padding(12)
            .background(.blue.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var connectionSection: some View {
        GroupBox("現在の接続") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(connectionTint)
                        .frame(width: 12, height: 12)
                        .padding(.top, 5)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.connectionStateTitle)
                            .font(.headline)
                        Text(model.connectionStateDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                }

                if !model.devices.isEmpty {
                    Picker("対象iPhone", selection: Binding(
                        get: { model.selectedDeviceID ?? model.devices.first?.identifier ?? "" },
                        set: { model.selectDevice($0) }
                    )) {
                        ForEach(model.devices) { device in
                            Text("\(device.name) (\(device.productVersion))")
                                .tag(device.identifier)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        model.refreshDevices()
                    } label: {
                        Label("接続を確認", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isBusy)
                    .accessibilityLabel("iPhone接続を確認")
                }
            }
            .padding(4)
        }
    }

    private var destinationSection: some View {
        GroupBox("移動先") {
            VStack(alignment: .leading, spacing: 12) {
                currentDestinationView

                Divider()

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

                VStack(alignment: .leading, spacing: 4) {
                    Text("選択中の移動先")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.selectedCoordinateText)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                }

                TextField("緯度, 経度", text: $model.coordinateInputText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        model.applyCoordinateInput()
                    }
                    .onChange(of: model.coordinateInputText) { _, _ in
                        model.previewCoordinateInput()
                    }

                Button {
                    model.moveToSelectedLocation()
                } label: {
                    Label("この場所に移動", systemImage: "location.fill")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.isBusy || model.selectedDevice == nil)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityLabel("この場所に移動")

                Button {
                    model.resetLocation()
                } label: {
                    Label("移動を解除", systemImage: "location.slash")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.isBusy)
                .accessibilityLabel("移動を解除")
            }
            .padding(4)
        }
    }

    private var currentDestinationView: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("現在の移動先")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(model.activeLocationTitle)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text(model.activeCoordinateDetail)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(model.activeCoordinate == nil ? Color.secondary : (model.activeLocationMayRemain ? Color.orange : Color.primary))
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connectionTint: Color {
        switch model.connectionStateKind {
        case .ready:
            return .green
        case .preparing:
            return .orange
        case .failed:
            return .red
        case .detected:
            return .blue
        case .unavailable:
            return .secondary
        }
    }
}
