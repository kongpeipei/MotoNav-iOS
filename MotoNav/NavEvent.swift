//
//  NavEvent.swift
//  MotoNav
//
//  v2.27 新增：导航事件统一调度
//
//  为什么需要这个文件
//  ------------------
//  优化建议 #10：语音播报与顶部提示应共用一套事件调度。
//
//  改造前的问题（真实存在的错位风险）：
//  · 顶部提示文案由 AppModel.navTopHintText() 生成
//  · 语音播报由 AppModel 里另一段逻辑（turnText + speak）生成
//  两条链路各自算"前方多少米、什么动作"，于是可能出现
//  「语音说右转、卡片显示左转」「语音报 120 米、卡片显示 80 米」。
//
//  改造后的做法：
//  两者都从**同一个** GuidanceEvent 派生 —— 事件里已经算好了
//  距离、动作、进入道路、车道建议，UI 只负责显示，语音只负责念。
//  物理上杜绝不一致。
//
//  距离分级（建议 #9）
//  ----------------
//  旧逻辑：>60 米只报动作不报米数，≤60 米才报米数。
//  问题：60 米处数字每 0.5 秒跳一次，骑行时读数追不上。
//
//  新分级：
//  · >300 米   → 不显示米数（省空间，也不值得念）
//  · 60~300 米 → 显示米数，但**取整到 10 米**（200/190/180…），跳得慢、好读
//  · ≤60 米    → 显示精确米数
//
//  车道路线（建议 #8）
//  ----------------
//  高德 steps 里已经解析了 lanes（车道信息），但此前只用于底部车道图标。
//  这里把它带进事件，顶部提示卡就能显示「进入长江东路 · 走第 2 车道」。
//

import Foundation
import CoreLocation

// MARK: - 导航事件

/// v2.27 导航事件：顶部提示与语音播报的唯一数据源
struct GuidanceEvent {
    /// 事件类型
    enum Kind {
        /// 起步阶段，还没驶入主线
        case needExit
        /// 前方有转向动作
        case turn
        /// 直行到终点
        case straightToEnd
    }

    let kind: Kind
    /// 转向图标（SF Symbol 名）
    let icon: String
    /// 主文案（"前方 200 米右转"）
    let text: String
    /// 副文案（"进入长江东路"）
    let subtitle: String
    /// 车道建议（"走第 2 车道"）；没有车道数据时为空
    let laneHint: String
    /// 车道图标列表（对应 lanes 顺序）
    let laneIcons: [String]
    /// 推荐车道下标（对应 laneIcons 的索引）；-1 表示无推荐
    let recommendedLane: Int
    /// 距离（米）；needExit / straightToEnd 时为 0
    let distanceM: Int
    /// 动作中文（"右转"），语音用
    let action: String
    /// 目标道路名（语音用）
    let roadName: String

    /// 是否有车道建议
    var hasLaneHint: Bool { !laneHint.isEmpty }
}

// MARK: - 事件生成器

/// v2.27 导航事件生成器
///
/// 放在 AppModel 之外做成独立枚举，是为了让它可以被单测覆盖，
/// 且不依赖 AppModel 的 @Published 状态（避免在 body 求值时被牵动）。
enum GuidanceEventBuilder {

    // MARK: 距离分级常量

    /// 超过这个距离就不显示米数了（省空间 + 没必要念）
    static let hideDistanceAboveM = 300
    /// 超过这个距离把米数取整到 10 米（60~300 米之间）
    static let roundDistanceAboveM = 60
    /// 取整到多少米
    static let roundStepM = 10

    /// 按分级格式化距离
    /// - 300 米以上 → nil（不显示）
    /// - 60~300 米 → 取整到 10 米
    /// - 60 米以下 → 精确值
    static func formatDistance(_ m: Int) -> String? {
        guard m > 0 else { return nil }
        if m > hideDistanceAboveM { return nil }
        if m > roundDistanceAboveM {
            let r = ((m + roundStepM / 2) / roundStepM) * roundStepM
            return "\(r)米"
        }
        return "\(m)米"
    }

