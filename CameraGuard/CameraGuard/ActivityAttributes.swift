import ActivityKit

/// v1.9 灵动岛 / Live Activity 共享属性类型。
/// 注意：Widget 扩展（WidgetExtension 模块）内有字段完全一致的同名类型，
/// ActivityKit 按类型名 + 字段结构在 App 与扩展之间匹配，两者必须保持一致。
struct CameraGuardActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// "cruising" 巡航（绿色） / "warning" 预警（红色）
        var phase: String
        var title: String
        var detail: String
        /// 距最近抓拍点距离（米），巡航态为 0
        var distanceM: Int
        /// v1.28 抓拍类型图标 key（PoiType.rawValue，"" = 无最近点不显示）
        var icon: String
    }
    var name: String = "电子眼卫士"
}
