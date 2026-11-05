import Foundation

/// v1.18：内存环形运行日志。
/// 用于用户反馈「点位管理/语音引擎异常」等运行问题时，把关键路径事件记录在案，
/// 由主界面右上角「运行日志」按钮打开查看/导出，配合开发者快速定位。
/// 线程安全：内部用 NSLock 保护，任意线程可调用 log()。
final class RingLog: @unchecked Sendable {
    static let shared = RingLog()

    private struct Entry {
        let time: Date
        let tag: String
        let message: String
    }

    private var entries: [Entry] = []
    private let capacity = 800
    private let lock = NSLock()
    /// 自检结果（LogViewer 点「运行自检」后写入，导出时一并附上）
    private(set) var selfCheck: [String] = []

    private init() {}

    /// 追加一条日志（超容量丢弃最旧）
    func log(_ tag: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(Entry(time: Date(), tag: tag, message: message))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        #if DEBUG
        NSLog("[CameraGuard:%@] %@", tag, message)
        #endif
    }

    /// 记录一次自检结果（不影响滚动日志）
    func setSelfCheck(_ lines: [String]) {
        lock.lock()
        defer { lock.unlock() }
        selfCheck = lines
    }

    /// 导出全部日志文本（含自检结果；用于复制/分享给开发者）
    func export() -> String {
        lock.lock()
        defer { lock.unlock() }
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm:ss.SSS"
        var lines = ["电子眼卫士 CameraGuard 运行日志（v1.18 内置）", "导出时间：\(df.string(from: Date()))", ""]
        if !selfCheck.isEmpty {
            lines.append("===== 运行自检 =====")
            lines.append(contentsOf: selfCheck)
            lines.append("")
        }
        lines.append("===== 事件日志 =====")
        lines.append(contentsOf: entries.map { "[\(df.string(from: $0.time))][\($0.tag)] \($0.message)" })
        return lines.joined(separator: "\n")
    }

    /// 清空日志
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        selfCheck.removeAll()
    }

    /// 供查看页统计
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}
