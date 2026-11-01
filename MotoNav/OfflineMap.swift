import Foundation
import CoreLocation
import UIKit

// =============================================================================
// v1.99 离线地图包：按城市/半径预下载高德瓦片到 Tiles/offline/，
// 山区无信号时地图仍有底图（渲染器会优先读这里，导航时也用得上）。
// 瓦片命名与在线缓存完全一致（d-z-x-y.png），因此可被缓存复用、无需改渲染逻辑。
// =============================================================================

struct OfflinePack: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var lat: Double
    var lon: Double
    var radiusKm: Double
    var tileCount: Int
    var bytes: Int
    var levels: String
    var finishedAt: Date

    var sizeText: String {
        bytes > 1024 * 1024 ? String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
                            : "\(bytes / 1024) KB"
    }
    var subtitle: String { "\(sizeText) · \(tileCount) 张 · \(levels)" }
}

@MainActor
final class OfflineMapManager: ObservableObject {
    static let shared = OfflineMapManager()

    /// 渲染器共用的瓦片目录（必须与 AmapTileRenderer 一致）
    static let tileRoot: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tiles", isDirectory: true)
        return u
    }()
    static let offlineDir: URL = tileRoot.appendingPathComponent("offline", isDirectory: true)

    @Published private(set) var packs: [OfflinePack] = []
    @Published var busy = false
    @Published var progress: Double = 0
    @Published var progressText = ""
    @Published var lastError: String?

    private var cancelled = false
    private let manifestURL = OfflineMapManager.tileRoot.appendingPathComponent("offline-packs.json")

    private init() {
        try? FileManager.default.createDirectory(at: Self.offlineDir, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
              let list = try? JSONDecoder().decode([OfflinePack].self, from: data) else { return }
        packs = list.sorted { $0.finishedAt > $1.finishedAt }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(packs) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    var totalBytes: Int { packs.reduce(0) { $0 + $1.bytes } }
    var totalText: String {
        totalBytes > 1024 * 1024 ? String(format: "%.1f MB", Double(totalBytes) / 1024 / 1024)
                                 : "\(totalBytes / 1024) KB"
    }

    func cancel() { cancelled = true }

    func delete(_ pack: OfflinePack) {
        let keys = Self.tileKeys(lat: pack.lat, lon: pack.lon, radiusKm: pack.radiusKm)
        for k in keys {
            try? FileManager.default.removeItem(at: Self.offlineDir.appendingPathComponent(k + ".png"))
        }
        packs.removeAll { $0.id == pack.id }
        persist()
    }

    // MARK: - 下载

    /// 估算将要下载的瓦片数（不联网，按典型纬度估算）
    static func estimateTileCount(radiusKm: Double) -> Int {
        tileKeys(lat: 31.23, lon: 121.47, radiusKm: radiusKm).count
    }

    func download(name: String, lat: Double, lon: Double, radiusKm: Double) async {
        guard !busy else { return }
        busy = true
        cancelled = false
        lastError = nil
        progress = 0
        progressText = "准备中…"
        try? FileManager.default.createDirectory(at: Self.offlineDir, withIntermediateDirectories: true)

        let keys = Self.tileKeys(lat: lat, lon: lon, radiusKm: radiusKm)
        guard !keys.isEmpty else {
            busy = false
            lastError = "范围太小，未生成瓦片"
            return
        }
        let levels = Self.levelRange(radiusKm: radiusKm)
        var done = 0
        var bytes = 0
        let total = keys.count

        // 6 并发抓取，避免触发高德限流又能跑满带宽
        await withTaskGroup(of: (String, Int).self) { group in
            var iterator = keys.makeIterator()
            var inflight = 0
            func addNext() {
                guard let key = iterator.next() else { return }
                inflight += 1
                group.addTask { await Self.fetchOne(key: key) }
            }
            for _ in 0..<6 { addNext() }
            while let (key, size) = await group.next() {
                inflight -= 1
                if cancelled { break }
                done += 1
                bytes += size
                if !key.isEmpty { progress = Double(done) / Double(total) }
                // 进度文字每 20 张刷一次，降低主线程压力
                if done % 20 == 0 || done == total {
                    progressText = "已下载 \(done)/\(total) 张 · \(bytes / 1024) KB"
                }
                addNext()
            }
        }

        if cancelled {
            busy = false
            progressText = "已取消"
            // 已下载的瓦片保留（在线缓存同样能用）
            return
        }
        let pack = OfflinePack(name: name, lat: lat, lon: lon, radiusKm: radiusKm,
                               tileCount: total, bytes: bytes,
                               levels: Self.levelsText(levels), finishedAt: Date())
        packs.insert(pack, at: 0)
        persist()
        progress = 1
        progressText = "完成：\(pack.subtitle)"
        busy = false
    }

    private static func fetchOne(key: String) async -> (String, Int) {
        let parts = key.split(separator: "-")
        guard parts.count == 4,
              let z = Int(parts[1]), let x = Int(parts[2]), let y = Int(parts[3]) else { return ("", 0) }
        let dest = offlineDir.appendingPathComponent(key + ".png")
        if FileManager.default.fileExists(atPath: dest.path) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
            let sz = (attrs?[.size] as? Int) ?? 0
            return (key, sz)
        }
        let sd = ((x + y) % 4) + 1
        let urlStr = AmapTileOverlay.tileURL
            .replacingOccurrences(of: "{SD}", with: "\(sd)")
            .replacingOccurrences(of: "{STYLE}", with: "7")
            .replacingOccurrences(of: "{x}", with: "\(x)")
            .replacingOccurrences(of: "{y}", with: "\(y)")
            .replacingOccurrences(of: "{z}", with: "\(z)")
        guard let url = URL(string: urlStr) else { return ("", 0) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("MotoNav/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 500 else { return ("", 0) }
        try? data.write(to: dest, options: .atomic)
        return (key, data.count)
    }

    // MARK: - 瓦片键计算（与渲染器一致：v2.00 底图直铺 GCJ 网格，索引即目标瓦片）

    private static func levelRange(radiusKm: Double) -> ClosedRange<Int> {
        if radiusKm <= 5 { return 12...16 }
        if radiusKm <= 15 { return 11...15 }
        if radiusKm <= 40 { return 10...14 }
        return 9...13
    }

    private static func levelsText(_ r: ClosedRange<Int>) -> String {
        "z\(r.lowerBound)-\(r.upperBound)"
    }

    static func tileKeys(lat: Double, lon: Double, radiusKm: Double) -> [String] {
        let levels = levelRange(radiusKm: radiusKm)
        let (glat, glon) = CoordConv.wgs2gcj(lat, lon)
        // 半径 → 经纬度跨度（含 15% 余量，覆盖投影误差）
        let dLat = radiusKm / 111.0 * 1.15
        let dLon = radiusKm / (111.0 * max(0.2, cos(glat * .pi / 180))) * 1.15
        var out: [String] = []
        var seen = Set<String>()
        for z in levels {
            let n = Double(1 << z)
            let x0 = Int(floor((glon - dLon + 180) / 360 * n))
            let x1 = Int(floor((glon + dLon + 180) / 360 * n))
            let y0 = tileY(glat + dLat, z)
            let y1 = tileY(glat - dLat, z)
            guard x1 >= x0, y1 >= y0 else { continue }
            for x in x0...x1 {
                for y in y0...y1 {
                    guard x >= 0, y >= 0, x < Int(n), y < Int(n) else { continue }
                    let key = "d-\(z)-\(x)-\(y)"
                    if seen.insert(key).inserted { out.append(key) }
                }
            }
            if out.count > 5000 { break }   // 安全上限，避免一次下载过多
        }
        return out
    }

    private static func tileY(_ lat: Double, _ z: Int) -> Int {
        let n = Double(1 << z)
        let clamped = min(85.0, max(-85.0, lat))
        let r = clamped / 180.0 * .pi
        return Int(floor((1.0 - log(tan(r) + 1.0 / cos(r)) / .pi) / 2.0 * n))
    }
}
