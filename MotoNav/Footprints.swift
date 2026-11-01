import Foundation
import CoreLocation
import SwiftUI
import UIKit

// =============================================================================
// v1.99 足迹与行程记录：每次导航自动存档轨迹（里程/时长/均速/最高速），
// 可在"我的 - 足迹"回看、在地图上回放，支持删除与导出 GPX。
// 数据落在 Documents/footprints.json，卸载 App 才会清除。
// =============================================================================

struct Footprint: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    /// 目的地名称
    var destName: String
    /// 开始时间
    var startedAt: Date
    var distanceM: Int
    var durationS: Int
    /// 平均速度 km/h
    var avgSpeed: Double
    /// 最高速度 km/h
    var maxSpeed: Double
    /// 轨迹点（每点 [纬度, 经度]），已按距离抽稀
    var points: [[Double]]

    var coordinateList: [CLLocationCoordinate2D] {
        points.compactMap { p in
            p.count >= 2 ? CLLocationCoordinate2D(latitude: p[0], longitude: p[1]) : nil
        }
    }

    var dateText: String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: startedAt)
    }
    var distanceText: String {
        distanceM >= 1000 ? String(format: "%.1f km", Double(distanceM) / 1000) : "\(distanceM) m"
    }
    var durationText: String {
        let m = durationS / 60
        return m >= 60 ? "\(m / 60) 小时 \(m % 60) 分" : (m > 0 ? "\(m) 分钟" : "\(durationS) 秒")
    }
}

/// 足迹仓库（单例，导航结束自动写入）
final class FootprintStore: ObservableObject {
    static let shared = FootprintStore()

    @Published private(set) var items: [Footprint] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("footprints.json")
    }()

    private init() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([Footprint].self, from: data) else { return }
        items = list.sorted { $0.startedAt > $1.startedAt }
    }

    private func persist() {
        // 最多保留 200 条，避免无限增长
        if items.count > 200 { items = Array(items.prefix(200)) }
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func add(_ f: Footprint) {
        guard f.distanceM >= 80, f.points.count >= 2 else { return }
        items.insert(f, at: 0)
        persist()
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
    }

    var totalDistanceM: Int { items.reduce(0) { $0 + $1.distanceM } }
    var totalDurationS: Int { items.reduce(0) { $0 + $1.durationS } }

    /// 导出 GPX（分享用）
    func gpx(for f: Footprint) -> String {
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        s += "<gpx version=\"1.1\" creator=\"MotoNav\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n"
        s += "<trk><name>\(f.destName)</name><trkseg>\n"
        for p in f.points where p.count >= 2 {
            s += "<trkpt lat=\"\(p[0])\" lon=\"\(p[1])\"></trkpt>\n"
        }
        s += "</trkseg></trk></gpx>\n"
        return s
    }
}

/// 轨迹抽稀：相邻点 <15 米丢弃，控制存档体积
enum TrackSimplifier {
    static func simplify(_ pts: [CLLocationCoordinate2D], minGapM: Double = 15) -> [[Double]] {
        var out: [[Double]] = []
        var last: CLLocationCoordinate2D?
        for p in pts {
            if let l = last {
                let d = CLLocation(latitude: l.latitude, longitude: l.longitude)
                    .distance(from: CLLocation(latitude: p.latitude, longitude: p.longitude))
                if d < minGapM { continue }
            }
            out.append([p.latitude, p.longitude])
            last = p
        }
        // 末点补齐，保证轨迹到终点
        if let l = last, let lastPt = pts.last,
           l.latitude != lastPt.latitude || l.longitude != lastPt.longitude {
            out.append([lastPt.latitude, lastPt.longitude])
        }
        return out
    }
}

/// 轨迹 GPX 导出（系统分享面板）
struct GPXShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
