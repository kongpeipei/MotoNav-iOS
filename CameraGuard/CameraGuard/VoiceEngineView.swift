import SwiftUI

/// 语音引擎设置页：系统 / 讯飞 二选一。
/// v1.5：去掉全部内置语音包预设 —— 在「高级」里填写 vcn 后自动生成一个语音包，
/// 名称可直接编辑，已有语音包支持左滑删除。
struct VoiceEngineView: View {
    @EnvironmentObject private var engine: AlertEngine
    /// 输入防抖任务：避免每输入一个字符就写一次 UserDefaults / 重建索引
    @State private var saveTask: Task<Void, Never>?

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
                Section {
                    if engine.voicePacks.isEmpty {
                        Text("还没有语音包：在下方「高级」里填写发音人 vcn，会自动生成一个语音包")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(engine.voicePacks) { pack in
                            voicePackRow(pack)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        engine.deleteVoicePack(vcn: pack.vcn)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                        }
                    }
                } header: {
                    Text("我的语音包（左滑可删除）")
                } footer: {
                    Text("点左侧圆圈切换到该语音包；名称可直接编辑")
                }

                Section {
                    DisclosureGroup("高级：讯飞凭证（v1.13 已内置默认，留空即用内置）") {
                        TextField("AppID", text: $engine.xfAppID)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                        TextField("APIKey", text: $engine.xfAPIKey)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                        SecureField("APISecret", text: $engine.xfAPISecret)
                        // 输入 vcn 即自动建档（不区分大小写前的空白会被自动去掉）
                        TextField("发音人 vcn（输入后自动添加语音包）", text: $engine.xfVcn)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                    }
                    Text("已内置默认讯飞语音包（加密存储），可直接使用；未配置或密钥错误时会自动回退系统语音")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("语音引擎")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: engine.ttsProvider) { _, _ in engine.saveSettings() }
        // 文本类凭证输入防抖保存，停止输入 0.6 秒后再落盘
        .onChange(of: engine.xfAppID) { _, _ in scheduleDebouncedSave() }
        .onChange(of: engine.xfAPIKey) { _, _ in scheduleDebouncedSave() }
        .onChange(of: engine.xfAPISecret) { _, _ in scheduleDebouncedSave() }
        // vcn 输入防抖建档：停止输入后再校验/新增，避免边输入边生成半截 vcn
        .onChange(of: engine.xfVcn) { _, _ in scheduleDebouncedVcnSync() }
    }

    // MARK: - 语音包行

    private func voicePackRow(_ pack: VoicePack) -> some View {
        HStack(spacing: 10) {
            Button {
                engine.selectVoicePack(vcn: pack.vcn)
            } label: {
                Image(systemName: pack.vcn == engine.xfVcn ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(pack.vcn == engine.xfVcn ? Color.blue : Color.secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                TextField("语音包名称", text: nameBinding(for: pack))
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                Text("vcn: \(pack.vcn)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 名称编辑绑定：直接改内存中的语音包，落盘做防抖（不影响 vcn 与选中状态）
    private func nameBinding(for pack: VoicePack) -> Binding<String> {
        Binding(
            get: { engine.voicePacks.first { $0.vcn == pack.vcn }?.name ?? pack.name },
            set: { newName in
                guard let idx = engine.voicePacks.firstIndex(where: { $0.vcn == pack.vcn }) else { return }
                engine.voicePacks[idx].name = newName
                scheduleDebouncedSave()
            }
        )
    }

    // MARK: - 防抖

    private func scheduleDebouncedSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            engine.saveSettings()
        }
    }

    private func scheduleDebouncedVcnSync() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            engine.syncVoicePackWithCurrentVcn()
        }
    }
}
