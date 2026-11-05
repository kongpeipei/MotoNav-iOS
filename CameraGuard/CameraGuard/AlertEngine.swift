import Foundation
import CoreLocation
import AVFoundation
import UIKit
import UserNotifications
import CoreHaptics
import ActivityKit

/// TTS 引擎选择（优化 #1：保留系统默认，给高级用户留讯飞接入点）
enum TtsProvider: String, CaseIterable, Identifiable, Codable {
    case system       // 系统 AVSpeechSynthesizer（推荐，零延迟、离线可用）
    case iflytekPro   // 讯飞在线合成（需自行接入 SDK，延迟较高，耗流量）

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system:     return "系统语音（推荐，离线零延迟）"
        case .iflytekPro: return "讯飞在线合成（自定义 vcn，需填 AppID/APIKey）"
        }
    }
}

/// 自定义讯飞语音包（v1.5：不再内置预设；填写 vcn 即自动建档，名称可编辑、可左滑删除）
struct VoicePack: Identifiable, Codable, Equatable {
    var vcn: String      // 同时作为唯一标识
    var name: String
    var id: String { vcn }

    init(vcn: String, name: String) {
        self.vcn = vcn
        self.name = name
    }
}

/// 速度自适应预警距离系数（引擎判定与首页显示共用，避免两处阈值漂移）
/// 入参单位为 m/s；低速步行/骑行 1.0×，提速后逐步放大提前量。
enum AdaptiveWarn {
    static func factor(speedMetersPerSecond speed: Double) -> Double {
        switch speed {
        case ...10:  return 1.0   // ≤36 km/h
        case ...15:  return 1.2   // ≤54 km/h
        case ...22:  return 1.5   // ≤80 km/h
        default:     return 2.0
        }
    }
    static func effectiveDistance(base: Double, speedMetersPerSecond speed: Double) -> Double {
        base * factor(speedMetersPerSecond: speed)
    }
}

/// 核心引擎：持续定位 → 匹配最近违法拍照点 → 接近时语音播报（支持后台运行）
/// 优化点：A 速度自适应预警距离 / B 双保险节流 / C 震动反馈 / D 纬度分桶查找 / F 通知权限
@MainActor
final class AlertEngine: NSObject, ObservableObject, CLLocationManagerDelegate {

    // MARK: - UI 绑定状态

    @Published var statusText = "启动中…"
    @Published var location: CLLocation?
    @Published var speedKmh: Double = 0
    @Published var nearest: Poi?
    @Published var nearestDistance: Double = .greatestFiniteMagnitude
    @Published var announcements: [Announcement] = []
    @Published var isMonitoring = false
    @Published var enabledTypes: Set<PoiType>
    @Published var warnDistance: Double
    /// v1.6 震动反馈：持续时间（秒，0 = 关闭）与强度（0~1）
    @Published var hapticDuration: Double
    @Published var hapticIntensity: Double
    /// v1.7 上次开启时的时长：关闭震动后再打开恢复原值，而不是从 1 秒重新开始
    private var hapticLastDuration: Double
    /// v1.6 是否弹「改为始终定位」引导（仅当当前授权为「使用期间」时）
    @Published var showAlwaysPrompt = false
    @Published var ttsProvider: TtsProvider
    @Published var xfAppID: String
    @Published var xfAPIKey: String
    @Published var xfAPISecret: String
    @Published var xfVcn: String
    /// 最近一次 TTS 结果反馈（用于 UI 显示讯飞是否成功 / 回退）
    @Published var ttsFeedback: String = ""
    /// 用户自定义点位（持久化在 UserDefaults）
    @Published var userPois: [Poi] = []
    /// 自定义讯飞语音包（v1.5：空列表为初始状态，填写 vcn 后自动添加）
    @Published var voicePacks: [VoicePack] = []
    /// v1.8 内置点位编辑台账：已删除的内置点位 id 与补丁（名称/半径/启用状态覆盖）
    @Published private(set) var deletedBuiltinIds: Set<String> = []
    @Published private(set) var builtinPatches: [String: Poi] = [:]

    // MARK: - v1.9 悬浮球 / 弹窗 / 灵动岛

    /// 悬浮球总开关（高级设置第一项）
    @Published var floatEnabled: Bool = true
    /// 悬浮球是否允许拖动（位置归一化 0~1 持久化）
    @Published var floatDraggable: Bool = true
    /// 接近抓拍点时的顶部弹窗停留时长（1~10 秒，默认 1.2）
    @Published var bannerDuration: Double = 1.2
    /// 后台/锁屏时是否使用灵动岛实时活动
    @Published var liveActivityEnabled: Bool = true
    /// 悬浮球当前位置（归一化坐标，0~1）
    @Published var ballPosition: CGPoint = CGPoint(x: 0.88, y: 0.80)

