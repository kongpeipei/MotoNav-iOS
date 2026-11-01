import Foundation
import CoreLocation
import UIKit
import SwiftUI

// =============================================================================
// v1.99 骑士专属能力：限行/禁摩风险识别、实时路况分段、播报分级、沿途服务设施
// 全部本地计算，不依赖额外接口（路况来自高德 v3 返回的 tmc 字段）
// =============================================================================

/// 播报详细程度（"我的 - 语音播报"）
enum SpeechLevel: Int, CaseIterable, Identifiable {
    case simple = 0      // 只报关键转向
    case standard = 1    // 转向 + 红绿灯/测速 + 到达
    case detailed = 2    // 再加路名、剩余里程、弯道、限行提醒

    var id: Int { rawValue }
    var title: String { ["简洁", "标准", "详细"][rawValue] }
    var caption: String {
        switch self {
        case .simple: return "只播报转弯与到达"
        case .standard: return "转弯 + 电子眼 + 到达（推荐）"
        case .detailed: return "再加路名、剩余里程、弯道与限行提醒"
        }
    }
    /// 800 米级远提示
    var farPrompt: Bool { self != .simple }
    /// 转弯后补充路名/剩余里程
    var verbose: Bool { self == .detailed }
}

/// 路线上的骑行风险段（禁摩/限行、隧道、高架、高速、大桥）
struct RoadRisk: Identifiable, Equatable {
    enum Kind: String, Codable {
        case highway      // 高速（多数省份禁摩）
        case elevated     // 高架/快速路（很多城市禁摩）
        case tunnel       // 隧道（部分禁摩，灯光暗）
        case bridge       // 跨江大桥（部分禁摩）
        case restricted   // 明确标注的禁摩/限行路段

        var title: String {
            switch self {
            case .highway: return "高速公路"
            case .elevated: return "高架/快速路"
            case .tunnel: return "隧道"
            case .bridge: return "跨江大桥"
            case .restricted: return "禁摩/限行路段"
            }
        }
        var icon: String {
            switch self {
            case .highway: return "road.lanes"
            case .elevated: return "arrow.up.right.square"
            case .tunnel: return "light.max"
            case .bridge: return "water.waves"
            case .restricted: return "nosign"
            }
        }
        /// 是否属于"摩托车可能不能上"的类型
        var motoBlocked: Bool {
            switch self {
            case .highway, .elevated, .restricted: return true
            case .tunnel, .bridge: return false
            }
        }
        var advice: String {
            switch self {
            case .highway: return "多数省份禁止摩托车上高速，请提前规划国道"
            case .elevated: return "不少城市高架/快速路禁摩，注意入口标志"
            case .tunnel: return "隧道内禁变道，提前开灯"
            case .bridge: return "大桥横风大，注意侧风"
            case .restricted: return "该路段有限行/禁摩标注"
            }
        }
    }

    let kind: Kind
    let roadName: String
    let fromM: Int
    let toM: Int

    var id: String { "\(kind.rawValue)#\(roadName)#\(fromM)" }
    var lengthM: Int { max(0, toM - fromM) }
    /// 是否落在已行驶里程之前（用于导航中过滤）
    func ahead(of traveled: Int) -> Bool { toM > traveled }
}

/// 路况分段（高德 tmc → 折线 + 等级）
struct TrafficSpan: Equatable {
    /// 0 畅通 / 1 缓行 / 2 拥堵 / 3 严重拥堵
    let level: Int
    let points: [CLLocationCoordinate2D]

    static func == (l: TrafficSpan, r: TrafficSpan) -> Bool {
        l.level == r.level && l.points.count == r.points.count
            && (l.points.first?.latitude ?? 0) == (r.points.first?.latitude ?? 0)
            && (l.points.first?.longitude ?? 0) == (r.points.first?.longitude ?? 0)
    }

    var color: UIColor {
        switch level {
        case 0: return UIColor(red: 0.30, green: 0.78, blue: 0.35, alpha: 1)
        case 1: return UIColor(red: 0.98, green: 0.76, blue: 0.18, alpha: 1)
        case 2: return UIColor(red: 0.94, green: 0.36, blue: 0.20, alpha: 1)
        default: return UIColor(red: 0.62, green: 0.10, blue: 0.10, alpha: 1)
        }
    }
    var title: String { ["畅通", "缓行", "拥堵", "严重拥堵"][max(0, min(3, level))] }
}

