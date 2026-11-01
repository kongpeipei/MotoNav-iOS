//
//  StartupLog.swift
//  MotoNav
//
//  v2.03 新增：启动过程埋点日志
//
//  背景：用企业证书/第三方签名服务重签后出现「点图标闪一下退回桌面」时，
//        设备上没有任何可读的崩溃信息，只能靠猜。这个日志把启动的每一步
//        （进程起来 → 模型初始化完成 → 首屏渲染完成）写进沙箱 Documents，
//        并开启「文件」App 共享（UIFileSharingEnabled）：
//        设置 → 文件 App → 我的 iPhone → 骑士地图 → startup.log
//
//  判读方法：
//    · 只有 "app-launch"                    → 死在 AppModel 初始化之前（签名/entitlement 问题）
//    · 有 "app-launch" + "model-ready"       → 死在首屏构建（代码问题，能定位到具体阶段）
//    · 三步都有 "ui-ready"                   → 启动本身没问题，闪退发生在之后
//    · 一条都没有                            → 进程根本没起来，100% 是签名问题
//

import Foundation

enum StartupLog {
    /// 日志文件路径（沙箱 Documents/startup.log，可在「文件」App 里直接看到）
    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("startup.log")
    }

    /// 串行队列：定位/渲染回调在多个线程触发，避免并发写同一文件
    private static let queue = DispatchQueue(label: "motonav.startuplog")

    /// 记录一个启动阶段标记
    static func mark(_ stage: String, _ detail: String = "") {
        let line = "\(timestamp()) \(stage)\(detail.isEmpty ? "" : " — " + detail)\n"
        queue.async { append(line) }
    }

    /// 记录错误（不崩溃，只留痕）
    static func error(_ stage: String, _ err: Error) {
        mark(stage, "ERROR: \(err.localizedDescription)")
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: Date())
    }

    private static func append(_ line: String) {
        let url = fileURL
        var data = (try? Data(contentsOf: url)) ?? Data()
        // 日志上限 64KB：超过就砍掉前半段，防止长期使用无限增长
        if data.count > 64 * 1024 {
            data = data.suffix(32 * 1024)
        }
        // 每次启动插一条分隔线，方便分辨"这次"和"上次"
        if data.isEmpty {
            data.append(Data("=== 骑士地图启动日志 ===\n".utf8))
        }
        data.append(Data(line.utf8))
        try? data.write(to: url, options: .atomic)
    }

    /// 清空日志（设置页"清空启动日志"按钮用）
    static func clear() {
        queue.async { try? FileManager.default.removeItem(at: fileURL) }
    }
}
