import SwiftUI
import UIKit
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
            // v1.6：启动时若只是「使用期间」定位，主动询问是否升级为「始终」，保证锁屏后台继续播报
            .alert("开启「始终」定位", isPresented: $engine.showAlwaysPrompt) {
                Button("现在允许") { engine.requestAlwaysAuthorization() }
                Button("去系统设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("稍后", role: .cancel) { }
            } message: {
                Text("锁屏或切到后台后仍要语音提醒违法拍照点，需要把定位权限改为「始终允许」。")
            }
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

                Text(hintText(for: p))
                    .font(.footnote)
                    .foregroundStyle(hintColor(for: p))
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

    /// 当前自适应预警距离：与引擎共用 AdaptiveWarn 系数，保证界面显示与实际触发阈值一致
    private var effectiveWarn: Double {
        AdaptiveWarn.effectiveDistance(base: engine.warnDistance,
                                        speedMetersPerSecond: engine.speedKmh / 3.6)
    }

    /// v1.4：播报后不再一直显示「即将播报」，改为「已播报」，避免用户以为还没提醒
    private func hintText(for p: Poi) -> String {
        let within = engine.nearestDistance <= effectiveWarn
        if within && engine.announced.contains(p.id) {
            return "✓ 已播报「\(p.type.voiceText)」，请减速通过"
        }
        if within {
            return "⚠️ 即将播报：\(p.type.voiceText)"
        }
        return "接近 \(Int(effectiveWarn)) 米内自动语音提醒"
    }

    private func hintColor(for p: Poi) -> Color {
        let within = engine.nearestDistance <= effectiveWarn
        if within && engine.announced.contains(p.id) { return .secondary }
        return within ? .red : .secondary
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
                        // v1.4：删除按钮改显式图标（原 swipeActions 在 ScrollView 内不生效，左滑无法删除）
                        Button {
                            engine.announcements.removeAll { $0.id == a.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                                .padding(4)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
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

            // #1 语音引擎（折叠入口，点进去再选系统/讯飞；凭证收起防误操作）
            NavigationLink {
                VoiceEngineView()
                    .environmentObject(engine)
            } label: {
                HStack {
                    Image(systemName: "waveform.circle.fill")
                        .foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("语音引擎")
                            .font(.subheadline.weight(.medium))
                        Text(voiceEngineSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
            }

            Divider()

            // v1.6 震动设置：0 秒为关闭，最长 60 秒；强度 0~100%
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .foregroundStyle(.orange)
                    Text("震动提醒")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(engine.hapticDuration == 0 ? "已关闭"
                         : String(format: "%.1f 秒", engine.hapticDuration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(engine.hapticDuration == 0 ? .tertiary : .secondary)
                }
                Slider(value: $engine.hapticDuration, in: 0...60, step: 0.5)
                    .tint(.orange)
                Text("持续时间：0 秒为关闭，最长 60 秒")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                HStack(spacing: 10) {
                    Text("强度")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .leading)
                    Slider(value: $engine.hapticIntensity, in: 0...1, step: 0.1)
                        .tint(.orange)
                    Text("\(Int(engine.hapticIntensity * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }

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

            if !engine.ttsFeedback.isEmpty {
                Text(engine.ttsFeedback)
                    .font(.caption)
                    .foregroundStyle(engine.ttsFeedback.contains("失败") ? .red : .secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: engine.warnDistance) { _, _ in engine.saveSettings() }
        .onChange(of: engine.hapticDuration) { _, _ in engine.saveSettings() }
        .onChange(of: engine.hapticIntensity) { _, _ in engine.saveSettings() }
    }

    // MARK: - Helpers

    private func binding(for t: PoiType) -> Binding<Bool> {
        Binding(
            get: { engine.enabledTypes.contains(t) },
            set: { on in
                if on { engine.enabledTypes.insert(t) } else { engine.enabledTypes.remove(t) }
                engine.saveSettings(rebuildIndex: true)   // 类型开关影响分桶过滤，需要重建索引
            }
        )
    }

    private func distanceText(_ d: Double) -> String {
        d >= 1000 ? String(format: "%.1f 公里", d / 1000) : "\(Int(d)) 米"
    }

    private var voiceEngineSummary: String {
        engine.ttsProvider == .system ? "系统语音" : "讯飞 · \(engine.voiceDisplayName)"
    }
}
