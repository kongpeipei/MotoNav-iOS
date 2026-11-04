import Foundation
import CoreLocation
import AVFoundation
import UIKit
import UserNotifications

/// TTS 引擎选择（优化 #1：保留系统默认，给高级用户留讯飞接入点）
enum TtsProvider: String, CaseIterable, Identifiable, Codable {
    case system       // 系统 AVSpeechSynthesizer（推荐，零延迟、离线可用）
    case iflytekPro   // 讯飞在线合成（需自行接入 SDK，延迟较高，耗流量）

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system:     return "系统语音（推荐，离线零延迟）"
        case .iflytekPro: return "讯飞在线合成（四川话·叶子，需填 AppID/APIKey）"
        }
    }
}

/// 讯飞发音人预设（vcn 以讯飞控制台为准，可手动编辑覆盖）
struct VoicePreset: Identifiable {
    let name: String
    let vcn: String
    var id: String { vcn }
}

enum VoicePresets {
    static let all: [VoicePreset] = [
        VoicePreset(name: "小燕（普通话女声·默认）", vcn: "xiaoyan"),
        VoicePreset(name: "小峰（普通话男声）", vcn: "xiaofeng"),
        VoicePreset(name: "小宇（男声）", vcn: "xiaoyu"),
        VoicePreset(name: "小萌（女声）", vcn: "xiaomeng"),
        VoicePreset(name: "小晴（女声）", vcn: "xiaoqing"),
        VoicePreset(name: "小静（女声）", vcn: "xiaojing"),
        VoicePreset(name: "小新（童声）", vcn: "xiaoxin"),
        VoicePreset(name: "叶子（四川话·女声）", vcn: "xiaorong"),
    ]
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
    @Published var ttsProvider: TtsProvider
    @Published var xfAppID: String
    @Published var xfAPIKey: String
    @Published var xfAPISecret: String
    @Published var xfVcn: String
    /// 用户自定义点位（持久化在 UserDefaults）
    @Published var userPois: [Poi] = []

    /// 全部有效点位 = Bundle 内置 + 用户自定义（均过滤 enabled=true）
    var pois: [Poi] {
        let bundled = bundledPois.filter { $0.enabled }
        let custom  = userPois.filter { $0.enabled }
        return bundled + custom
    }

    // MARK: - 私有属性

    private let lm = CLLocationManager()
    private(set) var bundledPois: [Poi] = []
    private var announced: Set<String> = []        // 已播报点位 id
    private var lastSpeak = Date.distantPast
    private let speech = AVSpeechSynthesizer()
    private var xfyunTTS: XfyunTTS?
    private let haptic = UINotificationFeedbackGenerator()

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
        self.ttsProvider = TtsProvider(rawValue: defaults.string(forKey: "ttsProvider") ?? "") ?? .iflytekPro
        self.xfAppID = defaults.string(forKey: "xfAppID") ?? "5ad38c61"
        self.xfAPIKey = defaults.string(forKey: "xfAPIKey") ?? "65eb7d0144b094c4c34b"
        self.xfAPISecret = defaults.string(forKey: "xfAPISecret") ?? "MGI5M2YzOGM3ZDRjNTAyYmM2YWQ1ZDY0"
        self.xfVcn = defaults.string(forKey: "xfVcn") ?? "xiaoyan"

        // 加载 Bundle 内置点位
        if let url = Bundle.main.url(forResource: "poi", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let arr = try? JSONDecoder().decode([Poi].self, from: data) {
            bundledPois = arr
        }

        // 加载用户自定义点位
        if let data = defaults.data(forKey: "userPois"),
           let decoded = try? JSONDecoder().decode([Poi].self, from: data) {
            userPois = decoded
        }

        super.init()

        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        lm.activityType = .otherNavigation
        lm.distanceFilter = 15   // 更频繁一点，加速时反应及时
        lm.pausesLocationUpdatesAutomatically = false
        lm.allowsBackgroundLocationUpdates = true
        lm.showsBackgroundLocationIndicator = true

        rebuildIndex()
        configureAudio()

        // 持久化观察
        observeSettings()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func observeSettings() {
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                               object: UserDefaults.standard, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.rebuildIndex()
        }
    }

    // MARK: - 索引（优化 D：纬度分桶 + 邻桶扫描）

    /// 重建分桶索引（每次新增/删除用户点位或过滤条件变化后调用）
    func rebuildIndex() {
        latBuckets.removeAll(keepingCapacity: true)
        for p in pois {
            let key = Int(p.latitude / bucketStep)
            latBuckets[key, default: []].append(p)
        }
    }

