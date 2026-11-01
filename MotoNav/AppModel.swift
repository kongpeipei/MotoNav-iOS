import Foundation
import CoreLocation
import AVFoundation
import UserNotifications
import UIKit
import ActivityKit
import CryptoKit
import AudioToolbox

extension Notification.Name {
    /// 触发点位提醒（object 为 Poi）
    static let motoAlert = Notification.Name("motoAlert")
    /// 点位列表变化（供 CarPlay 同步）
    static let motoPoisChanged = Notification.Name("motoPoisChanged")
}

/// CLLocationCoordinate2D Codable（轨迹历史持久化）

@MainActor
final class AppModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = AppModel()

    @Published var pois: [Poi] = []
    @Published var currentLocation: CLLocationCoordinate2D?
    /// 定位精度（米），越小信号越好
    @Published var locationAccuracy: CLLocationAccuracy = 0
    @Published var monitoring = false
    @Published var simulating = false
    @Published var status = "等待定位…"
    @Published var route: [CLLocationCoordinate2D] = []
    @Published var routePois: [Poi] = []
    /// 多路线方案（点"去这里"后展示，选择后应用）
    @Published var routeChoices: [RouteChoice] = []
    @Published var selectedPoi: Poi?
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
    // MARK: v2.04 官方电警接近提醒
    /// 正在提醒的点位 id（地图上该点放大 1.45 倍 + 白圈加粗）
    @Published var hotCameraId: Int = 0
    /// 接近横幅文案（nil 表示不显示）
    @Published var cameraAlert: String?
    /// 已进入 260m 圈的点位（离开 400m 后移除，实现"每次靠近只播一次"）
    private var camArmed: Set<Int> = []
    /// 每个点位最近一次播报时间（2 分钟内不重复，防止路口来回抖动刷屏）
    private var camSpokenAt: [Int: Date] = [:]
    /// 上次做接近判定的位置（位移 <20m 直接跳过，静止时不做无用计算）
    private var camLastPos: CLLocationCoordinate2D?
    /// 横幅自动消失任务
    private var camBannerTask: DispatchWorkItem?
    /// 导航跟随触发（导航开始/结束/到达时递增，地图进入跟随模式）
    @Published var navigateFollowTick = 0
    /// v1.84 巡航模式（非导航下累计位移 ≥300m 自动进入；定位点跟随 + 顶部巡航卡片）
    @Published var cruiseMode = false
    @Published var cruiseTick = 0
    private var cruiseBase: CLLocationCoordinate2D?
    /// v1.90 省电模式（电量≤20% 或系统低电量模式自动开启：降定位频率）
    @Published var powerSaving = false
    /// v1.92 进入省电前的 distanceFilter 原值（退出省电时还原，避免反向升频）
    private var baseDistanceFilter: CLLocationDistance = kCLDistanceFilterNone
    /// v1.92 电量复查节流时间戳（秒）
    private var lastPowerCheck: TimeInterval = 0
    /// 省电模式总开关（默认开；"我的"页可关）
    var powerSaveEnabled: Bool { UserDefaults.standard.object(forKey: "powerSaveEnabled") as? Bool ?? true }
    /// 当前选中的路线方案下标（高德式：默认选中推荐，卡片点击切换）
    @Published var selectedRouteIdx = 0
    /// 手机朝向（度，0=北，顺时针）
    @Published var heading: Double = 0
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
    /// 市区加油站坐标
    @Published var gasStations: [CLLocationCoordinate2D] = []
    /// 加油站全览请求计数
    @Published var gasTick = 0
    /// 地图小区/商铺名称标签（带坐标）
    @Published var placeLabels: [PlaceLabel] = []

    /// 合肥小区/商铺联想库（内置 + 在线刷新）
    @Published var hfPois: [String] = []

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
        var id: String { "\(name)#\(lat)#\(lon)" }
    }

    /// 类型筛选（默认全部启用）
    var enabledTypes: Set<PoiType> = Set(PoiType.allCases)
    /// 点位总开关
    var allPoiEnabled = true

    private let repo = PoiRepository()
    private let lm = CLLocationManager()
    private let speech = AVSpeechSynthesizer()
    /// v1.61 恢复：讯飞在线语音合成（真四川话女声，失败自动降级系统语音）
    private var xfPlayer: AVAudioPlayer?
    private var xfSeq = 0
    /// 讯飞诊断（试听/播报失败时显示具体原因，设置页 footer）
    @Published var xfDiag = ""
    private var xfTask: URLSessionWebSocketTask?
    /// 语音播报总开关
    var voiceMuted: Bool { UserDefaults.standard.object(forKey: "voiceMuted") as? Bool ?? false }
    private var lastSpeakAt = Date.distantPast
    private var lastSpeakPriority = 0
    private var lastSpeakText = ""
    /// 违拍提醒 Live Activity（灵动岛/锁屏实时显示前方抓拍点，导航中生效）
    private var liveActivity: Activity<MotoNavAttributes>?
    private var simTimer: Timer?
    private var simStep = 0
    private var lastTrigger: [Int64: Date] = [:]
    /// 预警分档播报状态：0=未播 1=500m档 2=300m档（按点位）
    private var alertStage: [Int64: Int] = [:]
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
        let snapCount: Int
        let avgSpeedKmh: Double
    }
    @Published var tripSummary: TripSummary?

    /// 导航状态
    private var destLat = 0.0
    private var destLon = 0.0
    var destName = ""
    @Published var routeTurns: [RouteTurn] = []
    private var lastTurnSpoken = -1
    /// 已做过"前方xx米右转"远提示的转向序号（避免重复播报）
    private var farAnnounced: Set<Int> = []
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
    @Published var avoidHighway: Bool = UserDefaults.standard.object(forKey: "avoidHighway") as? Bool ?? false {
        didSet { UserDefaults.standard.set(avoidHighway, forKey: "avoidHighway") }
    }
    /// 当前路线的骑行风险段（高速/高架/隧道/大桥/禁摩）
    @Published var riderRisks: [RoadRisk] = []
    /// 当前路线的拥堵分段（红黄）
    @Published var trafficSpans: [TrafficSpan] = []
    /// 途经点（"顺路加一站"）
    @Published var waypoint: CLLocationCoordinate2D?
    @Published var waypointName = ""
    /// 足迹回放轨迹（我的-足迹 → 点一条记录）
    @Published var footprintPreview: [CLLocationCoordinate2D] = []
    /// 沿途服务设施搜索结果（"顺路加一站"）
    @Published var serviceTips: [AmapTip] = []
    @Published var serviceKindLoading = false
    @Published var serviceKindActive: ServiceKind?
    /// 导航轨迹缓冲（结束后存为足迹）
    private var trackPoints: [CLLocationCoordinate2D] = []
    private var maxSpeedKph: Double = 0
    private var lastRiskSpoken = Set<String>()
    private var lastCurveSpoken = Date.distantPast

    /// 实时速度（m/s，来自定位，导航卡显示 km/h）
    @Published var currentSpeed = 0.0

    private let historyKey = "search_history"
    private let historyLimit = 10
    private let hfKey = "hf_pois"

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
        // v1.61：内置高德 Key 兜底（用户设置过则用用户的；否则用内置，保证搜索联想/路线规划始终可用）
        if let saved = UserDefaults.standard.string(forKey: "amapKey"), !saved.isEmpty {
            amapKey = saved
        } else {
            amapKey = Self.builtinAmapKey
        }
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        pois = repo.load()
        loadHistory()
        loadHefeiPois()
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
    /// v1.92 新增：退出省电时还原 baseDistanceFilter，而不是无脑设 kCLDistanceFilterNone
    private func updateLocationFilter() {
        if powerSaving && !navigating {
            baseDistanceFilter = lm.distanceFilter
            lm.distanceFilter = 50
        } else {
            lm.distanceFilter = baseDistanceFilter
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

    func isFavorite(_ p: Poi) -> Bool {
        favorites["\(p.lat),\(p.lon)"] != nil
    }

    func toggleFavorite(_ p: Poi) {
        let key = "\(p.lat),\(p.lon)"
        if favorites[key] != nil {
            favorites.removeValue(forKey: key)
            favoriteTimes.removeValue(forKey: key)
        } else {
            favorites[key] = p.name
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
                out.append(AmapTip(name: name, sub: sub, lat: wlat, lon: wlon))
            }
            return out
        } catch {
            return []
        }
    }

    func setHome(_ p: Poi) {
        homePlace = SavedPlace(name: p.name, lat: p.lat, lon: p.lon)
        let ud = UserDefaults.standard
        if let d = try? JSONEncoder().encode(homePlace) { ud.set(d, forKey: homeKey) }
    }

    func setWork(_ p: Poi) {
        workPlace = SavedPlace(name: p.name, lat: p.lat, lon: p.lon)
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

    private func loadHefeiPois() {
        // 1) 本地缓存
        if let cached = UserDefaults.standard.stringArray(forKey: hfKey), !cached.isEmpty {
            hfPois = cached
        }
        // 2) 内置资源
        if hfPois.isEmpty,
           let url = Bundle.main.url(forResource: "hefei_pois", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            hfPois = arr
        }
        // 3) 在线刷新（失败静默）
        Task {
            if let fresh = await fetchHefeiPoisOnline() {
                hfPois = fresh
                UserDefaults.standard.set(fresh, forKey: hfKey)
            }
        }
    }

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
                placeLabels = Array(list.prefix(600))
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

    func fetchWeather() {
        guard let loc = currentLocation else { return }
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
            startMonitoring()
        default:
            status = "需要定位权限才能使用"
        }
    }

    func startMonitoring() {
        guard !monitoring else { return }
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
        Task { @MainActor in
            currentLocation = coord
            locationAccuracy = loc.horizontalAccuracy
            currentSpeed = loc.speed > 0 ? loc.speed : 0
            // v1.99 足迹轨迹 + 最高速（仅导航中记录，避免无意义点位）
            if navigating {
                trackPoints.append(coord)
                if loc.speed > 0 { maxSpeedKph = max(maxSpeedKph, loc.speed * 3.6) }
                checkRiderRisks(at: coord)
            }
            // v1.99 组队位置上报（未组队时是空操作）
            TeamRide.shared.update(lat: coord.latitude, lon: coord.longitude,
                                   speedKph: max(0, loc.speed) * 3.6)
            // v1.92 后台/前台都靠定位回调复查电量（通知在挂起时收不到）
            throttledPowerSavingCheck()
            if weatherText == nil { fetchWeather() }
            checkAlerts(at: coord)
            // v2.04 官方电警接近提醒：不看是否在导航，只要在移动就判
            checkPoliceCameras(at: coord)
            checkNavigation(at: coord)
            updateCruise(at: coord)
        }
    }

    // MARK: - 巡航模式（v1.84）

    /// 非导航状态下自动检测：定位点累计移动 ≥300 米进入巡航模式（地图缩放合理位置 + 定位点跟随）
    func updateCruise(at coord: CLLocationCoordinate2D) {
        guard !navigating else {
            if cruiseMode { exitCruise() }
            return
        }
        if let base = cruiseBase {
            if !cruiseMode && distanceM(coord, base) >= 300 {
                cruiseMode = true
                cruiseTick += 1
                cruiseBase = nil
            }
        } else {
            cruiseBase = coord
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
    }

    /// 巡航卡片"最近拍照点"：距离当前位置最近的启用电警点位
    var nearestCruiseCamera: (name: String, dist: Int) {
        guard let loc = currentLocation else { return ("暂无拍照点", 0) }
        var best: Poi?
        var bd = Double.greatestFiniteMagnitude
        for p in pois where p.enabled && p.type.isCamera {
            let d = distanceM(loc, p.coordinate)
            if d < bd { bd = d; best = p }
        }
        if let b = best { return (b.name, Int(bd)) }
        return ("暂无拍照点", 0)
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateHeading newHeading: CLHeading
    ) {
        let h = newHeading.trueHeading
        Task { @MainActor in
            heading = h
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                startMonitoring()
            }
        }
    }

    // MARK: - 接近提醒引擎

    func checkAlerts(at coord: CLLocationCoordinate2D) {
        let now = Date()
        // 导航中：三档播报只播最近的一个路线点位（避免同路口多点位语音重叠/连播）
        if navigating {
            var nearest: Poi?
            var nd = Double.greatestFiniteMagnitude
            for p in pois where p.enabled && allPoiEnabled && enabledTypes.contains(p.type) && routePois.contains(where: { $0.id == p.id }) {
                let d = distanceM(coord, p.coordinate)
                if d < nd { nd = d; nearest = p }
            }
            if let p = nearest {
                let stage = alertStage[p.id] ?? 0
                if nd <= 500 && stage < 1 {
                    alertStage[p.id] = 1
                    status = "前方约\(Int(nd))米\(p.type.voicePrefix)，\(p.name)，请注意"
                    speak("前方约\(Int(nd))米\(p.type.voicePrefix)，\(p.name)，请注意")
                    updateLiveActivity(poiName: p.name, poiType: p.type.label, distanceM: Int(nd))
                } else if nd <= 300 && stage < 2 {
                    alertStage[p.id] = 2
                    status = "接近\(p.type.voicePrefix)点位：\(p.name)，请减速"
                    speak("接近\(p.type.voicePrefix)点位，\(p.name)，请减速")
                    updateLiveActivity(poiName: p.name, poiType: p.type.label, distanceM: Int(nd))
                } else if nd <= p.radiusM && stage < 3 {
                    alertStage[p.id] = 3
                    triggerAlert(p, distance: nd)
                    updateLiveActivity(poiName: p.name, poiType: p.type.label, distanceM: Int(nd))
                } else if nd > 500 {
                    alertStage[p.id] = 0
                }
            }
            return
        }
        for p in pois where p.enabled && allPoiEnabled && enabledTypes.contains(p.type) {
            let d = distanceM(coord, p.coordinate)
            if d <= p.radiusM {
                if let last = lastTrigger[p.id], now.timeIntervalSince(last) < 90 { continue }
                lastTrigger[p.id] = now
                triggerAlert(p, distance: d)
            } else {
                lastTrigger.removeValue(forKey: p.id)
            }
        }
    }

    private func triggerAlert(_ p: Poi, distance: Double) {
        let msg = "前方约\(Int(distance))米\(p.type.voicePrefix)，\(p.name)，请提前减速、注意信号灯"
        status = msg
        selectedPoi = p
        speak(msg)
        postLocalNotification(p, distance: distance)
        NotificationCenter.default.post(name: .motoAlert, object: p)
    }

    private func distanceM(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// 当前定位到点位的直线距离（UI 用）
    func distance(to p: Poi, from coord: CLLocationCoordinate2D) -> Double {
        distanceM(coord, p.coordinate)
    }

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
        let v = UserDefaults.standard.string(forKey: "xfVcn") ?? "xiaorong"
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
        // v1.81.4 后台语音播报：playback 会话（Info.plist 已含 audio 后台模式），导航切后台语音继续
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let now = Date()
        // 播报去重：2.5 秒内不连续播报（转向近提示/到达/超速高优先级可打断）
        if now.timeIntervalSince(lastSpeakAt) < 2.5 && priority <= lastSpeakPriority {
            if now.timeIntervalSince(lastSpeakAt) < 1.2 || lastSpeakText == text { return }
        }
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

    private func postLocalNotification(_ p: Poi, distance: Double) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "前方\(p.type.voicePrefix)"
        content.body = "\(p.name) · 距离约\(Int(distance))米 · 请提前减速、注意信号灯"
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "moto_\(p.id)", content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false))
        center.add(req)
    }

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
        checkAlerts(at: currentLocation!)
    }

    // MARK: - 点位增删改

    func addPoi(type: PoiType, name: String, lat: Double, lon: Double, radiusM: Double = 150) {
        repo.add(type: type, name: name, lat: lat, lon: lon, radiusM: radiusM)
        refreshPois()
    }

    func updatePoi(id: Int64, type: PoiType, name: String, lat: Double, lon: Double, radiusM: Double) {
        repo.update(id: id, type: type, name: name, lat: lat, lon: lon, radiusM: radiusM)
        refreshPois()
    }

    func deletePoi(id: Int64) {
        repo.remove(id: id)
        refreshPois()
    }

    func togglePoi(id: Int64) {
        guard let p = pois.first(where: { $0.id == id }) else { return }
        repo.setEnabled(id: id, enabled: !p.enabled)
        refreshPois()
    }

    func importPois(_ text: String) -> Int {
        let n = repo.importJson(text)
        refreshPois()
        return n
    }

    func exportPois() -> String { repo.exportJson() }

    private func refreshPois() {
        pois = repo.all()
        NotificationCenter.default.post(name: .motoPoisChanged, object: nil)
    }

    /// CarPlay 展示用：附近启用点位
    func nearbyPois(withinM meters: Double = 8000) -> [Poi] {
        guard let loc = currentLocation else { return pois.filter(\.enabled) }
        return pois.filter { $0.enabled && distanceM(loc, $0.coordinate) <= meters }
    }

    // MARK: - 点位筛选与总开关

    func setAllPoiEnabled(_ enabled: Bool) {
        allPoiEnabled = enabled
        checkFilterChanged()
    }

    func setTypeEnabled(_ type: PoiType, enabled: Bool) {
        if enabled { enabledTypes.insert(type) } else { enabledTypes.remove(type) }
        checkFilterChanged()
    }

    private func checkFilterChanged() {
        if !allPoiEnabled {
            status = "点位提醒已全部关闭"
        } else {
            status = "点位筛选：" + enabledTypes.map(\.label).joined(separator: "、")
        }
        NotificationCenter.default.post(name: .motoPoisChanged, object: nil)
    }

    // MARK: - 目的地搜索与路线规划

    /// 按名称在点位库中搜索；返回匹配列表（含类型标签）
    func searchPois(_ query: String) -> [Poi] {
        guard !query.isEmpty else { return [] }
        return pois.filter { fuzzyMatch($0.name, query) }
    }

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
        for p in pois { pool.insert(p.name) }
        for h in searchHistory { pool.insert(h) }
        for hf in hfPois { pool.insert(hf) }
        for lm in searchLandmarks where lm.matches(query) { pool.insert(lm.name) }
        // v1.45：地图上的小区/商铺/道路名标注全部进联想池（截图里的朱山郢、油坊新城等可搜到）
        for pl in placeLabels { pool.insert(pl.name) }
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            // 空输入：收藏 ⭐ 优先，其次历史，其次常驻点位
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
        return Array(matched.prefix(10))
    }

    /// 保存/清除高德 Key（didSet 自动持久化）
    func setAmapKey(_ k: String) { amapKey = k }

    /// 高德「输入提示」联想：输入关键字实时返回 POI 候选（名称+副标题+精确坐标），需用户填写高德 Web 服务 Key
    func amapInputTips(_ q: String) async -> [AmapTip] {
        guard !amapKey.isEmpty, !q.isEmpty else { return [] }
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        // 不限制城市，全国范围搜索，优先返回当前位置附近结果
        guard let url = URL(string: "https://restapi.amap.com/v3/assistant/inputtips?key=\(amapKey)&keywords=\(enc)&datatype=all") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tips = obj["tips"] as? [[String: Any]] else { return [] }
            var out: [AmapTip] = []
            for t in tips {
                guard let name = t["name"] as? String, !name.isEmpty,
                      let loc = t["location"] as? String, !loc.isEmpty else { continue }
                let parts = loc.split(separator: ",").compactMap { Double($0) }
                guard parts.count == 2 else { continue }
                let district = t["district"] as? String ?? ""
                let addr = t["address"] as? String ?? ""
                var sub = ""
                if !addr.isEmpty { sub += addr }
                if !district.isEmpty { sub += (sub.isEmpty ? "" : " · ") + district }
                if sub.isEmpty { sub = t["type"] as? String ?? "地点" }
                // v1.98 高德给的是 GCJ-02，转 WGS 后与地图/路线同一口径（否则点搜索结果会偏 500 米）
                let (wlat, wlon) = CoordConv.gcj2wgs(parts[1], parts[0])
                out.append(AmapTip(name: name, sub: sub, lat: wlat, lon: wlon))
            }
            return Array(out.prefix(20))
        } catch {
            return []
        }
    }

    /// 右下角定位按钮：地图回中
    func centerOnUser() {
        locateTick += 1
    }

    /// v1.81 两点矩形范围内抓拍点位数量（沿途估算）
    func snapCountBetween(_ from: CLLocationCoordinate2D, _ to: CLLocationCoordinate2D) -> Int {
        guard !pois.isEmpty else { return 0 }
        let minLat = min(from.latitude, to.latitude) - 0.004
        let maxLat = max(from.latitude, to.latitude) + 0.004
        let minLon = min(from.longitude, to.longitude) - 0.004
        let maxLon = max(from.longitude, to.longitude) + 0.004
        return pois.filter { p in
            p.enabled && allPoiEnabled && enabledTypes.contains(p.type)
                && p.lat >= minLat && p.lat <= maxLat
                && p.lon >= minLon && p.lon <= maxLon
        }.count
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

    /// 规划到任意目的地并高亮沿途抓拍点位（起点/终点自动吸附到最近道路出入口）
    func planRoute(to name: String, lat: Double, lon: Double) {
        guard let start = currentLocation else {
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
                                                          via: self.waypoint)
            let choices = self.preferMotoRoutes(rawChoices)
            if let r = choices.first {
                if choices.count > 1 {
                    routeChoices = choices.map { c -> RouteChoice in
                        RouteChoice(points: c.points, distanceM: c.distanceM, durationS: c.durationS,
                                    turns: c.turns, label: c.label,
                                    poiCount: nearbyPoisOnRoute(c.points).count, traffic: c.traffic)
                    }
                    selectedRouteIdx = 0
                }
                route = r.points
                routeTurns = r.turns
                routeDistanceM = r.distanceM
                routeDurationS = r.durationS
                lastTurnSpoken = -1
                farAnnounced.removeAll()
                let near = nearbyPoisOnRoute(r.points)
                routePois = near
                fitTick += 1
                riderRisks = RiderAnalyzer.risks(r.turns, totalM: r.distanceM)
                trafficSpans = r.traffic
                trafficLights = TrafficLightBuilder.lights(turns: r.turns)
                status = routeSummary(name, distanceM: r.distanceM, durationS: r.durationS, poiCount: near.count)
            } else {
                fallbackStraightLine(from: from, to: rawEnd, name: name, lat: lat, lon: lon)
            }
        }
    }

    /// 路线服务不可用时的兜底：画直线示意 + 明确提示（可能横穿禁行区） + 3秒后自动重试
    private func fallbackStraightLine(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D,
                                      name: String, lat: Double, lon: Double, walkLeg: [CLLocationCoordinate2D] = []) {
        route = walkLeg.isEmpty ? [from, to] : walkLeg + [to]
        routePois = nearbyPoisOnRoute(route)
        routeTurns = []
        routeDistanceM = 0
        routeDurationS = 0
        routeChoices = []
        trafficLights = []
        fitTick += 1
        status = "路线服务不可用，直线仅为示意（可能横穿不可通行区域），正在自动重试…"
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            // 目的地未变才替换（用户可能已改目标）
            guard self.destName == name, self.destLat == lat, self.destLon == lon else { return }
            let retry = await RouteFetcher.fetchAll(from: from, to: to, amapKey: amapKey,
                                                    via: self.waypoint)
            if retry.isEmpty { return }
            let list = retry.map { c -> RouteChoice in
                let n = nearbyPoisOnRoute(c.points).count
                return RouteChoice(points: c.points, distanceM: c.distanceM,
                                   durationS: c.durationS, turns: c.turns,
                                   label: c.label, poiCount: n, traffic: c.traffic)
            }
            routeChoices = list
            selectedRouteIdx = 0
            applyRouteChoice(list[0], name: name)
            status = "路线已恢复，请选择方案或开始导航"
        }
    }

    /// 路线摘要文字（高德式：短距离显示米、短时间显示"1分钟内"，避免"0.0公里/0分钟"）
    private func routeSummary(_ name: String, distanceM: Int, durationS: Int, poiCount: Int) -> String {
        let distTxt = distanceM < 1000 ? "\(distanceM)米" : String(format: "%.1f公里", Double(distanceM) / 1000.0)
        let timeTxt = durationS < 60 ? "1分钟内" : "\(durationS / 60)分钟"
        return "到「\(name)」约\(distTxt)，预计\(timeTxt)，沿途抓拍点\(poiCount)处，请留意"
    }

    func clearRoute() {
        navigating = false
        UIApplication.shared.isIdleTimerDisabled = false
        navigateFollowTick += 1
        route = []
        routePois = []
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

    /// "去这里/导航到这里"触发：获取多路线方案（起点=当前定位点，终点吸附到最近道路出入口）
    /// autoStart=true 时路线就绪后自动进入导航（地点信息卡"导航"按钮）
    func fetchRouteChoices(to name: String, lat: Double, lon: Double, autoStart: Bool = false) {
        guard let start = currentLocation else {
            status = "请先定位后再规划路线"
            return
        }
        destName = name; destLat = lat; destLon = lon
        addHistory(name)
        status = "正在规划到「\(name)」…"
        let from = start
        let rawEnd = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        Task {
            // v1.98 不再用 OSRM 做起点吸附/步行连接：OSM 路网与高德底图不同源，
            // 吸附点常落到高德认不出的路上，表现为"路线起点悬空、整条线压不到路"。
            // 高德规划接口本身会把起终点吸附到可通行道路，直接传原始坐标最稳。
            let choices = await RouteFetcher.fetchAll(from: from, to: rawEnd, amapKey: amapKey,
                                                      via: self.waypoint)
            if choices.isEmpty {
                fallbackStraightLine(from: from, to: rawEnd, name: name, lat: lat, lon: lon, walkLeg: [])
            } else {
                // 高德式：默认选中推荐方案并画路线，卡片可切换，底部绿色"开始导航"
                let list = self.preferMotoRoutes(choices).map { c -> RouteChoice in
                    let n = nearbyPoisOnRoute(c.points).count
                    return RouteChoice(points: c.points, distanceM: c.distanceM,
                                       durationS: c.durationS, turns: c.turns,
                                       label: c.label, poiCount: n, traffic: c.traffic)
                }
                routeChoices = list
                selectedRouteIdx = 0
                applyRouteChoice(list[0], name: name)
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
        let n = name ?? destName
        route = c.points
        routeTurns = c.turns
        routeDistanceM = c.distanceM
        routeDurationS = c.durationS
        lastTurnSpoken = -1
        farAnnounced.removeAll()
        let near = nearbyPoisOnRoute(c.points)
        routePois = near
        fitTick += 1
        // v1.99 骑行风险 + 路况（切方案时同步刷新）
        riderRisks = RiderAnalyzer.risks(c.turns, totalM: c.distanceM)
        trafficSpans = c.traffic
        trafficLights = TrafficLightBuilder.lights(turns: c.turns)
        lastRiskSpoken.removeAll()
        status = routeSummary(n, distanceM: c.distanceM, durationS: c.durationS, poiCount: near.count)
        if !riderRisks.isEmpty {
            let blocked = riderRisks.contains { $0.kind.motoBlocked }
            status += "；" + (blocked ? "⚠️ 含禁摩风险路段：" : "注意：") + RiderAnalyzer.summary(riderRisks)
        }
    }

    /// 筛选距路线折线 130 米内的点位
    private func nearbyPoisOnRoute(_ points: [CLLocationCoordinate2D]) -> [Poi] {
        guard points.count >= 2 else { return [] }
        return pois.filter { p in
            guard p.enabled && allPoiEnabled && enabledTypes.contains(p.type) else { return false }
            var minD = Double.greatestFiniteMagnitude
            for i in 0..<(points.count - 1) {
                let d = distToSegment(p.coordinate, points[i], points[i + 1])
                if d < minD { minD = d }
            }
            return minD <= 130.0
        }
    }

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
            routeChoices = [] // v1.85 结束导航隐藏路线推荐卡，只保留行程卡（轻点卡片外任意处回首页）
            selectedRouteIdx = 0
            finishTrip()
            endLiveActivity()
            speak("导航结束")
            status = "导航已结束"
        } else {
            guard route.count >= 2 else { status = "请先搜索目的地并规划路线"; return }
            navigating = true
            UIApplication.shared.isIdleTimerDisabled = true // 导航中屏幕常亮（高德式）
            pitchDeg = 45         // v2.01 开始导航：3D 45° 俯视 + 约 200 米视野（见 MapView）
            navigateFollowTick += 1
            tripSummary = nil // v1.81.4 新导航开始时清除上次行程卡
            navStart = Date()
            // v1.99 轨迹重新开始
            trackPoints.removeAll()
            maxSpeedKph = 0
            lastRiskSpoken.removeAll()
            alertStage = [:]
            offRouteCount = 0
            arriveAnnounced = false
            startMonitoring()
            startLiveActivity(destName: destName)
            speak("开始导航到\(destName)，请按路线行驶")
            status = "导航中 → \(destName)"
        }
    }

    // MARK: - Live Activity（灵动岛/锁屏违拍提醒）

    /// 开始导航 → 启动灵动岛活动
    private func startLiveActivity(destName: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attr = MotoNavAttributes(destName: destName)
        let initial = MotoNavAttributes.ContentState(poiName: "已出发", poiType: "违拍提醒", distanceM: 0)
        do {
            liveActivity = try Activity<MotoNavAttributes>.request(
                attributes: attr, contentState: initial, pushType: nil)
        } catch {
            liveActivity = nil
        }
    }

    /// 接近违拍点 → 更新灵动岛内容（最近路线点位，三档渐进）
    private func updateLiveActivity(poiName: String, poiType: String, distanceM: Int) {
        guard let act = liveActivity else { return }
        let state = MotoNavAttributes.ContentState(poiName: poiName, poiType: poiType, distanceM: distanceM)
        Task {
            await act.update(using: state)
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

    /// 行程总结（到达或退出导航时生成）
    private func finishTrip() {
        guard let start = navStart else { return }
        let dur = Int(Date().timeIntervalSince(start))
        let avg = dur > 0 ? (Double(routeDistanceM) / 1000.0) / (Double(dur) / 3600.0) : 0
        tripSummary = TripSummary(
            destName: destName,
            distanceM: routeDistanceM,
            durationS: dur,
            snapCount: routePois.count,
            avgSpeedKmh: avg)
        // v1.99 足迹存档：轨迹抽稀后写入本地（里程过短不记）
        let pts = trackPoints.count >= 2 ? trackPoints : route
        FootprintStore.shared.add(Footprint(
            destName: destName,
            startedAt: start,
            distanceM: routeDistanceM,
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
        var minD = Double.greatestFiniteMagnitude
        for i in 0..<(route.count - 1) {
            let d = distToSegment(coord, route[i], route[i + 1])
            if d < minD { minD = d }
        }
        offRouteCount = (minD > 80) ? offRouteCount + 1 : 0
        guard offRouteCount >= 3, Date().timeIntervalSince(lastReroute) > 25 else { return }
        offRouteCount = 0
        lastReroute = Date()
        speak("路线已重新规划，请按新路线行驶")
        status = "路线已重新规划，请按新路线行驶"
        guard let start = currentLocation else { return }
        Task {
            // v1.98 偏航重规划也走高德（与规划同源），不再用 OSRM 吸附终点
            let dest = CLLocationCoordinate2D(latitude: destLat, longitude: destLon)
            let choices = await RouteFetcher.fetchAll(from: start, to: dest, amapKey: amapKey,
                                                      via: self.waypoint)
            if let r = choices.first {
                route = r.points
                routeTurns = r.turns
                routeDistanceM = r.distanceM
                routeDurationS = r.durationS
                routePois = nearbyPoisOnRoute(r.points)
                lastTurnSpoken = -1
                farAnnounced.removeAll()
                alertStage = [:]
                fitTick += 1
                // v1.99 偏航重规划后风险/路况同步刷新
                riderRisks = RiderAnalyzer.risks(r.turns, totalM: r.distanceM)
                trafficSpans = r.traffic
                trafficLights = TrafficLightBuilder.lights(turns: r.turns)
            }
        }
    }

    // MARK: - v1.99 摩托优先 / 风险播报 / 途经点 / 沿途服务

    /// 方案排序：开启"避开高速/高架"时按禁摩风险排序，并把首条标为"推荐"
    func preferMotoRoutes(_ list: [RouteChoice]) -> [RouteChoice] {
        guard !list.isEmpty else { return [] }
        var ordered = list
        if avoidHighway, list.count > 1 {
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
        let f = ordered[0]
        ordered[0] = RouteChoice(points: f.points, distanceM: f.distanceM, durationS: f.durationS,
                                 turns: f.turns, label: "推荐", poiCount: f.poiCount, traffic: f.traffic)
        return ordered
    }

    // MARK: - v2.04 官方电警接近提醒（不需要导航）

    /// 接近合肥交警公示的电警/卡口点位时提醒一次。
    ///
    /// 三条设计约束，都是踩过的坑：
    /// 1. **用位移判定"在移动"而不是 speed**：隧道、树荫、桥下 speed 长期为 0，
    ///    用 speed 判断会出现"车在开却不提醒"；位移 ≥20m 更稳。
    /// 2. **进入 260m 播报、离开 400m 重新武装**：单个阈值会在临界点反复触发刷屏。
    /// 3. **和导航播报错峰**：转向指令优先级 2/3，这里用 1，撞车时延迟 3.5 秒再补一次，
    ///    否则「前方 200 米左转」刚播完，电警提醒会被 2.5 秒静默窗口吞掉。
    func checkPoliceCameras(at coord: CLLocationCoordinate2D, force: Bool = false) {
        let store = PoliceCameraStore.shared
        guard store.voiceOn else { return }
        if !force {
            let moved = camLastPos.map { distanceM($0, coord) } ?? .greatestFiniteMagnitude
            guard moved >= 20 else { return }
            camLastPos = coord
        }

        // 已经离开 400m 的点位解除武装（下次靠近还能再报）
        if !camArmed.isEmpty {
            var keep: Set<Int> = []
            for c in store.all where camArmed.contains(c.id) {
                if distanceM(coord, c.coordinate) <= 400 { keep.insert(c.id) }
            }
            camArmed = keep
        }

        // 找 260m 内最近的一个
        var best: (PoliceCamera, Double)?
        for c in store.all {
            let d = distanceM(coord, c.coordinate)
            if d <= 260 {
                if best == nil || d < best!.1 { best = (c, d) }
            }
        }
        guard let (cam, d) = best else { return }
        guard !camArmed.contains(cam.id) else { return }
        if let t = camSpokenAt[cam.id], Date().timeIntervalSince(t) < 120 {
            camArmed.insert(cam.id)
            return
        }
        // 与导航播报错峰：3 秒内刚播过别的内容，就 3.5 秒后再来（此时人已更靠近，判定仍有效）
        if !force, Date().timeIntervalSince(lastSpeakAt) < 3.0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                guard let self, let loc = self.currentLocation else { return }
                self.checkPoliceCameras(at: loc, force: true)
            }
            return
        }

        camArmed.insert(cam.id)
        camSpokenAt[cam.id] = Date()
        hotCameraId = cam.id
        let meters = max(10, Int((d / 10).rounded()) * 10)
        speak("前方\(meters)米，\(cam.spokenName)，\(cam.type.voiceAction)", priority: 1)
        showCameraBanner("\(cam.type.title) · \(cam.spokenName) · \(meters) 米")
    }

    /// 顶部横幅：8 秒后自动收起，同时把地图上高亮的点恢复
    private func showCameraBanner(_ text: String) {
        camBannerTask?.cancel()
        cameraAlert = text
        let task = DispatchWorkItem { [weak self] in
            self?.cameraAlert = nil
            self?.hotCameraId = 0
        }
        camBannerTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: task)
    }

    /// 手动点"电警"按钮时看一眼附近：给用户一个"离我最近的拍照点在哪"的反馈
    func describeNearbyCameras() {
        guard let loc = currentLocation else {
            status = "还没定位到，稍后再试"
            return
        }
        let near = PoliceCameraStore.shared.nearest(to: loc, limit: 3)
        guard let first = near.first else {
            status = "附近 5 公里内没有已收录的官方电警点位"
            return
        }
        let parts = near.map { c, d in "\(c.name) \(Int(d))米" }
        status = "最近拍照点：" + parts.joined(separator: "；")
        hotCameraId = first.0.id
        showCameraBanner("\(first.0.type.title) · \(first.0.spokenName) · \(Int(first.1)) 米")
    }

    /// 导航中：向前 500 米内出现禁摩/隧道/高架等风险段时播报（每段只报一次）
    private func checkRiderRisks(at coord: CLLocationCoordinate2D) {
        guard navigating, !riderRisks.isEmpty, speechMode != .simple else { return }
        let remain = route.last.map { distanceM(coord, $0) } ?? 0
        let traveled = max(0, routeDistanceM - Int(remain))
        for r in riderRisks where r.ahead(of: traveled) {
            guard !lastRiskSpoken.contains(r.id) else { continue }
            let d = Double(r.fromM - traveled)
            guard d >= 0, d < 500 else { continue }
            lastRiskSpoken.insert(r.id)
            let road = r.roadName.isEmpty ? "" : "（\(r.roadName)）"
            speak("前方\(Int(d))米进入\(r.kind.title)\(road)，\(r.kind.advice)", priority: 2)
            status = "⚠️ 前方\(Int(d))米\(r.kind.title)"
        }
    }

    /// 顺路加一站：设置途经点并重新规划（保留原终点）
    func setWaypoint(name: String, lat: Double, lon: Double) {
        waypoint = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        waypointName = name
        status = "已顺路添加「\(name)」，正在重新规划…"
        guard destLat != 0 || destLon != 0 else { return }
        fetchRouteChoices(to: destName, lat: destLat, lon: destLon, autoStart: false)
    }

    func clearWaypoint() {
        waypoint = nil
        waypointName = ""
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

    /// 高德关键词周边搜索（返回按距离升序）
    func amapKeywordSearch(_ keyword: String, lat: Double, lon: Double, radius: Int = 8000) async -> [AmapTip] {
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
                if !dist.isEmpty { sub += " · 距路线\(Int(Double(dist) ?? 0))米" }
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
            // v1.90 到达震动提醒（骑行中不低头也感知到站）
            vibrationArrived()
            navigating = false
            UIApplication.shared.isIdleTimerDisabled = false
            navigateFollowTick += 1
            finishTrip()
            endLiveActivity()
            routePois = []
            return
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
            // 高德式两段播报：远提示（800 米级，含路名）→ 近提示（150 米内）
            // v1.99 播报分级：简洁只报近点；标准/详细保留 800 米远提示，详细再加剩余里程
            if speechMode.farPrompt && best < 900 && !farAnnounced.contains(idx) {
                farAnnounced.insert(idx)
                let road = t.roadName.isEmpty ? "" : "，进入\(t.roadName)"
                speak("前方\(Int(best))米\(text)\(road)")
                status = "导航：前方\(Int(best))米\(text)\(road) · 余\(Int(toDest / 1000))公里"
            } else if best < 150 {
                lastTurnSpoken = idx
                if speechMode.verbose {
                    let tail = toDest > 1000 ? "，剩余\(Int(toDest / 1000))公里" : ""
                    speak("\(text)，距您\(Int(best))米\(tail)")
                } else {
                    speak("\(text)，距您\(Int(best))米")
                }
                status = "导航：\(text) 距\(Int(best))米 · 余\(Int(toDest / 1000))公里"
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
        guard navigating, let loc = currentLocation, !route.isEmpty else { return "" }
        let toDest = distanceM(loc, route.last ?? CLLocationCoordinate2D(latitude: destLat, longitude: destLon))
        let traveled = max(0, routeDistanceM - Int(toDest))
        var name = ""
        for t in routeTurns where t.fromStartM <= traveled {
            if !t.roadName.isEmpty { name = t.roadName }
        }
        return name
    }

    /// 沿路线折线累计已走距离（米）：定位点到折线的最近点（含前段距离）
    /// v2.02 行进里程（增量搜索）
    ///
    /// 旧实现每次调用都线性扫完整条路线（几千点），而导航卡每秒刷新会调用 2~3 次
    /// （navigationStatus / nextTrafficLight / currentRoadName 各一次）→ 每秒上万次距离计算，
    /// 这是导航中"地图发涩、卡片一顿一顿"的主要来源。
    /// 现在只在上次位置附近 ±80 个点里找最近点，跑到窗口边缘才做一次全量校正。
    private var traveledCacheIdx = 0
    private var traveledRouteKey = ""

    private func traveledM(_ pts: [CLLocationCoordinate2D], _ loc: CLLocationCoordinate2D) -> Int {
        guard pts.count > 1 else { return 0 }
        let key = "\(pts.count)-\(pts[0].latitude)-\(pts[pts.count - 1].longitude)"
        if key != traveledRouteKey {
            traveledRouteKey = key
            traveledCacheIdx = 0
        }
        let lo = max(0, traveledCacheIdx - 80)
        let hi = min(pts.count - 1, traveledCacheIdx + 80)
        var bestI = lo
        var bestD = Double.greatestFiniteMagnitude
        for i in lo...hi {
            let d = distanceM(loc, pts[i])
            if d < bestD { bestD = d; bestI = i }
        }
        // 最近点贴着窗口边缘 → 说明可能已经跑出窗口，全量校正一次
        if (bestI == lo && lo > 0) || (bestI == hi && hi < pts.count - 1) {
            for i in pts.indices {
                let d = distanceM(loc, pts[i])
                if d < bestD { bestD = d; bestI = i }
            }
        }
        traveledCacheIdx = bestI
        var acc = 0.0
        for i in 0..<bestI { acc += distanceM(pts[i], pts[i + 1]) }
        return Int(acc + bestD / 2)
    }

    private func turnText(_ t: RouteTurn) -> String {
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
        case "fork": return t.modifier.contains("left") ? "前方分岔，靠左" : t.modifier.contains("right") ? "前方分岔，靠右" : "前方分岔，请减速选择车道"
        case "end of road": return t.modifier.contains("left") ? "前方道路尽头，左转" : "前方道路尽头，右转"
        case "continue": return "继续直行"
        case "roundabout": return "进入环岛，按指示方向行驶"
        case "uturn": return "前方掉头"
        case "arrive": return "即将到达目的地"
        default: return "前方注意路况"
        }
    }
}
