import Foundation
import CoreLocation
import UIKit

/// 提醒点位类型（与安卓版一致）
enum PoiType: String, Codable, CaseIterable {
    case RED_LIGHT
    case RESTRICTION
    case LANE
    case SPEED
    /// 自定义标记（长按地图「标记该点」添加，备注自定义名称）
    case CUSTOM

    var label: String {
        switch self {
        case .RED_LIGHT: return "闯红灯拍照"
        case .RESTRICTION: return "限行/禁摩"
        case .LANE: return "压线拍照"
        case .SPEED: return "超速拍照"
        case .CUSTOM: return "自定义标记"
        }
    }

    var voicePrefix: String {
        switch self {
        case .RED_LIGHT: return "闯红灯拍照"
        case .RESTRICTION: return "限行禁摩路段"
        case .LANE: return "压线违章拍照"
        case .SPEED: return "超速拍照"
        case .CUSTOM: return "自定义标记"
        }
    }

    var color: UIColor {
        switch self {
        case .RED_LIGHT: return .systemRed
        case .RESTRICTION: return .systemOrange
        case .LANE: return .systemCyan
        case .SPEED: return .systemOrange.withAlphaComponent(0.85)
        case .CUSTOM: return .systemPurple
        }
    }

    /// v1.90 电子眼预警图标（SF Symbol，按类型细分：红绿灯/测速/压线/限行/自定义）
    var alertIcon: String {
        switch self {
        case .RED_LIGHT: return "stopwatch"
        case .SPEED: return "speedometer"
        case .LANE: return "road.lanes"
        case .RESTRICTION: return "nosign"
        case .CUSTOM: return "mappin"
        }
    }

    /// 是否为电警拍照类型（自定义标记不是电警，不出现在「添加违法拍照」类型选择里）
    var isCamera: Bool { self != .CUSTOM }
}

/// 单个提醒点位
struct Poi: Codable, Identifiable, Equatable {
    var id: Int64
    var type: PoiType
    var name: String
    var lat: Double
    var lon: Double
    var radiusM: Double
    var enabled: Bool
    var note: String
    /// 是否为用户自定义/移动过的点位（true=橙色描边、可删除；false=内置原始库点位，不可删除）
    var isCustom: Bool = false

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

/// 地图小区/商铺名称标签（带坐标，点击可导航）
struct PlaceLabel: Identifiable, Hashable {
    let name: String
    let lat: Double
    let lon: Double
    var id: String { name }
}

/// 让 CLLocationCoordinate2D 满足 Equatable（驱动 onChange 观察预览点变化）
extension CLLocationCoordinate2D: Equatable {
    public static func == (l: CLLocationCoordinate2D, r: CLLocationCoordinate2D) -> Bool {
        l.latitude == r.latitude && l.longitude == r.longitude
    }
}

/// 轻点地图后的地点介绍卡数据（高德逆地理编码结果）
/// name/address/poiType 三个字段在解析完成前用本地标签兜底，loading 期间卡片显示骨架
struct TapPlaceInfo: Identifiable, Equatable {
    let lat: Double
    let lon: Double
    var name: String
    var address: String = ""
    /// 高德 POI 类型，已取末级（如「商务住宅;住宅区;住宅小区」→「住宅小区」）
    var poiType: String = ""
    var road: String = ""
    var loading: Bool = false

    var id: String { "\(lat),\(lon)" }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// 类型 → SF Symbol（卡片左上角图标）
    var icon: String {
        let t = poiType + " " + name
        func has(_ keys: [String]) -> Bool { keys.contains { t.contains($0) } }
        if has(["餐饮", "美食", "餐厅", "小吃", "咖啡", "茶", "快餐", "面馆", "火锅"]) { return "fork.knife" }
        if has(["购物", "商场", "超市", "便利店", "市场", "数码", "烟酒"]) { return "cart.fill" }
        if has(["学校", "教育", "大学", "中学", "小学", "幼儿园", "培训"]) { return "graduationcap.fill" }
        if has(["医院", "医疗", "诊所", "药房", "药店", "卫生"]) { return "cross.case.fill" }
        if has(["住宿", "酒店", "宾馆", "旅馆", "民宿"]) { return "bed.double.fill" }
        if has(["交通", "地铁", "公交", "车站", "停车场", "加油站", "充电"]) { return "car.fill" }
        if has(["银行", "金融", "ATM", "信用社"]) { return "banknote.fill" }
        if has(["公园", "景点", "风景", "绿地", "广场", "寺", "塔"]) { return "leaf.fill" }
        if has(["公司", "写字楼", "产业园", "工厂", "企业", "大厦"]) { return "building.2.fill" }
        if has(["住宅", "小区", "公寓", "花园", "村", "苑"]) { return "house.fill" }
        if has(["道路", "路", "街", "巷", "桥", "隧道"]) { return "road.lanes" }
        return "mappin.circle.fill"
    }
}