    /// 当前打包版本号（读取 CFBundleShortVersionString，供分享文案使用）
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.10"
    }

    // MARK: - v1.10 CarPlay（音频类）

    /// 是否已连接 CarPlay 车机（音频路由检测）
    @Published var carPlayConnected = false
    /// 顶部弹窗当前文案（nil 表示不显示）
    @Published var bannerText: String?
    /// 是否处于抓拍预警状态（悬浮球红色 + 灵动岛警告态）
    @Published private(set) var floatWarning: Bool = false
    /// 当前预警对应的点位 id（离开预警半径时清空）
    private var activeWarningId: String?
    private var bannerTask: Task<Void, Never>?
    private var liveActivity: Activity<CameraGuardActivityAttributes>?


    /// 内置点位生效列表 = 内置 - 已删除，再叠加用户补丁（坐标与类型始终不变）
    var builtinPois: [Poi] {
        basePois.filter { !deletedBuiltinIds.contains($0.id) }
            .map { builtinPatches[$0.id] ?? $0 }
    }

    /// v1.11 内置点位基础库：云端更新库（在线更新后持久化）优先，否则回退 Bundle 内置库
    var basePois: [Poi] {
        remotePois.isEmpty ? bundledPois : remotePois
    }

    /// 全部有效点位 = 内置（含补丁/删除）+ 用户自定义（均过滤 enabled=true）
    /// 结果缓存：定位回调、UI 计数、分桶索引都会读取，避免每次重新 filter 两个数组。
    private var cachedPois: [Poi] = []
    private var poiCacheValid = false
    var pois: [Poi] {
        if poiCacheValid { return cachedPois }
        let bundled = builtinPois.filter { $0.enabled }
        let custom  = userPois.filter { $0.enabled }
        cachedPois = bundled + custom
        poiCacheValid = true
        return cachedPois
    }

    private func invalidatePoiCache() {
        poiCacheValid = false
    }

    /// 当前发音人的显示名（未建档时回退到 vcn 原值）
    var voiceDisplayName: String {
        voicePacks.first { $0.vcn == xfVcn }?.name ?? (xfVcn.isEmpty ? "未设置" : xfVcn)
    }

    // MARK: - 私有属性

    private let lm = CLLocationManager()
    private(set) var bundledPois: [Poi] = []
    /// v1.11 云端点位库（在线更新结果，持久化到 UserDefaults；为空时回退 Bundle 内置库）
    private(set) var remotePois: [Poi] = []
    /// v1.11 在线更新状态文案（点位管理页展示）
    @Published var remoteUpdateStatus: String = ""
    /// 已播报点位 id（published 供首页显示「已播报」状态，避免播报后仍显示「即将播报」）
    @Published private(set) var announced: Set<String> = []
    /// v1.4 功耗自适应：当前是否处于高精度模式（低速/静止时降精度省电）
    private var highAccuracyMode = true
    private var lastSpeak = Date.distantPast
    private let speech = AVSpeechSynthesizer()
    private var xfyunTTS: XfyunTTS?
    private let haptics = HapticsPlayer()
    private var isTestingSpeech = false          // 测试按钮防重入

    /// 优化 D：纬度分桶索引（每 0.01° ≈ 1.11km，一个桶覆盖约 1.1km×1km 区域）
    private var latBuckets: [Int: [Poi]] = [:]
    private let bucketStep: Double = 0.01

    // MARK: - 初始化

    override init() {
        // 从 UserDefaults 读取设置
        let defaults = UserDefaults.standard
        if let raw = defaults.stringArray(forKey: "enabledTypes") {
            self.enabledTypes = Set(raw.compactMap { PoiType(rawValue: $0) })
        } else {
            self.enabledTypes = Set(PoiType.allCases)
        }

        self.warnDistance = defaults.object(forKey: "warnDistance") as? Double ?? 500
        self.hapticDuration = defaults.object(forKey: "hapticDuration") as? Double ?? 0.4
        self.hapticIntensity = defaults.object(forKey: "hapticIntensity") as? Double ?? 0.8
        self.hapticLastDuration = defaults.object(forKey: "hapticLastDuration") as? Double ?? 1.0
        // 默认使用离线系统语音；讯飞凭证一律由用户在「语音引擎」页自行填写，源码不内置任何密钥
        self.ttsProvider = TtsProvider(rawValue: defaults.string(forKey: "ttsProvider") ?? "") ?? .system
        self.xfAppID = defaults.string(forKey: "xfAppID") ?? ""
        self.xfAPIKey = defaults.string(forKey: "xfAPIKey") ?? ""
        self.xfAPISecret = defaults.string(forKey: "xfAPISecret") ?? ""
        self.xfVcn = defaults.string(forKey: "xfVcn") ?? "xiaoyan"

        // 加载 Bundle 内置点位：逐元素解码，单条坏数据不会导致整个数组解析失败而全部丢失
        if let url = Bundle.main.url(forResource: "poi", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            bundledPois = Self.parsePois(raw)
        }

        // 加载用户自定义点位
        if let data = defaults.data(forKey: "userPois"),
           let decoded = try? JSONDecoder().decode([Poi].self, from: data) {
            userPois = decoded
        }

        super.init()

        // v1.5 加载自定义语音包（须在 super.init() 之后读写 @Published 属性）；
        // 老用户已有 xfVcn 但没有包时，自动补一个（只补一次）
        loadVoicePacks()
        // v1.8 加载内置点位的删除/补丁台账（同样在 super.init() 之后）
        loadBuiltinLedger()
        // v1.9 加载悬浮球/弹窗/灵动岛设置与悬浮球位置
        loadFloatSettings()
        // v1.11 恢复云端点位库（在线更新结果持久化）
        loadRemotePois()

        lm.delegate = self
        // v1.4：初始按「行驶中」配置；低速/静止后自动切成低精度低频，减少骑行者电池消耗
        lm.desiredAccuracy = kCLLocationAccuracyBest
        lm.activityType = .otherNavigation
        lm.distanceFilter = 10   // 高速时需要更密的采样，保证预警及时
        lm.pausesLocationUpdatesAutomatically = false
        lm.allowsBackgroundLocationUpdates = true
        lm.showsBackgroundLocationIndicator = true

        invalidatePoiCache()
        rebuildIndex()
        configureAudio()
        // v1.10 CarPlay：监听音频路由变化（连接/断开车机），连接时自动开始监听
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    /// v1.5：从 UserDefaults 恢复语音包；无任何包但已有 vcn 时补一条同名包
    private func loadVoicePacks() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "voicePacks"),
           let decoded = try? JSONDecoder().decode([VoicePack].self, from: data) {
            voicePacks = decoded
        }
        let initialVcn = (defaults.string(forKey: "xfVcn") ?? "xiaoyan").trimmingCharacters(in: .whitespacesAndNewlines)
        if !initialVcn.isEmpty, !voicePacks.contains(where: { $0.vcn == initialVcn }) {
            voicePacks = [VoicePack(vcn: initialVcn, name: initialVcn)]
        }
    }

    /// v1.8：恢复内置点位删除/补丁台账
    private func loadBuiltinLedger() {
        let defaults = UserDefaults.standard
        if let arr = defaults.stringArray(forKey: "deletedBuiltinIds") {
            deletedBuiltinIds = Set(arr)
        }
        if let data = defaults.data(forKey: "builtinPatches"),
           let decoded = try? JSONDecoder().decode([String: Poi].self, from: data) {
            builtinPatches = decoded
        }
    }

    /// v1.9：恢复悬浮球/弹窗/灵动岛设置与悬浮球位置（归一化坐标）
    private func loadFloatSettings() {
        let defaults = UserDefaults.standard
        if let v = defaults.object(forKey: "floatEnabled") as? Bool { floatEnabled = v }
        if let v = defaults.object(forKey: "floatDraggable") as? Bool { floatDraggable = v }
        if let v = defaults.object(forKey: "bannerDuration") as? Double { bannerDuration = v }
        if let v = defaults.object(forKey: "liveActivityEnabled") as? Bool { liveActivityEnabled = v }
        let x = defaults.object(forKey: "floatBallX") as? Double ?? 0.88
        let y = defaults.object(forKey: "floatBallY") as? Double ?? 0.80
        ballPosition = CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    // MARK: - v1.11 点位在线更新（云端点位库）

    /// 云端点位库地址：仓库 main 分支的 poi.json（随仓库更新即全网同步，零服务器成本）
    static let remotePointsURL = "https://raw.githubusercontent.com/kongpeipei/MotoNav-iOS/main/CameraGuard/CameraGuard/poi.json"

    /// 逐条解析点位数组（坏条目跳过），Bundle 内置库与云端更新共用同一解析
    private static func parsePois(_ raw: [[String: Any]]) -> [Poi] {
        raw.compactMap { dict -> Poi? in
            guard let name = dict["name"] as? String,
                  let typeRaw = dict["type"] as? String,
                  let type = PoiType(rawValue: typeRaw),
                  let lat = (dict["lat"] as? NSNumber)?.doubleValue,
                  let lon = (dict["lon"] as? NSNumber)?.doubleValue else { return nil }
            return Poi(name: name, type: type, latitude: lat, longitude: lon,
                       radiusM: (dict["radiusM"] as? NSNumber)?.doubleValue ?? 500,
                       enabled: (dict["enabled"] as? Bool) ?? true)
        }
    }

    /// 恢复上次在线更新保存的云端点位库
    private func loadRemotePois() {
        if let data = UserDefaults.standard.data(forKey: "remotePois"),
           let decoded = try? JSONDecoder().decode([Poi].self, from: data),
           !decoded.isEmpty {
            remotePois = decoded
        }
    }

    /// 检查并应用云端最新点位库：下载 → 逐条校验 → 持久化 → 重建索引并立即生效
    func checkRemotePointsUpdate() {
        remoteUpdateStatus = "正在检查更新…"
        guard let url = URL(string: Self.remotePointsURL) else {
            remoteUpdateStatus = "更新地址无效"
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let task = URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.remoteUpdateStatus = "检查更新失败：\(error.localizedDescription)"
                    return
                }
                guard let data,
                      let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                      !raw.isEmpty else {
                    self.remoteUpdateStatus = "点位数据为空或格式错误"
                    return
                }
                let decoded = Self.parsePois(raw)
                guard !decoded.isEmpty else {
                    self.remoteUpdateStatus = "解析失败，请稍后再试"
                    return
                }
                let added = decoded.count - self.remotePois.count
                self.remotePois = decoded
                if let d = try? JSONEncoder().encode(decoded) {
                    UserDefaults.standard.set(d, forKey: "remotePois")
                }
                let dateText = Date().formatted(date: .numeric, time: .omitted)
                var msg = "更新完成：共 \(decoded.count) 个点位（\(dateText)）"
                if added > 0 { msg += "，新增 \(added) 个" }
                self.remoteUpdateStatus = msg
                self.invalidatePoiCache()
                self.rebuildIndex()
                // 同步刷新 CarPlay 卡片与灵动岛的点位数
                CarPlaySupport.pointsCountSnapshot = self.pois.count
                CarPlaySupport.updateNowPlaying()
                self.updateLiveActivity()
            }
        }
        task.resume()
    }

    // MARK: - 索引（优化 D：纬度分桶 + 邻桶扫描）

    /// 重建分桶索引（每次新增/删除用户点位或过滤条件变化后调用）
    func rebuildIndex() {
        invalidatePoiCache()
        latBuckets.removeAll(keepingCapacity: true)
        for p in pois {
            let key = Int(p.latitude / bucketStep)
            latBuckets[key, default: []].append(p)
        }
    }

    /// 基于分桶的近邻查找（优化 D：先筛桶再算距离，O(桶内数量)）
    private func findNearest(relativeTo loc: CLLocation) -> (Poi, Double)? {
        let latKey = Int(loc.coordinate.latitude / bucketStep)
        // 扫描当前桶 + 上下各 2 个纬度桶（5 × 0.01° ≈ 5.5km 纬度范围，覆盖 warnDistance=1000m 加余量）
        var best: Poi?
        var bestD = Double.greatestFiniteMagnitude
        for dLat in -2...2 {
            let key = latKey + dLat
            guard let bucket = latBuckets[key] else { continue }
            for p in bucket where enabledTypes.contains(p.type) {
                // 度单位粗筛：经度差乘 cos(纬度) 折算后与纬度差比较，先剔除远距离候选，减少 CLLocation 构造
                let deltaLat = (p.latitude - loc.coordinate.latitude)
                let deltaLon = (p.longitude - loc.coordinate.longitude) * cos(loc.coordinate.latitude * .pi / 180)
                if hypot(deltaLat, deltaLon) > 0.025 { continue }   // 0.025° ≈ 2.8km 上限
                let d = loc.distance(from: CLLocation(latitude: p.latitude, longitude: p.longitude))
                if d < bestD {
                    bestD = d
                    best = p
                }
            }
        }
        return best.map { ($0, bestD) }
    }

    // MARK: - 生命周期

    func start() {
        // 优化 F：启动时请求通知权限（兜底）
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            }
        }

        switch lm.authorizationStatus {
        case .notDetermined:
            lm.requestAlwaysAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            begin()
        case .denied, .restricted:
            statusText = "定位权限被拒绝，请在系统设置中开启"
        @unknown default:
            begin()
        }
    }

    private func begin() {
        guard !isMonitoring else { return }
        if needsAlwaysUpgrade { showAlwaysPrompt = true }
        lm.startUpdatingLocation()
        isMonitoring = true
        statusText = "监听中 · 已载入 \(pois.count) 个点位"
        // v1.9：开始监听时同步开启灵动岛实时活动（后台/锁屏可见）
        startLiveActivity()
        // v1.10 CarPlay：启动静音占位流（保持「正在播放」，连接车机后自动恢复并走车载音响）
        CarPlaySupport.isMonitoringSnapshot = true
        CarPlaySupport.pointsCountSnapshot = pois.count
        CarPlaySupport.startSilenceStream()
        CarPlaySupport.updateNowPlaying()
    }

    /// v1.6：当前是否只是「使用期间」授权 —— 是则 App 启动时弹引导，建议升级为「始终」
    var needsAlwaysUpgrade: Bool {
        lm.authorizationStatus == .authorizedWhenInUse
    }

    /// 请求升级为「始终」定位（系统会弹确认）
    func requestAlwaysAuthorization() {
        lm.requestAlwaysAuthorization()
    }

    func stop() {
        lm.stopUpdatingLocation()
        isMonitoring = false
        statusText = "已暂停监听"
        // v1.9：暂停监听时结束灵动岛实时活动
        endLiveActivity()
        // v1.10 CarPlay：停止静音占位流并刷新卡片为「已暂停」
        CarPlaySupport.isMonitoringSnapshot = false
        CarPlaySupport.stopSilenceStream()
        CarPlaySupport.updateNowPlaying()
    }

    // MARK: - v1.10 CarPlay 连接检测（AVAudioSession 路由变化）

    @objc nonisolated private func handleAudioRouteChange(_ note: Notification) {
        Task { @MainActor in self.processAudioRouteChange() }
    }

    private func processAudioRouteChange() {
        let onCar = CarPlaySupport.isConnectedToCarPlay()
        CarPlaySupport.isMonitoringSnapshot = isMonitoring
        CarPlaySupport.pointsCountSnapshot = pois.count
        if onCar != carPlayConnected {
            carPlayConnected = onCar
            if onCar {
                statusText = isMonitoring ? "监听中 · 已连接 CarPlay" : "已连接 CarPlay · 自动开始监听"
                // 用户诉求：连上 CarPlay 自动启动监听（已有定位授权时）
                if !isMonitoring {
                    let st = lm.authorizationStatus
                    if st == .authorizedAlways || st == .authorizedWhenInUse {
                        begin()
                    }
                }
            } else {
                statusText = isMonitoring ? "监听中" : "已暂停监听"
            }
        }
        CarPlaySupport.updateNowPlaying()
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedAlways:
                statusText = "已允许始终定位 · 后台播报可用"
                begin()
            case .authorizedWhenInUse:
                statusText = "仅使用期间定位 · 建议设为“始终”以支持锁屏后台播报"
                showAlwaysPrompt = true   // v1.6：启动/授权变化时引导升级，避免后台不播报
                begin()
            case .denied, .restricted:
                statusText = "定位权限被拒绝，请在系统设置中开启"
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in process(loc) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if (error as? CLError)?.code == .denied {
                statusText = "定位失败：权限被拒绝"
            }
        }
    }

    // MARK: - 核心逻辑（优化 A/B）

    private func process(_ loc: CLLocation) {
        location = loc
        let speed = loc.speed >= 0 ? loc.speed : 0
        speedKmh = speed * 3.6
        tuneLocationAccuracy(speedMetersPerSecond: speed)
        evaluateNearest()
    }

    /// v1.4 功耗优化：只有真正在移动时才需要高精度高频定位。
    /// 低速/等红灯/停车时切到 10 米精度 + 30 米过滤，显著降低 GPS 与后台唤醒耗电；
    /// 进入/退出阈值不同（3 m/s 进低速、5 m/s 回高速），避免在阈值附近来回抖动。
    private func tuneLocationAccuracy(speedMetersPerSecond speed: Double) {
        let shouldHigh = highAccuracyMode ? speed >= 3.0 : speed >= 5.0
        guard shouldHigh != highAccuracyMode else { return }
        highAccuracyMode = shouldHigh
        lm.desiredAccuracy = shouldHigh ? kCLLocationAccuracyBest : kCLLocationAccuracyNearestTenMeters
        lm.distanceFilter = shouldHigh ? 10 : 30
    }

    /// 优化 A：速度自适应预警距离按当前速度放大（骑行 1.0× ~ 高速 2.0×）
    /// 阈值统一在 AdaptiveWarn 中维护，首页显示与引擎判定共用同一套系数。
    private func adaptiveFactor(forSpeed speed: Double) -> Double {
        AdaptiveWarn.factor(speedMetersPerSecond: speed)
    }

    /// 用已缓存位置重新评估最近点位，更新首页并视情况播报。
    /// 新增 / 删除 / 导入点位后调用即可立即刷新，无需等下一次定位。
    private func evaluateNearest() {
        guard let loc = location else { return }
        let speed = loc.speed >= 0 ? loc.speed : 0
        let effectiveWarn = warnDistance * adaptiveFactor(forSpeed: speed)

        guard let (best, bestD) = findNearest(relativeTo: loc) else {
            nearest = nil
            nearestDistance = .greatestFiniteMagnitude
            if floatWarning || activeWarningId != nil {
                floatWarning = false
                activeWarningId = nil
                updateLiveActivity()
            }
            return
        }
        nearest = best
        nearestDistance = bestD

        // v1.9 悬浮球 / 灵动岛状态机：进入预警半径→红色+距离，离开预警半径→自动回绿
        if bestD > effectiveWarn {
            if floatWarning || activeWarningId != nil {
                floatWarning = false
                activeWarningId = nil
                updateLiveActivity()
                // v1.10 CarPlay：离开预警，卡片恢复默认标题
                CarPlaySupport.updateNowPlaying()
            }
        } else if floatWarning {
            // 持续处于预警状态：每次定位刷新都同步灵动岛距离
            updateLiveActivity()
        }

        // 优化 B：驶离冷却阈值 1.5x，避免两点相邻时反复触发
        if bestD > effectiveWarn * 1.5 {
            announced.remove(best.id)
            return
        }
        guard bestD <= effectiveWarn, !announced.contains(best.id), canSpeakNow() else { return }

        announced.insert(best.id)
        activeWarningId = best.id
        floatWarning = true
        let text = "前方\(Int(bestD))米，\(best.type.voiceText)，请谨慎行驶！"
        showBanner(text: text)
        speak(text)
        // v1.10 CarPlay：播报瞬间，车机卡片同步显示当前提醒
        CarPlaySupport.updateNowPlaying(title: "前方\(Int(bestD))米 · \(best.type.label)")
        // 优化 C：震动辅助
        vibrate()
        // v1.4：后台/锁屏时同步推一条本地通知，避免只靠语音导致漏提醒（此前申请了通知权限却从未使用）
        postBackgroundNotification(distance: Int(bestD), type: best.type, name: best.name)

        announcements.insert(
            Announcement(time: Date(), type: best.type, name: best.name,
                         distance: Int(bestD), text: text),
            at: 0
        )
        if announcements.count > 50 { announcements.removeLast(announcements.count - 50) }
        updateLiveActivity()
    }

    // MARK: - v1.9 顶部弹窗（接近抓拍点时先弹窗提示，按设置时长自动收起）

    /// 显示顶部弹窗：文案保留 bannerDuration 秒后自动隐藏
    func showBanner(text: String) {
        guard floatEnabled else { return }
        bannerText = text
        bannerTask?.cancel()
        bannerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(bannerDuration, 1) * 1_000_000_000))
            if !Task.isCancelled { bannerText = nil }
        }
    }

    /// 手动收起当前弹窗（关闭悬浮球时调用）
    func dismissBanner() {
        bannerTask?.cancel()
        bannerText = nil
    }

    // MARK: - v1.9 灵动岛 / Live Activity（后台、锁屏时同步悬浮球状态）

    /// 开始实时活动（进入监听时调用）
    func startLiveActivity() {
        guard liveActivityEnabled, liveActivity == nil else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = makeActivityState()
        liveActivity = try? Activity<CameraGuardActivityAttributes>.request(
            attributes: CameraGuardActivityAttributes(),
            contentState: state,
            pushType: nil
        )
    }

    /// 状态变化时刷新实时活动（进入/离开预警、距离刷新）
    func updateLiveActivity() {
        guard liveActivityEnabled else { return }
        let state = makeActivityState()
        if let activity = liveActivity {
            Task { await activity.update(using: state) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            liveActivity = try? Activity<CameraGuardActivityAttributes>.request(
                attributes: CameraGuardActivityAttributes(),
                contentState: state,
                pushType: nil
            )
        }
    }

    /// 结束实时活动（暂停监听 / 关闭开关时调用）
    func endLiveActivity() {
        guard let activity = liveActivity else { return }
        liveActivity = nil
        let state = makeActivityState()
        Task { await activity.end(using: state, dismissalPolicy: .immediate) }
    }

    /// 当前灵动岛内容状态：预警态（红色+距离）或巡航态
    private func makeActivityState() -> CameraGuardActivityAttributes.ContentState {
        if floatWarning, let n = nearest, nearestDistance.isFinite {
            return CameraGuardActivityAttributes.ContentState(
                phase: "warning",
                title: "前方 \(Int(nearestDistance)) 米 · \(n.type.label)",
                detail: "\(n.name) · 请减速通过",
                distanceM: Int(nearestDistance)
            )
        }
        return CameraGuardActivityAttributes.ContentState(
            phase: "cruising",
            title: "电子眼卫士 · 正常巡航",
            detail: "已载入 \(pois.count) 个点位",
            distanceM: 0
        )
    }

    // MARK: - 节流（优化 B 改进版：点位冷却 + 时间冷却双保险）

    private func canSpeakNow() -> Bool {
        let now = Date()
        let minGap: TimeInterval =
            UIApplication.shared.applicationState == .background ? 30 : 8
        guard now.timeIntervalSince(lastSpeak) > minGap else { return false }
        lastSpeak = now
        return true
    }

    // MARK: - TTS 播报（#1 讯飞折中：保留系统，讯飞接入点留壳）

    /// 讯飞凭证格式预检：AppID 8 位、APIKey/APISecret 32 位。不完整直接走系统语音，避免把
    /// “凭证不完整”误当成合成失败。真实鉴权失败仍由讯飞服务器返回具体错误。
    static func iflytekCredentialLooksValid(appID: String, apiKey: String, apiSecret: String) -> Bool {
        let a = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = apiSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        return a.count == 8 && k.count == 32 && s.count == 32
    }

    private func speak(_ text: String, force: Bool = false) {
        configureAudio()

        switch ttsProvider {
        case .system:
            speakSystem(text, force: force)

        case .iflytekPro:
            if !Self.iflytekCredentialLooksValid(appID: xfAppID, apiKey: xfAPIKey, apiSecret: xfAPISecret) {
                speakSystem(text)
                ttsFeedback = "讯飞凭证不完整（AppID \(xfAppID.count) 位 / APIKey \(xfAPIKey.count) 位 / Secret \(xfAPISecret.count) 位），已用系统语音"
                return
            }
            let tts = XfyunTTS(appID: xfAppID, apiKey: xfAPIKey, apiSecret: xfAPISecret, vcn: xfVcn)
            guard tts.isConfigured else {
                speakSystem(text)
                ttsFeedback = "讯飞未配置，已用系统语音"
                return
            }
            // v1.4：先停掉上一段未播完的讯飞请求，避免两句合成请求叠播、连接与音频资源泄漏
            xfyunTTS?.stop()
            xfyunTTS = tts
            ttsFeedback = "讯飞合成中 · \(voiceDisplayName)"
            tts.speak(text,
                      onFinish: { [weak self] in self?.xfyunTTS = nil },
                      onNoAudio: { [weak self] reason in
                          DispatchQueue.main.async {
                              self?.ttsFeedback = "讯飞失败，已回退系统语音（\(reason)）"
                              self?.speakSystem(text)
                          }
                      })
        }
    }

    private func speakSystem(_ text: String, force: Bool = false) {
        // 节流已限制播报频率；默认不打断正在播放的句子，避免两句语音互相截断、听感撕扯。
        if speech.isSpeaking {
            guard force else { return }
            speech.stopSpeaking(at: .word)
        }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        u.volume = 1.0
        speech.speak(u)
    }

    private func configureAudio() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// 震动反馈（C）：支持自定义时长/强度，0 秒即关闭
    private func vibrate() {
        haptics.play(duration: hapticDuration, intensity: hapticIntensity)
    }

    /// v1.7 震动开关：关闭时记下当前时长（0 秒），重新打开时恢复；开启时若从未设置则用 1 秒
    func setHapticEnabled(_ on: Bool) {
        if on {
            hapticDuration = hapticLastDuration > 0 ? hapticLastDuration : 1.0
        } else {
            if hapticDuration > 0 { hapticLastDuration = hapticDuration }
            hapticDuration = 0
        }
        saveSettings()
    }

    /// 拖动时长滑杆时同步记住“最近一次有效时长”，关掉再开不会丢设置
    func updateHapticDuration(_ value: Double) {
        hapticDuration = value
        if value > 0 { hapticLastDuration = value }
        saveSettings()
    }

    /// v1.8 滑杆整秒提示：短促轻震反馈（不改变已设置的时长/强度）
    func hapticTick() {
        haptics.play(duration: 0.12, intensity: 0.35)
    }

    /// 后台本地通知（仅 App 不在前台时发，前台已有界面与语音，不重复打扰）
    private func postBackgroundNotification(distance: Int, type: PoiType, name: String) {
        guard UIApplication.shared.applicationState == .background else { return }
        let content = UNMutableNotificationContent()
        content.title = "前方 \(distance) 米 · \(type.label)"
        content.body = name
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - 设置持久化

    /// 保存设置。
    /// - Parameter rebuildIndex: 仅当点位数据或类型过滤变化时才需要重建分桶索引；
    ///   只改播报距离、语音引擎/凭证时传 false，避免无意义的全量重算。
    func saveSettings(rebuildIndex: Bool = false) {
        let defaults = UserDefaults.standard
        defaults.set(enabledTypes.map { $0.rawValue }, forKey: "enabledTypes")
        defaults.set(warnDistance, forKey: "warnDistance")
        defaults.set(hapticDuration, forKey: "hapticDuration")
        defaults.set(hapticIntensity, forKey: "hapticIntensity")
        defaults.set(hapticLastDuration, forKey: "hapticLastDuration")
        defaults.set(ttsProvider.rawValue, forKey: "ttsProvider")
        defaults.set(xfAppID, forKey: "xfAppID")
        defaults.set(xfAPIKey, forKey: "xfAPIKey")
        defaults.set(xfAPISecret, forKey: "xfAPISecret")
        defaults.set(xfVcn, forKey: "xfVcn")
        if let data = try? JSONEncoder().encode(userPois) {
            defaults.set(data, forKey: "userPois")
        }
        if let data = try? JSONEncoder().encode(voicePacks) {
            defaults.set(data, forKey: "voicePacks")
        }
        // v1.8 内置点位编辑台账
        defaults.set(Array(deletedBuiltinIds), forKey: "deletedBuiltinIds")
        if let data = try? JSONEncoder().encode(builtinPatches) {
            defaults.set(data, forKey: "builtinPatches")
        }
        // v1.9 悬浮球/弹窗/灵动岛设置与悬浮球位置
        defaults.set(floatEnabled, forKey: "floatEnabled")
        defaults.set(floatDraggable, forKey: "floatDraggable")
        defaults.set(bannerDuration, forKey: "bannerDuration")
        defaults.set(liveActivityEnabled, forKey: "liveActivityEnabled")
        defaults.set(ballPosition.x, forKey: "floatBallX")
        defaults.set(ballPosition.y, forKey: "floatBallY")
        if rebuildIndex { self.rebuildIndex() }
    }

    // MARK: - 语音包管理（v1.5）

    /// 输入 vcn 后自动建档（已存在则不重复）；空白输入忽略
    func syncVoicePackWithCurrentVcn() {
        let trimmed = xfVcn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if xfVcn != trimmed { xfVcn = trimmed }
        guard !voicePacks.contains(where: { $0.vcn == trimmed }) else { return }
        voicePacks.append(VoicePack(vcn: trimmed, name: trimmed))
        saveSettings()
    }

    /// 重命名语音包（vcn 不变，仅显示名变化）
    func renameVoicePack(vcn: String, name: String) {
        guard let idx = voicePacks.firstIndex(where: { $0.vcn == vcn }) else { return }
        voicePacks[idx].name = name
        saveSettings()
    }

    /// 左滑删除语音包；删掉的正是当前选中项时，自动切到剩余第一个（没有则清空）
    func deleteVoicePack(vcn: String) {
        voicePacks.removeAll { $0.vcn == vcn }
        if xfVcn == vcn {
            xfVcn = voicePacks.first?.vcn ?? ""
        }
        saveSettings()
    }

    func selectVoicePack(vcn: String) {
        xfVcn = vcn
        saveSettings()
    }

    // MARK: - 用户 POI 管理（#3 点位编辑）

    func addUserPoi(_ poi: Poi) {
        // 去重（同 type+lat+lon 视为同一）
        guard !userPois.contains(where: { $0.latitude == poi.latitude && $0.longitude == poi.longitude && $0.type == poi.type }) else {
            return
        }
        userPois.append(poi)
        saveSettings(rebuildIndex: true)
        evaluateNearest()
    }

    func deleteUserPoi(id: String) {
        userPois.removeAll { $0.id == id }
        announced.remove(id)
        saveSettings(rebuildIndex: true)
        evaluateNearest()
    }

    func toggleUserPoi(id: String) {
        guard let idx = userPois.firstIndex(where: { $0.id == id }) else { return }
        userPois[idx].enabled.toggle()
        saveSettings(rebuildIndex: true)
        evaluateNearest()
    }

    /// 修改自定义点位：只允许改名称/半径/启用状态，坐标与类型固定不变（v1.8）
    func updateUserPoi(_ poi: Poi) {
        guard let idx = userPois.firstIndex(where: { $0.id == poi.id }) else { return }
        var p = poi
        let base = userPois[idx]
        p.type = base.type
        p.latitude = base.latitude
        p.longitude = base.longitude
        userPois[idx] = p
        saveSettings(rebuildIndex: true)
        evaluateNearest()
    }

    // MARK: - 内置点位编辑/删除（v1.8）

    /// 删除内置点位：写入删除台账并持久化（App 升级、重装后恢复默认可再次出现）
    func deleteBuiltinPoi(id: String) {
        guard !deletedBuiltinIds.contains(id) else { return }
        deletedBuiltinIds.insert(id)
        builtinPatches.removeValue(forKey: id)
        announced.remove(id)
        saveSettings(rebuildIndex: true)
        evaluateNearest()
    }

    /// 恢复被删除的内置点位（撤销删除）
    func restoreBuiltinPoi(id: String) {
        guard deletedBuiltinIds.remove(id) != nil else { return }
        saveSettings(rebuildIndex: true)
        evaluateNearest()
    }

    /// 开关内置点位（通过补丁覆盖 enabled）
    func toggleBuiltinPoi(id: String) {
        guard let base = basePois.first(where: { $0.id == id }),
              !deletedBuiltinIds.contains(id) else { return }
        var p = builtinPatches[id] ?? base
        p.enabled.toggle()
        builtinPatches[id] = p
        saveSettings(rebuildIndex: true)
        evaluateNearest()
    }

    /// 修改内置点位：只允许改名称/半径/启用状态，坐标与类型固定不变
    func updateBuiltinPoi(_ poi: Poi) {
        guard let base = basePois.first(where: { $0.id == poi.id }),
              !deletedBuiltinIds.contains(poi.id) else { return }
        var p = poi
        p.type = base.type
        p.latitude = base.latitude
        p.longitude = base.longitude
        builtinPatches[poi.id] = p
        saveSettings(rebuildIndex: true)
        evaluateNearest()
    }

    /// 导出全部点位（Bundle + 用户自定义）为 JSON Data（优化 E）
    func exportAllPois() -> Data? {
        struct ExportPoi: Encodable {
            let name, type: String
            let lat, lon: Double
            let radiusM: Double
            let enabled: Bool
        }
        let arr = pois.map { ExportPoi(name: $0.name, type: $0.type.rawValue,
                                        lat: $0.latitude, lon: $0.longitude,
                                        radiusM: $0.radiusM, enabled: $0.enabled) }
        return try? JSONEncoder().encode(arr)
    }

    /// 导入 JSON（格式兼容 poi.json），合并到 userPois。
    /// v1.4：改为逐条解析 + 坐标/去重校验，单条坏数据只跳过该条，不再让整批导入失败；
    /// 返回新增与跳过的条数，供界面给出明确结果。
    @discardableResult
    func importPois(from data: Data) throws -> (added: Int, skipped: Int) {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let raw = obj as? [[String: Any]] else { throw PoiImportError.invalidFormat }

        var added = 0
        var skipped = 0
        for dict in raw {
            guard let name = dict["name"] as? String,
                  let typeRaw = dict["type"] as? String,
                  let type = PoiType(rawValue: typeRaw),
                  let lat = (dict["lat"] as? NSNumber)?.doubleValue,
                  let lon = (dict["lon"] as? NSNumber)?.doubleValue,
                  (-90...90).contains(lat), (-180...180).contains(lon),
                  !(lat == 0 && lon == 0) else {
                skipped += 1
                continue
            }
            let poi = Poi(name: name, type: type, latitude: lat, longitude: lon,
                          radiusM: (dict["radiusM"] as? NSNumber)?.doubleValue ?? 500,
                          enabled: (dict["enabled"] as? Bool) ?? true)
            if userPois.contains(where: { $0.latitude == poi.latitude && $0.longitude == poi.longitude && $0.type == poi.type }) {
                skipped += 1
                continue
            }
            userPois.append(poi)
            added += 1
        }
        saveSettings(rebuildIndex: true)
        evaluateNearest()
        return (added, skipped)
    }

    // MARK: - 测试

    func testSpeak() {
        guard !isTestingSpeech else { return }
        isTestingSpeech = true
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.isTestingSpeech = false
            }
        }
        let text = "前方300米，有摩托车闯红灯拍照，请谨慎行驶！"
        speak(text, force: true)   // 测试按钮要求立即发声，允许打断当前语音
        vibrate()
        announcements.insert(
            Announcement(time: Date(), type: .CUSTOM, name: "测试", distance: 0, text: text),
            at: 0
        )
    }
}

/// 点位导入错误（仅根格式不合法时抛出；单条坏数据按跳过处理）
enum PoiImportError: LocalizedError {
    case invalidFormat

    var errorDescription: String? {
        "JSON 格式不正确：应为点位对象数组（name / type / lat / lon）"
    }
}

/// v1.6 可配置震动：CoreHaptics 连续触感支持自定义强度与时长（0~60 秒）；
/// 设备不支持或引擎启动失败时回退系统警告触感，保证提醒不会完全丢失。
final class HapticsPlayer {
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?

    init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = true
            try engine.start()
            self.engine = engine
        } catch {
            self.engine = nil
        }
    }

    func play(duration: Double, intensity: Double) {
        guard duration > 0 else { return }          // 0 秒 = 关闭震动
        let d = min(max(duration, 0.1), 60)
        let i = min(max(intensity, 0), 1)
        guard let engine else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        let params = [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(i)),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6)
        ]
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: params,
                                  relativeTime: 0, duration: d)
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            try? player?.stop(atTime: 0)
            try engine.start()
            let newPlayer = try engine.makeAdvancedPlayer(with: pattern)
            try newPlayer.start(atTime: 0)
            player = newPlayer
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }
}