    /// 基于分桶的近邻查找（优化 D：先筛桶再算距离，O(桶内数量)）
    private func findNearest(relativeTo loc: CLLocation) -> (Poi, Double)? {
        let latKey = Int(loc.coordinate.latitude / bucketStep)
        // 扫描当前桶 + 上下各 2 个桶（覆盖 5 × 1.1km ≈ 5.5km 范围，足够覆盖 warnDistance=1000m 加余量）
        let lonKey = Int(loc.coordinate.longitude / bucketStep)
        var best: Poi?
        var bestD = Double.greatestFiniteMagnitude
        for dLat in -2...2 {
            let key = latKey + dLat
            guard let bucket = latBuckets[key] else { continue }
            for p in bucket where enabledTypes.contains(p.type) {
                // 经度粗略过滤（先算经度差对应的近似距离，减少 CLLocation 构造）
                let deltaLat = (p.latitude - loc.coordinate.latitude)
                let deltaLon = (p.longitude - loc.coordinate.longitude) * cos(loc.coordinate.latitude * .pi / 180)
                // 0.02° ≈ 2.2km，粗略跳过远距离
                if hypot(deltaLat, deltaLon) > 0.025 { continue }
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
        lm.startUpdatingLocation()
        isMonitoring = true
        statusText = "监听中 · 已载入 \(pois.count) 个点位"
    }

    func stop() {
        lm.stopUpdatingLocation()
        isMonitoring = false
        statusText = "已暂停监听"
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

        // 优化 A：速度自适应预警距离
        // 骑车 ≤15 m/s (54 km/h) 用默认；更高速度自动放大到 1.2× ~ 2.0×
        let adaptiveFactor: Double
        if speed <= 5 {          // 步行 <18 km/h：保持默认
            adaptiveFactor = 1.0
        } else if speed <= 10 {  // 骑行 <36 km/h
            adaptiveFactor = 1.0
        } else if speed <= 15 { // 高速骑行 / 低速开车 <54 km/h
            adaptiveFactor = 1.2
        } else if speed <= 22 {  // 普通开车 <80 km/h
            adaptiveFactor = 1.5
        } else {                  // 高速 >80 km/h
            adaptiveFactor = 2.0
        }
        let effectiveWarn = warnDistance * adaptiveFactor

        guard let (best, bestD) = findNearest(relativeTo: loc) else { return }
        nearest = best
        nearestDistance = bestD

        // 优化 B：驶离冷却阈值从 1.2x 提升到 1.5x，避免两点相邻时反复触发
        if bestD > effectiveWarn * 1.5 {
            announced.remove(best.id)
            return
        }
        guard bestD <= effectiveWarn, !announced.contains(best.id), canSpeakNow() else { return }

        announced.insert(best.id)
        let text = "前方\(Int(bestD))米，\(best.type.voiceText)，请谨慎行驶！"
        speak(text)
        // 优化 C：震动辅助
        vibrate()

        announcements.insert(
            Announcement(time: Date(), type: best.type, name: best.name,
                         distance: Int(bestD), text: text),
            at: 0
        )
        if announcements.count > 50 { announcements.removeLast(announcements.count - 50) }
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

    private func speak(_ text: String) {
        configureAudio()

        switch ttsProvider {
        case .system:
            speakSystem(text)

        case .iflytekPro:
            let tts = XfyunTTS(appID: xfAppID, apiKey: xfAPIKey, apiSecret: xfAPISecret, vcn: xfVcn)
            guard tts.isConfigured else {
                speakSystem(text)
                statusText = "讯飞未配置，已回退系统语音"
                return
            }
            xfyunTTS = tts
            tts.speak(text) { [weak self] in
                self?.xfyunTTS = nil
            }
        }
    }

    private func speakSystem(_ text: String) {
        if speech.isSpeaking { speech.stopSpeaking(at: .word) }
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

    /// 震动反馈（C）：prepare 后再触发，避免首次无感
    private func vibrate() {
        haptic.prepare()
        vibrate()
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: 1.0)
    }

    // MARK: - 设置持久化

    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(enabledTypes.map { $0.rawValue }, forKey: "enabledTypes")
        defaults.set(warnDistance, forKey: "warnDistance")
        defaults.set(ttsProvider.rawValue, forKey: "ttsProvider")
        defaults.set(xfAppID, forKey: "xfAppID")
        defaults.set(xfAPIKey, forKey: "xfAPIKey")
        defaults.set(xfAPISecret, forKey: "xfAPISecret")
        defaults.set(xfVcn, forKey: "xfVcn")
        if let data = try? JSONEncoder().encode(userPois) {
            defaults.set(data, forKey: "userPois")
        }
        rebuildIndex()
    }

    // MARK: - 用户 POI 管理（#3 点位编辑）

    func addUserPoi(_ poi: Poi) {
        // 去重（同 type+lat+lon 视为同一）
        guard !userPois.contains(where: { $0.latitude == poi.latitude && $0.longitude == poi.longitude && $0.type == poi.type }) else {
            return
        }
        userPois.append(poi)
        saveSettings()
    }

    func deleteUserPoi(id: String) {
        userPois.removeAll { $0.id == id }
        saveSettings()
    }

    func toggleUserPoi(id: String) {
        guard let idx = userPois.firstIndex(where: { $0.id == id }) else { return }
        userPois[idx].enabled.toggle()
        saveSettings()
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

    /// 导入 JSON（格式兼容 poi.json），合并到 userPois（优化 E）
    func importPois(from data: Data) throws {
        let arr = try JSONDecoder().decode([Poi].self, from: data)
        for p in arr {
            if !userPois.contains(where: { $0.latitude == p.latitude && $0.longitude == p.longitude && $0.type == p.type }) {
                userPois.append(p)
            }
        }
        saveSettings()
    }

    // MARK: - 测试

    func testSpeak() {
        guard !speech.isSpeaking || canSpeakNow() else { return }
        let text = "前方300米，有摩托车闯红灯拍照，请谨慎行驶！"
        speak(text)
        vibrate()
        announcements.insert(
            Announcement(time: Date(), type: .CUSTOM, name: "测试", distance: 0, text: text),
            at: 0
        )
    }
}
