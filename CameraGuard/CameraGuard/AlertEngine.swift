import Foundation
import CoreLocation
import AVFoundation
import UIKit
import UserNotifications
import CoreHaptics
import ActivityKit
import AudioToolbox
import SwiftUI

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

    // MARK: - v1.9 弹窗 / 灵动岛（v1.12 起不再包含悬浮球）

    /// 接近抓拍点时的顶部弹窗停留时长（1~10 秒，默认 1.2）
    @Published var bannerDuration: Double = 1.2
    /// 后台/锁屏时是否使用灵动岛实时活动
    @Published var liveActivityEnabled: Bool = true

    /// 当前打包版本号（读取 CFBundleShortVersionString，供分享文案使用）
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.12"
    }

    /// 当前构建号（读取 CFBundleVersion，供运行日志导出 .ips 使用）
    static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    // MARK: - v1.10 CarPlay（音频类）

    /// 是否已连接 CarPlay 车机（音频路由检测）
    @Published var carPlayConnected = false
    /// 顶部弹窗当前文案（nil 表示不显示）
    @Published var bannerText: String?
    /// 是否处于抓拍预警状态（弹窗与灵动岛红色警告态）
    @Published private(set) var floatWarning: Bool = false
    /// 当前预警对应的点位 id（离开预警半径时清空）
    private var activeWarningId: String?
    private var bannerTask: Task<Void, Never>?
    private var liveActivity: Activity<CameraGuardActivityAttributes>?


    /// v1.8 起内置点位台账的稳定 id：类型+坐标6位（不含名称）。
    /// v1.17 显示 id 追加名称段后，台账读写继续以稳定 id 兜底双查，保证老用户已删除/已补丁的
    /// 点位不会复活或丢失，同时让「桥上/桥下」等同坐标真实点位各自独立。
    static func stableBuiltinId(for p: Poi) -> String {
        String(format: "%@-%.6f,%.6f", p.type.rawValue, p.latitude, p.longitude)
    }

    /// 内置点位生效列表 = 内置 - 已删除，再叠加用户补丁（坐标与类型始终不变）
    var builtinPois: [Poi] {
        bundledPois
            .filter { !deletedBuiltinIds.contains($0.id) && !deletedBuiltinIds.contains(Self.stableBuiltinId(for: $0)) }
            .map { builtinPatches[$0.id] ?? builtinPatches[Self.stableBuiltinId(for: $0)] ?? $0 }
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

        self.warnDistance = defaults.object(forKey: "warnDistance") as? Double ?? 800 // v1.33 默认 800 米
        self.hapticDuration = defaults.object(forKey: "hapticDuration") as? Double ?? 0.4
        self.hapticIntensity = defaults.object(forKey: "hapticIntensity") as? Double ?? 0.8
        self.hapticLastDuration = defaults.object(forKey: "hapticLastDuration") as? Double ?? 1.0
        // 默认使用离线系统语音；v1.13 起内置加密讯飞凭证，用户从未设置过引擎时默认使用讯飞
        let builtin = BuiltinXfyun.decrypt()
        let savedProvider = defaults.string(forKey: "ttsProvider") ?? ""
        if !savedProvider.isEmpty {
            self.ttsProvider = TtsProvider(rawValue: savedProvider) ?? .system
        } else {
            self.ttsProvider = builtin == nil ? .system : .iflytekPro
        }
        // 用户显式设置过的凭证优先；未设置时使用内置加密凭证（不明文落盘）
        let savedAppID = defaults.string(forKey: "xfAppID") ?? ""
        let savedKey = defaults.string(forKey: "xfAPIKey") ?? ""
        let savedSecret = defaults.string(forKey: "xfAPISecret") ?? ""
        self.xfAppID = savedAppID.isEmpty ? (builtin?.appid ?? "") : savedAppID
        self.xfAPIKey = savedKey.isEmpty ? (builtin?.apiKey ?? "") : savedKey
        self.xfAPISecret = savedSecret.isEmpty ? (builtin?.apiSecret ?? "") : savedSecret
        self.xfVcn = defaults.string(forKey: "xfVcn")?.isEmpty == false
            ? (defaults.string(forKey: "xfVcn") ?? "")
            : (builtin == nil ? "xiaoyan" : BuiltinXfyun.defaultVcn)

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
        // v1.9 加载弹窗/灵动岛设置
        loadFloatSettings()
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

    /// v1.5：从 UserDefaults 恢复语音包；无任何包但已有 vcn 时补一条同名包。
    /// v1.13：首次启动（无包无显式 vcn）时补内置默认发音人「讯飞小璇(英文)」。
    private func loadVoicePacks() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "voicePacks"),
           let decoded = try? JSONDecoder().decode([VoicePack].self, from: data) {
            // v1.17：按 vcn 去重，旧版本多次建档可能留下同 vcn 重复包，会导致列表 ForEach 断言崩溃
            var seen = Set<String>()
            voicePacks = decoded.filter { seen.insert($0.vcn).inserted }
        }
        let savedVcn = (defaults.string(forKey: "xfVcn") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveVcn = savedVcn.isEmpty ? xfVcn : savedVcn
        if !effectiveVcn.isEmpty, !voicePacks.contains(where: { $0.vcn == effectiveVcn }) {
            voicePacks = [VoicePack(vcn: effectiveVcn, name: BuiltinXfyun.vcnDisplayName(effectiveVcn))]
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

    /// v1.9：恢复弹窗/灵动岛设置
    private func loadFloatSettings() {
        let defaults = UserDefaults.standard
        if let v = defaults.object(forKey: "bannerDuration") as? Double { bannerDuration = v }
        if let v = defaults.object(forKey: "liveActivityEnabled") as? Bool { liveActivityEnabled = v }
    }

    /// 逐条解析点位数组（坏条目跳过；v1.17 按展示 id 去重，防重复点导致 ForEach 断言）。
    private static func parsePois(_ raw: [[String: Any]]) -> [Poi] {
        var seen = Set<String>()
        return raw.compactMap { dict -> Poi? in
            guard let name = dict["name"] as? String,
                  let typeRaw = dict["type"] as? String,
                  let type = PoiType(rawValue: typeRaw),
                  let lat = (dict["lat"] as? NSNumber)?.doubleValue,
                  let lon = (dict["lon"] as? NSNumber)?.doubleValue else { return nil }
            return Poi(name: name, type: type, latitude: lat, longitude: lon,
                       radiusM: (dict["radiusM"] as? NSNumber)?.doubleValue ?? 500,
                       enabled: (dict["enabled"] as? Bool) ?? true)
        }
        .filter { seen.insert($0.id).inserted }
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
        // v1.24：冷启动清理上次残留的灵动岛（App 被清除后系统仍保留显示，重开即清）
        cleanupStaleLiveActivities()

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

    /// v1.20 静止节流时间戳：静止时降低定位处理频率省电
    private var lastIdleEvaluate = Date.distantPast
    private var wasIdle = false

    /// v1.29 速度门控休眠：休眠中不预警不播报（最低功耗），只低速检测速度
    @Published private(set) var hibernating = false
    /// 唤醒阈值：速度 > 50km/h 唤醒进入监听
    private let wakeSpeed: Double = 50.0 / 3.6
    /// 休眠阈值：速度 < 10km/h（10码）进入休眠
    private let sleepSpeed: Double = 10.0 / 3.6

    private func process(_ loc: CLLocation) {
        location = loc
        let speed = loc.speed >= 0 ? loc.speed : 0
        speedKmh = speed * 3.6
        applyHibernationGate(speed: speed)
        tuneLocationAccuracy(speedMetersPerSecond: speed)
        // v1.20 静止省电：位置基本不动时每 12 秒才重新评估一次点位；
        // 首次进入静止仍立即评估（避免停在点位内漏播），移动时恢复逐次评估。
        let now = Date()
        let idle = speed < 0.5
        if idle {
            guard now.timeIntervalSince(lastIdleEvaluate) > 12 || !wasIdle else { return }
        }
        wasIdle = idle
        lastIdleEvaluate = now
        evaluateNearest()
    }

    /// v1.29 速度门控：>50km/h 唤醒监听；<10km/h 进入休眠省电。
    /// 中间速度保持当前状态，避免在阈值附近来回抖动。
    private func applyHibernationGate(speed: Double) {
        if hibernating {
            guard speed > wakeSpeed else { return }
            hibernating = false
            statusText = "检测到高速行驶 · 已唤醒监听"
            updateLiveActivity() // 立即恢复灵动岛巡航态（去掉"休眠中"）
        } else {
            guard speed < sleepSpeed else { return }
            hibernating = true
            statusText = "速度低于10码 · 进入休眠省电"
            // 强制结束预警态，休眠不打扰
            if floatWarning || activeWarningId != nil {
                floatWarning = false
                activeWarningId = nil
                announced.removeAll()
            }
            updateLiveActivity()
        }
    }

    /// v1.4/v1.20 功耗优化：只有真正在移动时才需要高精度高频定位。
    /// 静止（<0.5 m/s）→ 10 米精度 + 60 米过滤（低频唤醒，省电）；
    /// 低速（3 m/s 以下）→ 10 米精度 + 30 米过滤；高速 → Best + 10 米。
    /// 进入/退出阈值不同（3 m/s 进低速、5 m/s 回高速），避免在阈值附近来回抖动。
    /// v1.29：休眠态强制最低功耗（10 米精度 + 60 米过滤）。
    private func tuneLocationAccuracy(speedMetersPerSecond speed: Double) {
        if hibernating {
            if highAccuracyMode || lm.distanceFilter != 60 {
                highAccuracyMode = false
                lm.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
                lm.distanceFilter = 60
            }
            return
        }
        if speed < 0.5 {
            if highAccuracyMode || lm.distanceFilter != 60 {
                highAccuracyMode = false
                lm.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
                lm.distanceFilter = 60
            }
            return
        }
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
    /// v1.31：点位操作（新增/启用/修改/恢复/导入）传 forceAnnounce=true，
    /// 若新点位已在提醒范围内则绕开语音节流立即播报提醒。
    private func evaluateNearest(forceAnnounce: Bool = false) {
        guard let loc = location else { return }
        let speed = loc.speed >= 0 ? loc.speed : 0
        // v1.29 休眠态：不预警不播报，仅刷新最近距离供灵动岛显示。
        // v1.34：用户主动新增/启用/修改/恢复/导入点位（forceAnnounce=true）时，
        // 即使当前处于休眠（速度低于10码）也立即按用户设置的播报距离评估提醒。
        if hibernating && !forceAnnounce {
            if let (best, bestD) = findNearest(relativeTo: loc) {
                nearest = best
                nearestDistance = bestD
            }
            return
        }
        // v1.34：主动点位操作按用户设置的基础播报距离评估（不加自适应系数），
        // 保证"在播报距离内"即触发提醒，不受低速自适应缩小影响。
        let effectiveWarn = forceAnnounce ? warnDistance : warnDistance * adaptiveFactor(forSpeed: speed)

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

        // v1.9 灵动岛状态机：进入预警半径→红色+距离，离开预警半径→自动回绿
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
        guard bestD <= effectiveWarn, !announced.contains(best.id), canSpeakNow(force: forceAnnounce) else { return }

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
        bannerText = text
        bannerTask?.cancel()
        bannerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(bannerDuration, 1) * 1_000_000_000))
            if !Task.isCancelled { bannerText = nil }
        }
    }

    /// 手动收起当前弹窗
    func dismissBanner() {
        bannerTask?.cancel()
        bannerText = nil
    }

    // MARK: - v1.9 灵动岛 / Live Activity（后台、锁屏时同步预警状态）

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
    /// v1.25：巡航态右侧也显示实时最近距离（绿色），并与 app 内提示卡点位信息同步
    /// v1.28：按最近点位类型下发中间图标 key（icon）
    /// v1.29：休眠态显示「休眠中」巡航文案
    private func makeActivityState() -> CameraGuardActivityAttributes.ContentState {
        if hibernating {
            return CameraGuardActivityAttributes.ContentState(
                phase: "cruising",
                title: "电子眼卫士 · 休眠中",
                detail: "速度低于10码 · 恢复行驶自动监听",
                distanceM: safeMeters(nearestDistance),
                icon: ""
            )
        }
        if floatWarning, let n = nearest, nearestDistance.isFinite {
            return CameraGuardActivityAttributes.ContentState(
                phase: "warning",
                title: "前方 \(safeMeters(nearestDistance)) 米 · \(n.type.label)",
                detail: "\(n.name) · 请减速通过",
                distanceM: safeMeters(nearestDistance),
                icon: n.type.rawValue
            )
        }
        let d = safeMeters(nearestDistance)
        let detail: String
        let iconKey: String
        if let n = nearest, nearestDistance.isFinite {
            detail = "\(n.type.label) · \(n.name)"
            iconKey = n.type.rawValue
        } else {
            detail = "已载入 \(pois.count) 个点位"
            iconKey = ""
        }
        return CameraGuardActivityAttributes.ContentState(
            phase: "cruising",
            title: "电子眼卫士 · 正常巡航",
            detail: detail,
            distanceM: d,
            icon: iconKey
        )
    }

    /// v1.26 修复启动崩溃：Double→Int 转换陷阱。
    /// nearestDistance 初始为 .greatestFiniteMagnitude（1.8e308，isFinite 仍为 true），
    /// Int(1.8e308) 会触发 Swift "Double cannot be converted to Int" 运行时 trap（SIGTRAP）。
    /// 钳制到 0...100000，异常值统一按 0 处理。
    private func safeMeters(_ d: Double) -> Int {
        guard d.isFinite, d >= 0, d <= 100_000 else { return 0 }
        return Int(d)
    }

    // MARK: - v1.24/v1.25 灵动岛生命周期管理

    /// 由 App 的 scenePhase 驱动。
    /// v1.25（用户澄清）：不清除后台时灵动岛应一直显示，不做超时自动结束；
    /// 上滑清除 App 是系统级进程终止（iOS 无"被杀瞬间"回调），无法在那一刻结束灵动岛，
    /// 由冷启动清理（cleanupStaleLiveActivities）兜底。
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // 保持灵动岛持续显示（定位 App 后台长期存活，状态实时更新）
            break
        case .active:
            // 若活动被系统清理（极少见），监听中且开关开则自动补回
            if isMonitoring, liveActivityEnabled, liveActivity == nil {
                startLiveActivity()
            }
        default:
            break
        }
    }

    /// 冷启动清理残留：App 被上滑清除后系统仍会保留灵动岛显示，
    /// 下次打开 App 时把所有遗留活动立即结束，避免"关不掉"的观感
    private func cleanupStaleLiveActivities() {
        for activity in Activity<CameraGuardActivityAttributes>.activities {
            Task { await activity.end(dismissalPolicy: .immediate) }
        }
    }

    // MARK: - 节流（优化 B 改进版：点位冷却 + 时间冷却双保险）

    /// 语音播报节流：前台 8 秒、后台 30 秒最小间隔，防止连续点位刷屏。
    /// v1.31：点位新增/启用/修改/导入等用户主动操作时 force=true 绕过节流立即播报
    /// （仍会刷新 lastSpeak，避免随后普通定位在 8 秒内被连报干扰）。
    private func canSpeakNow(force: Bool = false) -> Bool {
        let now = Date()
        if force {
            lastSpeak = now
            return true
        }
        let minGap: TimeInterval =
            UIApplication.shared.applicationState == .background ? 30 : 8
        guard now.timeIntervalSince(lastSpeak) > minGap else { return false }
        lastSpeak = now
        return true
    }

    // MARK: - TTS 播报（#1 讯飞折中：保留系统，讯飞接入点留壳）

    /// 讯飞凭证格式预检（v1.14 放宽：仅防空值/过短，真实有效性由讯飞服务端判定；
    /// APIKey 存在 24 位 hex 与 32 位等多种格式，过严的「32 位」会把有效凭证误拦回系统语音）
    static func iflytekCredentialLooksValid(appID: String, apiKey: String, apiSecret: String) -> Bool {
        let a = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = apiSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        return a.count == 8 && k.count >= 16 && s.count >= 16
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
    /// v1.20 档位切换试震：按当前档位强度反馈（低/中/高可感知差异）
    func hapticTick() {
        haptics.play(duration: 0.15, intensity: hapticIntensity)
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
        // v1.13：凭证等于内置加密值时不清除也不落盘明文（保持走内置解密）；用户改过才存用户值
        let builtin = BuiltinXfyun.decrypt()
        if xfAppID == builtin?.appid { defaults.removeObject(forKey: "xfAppID") } else { defaults.set(xfAppID, forKey: "xfAppID") }
        if xfAPIKey == builtin?.apiKey { defaults.removeObject(forKey: "xfAPIKey") } else { defaults.set(xfAPIKey, forKey: "xfAPIKey") }
        if xfAPISecret == builtin?.apiSecret { defaults.removeObject(forKey: "xfAPISecret") } else { defaults.set(xfAPISecret, forKey: "xfAPISecret") }
        if builtin != nil, xfVcn == BuiltinXfyun.defaultVcn { defaults.removeObject(forKey: "xfVcn") } else { defaults.set(xfVcn, forKey: "xfVcn") }
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
        // v1.9 弹窗/灵动岛设置
        defaults.set(bannerDuration, forKey: "bannerDuration")
        defaults.set(liveActivityEnabled, forKey: "liveActivityEnabled")
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
        // v1.21 去重按 6 位归一化坐标（与 Poi.id 的格式化口径一致）：
        // 旧版用原始 double 比较，坐标微差（如 31.833001 vs 31.833000）放行后
        // 会在 id 归一化时撞车，导致点位管理页 ForEach 重复 id 崩溃（iOS 26 黄色感叹号占位页）
        guard !userPois.contains(where: { Self.normalizedKey($0) == Self.normalizedKey(poi) }) else {
            return
        }
        userPois.append(poi)
        // v1.35：清除该点位已播报记录，确保新增后立即播报
        announced.remove(poi.id)
        saveSettings(rebuildIndex: true)
        evaluateNearest(forceAnnounce: true)
    }

    /// v1.21 点位去重键：类型+6 位坐标（与 Poi.id 前缀口径一致）
    private static func normalizedKey(_ p: Poi) -> String {
        String(format: "%@-%.6f,%.6f", p.type.rawValue, p.latitude, p.longitude)
    }

    /// v1.21 渲染层去重：历史数据导致的重复展示 id 折叠为一条，防止 ForEach 重复 id 崩溃
    func deduplicated(_ arr: [Poi]) -> [Poi] {
        var seen = Set<String>()
        return arr.filter { seen.insert($0.id).inserted }
    }

    /// v1.23 语音包渲染层去重（按 vcn），防历史重复包导致语音引擎页 ForEach 崩溃
    var deduplicatedVoicePacks: [VoicePack] {
        var seen = Set<String>()
        return voicePacks.filter { seen.insert($0.vcn).inserted }
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
        // v1.35：启用已播报过的点位时清除去重记录，立即重新播报
        announced.remove(id)
        saveSettings(rebuildIndex: true)
        evaluateNearest(forceAnnounce: true)
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
        // v1.35：清除该点位已播报记录，修改后立即重新评估播报
        announced.remove(poi.id)
        saveSettings(rebuildIndex: true)
        evaluateNearest(forceAnnounce: true)
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
        // v1.35：清除该点位已播报记录，恢复后立即重新播报
        announced.remove(id)
        saveSettings(rebuildIndex: true)
        evaluateNearest(forceAnnounce: true)
    }

    /// v1.20 一键恢复全部内置点位：清空删除台账与改名/半径/开关补丁，回到出厂默认
    func restoreAllBuiltinPois() {
        deletedBuiltinIds.removeAll()
        builtinPatches.removeAll()
        announced.removeAll()
        saveSettings(rebuildIndex: true)
        evaluateNearest(forceAnnounce: true)
    }

    /// 开关内置点位（通过补丁覆盖 enabled）
    /// v1.18：改用稳定 id（类型+坐标6位）匹配基库，兼容改名后 id 变化
    func toggleBuiltinPoi(_ poi: Poi) {
        guard let base = bundledPois.first(where: { Self.stableBuiltinId(for: $0) == Self.stableBuiltinId(for: poi) }),
              !deletedBuiltinIds.contains(poi.id),
              !deletedBuiltinIds.contains(Self.stableBuiltinId(for: poi)) else { return }
        var p = builtinPatches[poi.id] ?? builtinPatches[Self.stableBuiltinId(for: poi)] ?? base
        p.enabled.toggle()
        builtinPatches[poi.id] = p
        // v1.35：启用已播报过的内置点位时清除去重记录，立即重新播报
        announced.remove(poi.id)
        announced.remove(Self.stableBuiltinId(for: poi))
        saveSettings(rebuildIndex: true)
        evaluateNearest(forceAnnounce: true)
    }

    /// 修改内置点位：只允许改名称/半径/启用状态，坐标与类型固定不变
    /// v1.18：按稳定 id 匹配基库，修复改名后 id 变化导致修改失效
    func updateBuiltinPoi(_ poi: Poi) {
        guard let base = bundledPois.first(where: { Self.stableBuiltinId(for: $0) == Self.stableBuiltinId(for: poi) }),
              !deletedBuiltinIds.contains(poi.id),
              !deletedBuiltinIds.contains(Self.stableBuiltinId(for: poi)) else { return }
        var p = poi
        p.type = base.type
        p.latitude = base.latitude
        p.longitude = base.longitude
        builtinPatches[poi.id] = p
        builtinPatches.removeValue(forKey: Self.stableBuiltinId(for: poi))
        // v1.35：清除该点位已播报记录，修改后立即重新评估播报
        announced.remove(poi.id)
        announced.remove(Self.stableBuiltinId(for: poi))
        saveSettings(rebuildIndex: true)
        evaluateNearest(forceAnnounce: true)
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
            // v1.21 与添加点位同口径：按 6 位归一化坐标去重，防微差坐标导入后 id 撞车
            if userPois.contains(where: { Self.normalizedKey($0) == Self.normalizedKey(poi) }) {
                skipped += 1
                continue
            }
            userPois.append(poi)
            // v1.35：导入的点位若已播报过，清除记录确保立即播报
            announced.remove(poi.id)
            added += 1
        }
        saveSettings(rebuildIndex: true)
        evaluateNearest(forceAnnounce: true)
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
/// 设备不支持或引擎启动失败时回退系统震动，保证提醒不会完全丢失。
/// v1.16：震动请求全部经串行队列执行（防重入/防高频叠加打爆调用栈），
/// 回退提示改走 AudioServices 系统震动，避开 UIFeedbackGenerator 统计链在部分 iOS 26.x 上的崩溃。
final class HapticsPlayer {
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private let queue = DispatchQueue(label: "haptics.serial")

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
        queue.async { [weak self] in
            guard let self else { return }
            guard let engine = self.engine else {
                AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
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
                try? self.player?.stop(atTime: 0)
                try engine.start()
                let newPlayer = try engine.makeAdvancedPlayer(with: pattern)
                try newPlayer.start(atTime: 0)
                self.player = newPlayer
            } catch {
                AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
            }
        }
    }
}