/// 沿途服务设施类型（"顺路加一站"）
enum ServiceKind: String, CaseIterable, Identifiable {
    case fuel, charge, toilet, store, repair, food

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fuel: return "加油"
        case .charge: return "充电"
        case .toilet: return "卫生间"
        case .store: return "便利店"
        case .repair: return "维修"
        case .food: return "吃饭"
        }
    }
    var icon: String {
        switch self {
        case .fuel: return "fuelpump.fill"
        case .charge: return "bolt.car.fill"
        case .toilet: return "figure.dress.line.vertical.figure"
        case .store: return "cart.fill"
        case .repair: return "wrench.and.screwdriver.fill"
        case .food: return "fork.knife"
        }
    }
    /// 高德周边搜索关键词
    var keyword: String {
        switch self {
        case .fuel: return "加油站"
        case .charge: return "充电桩"
        case .toilet: return "公共厕所"
        case .store: return "便利店"
        case .repair: return "摩托车维修"
        case .food: return "快餐"
        }
    }
    var tint: Color {
        switch self {
        case .fuel: return .orange
        case .charge: return .green
        case .toilet: return .blue
        case .store: return .purple
        case .repair: return .gray
        case .food: return .pink
        }
    }
}

/// 路线风险 / 弯道 / 服务设施 的本地分析器
enum RiderAnalyzer {

    /// 道路名 → 风险类型
    static func classify(_ name: String) -> RoadRisk.Kind? {
        let s = name.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.contains("禁摩") || s.contains("限行") { return .restricted }
        if s.contains("高速") { return .highway }
        if s.contains("高架") || s.contains("快速路") || s.contains("快速干道") || s.contains("立交") { return .elevated }
        if s.contains("隧道") { return .tunnel }
        if s.contains("大桥") || s.contains("特大桥") { return .bridge }
        return nil
    }

    /// 从转向步骤分析风险段：同名/同类道路合并成区间
    static func risks(_ turns: [RouteTurn], totalM: Int) -> [RoadRisk] {
        guard !turns.isEmpty else { return [] }
        var out: [RoadRisk] = []
        for (i, t) in turns.enumerated() {
            guard let kind = classify(t.roadName) else { continue }
            let start = t.fromStartM
            let end = i + 1 < turns.count ? turns[i + 1].fromStartM
                                        : max(totalM, start + 200)
            if let last = out.last, last.kind == kind, last.roadName == t.roadName,
               start - last.toM < 300 {
                out[out.count - 1] = RoadRisk(kind: kind, roadName: last.roadName,
                                              fromM: last.fromM, toM: max(last.toM, end))
            } else {
                out.append(RoadRisk(kind: kind, roadName: t.roadName, fromM: start, toM: end))
            }
        }
        return out
    }

    /// 一句话概括（规划卡上的提醒条）
    static func summary(_ risks: [RoadRisk]) -> String {
        guard !risks.isEmpty else { return "" }
        var byKind: [RoadRisk.Kind: Int] = [:]
        for r in risks { byKind[r.kind, default: 0] += 1 }
        let order: [RoadRisk.Kind] = [.restricted, .highway, .elevated, .tunnel, .bridge]
        let parts = order.compactMap { k -> String? in
            guard let n = byKind[k], n > 0 else { return nil }
            return "\(n) 段\(k.title)"
        }
        return parts.joined(separator: " · ")
    }

    /// 禁摩风险最高的方案下标（全部无风险返回 nil）
    static func mostRestricted(_ list: [RouteChoice]) -> Int? {
        var best = -1
        var bestScore = 0
        for (i, c) in list.enumerated() {
            let risks = risks(c.turns, totalM: c.distanceM)
            let score = risks.filter { $0.kind.motoBlocked }.reduce(0) { $0 + max(1, $1.lengthM / 500) }
            if score > bestScore { bestScore = score; best = i }
        }
        return bestScore > 0 ? best : nil
    }

    /// 弯道检测：连续折线转角 > threshold 视为一个弯，供"连续弯道"播报
    static func curves(_ pts: [CLLocationCoordinate2D], minAngleDeg: Double = 45) -> [(coord: CLLocationCoordinate2D, deg: Double)] {
        guard pts.count > 4 else { return [] }
        var out: [(CLLocationCoordinate2D, Double)] = []
        var lastIdx = -6
        for i in 1..<(pts.count - 1) {
            guard i - lastIdx >= 5 else { continue }
            let a = bearing(pts[i - 1], pts[i])
            let b = bearing(pts[i], pts[i + 1])
            var d = abs(b - a)
            if d > 180 { d = 360 - d }
            if d >= minAngleDeg {
                out.append((pts[i], d))
                lastIdx = i
            }
        }
        return out
    }

    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return atan2(y, x) * 180 / .pi
    }
}
