import ActivityKit

/// 机车地图 Live Activity 属性（App 侧定义，与 MotoNavWidget 内结构完全一致，
/// ActivityKit 按类型名 + 字段结构在 App 与扩展之间匹配）
struct MotoNavAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// "cruising" 巡航（绿色） / "warning" 预警（红色）
        var phase: String
        var title: String
        var detail: String
        /// 距最近点位距离（米），巡航态实时更新
        var distanceM: Int
        /// 点位类型图标 key（PoiType.rawValue，"" = 不显示）
        var icon: String

        public init(phase: String, title: String, detail: String, distanceM: Int, icon: String) {
            self.phase = phase
            self.title = title
            self.detail = detail
            self.distanceM = distanceM
            self.icon = icon
        }
    }
    var destName: String

    public init(destName: String) {
        self.destName = destName
    }
}