    /// 生成导航事件
    /// - Parameters:
    ///   - turns: 路线转向步骤
    ///   - traveledM: 已行驶里程（沿路线）
    ///   - minDistanceToRouteM: 当前位置到路线折线的最近距离（用于判断"还没上主线"）
    ///   - laneGuides: 车道建议（由 LaneGuideBuilder 生成）
    static func make(turns: [RouteTurn],
                     traveledM: Int,
                     minDistanceToRouteM: Double,
                     laneGuides: [LaneGuide]) -> GuidanceEvent {
        // ── 起步阶段：还没进入主线 → 提示先往出口走 ──
        if traveledM < 30, minDistanceToRouteM > 25 {
            return GuidanceEvent(kind: .needExit, icon: "arrow.turn.up.right",
                                 text: "请先去往出口", subtitle: "", laneHint: "",
                                 laneIcons: [], recommendedLane: -1, distanceM: 0,
                                 action: "前往出口", roadName: "")
        }

        // ── 找不到前方转向点 → 直行到终点 ──
        guard let t = turns.first(where: { $0.fromStartM > traveledM }) else {
            return GuidanceEvent(kind: .straightToEnd, icon: "straight.up",
                                 text: "前方直行到达终点", subtitle: "", laneHint: "",
                                 laneIcons: [], recommendedLane: -1, distanceM: 0,
                                 action: "直行", roadName: "")
        }

        let d = t.fromStartM - traveledM
        guard d > 0 else {
            return GuidanceEvent(kind: .straightToEnd, icon: "straight.up",
                                 text: "前方直行到达终点", subtitle: "", laneHint: "",
                                 laneIcons: [], recommendedLane: -1, distanceM: 0,
                                 action: "直行", roadName: "")
        }

        let action = actionText(t)
        let icon = turnIcon(t)

        // ── 距离分级（建议 #9）──
        let distText = formatDistance(d)
        let head = distText.map { "前方\($0)" } ?? "前方"

        // ── 副文案：进入哪条路（建议 #8）──
        let road = t.roadName.trimmingCharacters(in: .whitespaces)
        let subtitle = road.isEmpty ? "" : "进入\(road)"

        // ── 车道建议（建议 #8）：走第 N 车道 ──
        var laneIcons: [String] = []
        var recommendedLane = -1
        var laneHint = ""
        if !laneGuides.isEmpty {
            laneIcons = laneGuides.map { $0.icon }
            recommendedLane = laneGuides.firstIndex(where: { $0.recommended }) ?? -1
            if recommendedLane >= 0 {
                laneHint = "走第 \(recommendedLane + 1) 车道"
            }
        }

        return GuidanceEvent(kind: .turn, icon: icon,
                             text: head + action, subtitle: subtitle, laneHint: laneHint,
                             laneIcons: laneIcons, recommendedLane: recommendedLane,
                             distanceM: d, action: action, roadName: road)
    }

    // MARK: 动作与图标

    /// 转向动作的中文描述
    ///
    /// v2.27：这是动作文案的**唯一权威实现**。
    /// AppModel.turnText 改为转调到这里（优化建议 #10：语音与顶部提示共用同一份数据源），
    /// 这样"动作文案"只有一处规则，不会出现两套规则漂移。
    /// （早期版本曾在 AppModel 和这里各写一份，结果"急左转"和"向左急转"两种说法并存。）
    static func actionText(_ t: RouteTurn) -> String {
        switch t.action {
        case "turn":
            switch t.modifier {
            case "left": return "左转"
            case "right": return "右转"
            case "slight left": return "稍向左转"
            case "slight right": return "稍向右转"
            case "sharp left": return "急左转"
            case "sharp right": return "急右转"
            default: return "转弯"
            }
        case "new name": return "继续直行，进入新路段"
        case "merge": return "并入主路"
        case "on ramp": return "驶入匝道"
        case "off ramp": return "驶出匝道"
        case "fork":
            return t.modifier.contains("left") ? "前方分岔，靠左"
                 : t.modifier.contains("right") ? "前方分岔，靠右" : "前方分岔，请减速选择车道"
        case "end of road":
            return t.modifier.contains("left") ? "前方道路尽头，左转" : "前方道路尽头，右转"
        case "continue": return "继续直行"
        case "roundabout": return "进入环岛，按指示方向行驶"
        case "uturn": return "前方掉头"
        case "arrive": return "即将到达目的地"
        default: return "前方注意路况"
        }
    }

    /// 转向图标
    ///
    /// v2.27：直接复用 AppModel.navTurnIcon 的规则（它对 "sharp left" 用
    /// arrow.turn.up.left，而早期 NavEvent 里写成了 arrow.up.left ——
    /// 急转弯显示成普通左转，图标不吓人）。
    /// 这里与 AppModel.navTurnIcon 保持一致，避免两套图标规则。
    static func turnIcon(_ t: RouteTurn) -> String {
        if !t.modifier.isEmpty {
            switch t.modifier {
            case "left": return "arrow.turn.up.left"
            case "right": return "arrow.turn.up.right"
            case "slight left": return "arrow.up.left"
            case "slight right": return "arrow.up.right"
            case "sharp left": return "arrow.turn.up.left"
            case "sharp right": return "arrow.turn.up.right"
            case "uturn": return "arrow.uturn.up.left"
            default: break
            }
        }
        let a = t.action
        if a.contains("掉头") { return "arrow.uturn.up.left" }
        if a.contains("左") { return "arrow.turn.up.left" }
        if a.contains("右") { return "arrow.turn.up.right" }
        return "arrow.up"
    }

    /// 语音播报文案（建议 #10：与顶部提示共用同一份事件）
    static func speech(for e: GuidanceEvent) -> String {
        switch e.kind {
        case .needExit:
            return "请先去往出口"
        case .straightToEnd:
            return "前方直行到达终点"
        case .turn:
            var s = ""
            if let d = formatDistance(e.distanceM) {
                s = "前方\(d)\(e.action)"
            } else {
                s = "前方\(e.action)"
            }
            if !e.roadName.isEmpty { s += "，进入\(e.roadName)" }
            // 车道建议只在近距离时念（远处念了也来不及变道）
            if !e.laneHint.isEmpty, e.distanceM <= 300 { s += "，\(e.laneHint)" }
            return s
        }
    }
}
