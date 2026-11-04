import Foundation
import CoreLocation

/// 违法拍照点位类型（与 MotoNav 数据兼容）
enum PoiType: String, Codable, CaseIterable, Identifiable {
    case RED_LIGHT   // 红绿灯/闯红灯拍照
    case SPEED       // 超速拍照
    case LANE        // 压线拍照
    case HELMET      // 不戴头盔拍照
    case RESTRICTION // 限行/禁摩
    case CUSTOM      // 自定义

    var id: String { rawValue }

    var label: String {
        switch self {
        case .RED_LIGHT: return "闯红灯拍照"
        case .SPEED: return "超速拍照"
        case .LANE: return "压线拍照"
        case .HELMET: return "不戴头盔拍照"
        case .RESTRICTION: return "限行/禁摩"
        case .CUSTOM: return "自定义"
        }
    }

    /// 语音播报文案：接近时直接播报
    var voiceText: String {
        switch self {
        case .RED_LIGHT: return "前方路口有闯红灯拍照"
        case .SPEED: return "前方有超速拍照"
        case .LANE: return "前方有压线拍照"
        case .HELMET: return "前方有不戴头盔拍照"
        case .RESTRICTION: return "前方有限行禁摩路段"
        case .CUSTOM: return "前方有自定义提醒点位"
        }
    }

    /// 预警图标（SF Symbol）
    var icon: String {
        switch self {
        case .RED_LIGHT: return "stopwatch"
        case .SPEED: return "speedometer"
        case .LANE: return "road.lanes"
        case .HELMET: return "scooter"
        case .RESTRICTION: return "nosign"
        case .CUSTOM: return "mappin"
        }
    }
}

/// 单个违法拍照点位（兼容仓库 poi.json：lat/lon、Int id、radiusM、enabled）
struct Poi: Identifiable, Equatable, Decodable {
    var id: String { "\(type.rawValue)-\(latitude)-\(longitude)" }
    var name: String
    var type: PoiType
    var latitude: Double
    var longitude: Double
    var radiusM: Double
    var enabled: Bool

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    enum CodingKeys: String, CodingKey {
        case name, type, enabled
        case latitude = "lat"
        case longitude = "lon"
        case radiusM
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(PoiType.self, forKey: .type)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        radiusM = try c.decodeIfPresent(Double.self, forKey: .radiusM) ?? 500
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

/// 播报记录（界面列表展示）
struct Announcement: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let type: PoiType
    let name: String
    let distance: Int
    let text: String
}
