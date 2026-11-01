import Foundation
import CoreLocation
import SwiftUI

// MARK: - v2.01 红绿灯倒计时

/// 路口信号灯
///
/// 说明：高德 Web 服务不返回路口信号灯的实时相位，这里用**稳定的本地相位模型**——
/// 同一路口（按坐标做种子）每次进来倒计时都一致，周期 62 秒、红灯 34 秒，
/// 与市区常见配时接近；界面上标注"预计"，不冒充交管实时数据。
struct TrafficLight: Identifiable {
    let id: Int
    let coordinate: CLLocationCoordinate2D
    /// 距路线起点的里程（米）
    let fromStartM: Int
    /// 相位偏移（0~cycle 秒），由坐标决定 → 同一路口每次一致
    private let offset: Double

    /// 一个完整周期（秒）
    static let cycle: Double = 62
    /// 红灯时长（秒）
    static let redLen: Double = 34

    init(id: Int, coordinate: CLLocationCoordinate2D, fromStartM: Int) {
        self.id = id
        self.coordinate = coordinate
        self.fromStartM = fromStartM
        let seed = abs(coordinate.latitude * 1000.0 + coordinate.longitude * 1000.0)
        self.offset = (seed * 7.3).truncatingRemainder(dividingBy: Self.cycle)
    }

    /// 当前相位：是否红灯 + 剩余秒数
    func state(at date: Date = Date()) -> (red: Bool, remain: Int) {
        let t = date.timeIntervalSince1970 + offset
        let p = t.truncatingRemainder(dividingBy: Self.cycle)
        if p < Self.redLen {
            return (true, max(1, Int((Self.redLen - p).rounded(.up))))
        }
        return (false, max(1, Int((Self.cycle - p).rounded(.up))))
    }
}

enum TrafficLightBuilder {
    /// 从转向步骤提取"有信号灯的路口"
    ///
    /// 高德/OSRM 的 step 只在**路口处**切段，因此左转/右转/直行/掉头这些
    /// 动作点基本就是信号灯所在位置；同一路口 60 米内合并，避免一个路口算两次。
    static func lights(turns: [RouteTurn]) -> [TrafficLight] {
        var out: [TrafficLight] = []
        for t in turns where isSignalized(t.action) {
            if let last = out.last,
               last.coordinate.distance(to: t.coordinate) < 60 { continue }
            out.append(TrafficLight(id: out.count, coordinate: t.coordinate, fromStartM: t.fromStartM))
        }
        return out
    }

    /// 该动作是否发生在（通常会设信号灯的）路口
    private static func isSignalized(_ action: String) -> Bool {
        if action.isEmpty { return false }
        // 高德中文动作
        let cn = ["左转", "右转", "直行", "掉头", "左前方", "右前方", "向左后方", "向右后方"]
        if cn.contains(where: { action.contains($0) }) { return true }
        // OSRM 英文动作
        let en = ["turn", "end of road", "slight", "sharp", "uturn", "continue"]
        let a = action.lowercased()
        if en.contains(where: { a.contains($0) }) { return true }
        return false
    }
}

// MARK: - v2.01 车道级引导

/// 一条车道：图标 + 是否推荐走这条
struct LaneGuide: Identifiable {
    let id: Int
    let icon: String
    let recommended: Bool
}

enum LaneGuideBuilder {
    /// 生成车道组：优先用路线自带车道数据（OSRM indications），
    /// 高德接口没有车道字段时按转向动作合成一组（左/直/右 + 需走车道高亮）。
    static func guides(turn: RouteTurn?) -> [LaneGuide] {
        guard let t = turn else { return [] }
        if !t.lanes.isEmpty {
            var out: [LaneGuide] = []
            var anyRec = false
            for (i, lane) in t.lanes.enumerated() {
                let rec = matches(lane, modifier: t.modifier, action: t.action)
                if rec { anyRec = true }
                out.append(LaneGuide(id: i, icon: icon(lane), recommended: rec))
            }
            // 没有一条能对应上（数据异常）时，退化为首条推荐
            if !anyRec, !out.isEmpty {
                out[0] = LaneGuide(id: 0, icon: out[0].icon, recommended: true)
            }
            return out
        }
        // 合成车道组
        let leftish = isLeft(t.modifier, t.action)
        let rightish = isRight(t.modifier, t.action)
        if isUturn(t.modifier, t.action) {
            return [LaneGuide(id: 0, icon: "arrow.uturn.left", recommended: true),
                    LaneGuide(id: 1, icon: "arrow.up", recommended: false),
                    LaneGuide(id: 2, icon: "arrow.up.right", recommended: false)]
        }
        if leftish {
            return [LaneGuide(id: 0, icon: "arrow.up.left", recommended: true),
                    LaneGuide(id: 1, icon: "arrow.up.left", recommended: true),
                    LaneGuide(id: 2, icon: "arrow.up", recommended: false),
                    LaneGuide(id: 3, icon: "arrow.up.right", recommended: false)]
        }
        if rightish {
            return [LaneGuide(id: 0, icon: "arrow.up.left", recommended: false),
                    LaneGuide(id: 1, icon: "arrow.up", recommended: false),
                    LaneGuide(id: 2, icon: "arrow.up", recommended: false),
                    LaneGuide(id: 3, icon: "arrow.up.right", recommended: true)]
        }
        // 直行：中间两条车道
        return [LaneGuide(id: 0, icon: "arrow.up.left", recommended: false),
                LaneGuide(id: 1, icon: "arrow.up", recommended: true),
                LaneGuide(id: 2, icon: "arrow.up", recommended: true),
                LaneGuide(id: 3, icon: "arrow.up.right", recommended: false)]
    }

    private static func icon(_ lane: String) -> String {
        switch lane {
        case "left", "sharp left": return "arrow.up.left"
        case "slight left": return "arrow.up.left"
        case "right", "sharp right": return "arrow.up.right"
        case "slight right": return "arrow.up.right"
        case "uturn": return "arrow.uturn.left"
        case "merge": return "arrow.merge"
        case "fork": return "arrow.triangle.branch"
        default: return "arrow.up"
        }
    }

    private static func matches(_ lane: String, modifier: String, action: String) -> Bool {
        let l = lane.lowercased()
        if isLeft(modifier, action) { return l.contains("left") }
        if isRight(modifier, action) { return l.contains("right") }
        if isUturn(modifier, action) { return l.contains("uturn") }
        return l.contains("straight") || l == "none"
    }

    private static func isLeft(_ m: String, _ a: String) -> Bool {
        let s = (m + " " + a).lowercased()
        return s.contains("left") || s.contains("左")
    }
    private static func isRight(_ m: String, _ a: String) -> Bool {
        let s = (m + " " + a).lowercased()
        return s.contains("right") || s.contains("右")
    }
    private static func isUturn(_ m: String, _ a: String) -> Bool {
        let s = (m + " " + a).lowercased()
        return s.contains("uturn") || s.contains("掉头")
    }
}

extension CLLocationCoordinate2D {
    /// 两点距离（米，局部平面近似，够用于路口合并）
    func distance(to other: CLLocationCoordinate2D) -> Double {
        let dy = (other.latitude - latitude) * 110540.0
        let dx = (other.longitude - longitude) * 111320.0 * cos(latitude * .pi / 180.0)
        return (dx * dx + dy * dy).squareRoot()
    }
}
