import Foundation
import CoreLocation
import UIKit

/// 提醒点位类型（与安卓版一致）
enum PoiType: String, Codable, CaseIterable {
    case RED_LIGHT
    case RESTRICTION
    case LANE
    case SPEED

    var label: String {
        switch self {
        case .RED_LIGHT: return "闯红灯拍照"
        case .RESTRICTION: return "限行/禁摩"
        case .LANE: return "压线拍照"
        case .SPEED: return "超速拍照"
        }
    }

    var voicePrefix: String {
        switch self {
        case .RED_LIGHT: return "闯红灯拍照"
        case .RESTRICTION: return "限行禁摩路段"
        case .LANE: return "压线违章拍照"
        case .SPEED: return "超速拍照"
        }
    }

    var color: UIColor {
        switch self {
        case .RED_LIGHT: return .systemRed
        case .RESTRICTION: return .systemOrange
        case .LANE: return .systemCyan
        case .SPEED: return .systemOrange.withAlphaComponent(0.85)
        }
    }
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
