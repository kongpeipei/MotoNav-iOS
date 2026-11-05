import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 极简电子眼播报器主界面
struct ContentView: View {
    @EnvironmentObject private var engine: AlertEngine

    private let distanceOptions: [Double] = [300, 500, 800, 1000]

    /// v1.9：用 NavigationStack 路径管理页面跳转
    @State private var navPath = NavigationPath()

    /// v1.9 当前版本 IPA 的公开下载地址（GitHub Release 附件，随每次发布更新）
    private let ipaShareURL = "https://github.com/kongpeipei/MotoNav-iOS/releases/download/camera-guard-v1.20/CameraGuard-unsigned.ipa"

    var body: some View {
        NavigationStack(path: $navPath) {
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
            .navigationDestination(for: CameraGuardRoute.self) { route in
                switch route {
                case .poiEditor:
                    PoiEditorView()
                        .environmentObject(engine)
                case .voiceEngine:
                    VoiceEngineView()
                        .environmentObject(engine)
                }
            }
            // v1.9：右上角分享按钮（苹果同款分享图标），分享当前版本 IPA 安装包到微信/QQ
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        shareInstallPackage()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("分享安装包")
                }
            }
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
        // v1.9：顶部弹窗覆盖层（v1.12 起不再有悬浮球，避免全屏手势层拦截导航点击）
        .overlay(alignment: .top) { bannerOverlay }
    }

    /// v1.9 页面路由（用于 NavigationStack path）
    private enum CameraGuardRoute: Hashable {
        case poiEditor
        case voiceEngine
    }

    // MARK: - v1.9 分享当前版本 IPA

    private func shareInstallPackage() {
        let text = "电子眼卫士 \(AlertEngine.appVersion) 安装包（未签名，需用全能签重签后安装）："
        let url = URL(string: ipaShareURL)!
        let av = UIActivityViewController(activityItems: [text, url], applicationActivities: nil)
        if let pop = av.popoverPresentationController {
            pop.sourceView = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first(where: { $0.activationState == .foregroundActive })?
                .windows.first
            pop.sourceRect = CGRect(x: UIScreen.main.bounds.width - 60, y: 44, width: 1, height: 1)
        }
        currentTopViewController()?.present(av, animated: true)
    }

    /// 取当前最上层控制器，避免在 sheet/子页面叠层时从根控制器弹出失败
    private func currentTopViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return nil }
        var vc = (scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first)?.rootViewController
        while let presented = vc?.presentedViewController, !presented.isBeingDismissed {
            vc = presented
        }
        return vc
    }

    // MARK: - v1.9 顶部弹窗（接近抓拍点弹窗提示，按设置时长自动收起；v1.12 起无悬浮球）

    private var bannerOverlay: some View {
        Group {
            if let text = engine.bannerText {
                VStack(spacing: 3) {
                    Label("抓拍提醒", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    Text(text)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.95))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .background(Color.red.gradient, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .animation(.spring(duration: 0.35), value: engine.bannerText)
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
            // v1.10 CarPlay：已连接车机时显示小标签
            if engine.carPlayConnected {
                Label("CarPlay", systemImage: "car.fill")
                    .font(.caption2.bold())
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.15), in: Capsule())
            }
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

            // v1.9 提醒设置（v1.12 起移除悬浮球，保留弹窗展示时长与灵动岛）
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("弹窗展示时长")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(String(format: "%.1f 秒", engine.bannerDuration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $engine.bannerDuration, in: 1...10, step: 0.1)
                        .tint(.green)
                    Text("接近抓拍点时的顶部弹窗停留时长，到时自动收起")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .onChange(of: engine.bannerDuration) { _, _ in engine.saveSettings() }

                Toggle(isOn: Binding(
                    get: { engine.liveActivityEnabled },
                    set: { on in
                        engine.liveActivityEnabled = on
                        if on {
                            engine.startLiveActivity()
                        } else {
                            engine.endLiveActivity()
                        }
                        engine.saveSettings()
                    }
                )) {
                    HStack(spacing: 6) {
                        Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                            .foregroundStyle(.green)
                        Text("灵动岛实时活动（后台/锁屏）")
                            .font(.subheadline)
                    }
                }
            }

            Divider()

            // #3 点位管理入口（v1.14：显式 navPath 推入，绕开 iOS17 ScrollView 内 NavigationLink 点击失效）
            Button {
                navPath.append(CameraGuardRoute.poiEditor)
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
            .buttonStyle(.plain)

            Divider()

            // #1 语音引擎（v1.14：显式 navPath 推入；凭证收起防误操作）
            Button {
                navPath.append(CameraGuardRoute.voiceEngine)
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
            .buttonStyle(.plain)

            Divider()

            // v1.6/v1.7/v1.8 震动设置：开关 + 持续时长（0 ~ 10 秒，0 为关闭，滑到整秒有震动提示）+ 强度
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(
                    get: { engine.hapticDuration > 0 },
                    set: { engine.setHapticEnabled($0) }
                )) {
                    HStack(spacing: 6) {
                        Image(systemName: "iphone.radiowaves.left.and.right")
                            .foregroundStyle(.orange)
                        Text("震动提醒")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(engine.hapticDuration == 0 ? "已关闭"
                             : String(format: "%.0f 秒", engine.hapticDuration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(engine.hapticDuration == 0 ? .tertiary : .secondary)
                    }
                }

                // v1.8：时长范围 0 ~ 10 秒、步进 1 秒；滑到整秒时给一次短促震动反馈
                Slider(value: Binding(
                    get: { engine.hapticDuration },
                    set: { v in
                        let whole = v.rounded(.down)
                        if whole != engine.hapticDuration {
                            engine.updateHapticDuration(whole)
                            if whole > 0 { engine.hapticTick() }
                        }
                    }
                ), in: 0...10, step: 1)
                    .tint(.orange)
                Text("持续时间：0 ~ 10 秒（0 秒为关闭，滑到整秒会有一次震动提示）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if engine.hapticDuration > 0 {
                    // v1.20 强度改为低/中/高三档（映射 0.35/0.65/1.0），切换档位即时震动反馈
                    Picker("强度", selection: hapticLevelBinding) {
                        Text("低").tag(0)
                        Text("中").tag(1)
                        Text("高").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: engine.hapticIntensity) { _, _ in engine.saveSettings() }
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
    }

    /// v1.20 震动强度三档映射：低=0.35 / 中=0.65 / 高=1.0，切换时即时震动反馈
    private var hapticLevelBinding: Binding<Int> {
        Binding(
            get: {
                let v = engine.hapticIntensity
                return v < 0.5 ? 0 : (v < 0.8 ? 1 : 2)
            },
            set: { level in
                let values = [0.35, 0.65, 1.0]
                let newValue = values[max(0, min(2, level))]
                guard newValue != engine.hapticIntensity else { return }
                engine.hapticIntensity = newValue
                engine.saveSettings()
                engine.hapticTick()
            }
        )
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
