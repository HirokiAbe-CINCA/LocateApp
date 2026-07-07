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
                    .disabled(model.isBusy)
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

                Divider()

                autoRecoverySettings
                eventLogView
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

            if let caution = model.activeLocationCaution {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: model.isPreventingSleep ? "moon.zzz.slash" : "exclamationmark.triangle.fill")
                        .frame(width: 14)
                    Text(caution)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(model.isPreventingSleep ? Color.secondary : Color.orange)
            }

            if model.activeCoordinate != nil {
                continuityStatusView
            }

            if model.hasDetectedDeviceReconnect, model.canReapplyActiveLocation {
                reconnectBanner
            }

            if model.canReapplyActiveLocation {
                Button {
                    model.reapplyActiveLocation()
                } label: {
                    Label("前回の場所へ再移動", systemImage: "arrow.clockwise.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.shouldHighlightReapplyAction ? Color.orange : Color.accentColor)
                .controlSize(.regular)
                .disabled(model.isBusy)
                .accessibilityLabel("前回の場所へ再移動")
                .help("iPhoneを接続・ロック解除して、前回の座標をもう一度設定します。")
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var continuityStatusView: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let runtimeText = model.continuityRuntimeText {
                Text(runtimeText)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
            }
            Text(model.continuityMonitorText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var reconnectBanner: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .frame(width: 14)
            Text(model.autoReapplyAfterWake || model.keepsTryingAutoRecovery ? "iPhoneを再検出しました。再移動を自動実行します。" : "iPhoneを再検出しました。前回の場所へ再移動できます。")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(Color.orange)
    }

    private var autoRecoverySettings: some View {
        DisclosureGroup("自動再接続") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("復旧を諦めない", isOn: $model.keepsTryingAutoRecovery)
                Toggle("スリープ復帰後に自動再移動", isOn: $model.autoReapplyAfterWake)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.privilegedTunneldStatusText)
                        .font(.caption.weight(.semibold))
                    Text(model.privilegedTunneldHelpText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Button {
                            model.refreshPrivilegedTunneldStatus()
                        } label: {
                            Label("状態更新", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.isBusy)

                        if model.canRegisterPrivilegedTunneld {
                            Button {
                                model.registerPrivilegedTunneld()
                            } label: {
                                Label("登録", systemImage: "lock.shield")
                            }
                            .disabled(model.isBusy)
                        }

                        if model.canOpenPrivilegedTunneldSettings {
                            Button {
                                model.openPrivilegedTunneldSettings()
                            } label: {
                                Label("設定を開く", systemImage: "gearshape")
                            }
                            .disabled(model.isBusy)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Stepper(
                    "初回間隔 \(Int(model.autoRecoveryRetryDelaySeconds))秒",
                    value: $model.autoRecoveryRetryDelaySeconds,
                    in: 5...120,
                    step: 5
                )
                Stepper(
                    "最大間隔 \(Int(model.autoRecoveryMaximumDelaySeconds))秒",
                    value: $model.autoRecoveryMaximumDelaySeconds,
                    in: 10...300,
                    step: 10
                )
                Text(model.autoRecoveryPolicySummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
        .font(.caption)
    }

    private var eventLogView: some View {
        DisclosureGroup("イベントログ") {
            VStack(alignment: .leading, spacing: 6) {
                if model.locationEventLog.isEmpty {
                    Text("イベントはまだありません。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.locationEventLog.prefix(10)) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(entry.timeText)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .font(.caption2)
            .padding(.top, 6)
        }
        .font(.caption)
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
