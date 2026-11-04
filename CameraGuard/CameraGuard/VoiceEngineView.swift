import SwiftUI

/// 语音引擎设置页：系统 / 讯飞 二选一，讯飞下展开语音包，凭证折叠防误操作。
struct VoiceEngineView: View {
    @EnvironmentObject private var engine: AlertEngine

    var body: some View {
        Form {
            Section("语音引擎") {
                Picker("引擎", selection: $engine.ttsProvider) {
                    ForEach(TtsProvider.allCases) { p in
                        Text(p.label).tag(p)
                    }
                }
                .pickerStyle(.inline)

                if engine.ttsProvider == .system {
                    Text("系统语音离线可用、零延迟，无需联网")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if engine.ttsProvider == .iflytekPro {
                Section("讯飞语音包") {
                    Picker("发音人", selection: $engine.xfVcn) {
                        ForEach(VoicePresets.all) { v in
                            Text(v.name).tag(v.vcn)
                        }
                    }
                    .pickerStyle(.inline)

                    Text("当前 vcn：\(engine.xfVcn)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if !engine.ttsFeedback.isEmpty {
                        Text(engine.ttsFeedback)
                            .font(.caption)
                            .foregroundStyle(engine.ttsFeedback.contains("失败") ? .red : .secondary)
                    }
                }

                Section {
                    DisclosureGroup("高级：填写讯飞凭证（防误操作）") {
                        TextField("AppID", text: $engine.xfAppID)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                        TextField("APIKey", text: $engine.xfAPIKey)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                        SecureField("APISecret", text: $engine.xfAPISecret)
                        TextField("发音人 vcn", text: $engine.xfVcn)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                    }
                    Text("未配置或密钥错误时会自动回退系统语音")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("语音引擎")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: engine.ttsProvider) { _, _ in engine.saveSettings() }
        .onChange(of: engine.xfVcn) { _, _ in engine.saveSettings() }
        .onChange(of: engine.xfAppID) { _, _ in engine.saveSettings() }
        .onChange(of: engine.xfAPIKey) { _, _ in engine.saveSettings() }
        .onChange(of: engine.xfAPISecret) { _, _ in engine.saveSettings() }
    }
}