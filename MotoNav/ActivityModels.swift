import ActivityKit

/// 违拍提醒 Live Activity 属性（主 App 侧定义，与 MotoNavWidget 内结构一致）
struct MotoNavAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var poiName: String
        var poiType: String
        var distanceM: Int
    }
    var destName: String
}
