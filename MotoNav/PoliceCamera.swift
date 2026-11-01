//
//  PoliceCamera.swift
//  MotoNav
//
//  v2.04 新增：合肥市官方电警点位图层
//
//  数据来源
//  --------
//  合肥市公安局交通警察支队在「合肥市公安局 → 重点领域信息公开 → 交通管理 →
//  交通秩序管理公告」栏目逐批公示的《新增非现场处罚点位公示》
//  （gaj.hefei.gov.cn/public/6811/…），以及安徽省公安厅机场公安局的通告。
//  内置的 hefei_cameras.json 逐条标注了所属公示，坐标由高德地理编码解析后人工核对。
//
//  为什么不是"全量"
//  ----------------
//  交管部门只公示**新增**点位，历史底库从未完整公开。所以这份内置库是
//  "能在公开渠道逐条核实的点位集合"，不是合肥电警的全部。
//  后续新公示可以按同样的 JSON 结构追加（我的 → 电警点位 → 导入）。
//
//  只针对摩托车
//  ------------
//  摩托车会被拍的主要是：闯红灯（电警）、不戴头盔/闯禁行/超速（卡口）、
//  不礼让行人。数据里只保留这几类，纯汽车的"不系安全带/打电话"不单独提醒。
//

import Foundation
import CoreLocation
import UIKit

// MARK: - 点位类型

enum CameraKind: String, Codable, CaseIterable {
    /// 电子警察：闯红灯、不按导向车道、压线、逆行
    case redLight = "电警"
    /// 卡口：不戴头盔、闯禁行、超速、违反禁令标志
    case checkpoint = "卡口"
    /// 人行横道不礼让行人
    case yieldPedestrian = "礼让行人"

    var title: String { rawValue }

    /// 语音里的抓拍说明（摩托车视角）
    var voiceAction: String {
        switch self {
        case .redLight: return "电子警察，注意信号灯"
        case .checkpoint: return "卡口抓拍，注意禁令标志、别闯禁行"
        case .yieldPedestrian: return "人行横道，注意礼让行人"
        }
    }

    /// 地图图标
    var icon: String {
        switch self {
        case .redLight: return "camera.fill"
        case .checkpoint: return "video.fill"
        case .yieldPedestrian: return "figure.walk"
        }
    }

    var color: UIColor {
        switch self {
        case .redLight: return UIColor(red: 0.90, green: 0.16, blue: 0.20, alpha: 1)
        case .checkpoint: return UIColor(red: 0.95, green: 0.45, blue: 0.10, alpha: 1)
        case .yieldPedestrian: return UIColor(red: 0.85, green: 0.20, blue: 0.55, alpha: 1)
        }
    }
}

// MARK: - 单个点位

struct PoliceCamera: Codable, Identifiable, Equatable {
    let id: Int
    /// 官方点位名（路口名），如「清溪路与潜山路交口」
    let name: String
    let district: String
    let type: CameraKind
    /// v2.20 改为可变：支持用户手动拖动校准（原始公示坐标会被覆盖值替换）
    var lat: Double
    var lon: Double
    /// 抓拍方向（官方公示原样，如「东、西、北」）
    var dirs: String = ""
    /// 坐标精度：路口POI（±30m）/ 地理编码（±300m）
    var acc: String = ""
    /// 来源公示（便于溯源）
    var source: String = ""

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// 播报用简称：去掉"交口"和市名，读起来不生硬
    var spokenName: String {
        name.replacingOccurrences(of: "交口", with: "")
            .replacingOccurrences(of: "合肥市", with: "")
    }

    /// 地图气泡副标题
    var detailLine: String {
        var parts: [String] = [district]
        if !dirs.isEmpty { parts.append("抓拍方向 \(dirs)") }
        if !acc.isEmpty { parts.append(acc) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 数据仓库

@MainActor
final class PoliceCameraStore: ObservableObject {
    static let shared = PoliceCameraStore()

    /// 全部官方点位（内置库 + 用户手动校准后的坐标）
    @Published private(set) var all: [PoliceCamera] = []
    /// v2.20 已被用户手动校准过的点位数
    @Published private(set) var adjustedCount = 0
    /// 内置库原始点位（不被校准覆盖污染）
    private var raw: [PoliceCamera] = []
    /// 人工校准覆盖表：id → [lat, lon]（WGS）
    private var overrides: [Int: [Double]] = [:]
    private let overrideKey = "pcCoordOverrides"
    /// 地图图层开关（默认开：打开就能看到红点）
    @Published var layerOn: Bool {
        didSet { UserDefaults.standard.set(layerOn, forKey: "pcLayerOn") }
    }
    /// 接近语音提醒（默认开）
    @Published var voiceOn: Bool {
        didSet { UserDefaults.standard.set(voiceOn, forKey: "pcVoiceOn") }
    }

    private init() {
        layerOn = UserDefaults.standard.object(forKey: "pcLayerOn") as? Bool ?? true
        voiceOn = UserDefaults.standard.object(forKey: "pcVoiceOn") as? Bool ?? true
        load()
    }

    private func load() {
        // v2.20 先读人工校准覆盖表，再套到内置库上
        if let saved = UserDefaults.standard.dictionary(forKey: overrideKey) as? [String: [Double]] {
            for (k, v) in saved {
                if let id = Int(k), v.count == 2 { overrides[id] = v }
            }
        }
        guard let url = Bundle.main.url(forResource: "hefei_cameras", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([PoliceCamera].self, from: data) else {
            applyOverrides()
            return
        }
        raw = list
        applyOverrides()
    }

    /// 把人工校准坐标套到内置库上（每次改动后重算 all）
    private func applyOverrides() {
        all = raw.map { c in
            guard let o = overrides[c.id], o.count == 2 else { return c }
            var n = c
            n.lat = o[0]
            n.lon = o[1]
            return n
        }
        adjustedCount = overrides.count
    }

    /// v2.20 手动拖动校准：记录新坐标并持久化（下次启动仍然生效）
    func adjust(id: Int, lat: Double, lon: Double) {
        overrides[id] = [lat, lon]
        saveOverrides()
        applyOverrides()
    }

    /// 恢复某个点的官方公示坐标
    func restore(id: Int) {
        overrides.removeValue(forKey: id)
        saveOverrides()
        applyOverrides()
    }

    /// 清除全部人工校准
    func restoreAll() {
        overrides.removeAll()
        saveOverrides()
        applyOverrides()
    }

    private func saveOverrides() {
        var d: [String: [Double]] = [:]
        for (k, v) in overrides { d[String(k)] = v }
        UserDefaults.standard.set(d, forKey: overrideKey)
    }

    /// 地图要显示的点位（关掉图层就是空数组）
    var visible: [PoliceCamera] { layerOn ? all : [] }

    /// 当前位置附近的点位（由近到远），limit 控制返回量
    func nearest(to coord: CLLocationCoordinate2D, limit: Int = 3) -> [(PoliceCamera, Double)] {
        all
            .map { ($0, $0.coordinate.distance(to: coord)) }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map { $0 }
    }
}
