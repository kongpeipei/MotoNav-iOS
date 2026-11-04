import SwiftUI
import UniformTypeIdentifiers

/// 极简电子眼播报器主界面
struct ContentView: View {
    @EnvironmentObject private var engine: AlertEngine

    private let distanceOptions: [Double] = [300, 500, 800, 1000]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    statusBar
                    nearestCard
                    backgroundHint
                    announcementsSection
                    settingsSection
                    advancedSection
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("电子眼卫士")
        }
    }

    // MARK: - 状态栏

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(engine.isMonitoring ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Text(engine.statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button {
                engine.isMonitoring
                    ? engine.stop()
                    : engine.start()
            } label: {
                Text(engine.isMonitoring ? "暂停" : "开始")
                    .font(.footnote.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(engine.isMonitoring ? Color.orange : Color.blue,
                                in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 最近点位卡片

    private var nearestCard: some View {
        VStack(spacing: 8) {
            if let p = engine.nearest, engine.nearestDistance < .greatestFiniteMagnitude {
                Text(distanceText(engine.nearestDistance))
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .foregroundStyle(engine.nearestDistance <= effectiveWarn ? .red : .primary)

                HStack(spacing: 6) {
                    Image(systemName: p.type.icon)
                    Text(p.type.label)
                        .font(.headline)
                    Text("· \(p.name)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // 优化 A：显示当前速度和自适应预警距离
                HStack(spacing: 16) {
                    Label(String(format: "当前 %.0f km/h", engine.speedKmh), systemImage: "speedometer")
                    Label(String(format: "预警 %.0f m", effectiveWarn), systemImage: "exclamationmark.triangle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(engine.nearestDistance <= effectiveWarn
                     ? "⚠️ 即将播报：\(p.type.voiceText)"
                     : "接近 \(Int(effectiveWarn)) 米内自动语音提醒")
                    .font(.footnote)
                    .foregroundStyle(engine.nearestDistance <= effectiveWarn ? .red : .secondary)
            } else {
                Image(systemName: "location.magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("定位中，附近暂无违法拍照点")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("载入 \(engine.pois.count) 个点位 · 接近自动播报")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    /// 计算当前自适应预警距离（与 AlertEngine.process 逻辑一致）
    private var effectiveWarn: Double {
        let speed = engine.speedKmh / 3.6  // km/h → m/s
        let factor: Double
        if speed <= 5 { factor = 1.0 }
        else if speed <= 10 { factor = 1.0 }
        else if speed <= 15 { factor = 1.2 }
        else if speed <= 22 { factor = 1.5 }
        else { factor = 2.0 }
        return engine.warnDistance * factor
    }

    // MARK: - 后台运行提示

    private var backgroundHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "moon.zzz.fill")
                .foregroundStyle(.yellow)
            Text("后台运行：打开一次后，切后台 / 锁屏仍会持续定位并语音提醒。需在 系统设置→隐私与安全性→定位服务→电子眼卫士 中选择「始终」")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 播报记录（#2 左滑删除）

    private var announcementsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("最近播报")
                    .font(.headline)
                Spacer()
                if !engine.announcements.isEmpty {
                    Button(role: .destructive) {
                        engine.announcements.removeAll()
                    } label: {
                        Text("清空")
                            .font(.caption)
                    }
                }
            }
            if engine.announcements.isEmpty {
                Text("暂无播报记录，接近点位后自动出现")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                ForEach(engine.announcements) { a in
                    HStack(spacing: 8) {
                        Image(systemName: a.type.icon)
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.text)
                                .font(.subheadline)
                                .lineLimit(2)
                            Text("\(a.time.formatted(date: .omitted, time: .shortened)) · 触发时约 \(a.distance) 米")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    // #2 左滑删除单条
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            engine.announcements.removeAll { $0.id == a.id }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    if a.id != engine.announcements.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 基础设置（距离 + 类型开关）

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("基础设置")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("基础播报距离：\(Int(engine.warnDistance)) 米")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("播报距离", selection: $engine.warnDistance) {
                    ForEach(distanceOptions, id: \.self) { d in
                        Text("\(Int(d))m").tag(d)
                    }
                }
                .pickerStyle(.segmented)
            }

            // 类型开关（#3 已去掉 CUSTOM 自定义开关行，改为在点位编辑器里管理）
            VStack(alignment: .leading, spacing: 8) {
                Text("播报类型（可单独关闭）")
                    .font(.subheadline)
                ForEach(PoiType.allCases.filter { $0 != .CUSTOM }, id: \.self) { t in
                    Toggle(isOn: binding(for: t)) {
                        HStack(spacing: 6) {
                            Image(systemName: t.icon)
                            Text(t.label)
                        }
                        .font(.subheadline)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 高级设置（点位管理 / TTS / 测试）

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("高级设置")
                .font(.headline)

            // #3 点位管理入口
            NavigationLink {
                PoiEditorView()
                    .environmentObject(engine)
            } label: {
                HStack {
                    Image(systemName: "map.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("点位管理")
                            .font(.subheadline.weight(.medium))
                        Text("查看内置、添加自定义、删除点位，支持交叉口地址解析")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(engine.userPois.count) 自定义")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
            }

            Divider()

            // #1 TTS 引擎选择
            VStack(alignment: .leading, spacing: 6) {
                Text("语音引擎")
                    .font(.subheadline)
                Picker("TTS", selection: $engine.ttsProvider) {
                    ForEach(TtsProvider.allCases) { p in
                        Text(p.label).tag(p)
                    }
                }
                .pickerStyle(.menu)

                if engine.ttsProvider == .iflytekPro {
                    Text("填写讯飞开放平台控制台的 AppID / APIKey / APISecret")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("AppID", text: $engine.xfAppID)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    TextField("APIKey", text: $engine.xfAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    SecureField("APISecret", text: $engine.xfAPISecret)
                        .textFieldStyle(.roundedBorder)
                    TextField("发音人 vcn（默认 xiaoyan，四川话填控制台的叶子/小蓉对应值）", text: $engine.xfVcn)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    Picker("预设发音人", selection: $engine.xfVcn) {
                        ForEach(VoicePresets.all) { v in
                            Text(v.name).tag(v.vcn)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("「叶子(四川话)」的 vcn 以讯飞控制台为准，若默认值不符请直接改上方 vcn")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("未配置或密钥错误时自动回退系统语音")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("系统语音离线可用、零延迟")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: engine.ttsProvider) { _, _ in engine.saveSettings() }
            .onChange(of: engine.xfAppID) { _, _ in engine.saveSettings() }
            .onChange(of: engine.xfAPIKey) { _, _ in engine.saveSettings() }
            .onChange(of: engine.xfAPISecret) { _, _ in engine.saveSettings() }
            .onChange(of: engine.xfVcn) { _, _ in engine.saveSettings() }

            Divider()

            Button {
                engine.testSpeak()
            } label: {
                Label("测试语音播报 + 震动", systemImage: "speaker.wave.2")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: engine.warnDistance) { _, _ in engine.saveSettings() }
        .onChange(of: engine.enabledTypes) { _, _ in engine.saveSettings() }
    }

    // MARK: - Helpers

    private func binding(for t: PoiType) -> Binding<Bool> {
        Binding(
            get: { engine.enabledTypes.contains(t) },
            set: { on in
                if on { engine.enabledTypes.insert(t) } else { engine.enabledTypes.remove(t) }
                engine.saveSettings()
            }
        )
    }

    private func distanceText(_ d: Double) -> String {
        d >= 1000 ? String(format: "%.1f 公里", d / 1000) : "\(Int(d)) 米"
    }
}
