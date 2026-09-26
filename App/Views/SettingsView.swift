import SwiftUI
import X32RemoteCore

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var model = appModel

        NavigationStack {
            Form {
                Section("调音台连接") {
                    TextField("IP 地址", text: $model.mixerIP)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()

                    HStack {
                        Text("端口")
                        Spacer()
                        TextField("端口", value: $model.mixerPort, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                }

                Section {
                    if appModel.isConnected {
                        Button("断开连接", role: .destructive) {
                            Task { @MainActor in appModel.disconnect() }
                        }
                    } else {
                        Button("连接") {
                            Task {
                                await appModel.connect()
                            }
                        }

                        Button("自动发现") {
                            Task {
                                await appModel.discoverMixers()
                            }
                        }
                        .disabled(appModel.isDiscovering)
                    }
                }

                bridgeSection

                if !appModel.bridgeEvents.isEmpty {
                    bridgeEventSection
                }

                Section("连接方式") {
                    Text("路由器/交换机：调音台网口接入路由器，手机连同一网络（有线或 WiFi 都行），填调音台 IP 或点「自动发现」。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("网线直连：电脑或手机（经转换器）直插调音台，两端配同网段静态 IP（如调音台 192.168.0.100、手机 192.168.0.50），App 里填调音台 IP。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("USB：不支持控制。X32/M32 的 USB 口是音频接口（X-USB/X-LIVE 卡），不跑 OSC；控制协议只能走以太网（UDP 端口 10023）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("实时数据：连接后 App 自动订阅推子/静音变更并轮询电平表，台面上的操作会实时同步到手机；手机上的调整也会即时写回调音台。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !appModel.discoveredMixers.isEmpty {
                    Section("发现的调音台") {
                        ForEach(appModel.discoveredMixers) { mixer in
                            Button {
                                model.mixerIP = mixer.host
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(mixer.name)
                                            .font(.headline)
                                        Text("\(mixer.model) · \(mixer.host)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if mixer.host == appModel.mixerIP {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                            .foregroundColor(.primary)
                        }
                    }
                }

                if appModel.isDiscovering {
                    Section {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("扫描网络中...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.leading, 8)
                        }
                    }
                }

                Section("状态") {
                    HStack {
                        Circle()
                            .fill(appModel.isConnected ? Color.green : Color.gray)
                            .frame(width: 10, height: 10)
                        Text(appModel.connectionMessage)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("设置")
        }
    }

    // MARK: - 桥接模式

    private var bridgeSection: some View {
        Section {
            Toggle(isOn: appModelBridgeEnabled) {
                Label("手机自带桥接引擎", systemImage: "arrow.left.arrow.right")
            }
            if appModel.bridgeEnabled {
                HStack {
                    Circle()
                        .fill(bridgeColor)
                        .frame(width: 10, height: 10)
                    Text(appModel.bridgeState.label)
                        .foregroundStyle(.secondary)
                }
                Text("手机直连真台时，App 内部维护一份本地虚拟台面：卡片渐变、回声抑制、真台手动干预检测全部在手机里完成，不需要电脑参与。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("真台面板上有人动了某路推子、而那一路正被卡片渐变驱动时，只会冻结那一路并弹出提示，卡片的其它动作与通道照常执行。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("桥接模式")
        } footer: {
            if !appModel.bridgeEnabled {
                Text("关闭时 App 只作为纯遥控器使用；开启后可脱离电脑独立跑卡片自动化。")
            }
        }
    }

    /// `bridgeEnabled` 带持久化副作用，用显式 Binding 避免 @Bindable 内部写入路径差异
    private var appModelBridgeEnabled: Binding<Bool> {
        Binding(get: { appModel.bridgeEnabled },
                set: { appModel.bridgeEnabled = $0 })
    }

    private var bridgeColor: Color {
        switch appModel.bridgeState {
        case .off:    return Color.gray
        case .link:   return Color.orange
        case .online: return Color.green
        case .stale:  return Color.red
        }
    }

    private var bridgeEventSection: some View {
        Section {
            ForEach(Array(appModel.bridgeEvents.prefix(10))) { event in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: event.isWarning ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(.caption)
                        .foregroundColor(event.isWarning ? Color.orange : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.text)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(event.time)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Button("清空事件", role: .destructive) {
                appModel.bridgeEvents.removeAll()
            }
        } header: {
            Text("桥接事件（最近 \(min(appModel.bridgeEvents.count, 10)) 条）")
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppModel())
}
