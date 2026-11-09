import Foundation
import Combine
import CoreLocation
import MapKit
import AVFoundation
import UserNotifications
import UIKit
import ActivityKit
import CryptoKit
import AudioToolbox

extension Notification.Name {
    static let motoAlert = Notification.Name("motoAlert")
    /// 点位列表变化（供 CarPlay 同步）
}

/// v2.13 指南针独立状态。
///
/// 为什么单独拎出来：磁力计回调 10~20Hz，如果朝向往 AppModel 的 `@Published heading` 里写，
/// 每一次都会让 `ContentView.body` 整体重新求值 —— 而 body 是 4000 行的单一函数
/// （v2.11 为绕开栈溢出还套了大量 AnyView，AnyView 会让内部子树在求值时**立刻**构建）。
/// 20 次/秒 × 整棵树，主线程直接被打满：启动后画面停在闪屏、连 1 秒后的关闭任务都排不上。
/// 拆成独立 ObservableObject 后，朝向变化只让那个 56pt 的小圆圈重算。
final class CompassState: ObservableObject {
    @Published var angle: Double = 0
}


/// v2.22 内部道路连接段（定位点 ↔ 道路出入口）
struct RouteLink {
    let from: CLLocationCoordinate2D
    let to: CLLocationCoordinate2D
}

/// v2.19 路线途经点（名称 + WGS-84 坐标）
struct RouteWaypoint: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let lat: Double
    let lon: Double
}


/// CLLocationCoordinate2D Codable（轨迹历史持久化）

