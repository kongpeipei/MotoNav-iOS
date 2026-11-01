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
