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

    /// 同步写盘（v2.09）。
    ///
    /// `mark` 是把写入丢到串行队列里，正常用没问题；但**进程被系统硬杀时不保证落地**，
    /// 之前几版最后一行日志因此不可信（bf-end / map-make 可能确实执行了，只是没写进去）。
    /// 诊断关键路径（body 各段、makeUIView 各步）一律用这个，代价是几十次同步写，可接受。
    static func markSync(_ stage: String, _ detail: String = "") {
        // 锁在 append 内部（异步路径同样走那里），这里不要再加锁，否则同一把非递归锁会死锁
        append("\(timestamp()) \(stage)\(detail.isEmpty ? "" : " — " + detail)\n")
    }

    private static let syncLock = NSLock()

    /// 只记第一次（用于 body / updateUIView 这类每次刷新都会跑的位置，避免刷屏）
    private static var onceKeys = Set<String>()
    private static let onceLock = NSLock()
    static func markOnce(_ stage: String, _ detail: String = "") {
        onceLock.lock()
        let first = onceKeys.insert(stage).inserted
        onceLock.unlock()
        guard first else { return }
        markSync(stage, detail)
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: Date())
    }

    private static func append(_ line: String) {
        syncLock.lock()
        defer { syncLock.unlock() }
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

    /// 取最后 n 行（诊断页直接显示在屏幕上，用户不用去「文件」App 找）
    static func tail(_ n: Int) -> String {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return "（无日志）" }
        let lines = text.split(separator: "\n").map(String.init)
        return lines.suffix(n).joined(separator: "\n")
    }

    /// 清空日志（设置页"清空启动日志"按钮用）
    static func clear() {
        queue.async { try? FileManager.default.removeItem(at: fileURL) }
    }
}
