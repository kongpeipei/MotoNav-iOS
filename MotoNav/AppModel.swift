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
    @Published var routePois: [Poi] = []
    @Published var selectedPoi: Poi?
    @Published var navigating = false
    @Published var searchHistory: [String] = []

    /// 类型筛选（默认全部启用）
    var enabledTypes: Set<PoiType> = Set(PoiType.allCases)
    /// 点位总开关
    var allPoiEnabled = true

    private let repo = PoiRepository()
    private let lm = CLLocationManager()
    private let speech = AVSpeechSynthesizer()
    private var simTimer: Timer?
    private var simStep = 0
    private var lastTrigger: [Int64: Date] = [:]

    /// 导航状态
    private var destLat = 0.0
    private var destLon = 0.0
    private var destName = ""
    private var routeTurns: [RouteTurn] = []
    private var lastTurnSpoken = -1

    private let historyKey = "search_history"
    private let historyLimit = 10

    private override init() {
        super.init()
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        pois = repo.load()
        loadHistory()
        NotificationCenter.default.addObserver(
            self, selector: #selector(authorizeAndStart),
            name: UIApplication.didBecomeActiveNotification, object: nil)
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
            checkNavigation(at: coord)
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
        return pois.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// 规划到任意目的地并高亮沿途抓拍点位
    func planRoute(to name: String, lat: Double, lon: Double) {
        guard let start = currentLocation else {
            status = "请先定位后再规划路线"
            return
        }
        destName = name; destLat = lat; destLon = lon
        addHistory(name)
        status = "正在规划到「\(name)」…"
        let from = start
        Task {
            let r = await RouteFetcher.fetch(from: from, to: CLLocationCoordinate2D(latitude: lat, longitude: lon))
            if let r = r {
                route = r.points
                routeTurns = r.turns
                lastTurnSpoken = -1
                let near = nearbyPoisOnRoute(r.points)
                routePois = near
                status = String(
                    format: "到「%@」约%.1f公里，预计%d分钟，沿途抓拍点%d处，请留意",
                    name, Double(r.distanceM) / 1000.0, r.durationS / 60, near.count)
            } else {
                route = [from, CLLocationCoordinate2D(latitude: lat, longitude: lon)]
                routePois = nearbyPoisOnRoute(route)
                routeTurns = []
                status = "路线服务不可用，已显示直线到「\(name)」"
            }
        }
    }

    func clearRoute() {
        navigating = false
        route = []
        routePois = []
        routeTurns = []
        lastTurnSpoken = -1
        status = "已清除路线"
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
            speak("导航结束")
            status = "导航已结束"
        } else {
            guard route.count >= 2 else { status = "请先搜索目的地并规划路线"; return }
            navigating = true
            startMonitoring()
            speak("开始导航到\(destName)，请按路线行驶")
            status = "导航中 → \(destName)"
        }
    }

    private func checkNavigation(at coord: CLLocationCoordinate2D) {
        guard navigating else { return }
        let toDest = distanceM(coord, CLLocationCoordinate2D(latitude: destLat, longitude: destLon))
        if toDest < 100 {
            speak("已到达目的地，\(destName)，导航结束")
            status = "已到达：\(destName)"
            navigating = false
            routePois = []
            return
        }
        guard !routeTurns.isEmpty else { return }
        var idx = -1
        var best = Double.greatestFiniteMagnitude
        for i in routeTurns.indices where i > lastTurnSpoken {
            let d = distanceM(coord, routeTurns[i].coordinate)
            if d < best { best = d; idx = i }
        }
        if idx >= 0 && best < 150 {
            lastTurnSpoken = idx
            let t = routeTurns[idx]
            let text = turnText(t)
            speak("\(text)，距您\(Int(best))米")
            status = "导航：\(text) 距\(Int(best))米 · 余\(Int(toDest / 1000))公里"
        }
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
