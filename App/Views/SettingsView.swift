import SwiftUI

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
                            appModel.disconnect()
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
}

#Preview {
    SettingsView()
        .environment(AppModel())
}