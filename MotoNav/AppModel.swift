import Foundation
import CoreLocation
import AVFoundation
import UserNotifications
import UIKit

extension Notification.Name {
    /// 触发点位提醒（object 为 Poi）
    static let motoAlert = Notification.Name("motoAlert")
    /// 点位列表变化（供 CarPlay 同步）
    static let motoPoisChanged = Notification.Name("motoPoisChanged")
}

@MainActor
final class AppModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = AppModel()

    @Published var pois: [Poi] = []
    @Published var currentLocation: CLLocationCoordinate2D?
    @Published var monitoring = false
    @Published var simulating = false
    @Published var status = "等待定位…"
    @Published var route: [CLLocationCoordinate2D] = []
    @Published var selectedPoi: Poi?

    private let repo = PoiRepository()
    private let lm = CLLocationManager()
    private let speech = AVSpeechSynthesizer()
    private var simTimer: Timer?
    private var simStep = 0
    private var lastTrigger: [Int64: Date] = [:]

    private override init() {
        super.init()
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        pois = repo.load()
        NotificationCenter.default.addObserver(
            self, selector: #selector(authorizeAndStart),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    // MARK: - 权限与定位

    @objc func authorizeAndStart() {
        let status = lm.authorizationStatus
        switch status {
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
        monitoring = true
        status = "GPS 已开启"
    }

    func stopMonitoring() {
        lm.stopUpdatingLocation()
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
            status = String(format: "纬度%.5f 经度%.5f", coord.latitude, coord.longitude)
            checkAlerts(at: coord)
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
        for p in pois where p.enabled {
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
        let msg = "\(p.type.voicePrefix)，\(p.name)，距离约\(Int(distance))米"
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

    // MARK: - 语音

    func speak(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = 0.5
        speech.speak(u)
    }

    // MARK: - 本地通知

    private func postLocalNotification(_ p: Poi, distance: Double) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = p.type.voicePrefix
        content.body = "\(p.name) · 距离约\(Int(distance))米"
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
}
