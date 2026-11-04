import Foundation
import CoreLocation
import AVFoundation
import UIKit

/// 核心引擎：持续定位 → 匹配最近违法拍照点 → 接近时语音播报（支持后台运行）
/// 后台能力依赖 Info.plist UIBackgroundModes = [location, audio]
@MainActor
final class AlertEngine: NSObject, ObservableObject, CLLocationManagerDelegate {

    // MARK: - 发布状态（UI 绑定）
    @Published var statusText = "启动中…"
    @Published var location: CLLocation?
    @Published var nearest: Poi?
    @Published var nearestDistance: Double = .greatestFiniteMagnitude
    @Published var announcements: [Announcement] = []
    @Published var isMonitoring = false
    /// 各类型播报开关（默认全开）
    @Published var enabledTypes: Set<PoiType> = Set(PoiType.allCases)
    /// 播报触发距离（米，默认 500）
    @Published var warnDistance: Double = 500

    /// 全部点位（仅启用项）
    let pois: [Poi]

    private var lm: CLLocationManager
    private var announced: Set<String> = []        // 已播报点位 id（避免重复）
    private var lastSpeak = Date.distantPast
    private let speech = AVSpeechSynthesizer()

    override init() {
        var loaded: [Poi] = []
        if let url = Bundle.main.url(forResource: "poi", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let arr = try? JSONDecoder().decode([Poi].self, from: data) {
            loaded = arr.filter { $0.enabled }
        }
        pois = loaded
        lm = CLLocationManager()
        super.init()
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        lm.activityType = .otherNavigation
        lm.distanceFilter = 20
        // 关键后台配置：不自动暂停 + 允许后台定位
        lm.pausesLocationUpdatesAutomatically = false
        lm.allowsBackgroundLocationUpdates = true
        lm.showsBackgroundLocationIndicator = true
        configureAudio()
    }

    /// 启动即调用：请求权限并开始监听
    func start() {
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

    /// 暂停监听（界面按钮）
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
        Task { @MainActor in
            process(loc)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if (error as? CLError)?.code == .denied {
                statusText = "定位失败：权限被拒绝"
            }
        }
    }

    // MARK: - 核心逻辑

    private func process(_ loc: CLLocation) {
        location = loc
        // 找最近一个启用且类型开启的点位
        var best: Poi?
        var bestD = Double.greatestFiniteMagnitude
        for p in pois where enabledTypes.contains(p.type) {
            let d = loc.distance(from: CLLocation(latitude: p.latitude, longitude: p.longitude))
            if d < bestD {
                bestD = d
                best = p
            }
        }
        nearest = best
        nearestDistance = bestD

        guard let p = best else { return }

        if bestD > warnDistance * 1.2 {
            // 已驶离该点，允许再次接近时重新播报
            announced.remove(p.id)
            return
        }
        guard bestD <= warnDistance, !announced.contains(p.id), canSpeakNow() else { return }

        announced.insert(p.id)
        let text = "\(p.type.voiceText)，\(p.name)，请注意"
        speak(text)
        announcements.insert(
            Announcement(time: Date(), type: p.type, name: p.name, distance: Int(bestD), text: text),
            at: 0
        )
        if announcements.count > 20 { announcements.removeLast(announcements.count - 20) }
    }

    /// 播报节流：前台 8 秒一次，后台 30 秒一次（省电、避免系统后台资源限制）
    private func canSpeakNow() -> Bool {
        let now = Date()
        let minGap: TimeInterval =
            UIApplication.shared.applicationState == .background ? 30 : 8
        guard now.timeIntervalSince(lastSpeak) > minGap else { return false }
        lastSpeak = now
        return true
    }

    /// 语音播报（playback 会话 + 中文女声）
    private func speak(_ text: String) {
        configureAudio()
        if speech.isSpeaking {
            speech.stopSpeaking(at: .word) // 自然断句，保证新提醒及时
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

    /// 手动触发一次播报（供界面测试用）
    func testSpeak() {
        guard !speech.isSpeaking || canSpeakNow() else { return }
        let text = "电子眼卫士播报测试，前方路口请注意"
        speak(text)
        announcements.insert(
            Announcement(time: Date(), type: .CUSTOM, name: "测试", distance: 0, text: text),
            at: 0
        )
    }
}
