import Foundation
import UIKit

/// v1.18：运行日志导出为文件（.txt / .ips 两种格式），供分享给开发者或直接分析。
enum LogExporter {
    private static var df: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }

    /// 导出 .txt：纯文本日志（与查看页内容一致）
    static func writeTxt() -> URL? {
        let text = RingLog.shared.export()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraGuard-runlog-\(df.string(from: Date())).txt")
        guard let data = text.data(using: .utf8) else { return nil }
        try? data.write(to: url)
        return url
    }

    /// 导出 .ips：模拟 iOS 崩溃日志结构（JSON），异常项来自自检结果，
    /// 可直接当作崩溃日志交给开发者 / AI 分析。
    static func writeIPS() -> URL? {
        var dict: [String: Any] = [:]
        dict["app_name"] = "CameraGuard"
        dict["app_version"] = AlertEngine.appVersion
        dict["build_version"] = AlertEngine.appBuild
        dict["bundleID"] = "com.motonav.app.eye"
        dict["os_version"] = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        dict["device_model"] = UIDevice.current.model
        let ts = DateFormatter()
        ts.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"
        dict["timestamp"] = ts.string(from: Date())
        dict["exception_type"] = "运行日志（非崩溃）"
        dict["exception_notes"] = RingLog.shared.selfCheck.filter { $0.hasPrefix("⚠️") }
        dict["event_log"] = Array(RingLog.shared.export()
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("[") })

        guard let json = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: json, encoding: .utf8) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraGuard-\(df.string(from: Date())).ips")
        // .ips 文件惯例：首行为 JSON 头说明，之后为 JSON 正文
        guard let data = ("// 运行日志导出（电子眼卫士 CameraGuard）\n" + text).data(using: .utf8) else { return nil }
        try? data.write(to: url)
        return url
    }
}