@MainActor
final class AppModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = AppModel()

    @Published var currentLocation: CLLocationCoordinate2D?
    /// v2.34 上次应用定位采样档位时的前后台状态（变化时刷新 distanceFilter）
    private var lastLocationFilterAppState: UIApplication.State = .active
    /// 定位精度（米），越小信号越好
    @Published var locationAccuracy: CLLocationAccuracy = 0
    @Published var monitoring = false
    @Published var simulating = false
    @Published var status = "等待定位…"
    @Published var route: [CLLocationCoordinate2D] = []
    /// 多路线方案（点"去这里"后展示，选择后应用）
    @Published var routeChoices: [RouteChoice] = []
    @Published var navigating = false {
        // v1.92：开始/结束导航时同步定位频率——导航中强制取消 50 米降频，保证提醒时效
        didSet { if oldValue != navigating { updateLocationFilter() } }
    }
    @Published var searchHistory: [String] = []
    /// 定位按钮点击计数（驱动地图回中）
    @Published var locateTick = 0
    /// 路线全览请求计数（规划完成后 +1，驱动地图缩放全览）
    /// 导航中路线全览请求计数（导航退出卡"全览"点击 +1，触发地图缩放显示全程路线；v1.81.4）
    @Published var overviewTick = 0
    @Published var fitTick = 0    /// 地图缩放按钮计数（+1 放大 / 缩小，MapView 响应）
    @Published var zoomInTick = 0
    @Published var zoomOutTick = 0
    /// v2.01 地图俯仰角（0=2D 平视 / 45=3D 俯视）；导航开始自动 45，右上"3D"按钮切换
    @Published var pitchDeg: Double = 0
    /// v2.01 路线上的信号灯路口（红绿灯倒计时用）
    @Published var trafficLights: [TrafficLight] = []
    /// v2.02 比例尺文本（放在 ObservableObject 里而不是 View 的 @State：
    /// 地图回调改 @State 会在 SwiftUI 更新周期内触发"下一轮更新"，形成循环，是启动卡顿/闪退的根因之一）
    @Published var scaleText = "200 米"
    /// 导航跟随触发（导航开始/结束/到达时递增，地图进入跟随模式）
    @Published var navigateFollowTick = 0
    /// v1.84 巡航模式（非导航下累计位移 ≥300m 自动进入；定位点跟随 + 顶部巡航卡片）
    @Published var cruiseMode = false
    /// v2.88 巡航统计：开始时间 + 总路程
    @Published var cruiseStartTime: Date? = nil
    @Published var cruiseTotalDistance: Double = 0
    /// v2.87 用户自定义3D俯角（度），0=2D，45=默认3D
    @Published var userPitchDeg: Double = 45 {
        didSet {
            UserDefaults.standard.set(userPitchDeg, forKey: "userPitchDeg")
        }
    }
    /// v2.86 首页无操作时间（10秒无操作自动进入巡航模式）
    @Published var lastUserActionTime = Date()
    @Published var cruiseTick = 0
    private var cruiseBase: CLLocationCoordinate2D?
    /// v1.90 省电模式（电量≤20% 或系统低电量模式自动开启：降定位频率）
    @Published var powerSaving = false
    /// v1.92 电量复查节流时间戳（秒）
    private var lastPowerCheck: TimeInterval = 0
    /// 省电模式总开关（默认开；"我的"页可关）
    var powerSaveEnabled: Bool { UserDefaults.standard.object(forKey: "powerSaveEnabled") as? Bool ?? true }
    /// 当前选中的路线方案下标（高德式：默认选中推荐，卡片点击切换）
    @Published var selectedRouteIdx = 0
    /// v2.34 体验审查 E8：限速提醒阈值（km/h，0=关闭，默认 60），设置页可改。
    /// 超过阈值时导航底卡速度数字变红（无路网限速数据源，用统一阈值兜底）
    var speedLimitKph: Int {
        get { UserDefaults.standard.object(forKey: "speedLimitKph") as? Int ?? 60 }
        set { UserDefaults.standard.set(newValue, forKey: "speedLimitKph") }
    }
    /// 手机朝向（度，0=北，顺时针）
    ///
    /// v2.13：只在导航中更新。导航时地图要跟着手机转向，这时发布一次是值得的；
    /// 平时全部走 `compass`，避免 10~20Hz 的朝向回调把整个界面重算打满主线程。
    @Published var heading: Double = 0
    /// v2.90 GPS 行进方向（度）：>10 km/h 时用来驱动地图朝向，
    /// 不受手机在支架上装歪的影响；停车时置 nil，回落到罗盘
    private var gpsHeading: Double? = nil
    /// 指南针朝向（独立发布，只驱动指南针小圆圈）
    let compass = CompassState()
    /// 自定义背景图片（相册选择，v1.11 已移除入口，保留字段兼容旧数据）
    @Published var bgImage: UIImage?
    /// 天气文本（小图标 + 温度，显示在 ⋯ 左侧）
    @Published var weatherText: String?
    /// 天气代码（WMO，v1.81.4 全屏天气动画用：雨/雪）
    @Published var weatherCode: Int?
    /// 明日天气（最高/最低）
    @Published var tomorrowText: String?
    /// 搜索预览点（绿色高亮，等待"去这里"）
    @Published var searchPreview: CLLocationCoordinate2D?
    @Published var searchPreviewName = ""
    /// v2.86 搜索结果标注（地图上显示所有搜索结果）
    @Published var searchResultAnnotations: [SearchResultAnnotation] = []
    /// 市区加油站坐标
    @Published var gasStations: [CLLocationCoordinate2D] = []
    /// 加油站全览请求计数
    @Published var gasTick = 0
    /// 地图小区/商铺名称标签（带坐标）
    @Published var placeLabels: [PlaceLabel] = []

    /// 合肥小区/商铺联想库（内置 + 在线刷新）

    /// 高德开放平台 Web 服务 Key（可选；填写后搜索联想走高德「输入提示」接口，最接近高德搜索体验）
    /// 高德开放平台 Web 服务 Key（v1.92：内置 Key 改由构建期注入，源码不再含明文）
    /// 未注入时为空串 → 在线联想/路线规划自动跳过，其余功能不受影响
    static var builtinAmapKey: String { AppSecrets.value(AppSecrets.amapKey) }
    @Published var amapKey: String = AppSecrets.value(AppSecrets.amapKey) {
        didSet { UserDefaults.standard.set(amapKey, forKey: "amapKey") }
    }

    /// 高德「输入提示」联想候选（名称 + 副标题 + 精确坐标）
    struct AmapTip: Identifiable {
        let name: String
        let sub: String
        let lat: Double
        let lon: Double
        var distance: Double?
        var id: String { "\(name)#\(lat)#\(lon)" }
    }

    private let lm = CLLocationManager()
    private let speech = AVSpeechSynthesizer()
    /// v1.61 恢复：讯飞在线语音合成（真四川话女声，失败自动降级系统语音）
    private var xfPlayer: AVAudioPlayer?
    private var xfSeq = 0
    /// 讯飞诊断（试听/播报失败时显示具体原因，设置页 footer）
    @Published var xfDiag = ""
    private var xfTask: URLSessionWebSocketTask?
    /// 语音播报总开关
    @Published var voiceMuted: Bool = UserDefaults.standard.object(forKey: "voiceMuted") as? Bool ?? false
    /// v2.34 体验审查 E7：最近一次播报时间（供导航底卡"播报中"喇叭指示，2.5s 内高亮）
    @Published private(set) var lastSpeakAt = Date.distantPast
    /// v2.36 F2 灵动岛更新节流：Live Activity 更新是 XPC 开销，5 秒一次足够锁屏读数
    private var lastActivityUpdate = Date(timeIntervalSince1970: 0)
    /// v2.36 F5 超速播报节流（30 秒内不重复；回到限速内后重置）
    private var lastOverspeedSpeak = Date(timeIntervalSince1970: 0)
    /// v2.38 H1 实际行驶距离累计（m，导航中每次发布移动 >5m 累加）：
    /// 行程卡/足迹显示真实里程，而非高德规划距离（偏航绕路时规划值偏小）
    private var actualTripM = 0.0
    private var lastSpeakPriority = 0
    private var lastSpeakText = ""
    /// 导航巡航 Live Activity（灵动岛/锁屏：头盔 + 已出发/去往目的地，导航中生效）
    private var liveActivity: Activity<MotoNavAttributes>?
    private var simTimer: Timer?
    private var simStep = 0
    /// 偏离路线检测
    private var offRouteCount = 0
    private var lastReroute = Date(timeIntervalSince1970: 0)
    /// 导航开始时间（行程总结用）
    private var navStart: Date?
    /// 即将到达播报去重
    private var arriveAnnounced = false
    /// 收藏点位（key: "lat,lon"）
    @Published var favorites: [String: String] = [:]
    /// v1.82 收藏时间戳（key: "lat,lon" → 收藏时刻，用于"我的-收藏"按最新在前排序）
    @Published var favoriteTimes: [String: Double] = [:]
    /// 常用地点（家/公司）
    struct SavedPlace: Codable { var name: String; var lat: Double; var lon: Double }
    /// v1.69 搜索面板快捷卡片（家/公司之外的"+"自定义点位）
    struct QuickPoi: Codable, Identifiable, Hashable {
        var name: String
        var lat: Double
        var lon: Double
        var id: String { "\(name)|\(lat)|\(lon)" }
    }
    @Published var homePlace: SavedPlace?
    @Published var workPlace: SavedPlace?
    /// v1.69 自定义快捷卡片（"+"在地图选点生成，长按删除）
    @Published var quickPois: [QuickPoi] = []
    /// 行程总结（到达或退出导航时生成）
    struct TripSummary {
        let destName: String
        let distanceM: Int
        let durationS: Int
        let avgSpeedKmh: Double
        /// v2.54 行程卡补起止时间（原来只有里程/用时/速度，回看时不知道是哪一段）
        let startAt: Date
    }
    @Published var tripSummary: TripSummary?
    /// v2.54 导航进度（0~1）：右侧竖直路程进度条用。
    /// 由 updateNavProgress 在定位回调里更新，不在 body 求值期算（避免整树重算循环）。
    @Published var navProgress: Double = 0

    /// 导航状态
    private var destLat = 0.0
    private var destLon = 0.0
    var destName = ""
    @Published var routeTurns: [RouteTurn] = []
    private var lastTurnSpoken = -1
    /// v2.87 路口自动缩放：是否已经拉近了
    private var junctionZoomedIn = false
    private var junctionZoomedInTurn = -1
    /// v2.87 导航中自动显示前方加油站
    private var lastGasSearchTime = Date.distantPast
    /// 已做过"前方xx米右转"远提示的转向序号（避免重复播报）
    private var farAnnounced: Set<Int> = []
    // v2.93 转向播报执行档：50米执行提醒已报过的索引
    private var closeAnnounced: Set<Int> = []
    /// v2.43 M1 已播报过"已通过路口"确认的转向序号（每个转向只确认一次）
    private var turnConfirmSet: Set<Int> = []
    /// v2.43 M2 已播报过前方拥堵提示（过段后复位，允许下次再报）
    private var trafficAheadSpoken = false
    /// 所选路线全程距离/用时（导航信息卡：剩余里程与时间按比例估算）
    @Published var routeDistanceM = 0
    @Published var routeDurationS = 0

    // MARK: - v1.99 骑士增强：播报分级 / 限行风险 / 路况 / 途经点 / 足迹
    /// 播报详细程度（0 简洁 / 1 标准 / 2 详细）
    @Published var speechLevel: Int = UserDefaults.standard.object(forKey: "speechLevel") as? Int ?? 1 {
        didSet { UserDefaults.standard.set(speechLevel, forKey: "speechLevel") }
    }
    /// v2.00 命名避开 AVSpeechSynthesizer 实例（speech），否则同名冲突
    var speechMode: SpeechLevel { SpeechLevel(rawValue: speechLevel) ?? .standard }
    /// 规划时优先避开高速/高架（摩托友好）
    // v2.28 出行方式（高德样式规划卡的第一排选择器）
    /// 摩托车是本 App 的核心场景：会规避禁摩路段、播报红绿灯
    enum TravelMode: String, CaseIterable, Identifiable {
        case moto, car
        var id: String { rawValue }
        var title: String {
            switch self {
            case .moto: return "摩托车"
            case .car: return "汽车"
            }
        }
        var icon: String {
            switch self {
            case .moto: return "motorcycle"
            case .car: return "car"
            }
        }
    }

    /// 当前出行方式
    @Published var travelMode: TravelMode = .moto

    /// v2.29 各方案的禁摩风险等级（按方案下标索引）
    ///
    /// 调研发现：高德/百度的方案卡只显示「距离 / 用时 / 红绿灯数」，
    /// **没有禁摩风险这一维度** —— 但对摩托车这是最关键的信息
    /// （合肥这类城市禁摩高架/主干道很常见）。
    ///
    /// 缓存起来：riderRisks 是按当前选中方案算的，
    /// 而方案卡要逐个显示各方案的风险等级，不能直接复用。
    /// 这里按方案下标缓存，方案列表变化时清空。
    private var choiceRiskCache: [Int: ChoiceRisk] = [:]
    private var choiceRiskCacheKey: String = ""

    /// v2.29 方案卡上的禁摩风险徽标
    enum ChoiceRisk {
        case none       // 无风险
        case low        // 轻微（隧道/大桥）
        case high       // 明确禁摩/高速/高架

        var label: String {
            switch self {
            case .none: return "可通行"
            case .low: return "有隧道/大桥"
            case .high: return "含禁摩路段"
            }
        }
        var shortLabel: String {
            switch self {
            case .none: return "可通行"
            case .low: return "注意"
            case .high: return "禁摩"
            }
        }
        var isBlocked: Bool { self == .high }
    }

    /// v2.29 取某方案的禁摩风险等级
    func choiceRisk(_ c: RouteChoice, index: Int) -> ChoiceRisk {
        // 缓存键：方案列表的指纹（数量 + 每条的里程/用时）
        let key = routeChoices.map { "\($0.distanceM)-\($0.durationS)" }.joined(separator: "|")
        if key != choiceRiskCacheKey {
            choiceRiskCacheKey = key
            choiceRiskCache.removeAll()
        }
        if let cached = choiceRiskCache[index] { return cached }
        let risks = RiderAnalyzer.risks(c.turns, totalM: c.distanceM)
        let blocked = risks.contains { $0.kind.motoBlocked }
        let risky = !risks.isEmpty
        let r: ChoiceRisk = blocked ? .high : (risky ? .low : .none)
        choiceRiskCache[index] = r
        return r
    }

    /// v2.29 起点是否被手动固定（不等于当前位置）
    ///
    /// 调研发现：Google 明确要求"起点必须是当前位置，否则只给路线预览"，
    /// 而高德/百度允许手动起点但**不告诉用户导航实际从哪开始**——
    /// 用户看到"出发点：XX"，实际导航却是从几公里外的那个点开始的，
    /// 到了那儿才提示"请先去往出口"（本 App 也一样，见 navTopHintBar 的 needExit）。
    ///
    /// 这里显式暴露这个状态，让用户能一键纠正。
    var originIsManual: Bool { originLat != 0 || originLon != 0 }

    /// v2.29 手动起点与当前位置的距离（米）；未固定时返回 nil
    ///
    /// 带缓存：这个值会在 body 求值期被读（规划卡的提示条），
    /// 而 distanceM 会构造两个 CLLocation —— 每帧算一次是纯浪费。
    /// 位置变化超过 50 米才重算。
    private var originDistCache: Int?
    private var originDistCacheAt: CLLocationCoordinate2D?

    func originDistanceFromUser() -> Int? {
        guard originIsManual, let cur = currentLocation else { return nil }
        // 位置没怎么动就直接用缓存
        if let cached = originDistCache, let at = originDistCacheAt {
            if distanceM(at, cur) < 50 { return cached }
        }
        let d = Int(distanceM(cur, CLLocationCoordinate2D(latitude: originLat, longitude: originLon)))
        originDistCache = d
        originDistCacheAt = cur
        return d
    }

    /// v2.29 起点改回当前位置（起点不再固定）
    func resetOriginToCurrentLocation() {
        originName = "我的位置"
        originLat = 0
        originLon = 0
        status = "起点已改回我的位置，正在重新规划…"
        replan()
    }

    /// v2.29 骑行极简模式（竞品空白点）
    ///
    /// 调研发现：高德/百度只有"播报分级"，**所有竞品都没有骑行视觉精简模式** ——
    /// 屏幕信息密度还是按驾车设计的。但摩托车骑手戴着头盔，
    /// 视野只有一条缝，余光能读到的信息非常有限。
    ///
    /// 极简模式下：
    /// · 底卡只留「下一动作 + 距离 + 车速 + ETA」，隐藏车道图与红绿灯读秒
    /// · 字号放大（动作 14pt → 18pt），距离与车速同步放大
    /// · 隐藏地图上的缩放按钮组与比例尺（减少视觉噪声）
    ///
    /// 与 speechMode（播报分级）正交：语音照旧，屏幕更干净。
    @Published var ridingMinimalUI: Bool = UserDefaults.standard.object(forKey: "ridingMinimalUI") as? Bool ?? false {
        didSet { UserDefaults.standard.set(ridingMinimalUI, forKey: "ridingMinimalUI") }
    }

    /// v2.28 优先少红绿灯（排序偏好，作用于方案列表）
    @Published var preferFewLights: Bool = UserDefaults.standard.object(forKey: "preferFewLights") as? Bool ?? false {
        didSet { UserDefaults.standard.set(preferFewLights, forKey: "preferFewLights") }
    }
    /// v2.28 优先距离最短（排序偏好，作用于方案列表）
    @Published var preferShortest: Bool = UserDefaults.standard.object(forKey: "preferShortest") as? Bool ?? false {
        didSet { UserDefaults.standard.set(preferShortest, forKey: "preferShortest") }
    }

    @Published var avoidHighway: Bool = UserDefaults.standard.object(forKey: "avoidHighway") as? Bool ?? false {
        didSet { UserDefaults.standard.set(avoidHighway, forKey: "avoidHighway") }
    }
    /// 当前路线的骑行风险段（高速/高架/隧道/大桥/禁摩）
    @Published var riderRisks: [RoadRisk] = []
    /// 当前路线的拥堵分段（红黄）
    @Published var trafficSpans: [TrafficSpan] = []
    /// v2.19 途经点（可多个，路线依次穿过 起点→途经1→途经2→…→终点）
    @Published var waypoints: [RouteWaypoint] = []
    /// v2.21 地图聚焦到指定坐标（途经点定位用）
    @Published var focusCoord: CLLocationCoordinate2D?
    @Published var focusTick = 0
    /// v2.22 导航中用户手动拖动了地图（提示卡切换为"继续导航"）
    @Published var navUserMoved = false
    /// v2.22 导航视野档位目标（比例尺 1 厘米对应的米数：50 / 500）
    @Published var navScaleTarget = 50
    /// v2.81 转弯缩放的滞回状态：0 = 远离路口，1 = 中档（<250 m），2 = 近档（<100 m）
    private var navNearZone = 0
    /// v2.81 供界面用：当前是否处于"临近转弯"区间。
    /// 顶部条的变绿强调和缩放档位必须用同一个判断，否则会出现
    /// "条已经绿了、视野还没拉近"这种前后不一致。
    var navNearTurning: Bool { navigating && navNearZone == 2 }
    @Published var navScaleTick = 0
    /// v2.22 已行驶折线点索引（用于"走过的路变灰"）
    @Published var traveledIdx = 0
    /// v2.22 顶部路线提示（高德式："请先去往出口" / "前方xx米路口直行"）
    @Published var navTopHint = ""
    @Published var navTopHintIcon = "straight.up"
    /// v2.23 途经点候选（点 ➕ 搜索后选中的点，尚未确认加入）
    @Published var waypointCandidate: RouteWaypoint?
    /// v2.23 加入候选前的时长（秒）——用于对比"添加前 vs 添加后"
    @Published var durationBeforeVia: Int = 0
    /// v2.23 加入候选后的时长（秒）
    @Published var durationAfterVia: Int = 0
    /// v2.23 正在计算途经点时长对比
    @Published var viaCompareLoading = false
    /// v2.19 起点（默认跟随当前定位；点交换按钮后固定为原终点）
    @Published var originName = "我的位置"
    @Published var originLat = 0.0
    @Published var originLon = 0.0   // 0 = 跟随当前定位
    /// 足迹回放轨迹（我的-足迹 → 点一条记录）
    @Published var footprintPreview: [CLLocationCoordinate2D] = []
    /// 沿途服务设施搜索结果（"顺路加一站"）
    @Published var serviceTips: [AmapTip] = []
    @Published var serviceKindLoading = false
    @Published var serviceKindActive: ServiceKind?
    /// 导航轨迹缓冲（结束后存为足迹）
    private var trackPoints: [CLLocationCoordinate2D] = []
    private var maxSpeedKph: Double = 0
    private var lastCurveSpoken = Date.distantPast

    /// 实时速度（m/s，来自定位，导航卡显示 km/h）
    @Published var currentSpeed = 0.0

    private let historyKey = "search_history"
    private let historyLimit = 10

    // MARK: - 本地高频地标词典（离线可用：殡仪馆/车站/机场/医院/高校/公园/商圈）
    struct SearchLandmark {
        let name: String
        let aliases: [String]
        let lat: Double
        let lon: Double
        func matches(_ q: String) -> Bool {
            let query = q.trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { return false }
            if name.localizedCaseInsensitiveContains(query) || query.localizedCaseInsensitiveContains(name) { return true }
            return aliases.contains { a in
                query.localizedCaseInsensitiveContains(a) || a.localizedCaseInsensitiveContains(query)
            }
        }
    }

    let searchLandmarks: [SearchLandmark] = [
        SearchLandmark(name: "合肥市殡仪馆", aliases: ["殡仪馆", "合肥殡仪馆"], lat: 31.86826, lon: 117.24841),
        SearchLandmark(name: "合肥南站", aliases: ["高铁南站", "合肥高铁南站"], lat: 31.797955, lon: 117.290331),
        SearchLandmark(name: "合肥站", aliases: ["合肥火车站", "火车站"], lat: 31.8831, lon: 117.3092),
        SearchLandmark(name: "合肥新桥国际机场", aliases: ["新桥机场", "合肥机场", "机场"], lat: 31.9863, lon: 116.9765),
        SearchLandmark(name: "合肥汽车客运总站", aliases: ["客运总站", "汽车客运总站"], lat: 31.8796, lon: 117.3103),
        SearchLandmark(name: "合肥汽车南站", aliases: ["汽车南站"], lat: 31.8010, lon: 117.2860),
        SearchLandmark(name: "合肥汽车西站", aliases: ["汽车西站"], lat: 31.8260, lon: 117.1820),
        SearchLandmark(name: "安徽省立医院", aliases: ["省立医院", "中科大附一院"], lat: 31.8582, lon: 117.2603),
        SearchLandmark(name: "安徽医科大学第一附属医院", aliases: ["安医大一附院", "安医附院"], lat: 31.8515, lon: 117.2558),
        SearchLandmark(name: "安徽医科大学第二附属医院", aliases: ["安医大二附院", "安医二附院"], lat: 31.8224, lon: 117.2120),
        SearchLandmark(name: "合肥市第一人民医院", aliases: ["市一院", "合肥市一院"], lat: 31.8731, lon: 117.2720),
        SearchLandmark(name: "合肥市第二人民医院", aliases: ["市二院", "合肥市二院"], lat: 31.8712, lon: 117.3255),
        SearchLandmark(name: "合肥市第三人民医院", aliases: ["市三院"], lat: 31.8558, lon: 117.2640),
        SearchLandmark(name: "合肥市第四人民医院", aliases: ["市四院", "合肥四院"], lat: 31.8552, lon: 117.2450),
        SearchLandmark(name: "合肥市口腔医院", aliases: ["口腔医院"], lat: 31.8668, lon: 117.2795),
        SearchLandmark(name: "安徽省妇幼保健院", aliases: ["妇幼保健院", "妇幼"], lat: 31.8625, lon: 117.2730),
        SearchLandmark(name: "安徽中医药大学第一附属医院", aliases: ["中医附院", "安徽省中医院"], lat: 31.8665, lon: 117.2700),
        SearchLandmark(name: "中国科学技术大学", aliases: ["中科大", "中国科大"], lat: 31.8430, lon: 117.2650),
        SearchLandmark(name: "合肥工业大学", aliases: ["合工大", "合肥工大"], lat: 31.8465, lon: 117.2925),
        SearchLandmark(name: "安徽大学", aliases: ["安大", "安徽大学龙河校区"], lat: 31.8405, lon: 117.2770),
        SearchLandmark(name: "安徽农业大学", aliases: ["安农大"], lat: 31.8700, lon: 117.2560),
        SearchLandmark(name: "包公园", aliases: ["包公祠"], lat: 31.8578, lon: 117.2930),
        SearchLandmark(name: "逍遥津公园", aliases: ["逍遥津"], lat: 31.8722, lon: 117.2828),
        SearchLandmark(name: "合肥植物园", aliases: ["植物园"], lat: 31.8382, lon: 117.1930),
        SearchLandmark(name: "大蜀山", aliases: ["大蜀山森林公园"], lat: 31.8345, lon: 117.1880),
        SearchLandmark(name: "天鹅湖公园", aliases: ["天鹅湖"], lat: 31.8085, lon: 117.2230),
        SearchLandmark(name: "罍街", aliases: ["罍街夜市"], lat: 31.8395, lon: 117.2820),
        SearchLandmark(name: "之心城", aliases: ["三里庵之心城"], lat: 31.8580, lon: 117.2508),
        SearchLandmark(name: "合肥万象城", aliases: ["万象城"], lat: 31.8068, lon: 117.2400),
        SearchLandmark(name: "淮河路步行街", aliases: ["步行街", "淮河路"], lat: 31.8725, lon: 117.2780),
        SearchLandmark(name: "合肥城隍庙", aliases: ["城隍庙"], lat: 31.8685, lon: 117.2685),
        SearchLandmark(name: "合肥野生动物园", aliases: ["野生动物园", "合肥动物园"], lat: 31.8268, lon: 117.1758),
        SearchLandmark(name: "合肥海洋世界", aliases: ["海洋世界"], lat: 31.8030, lon: 117.2200),
        SearchLandmark(name: "合肥融创乐园", aliases: ["融创乐园", "万达乐园"], lat: 31.7915, lon: 117.2370),
        SearchLandmark(name: "安徽博物院", aliases: ["省博物馆", "安徽省博物馆"], lat: 31.8150, lon: 117.2215),
        SearchLandmark(name: "合肥体育中心", aliases: ["奥体中心"], lat: 31.8000, lon: 117.2260),
        SearchLandmark(name: "合肥滨湖国际会展中心", aliases: ["会展中心", "滨湖会展"], lat: 31.7610, lon: 117.2770),
        SearchLandmark(name: "渡江战役纪念馆", aliases: ["渡江纪念馆"], lat: 31.7625, lon: 117.2990),
        SearchLandmark(name: "骆岗公园", aliases: ["合肥园博园", "骆岗中央公园"], lat: 31.7770, lon: 117.2790),
        SearchLandmark(name: "三河古镇", aliases: ["三河"], lat: 31.5350, lon: 117.2460),
        SearchLandmark(name: "巢湖中庙", aliases: ["中庙", "巢湖中庙景区"], lat: 31.5650, lon: 117.8580),
        SearchLandmark(name: "合肥市政府", aliases: ["政务中心", "合肥政务中心"], lat: 31.8168, lon: 117.2270),
        SearchLandmark(name: "四牌楼", aliases: ["四牌楼商圈"], lat: 31.8680, lon: 117.2810),
        SearchLandmark(name: "肥东县", aliases: ["肥东"], lat: 31.8900, lon: 117.4710),
        SearchLandmark(name: "肥西县", aliases: ["肥西"], lat: 31.7060, lon: 117.1660),
        SearchLandmark(name: "长丰县", aliases: ["长丰"], lat: 31.6930, lon: 117.1670)
    ]

    func matchLandmark(_ q: String) -> SearchLandmark? {
        let query = q.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nil }
        return searchLandmarks.first { $0.matches(query) }
    }

    private override init() {
        super.init()
        userPitchDeg = UserDefaults.standard.double(forKey: "userPitchDeg")
        if userPitchDeg == 0 { userPitchDeg = 45 }
        // v1.61：内置高德 Key 兜底（用户设置过则用用户的；否则用内置，保证搜索联想/路线规划始终可用）
        if let saved = UserDefaults.standard.string(forKey: "amapKey"), !saved.isEmpty {
            amapKey = saved
        } else {
            amapKey = Self.builtinAmapKey
        }
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        loadHistory()
        loadFavorites()
        loadHomeWork()
        loadQuickPois()
        // v1.90 省电模式：监听电池电量和系统低电量模式，自动降定位频率
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyPowerSaving() }
        }
        NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyPowerSaving() }
        }
        applyPowerSaving()
        // v2.32 冷启动清理残留灵动岛：App 被上滑清除后系统仍会保留 Live Activity，
        // 下次打开时立即结束所有遗留活动（与 CameraGuard 同款兜底）。
        cleanupStaleLiveActivities()
        NotificationCenter.default.addObserver(
            self, selector: #selector(authorizeAndStart),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    /// v1.92 省电模式应用：电量≤20% 或系统低电量模式 → 非导航态下降低定位频率
    /// 修复：退出省电时原代码写死 kCLDistanceFilterNone（每次移动都回调），
    ///       反而比省电前更耗电；现在改为还原进入省电前记录的原始值。
    func applyPowerSaving() {
        let level = UIDevice.current.batteryLevel
        let lowBattery = level >= 0 && level <= 0.20 // batteryLevel=-1 表示未知（模拟器/未开启监控）
        let sysLow = ProcessInfo.processInfo.isLowPowerModeEnabled
        let on = powerSaveEnabled && (lowBattery || sysLow)
        guard on != powerSaving else { return }
        powerSaving = on
        updateLocationFilter()
        if on {
            status = "已开启省电模式：降低定位频率（电量恢复后自动关闭）"
        } else {
            status = "省电模式已关闭"
        }
    }

    /// 定位频率按「省电 + 是否导航」切换：
    /// - 省电且非导航 → 50 米过滤（省电）
    /// - 导航中一律不降频，否则转向/电子眼提醒会被推迟数十米，骑到跟前才报
    /// 定位频率：省电且非导航 → 50 米（几乎不动就不回调）；
    /// 导航中 2 米（转弯/到点提示及时）；其余 8 米。
    ///
    /// v2.12：旧实现把 `baseDistanceFilter = lm.distanceFilter` 写在"进入省电"分支里，
    /// 第二次进入省电时基准值已经被改成 50，退出省电就永远停在 50 米——反过来更耗电
    /// （导航时 50 米才回调一次，转弯提示会明显滞后）。现在直接按状态算，不留隐式基准。
    ///
    /// v2.27（优化建议 #22）：再叠加一层「运动状态」分级：
    ///   · 静止（速度 < 0.5 m/s 持续 2 分钟）→ 25 米过滤（省电，但比 50 米跟手）
    ///   · 骑行中（速度 > 3 m/s）→ 恢复 8 米
    ///   · 隧道/无定位 → 主动提示"定位可能不准"
    private func updateLocationFilter() {
        // 导航中一律高频（转向/电子眼提醒不能延迟）
        if navigating {
            lm.distanceFilter = 2
            return
        }
        // v2.34 后台降频省电：非导航切后台后采样降到 50m（导航仍保持 2m 高频，转向提醒不延迟）
        if UIApplication.shared.applicationState == .background {
            lm.distanceFilter = 50
            return
        }
        if powerSaving {
            lm.distanceFilter = 50
            return
        }
        // 非导航、非省电：按是否在移动分级
        lm.distanceFilter = isMoving ? 8 : 25
    }

    /// v2.27（优化建议 #22）运动状态判定
    ///
    /// 静止（速度 < 0.5 m/s）持续 2 分钟 → 降频省电；
    /// 速度 > 3 m/s（骑行）→ 恢复高频。
    /// 阈值取 0.5 / 3 m/s：0.5 m/s ≈ 1.8 km/h（走路速度以下算静止），
    /// 3 m/s ≈ 10.8 km/h（低于此速度的"移动"多半是推车等，不需要高精度）。
    @Published private(set) var isMoving = false
    private var stillSince: Date?
    /// v2.27 隧道/失定位提示（连续多久没有新定位算"进入隧道"）
    private var lastLocationAt = Date()
    private var tunnelHinted = false

    /// v2.27 根据速度更新运动状态与定位频率
    private func updateMotionState() {
        let speed = currentSpeed
        let now = Date()
        if speed > 3.0 {
            if !isMoving {
                isMoving = true
                stillSince = nil
                updateLocationFilter()
            }
        } else if speed < 0.5 {
            if isMoving {
                isMoving = false
                stillSince = now
                updateLocationFilter()
            } else if let s = stillSince {
                // 静止满 2 分钟 → 再降一档频率
                if now.timeIntervalSince(s) > 120 {
                    stillSince = now
                    lm.distanceFilter = 25
                }
            } else {
                stillSince = now
            }
        }
    }

    /// v2.27 隧道提示：连续 30 秒没有新定位 → 提示定位可能不准
    ///
    /// 检查时机放在 navigationStatus（导航中 UI 每次刷新都会调它），
    /// 而不是只放在定位回调里 —— 因为"失去定位"的特征恰恰是**不再有回调**，
    /// 只在回调里检查就永远触发不了。
    private func checkTunnelSignal() {
        let idle = Date().timeIntervalSince(lastLocationAt)
        if idle > 30, !tunnelHinted, navigating {
            tunnelHinted = true
            speak("已进入隧道或遮挡区域，定位可能暂时不准确")
            status = "定位信号丢失，注意安全"
        } else if idle < 10 {
            tunnelHinted = false
        }
    }

    /// v1.92 到达震动（骑行时头盔+风噪下「嗡」一声几乎无感，改为三段成功型触感，辨识度高）
    /// 用 UINotificationFeedbackGenerator：有触觉引擎的设备反馈更清晰，无引擎设备自动降级
    private func vibrationArrived() {
        // 每次新建一个生成器：避免实例在 asyncAfter 之前被释放导致后续两下没有反馈
        for i in 0...2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.18) {
                let gen = UINotificationFeedbackGenerator()
                gen.notificationOccurred(.success)
            }
        }
    }

    /// v1.92 后台补判电量：batteryStateDidChange 通知在 App 挂起时收不到，
    /// 而后台定位恰恰最耗电；改为在定位回调里低频（≥60 秒）复查一次电量/低电量模式
    private func throttledPowerSavingCheck() {
        let now = Date().timeIntervalSince1970
        if now - lastPowerCheck < 60 { return }
        lastPowerCheck = now
        applyPowerSaving()
    }

    // MARK: - 收藏 / 家 / 公司（v1.29）

    private let favKey = "fav_pois"
    private let favTimesKey = "fav_pois_times"
    private let homeKey = "home_place"
    private let workKey = "work_place"

    private func loadFavorites() {
        if let d = UserDefaults.standard.dictionary(forKey: favKey) as? [String: String] {
            favorites = d
        }
        if let t = UserDefaults.standard.dictionary(forKey: favTimesKey) as? [String: Double] {
            favoriteTimes = t
        }
    }

    private func loadHomeWork() {
        let ud = UserDefaults.standard
        if let d = ud.data(forKey: homeKey), let p = try? JSONDecoder().decode(SavedPlace.self, from: d) {
            homePlace = p
        }
        if let d = ud.data(forKey: workKey), let p = try? JSONDecoder().decode(SavedPlace.self, from: d) {
            workPlace = p
        }
    }

    /// v2.33 电警点位已整体移除（为电子眼融合做准备）；收藏按 name/lat/lon 判定
    func isFavorite(name: String, lat: Double, lon: Double) -> Bool {
        favorites["\(lat),\(lon)"] != nil
    }

    /// v2.33 切换收藏（name/lat/lon，与联想地点收藏共用收藏夹）
    func toggleFavorite(name: String, lat: Double, lon: Double) {
        let key = "\(lat),\(lon)"
        if favorites[key] != nil {
            favorites.removeValue(forKey: key)
            favoriteTimes.removeValue(forKey: key)
        } else {
            favorites[key] = name
            favoriteTimes[key] = Date().timeIntervalSince1970
        }
        UserDefaults.standard.set(favorites, forKey: favKey)
        UserDefaults.standard.set(favoriteTimes, forKey: favTimesKey)
    }

    /// v1.81 联想地点/信息卡收藏（与点位收藏共用同一收藏夹）
    func isTipFavorite(lat: Double, lon: Double) -> Bool {
        favorites["\(lat),\(lon)"] != nil
    }

    /// v1.81 切换联想地点收藏（星星实心/空心 + 我的页收藏夹增删）
    func toggleTipFavorite(name: String, lat: Double, lon: Double) {
        let key = "\(lat),\(lon)"
        if favorites[key] != nil {
            favorites.removeValue(forKey: key)
            favoriteTimes.removeValue(forKey: key)
        } else {
            favorites[key] = name
            favoriteTimes[key] = Date().timeIntervalSince1970
        }
        UserDefaults.standard.set(favorites, forKey: favKey)
        UserDefaults.standard.set(favoriteTimes, forKey: favTimesKey)
    }

    /// v1.97 "我的-常用地点"左滑删除收藏项（按坐标）
    func removeFavorite(lat: Double, lon: Double) {
        let key = "\(lat),\(lon)"
        favorites.removeValue(forKey: key)
        favoriteTimes.removeValue(forKey: key)
        UserDefaults.standard.set(favorites, forKey: favKey)
        UserDefaults.standard.set(favoriteTimes, forKey: favTimesKey)
    }

    /// v1.81 高德周边搜索（信息卡"搜周边"）：以该点为中心返回附近 POI
    /// v1.98 坐标口径统一：入参/返回都是 WGS-84（地图网格），高德接口前后各转一次
    func placeAround(lat: Double, lon: Double) async -> [AmapTip] {
        guard !amapKey.isEmpty else { return [] }
        let (glat, glon) = CoordConv.wgs2gcj(lat, lon)
        let loc = String(format: "%.6f,%.6f", glon, glat)
        guard let url = URL(string: "https://restapi.amap.com/v3/place/around?key=\(amapKey)&location=\(loc)&radius=5000&offset=15&page=1") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pois = obj["pois"] as? [[String: Any]] else { return [] }
            var out: [AmapTip] = []
            for p in pois {
                guard let name = p["name"] as? String, !name.isEmpty,
                      let loc2 = p["location"] as? String, !loc2.isEmpty else { continue }
                let parts = loc2.split(separator: ",").compactMap { Double($0) }
                guard parts.count == 2 else { continue }
                let (wlat, wlon) = CoordConv.gcj2wgs(parts[1], parts[0])
                let addr = p["address"] as? String ?? ""
                let dist = p["distance"] as? String ?? ""
                var sub = addr.isEmpty ? (p["type"] as? String ?? "地点") : addr
                if !dist.isEmpty { sub += " · 距此\(Int(Double(dist) ?? 0))米" }
                out.append(AmapTip(name: name, sub: sub, lat: wlat, lon: wlon, distance: Double(dist)))
            }
            return out
        } catch {
            return []
        }
    }

    /// v2.33 电警点位已移除：家/公司改 name/lat/lon 入参
    func setHome(name: String, lat: Double, lon: Double) {
        homePlace = SavedPlace(name: name, lat: lat, lon: lon)
        let ud = UserDefaults.standard
        if let d = try? JSONEncoder().encode(homePlace) { ud.set(d, forKey: homeKey) }
    }

    /// v2.33 电警点位已移除：家/公司改 name/lat/lon 入参
    func setWork(name: String, lat: Double, lon: Double) {
        workPlace = SavedPlace(name: name, lat: lat, lon: lon)
        let ud = UserDefaults.standard
        if let d = try? JSONEncoder().encode(workPlace) { ud.set(d, forKey: workKey) }
    }

    /// v1.65：用当前位置直接设置家/公司（我的页"未设置"时一键设置）
    func setHomeCoord(_ coord: CLLocationCoordinate2D, name: String = "家") {
        homePlace = SavedPlace(name: name, lat: coord.latitude, lon: coord.longitude)
        let ud = UserDefaults.standard
        if let d = try? JSONEncoder().encode(homePlace) { ud.set(d, forKey: homeKey) }
    }

    func setWorkCoord(_ coord: CLLocationCoordinate2D, name: String = "公司") {
        workPlace = SavedPlace(name: name, lat: coord.latitude, lon: coord.longitude)
        let ud = UserDefaults.standard
        if let d = try? JSONEncoder().encode(workPlace) { ud.set(d, forKey: workKey) }
    }

    // MARK: - v1.97 常用地点统一编辑（家 / 公司 / 自定义选项 / 新增）

    /// 读取某个常用地点选项当前保存的地点（未设置为 nil）
    func commonPlace(for slot: CommonPlaceSlot) -> SavedPlace? {
        switch slot {
        case .home:
            return homePlace
        case .work:
            return workPlace
        case .favorite(let key):
            guard let name = favorites[key] else { return nil }
            let parts = key.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { return nil }
            return SavedPlace(name: name, lat: parts[0], lon: parts[1])
        case .custom(let id):
            guard let q = quickPois.first(where: { $0.id == id }) else { return nil }
            return SavedPlace(name: q.name, lat: q.lat, lon: q.lon)
        case .newCustom:
            return nil
        }
    }

    /// 该坐标是否就是选项当前保存的地点（用于卡片收藏键的"已设置/取消"判断）
    func commonPlaceMatches(_ slot: CommonPlaceSlot, lat: Double, lon: Double) -> Bool {
        guard let p = commonPlace(for: slot) else { return false }
        return abs(p.lat - lat) < 1e-6 && abs(p.lon - lon) < 1e-6
    }

    /// 把地点写入指定选项（覆盖家/公司，或更新/新增自定义选项）
    func assignCommonPlace(_ slot: CommonPlaceSlot, name: String, lat: Double, lon: Double) {
        switch slot {
        case .home:
            homePlace = SavedPlace(name: name, lat: lat, lon: lon)
            saveHomeWork()
        case .work:
            workPlace = SavedPlace(name: name, lat: lat, lon: lon)
            saveHomeWork()
        case .favorite(let oldKey):
            // 收藏项改点：删旧坐标、按新坐标重建（收藏时间刷新，列表回到最前）
            favorites.removeValue(forKey: oldKey)
            favoriteTimes.removeValue(forKey: oldKey)
            let newKey = "\(lat),\(lon)"
            favorites[newKey] = name
            favoriteTimes[newKey] = Date().timeIntervalSince1970
            UserDefaults.standard.set(favorites, forKey: favKey)
            UserDefaults.standard.set(favoriteTimes, forKey: favTimesKey)
        case .custom(let id):
            let qp = QuickPoi(name: name, lat: lat, lon: lon)
            if let i = quickPois.firstIndex(where: { $0.id == id }) {
                quickPois.remove(at: i)
                quickPois.removeAll { $0.id == qp.id }   // 改到已存在的同一地点时去重
                quickPois.insert(qp, at: min(i, quickPois.count))
            } else {
                quickPois.removeAll { $0.id == qp.id }
                quickPois.insert(qp, at: 0)
            }
            saveQuickPois()
        case .newCustom:
            // 新增选项排在最前（"+"下方、最新收藏地址下方），重复地点只保留一条
            let qp = QuickPoi(name: name, lat: lat, lon: lon)
            quickPois.removeAll { $0.id == qp.id }
            quickPois.insert(qp, at: 0)
            saveQuickPois()
        }
    }

    /// 清空指定选项：家/公司置空，自定义选项直接删除；返回是否删掉了整条选项
    @discardableResult
    func clearCommonPlace(_ slot: CommonPlaceSlot) -> Bool {
        switch slot {
        case .home:
            homePlace = nil
            UserDefaults.standard.removeObject(forKey: homeKey)
            return false
        case .work:
            workPlace = nil
            UserDefaults.standard.removeObject(forKey: workKey)
            return false
        case .favorite(let key):
            let parts = key.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 { removeFavorite(lat: parts[0], lon: parts[1]) }
            return true
        case .custom(let id):
            removeQuickPoi(id: id)
            return true
        case .newCustom:
            return false
        }
    }

    private func saveHomeWork() {
        let ud = UserDefaults.standard
        if let d = try? JSONEncoder().encode(homePlace) {
            ud.set(d, forKey: homeKey)
        } else {
            ud.removeObject(forKey: homeKey)
        }
        if let d = try? JSONEncoder().encode(workPlace) {
            ud.set(d, forKey: workKey)
        } else {
            ud.removeObject(forKey: workKey)
        }
    }

    // MARK: - v1.69 搜索面板自定义快捷卡片（+ 选点生成，长按删除）

    private let quickKey = "quick_pois"

    func loadQuickPois() {
        if let d = UserDefaults.standard.data(forKey: quickKey),
           let arr = try? JSONDecoder().decode([QuickPoi].self, from: d) {
            quickPois = arr
        }
    }

    func addQuickPoi(name: String, lat: Double, lon: Double) {
        quickPois.append(QuickPoi(name: name, lat: lat, lon: lon))
        saveQuickPois()
    }

    func removeQuickPoi(id: String) {
        quickPois.removeAll { $0.id == id }
        saveQuickPois()
    }

    /// v2.34 快捷卡片重命名（对比高德：长按卡片可改名/删除）
    func renameQuickPoi(id: String, newName: String) {
        let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = quickPois.firstIndex(where: { $0.id == id }) else { return }
        var qp = quickPois[i]
        qp.name = n
        quickPois[i] = qp
        saveQuickPois()
    }

    private func saveQuickPois() {
        if let d = try? JSONEncoder().encode(quickPois) {
            UserDefaults.standard.set(d, forKey: quickKey)
        }
    }

    // MARK: - 网络查询工具（v1.26：统一超时 + 备用镜像 + 动态搜索范围）

    /// 生成动态 bbox 字符串 "minLat,minLon,maxLat,maxLon"。
    /// 以 center 为中心（无定位时回退合肥），latSpan/lonSpan 为跨度（度），使在线查询跟随当前位置，支持全国范围。
    private func bbox(center: CLLocationCoordinate2D?, latSpan: Double, lonSpan: Double) -> String {
        let c = center ?? CLLocationCoordinate2D(latitude: 31.86, longitude: 117.28)
        return String(format: "%.4f,%.4f,%.4f,%.4f",
                      c.latitude - latSpan / 2, c.longitude - lonSpan / 2,
                      c.latitude + latSpan / 2, c.longitude + lonSpan / 2)
    }

    /// 统一的 Overpass POST 查询：主实例失败自动切换备用镜像，解析失败返回 nil。
    private func overpassQuery(_ query: String, timeout: TimeInterval = 25) async -> [String: Any]? {
        let endpoints = [
            "https://overpass-api.de/api/interpreter",
            "https://overpass.kumi.systems/api/interpreter"
        ]
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = timeout
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue("MotoNavHelper/1.0", forHTTPHeaderField: "User-Agent")
            req.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)".data(using: .utf8)
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return root
            }
        }
        return nil
    }

    // MARK: - 合肥小区/商铺联想


    /// 在线拉取当前位置周边小区/商铺名称（Overpass 免费接口，范围跟随定位）
    private func fetchHefeiPoisOnline() async -> [String]? {
        let bb = bbox(center: currentLocation, latSpan: 0.6, lonSpan: 0.9)
        let q = "[out:json][timeout:25];(node[\"shop\"](\(bb));way[\"shop\"](\(bb));node[\"name\"~\"小区|花园|苑|家园|社区|新村|公寓|广场|商场|购物\"](\(bb)););out tags;"
        guard let root = await overpassQuery(q, timeout: 20),
              let els = root["elements"] as? [[String: Any]] else { return nil }
        var names = Set<String>()
        for e in els {
            if let t = e["tags"] as? [String: Any],
               let n = (t["name"] as? String)?.trimmingCharacters(in: .whitespaces),
               !n.isEmpty {
                names.insert(n)
            }
        }
        return names.count > 20 ? Array(names) : nil
    }

    /// 按名称在线查询地点坐标（联想命中后的规划 / 模糊兜底搜索，范围跟随定位）
    /// fuzzy=true 时模糊匹配 node/way/relation（小区多为 way，精确匹配找不到时兜底）
    func findHefeiCoordinate(_ name: String, fuzzy: Bool = false) async -> CLLocationCoordinate2D? {
        let esc = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let bb = bbox(center: currentLocation, latSpan: 1.0, lonSpan: 1.4)
        let q: String
        if fuzzy {
            q = "[out:json][timeout:20];(node[\"name\"~\"\(esc)\",i](\(bb));way[\"name\"~\"\(esc)\",i](\(bb));relation[\"name\"~\"\(esc)\",i](\(bb)););out center 15;"
        } else {
            q = "[out:json][timeout:15];node[\"name\"=\"\(esc)\"](\(bb));out center 1;"
        }
        guard let root = await overpassQuery(q, timeout: fuzzy ? 20 : 15),
              let els = root["elements"] as? [[String: Any]] else { return nil }
        var best: CLLocationCoordinate2D?
        var bestIsExact = false
        for e in els {
            var lat = e["lat"] as? Double ?? 0
            var lon = e["lon"] as? Double ?? 0
            if (lat == 0 || lon == 0), let c = e["center"] as? [String: Any] {
                lat = c["lat"] as? Double ?? 0
                lon = c["lon"] as? Double ?? 0
            }
            guard lat != 0, lon != 0 else { continue }
            let exact: Bool
            if let n = (e["tags"] as? [String: Any])?["name"] as? String {
                exact = n.localizedCaseInsensitiveContains(name)
            } else {
                exact = false
            }
            if exact && !bestIsExact {
                best = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                bestIsExact = true
            }
            if best == nil {
                best = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }
        return best
    }

    /// Photon（免费、无 Key、稳定）在线地理编码：当前位置周边按名称查点，过滤合肥
    func photonSearch(_ name: String) async -> (CLLocationCoordinate2D, String)? {
        let c = currentLocation ?? CLLocationCoordinate2D(latitude: 31.86, longitude: 117.28)
        guard let esc = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        let bbox = "\(c.longitude - 0.8),\(c.latitude - 0.6),\(c.longitude + 0.8),\(c.latitude + 0.6)"
        guard let url = URL(string: "https://photon.komoot.io/api/?q=\(esc)&limit=5&bbox=\(bbox)") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("MotoNavHelper/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feats = root["features"] as? [[String: Any]] else { return nil }
        for f in feats {
            guard let props = f["properties"] as? [String: Any],
                  let geo = f["geometry"] as? [String: Any],
                  let coords = geo["coordinates"] as? [Double], coords.count >= 2 else { continue }
            let city = props["city"] as? String ?? ""
            let state = props["state"] as? String ?? ""
            // 限定合肥市/安徽省，避免搜到同名外地地点
            if !city.contains("合肥") && !state.contains("安徽") { continue }
            let n = props["name"] as? String ?? name
            return (CLLocationCoordinate2D(latitude: coords[1], longitude: coords[0]), n)
        }
        return nil
    }

    /// 在线搜索兜底：联想库未收录的地点（如新小区、品牌门店），模糊查询后预览；
    /// 双通道降级：Overpass → Photon（稳定），仍失败引导复制位置链接
    func onlineSearch(_ name: String) {
        // 本地地标词典优先（离线可用，网络不可达也能定位）
        if let lm = matchLandmark(name) {
            setPreview(lm.name, lat: lm.lat, lon: lm.lon)
            status = "已定位「\(lm.name)」（坐标为估算，可长按点位拖动校准），点「去这里」规划路线"
            return
        }
        status = "正在在线搜索「\(name)」…"
        Task {
            var variants = [name]
            if name.count > 4 {
                variants.append(String(name.dropFirst(2)))       // 去开发商前缀
            }
            if name.count > 6 {
                variants.append(String(name.suffix(2)))          // 保留核心尾词
            }
            if name.count > 3 {
                variants.append(String(name.prefix(3)))          // 品牌/核心首词（如"特斯拉"）
            }
            var found: CLLocationCoordinate2D?
            var foundName = name
            // 通道1：Overpass（合肥点位更全，但公共实例不稳）
            for v in variants {
                if let c = await findHefeiCoordinate(v, fuzzy: true) { found = c; break }
            }
            // 通道2：Photon（稳定可达，地址库更全）
            if found == nil {
                for v in variants {
                    if let (c, n) = await photonSearch(v) { found = c; foundName = n; break }
                }
            }
            if let c = found {
                setPreview(foundName, lat: c.latitude, lon: c.longitude)
                status = "已定位到「\(foundName)」（坐标为估算，请实地校准），点「去这里」规划路线"
            } else {
                status = "「\(name)」暂未收录，请从微信/高德复制位置（或 纬度,经度）粘贴到搜索框"
            }
        }
    }

    // MARK: - 外部位置识别（微信/高德复制、深链）

    /// 解析外部位置文本：腾讯/高德 coord= 链接、geo:、裸经纬度
    func parseExternalLocation(_ text: String) -> CLLocationCoordinate2D? {
        let pattern = #"([-+]?\d{1,2}\.\d{3,})\s*[,，]\s*([-+]?\d{1,3}\.\d{3,})"#
        if let r = text.range(of: pattern, options: .regularExpression) {
            let s = String(text[r])
            let p = s.split(whereSeparator: { $0 == "," || $0 == "，" }).compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if p.count == 2, p[0] >= -90, p[0] <= 90, p[1] >= -180, p[1] <= 180 {
                return CLLocationCoordinate2D(latitude: p[0], longitude: p[1])
            }
        }
        return nil
    }

    /// 处理 motonav://route?lat=..&lon=..&name=.. 深链
    func handleRouteURL(_ url: URL) {
        guard url.scheme?.lowercased() == "motonav" else { return }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems else { return }
        var lat = 0.0, lon = 0.0
        var name = "地图位置"
        for it in items {
            switch it.name {
            case "lat": lat = Double(it.value ?? "") ?? 0
            case "lon", "lng": lon = Double(it.value ?? "") ?? 0
            case "name": if let v = it.value, !v.isEmpty { name = v }
            default: break
            }
        }
        guard lat != 0, lon != 0 else { return }
        setPreview(name, lat: lat, lon: lon)
        status = "已从链接定位到「\(name)」，点「去这里」规划路线"
    }

    /// 启动时检查剪贴板：微信/高德复制的位置文本 → 弹出"去这里"
    func checkClipboard() {
        guard let s = UIPasteboard.general.string,
              let c = parseExternalLocation(s) else { return }
        let name = s.components(separatedBy: "\n").first.map { String($0.prefix(24)) } ?? "剪贴板位置"
        setPreview(name, lat: c.latitude, lon: c.longitude)
        status = "检测到剪贴板位置「\(name)」，点「去这里」规划路线"
    }

    /// 拉取地图周边小区/商铺名称标签（带坐标，范围跟随定位，半径约 16km）
    func fetchPlaceLabels() {
        Task {
            let bb = bbox(center: currentLocation, latSpan: 0.3, lonSpan: 0.4)
            let q = "[out:json][timeout:30];(node[\"name\"~\"小区|花园|苑|家园|社区|新村|公寓|广场|商场|购物|中心\"](\(bb));way[\"name\"~\"小区|花园|苑|家园|社区|新村|公寓|广场|商场|购物|中心\"](\(bb)););out center 500;"
            guard let root = await overpassQuery(q, timeout: 30),
                  let els = root["elements"] as? [[String: Any]] else { return }
            var list: [PlaceLabel] = []
            var seen = Set<String>()
            for e in els {
                guard let n = ((e["tags"] as? [String: Any])?["name"] as? String)?
                    .trimmingCharacters(in: .whitespaces), !n.isEmpty, n.count <= 12 else { continue }
                var lat = e["lat"] as? Double ?? 0
                var lon = e["lon"] as? Double ?? 0
                if (lat == 0 || lon == 0), let c = e["center"] as? [String: Any] {
                    lat = c["lat"] as? Double ?? 0
                    lon = c["lon"] as? Double ?? 0
                }
                guard lat != 0, lon != 0, !seen.contains(n) else { continue }
                seen.insert(n)
                list.append(PlaceLabel(name: n, lat: lat, lon: lon))
            }
            if list.count > 30 {
                // v2.12：地名标签从 600 降到 220。600 个 MKAnnotation 在低端机上光渲染就掉帧，
                // 而屏幕上同时能看到的本来也就几十个；按到当前位置的距离排序，优先留住近处的。
                let center = currentLocation
                if let c = center {
                    list.sort {
                        distanceM(c, CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon))
                            < distanceM(c, CLLocationCoordinate2D(latitude: $1.lat, longitude: $1.lon))
                    }
                }
                placeLabels = Array(list.prefix(220))
            }
        }
    }

    // MARK: - 历史搜索

    private func loadHistory() {
        let arr = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
        searchHistory = Array(arr.prefix(historyLimit))
    }

    func addHistory(_ name: String) {
        guard !name.isEmpty else { return }
        searchHistory.removeAll { $0 == name }
        searchHistory.insert(name, at: 0)
        if searchHistory.count > historyLimit { searchHistory.removeLast() }
        UserDefaults.standard.set(searchHistory, forKey: historyKey)
    }

    func clearHistory() {
        searchHistory = []
        UserDefaults.standard.removeObject(forKey: historyKey)
    }

    /// v1.82 删除单个搜索历史（联想列表"常搜"项左拉删除）
    func removeHistory(_ name: String) {
        searchHistory.removeAll { $0 == name }
        UserDefaults.standard.set(searchHistory, forKey: historyKey)
    }

    // MARK: - 类别搜索（学校/医院/加油站，附近10公里）

    /// 类别搜索结果（name + 坐标 + 类别）
    struct CategoryResult: Identifiable, Hashable {
        let name: String
        let lat: Double
        let lon: Double
        let kind: String
        var id: String { "\(kind)|\(name)|\(lat)|\(lon)" }
    }

    @Published var categoryResults: [CategoryResult] = []
    /// 类别结果地图刷新计数
    @Published var categoryTick = 0

    /// 判断关键词是否为类别搜索（学校/医院/加油站），返回类别与 Overpass amenity 匹配式
    func categoryKeyword(_ q: String) -> (kind: String, amenity: String)? {
        if q.contains("学校") || q.contains("中学") || q.contains("小学") || q.contains("大学") || q.contains("学院") || q.contains("幼儿园") {
            return ("学校", "school|kindergarten|college|university")
        }
        if q.contains("医院") || q.contains("诊所") || q.contains("卫生") || q.contains("卫生院") {
            return ("医院", "hospital|clinic|doctors|dentist")
        }
        if q.contains("加油站") || q.contains("油站") {
            return ("加油站", "fuel")
        }
        return nil
    }

    /// 按当前位置拉取附近约10公里内的类别点位并高亮
    func fetchCategory(_ q: String) {
        guard let c = categoryKeyword(q) else { return }
        let center = currentLocation ?? CLLocationCoordinate2D(latitude: 31.86, longitude: 117.28)
        let dLat = 0.09
        let dLon = 0.11
        let bbox = String(format: "%.4f,%.4f,%.4f,%.4f", center.latitude - dLat, center.longitude - dLon, center.latitude + dLat, center.longitude + dLon)
        let query = "[out:json][timeout:25];(node[\"amenity\"~\"\(c.amenity)\"](\(bbox));way[\"amenity\"~\"\(c.amenity)\"](\(bbox)););out center 80;"
        status = "正在查找附近10公里\(c.kind)…"
        Task {
            guard let root = await overpassQuery(query, timeout: 25),
                  let els = root["elements"] as? [[String: Any]] else {
                status = "查询\(c.kind)失败，请稍后重试"
                return
            }
            let cl = CLLocation(latitude: center.latitude, longitude: center.longitude)
            var list: [CategoryResult] = []
            var seen = Set<String>()
            for e in els {
                guard let n = ((e["tags"] as? [String: Any])?["name"] as? String)?
                    .trimmingCharacters(in: .whitespaces), !n.isEmpty else { continue }
                var lat = e["lat"] as? Double ?? 0
                var lon = e["lon"] as? Double ?? 0
                if (lat == 0 || lon == 0), let cc = e["center"] as? [String: Any] {
                    lat = cc["lat"] as? Double ?? 0
                    lon = cc["lon"] as? Double ?? 0
                }
                guard lat != 0, lon != 0 else { continue }
                let key = n
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                let dist = cl.distance(from: CLLocation(latitude: lat, longitude: lon))
                if dist <= 10000 { // 10公里内
                    list.append(CategoryResult(name: n, lat: lat, lon: lon, kind: c.kind))
                }
            }
            list.sort { a, b in
                let da = cl.distance(from: CLLocation(latitude: a.lat, longitude: a.lon))
                let db = cl.distance(from: CLLocation(latitude: b.lat, longitude: b.lon))
                return da < db
            }
            categoryResults = list
            categoryTick += 1
            status = list.isEmpty ? "附近10公里未找到\(c.kind)" : "找到 \(list.count) 个\(c.kind)，点击可直接规划路线"
        }
    }

    func clearCategory() {
        categoryResults = []
        categoryTick += 1
    }

    /// 类别点距离文本
    func categoryDistance(_ r: CategoryResult) -> String {
        guard let cur = currentLocation else { return "" }
        let d = CLLocation(latitude: cur.latitude, longitude: cur.longitude)
            .distance(from: CLLocation(latitude: r.lat, longitude: r.lon))
        if d < 1000 { return "\(Int(d))m" }
        return String(format: "%.1fkm", d / 1000)
    }

    // MARK: - 天气（Open-Meteo 免费接口）

    /// 上次发起天气请求的时间（v2.12：节流用）
    private var lastWeatherTry: TimeInterval = 0

    func fetchWeather() {
        guard let loc = currentLocation else { return }
        // v2.12：定位回调每秒都来，旧代码只在 weatherText == nil 时才拉，
        // 一旦首次请求失败（弱网/无网），就会每次定位都重发一次请求 —— 一直失败一直发。
        // 现在统一节流：5 分钟内最多请求一次，成功失败都算。
        let now = Date().timeIntervalSince1970
        guard now - lastWeatherTry > 300 else { return }
        lastWeatherTry = now
        Task {
            var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
            comps.queryItems = [
                URLQueryItem(name: "latitude", value: String(loc.latitude)),
                URLQueryItem(name: "longitude", value: String(loc.longitude)),
                // v1.26：新增降水、风速，对摩托车出行更关键
                URLQueryItem(name: "current", value: "temperature_2m,weather_code,precipitation,wind_speed_10m,wind_direction_10m"),
                URLQueryItem(name: "hourly", value: "precipitation_probability"),
                URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
                URLQueryItem(name: "timezone", value: "Asia/Shanghai"),
                URLQueryItem(name: "forecast_days", value: "2")
            ]
            guard let url = comps.url else { return }
            var req = URLRequest(url: url)
            req.timeoutInterval = 12
            req.setValue("MotoNavHelper/1.0", forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            // 当前天气（兼容新旧两种字段名）
            var icon = "🌡️"
            var temp: Double?
            var windKmH: Double?
            var precipProb: Int?
            if let cur = root["current"] as? [String: Any] {
                temp = cur["temperature_2m"] as? Double ?? cur["temperature"] as? Double
                if let code = cur["weather_code"] as? Int ?? cur["weathercode"] as? Int {
                    icon = weatherIcon(code)
                    weatherCode = code
                }
                windKmH = cur["wind_speed_10m"] as? Double
            }
            // 当前小时降水概率（hourly 首项即当前整点，时区已对齐上海）
            if let hourly = root["hourly"] as? [String: Any],
               let probs = hourly["precipitation_probability"] as? [Double],
               let first = probs.first {
                precipProb = Int(first.rounded())
            }
            if let t = temp {
                var parts = [icon, "\(Int(t.rounded()))°"]
                if let pp = precipProb, pp > 0 { parts.append("降水\(pp)%") }
                if let w = windKmH { parts.append("风\(Int(w.rounded()))km/h") }
                weatherText = parts.joined(separator: " ")
            }
            // 明日最高/最低 + 降水概率
            if let daily = root["daily"] as? [String: Any],
               let max = daily["temperature_2m_max"] as? [Double],
               let min = daily["temperature_2m_min"] as? [Double],
               max.count > 1, min.count > 1 {
                var t = "明日 \(Int(min[1].rounded()))~\(Int(max[1].rounded()))°"
                if let ppMax = daily["precipitation_probability_max"] as? [Double],
                   ppMax.count > 1, Int(ppMax[1].rounded()) > 0 {
                    t += " 降水\(Int(ppMax[1].rounded()))%"
                }
                tomorrowText = t
            }
        }
    }

    private func weatherIcon(_ code: Int) -> String {
        switch code {
        case 0: return "☀️"
        case 1, 2: return "🌤️"
        case 3: return "☁️"
        case 45, 48: return "🌫️"
        case 51, 53, 55, 56, 57: return "🌦️"
        case 61, 63, 65, 66, 67: return "🌧️"
        case 71, 73, 75, 77: return "🌨️"
        case 80, 81, 82: return "🌦️"
        case 85, 86: return "🌨️"
        case 95, 96, 99: return "⛈️"
        default: return "🌡️"
        }
    }

    // MARK: - 市区加油站（Overpass）

    func fetchGasStations() {
        Task {
            let bb = bbox(center: currentLocation, latSpan: 0.45, lonSpan: 0.6)
            let q = "[out:json][timeout:25];node[\"amenity\"=\"fuel\"](\(bb));out;"
            guard let root = await overpassQuery(q, timeout: 25),
                  let els = root["elements"] as? [[String: Any]] else {
                status = "加油站数据加载失败，请检查网络"
                return
            }
            var list: [CLLocationCoordinate2D] = []
            for e in els {
                if let lat = e["lat"] as? Double, let lon = e["lon"] as? Double, lat != 0, lon != 0 {
                    list.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                }
            }
            gasStations = list
            if !list.isEmpty {
                gasTick += 1
                status = "已显示市区 \(list.count) 个加油站"
            }
        }
    }

    // MARK: - 搜索预览（绿色高亮 + 去这里）

    func setPreview(_ name: String, lat: Double, lon: Double) {
        searchPreviewName = name
        searchPreview = CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    func clearPreview() {
        searchPreview = nil
        searchPreviewName = ""
    }

    // MARK: - 权限与定位

    @objc func authorizeAndStart() {
        let auth = lm.authorizationStatus
        switch auth {
        case .notDetermined:
            lm.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            locationDenied = false
            startMonitoring()
        default:
            locationDenied = true
            status = "需要定位权限才能使用，点上方横幅可去设置开启"
        }
    }

    func startMonitoring() {
        guard !monitoring else { return }
        lm.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        updateLocationFilter()
        lm.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            // v1.63：摩托导航手机通常平放/斜放在车把支架，
            // 默认竖屏朝向计算的 trueHeading 在平放时会偏/失效 → 指定 faceUp 让箭头真正跟随手机朝向
            lm.headingOrientation = .faceUp
            lm.startUpdatingHeading()
        }
        monitoring = true
        // v1.12：默认开启监控，不再提示"GPS 已开启"
    }

    func stopMonitoring() {
        lm.stopUpdatingLocation()
        lm.stopUpdatingHeading()
        monitoring = false
        status = "等待定位…"
    }

    func toggleMonitoring() {
        monitoring ? stopMonitoring() : startMonitoring()
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let loc = locations.last else { return }
        let coord = loc.coordinate
        // v2.34 前后台切换时刷新定位采样频率（后台 50m / 前台按运动状态分级）
        // v2.47 修复：didUpdateLocations 为非隔离上下文，属性访问须进 MainActor
        Task { @MainActor in
            if UIApplication.shared.applicationState != self.lastLocationFilterAppState {
                self.lastLocationFilterAppState = UIApplication.shared.applicationState
                self.updateLocationFilter()
            }
        }
        Task { @MainActor in
            // v2.14 发布降频：位置/精度/速度是「界面重建」的触发器。
            // 静止时 GPS 会以 1Hz 左右抖动（每次几米），而 ContentView.body 是一整棵树，
            // 每重算一次都要重建几十个浮层 —— 抖动叠加起来就是「界面完整但点不动」。
            // 移动超过 5 米或速度明显变化才写 @Published；下面的业务逻辑（导航/巡航）
            // 仍然每次定位都执行，不受影响。
            let speed = loc.speed > 0 ? loc.speed : 0
            let moved: Double = currentLocation.map { distanceM($0, coord) } ?? .greatestFiniteMagnitude
            if moved > 5 || abs(speed - currentSpeed) > 0.5 {
                currentLocation = coord
                locationAccuracy = loc.horizontalAccuracy
                currentSpeed = speed
            }
            // v2.90 采集 GPS 行进方向（供地图朝向融合用）：
            // CLLocation.course 在速度无效时返回 -1，这里一并当作无效处理。
            if loc.speed > 2.8, loc.course >= 0 {
                gpsHeading = loc.course
            } else {
                gpsHeading = nil
            }
            // v2.27（优化建议 #22）：运动状态分级（静止降频 / 骑行恢复）+ 隧道信号丢失检测
            lastLocationAt = Date()
            updateMotionState()
            checkTunnelSignal()
            // v1.99 足迹轨迹 + 最高速（仅导航中记录，避免无意义点位）
            if navigating {
                trackPoints.append(coord)
                // v2.38 H1 实际行驶距离：每次"发布移动 >5m"累加一段。
                // 复用发布降频的 moved 语义（currentLocation 更新条件就是 moved>5），
                // 静止 GPS 抖动（1~3m）天然被过滤，总量误差 <5m/发布段
                if moved > 5 { actualTripM += moved }
                // v2.36 F6 轨迹源数组封顶：足迹存档已抽稀，但源数组不封顶会随导航时长
                // 无限累积（2 小时 ≈ 数万点）；超 8000 点隔点抽稀一次（内存有界）
                if trackPoints.count > 8000 {
                    trackPoints = stride(from: 0, to: trackPoints.count, by: 2).map { trackPoints[$0] }
                }
                if loc.speed > 0 { maxSpeedKph = max(maxSpeedKph, loc.speed * 3.6) }
                checkRiderRisks(at: coord)
                // v2.43 M1 转弯后确认 + M2 前方拥堵提示（高德式小提示）
                checkTurnConfirm(at: coord)
                checkTrafficAhead(at: coord)
                // v2.28 导航进度更新放在这里（事件驱动），而不是 body 求值期 ——
                // 后者会触发 SwiftUI 无限重算循环（"点开始导航就卡死"的根因）。
                updateNavProgress(at: coord)
                // v2.29 按速度自动切换视野档位（低速看清路口 / 高速看远）
                updateAutoNavScale()
                // v2.90 每个定位都重算一次朝向（高速用 GPS 方向，低速用罗盘）
                applyFusedHeading()
                // v2.36 F5 超速语音播报：E8 视觉变红的语音版（高优先级可打断普通播报）
                // v2.38 H3 语音加 4km/h 缓冲：GPS 瞬时速度误差 ±2km/h，
                // 限速 60 时 61 就报会频繁误报；视觉红线保持瞬时（见 navBottomCard E8）
                if speedLimitKph > 0, currentSpeed * 3.6 > Double(speedLimitKph) + 4 {
                    if Date().timeIntervalSince(lastOverspeedSpeak) > 30 {
                        lastOverspeedSpeak = Date()
                        // v2.93 超速提醒优化：更简洁，和高德对齐
                        speak("您已超速，请减速", priority: 2)
                    }
                } else {
                    lastOverspeedSpeak = Date(timeIntervalSince1970: 0)
                }
            }
            // v1.99 组队位置上报（未组队时是空操作）
            TeamRide.shared.update(lat: coord.latitude, lon: coord.longitude,
                                   speedKph: max(0, loc.speed) * 3.6)
            // v1.92 后台/前台都靠定位回调复查电量（通知在挂起时收不到）
            throttledPowerSavingCheck()
            fetchWeather()
            // v2.17 在线搜索按「当前城市」收敛：定位一到位就把城市名预热好，
            // 免得第一次输入关键词时才临时多发一次逆地理（首字联想会慢半拍）
            if cityCache == nil { Task { _ = await self.currentCityName() } }
            // v2.33 电警播报引擎已整体移除（为电子眼融合做准备）
            checkNavigation(at: coord)
            updateCruise(at: coord)
        }
    }

    // MARK: - 巡航模式（v1.84）

    /// 非导航状态下自动检测：首页无操作 ≥10 秒进入巡航模式（地图缩放合理位置 + 定位点跟随）
    func updateCruise(at coord: CLLocationCoordinate2D) {
        guard !navigating else {
            if cruiseMode { exitCruise() }
            return
        }
        if cruiseAutoBlocked {
            cruiseBase = nil
        } else if !cruiseMode && Date().timeIntervalSince(lastUserActionTime) >= 10 {
            // 首页无操作10秒自动进入巡航模式
            cruiseMode = true
            cruiseTick += 1
            cruiseBase = nil
            // v2.88 设置巡航开始时间
            cruiseStartTime = Date()
            cruiseTotalDistance = 0
            // v2.88 巡航模式屏幕常亮
            UIApplication.shared.isIdleTimerDisabled = true
        }
        if cruiseMode {
            cruiseTick += 1 // 驱动地图跟随定位点（MapView 内做 GPS 抖动节流）
        }
    }

    /// 关闭巡航模式（卡片右上角 ×）：恢复初始地图，重新累计位移
    func exitCruise() {
        cruiseMode = false
        cruiseBase = nil
        cruiseTick += 1
        // v2.88 清零巡航统计
        cruiseStartTime = nil
        cruiseTotalDistance = 0
        // v2.88 退出巡航恢复自动息屏（如果不是导航中）
        if !navigating {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    /// v2.88 测试导航：模拟导航到虚拟目的地，用来测试导航功能
    func startTestNavigation() {
        // 先退出巡航
        exitCruise()
        // 用当前位置作为起点，前方1公里作为终点，生成一条直线路线
        guard let currentLoc = currentLocation else {
            status = "无法获取当前位置"
            return
        }
        // 终点：当前位置向北1公里
        let destLat = currentLoc.latitude + 0.009
        let destLon = currentLoc.longitude
        // 生成一条简单的直线路线（10个点）
        var testRoute: [CLLocationCoordinate2D] = []
        for i in 0...10 {
            let ratio = Double(i) / 10.0
            let lat = currentLoc.latitude + (destLat - currentLoc.latitude) * ratio
            let lon = currentLoc.longitude + (destLon - currentLoc.longitude) * ratio
            testRoute.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        route = testRoute
        destName = "测试目的地"
        destLat = destLat
        destLon = destLon
        // 开始导航
        navigating = true
        heading = compass.angle
        UIApplication.shared.isIdleTimerDisabled = true
        pitchDeg = 45
        navScaleTarget = 100
        navScaleTick += 1
        navUserMoved = false
        navigateFollowTick += 1
        status = "测试导航中"
    }

    /// v2.34 体验审查 E5：手动退出巡航 → 本次会话内不再自动进入（避免反复打扰）。
    /// 与 exitCruise 的区别：exitCruise 供程序内部调用（如规划路线时让位），不抑制；
    /// 用户点巡航卡 × 走这里，App 重启前不再自动进巡航。
    private var cruiseAutoBlocked = false
    func dismissCruiseManually() {
        exitCruise()
        cruiseAutoBlocked = true
        status = "已退出巡航 · 本次使用内不再自动进入"
    }

    /// v2.90 导航朝向融合：这是地图旋转的唯一出口
    ///
    /// 旧版只用手机罗盘（CLHeading.trueHeading）驱动 camera.heading。
    /// 骑行时手机装在支架上，支架一旦装歪（比如斜着夹 20°），
    /// 地图就会永远比真实行进方向偏同样一个角度 —— 高德不会，它优先用 GPS 行进方向。
    ///
    /// 现在的规则：
    ///  · 速度 > 10 km/h 且 GPS course 有效 → 用行进方向（不受支架角度影响）
    ///  · 其余情况（停车、GPS 方向无效）→ 回落手机罗盘
    /// GPS course 是瞬时方向、抖动比罗盘大，所以死区放宽到 5°（罗盘仍是 4°）。
    private func applyFusedHeading() {
        guard navigating else { return }
        // v2.86 速度不为0时用GPS行进方向，速度为0时才用指南针
        let moving = currentSpeed > 0.5    // 0.5 m/s ≈ 1.8 km/h，稍微动一下就算移动
        let target: Double
        if moving, let g = gpsHeading {
            target = g
        } else {
            target = compass.angle
        }
        let diff = abs(target - heading)
        let delta = min(diff, 360 - diff)
        // GPS方向抖动大，死区5°；罗盘死区4°
        guard delta >= (moving ? 5 : 4) else { return }
        heading = target
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateHeading newHeading: CLHeading
    ) {
        // trueHeading 无效（磁干扰/未校准）时退回磁北，否则会把指南针打成 0
        let h = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        Task { @MainActor in
            // v2.13 分流：
            //  · compass.angle 只驱动指南针小圈，随便高频更新；
            //  · heading 会触发 ContentView 整树重算，只有导航中（地图要跟着转）才写。
            let diff = abs(h - compass.angle)
            let delta = min(diff, 360 - diff)
            guard delta >= 2 else { return }
            compass.angle = h
            // 导航中地图要跟着手机转，这时才发布 heading；再叠加 4° 死区，
            // 把 20Hz 压到 5Hz 左右 —— 4° 在这块 56pt 的指北针和 200 米视野上看不出来。
            if navigating {
                // v2.90 不再直接用罗盘写 heading：高速行驶交给 GPS 行进方向
                applyFusedHeading()
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                locationDenied = false
                startMonitoring()
            } else if status == .denied || status == .restricted {
                locationDenied = true
                self.status = "需要定位权限才能导航，点上方横幅可去设置开启"
            }
        }
    }

    /// v2.34 体验审查 E3：定位权限被拒（顶部横幅引导去系统设置）
    @Published var locationDenied = false

    // MARK: - v2.27 诊断信息（优化建议 #24/#25）

    /// 定位授权状态的可读描述
    var locationAuthText: String {
        switch lm.authorizationStatus {
        case .authorizedAlways: return "始终允许"
        case .authorizedWhenInUse: return "使用 App 期间允许"
        case .denied: return "已拒绝（去系统设置开启）"
        case .restricted: return "受限"
        case .notDetermined: return "未询问"
        @unknown default: return "未知"
        }
    }

    /// 最近的操作日志（诊断页展示；用户截图给开发者时能直接看到发生了什么）
    ///
    /// 只保留最近 50 条，避免无限增长。
    @Published private(set) var recentLogs: [String] = []

    /// 记录一条诊断日志
    func log(_ text: String) {
        let line = "[\(Self.timeText(Date()))] \(text)"
        recentLogs.append(line)
        if recentLogs.count > 50 {
            recentLogs.removeFirst(recentLogs.count - 50)
        }
    }

    /// 时间格式化（HH:mm:ss）
    private static func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    // MARK: - 接近提醒引擎



    func distanceM(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// 当前定位到点位的直线距离（UI 用）

    // MARK: - 语音（讯飞在线四川话女声优先，失败自动降级系统 TTS 川味甜妹）

    /// 讯飞开放平台「摩卫士」应用三值（v1.52 用户实名认证后提供，可被 UserDefaults 覆盖）
    // v1.92：三项默认值改由构建期注入，源码不再含明文；未注入时为空 → 自动改用系统 TTS
    static var xfAppIdDefault: String { AppSecrets.value(AppSecrets.xfAppId) }
    static var xfApiKeyDefault: String { AppSecrets.value(AppSecrets.xfApiKey) }
    static var xfApiSecretDefault: String { AppSecrets.value(AppSecrets.xfApiSecret) }
    var xfAppId: String { UserDefaults.standard.string(forKey: "xfAppId") ?? Self.xfAppIdDefault }
    var xfApiKey: String { UserDefaults.standard.string(forKey: "xfApiKey") ?? Self.xfApiKeyDefault }
    var xfApiSecret: String { UserDefaults.standard.string(forKey: "xfApiSecret") ?? Self.xfApiSecretDefault }
    /// 音色：vcn 代码（v1.80 起仅保留讯飞已授权发音人；旧 yezi 自动迁移到特色 x4_yezi）
    var xfVcn: String {
        // v2.92 默认语音改成四川话女声·叶子（用户指定）
        let v = UserDefaults.standard.string(forKey: "xfVcn") ?? "x4_yezi"
        return v == "yezi" ? "x4_yezi" : v
    }
    /// 讯飞引擎开关（默认开；设置为 false 用系统语音）
    var xfEnabled: Bool { UserDefaults.standard.object(forKey: "xfEnabled") as? Bool ?? true }
    /// 当前音色显示名
    var xfVcnName: String {
        switch xfVcn {
        case "xiaoyu": return "普通话女声·晓宇"
        case "xiaomei": return "普通话女声·小美"
        case "xiaoqiang": return "普通话男声·小强"
        case "xiaoyue": return "粤语女声·晓月"
        case "x4_xiaolu": return "普通话女声·讯飞小露"
        case "x4_xiaorong": return "四川话女声·讯飞小蓉"
        case "x4_yezi": return "四川话女声·叶子"
        case "x4_lingbosong": return "普通话男声·聆伯松"
        case "x4_lingxiaoxuan_wenrou": return "普通话女声·聆小璇-温柔"
        case "xiaoyan": return "普通话女声·晓燕"
        default: return "四川话女声·小蓉"
        }
    }

    /// 语音播报开关（高德式导航静音按钮）
    func toggleVoice() {
        let muted = !voiceMuted
        UserDefaults.standard.set(muted, forKey: "voiceMuted")
        if muted {
            speech.stopSpeaking(at: .immediate)
            xfPlayer?.stop()
        } else {
            speak("语音播报已开启")
        }
    }

    /// v2.29 音频会话激活（带缓存，避免重复的同步 IPC）
    ///
    /// setCategory / setActive 都是 coreaudiod 的同步调用，
    /// 在来电、Siri 抢占、蓝牙切路由时可能阻塞几百毫秒甚至秒级。
    /// 导航中播报很频繁（每几百米一次），每次都调一遍既慢又可能卡主线程。
    ///
    /// 这里只在会话还没激活时设置一次。被系统打断（来电）时由
    /// `invalidateAudioSession()` 置回 false，下次播报会重新激活。
    private var audioSessionActive = false

    private func activateAudioSessionIfNeeded() {
        guard !audioSessionActive else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        audioSessionActive = true
    }

    /// 音频会话被系统抢占后调用（下次播报会重新激活）
    func invalidateAudioSession() {
        audioSessionActive = false
    }

    private func speakSystem(_ text: String) {
        // v1.80 恢复最早默认中文女声（用户要求"本地内置改回原来声音"）：系统默认 zh-CN、正常语速、无语气词
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = 0.5
        speech.speak(u)
    }

    /// 讯飞在线语音合成（wss WebSocket + HMAC-SHA256 鉴权，mp3 分片返回）
    /// v1.79 fix：鉴权参数必须放 URL query（放握手 Header 被网关 401），改 URLSession WebSocket；
    ///           参数与文本合并单帧发送（分两帧会报 10163 datalist is nil）；rdn 必须为字符串
    private func speakXf(_ text: String) {
        let appId = xfAppId, apiKey = xfApiKey, apiSecret = xfApiSecret
        guard !appId.isEmpty, !apiKey.isEmpty, !apiSecret.isEmpty else {
            speakSystem(text); return
        }
        xfSeq += 1
        let mySeq = xfSeq
        let vcn = xfVcn
        // v1.80 仅四川话音色（小蓉/讯飞小蓉/叶子）加川味语气词，普通话/粤语/男声原样播报
        let sichuan = ["xiaorong", "x4_xiaorong", "x4_yezi"].contains(vcn)
        let t = sichuan ? sweetSichuan(text) : text

        // HMAC-SHA256 鉴权（讯飞 v2/tts 要求鉴权参数放 URL query，非握手头）
        let host = "tts-api.xfyun.cn"
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "GMT")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let date = df.string(from: Date())
        let origin = "host: \(host)\ndate: \(date)\nGET /v2/tts HTTP/1.1"
        let key = SymmetricKey(data: Data(apiSecret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(origin.utf8), using: key)
        let sig = Data(mac).base64EncodedString()
        let authOrigin = "api_key=\"\(apiKey)\", algorithm=\"hmac-sha256\", headers=\"host date request-line\", signature=\"\(sig)\""
        let auth = Data(authOrigin.utf8).base64EncodedString()

        var comps = URLComponents(string: "wss://\(host)/v2/tts")!
        comps.queryItems = [
            URLQueryItem(name: "authorization", value: auth),
            URLQueryItem(name: "date", value: date),
            URLQueryItem(name: "host", value: host)
        ]
        guard let url = comps.url else { speakSystem(text); return }

        xfTask?.cancel()
        let task = URLSession.shared.webSocketTask(with: url)
        xfTask = task

        // 参数与文本合并单帧（v2/tts 流式协议：common+business+data 一帧）
        let frame: [String: Any] = [
            "common": ["app_id": appId],
            "business": ["aue": "lame", "sfl": 1, "auf": "audio/L16;rate=16000",
                         "vcn": vcn, "speed": 55, "volume": 60, "pitch": 50,
                         "tte": "UTF8", "rdn": "0"],
            "data": ["status": 2, "text": Data(t.utf8).base64EncodedString()]
        ]
        guard let j = try? JSONSerialization.data(withJSONObject: frame),
              let js = String(data: j, encoding: .utf8) else {
            speakSystem(text); return
        }

        // 局部状态（非隔离变量，回调闭包捕获）
        var audio = Data()
        var done = false
        var failed = false
        let finishAudio = { (buf: Data) in
            if !buf.isEmpty && !done {
                done = true
                task.cancel()
                Task { @MainActor [weak self] in
                    guard let self = self, mySeq == self.xfSeq else { return }
                    if !self.playXf(buf) {
                        self.xfDiag = "讯飞音频解析失败，已降级系统语音"
                        self.speakSystem(text)
                    }
                }
            }
        }
        let fallback = { (diag: String) in
            if !failed {
                failed = true
                task.cancel()
                Task { @MainActor [weak self] in
                    guard let self = self, mySeq == self.xfSeq else { return }
                    self.xfDiag = diag
                    self.speakSystem(text)
                }
            }
        }

        func receive() {
            task.receive { result in
                if done || failed { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let s):
                        if let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] {
                            let code = obj["code"] as? Int ?? 0
                            if code != 0 {
                                if code == 11200 {
                                    fallback("音色未授权（11200），请在控制台发音人授权管理添加试用")
                                } else {
                                    fallback("讯飞错误码 \(code)")
                                }
                                return
                            }
                            let d = obj["data"] as? [String: Any]
                            if let b64 = d?["audio"] as? String, let b = Data(base64Encoded: b64) {
                                audio.append(b)
                            }
                            if d?["status"] as? Int == 2 { finishAudio(audio) }
                        }
                        receive()
                    case .data(let d):
                        audio.append(d)
                        receive()
                    @unknown default:
                        receive()
                    }
                case .failure:
                    fallback("讯飞连接失败（服务未开通或 Key 错误）")
                }
            }
        }

        task.resume()
        task.send(.string(js)) { _ in }
        receive()
    }

    /// 播放讯飞返回的 mp3
    @discardableResult
    private func playXf(_ data: Data) -> Bool {
        xfPlayer?.stop()
        guard let p = try? AVAudioPlayer(data: data) else { return false }
        p.volume = 1.0
        p.prepareToPlay()
        p.play()
        xfPlayer = p
        return true
    }

    func speak(_ text: String, priority: Int = 0) {
        guard !voiceMuted else { return }
        // v1.82 后台播报节流：切后台后普通提示 30 秒内最多 1 次、高优先级 8 秒 1 次，
        // 避免持续语音唤醒造成耗电与系统后台资源限制（导航提醒依旧后台播报）
        if UIApplication.shared.applicationState == .background {
            let since = Date().timeIntervalSince(lastSpeakAt)
            if since < 30 && priority < 2 { return }
            if since < 8 { return }
        }
        let now = Date()
        // 播报去重：2.5 秒内不连续播报（转向近提示/到达/超速高优先级可打断）
        //
        // v2.29：**去重判断必须放在音频会话激活之前**。
        // 旧顺序是「先 setCategory + setActive(true) → 再去重」，
        // 而这两个调用是 coreaudiod 的同步 IPC（来电/Siri/蓝牙切路由时可能阻塞数百毫秒到秒级），
        // 每次播报都白付一次，连被去重挡掉的那些播报也付了 —— 纯浪费。
        if now.timeIntervalSince(lastSpeakAt) < 2.5 && priority <= lastSpeakPriority {
            if now.timeIntervalSince(lastSpeakAt) < 1.2 || lastSpeakText == text { return }
        }
        // v2.34 播报防扎堆：1.5 秒内同类"距离+方向"提示（文本含"米"）直接合并，
        // 路口密集区（连续 300m/200m/100m 转向）只报第一条，不再一条接一条堆叠
        if now.timeIntervalSince(lastSpeakAt) < 1.5, priority <= lastSpeakPriority,
           text.contains("米"), lastSpeakText.contains("米") { return }
        // v1.81.4 后台语音播报：playback 会话（Info.plist 已含 audio 后台模式），导航切后台语音继续
        //
        // v2.29：只在会话尚未激活时才设置 —— 重复 setActive 是无意义的同步开销。
        activateAudioSessionIfNeeded()
        if priority > lastSpeakPriority && now.timeIntervalSince(lastSpeakAt) < 6 {
            speech.stopSpeaking(at: .immediate)
            xfPlayer?.stop()
        }
        lastSpeakAt = now
        lastSpeakPriority = priority
        lastSpeakText = text
        if xfEnabled {
            speakXf(text)
        } else {
            speakSystem(text)
        }
    }

    /// 川味语气词化（先长短语后短词，避免嵌套替换错乱）
    private func sweetSichuan(_ text: String) -> String {
        var s = text
        let map: [(String, String)] = [
            ("前方即将到达目的地", "马上就到咯"),
            ("路线已重新规划", "路线重新规划咯"),
            ("导航结束", "导航结束咯"),
            ("请提前减速", "提前减速哦"),
            ("前方", "前头"),
            ("米右转", "米右转咯"),
            ("米左转", "米左转咯"),
            ("右转", "右转咯"),
            ("左转", "左转咯"),
            ("请注意", "注意哦"),
            ("请减速", "减速嘛"),
            ("到达", "到咯"),
        ]
        for (k, v) in map {
            s = s.replacingOccurrences(of: k, with: v)
        }
        return s
    }

    // MARK: - 本地通知


    // MARK: - 模拟测试

    func toggleSimulation() {
        simulating.toggle()
        if simulating {
            stopMonitoring()
            simTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.simTick() }
            }
        } else {
            simTimer?.invalidate()
            simTimer = nil
        }
    }

    private func simTick() {
        let pts: [(Double, Double)] = [
            (31.8090, 117.2140), (31.8120, 117.2220), (31.8150, 117.2310),
            (31.8120, 117.2260), (31.8090, 117.2140)
        ]
        let a = pts[simStep % pts.count]
        let b = pts[(simStep + 1) % pts.count]
        let t = Double(simStep % 40) / 40.0
        let lat = a.0 + (b.0 - a.0) * t
        let lon = a.1 + (b.1 - a.1) * t
        simStep += 2
        currentLocation = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        status = String(format: "模拟行驶中 %.5f,%.5f", lat, lon)
    }

    // MARK: - 目的地搜索与路线规划

    /// 按名称在点位库中搜索；返回匹配列表（含类型标签）

    // MARK: - 拼音/错别字模糊匹配（v1.29）
    private func pinyinOf(_ s: String) -> (full: String, initials: String) {
        let m = NSMutableString(string: s)
        CFStringTransform(m, nil, kCFStringTransformToLatin, false)
        CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
        let spaced = (m as String).lowercased()
        let full = spaced.replacingOccurrences(of: " ", with: "")
        let initials = spaced.split(separator: " ").compactMap { $0.first }.map(String.init).joined()
        return (full, initials)
    }

    private func fuzzyMatch(_ s: String, _ q: String) -> Bool {
        if s.localizedCaseInsensitiveContains(q) { return true }
        let (pf, pi) = pinyinOf(s)
        let (qf, _) = pinyinOf(q)
        if !qf.isEmpty {
            if pf.contains(qf) || qf.contains(pf) || pf == qf { return true }
            if pi.hasPrefix(qf) { return true }
        }
        return false
    }

    /// 搜索智能联想：收藏 ⭐ 优先 + 点位名称 + 历史目的地 + 合肥小区/商铺 + 地标词典（最多 10 条）；
    /// 无匹配时给出"在线搜索「关键词」"入口
    func searchSuggestions(_ query: String) -> [String] {
        var pool = Set<String>()
        for h in searchHistory { pool.insert(h) }
        for lm in searchLandmarks where lm.matches(query) { pool.insert(lm.name) }
        // v1.45：地图上的小区/商铺/道路名标注全部进联想池（截图里的朱山郢、油坊新城等可搜到）
        for pl in placeLabels { pool.insert(pl.name) }
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            // 空输入：收藏 ⭐ 优先，其次历史
            var ordered: [String] = []
            for n in favorites.values where !ordered.contains(n) { ordered.append(n) }
            for h in searchHistory where !ordered.contains(h) { ordered.append(h) }
            for x in pool where !ordered.contains(x) { ordered.append(x) }
            return Array(ordered.prefix(10))
        }
        var matched = pool.filter { fuzzyMatch($0, q) }.map { $0 }
        // 收藏点位命中置顶（⭐ 前缀由界面渲染，数据保持原名可点击）
        let favHits = favorites.values.filter { fuzzyMatch($0, q) && !matched.contains($0) }
        matched = Array(favHits) + matched
        if matched.isEmpty {
            matched = ["🔍 在线搜索「\(q)」"]
        }
        // v2.34 导航态沿途 POI 优先（对比高德：导航中联想先把顺路的排前，避免搜出反方向目的地）
        if navigating, route.count >= 2 {
            let pos = matched.enumerated().compactMap { idx, n -> (Int, Double)? in
                guard let pl = placeLabels.first(where: { $0.name == n }) else { return nil }
                return (idx, distanceToRouteM(CLLocationCoordinate2D(latitude: pl.lat, longitude: pl.lon)))
            }
            if !pos.isEmpty {
                let orderedIdx = pos.sorted { $0.1 < $1.1 }.map { $0.0 }
                matched = orderedIdx.map { matched[$0] } + matched.enumerated()
                    .filter { !orderedIdx.contains($0.offset) }.map { $0.element }
            }
        }
        return Array(matched.prefix(10))
    }

    /// v2.34 点到当前路线折线的最近距离（沿途排序用；坐标系差异的数百米误差不影响排序方向）
    private func distanceToRouteM(_ c: CLLocationCoordinate2D) -> Double {
        guard route.count >= 2 else { return .greatestFiniteMagnitude }
        var best = Double.greatestFiniteMagnitude
        for i in 0..<(route.count - 1) {
            best = min(best, distToSegment(c, route[i], route[i + 1]))
        }
        return best
    }

    /// 保存/清除高德 Key（didSet 自动持久化）
    func setAmapKey(_ k: String) { amapKey = k }

    // MARK: - v2.17 在线搜索的地域约束

    /// 当前城市名缓存（高德 regeo；30 分钟或移动超 20 公里后失效）
    private var cityCache: (name: String, lat: Double, lon: Double, at: Date)?
    /// 取城市失败的时间（网络/限额）：120 秒内不再重试，避免每个定位回调都发一次请求
    private var cityFailAt: Date?

    /// 当前所在城市名（"合肥市"）。取不到就返回空串，调用方按"不限城市"处理。
    func currentCityName() async -> String {
        guard let loc = currentLocation else { return "" }
        if let c = cityCache,
           Date().timeIntervalSince(c.at) < 1800,
           distanceM(CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon), loc) < 20_000 {
            return c.name
        }
        let name = await amapRegeoCity(lat: loc.latitude, lon: loc.longitude)
        if !name.isEmpty {
            cityCache = (name, loc.latitude, loc.longitude, Date())
            cityFailAt = nil
        } else {
            cityFailAt = Date()
        }
        return name
    }

    /// 逆地理只取行政区（extensions=base，比 all 轻很多）
    private func amapRegeoCity(lat: Double, lon: Double) async -> String {
        guard !amapKey.isEmpty else { return "" }
        let (glat, glon) = CoordConv.wgs2gcj(lat, lon)
        var comps = URLComponents(string: "https://restapi.amap.com/v3/geocode/regeo")
        comps?.queryItems = [
            .init(name: "key", value: amapKey),
            .init(name: "location", value: String(format: "%.6f,%.6f", glon, glat)),
            .init(name: "extensions", value: "base"),
        ]
        guard let url = comps?.url else { return "" }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let re = obj["regeocode"] as? [String: Any],
              let ac = re["addressComponent"] as? [String: Any] else { return "" }
        // 直辖市（北京/上海…）的 city 字段是空数组，用 province 顶
        let city = (ac["city"] as? String) ?? ""
        let prov = (ac["province"] as? String) ?? ""
        return city.isEmpty ? prov : city
    }

    /// 高德「输入提示」联想：输入关键字实时返回 POI 候选（名称+副标题+精确坐标）
    ///
    /// v2.17 修复「搜到外地去了」：旧版请求只带 `datatype=all`，既没有 `city` 也没有 `location`，
    /// 高德就按全国库返回（且顺序与距离无关）；本地再按距离排序，最近的一条也有 500 多公里。
    /// 现在分四步收敛，绝大多数关键词在第 1 步就命中本市结果：
    ///   1) 本市内联想（city + citylimit=true）
    ///   2) 本市没有 → 放开城市但带上 location（高德按距离给结果），本地再剔掉外地条目
    ///   3) 还没有 → 本市关键词检索 place/text（覆盖比 inputtips 全）
    ///   4) 仍没有 → 当前位置周边 30 公里搜索
    func amapInputTips(_ q: String) async -> [AmapTip] {
        let query = q.trimmingCharacters(in: .whitespaces)
        guard !amapKey.isEmpty, !query.isEmpty else { return [] }
        let anchor = currentLocation
        let city = await currentCityName()

        var tips = await amapInputTipsRaw(query, anchor: anchor, city: city, cityLimit: true)

        // v2.25 关键修正：citylimit=true 命中"非空"不代表用户想要的结果。
        // 典型case（实测）：搜"吴圩镇" —— 真正的吴圩镇在**滁州市定远县**，
        // 但 citylimit=true 时高德只返回合肥市内的三个同名村/路
        // （肥西"吴圩"、长丰"吴圩"、蜀山"吴圩"），名称都不是用户搜的"吴圩镇"。
        // 旧逻辑只看"是否为空"，于是到此为止，用户永远看不到真正的吴圩镇。
        //
        // 现在：如果城市内结果里**没有一条名称包含关键词**（例如搜"吴圩镇"，
        // 结果全是"吴圩"），就认为"本市没这个点"，继续去全国范围找，
        // 两边合并后再排序（精确命中的排前面，同名的按距离排后面）。
        if !tips.contains(where: { $0.name.contains(query) }) {
            let wider = await amapInputTipsRaw(query, anchor: anchor, city: city, cityLimit: false)
            for t in wider where !tips.contains(where: { $0.id == t.id }) {
                tips.append(t)
            }
        }
        if tips.isEmpty, !city.isEmpty {
            tips = await amapTextSearch(query, city: city, anchor: anchor)
        }
        if tips.isEmpty, let a = anchor {
            tips = await amapKeywordSearch(query, lat: a.latitude, lon: a.longitude,
                                           radius: 30000, distanceNote: false)
        }
        // v2.90 补搜"建制镇"：高德 inputtips 对"吴圩"这类地名只做字符串模糊匹配，
        // 返回同名的村/路（吴小圩、吴大圩、吴圩、吴圩村），**不会返回真正的"吴圩镇"** ——
        // 因为"镇"是行政建制名，不在它的匹配口径里。
        // 所以当地名式关键词（2~4 个汉字、本身不带建制后缀）在当前结果里
        // 没有"名称等于它或名称以它开头"的条目时，追加一次 "<关键词>镇" 检索，
        // 把真正的建制镇带回来参与排序。
        let placeSuffixes = ["镇", "村", "街道", "路", "街"]
        let looksLikePlaceName = (2...4).contains(query.count)
            && !placeSuffixes.contains(where: { query.hasSuffix($0) })
        if looksLikePlaceName,
           !tips.contains(where: { $0.name == query || $0.name.hasPrefix(query) }) {
            let richer = await amapInputTipsRaw(query + "镇", anchor: anchor, city: city, cityLimit: false)
            for t in richer where !tips.contains(where: { $0.id == t.id }) {
                tips.append(t)
            }
        }
        return rankTips(tips, anchor: anchor, keyword: query)
    }

    /// inputtips 请求本体（city/location 都按高德要求传 GCJ 坐标与城市名）
    private func amapInputTipsRaw(_ q: String, anchor: CLLocationCoordinate2D?,
                                  city: String, cityLimit: Bool) async -> [AmapTip] {
        var items: [URLQueryItem] = [
            .init(name: "key", value: amapKey),
            .init(name: "keywords", value: q),
            .init(name: "datatype", value: "all"),
        ]
        if let a = anchor {
            let (glat, glon) = CoordConv.wgs2gcj(a.latitude, a.longitude)
            items.append(.init(name: "location", value: String(format: "%.6f,%.6f", glon, glat)))
        }
        if !city.isEmpty {
            items.append(.init(name: "city", value: city))
            if cityLimit { items.append(.init(name: "citylimit", value: "true")) }
        }
        var comps = URLComponents(string: "https://restapi.amap.com/v3/assistant/inputtips")
        comps?.queryItems = items
        guard let url = comps?.url else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tips = obj["tips"] as? [[String: Any]] else { return [] }
        var out: [AmapTip] = []
        for t in tips {
            guard let name = t["name"] as? String, !name.isEmpty,
                  let loc = t["location"] as? String, !loc.isEmpty else { continue }
            let parts = loc.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { continue }
            // v2.25 inputtips 字段解析修正：
            // 高德这个接口的字段类型很坑 ——
            //   address 常常是**空数组 []**（不是字符串），有值时才是字符串；
            //   district 在部分条目里也是数组；
            //   type 字段**根本不存在**（只有数字型的 typecode）。
            // 旧代码一律 `as? String`，于是 address/type 恒为 nil，
            // 副标题全部退化成"地点" —— 这就是"搜出来一些奇怪的地址"的直接原因。
            let addr = Self.tipString(t["address"])
            let district = Self.tipString(t["district"])
            var sub = ""
            if !addr.isEmpty { sub += addr }
            if !district.isEmpty { sub += (sub.isEmpty ? "" : " · ") + district }
            if sub.isEmpty { sub = "地点" }
            // v1.98 高德给的是 GCJ-02，转 WGS 后与地图/路线同一口径（否则点搜索结果会偏 500 米）
            let (wlat, wlon) = CoordConv.gcj2wgs(parts[1], parts[0])
            out.append(AmapTip(name: name, sub: sub, lat: wlat, lon: wlon))
        }
        return Array(out.prefix(20))
    }

    /// v2.25 inputtips 字段取值：字段可能是字符串、也可能是空数组（甚至数字）
    /// 统一转成可读字符串，取不到返回空串
    private static func tipString(_ any: Any?) -> String {
        guard let any else { return "" }
        if let s = any as? String { return s }
        if let arr = any as? [String] {
            // 空数组 → 空串；有值时取第一个非空项（高德多给一个 ["合肥市"] 之类的数组）
            for x in arr where !x.isEmpty { return x }
            return ""
        }
        if let arr = any as? [Any] {
            let parts = arr.compactMap { $0 as? String }.filter { !$0.isEmpty }
            return parts.joined(separator: "")
        }
        if let n = any as? Int { return String(n) }
        return ""
    }

    /// 城市内关键词检索（place/text）：inputtips 偏"输入联想"，覆盖不全时用它兜底
    private func amapTextSearch(_ q: String, city: String,
                                anchor: CLLocationCoordinate2D?) async -> [AmapTip] {
        var items: [URLQueryItem] = [
            .init(name: "key", value: amapKey),
            .init(name: "keywords", value: q),
            .init(name: "city", value: city),
            .init(name: "citylimit", value: "true"),
            .init(name: "offset", value: "25"),
            .init(name: "page", value: "1"),
            .init(name: "extensions", value: "base"),
        ]
        if let a = anchor {
            let (glat, glon) = CoordConv.wgs2gcj(a.latitude, a.longitude)
            items.append(.init(name: "location", value: String(format: "%.6f,%.6f", glon, glat)))
        }
        var comps = URLComponents(string: "https://restapi.amap.com/v3/place/text")
        comps?.queryItems = items
        guard let url = comps?.url else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pois = obj["pois"] as? [[String: Any]] else { return [] }
        var out: [AmapTip] = []
        for p in pois {
            guard let name = p["name"] as? String, !name.isEmpty,
                  let loc = p["location"] as? String, !loc.isEmpty else { continue }
            let parts = loc.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { continue }
            let addr = p["address"] as? String ?? ""
            var sub = addr
            if sub.isEmpty || sub == "[]" { sub = p["type"] as? String ?? "地点" }
            let (wlat, wlon) = CoordConv.gcj2wgs(parts[1], parts[0])
            out.append(AmapTip(name: name, sub: sub, lat: wlat, lon: wlon))
        }
        return out
    }

    /// 结果收敛：去重 → 按距离升序 → 把明显在外地的条目剔掉（只剩外地时就保留最近的几条）
    private func rankTips(_ tips: [AmapTip], anchor: CLLocationCoordinate2D?,
                          keyword: String = "") -> [AmapTip] {
        var seen = Set<String>()
        var rows: [(AmapTip, Double, Int)] = []
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        for t in tips {
            guard seen.insert(t.id).inserted else { continue }
            let d = anchor.map {
                distanceM($0, CLLocationCoordinate2D(latitude: t.lat, longitude: t.lon))
            } ?? 0
            // v2.25 精确命中优先：名称里包含关键词的排在前面。
            // 搜"吴圩镇"时，高德会先返回合肥的"吴圩"（同名村），
            // 不做这一步的话用户看到的第一条就是错的那个。
            // v2.90 从"两级（含/不含）"改成"四级"：
            //   0 名称与关键词完全相同（"吴圩"）
            //   1 名称以关键词开头（"吴圩镇" / "吴圩村"）
            //   2 名称包含关键词（"老吴圩桥"）
            //   3 其他（"吴小圩""吴大圩" 这类高德的字序模糊匹配）
            // 旧的二级排序里 "吴小圩" 因为不含"吴圩"直接被扔到"其他"，
            // 却又靠距离最近排在第一屏，看起来就像"搜吴圩给了个吴小圩"。
            let rank = AppModel.nameMatchRank(t.name, kw)
            rows.append((t, d, rank))
        }
        guard anchor != nil else { return rows.map { $0.0 } }
        // 排序：名称匹配等级优先 → 距离近优先
        rows.sort { a, b in
            if a.2 != b.2 { return a.2 < b.2 }
            return a.1 < b.1
        }
        // v2.25 距离过滤放宽：**精确命中（名称含关键词）的条目不受距离限制**。
        // 用户搜"吴圩镇"（在滁州定远县，距合肥 55~68km；若人在更远的城市可能超 100km）
        // 就是明确要那个地方，不能因为"跨市"就把它从列表里抹掉。
        // 非精确命中的条目仍按 100km 过滤，避免外地无关 POI 挤进列表。
        let exactRows = rows.filter { $0.2 <= 2 }
        let otherRows = rows.filter { $0.2 > 2 && $0.1 <= 100_000 }
        var kept = exactRows + otherRows
        if kept.isEmpty {
            // 全都超距（且无精确命中）→ 退而取最近的 10 条，别让列表空掉
            kept = Array(rows.prefix(10))
        }
        return kept.map { $0.0 }
    }

    /// v2.90 名称与关键词的匹配等级（数字越小越精确）
    static func nameMatchRank(_ name: String, _ kw: String) -> Int {
        if kw.isEmpty { return 3 }
        if name == kw { return 0 }
        if name.hasPrefix(kw) { return 1 }
        if name.contains(kw) { return 2 }
        return 3
    }

    /// 右下角定位按钮：地图回中
    func centerOnUser() {
        locateTick += 1
    }


    /// v1.81 高德逆地理：道路描述 + 区域（AOI）名称与多边形（extensions=all）
    func amapRegeoInfo(lat: Double, lon: Double) async -> (road: String?, aoiName: String?, polygon: [CLLocationCoordinate2D]?) {
        guard !amapKey.isEmpty else { return (nil, nil, nil) }
        // v1.98 入参 WGS-84 → 高德要 GCJ-02；AOI 多边形返回后转回 WGS 再画
        let (glat, glon) = CoordConv.wgs2gcj(lat, lon)
        let loc = String(format: "%.6f,%.6f", glon, glat)
        guard let url = URL(string: "https://restapi.amap.com/v3/geocode/regeo?key=\(amapKey)&location=\(loc)&extensions=all") else { return (nil, nil, nil) }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let re = obj["regeocode"] as? [String: Any] else { return (nil, nil, nil) }
            let faddr = re["formatted_address"] as? String ?? ""
            var roads: [String] = []
            if let rs = re["roads"] as? [[String: Any]] {
                for r in rs.prefix(3) {
                    if let n = r["name"] as? String, !n.isEmpty { roads.append(n) }
                }
            }
            var road: String?
            if roads.count >= 2 {
                road = "\(roads[0])与\(roads[1])附近"
            } else if let r0 = roads.first {
                road = "\(r0)附近"
            } else if !faddr.isEmpty {
                road = faddr
            }
            // 区域范围（AOI）：优先取覆盖该点面积最大的 aoi 多边形
            var aoiName: String?
            var polygon: [CLLocationCoordinate2D]?
            if let aois = re["aois"] as? [[String: Any]], !aois.isEmpty {
                var bestCount = 0
                for a in aois {
                    guard let poly = a["polyline"] as? String, !poly.isEmpty else { continue }
                    var pts: [CLLocationCoordinate2D] = []
                    for pair in poly.split(separator: ";") {
                        let parts = pair.split(separator: ",").compactMap { Double($0) }
                        if parts.count == 2 {
                            let (wlat, wlon) = CoordConv.gcj2wgs(parts[1], parts[0])
                            pts.append(CLLocationCoordinate2D(latitude: wlat, longitude: wlon))
                        }
                    }
                    if pts.count > bestCount {
                        bestCount = pts.count
                        aoiName = a["name"] as? String
                        polygon = pts
                    }
                }
            }
            return (road, aoiName, polygon)
        } catch {
            return (nil, nil, nil)
        }
    }

    /// v1.95 轻点地图：逆地理编码取地点名称/地址/类型（地点介绍卡数据源）
    /// 与 amapRegeoInfo 的区别是在同一请求里额外解析 pois[]，用来给出"这是什么地方"而不是只给道路名
    func amapTapPlace(lat: Double, lon: Double) async -> (name: String, address: String, type: String, road: String)? {
        guard !amapKey.isEmpty else { return nil }
        // v1.98 入参是地图/定位的 WGS-84，高德接口要 GCJ-02，请求前转换
        let (glat, glon) = CoordConv.wgs2gcj(lat, lon)
        let loc = String(format: "%.6f,%.6f", glon, glat)
        let urlStr = "https://restapi.amap.com/v3/geocode/regeo?key=\(amapKey)&location=\(loc)&extensions=all&radius=200&roadlevel=0"
        guard let url = URL(string: urlStr) else { return nil }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let re = obj["regeocode"] as? [String: Any] else { return nil }

            let addr = re["formatted_address"] as? String ?? ""

            // v1.98 名称取"离点击点最近"的 POI（高德 pois[].distance 单位米），
            // 超过 120 米就不用它——否则点了 A 地，卡片会显示旁边 B 店的名字
            var name = ""
            var typeName = ""
            if let pois = re["pois"] as? [[String: Any]] {
                let sorted = pois.compactMap { p -> (String, String, Double)? in
                    guard let n = p["name"] as? String, !n.isEmpty else { return nil }
                    let raw = (p["type"] as? String) ?? ""
                    let t = raw.split(separator: ";").last.map(String.init) ?? raw
                    let d = Double((p["distance"] as? String) ?? "9999") ?? 9999
                    return (n, t, d)
                }.sorted { $0.2 < $1.2 }
                if let best = sorted.first, best.2 <= 120 {
                    name = best.0
                    typeName = best.1
                }
            }
            if name.isEmpty, let aois = re["aois"] as? [[String: Any]], let a0 = aois.first {
                let n = (a0["name"] as? String) ?? ""
                if !n.isEmpty {
                    name = n
                    let raw = (a0["type"] as? String) ?? ""
                    typeName = raw.split(separator: ";").last.map(String.init) ?? raw
                }
            }
            if name.isEmpty && addr.isEmpty { return nil }

            var road = ""
            if let rs = re["roads"] as? [[String: Any]] {
                // 多条道路时取最近的一条（高德按距离升序返回 roads）
                for r in rs {
                    if let n = r["name"] as? String, !n.isEmpty { road = n; break }
                }
            }
            return (name.isEmpty ? "地图选点" : name, addr, typeName, road)
        } catch {
            return nil
        }
    }

    /// 规划到任意目的地（起点/终点自动吸附到最近道路出入口）
    func planRoute(to name: String, lat: Double, lon: Double) {
        if cruiseMode { exitCruise() }   // v2.33 巡航中规划：退出巡航，避免顶部巡航卡与规划卡并存
        guard let start = resolvedOrigin else {
            status = "请先定位后再规划路线"
            return
        }
        destName = name; destLat = lat; destLon = lon
        addHistory(name)
        status = "正在规划到「\(name)」…"
        let from = start
        let rawEnd = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        Task {
            // v1.98 与 fetchRouteChoices 对齐：直接用高德多方案（不再走 OSRM 吸附），
            // 取推荐方案作为当前路线，方案列表一并保留供切换
            let rawChoices = await RouteFetcher.fetchAll(from: from, to: rawEnd, amapKey: amapKey,
                                                          via: self.waypointCoords)
            let choices = self.preferMotoRoutes(rawChoices)
            if let r = choices.first {
                if choices.count > 1 {
                    routeChoices = choices.map { c -> RouteChoice in
                        RouteChoice(points: c.points, distanceM: c.distanceM, durationS: c.durationS,
                                    turns: c.turns, label: c.label,
                                    traffic: c.traffic,
                                    trafficLights: c.trafficLights)
                    }
                    selectedRouteIdx = 0
                }
                route = r.points
                routeTurns = r.turns
                routeDistanceM = r.distanceM
                routeDurationS = r.durationS
                lastTurnSpoken = -1
                farAnnounced.removeAll()
                closeAnnounced.removeAll()
                // v2.46 P1 重路由后同步清空 v2.43 的转后确认/拥堵提示去重状态：
                // 新路线转向序号与旧路线重叠时，旧去重记录会让新路线的
                // 转弯后确认/拥堵提示静默失效
                turnConfirmSet.removeAll()
                trafficAheadSpoken = false
                fitTick += 1
                riderRisks = RiderAnalyzer.risks(r.turns, totalM: r.distanceM)
                trafficSpans = r.traffic
                trafficLights = TrafficLightBuilder.lights(turns: r.turns)
                status = routeSummary(name, distanceM: r.distanceM, durationS: r.durationS)
            } else {
                fallbackStraightLine(from: from, to: rawEnd, name: name, lat: lat, lon: lon)
            }
        }
    }

    /// 路线服务不可用时的兜底：画直线示意 + 明确提示（可能横穿禁行区） + 3秒后自动重试
    private func fallbackStraightLine(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D,
                                      name: String, lat: Double, lon: Double, walkLeg: [CLLocationCoordinate2D] = []) {
        route = walkLeg.isEmpty ? [from, to] : walkLeg + [to]
        routeTurns = []
        routeDistanceM = 0
        routeDurationS = 0
        actualTripM = 0
        routeChoices = []
        trafficLights = []
        fitTick += 1
        status = "路线服务不可用，直线仅为示意（可能横穿不可通行区域），正在自动重试…"
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            // 目的地未变才替换（用户可能已改目标）
            guard self.destName == name, self.destLat == lat, self.destLon == lon else { return }
            let retry = await RouteFetcher.fetchAll(from: from, to: to, amapKey: amapKey,
                                                    via: self.waypointCoords)
            if retry.isEmpty { return }
            let list = retry.map { c -> RouteChoice in
                return RouteChoice(points: c.points, distanceM: c.distanceM,
                                   durationS: c.durationS, turns: c.turns,
                                   label: c.label, traffic: c.traffic,
                                   trafficLights: c.trafficLights)
            }
            // v2.94 修复：切回主线程再更新 UI 状态
            DispatchQueue.main.async {
                self.routeChoices = list
                self.selectedRouteIdx = 0
                self.applyRouteChoice(list[0], name: name)
                self.status = "路线已恢复，请选择方案或开始导航"
            }
        }
    }

    /// 路线摘要文字（高德式：短距离显示米、短时间显示"1分钟内"，避免"0.0公里/0分钟"）
    /// v2.33 电警点位已移除：不再显示"沿途抓拍点 N 处"
    private func routeSummary(_ name: String, distanceM: Int, durationS: Int) -> String {
        let distTxt = distanceM < 1000 ? "\(distanceM)米" : String(format: "%.1f公里", Double(distanceM) / 1000.0)
        let timeTxt = durationS < 60 ? "1分钟内" : "\(durationS / 60)分钟"
        return "到「\(name)」约\(distTxt)，预计\(timeTxt)"
    }

    func clearRoute() {
        navigating = false
        UIApplication.shared.isIdleTimerDisabled = false
        navigateFollowTick += 1
        route = []
        routeTurns = []
        routeChoices = []
        trafficLights = []
        routeDistanceM = 0
        routeDurationS = 0
        lastTurnSpoken = -1
        farAnnounced.removeAll()
        endLiveActivity()
        status = "已清除路线"
    }

    /// v2.23 地点卡「导航」直达：直接进入导航，**不经过路线规划界面**
    ///
    /// 旧实现走 fetchRouteChoices(autoStart: true)：那个方法会先把方案列表写进
    /// `routeChoices`，而 bottomOverlay 用 `!model.routeChoices.isEmpty` 判断是否渲染
    /// 路线规划卡（上下两张）→ 于是规划卡先闪出来，0.4 秒后才切进导航，
    /// 用户体感就是"点导航先进入路线规划界面"。
    ///
    /// 现在改成：
    ///   1) 只取方案列表的第一条（推荐）填入 route / routeTurns 等导航必需字段；
    ///   2) **不写 routeChoices**（规划卡因此完全不渲染），choiceRoutes 为空也不画备选线；
    ///   3) 直接 toggleNavigation() 进导航，地图由导航跟随接管（不做全览 fit）。
    ///   4) 万一高德没算出路线（choices 为空），退回规划模式让用户看到提示并可重试。
    func navigateDirect(to name: String, lat: Double, lon: Double) {
        guard let start = resolvedOrigin else {
            status = "请先定位后再导航"
            return
        }
        destName = name; destLat = lat; destLon = lon
        addHistory(name)
        status = "正在规划到「\(name)」…"
        let rawEnd = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        Task {
            let choices = await RouteFetcher.fetchAll(from: start, to: rawEnd, amapKey: amapKey,
                                                      via: self.waypointCoords)
            if choices.isEmpty {
                // 没算出路线：退回规划模式（显示兜底直线 + 3 秒自动重试），不进入导航
                fallbackStraightLine(from: start, to: rawEnd, name: name, lat: lat, lon: lon)
                status = "路线服务暂时不可用，已切回规划模式，可稍后重试"
                return
            }
            let list = self.preferMotoRoutes(choices)
            guard let best = list.first else {
                fallbackStraightLine(from: start, to: rawEnd, name: name, lat: lat, lon: lon)
                return
            }
            // 只填导航必需字段（routeChoices 保持为空 → 规划卡不渲染）
            self.route = best.points
            self.routeTurns = best.turns
            self.routeDistanceM = best.distanceM
            self.routeDurationS = best.durationS
            self.lastTurnSpoken = -1
            self.farAnnounced.removeAll()
            self.riskSpokenStage.removeAll()
            self.riderRisks = RiderAnalyzer.risks(best.turns, totalM: best.distanceM)
            self.trafficSpans = best.traffic
            self.trafficLights = TrafficLightBuilder.lights(turns: best.turns)
            self.status = self.routeSummary(name, distanceM: best.distanceM,
                                            durationS: best.durationS)
            // 直接进导航（导航跟随会接管相机，不做路线全览）
            // v2.94 修复：异步回调里直接改 @Published 状态有时 UI 不刷新（"有时候进不去导航"），
            // 必须切回主线程再更新 UI 状态
            DispatchQueue.main.async {
                self.toggleNavigation()
            }
        }
    }

    /// "去这里/导航到这里"触发：获取多路线方案（起点=当前定位点，终点吸附到最近道路出入口）
    /// autoStart=true 时路线就绪后自动进入导航（地点信息卡"导航"按钮）
    func fetchRouteChoices(to name: String, lat: Double, lon: Double, autoStart: Bool = false) {
        if cruiseMode { exitCruise() }   // v2.33 巡航中规划：退出巡航，避免顶部巡航卡与规划卡并存
        guard let start = resolvedOrigin else {
            status = "请先定位后再规划路线"
            return
        }
        destName = name; destLat = lat; destLon = lon
        addHistory(name)
        status = "正在规划到「\(name)」…"
        let from = start
        let rawEnd = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        Task {
            defer { self.swapInFlight = false }  // v2.34 交换规划结束（成功/失败/降级）都解锁
            // v1.98 不再用 OSRM 做起点吸附/步行连接：OSM 路网与高德底图不同源，
            // 吸附点常落到高德认不出的路上，表现为"路线起点悬空、整条线压不到路"。
            // 高德规划接口本身会把起终点吸附到可通行道路，直接传原始坐标最稳。
            let choices = await RouteFetcher.fetchAll(from: from, to: rawEnd, amapKey: amapKey,
                                                      via: self.waypointCoords)
            if choices.isEmpty {
                // v2.29 降级：第一次规划失败且还有途经点 → 去掉途经点再试一次
                // （起终点互换后途经点顺序/位置最容易导致高德直接失败）
                if !self.degradedPlan, !self.waypoints.isEmpty {
                    self.replanWithoutWaypoints(reason: "反向规划失败")
                    return
                }
                self.degradedPlan = false
                fallbackStraightLine(from: from, to: rawEnd, name: name, lat: lat, lon: lon, walkLeg: [])
            } else {
                // 规划成功 → 清除降级标记
                self.degradedPlan = false
                // 高德式：默认选中推荐方案并画路线，卡片可切换，底部绿色"开始导航"
                let list = self.preferMotoRoutes(choices).map { c -> RouteChoice in
                    return RouteChoice(points: c.points, distanceM: c.distanceM,
                                       durationS: c.durationS, turns: c.turns,
                                       label: c.label, traffic: c.traffic,
                                   trafficLights: c.trafficLights)
                }
                // v2.94 修复：异步回调里直接改 routeChoices 有时 UI 不刷新（"有时候进不去规划页"），
                // 切回主线程再更新 UI 状态
                DispatchQueue.main.async {
                    self.routeChoices = list
                    self.selectedRouteIdx = 0
                    self.applyRouteChoice(list[0], name: name)
                }
                // v1.81 直达导航：方案就绪后自动进入导航
                if autoStart {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        guard let self = self, self.route.count >= 2 else { return }
                        if !self.navigating { self.toggleNavigation() }
                    }
                }
            }
        }
    }

    /// v1.63 导航中手动刷新：按当前终点重新规划并保持导航
    func refreshRoute() {
        guard destLat != 0 || destLon != 0 else {
            status = "暂无路线可刷新"
            return
        }
        status = "正在刷新路线…"
        let wasNavigating = navigating
        fetchRouteChoices(to: destName, lat: destLat, lon: destLon)
        if wasNavigating {
            speak("路线已重新规划", priority: 2)
        }
    }

    /// 应用所选路线方案（地图严格绘制该方案折线；方案列表保留供切换/开始导航）
    func applyRouteChoice(_ c: RouteChoice, name: String? = nil) {
        guard !c.points.isEmpty else { return } // v2.31 防呆：空方案不应用
        let n = name ?? destName
        route = c.points
        routeTurns = c.turns
        routeDistanceM = c.distanceM
        routeDurationS = c.durationS
        lastTurnSpoken = -1
        farAnnounced.removeAll()
        turnConfirmSet.removeAll()
        trafficAheadSpoken = false
        fitTick += 1
        // v1.99 骑行风险 + 路况（切方案时同步刷新）
        riderRisks = RiderAnalyzer.risks(c.turns, totalM: c.distanceM)
        trafficSpans = c.traffic
        trafficLights = TrafficLightBuilder.lights(turns: c.turns)
        riskSpokenStage.removeAll()
        status = routeSummary(n, distanceM: c.distanceM, durationS: c.durationS)
        if !riderRisks.isEmpty {
            let blocked = riderRisks.contains { $0.kind.motoBlocked }
            status += "；" + (blocked ? "⚠️ 含禁摩风险路段：" : "注意：") + RiderAnalyzer.summary(riderRisks)
        }
    }

    /// 筛选距路线折线 130 米内的点位

    /// 点 p 到线段 ab 的垂直距离（局部平面近似，米）
    private func distToSegment(_ p: CLLocationCoordinate2D, _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let cosLat = cos(a.latitude * .pi / 180.0)
        let x1 = (b.longitude - a.longitude) * 111320.0 * cosLat
        let y1 = (b.latitude - a.latitude) * 110540.0
        let xp = (p.longitude - a.longitude) * 111320.0 * cosLat
        let yp = (p.latitude - a.latitude) * 110540.0
        let len2 = x1 * x1 + y1 * y1
        if len2 <= 0 { return hypot(xp, yp) }
        let t = min(max((xp * x1 + yp * y1) / len2, 0), 1)
        let cx = t * x1, cy = t * y1
        return hypot(xp - cx, yp - cy)
    }

    // MARK: - 实时导航播报

    func toggleNavigation() {
        if navigating {
            navigating = false
            UIApplication.shared.isIdleTimerDisabled = false // 恢复自动锁屏
            pitchDeg = 0          // v2.01 退出导航回 2D 平视
            navigateFollowTick += 1
            navUserMoved = false
            // v2.34 退出导航保留路线推荐卡（高德式：回到路线预览页，起终点/换路线仍可操作）；
            // 轻点卡片外任意处或左滑仍可关闭回首页（closeRoutePlan）
            selectedRouteIdx = 0
            navStatusCache = nil // v2.28 清缓存，避免下次进入导航时先显示上一条路线的余量
            finishTrip()
            endLiveActivity()
            speak("导航结束")
            status = "导航已结束"
        } else {
            guard route.count >= 2 else { status = "请先搜索目的地并规划路线"; return }
            navigating = true
            // v2.13：平时 heading 不更新，进入导航先把当前朝向补上，避免地图一开就转到正北
            heading = compass.angle
            UIApplication.shared.isIdleTimerDisabled = true // 导航中屏幕常亮（高德式）
            pitchDeg = 45         // v2.01 开始导航：3D 45° 俯视（视野见 MapView）
            // v2.49 起步视野按当前速度直接定档
            // （旧版先写死 50、再被自动切档改掉，开导航瞬间地图要跳两次）
            navScaleTarget = autoNavScaleTarget(snap: true)
            navScaleTick += 1
            navUserMoved = false
            navigateFollowTick += 1
            tripSummary = nil // v1.81.4 新导航开始时清除上次行程卡
            navStart = Date()
            // v1.99 轨迹重新开始
            trackPoints.removeAll()
            maxSpeedKph = 0
            riskSpokenStage.removeAll()
            offRouteCount = 0
            arriveAnnounced = false
            startMonitoring()
            // v2.28：立即初始化导航状态缓存。
            // 否则从「点开始导航」到「第一次定位回调」之间（可能有好几百毫秒），
            // 底部导航卡会因为 navStatusCache == nil 而整个不显示 —— 看起来像"点了没反应"。
            navStatusCache = navigationStatus(at: currentLocation)
            // v2.29 顺序调整：先让 UI 状态全部发布出去（navigating 等 @Published 要下个
            // runloop 才生效），**再**做可能阻塞的事。
            //
            // 旧顺序把 startLiveActivity 放在最前面，而 Activity.request 是**同步**的
            // （内部 XPC 到 activitykitd，首次还要冷启动 Widget 扩展），
            // 耗时几百毫秒到数秒。主线程被堵住 → 第一帧导航 UI 根本画不出来 →
            // 用户看到的就是"点了开始导航卡住了"。
            //
            // 这个卡顿是**偶发**的：取决于 activitykitd 守护进程冷热、Widget 扩展是否已加载，
            // 所以用户描述是"有时候点开始导航会卡住"。
            //
            // 现在改成：先发状态 → 下一轮 runloop 再启动 Live Activity，
            // 且用 Task 包裹（不在主线程同步等），并加超时兜底。
            scheduleLiveActivityStart(destName: destName)
            // v2.46 P6 开始导航触感确认：到达已有震动提醒，开始也补一次
            // （戴头盔/手套时看不到屏幕，凭触感确认导航已启动）
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            // v2.44 N3 开始导航加全程概览（高德式）：全程X公里，预计X分钟
            let km = String(format: "%.1f", Double(max(routeDistanceM, 0)) / 1000.0)
            let min = max(routeDurationS, 0) / 60
            speak("开始导航到\(destName)，全程\(km)公里，预计\(min)分钟，请按路线行驶")
            status = "导航中 → \(destName) · 户外可调亮屏幕看路口"
        }
    }

    // MARK: - Live Activity（灵动岛/锁屏违拍提醒）

    /// 开始导航 → 启动灵动岛活动
    private func startLiveActivity(destName: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attr = MotoNavAttributes(destName: destName)
        let initial = MotoNavAttributes.ContentState(phase: "cruising", title: "已出发", detail: "去往 \(destName)", distanceM: 0, icon: "")
        do {
            liveActivity = try Activity<MotoNavAttributes>.request(
                attributes: attr, contentState: initial, pushType: nil)
        } catch {
            liveActivity = nil
        }
    }

    /// 到达/退出导航/清空路线 → 结束灵动岛活动
    private func endLiveActivity() {
        guard let act = liveActivity else { return }
        liveActivity = nil
        Task {
            await act.end(using: nil, dismissalPolicy: .immediate)
        }
    }

    /// v2.36 F2 导航中灵动岛/锁屏实时刷新：剩余距离驱动（节流见调用处）。
    /// 锁屏卡展示"导航中 / 去往X / Nm"，不再是一成不变的 0m。
    private func updateLiveActivity(remainM: Int) {
        guard let act = liveActivity, navigating else { return }
        // v2.47 Q1 锁屏 detail 随状态升级（phase 保持 cruising，Widget 渲染分支稳定）：
        // 偏航中 → 已偏航提示；剩余 <500m → 即将到达；否则 → 去往目的地
        var detail: String
        if offRouteCount > 0 {
            detail = "已偏航，正在重新规划"
        } else if remainM < 500 {
            detail = destName.isEmpty ? "即将到达目的地" : "即将到达：\(destName)"
        } else {
            detail = destName.isEmpty ? "去往目的地" : "去往 \(destName)"
        }
        let state = MotoNavAttributes.ContentState(
            phase: "cruising", title: "导航中",
            detail: detail,
            distanceM: remainM, icon: "")
        Task {
            try? await act.update(using: state)
        }
    }

    /// v2.32 冷启动清理残留：App 被上滑清除后系统仍会保留灵动岛显示，
    /// 下次打开 App 时把所有遗留活动立即结束（上滑清除无系统回调，只能冷启动兜底）。
    private func cleanupStaleLiveActivities() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        liveActivity = nil
        for activity in Activity<MotoNavAttributes>.activities {
            Task { await activity.end(dismissalPolicy: .immediate) }
        }
    }

    /// 行程总结（到达或退出导航时生成）
    private func finishTrip() {
        guard let start = navStart else { return }
        let dur = Int(Date().timeIntervalSince(start))
        // v2.38 H1 行程卡用实际行驶距离（无实际记录时回退规划距离）：
        // 偏航/绕路时真实里程不会被高德规划值压低
        let shownM = actualTripM > 0 ? Int(actualTripM) : routeDistanceM
        let avg = dur > 0 ? (Double(shownM) / 1000.0) / (Double(dur) / 3600.0) : 0
        tripSummary = TripSummary(
            destName: destName,
            distanceM: shownM,
            durationS: dur,
            avgSpeedKmh: avg,
            startAt: start)
        // v1.99 足迹存档：轨迹抽稀后写入本地（里程过短不记）
        let pts = trackPoints.count >= 2 ? trackPoints : route
        FootprintStore.shared.add(Footprint(
            destName: destName,
            startedAt: start,
            distanceM: shownM,
            durationS: dur,
            avgSpeed: avg,
            maxSpeed: maxSpeedKph,
            points: TrackSimplifier.simplify(pts)))
        navStart = nil
        trackPoints.removeAll()
    }

    /// 偏离路线检测：距路线折线 >80m 连续 3 次且距上次重规划 >25s → 自动重规划并播报
    private func rerouteIfOffTrack(at coord: CLLocationCoordinate2D) {
        guard navigating, route.count >= 2 else { offRouteCount = 0; return }
        // v2.28 性能：旧版每次定位都遍历整条路线的所有线段（可达 2000 段），
        // 每段一次 distToSegment（含 cos/hypot）→ 每次定位 2000 次三角函数运算。
        // 导航中定位是高频的（移动 2 米就回调一次），这是"导航时地图发涩"的一大来源。
        //
        // 现在只算最近点附近的线段：最近折线点索引由 nearestRouteIndex 增量维护，
        // 偏航检测要判断的"离路线多远"，用最近点前后各 10 段足够
        // （真正偏航 80 米以上时，最近点索引也已经同步更新了）。
        let center = min(idxCache, route.count - 1)
        let lo = max(0, center - 10)
        let hi = min(route.count - 2, center + 10)
        var minD = Double.greatestFiniteMagnitude
        for i in lo...hi {
            let d = distToSegment(coord, route[i], route[i + 1])
            if d < minD { minD = d }
        }
        offRouteCount = (minD > 80) ? offRouteCount + 1 : 0
        guard offRouteCount >= 3, Date().timeIntervalSince(lastReroute) > 25 else { return }
        offRouteCount = 0
        lastReroute = Date()
        guard let start = currentLocation else { return }
        Task {
            // v1.98 偏航重规划也走高德（与规划同源），不再用 OSRM 吸附终点
            let dest = CLLocationCoordinate2D(latitude: destLat, longitude: destLon)
            let choices = await RouteFetcher.fetchAll(from: start, to: dest, amapKey: amapKey,
                                                      via: self.waypointCoords)
            // v2.36 F4 重规划成功才播报；失败（无网/超时返回空）如实提示，不再"假成功"
            if let r = choices.first {
                // v2.93 偏航提示优化：更明确，和高德对齐
            speak("偏航，正在重新规划路线，请按新路线行驶")
                status = "路线已重新规划，请按新路线行驶"
                route = r.points
                route = r.points
                routeTurns = r.turns
                routeDistanceM = r.distanceM
                routeDurationS = r.durationS
                lastTurnSpoken = -1
                farAnnounced.removeAll()
                closeAnnounced.removeAll()
                fitTick += 1
                // v1.99 偏航重规划后风险/路况同步刷新
                riderRisks = RiderAnalyzer.risks(r.turns, totalM: r.distanceM)
                trafficSpans = r.traffic
                trafficLights = TrafficLightBuilder.lights(turns: r.turns)
            } else {
                status = "重新规划失败，请检查网络后重试"
            }
        }
    }

    // MARK: - v1.99 摩托优先 / 风险播报 / 途经点 / 沿途服务

    /// 方案排序：开启"避开高速/高架"时按禁摩风险排序，并把首条标为"推荐"
    func preferMotoRoutes(_ list: [RouteChoice]) -> [RouteChoice] {
        guard !list.isEmpty else { return [] }
        var ordered = list

        // v2.28 出行方式影响排序权重：
        // · 摩托车：禁摩路段是硬约束 —— 宁可多绕 2 分钟也不能穿过禁摩段，
        //   所以禁摩风险权重给得最高（原来只在 avoidHighway 时才考虑）。
        // · 汽车：禁摩路段无所谓，主要看用时。
        if travelMode == .moto, list.count > 1 {
            let scored = list.enumerated().map { (idx, c) -> (Int, Int, RouteChoice) in
                let risk = RiderAnalyzer.risks(c.turns, totalM: c.distanceM)
                    .filter { $0.kind.motoBlocked }
                    .reduce(0) { $0 + max(1, $1.lengthM / 800) }
                return (risk, idx, c)
            }
            ordered = scored.sorted { a, b in
                a.0 == b.0 ? a.1 < b.1 : a.0 < b.0
            }.map { $0.2 }
        } else if avoidHighway, list.count > 1 {
            let scored = list.enumerated().map { (idx, c) -> (Int, Int, RouteChoice) in
                let risk = RiderAnalyzer.risks(c.turns, totalM: c.distanceM)
                    .filter { $0.kind.motoBlocked }
                    .reduce(0) { $0 + max(1, $1.lengthM / 800) }
                return (risk, idx, c)
            }
            ordered = scored.sorted { a, b in
                a.0 == b.0 ? a.1 < b.1 : a.0 < b.0
            }.map { $0.2 }
        }

        // v2.28 用户显式偏好（"偏好"菜单里可开）：在推荐位确定后再做二次调整，
        // 因为这两个偏好的定义就是"优先"，所以直接把最优的那条提到第一位。
        if list.count > 1 {
            if preferFewLights {
                // 红绿灯少的优先（trafficLights < 0 表示高德没给数据，不参与比较）
                let withLights = ordered.filter { $0.trafficLights >= 0 }
                if let best = withLights.min(by: { $0.trafficLights < $1.trafficLights }),
                   let idx = ordered.firstIndex(where: { sameRoute($0, best) }) {
                    ordered.insert(best, at: 0)
                    ordered.remove(at: idx + 1)
                }
            } else if preferShortest {
                if let best = ordered.min(by: { $0.distanceM < $1.distanceM }),
                   let idx = ordered.firstIndex(where: { sameRoute($0, best) }) {
                    ordered.insert(best, at: 0)
                    ordered.remove(at: idx + 1)
                }
            }
        }

        let f = ordered[0]
        ordered[0] = RouteChoice(points: f.points, distanceM: f.distanceM, durationS: f.durationS,
                                 turns: f.turns, label: "推荐", traffic: f.traffic,
                                 trafficLights: f.trafficLights)
        return ordered
    }

    /// v2.28 判断两个方案是否是同一条路线（用于偏好调整时的身份比对）
    private func sameRoute(_ a: RouteChoice, _ b: RouteChoice) -> Bool {
        a.distanceM == b.distanceM && a.durationS == b.durationS
            && a.points.count == b.points.count
    }


    /// 导航中：向前 500 米内出现禁摩/隧道/高架等风险段时播报（每段只报一次）
    /// v2.29 已播报过的风险（记录播报到了哪一档）
    private var riskSpokenStage: [String: Int] = [:]

    /// 骑行风险提醒（禁摩/限行/隧道/大桥）
    ///
    /// v2.29 改成**双段式**时机（竞品空白点）：
    /// 调研发现高德只在遇到禁行点时说一句"前方禁摩，已重新规划"，
    /// 百度也只有一次提醒 —— 骑手没有决策窗口。
    ///
    /// 现在分两档：
    /// · **500 米预告**："前方 500 米进入 XX 路（禁摩/限行路段），请提前绕行"
    ///   —— 提前知道，给出调整路线的时间
    /// · **150 米决策**："前方 150 米到达 XX 路路口，请走右侧辅路"
    ///   —— 到了必须做决定的时刻，给出路口级的具体指引
    ///
    /// 只有禁摩类（motoBlocked）走双段式；隧道/大桥只需预告一次
    /// （它们不是"能不能进"的问题，而是"注意安全"）。
    /// v2.43 M1 转弯后确认播报（高德式）：刚过转向点 20~200m 内确认一次，
    /// 骑手戴头盔余光确认"已经走上目标道路"，不重复播报
    private func checkTurnConfirm(at coord: CLLocationCoordinate2D) {
        guard navigating, !routeTurns.isEmpty, speechMode != .simple else { return }
        let traveled = traveledM(route, coord)
        for (idx, t) in routeTurns.enumerated() where !turnConfirmSet.contains(idx) {
            let passed = traveled - t.fromStartM
            if passed >= 20 && passed < 200 {
                turnConfirmSet.insert(idx)
                let road = t.roadName.isEmpty ? "" : "，已进入\(t.roadName)"
                speak("已通过路口\(road)", priority: 2)
                break
            }
        }
    }

    /// v2.43 M2 前方拥堵提示（高德式）：距拥堵/缓行段起点 40~600m 播报一次，
    /// 红色折线之外的听觉补全；驶离该段后复位允许下次再报
    private func checkTrafficAhead(at coord: CLLocationCoordinate2D) {
        guard navigating, !trafficSpans.isEmpty else { return }
        if trafficAheadSpoken {
            // 已报过：驶离最近拥堵段起点 800m 外才复位
            if let start = trafficSpans.first(where: { $0.level >= 1 })?.points.first,
               distanceM(coord, start) > 800 {
                trafficAheadSpoken = false
            }
            return
        }
        for span in trafficSpans where span.level >= 1 {
            guard let start = span.points.first else { continue }
            let d = distanceM(coord, start)
            guard d > 40 && d < 600 else { continue }
            trafficAheadSpoken = true
            // v2.45 O2 拥堵段通行时间估算（高德式）：段长 ÷ 假设车速
            // （严重拥堵 12 / 拥堵 22 / 缓行 32 km/h），供骑手预估延误
            var spanLen = 0.0
            for i in 0..<max(0, span.points.count - 1) { spanLen += distanceM(span.points[i], span.points[i + 1]) }
            let kmh: Double = span.level >= 3 ? 12 : (span.level == 2 ? 22 : 32)
            let passMin = max(1, Int(spanLen / 1000.0 / kmh * 60))
            let dist = GuidanceEventBuilder.formatDistance(Int(d))
            let text = span.level >= 2 ? "前方\(dist)拥堵路段，预计通行约\(passMin)分钟"
                                       : "前方\(dist)缓行路段，注意路况"
            speak(text, priority: 1)
            status = "⚠️ \(text)"
            break
        }
    }

    private func checkRiderRisks(at coord: CLLocationCoordinate2D) {
        guard navigating, !riderRisks.isEmpty, speechMode != .simple else { return }
        let remain = route.last.map { distanceM(coord, $0) } ?? 0
        let traveled = max(0, routeDistanceM - Int(remain))
        for r in riderRisks where r.ahead(of: traveled) {
            let d = Double(r.fromM - traveled)
            guard d >= 0 else { continue }
            let stage = riskSpokenStage[r.id] ?? 0

            // 第二档：150 米内的路口级决策提醒
            if stage == 1, d < 150 {
                riskSpokenStage[r.id] = 2
                let road = r.roadName.isEmpty ? "" : "（\(r.roadName)）"
                speak("前方\(Int(d))米到达\(r.kind.title)\(road)路口，请按现场指示绕行", priority: 2)
                status = "⚠️ 前方\(Int(d))米需绕行"
                continue
            }

            // 第一档：500 米预告
            guard stage == 0, d < 500 else { continue }
            riskSpokenStage[r.id] = 1
            let road = r.roadName.isEmpty ? "" : "（\(r.roadName)）"
            if r.kind.motoBlocked {
                // 禁摩类：预告 + 明确说"提前绕行"
                speak("前方\(Int(d))米进入\(r.kind.title)\(road)，\(r.kind.advice)", priority: 2)
                status = "⚠️ 前方\(Int(d))米\(r.kind.title)"
            } else {
                // 隧道/大桥：一次预告即可
                riskSpokenStage[r.id] = 2   // 不再报第二档
                speak("前方\(Int(d))米\(r.kind.title)\(road)，\(r.kind.advice)", priority: 2)
                status = "⚠️ 前方\(Int(d))米\(r.kind.title)"
            }
        }
    }

    /// 起点解析：未手动设置时跟随当前定位
    var resolvedOrigin: CLLocationCoordinate2D? {
        if originLat != 0 || originLon != 0 {
            return CLLocationCoordinate2D(latitude: originLat, longitude: originLon)
        }
        return currentLocation
    }

    /// v2.19 途经点坐标（高德 waypoints 参数，WGS 传入前转 GCJ 在 RouteFetcher 内处理）
    var waypointCoords: [CLLocationCoordinate2D] {
        waypoints.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    /// 添加途经点并立即重新规划（路线自动穿过 起点→途经1→2→…→终点）
    func addWaypoint(name: String, lat: Double, lon: Double) {
        guard waypoints.count < 5 else {
            status = "途经点最多 5 个，先删掉一个再加"
            return
        }
        let wp = RouteWaypoint(name: name, lat: lat, lon: lon)
        waypoints.append(wp)
        status = "已添加途经「\(name)」，正在重新规划…"
        replan()
    }

    func removeWaypoint(_ wp: RouteWaypoint) {
        waypoints.removeAll { $0.id == wp.id }
        status = "已删除途经「\(wp.name)」，正在重新规划…"
        replan()
    }

    /// v2.27 途经点调序（优化建议 #15）
    ///
    /// 骑行场景经常要微调途经点顺序（接人顺序、加油顺序）。
    /// iOS 上长按拖动排序实现成本高且容易与卡片拖动手势冲突，
    /// 所以用「上移/下移」按钮 —— 稳、可预期、零学习成本。
    ///
    /// - Parameter offset: -1 上移，+1 下移
    func moveWaypoint(_ wp: RouteWaypoint, offset: Int) {
        guard offset == -1 || offset == 1 else { return }
        guard let idx = waypoints.firstIndex(where: { $0.id == wp.id }) else { return }
        let target = idx + offset
        guard target >= 0, target < waypoints.count else {
            status = offset < 0 ? "「\(wp.name)」已是第一个途经点" : "「\(wp.name)」已是最后一个途经点"
            return
        }
        // 交换位置（相邻，直接 swap 即可）
        waypoints.swapAt(idx, target)
        status = "已把「\(wp.name)」移到第 \(target + 1) 位，正在重新规划…"
        replan()
    }

    /// v2.27 途经点距离（优化建议 #17）
    ///
    /// 在每个途经点旁显示「距我 1.2 公里」，方便判断顺序是否合理
    /// （比如先加了个远的接人点，其实另一个更近）。
    /// - Returns: 距离文本；没有定位时返回空串
    func waypointDistanceText(_ wp: RouteWaypoint) -> String {
        guard let loc = currentLocation else { return "" }
        let d = distanceM(loc, CLLocationCoordinate2D(latitude: wp.lat, longitude: wp.lon))
        if d >= 1000 { return String(format: "%.1f km", d / 1000.0) }
        return "\(Int(d)) m"
    }

    func clearWaypoints() {
        waypoints.removeAll()
    }

    /// v2.23 选定候选途经点：算出"添加前 / 添加后"的行程时长，供 UI 对比
    /// - 不改当前 route（还没确认），只算数字
    /// - 添加前 = 起点 → 终点；添加后 = 起点 → 途经点 → 终点
    ///
    /// v2.27（优化建议 #16）**省掉一半高德请求**：
    /// 旧实现为了拿"添加前"的时长，又发了一次完整的路线请求（fetchAll），
    /// 而"添加前"的时长其实就是**当前已应用路线的时长**（routeDurationS）——
    /// 当前路线已经规划过一次了，数字就在手上，没必要重算。
    /// 现在只请求"添加后"（带候选途经点）那一次，请求数从 2 次降到 1 次。
    func previewWaypointCandidate(_ wp: RouteWaypoint) {
        waypointCandidate = wp
        viaCompareLoading = true
        guard let start = resolvedOrigin, destLat != 0 || destLon != 0 else {
            viaCompareLoading = false
            return
        }
        // "添加前" = 当前路线时长（已有，不用重算）
        durationBeforeVia = routeDurationS
        let end = CLLocationCoordinate2D(latitude: destLat, longitude: destLon)
        let existing = waypointCoords
        Task {
            // 只请求"添加后"这一次
            let after = await RouteFetcher.fetchAll(from: start, to: end, amapKey: amapKey,
                                                   via: existing + [CLLocationCoordinate2D(latitude: wp.lat, longitude: wp.lon)])
            durationAfterVia = preferMotoRoutes(after).first?.durationS ?? 0
            viaCompareLoading = false
        }
    }

    /// v2.23 确认添加候选途经点 → 正式加入并重规划
    func confirmWaypointCandidate() {
        guard let wp = waypointCandidate else { return }
        waypointCandidate = nil
        durationBeforeVia = 0
        durationAfterVia = 0
        addWaypoint(name: wp.name, lat: wp.lat, lon: wp.lon)
    }

    /// v2.23 取消候选途经点
    func cancelWaypointCandidate() {
        waypointCandidate = nil
        durationBeforeVia = 0
        durationAfterVia = 0
        viaCompareLoading = false
    }

    /// v2.21 点击途经点 → 地图定位到该点（并短暂高亮）
    func focusWaypoint(_ wp: RouteWaypoint) {
        focusCoord = CLLocationCoordinate2D(latitude: wp.lat, longitude: wp.lon)
        focusTick += 1
        status = "已定位到途经「\(wp.name)」"
    }

    /// v2.19 起终点互换：起点变为原终点，终点变为原起点，互换后立即重新规划
    /// v2.29 起终点互换（用户报告：互换后点开始导航，出发点还是互换前的状态，
    /// 而且导航不显示任何路线和卡片）
    ///
    /// 旧实现的三个真实缺陷：
    /// 1. **途经点没有跟着换方向** —— 起点变成原终点后，途经点仍在原路径上，
    ///    高德收到的是「A(原终点) → 途经(原路径上) → B(原起点)」这种自相矛盾的请求，
    ///    直接失败 → 没有路线、没有卡片。
    /// 2. **起点被永久钉死** —— originLat/originLon 写成原终点后不再跟随定位，
    ///    用户已经骑着车离开几公里了，导航还从旧位置起算。
    /// 3. **终点名显示成"我的位置"** —— 换成真实地名更符合直觉。
    ///
    /// 现在按高德/百度的正确语义实现：
    /// · 起点 = 原终点（固定，这是用户明确要的"从那边出发"）
    /// · 终点 = 原起点（如果原起点是"我的位置"，就显示当前定位的名字）
    /// · **途经点按新方向重排**：原来在"起点→终点"路径上的点仍在，
    ///   但顺序反转（返程时"去接人"的顺序应该倒过来）
    /// · 互换后如果规划失败，自动退回"用当前定位作为终点"再试一次
    private var swapInFlight = false
    func swapOriginDest() {
        // v2.34 防重复点击：交换+重规划是异步网络过程，连点会并发多次 replan 造成路线闪烁
        guard !swapInFlight else { status = "正在交换并重新规划…"; return }
        swapInFlight = true
        guard destLat != 0 || destLon != 0 else {
            status = "还没有终点，先选一个目的地"
            return
        }
        guard let oldOrigin = resolvedOrigin else {
            status = "请先定位后再规划路线"
            return
        }
        let oldOriginName = originName
        let oldOriginLat = oldOrigin.latitude
        let oldOriginLon = oldOrigin.longitude

        // ① 起点 = 原终点
        originName = destName
        originLat = destLat
        originLon = destLon

        // ② 终点 = 原起点
        destName = oldOriginName
        destLat = oldOriginLat
        destLon = oldOriginLon

        // ③ 途经点按新方向重排（v2.29 修复"互换后无路线无卡片"）
        //
        // 高德的做法是"系统会自动优化最优行驶顺序"——
        // 返程时途经点的访问顺序应该反过来（原来"先 A 后 B"，返程就是"先 B 后 A"）。
        // 这里做同样的事：把途经点数组反转。
        //
        // 为什么必须反：旧起点→旧终点的路径是 A→W1→W2→B，
        // 反向走就是 B→W2→W1→A。若不反，请求会变成 B→W1→W2→A，
        // W1、W2 都不在新路径上，高德要么绕一大圈（用户截图里"69.8 公里"就是这个症状）、要么直接报错（无路线无卡片）。
        if waypoints.count > 1 {
            waypoints.reverse()
        }

        status = "已交换起点终点，正在重新规划…"
        replan()
    }

    /// v2.29 互换后的规划失败降级
    ///
    /// 起终点互换是高德最容易失败的操作：起点变成了原终点（几公里外），
    /// 终点变成"当前位置"，方向与原来完全相反。
    /// 如果高德因为途经点顺序或其它原因返回失败，用户会看到"无路线无卡片"，
    /// 不知道发生了什么。
    ///
    /// 这里做一次降级：失败时**去掉途经点**再试一次（途经点是最容易让
    /// 反向规划失败的因素），并在提示里说清楚发生了什么。
    func replanWithoutWaypoints(reason: String) {
        guard !waypoints.isEmpty else { return }
        let saved = waypoints
        waypoints = []
        status = "\(reason)，正在去掉途经点重新规划…"
        // 起终点与途经点数量变化会影响下次 fetchRouteChoices 的参数，
        // 这里用一个标记让 fetchRouteChoices 知道这次是降级规划
        degradedPlan = true
        _ = saved
        replan()
    }

    /// v2.29 标记：本次规划是"去掉途经点"的降级规划
    var degradedPlan = false

    /// 按当前起点/途经/终点重新拉方案（不自动开始导航）
    func replan() {
        guard destLat != 0 || destLon != 0 else { return }
        fetchRouteChoices(to: destName, lat: destLat, lon: destLon, autoStart: false)
    }

    /// 沿途服务设施：以路线中点（无路线时用当前定位）为中心按关键词搜索
    func loadServices(_ kind: ServiceKind) async {
        serviceKindActive = kind
        serviceTips = []
        serviceKindLoading = true
        let anchor: CLLocationCoordinate2D?
        if route.count > 2 {
            anchor = route[route.count / 2]
        } else {
            anchor = currentLocation
        }
        defer { serviceKindLoading = false }
        guard let a = anchor else { return }
        serviceTips = await amapKeywordSearch(kind.keyword, lat: a.latitude, lon: a.longitude, radius: 8000)
    }

    func clearServices() {
        serviceTips = []
        serviceKindActive = nil
    }

    /// v2.87 搜索附近加油站
    private func searchGasStationsNear(_ coord: CLLocationCoordinate2D) {
        Task {
            let tips = await amapKeywordSearch("加油站", lat: coord.latitude, lon: coord.longitude, radius: 5000)
            gasStations = tips.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        }
    }
    /// 高德关键词周边搜索（返回按距离升序）
    func amapKeywordSearch(_ keyword: String, lat: Double, lon: Double, radius: Int = 8000,
                           distanceNote: Bool = true) async -> [AmapTip] {
        guard !amapKey.isEmpty else { return [] }
        let (glat, glon) = CoordConv.wgs2gcj(lat, lon)
        let loc = String(format: "%.6f,%.6f", glon, glat)
        let enc = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlStr = "https://restapi.amap.com/v3/place/around?key=\(amapKey)&location=\(loc)&keywords=\(enc)&radius=\(radius)&offset=20&page=1&sortrule=distance"
        guard let url = URL(string: urlStr) else { return [] }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pois = obj["pois"] as? [[String: Any]] else { return [] }
            var out: [AmapTip] = []
            for p in pois {
                guard let name = p["name"] as? String, !name.isEmpty,
                      let loc2 = p["location"] as? String, !loc2.isEmpty else { continue }
                let parts = loc2.split(separator: ",").compactMap { Double($0) }
                guard parts.count == 2 else { continue }
                let (wlat, wlon) = CoordConv.gcj2wgs(parts[1], parts[0])
                let addr = p["address"] as? String ?? ""
                let dist = p["distance"] as? String ?? ""
                var sub = addr.isEmpty ? (p["type"] as? String ?? "地点") : addr
                if distanceNote, !dist.isEmpty {
                    // v2.23 距离统一用 km 显示（<1km 保留米，超过 1km 用一位小数的 km）
                    let dm = Double(dist) ?? 0
                    if dm < 1000 {
                        sub += " · 距路线\(Int(dm))米"
                    } else {
                        sub += String(format: " · 距路线%.1f公里", dm / 1000.0)
                    }
                }
                out.append(AmapTip(name: name, sub: sub, lat: wlat, lon: wlon))
            }
            return out
        } catch {
            return []
        }
    }

    private func checkNavigation(at coord: CLLocationCoordinate2D) {
        guard navigating else { return }
        rerouteIfOffTrack(at: coord)
        // 到达判定用路线终点（吸附后的"最近出入口"），与路线绘制一致
        let toDest: Double
        if let last = route.last {
            toDest = distanceM(coord, last)
        } else {
            toDest = distanceM(coord, CLLocationCoordinate2D(latitude: destLat, longitude: destLon))
        }
        // v1.82 到达阈值按当前速度动态调整：快路提前判定（>40km/h 用 150 米，低速 80 米），避免高速误判或低速过早
        let arriveThreshold = (currentSpeed * 3.6) > 40 ? 150 : 80
        if toDest < Double(arriveThreshold) {
            speak("已到达目的地，\(destName)，导航结束")
            status = "已到达：\(destName)"
            // v2.39 I4 停车位置记忆（高德式：到达后可在"我的"页一键导航回程找车）
            UserDefaults.standard.set(coord.latitude, forKey: "lastParkedLat")
            UserDefaults.standard.set(coord.longitude, forKey: "lastParkedLon")
            UserDefaults.standard.set(destName, forKey: "lastParkedName")
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastParkedTime")
            // v1.90 到达震动提醒（骑行中不低头也感知到站）
            vibrationArrived()
            navigating = false
            UIApplication.shared.isIdleTimerDisabled = false
            navigateFollowTick += 1
            finishTrip()
            endLiveActivity()
            return
        }
        // v2.87 每隔30秒搜索5公里内加油站
        if navigating, Date().timeIntervalSince(lastGasSearchTime) > 30 {
            lastGasSearchTime = Date()
            searchGasStationsNear(coord)
        }
        // 接近终点播报（高德式：剩余500米提示即将到达）
        if toDest < 500 && !arriveAnnounced {
            arriveAnnounced = true
            speak("前方即将到达目的地，\(destName)")
        } else if toDest > 800 {
            arriveAnnounced = false
        }
        guard !routeTurns.isEmpty else { return }
        var idx = -1
        var best = Double.greatestFiniteMagnitude
        for i in routeTurns.indices where i > lastTurnSpoken {
            let d = distanceM(coord, routeTurns[i].coordinate)
            if d < best { best = d; idx = i }
        }
        if idx >= 0 {
            let t = routeTurns[idx]
            let text = turnText(t)
            // v2.87 路口自动缩放：接近路口<200m拉近，通过后拉远
            if best < 200 && !junctionZoomedIn {
                junctionZoomedIn = true
                junctionZoomedInTurn = idx
                stepNavScale(zoomIn: true)
            } else if best > 300 && junctionZoomedIn && junctionZoomedInTurn == idx {
                junctionZoomedIn = false
                junctionZoomedInTurn = -1
                stepNavScale(zoomIn: false)
            }
            // 高德式两段播报：远提示（800 米级，含路名）→ 近提示（150 米内）
            // v1.99 播报分级：简洁只报近点；标准/详细保留 800 米远提示，详细再加剩余里程
            //
            // v2.27（优化建议 #10）：远提示改用 GuidanceEvent 的距离分级，
            // 与顶部提示卡共用同一套取整规则 —— 以前这里报"前方 137 米"、
            // 卡片显示"前方 140 米"，同一件事两个数字。现在两者完全一致。
            if speechMode.farPrompt && best < 1500 && !farAnnounced.contains(idx) {
                farAnnounced.insert(idx)
                let road = t.roadName.isEmpty ? "" : "，进入\(t.roadName)"
                // 用事件里的分级距离（>300 米不报米数）
                let d = GuidanceEventBuilder.formatDistance(Int(best))
                let speakText = d.map { "前方\($0)\(text)\(road)" } ?? "前方\(text)\(road)"
                speak(speakText)
                status = "导航：\(speakText) · 余\(Int(toDest / 1000))公里"
            } else if best < 200 {
                // v2.93 转向播报加中间档：100米确认
                lastTurnSpoken = idx
                if speechMode.verbose {
                    let tail = toDest > 1000 ? "，剩余\(Int(toDest / 1000))公里" : ""
                    speak("\(text)，距您\(Int(best))米\(tail)")
                } else {
                    speak("\(text)，距您\(Int(best))米")
                }
                status = "导航：\(text) 距\(Int(best))米 · 余\(Int(toDest / 1000))公里"
            } else if best < 100 && !closeAnnounced.contains(idx) {
                // v2.93 转向播报加执行档：50米执行提醒
                closeAnnounced.insert(idx)
                speak(text)
                status = "导航：\(text)"
            }
        }
    }

    // MARK: - 导航信息卡（高德式：剩余里程/时间 + 速度 + 下一转向）

    struct NavStatus {
        let remainM: Int
        let remainS: Int
        let speedKph: Double
        let nextTurn: RouteTurn?
        let distToTurnM: Int
    }

    /// v2.29 延迟启动 Live Activity（避免阻塞"开始导航"的第一帧）
    ///
    /// Activity.request 是同步阻塞调用（XPC 到 activitykitd），
    /// 放在 toggleNavigation 的主线程上会卡住第一帧渲染。
    /// 这里推到下一轮 runloop 之后再启动，并且：
    /// · 用 Task 包裹，不阻塞主线程
    /// · 加超时兜底：3 秒还没起来就放弃（灵动岛只是附加功能，不值得为此拖慢导航）
    private func scheduleLiveActivityStart(destName: String) {
        Task { @MainActor [weak self] in
            // 让本轮 runloop 先把 navigating=true 等 @Published 发布出去
            await Task.yield()
            guard let self, self.navigating else { return }
            // 再让出一轮，确保 UI 已经画出第一帧
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard self.navigating, self.liveActivity == nil else { return }
            self.startLiveActivity(destName: destName)
        }
    }

    /// v2.28 导航状态缓存（由定位回调更新，UI 直接读）
    ///
    /// 之前 UI 有 3 处调用 navigationStatus(at:)（转向放大卡 / 顶部导航条 / 底部导航卡），
    /// 每次都要重算一遍沿路线里程 —— 而这些都在 body 求值期发生，
    /// 一次重算就是 3 遍几何运算。现在改为：定位回调算一次存这里，UI 只读。
    @Published private(set) var navStatusCache: NavStatus?

    /// v2.28 导航状态（**纯函数**，不做任何状态写入）
    ///
    /// 之前这个方法在 body 求值期间写 @Published（traveledIdx），
    /// 而它被 UI 调了 3 次（turnAheadCard / navTopBar / navBottomCard），
    /// 于是形成死循环：
    ///   body 求值 → 写 @Published → SwiftUI 标记需重算 → body 再求值 → 再写 …
    /// 表现就是"点开始导航后界面彻底卡死，点不动也退不出"。
    ///
    /// 现在它只算不写。要更新进度，由定位回调（didUpdateLocations）调
    /// `updateNavProgress(at:)` 来做 —— 那是事件驱动，不会自激。
    func navigationStatus(at coord: CLLocationCoordinate2D?) -> NavStatus? {
        guard !route.isEmpty, let start = route.first, let end = route.last else { return nil }
        let loc = coord ?? currentLocation
        guard let loc = loc else { return nil }
        let traveled = traveledM(route, loc)
        let total = routeDistanceM > 0 ? routeDistanceM : Int(distanceM(start, end))
        let remainM = max(0, total - traveled)
        let remainS = (routeDurationS > 0 && total > 0)
            ? Int(Double(routeDurationS) * Double(remainM) / Double(total))
            : 0
        let speed = (currentSpeed > 0) ? currentSpeed * 3.6 : 0
        let nt = routeTurns.first { $0.fromStartM > traveled }
        return NavStatus(remainM: remainM, remainS: remainS, speedKph: speed,
                         nextTurn: nt, distToTurnM: nt.map { $0.fromStartM - traveled } ?? 0)
    }

    /// v2.28 导航进度更新（由定位回调驱动，**不在 body 求值期调用**）
    ///
    /// "已走过的路变灰"（traveledIdx）
    /// 都需要随位置变化更新，但更新动作绝不能发生在 body 求值期间 ——
    /// 那会触发 SwiftUI 的无限重算循环（见 navigationStatus 的说明）。
    ///
    /// 这里做两件事：
    /// 1. 只在值真的变化时才写 @Published（避免无谓的整树重算）；
    /// 2. traveledIdx 的计算全部走 O(1) 的缓存路径。
    func updateNavProgress(at coord: CLLocationCoordinate2D?) {
        guard navigating, !route.isEmpty else { return }
        let loc = coord ?? currentLocation
        guard let loc = loc else { return }
        // v2.28：一次性算出导航状态缓存，UI 的 3 处调用直接读它
        // （原来每次 body 重算都要重跑一遍几何运算）
        let st = navigationStatus(at: loc)
        if let st {
            // 只在关键值变化时才发布，避免无谓的整树重算
            if let old = navStatusCache,
               old.remainM == st.remainM, old.remainS == st.remainS,
               old.nextTurn?.fromStartM == st.nextTurn?.fromStartM,
               abs(old.speedKph - st.speedKph) < 0.5 {
                // 值没变，不发布
            } else {
                navStatusCache = st
            }
        }
        // v2.36 F2 导航中灵动岛实时剩余距离：5 秒节流一次（Live Activity XPC 有开销，
        // 且锁屏读数不需要秒级精度）
        if let st = navStatusCache,
           Date().timeIntervalSince(lastActivityUpdate) > 5 {
            lastActivityUpdate = Date()
            updateLiveActivity(remainM: st.remainM)
        }
        // 已走过的路变灰：折线最近点索引
        let idx = nearestRouteIndex(route, loc)
        if idx != traveledIdx { traveledIdx = idx }
        // v2.54 路程进度条：从 remainM 反推已走比例。
        // 阈值 0.2% 防抖 —— 每 0.2% 才发布一次，避免定位帧率驱动的整树重算。
        let total = max(1, routeDistanceM > 0 ? routeDistanceM
                        : (route.count >= 2 ? Int(distanceM(route.first!, route.last!)) : 1))
        let p = max(0.0, min(1.0, 1.0 - Double(navStatusCache?.remainM ?? total) / Double(total)))
        if abs(p - navProgress) > 0.002 { navProgress = p }
    }

    /// v2.22 最近折线点索引（走过的路变灰用；带缓存，增量搜索）
    ///
    /// v2.28：距离计算改用平面近似（flatDist），不再为每个点构造 CLLocation。
    /// 这个方法每次定位都会跑（窗口 160 点 + 偶尔全量），CLLocation 的对象分配
    /// 在导航态高频调用下是明显的 GC 压力来源。
    private var idxCache = 0
    private var idxCacheKey = ""
    private func nearestRouteIndex(_ pts: [CLLocationCoordinate2D], _ loc: CLLocationCoordinate2D) -> Int {
        guard pts.count > 1 else { return 0 }
        let key = "\(pts.count)-\(pts[0].latitude)-\(pts[pts.count - 1].longitude)"
        if key != idxCacheKey { idxCacheKey = key; idxCache = 0 }
        let lo = max(0, idxCache - 80), hi = min(pts.count - 1, idxCache + 80)
        var bestI = lo, bestD = Double.greatestFiniteMagnitude
        for i in lo...hi {
            let d = flatDist(loc, pts[i])
            if d < bestD { bestD = d; bestI = i }
        }
        if (bestI == lo && lo > 0) || (bestI == hi && hi < pts.count - 1) {
            for i in pts.indices {
                let d = flatDist(loc, pts[i])
                if d < bestD { bestD = d; bestI = i }
            }
        }
        idxCache = bestI
        return bestI
    }

    /// v2.22 转向图标（全局唯一实现，ContentView 也复用）
    func navTurnIcon(_ t: RouteTurn) -> String {
        // v2.27：转调 GuidanceEventBuilder.turnIcon —— 图标规则的唯一权威实现
        // （优化建议 #10：同一件事只有一套规则）
        GuidanceEventBuilder.turnIcon(t)
    }

    /// v2.22 顶部路线提示卡文案（高德式）
    ///
    /// 规则（自定义刷新）：
    /// · 起步阶段（已走 < 30 米且当前位置离路线折线 > 25 米）→ "请先去往出口"
    /// · 正常行驶 → 取前方最近的转向点，"前方xx米路口直行/右转/左转"
    ///   其中 xx = 当前位置到该路口的距离（沿路线里程差）
    /// · 前方 60 米内才显示具体路口动作，避免频繁跳动
    func navTopHintText() -> (text: String, icon: String) {
        let e = currentGuidanceEvent()
        return (e.text, e.icon)
    }

    /// v2.27 当前导航事件（顶部提示与语音播报的**唯一**数据源）
    ///
    /// 优化建议 #10：以前语音和顶部提示是两条独立链路，各自算"前方多少米、什么动作"，
    /// 于是可能出现「语音说右转、卡片显示左转」「语音报 120 米、卡片显示 80 米」。
    ///
    /// 现在两者都从 GuidanceEvent 派生 —— 事件里已经算好距离、动作、进入道路、车道建议，
    /// UI 只负责显示、语音只负责念，物理上杜绝不一致。
    func currentGuidanceEvent() -> GuidanceEvent {
        guard navigating, let loc = currentLocation, !route.isEmpty else {
            return GuidanceEvent(kind: .straightToEnd, icon: "straight.up",
                                 text: "", subtitle: "", laneHint: "",
                                 laneIcons: [], recommendedLane: -1, distanceM: 0,
                                 action: "直行", roadName: "")
        }
        let traveled = traveledM(route, loc)
        // 当前位置到路线折线的最近距离（判断"还没上主线"）
        //
        // v2.28：旧版是 `for p in route { minD = min(minD, distanceM(loc, p)) }` ——
        // 对整条路线（可达 2000+ 点）做全量扫描，且 distanceM 每次构造 2 个 CLLocation。
        // 而这个方法在 body 求值期被调用（导航卡每秒刷新数次），
        // 于是每秒几万次对象分配 → 主线程被拖垮，界面"卡住"。
        //
        // 现在改成"只算最近点附近那一小段"：
        // traveledM 已经找到了路线上的最近点索引，最小距离必然出现在它附近，
        // 扫 ±10 个点足够，误差在 1 米以内。
        let minD = minDistanceToRoute(loc)
        // 车道建议：用 LaneGuideBuilder 生成（高德没给车道数据时按动作合成）
        let nextTurn = routeTurns.first { $0.fromStartM > traveled }
        let guides = LaneGuideBuilder.guides(turn: nextTurn)
        return GuidanceEventBuilder.make(turns: routeTurns,
                                         traveledM: traveled,
                                         minDistanceToRouteM: minD,
                                         laneGuides: guides)
    }

    /// v2.28 定位点到路线折线的最小距离（米）
    ///
    /// 用 traveledM 已缓存的最近点索引，只扫附近一小段 —— O(1) 而非 O(n)。
    private func minDistanceToRoute(_ loc: CLLocationCoordinate2D) -> Double {
        guard route.count > 1 else { return .greatestFiniteMagnitude }
        let center = min(traveledCacheIdx, route.count - 1)
        var minD = Double.greatestFiniteMagnitude
        let lo = max(0, center - 10)
        let hi = min(route.count - 1, center + 10)
        for i in lo...hi {
            minD = min(minD, flatDist(loc, route[i]))
        }
        return minD
    }

    /// v2.22 起点内部道路连接：定位点 → 路线起点（道路入口）
    /// 高德规划时起点会被吸附到最近的道路出入口，两者之间有一段小区/园区内部道路。
    /// 这里算出这段连接，配合蓝色虚线 + 入口处的白色转向箭头（高德式）。
    var routeStartLink: RouteLink? {
        guard navigating, let loc = currentLocation, route.count > 1 else { return nil }
        let entry = route[0]
        let d = distanceM(loc, entry)
        guard d > 20 else { return nil }   // 已在路上，不需要连接线
        return RouteLink(from: loc, to: entry)
    }

    /// v2.22 终点内部道路连接：路线终点（道路出口）→ 目的地
    var routeEndLink: RouteLink? {
        guard navigating, route.count > 1, destLat != 0 || destLon != 0 else { return nil }
        let exit = route[route.count - 1]
        let target = CLLocationCoordinate2D(latitude: destLat, longitude: destLon)
        let d = distanceM(exit, target)
        guard d > 20 else { return nil }
        return RouteLink(from: exit, to: target)
    }

    /// v2.22 起点入口转向箭头（按路线第一段相对定位点的方位判断左/直/右）
    var routeStartArrow: String {
        guard let link = routeStartLink, route.count > 1 else { return "straight" }
        return turnKind(from: link.from, via: link.to, to: route[min(2, route.count - 1)])
    }

    /// v2.22 终点入口转向箭头（按从路线倒数第二段→出口→目标点的转向判断）
    var routeEndArrow: String {
        guard let link = routeEndLink, route.count > 2 else { return "straight" }
        return turnKind(from: route[route.count - 2], via: link.from, to: link.to)
    }

    /// 依据三点走向判断转向（left / right / straight）
    private func turnKind(from a: CLLocationCoordinate2D, via b: CLLocationCoordinate2D,
                          to c: CLLocationCoordinate2D) -> String {
        let brg1 = bearing(from: a, to: b)
        let brg2 = bearing(from: b, to: c)
        var d = brg2 - brg1
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        if d > 25 { return "right" }
        if d < -25 { return "left" }
        return "straight"
    }

    /// 两点间方位角（度，正北为 0，顺时针）
    private func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }

    /// 导航视野切换：1 厘米对应多少米（16 = 最近，58 = 最远）
    func setNavScale(_ metersPerCm: Int) {
        guard navScaleTarget != metersPerCm else { return }
        navScaleTarget = metersPerCm
        navScaleTick += 1
        // v2.88 手动改档要记时间：否则 autoNavScale 下一个定位回调就按速度把它改回去，
        // 用户点"+"看着没反应（其实是被自动档位立刻覆盖了）
        lastManualScaleAt = Date()
    }

    /// v2.88 导航态 +/- 按钮：在档位表里走一格
    ///
    /// 旧版这两个按钮直接缩放相机（以"地图中心"为锚），导航态有三个毛病：
    ///  ① 车不在屏幕中心（在偏下 56%），以中心缩放会把车往上拽，越点越靠中间；
    ///  ② 缩放走的是 setRegion，会触发 regionDidChange 的"非程序化"判定 →
    ///     userMoved 被置 true → 跟随停掉、冒出"继续导航"、地图也不再随车头转；
    ///  ③ 直接改相机距离，绕过了档位系统，下一次自动档位又把它改回去。
    /// 现在改为只改档位，由 MapView 的 navScaleTick 分支统一重设相机：
    /// 车保持在屏幕偏下、heading 保持车头朝上。
    func stepNavScale(zoomIn: Bool) {
        let steps = AppModel.navScaleSteps
        let cur = steps.firstIndex(of: navScaleTarget) ?? (zoomIn ? steps.count - 1 : 0)
        let next = zoomIn ? max(0, cur - 1) : min(steps.count - 1, cur + 1)
        setNavScale(steps[next])
    }

    /// v2.29 自动视野档位开关（按速度切换）
    ///
    /// 调研发现：Komoot 支持面板滑动换指标、OsmAnd 面板可自定义，
    /// 行业共识是"仪表信息应该随骑行状态自动变"。
    /// 骑行场景下这一点特别明显：
    /// · 低速（等红灯、拐弯）→ 需要看清近处路口 → 近景
    /// · 中速（市区骑行）→ 中景
    /// · 高速（快速路）→ 需要看前方几百米的排队情况 → 远景
    ///
    /// 默认开启。用户手动切档后 20 秒内不自动覆盖（尊重用户意图）。
    @Published var autoNavScale: Bool = UserDefaults.standard.object(forKey: "autoNavScale") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoNavScale, forKey: "autoNavScale") }
    }
    /// v2.29 用户最后一次手动切档的时间（用于抑制自动切换）
    private var lastManualScaleAt: Date = .distantPast

    /// v2.52 五档视野表（米/厘米）：22 / 30 / 42 / 58 / 80
    ///
    /// 对照高德的结论：v2.49 已把旧值 25/35/50/70/100 收到 22/30/42/58/80，
    /// v2.53 真机导航仍反馈"比高德远"（用户截图里 0 km/h 时比例尺已经到 1 公里，
    /// 高德起步态是 200~500 米级别），v2.54 再整体收一档：
    ///   16/22/30/42/58 → 前方可见约 330/460/620/870/1200 m
    /// 高德同车速市区视距约 600~800 m：22~34 km/h 落在 620 m（30 档），
    /// 34~48 km/h 落在 870 m（42 档），都在高德区间内；起步/等灯用 330 m 看得最清。
    /// v2.56 档位整体上调约 25%，对齐高德导航态的真实视野：
    /// 高德停车/市区约能看到前方 500~600 m、快速路约 1 km；
    /// 旧档位（16 起）换算下来前方只有约 320 m，路线只露出一小段，
    /// 后续走向看不清 —— 这也是截图里"路线缩成一条、周围大片空地"的由来。
    ///   20 → 前方约 400 m（停车/起步）
    ///   28 → 约 560 m（市区骑行）
    ///   38 → 约 760 m
    ///   50 → 约 1.0 km（快速路）
    ///   66 → 约 1.3 km（高速巡航）
    /// v2.70 前置一档 12（约 240 m 视野）：旧版最紧一档是 400 m，
    /// 转弯前那几十米的车道细节始终看不清，高德车道级是 ~100~200 m 量级。
    ///   12 → 约 240 m（转弯前贴脸）
    ///   20 → 约 400 m（停车/起步）
    ///   28 → 约 560 m（市区骑行）
    ///   38 → 约 760 m
    ///   50 → 约 1.0 km（快速路）
    ///   66 → 约 1.3 km（高速巡航）
    // v2.92 导航视野整体拉远：旧版 [12, 20, 28, 38, 50, 66] 低速时只有 ~360m 可见，
    // 用户反馈"看见范围太小"。对齐高德：正常行驶前方可见 1~2 公里。
    // 新表：[20, 32, 48, 68, 95, 130]（米/厘米），最低档 ~600m、最高档 ~3.9km。
    // v2.93 导航视野再拉远一档：用户反馈跟随模式地图看见范围太小
    // 从 [20,32,48,68,95,130] 调到 [30,45,65,90,120,160]
    // v2.94 导航视野再拉远一档：[30,45,65,90,120,160] → [40,60,85,120,160,200]
    // v2.85 跟随模式视野增加一档（整体拉远）
    static let navScaleSteps = [50, 75, 105, 145, 190, 240]
    /// 相邻档位的升级边界（km/h），与新档位一一对应
    // v2.92 升档边界随新 steps 表调整：低速起步就有足够视野，速度越快看得越远
    private static let navScaleUpBounds = [12, 20, 32, 48, 65]
    /// 切档滞回带宽（km/h）：GPS 速度在阈值附近抖动时不来回切档
    /// v2.70 3.0 → 5.0：摩托车走走停停，3 km/h 的带太窄，起步/刹车会反复跳档
    private static let navScaleHysteresis = 5.0
    /// 临近转向的临时近景半径（米）
    private static let navTurnZoomRadiusM = 250
    /// v2.70 贴脸近景半径（米）：转弯前的车道级视野
    private static let navTurnCloseRadiusM = 100

    /// v2.49 按速度自动选择视野档位（米/厘米）
    ///
    /// 相比 v2.29 的三档：
    /// ① 五档细分，市区 20~35 km/h 不再被迫用"前方 745m"的中景；
    /// ② ±3 km/h 滞回，速度抖动不会把地图来回缩放；
    /// ③ 每次只挪一档，速度突变时 1~2 秒平滑推进，而不是一次跳 4 倍；
    /// ④ 距下一转向 <250m 临时降一档，路口看得清（转过后自动恢复）。
    /// - Parameter snap: true 时直接按速度查表定档（不逐档递进）——
    ///   用于"开始导航 / 继续导航"这类需要一步到位的场景，避免从上次档位一秒一档地挪
    func autoNavScaleTarget(snap: Bool = false) -> Int {
        let kph = max(0.0, currentSpeed * 3.6)
        let steps = AppModel.navScaleSteps
        var idx: Int
        if snap {
            idx = 0
            for b in AppModel.navScaleUpBounds where kph >= Double(b) { idx += 1 }
        } else {
            idx = steps.firstIndex(of: navScaleTarget) ?? 2
        }
        // 升档：超过边界 + 滞回带
        if !snap, idx < steps.count - 1,
           kph >= Double(AppModel.navScaleUpBounds[idx]) + AppModel.navScaleHysteresis {
            idx += 1
        }
        // 降档：低于边界 - 滞回带
        else if !snap, idx > 0,
                kph <= Double(AppModel.navScaleUpBounds[idx - 1]) - AppModel.navScaleHysteresis {
            idx -= 1
        }
        // v2.70 转弯优先：离转向越近，视野越贴脸（高德车道级就是这个逻辑）。
        // 旧版只"降一档"，最紧仍停在 400 m，路口细节永远看不清；
        // 而且 snap 场景下也只看速度，等于停车等灯时视野反而拉到最远。
        if navigating {
            // v2.81 加滞回：这段原来没有滞回带，而 distToTurnM 每个 tick 都在变，
            // GPS 在 100 m / 250 m 边界抖十来米，idx 就在 0 和 1 之间来回翻 ——
            // 表现就是"导航态画面忽近忽远地跳"，这是乱跳的主因。
            // 现在进入阈值小、退出阈值大：<100 进近档、要到 170 才退出；
            // <250 进中档、要到 320 才退出。中间地带保持上一次判断。
            let d = navStatusCache?.distToTurnM ?? 9_999
            if d < AppModel.navTurnCloseRadiusM {
                navNearZone = 2
            } else if d < AppModel.navTurnZoomRadiusM {
                if navNearZone < 2 { navNearZone = 1 }
            } else if d >= AppModel.navTurnZoomRadiusM + 70 {
                navNearZone = 0
            }
            switch navNearZone {
            case 2: idx = 0                              // 贴脸，路口占满屏幕
            case 1: idx = min(idx, 1)                    // 逼近路口，压到第二紧
            default: break
            }
        } else {
            navNearZone = 0
        }
        return steps[idx]
    }

    /// v2.29 在定位回调里调用：按速度自动切视野
    ///
    /// 用户手动切过之后 20 秒内不动 —— 骑行中用户主动调了视野，
    /// 说明他有明确意图（可能前方在修路、或者他就是想看远点），
    /// 20 秒后（过了这个路口）再恢复自动。
    private func updateAutoNavScale() {
        guard navigating, autoNavScale else { return }
        if Date().timeIntervalSince(lastManualScaleAt) < 20 { return }
        let target = autoNavScaleTarget()
        if navScaleTarget != target {
            navScaleTarget = target
            navScaleTick += 1
        }
    }

    /// v2.54 循环切换导航视野档位（五档：16 / 22 / 30 / 42 / 58 米每厘米）
    ///
    /// 五档对应骑行时五种真实需求：
    /// · 16/22 —— 起步、等灯、老城区路口密集处，看清转向细节
    /// · 30 —— 默认档（22~34 km/h），前方约 620 m，兼顾路口与路况
    /// · 42/58 —— 大路/高架，看前方 870~1200 m 的排队情况
    ///
    /// 骑行中单手操作，所以只做一个循环按钮而不是分段控件：
    /// 按一次切到下一档，不用瞄准。
    func cycleNavScale() {
        // v2.56 五档循环：20 → 28 → 38 → 50 → 66 → 20
        let steps = AppModel.navScaleSteps
        let idx = steps.firstIndex(of: navScaleTarget) ?? 2
        let next = steps[(idx + 1) % steps.count]
        // v2.29 记录手动操作：20 秒内不被自动切换覆盖
        lastManualScaleAt = Date()
        setNavScale(next)
        status = "视野：\(next) 米/厘米"
    }

    /// v2.01 下一个信号灯（导航中做红绿灯倒计时）：260 米内的第一个灯
    var nextTrafficLight: (light: TrafficLight, dist: Int)? {
        guard navigating, !trafficLights.isEmpty,
              let loc = currentLocation, route.count >= 2 else { return nil }
        let traveled = traveledM(route, loc)
        guard let l = trafficLights.first(where: { $0.fromStartM > traveled - 15 }) else { return nil }
        let d = l.fromStartM - traveled
        guard d <= 260 else { return nil }
        return (l, max(0, d))
    }

    /// v2.02 比例尺更新（去重，避免无效刷新）
    func setScale(_ text: String) {
        guard !text.isEmpty, text != scaleText else { return }
        scaleText = text
    }

    /// v2.01 3D / 2D 切换（地图右侧"3D"按钮）
    func togglePitch() {
        pitchDeg = pitchDeg > 0 ? 0 : 45
        status = pitchDeg > 0 ? "3D 俯视 45°" : "2D 平视"
    }

    /// v1.82 当前所在道路名：取已通过转向点中最后一个转入的道路（高德式顶部道路名）
    var currentRoadName: String {
        guard navigating, !route.isEmpty else { return "" }
        let traveled = traveledM(route, currentLocation ?? route[0])
        // v2.28：原来用「到终点直线距离」反推行程，再全量遍历 routeTurns 找最后一个匹配项。
        // routeTurns 可达上百个，而这段代码在 body 求值期被调用（导航每秒刷新数次），
        // 属于纯浪费。现在直接用已缓存的沿路线里程 + 二分查找定位转向点。
        guard !routeTurns.isEmpty else { return "" }
        // 找最后一个 fromStartM <= traveled 的转向点
        var lo = 0, hi = routeTurns.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if routeTurns[mid].fromStartM <= traveled {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        // 从该点往回找最近一个有路名的（有些转向点是内部道路，没有名称）
        var i = found
        while i >= 0 {
            if !routeTurns[i].roadName.isEmpty { return routeTurns[i].roadName }
            i -= 1
        }
        return ""
    }

    /// 沿路线折线累计已走距离（米）：定位点到折线的最近点（含前段距离）
    /// v2.02 行进里程（增量搜索）
    ///
    /// 旧实现每次调用都线性扫完整条路线（几千点），而导航卡每秒刷新会调用 2~3 次
    /// （navigationStatus / nextTrafficLight / currentRoadName 各一次）→ 每秒上万次距离计算，
    /// 这是导航中"地图发涩、卡片一顿一顿"的主要来源。
    /// 现在只在上次位置附近 ±80 个点里找最近点，跑到窗口边缘才做一次全量校正。
    ///
    /// v2.28 关键优化：**前缀距离表**
    /// 旧版即使找到了最近点，还要从 0 开始逐段累加到该点（O(n) 次距离计算），
    /// 路线 2000 点时每次调用仍是 2000 次 CLLocation 构造 + 距离计算。
    /// 现在预先算好"从起点到第 i 点的累计距离"（cumDist），
    /// 查表即得 O(1) 结果。这让"每次定位都算一次里程"变得廉价。
    private var traveledCacheIdx = 0
    private var traveledRouteKey = ""
    /// 前缀距离表：cumDist[i] = 从 pts[0] 沿折线到 pts[i] 的累计距离（米）
    private var traveledCumDist: [Double] = []
    /// 平面近似距离（米）：比 CLLocation.distance 快一个数量级，且不产生对象分配
    private func flatDist(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dy = (a.latitude - b.latitude) * 110540.0
        let dx = (a.longitude - b.longitude) * 111320.0
            * cos((a.latitude + b.latitude) * 0.5 * .pi / 180.0)
        return (dx * dx + dy * dy).squareRoot()
    }

    private func traveledM(_ pts: [CLLocationCoordinate2D], _ loc: CLLocationCoordinate2D) -> Int {
        guard pts.count > 1 else { return 0 }
        let key = "\(pts.count)-\(pts[0].latitude)-\(pts[pts.count - 1].longitude)"
        if key != traveledRouteKey {
            traveledRouteKey = key
            traveledCacheIdx = 0
            // 重建前缀距离表（路线换了才重建）
            var cum = [Double](repeating: 0, count: pts.count)
            for i in 1..<pts.count {
                cum[i] = cum[i - 1] + flatDist(pts[i - 1], pts[i])
            }
            traveledCumDist = cum
        }
        let lo = max(0, traveledCacheIdx - 80)
        let hi = min(pts.count - 1, traveledCacheIdx + 80)
        var bestI = lo
        var bestD = Double.greatestFiniteMagnitude
        for i in lo...hi {
            let d = flatDist(loc, pts[i])
            if d < bestD { bestD = d; bestI = i }
        }
        // 最近点贴着窗口边缘 → 说明可能已经跑出窗口，全量校正一次
        if (bestI == lo && lo > 0) || (bestI == hi && hi < pts.count - 1) {
            for i in pts.indices {
                let d = flatDist(loc, pts[i])
                if d < bestD { bestD = d; bestI = i }
            }
        }
        traveledCacheIdx = bestI
        // O(1) 查表得到前段距离（旧版是 O(n) 累加）
        let acc = bestI < traveledCumDist.count ? traveledCumDist[bestI] : 0
        return Int(acc + bestD / 2)
    }

    /// 转向动作的中文描述
    ///
    /// v2.27：转调 GuidanceEventBuilder.actionText —— 那是动作文案的**唯一权威实现**。
    /// 优化建议 #10：语音与顶部提示共用同一份数据源，
    /// 动作文案只能有一处规则（早期版本这里和 NavEvent 各写一份，
    /// 结果"急左转"和"向左急转"两种说法并存）。
    func turnText(_ t: RouteTurn) -> String {
        GuidanceEventBuilder.actionText(t)
    }
}

// v2.86 搜索结果标注
class SearchResultAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?
    let index: Int
    init(coordinate: CLLocationCoordinate2D, title: String, subtitle: String, index: Int) {
        self.coordinate = coordinate
        self.title = title
        self.subtitle = subtitle
        self.index = index
    }
}
