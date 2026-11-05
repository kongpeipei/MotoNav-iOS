import SwiftUI
import UIKit
import CoreLocation

/// v1.18：运行日志查看页。
/// 打开即显示最近事件日志；顶部「运行自检」会在不触发 SwiftUI 渲染的前提下，
/// 复算点位/语音包的重复 id、数量与状态，直接暴露「黄色感叹号 / 页面进不去」的根因数据。
struct LogViewer: View {
    @EnvironmentObject private var engine: AlertEngine
    @State private var logText = ""
    @State private var checkResult: [String] = []
    @State private var lastCheck = "尚未运行自检"

    var body: some View {
        VStack(spacing: 0) {
            // 自检结果区（异常条目红色高亮）
            if !checkResult.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(checkResult.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .foregroundStyle(line.hasPrefix("⚠️") ? .red : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 220)
                .background(Color(.secondarySystemBackground))
            }

            Divider()

            ScrollView {
                Text(logText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .navigationTitle("运行日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("自检") { runSelfCheck() }
                Button("清空") { RingLog.shared.clear(); refresh() }
                Button { copyLog() } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(logText.isEmpty)
                Button { shareLog() } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(logText.isEmpty)
            }
        }
        .onAppear {
            refresh()
            runSelfCheck()
        }
    }

    private func refresh() {
        logText = RingLog.shared.export()
    }

    /// 运行自检：纯数据统计，不做 ForEach 渲染，安全复现崩溃条件
    private func runSelfCheck() {
        let builtin = engine.builtinPois
        let base = engine.basePois
        let custom = engine.userPois
        let packs = engine.voicePacks

        var lines: [String] = []
        lines.append("设备/系统：\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        lines.append("App 版本：\(AlertEngine.appVersion)（\(AlertEngine.appBuild)）")
        lines.append("语音引擎：\(engine.ttsProvider.rawValue)｜当前 vcn：\(engine.xfVcn.isEmpty ? "未设置" : engine.xfVcn)")
        lines.append("云端点位库：\(engine.remotePois.count) 个（本地 \(engine.bundledPois.count) 个），生效内置 \(builtin.count) 个，自定义 \(custom.count) 个")
        lines.append("语音包：\(packs.count) 个")
        lines.append("在线更新状态：\(engine.remoteUpdateStatus.isEmpty ? "未检查" : engine.remoteUpdateStatus)")

        // 点位重复 id 检测（ForEach 崩溃条件复现）
        var builtinIds = Set<String>()
        var dupBuiltin = 0
        for p in builtin {
            if !builtinIds.insert(p.id).inserted { dupBuiltin += 1 }
        }
        lines.append(dupBuiltin == 0 ? "内置点位 id 唯一性：正常" : "⚠️ 内置点位存在 \(dupBuiltin) 个重复 id → 点位管理页会崩成感叹号！")
        var customIds = Set<String>()
        var dupCustom = 0
        for p in custom {
            if !customIds.insert(p.id).inserted { dupCustom += 1 }
        }
        lines.append(dupCustom == 0 ? "自定义点位 id 唯一性：正常" : "⚠️ 自定义点位存在 \(dupCustom) 个重复 id！")

        // 语音包重复 vcn 检测
        var vcns = Set<String>()
        var dupVcns = 0
        for p in packs {
            if !vcns.insert(p.vcn).inserted { dupVcns += 1 }
        }
        lines.append(dupVcns == 0 ? "语音包 vcn 唯一性：正常" : "⚠️ 语音包存在 \(dupVcns) 个重复 vcn → 语音引擎页会崩！")

        // 凭证状态
        let builtinCred = BuiltinXfyun.decrypt()
        lines.append("内置讯飞凭证：\(builtinCred == nil ? "未内置" : "已内置（AppID \(builtinCred?.appid ?? "")）")")
        lines.append(builtinCred == nil || engine.xfAppID.isEmpty
                     ? "⚠️ 当前 AppID 为空 → 讯飞不可用，会自动回退系统语音"
                     : "当前凭证：AppID \(engine.xfAppID)｜Key \(engine.xfAPIKey.isEmpty ? "空" : "已填")｜Secret \(engine.xfAPISecret.isEmpty ? "空" : "已填")")

        // 定位权限
        let auth = CLLocationManager.authorizationStatus()
        let authText: String
        switch auth {
        case .authorizedAlways: authText = "始终允许（正常）"
        case .authorizedWhenInUse: authText = "仅使用期间 → 锁屏/后台可能不播报，建议开启「始终」"
        case .denied, .restricted: authText = "已拒绝 → 无法播报！请到系统设置开启"
        default: authText = "未请求/未知"
        }
        lines.append("定位权限：\(authText)")

        RingLog.shared.log("自检", "完成（\(lines.count) 项）")
        checkResult = lines
        RingLog.shared.setSelfCheck(lines)
        lastCheck = "最近自检：\(Date().formatted(date: .omitted, time: .standard))"
        refresh()
    }

    private func copyLog() {
        UIPasteboard.general.string = logText
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func shareLog() {
        let text = logText
        let av = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let pop = av.popoverPresentationController {
            pop.sourceView = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first(where: { $0.activationState == .foregroundActive })?
                .windows.first
            pop.sourceRect = CGRect(x: UIScreen.main.bounds.width - 60, y: 44, width: 1, height: 1)
        }
        topViewController()?.present(av, animated: true)
    }

    private func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return nil }
        var vc = (scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first)?.rootViewController
        while let presented = vc?.presentedViewController, !presented.isBeingDismissed {
            vc = presented
        }
        return vc
    }
}
