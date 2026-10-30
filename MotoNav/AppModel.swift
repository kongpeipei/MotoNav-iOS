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
    /// 多路线方案（点"去这里"后展示，选择后应用）
    @Published var routeChoices: [RouteChoice] = []
    @Published var selectedPoi: Poi?
    @Published var navigating = false
    @Published var searchHistory: [String] = []
    /// 定位按钮点击计数（驱动地图回中）
    @Published var locateTick = 0
    /// 路线全览请求计数（规划完成后 +1，驱动地图缩放全览）
    @Published var fitTick = 0
    /// 手机朝向（度，0=北，顺时针）
    @Published var heading: Double = 0
    /// 自定义背景图片（相册选择，v1.11 已移除入口，保留字段兼容旧数据）
    @Published var bgImage: UIImage?
    /// 天气文本（小图标 + 温度，显示在 ⋯ 左侧）
    @Published var weatherText: String?
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
    private let hfKey = "hf_pois"

    private override init() {
        super.init()
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        pois = repo.load()
        loadHistory()
        loadHefeiPois()
        NotificationCenter.default.addObserver(
            self, selector: #selector(authorizeAndStart),
            name: UIApplication.didBecomeActiveNotification, object: nil)
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

    /// 在线搜索兜底：联想库未收录的地点（如新小区），模糊查询后预览；
    /// 多级降级：全名 → 去前缀（如"金辉锦绣云庭"→"锦绣云庭"），仍失败引导复制位置链接
    func onlineSearch(_ name: String) {
        status = "正在在线搜索「\(name)」…"
        Task {
            var variants = [name]
            if name.count > 4 {
                variants.append(String(name.dropFirst(2)))       // 去开发商前缀
            }
            if name.count > 6 {
                variants.append(String(name.suffix(2)))          // 保留核心尾词
            }
            var found: CLLocationCoordinate2D?
            for v in variants {
                if let c = await findHefeiCoordinate(v, fuzzy: true) {
                    found = c
                    break
                }
            }
            if let c = found {
                setPreview(name, lat: c.latitude, lon: c.longitude)
                status = "已定位到「\(name)」（坐标为估算，请实地校准），点「去这里」规划路线"
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
            if weatherText == nil { fetchWeather() }
            checkAlerts(at: coord)
            checkNavigation(at: coord)
        }
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

    /// 搜索智能联想：点位名称 + 历史目的地 + 合肥小区/商铺（最多 10 条）；
    /// 无匹配时给出"在线搜索「关键词」"入口
    func searchSuggestions(_ query: String) -> [String] {
        var pool = Set<String>()
        for p in pois { pool.insert(p.name) }
        for h in searchHistory { pool.insert(h) }
        for hf in hfPois { pool.insert(hf) }
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return Array(pool).prefix(10).map { $0 } }
        var matched = pool.filter { $0.localizedCaseInsensitiveContains(q) }.prefix(10).map { $0 }
        if matched.isEmpty {
            matched = ["🔍 在线搜索「\(q)」"]
        }
        return matched
    }

    /// 右下角定位按钮：地图回中
    func centerOnUser() {
        locateTick += 1
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
                fitTick += 1
                status = String(
                    format: "到「%@」约%.1f公里，预计%d分钟，沿途抓拍点%d处，请留意",
                    name, Double(r.distanceM) / 1000.0, r.durationS / 60, near.count)
            } else {
                route = [from, CLLocationCoordinate2D(latitude: lat, longitude: lon)]
                routePois = nearbyPoisOnRoute(route)
                routeTurns = []
                fitTick += 1
                status = "路线服务不可用，已显示直线到「\(name)」"
            }
        }
    }

    func clearRoute() {
        navigating = false
        route = []
        routePois = []
        routeTurns = []
        routeChoices = []
        lastTurnSpoken = -1
        status = "已清除路线"
    }

    /// "去这里/导航到这里"触发：获取多路线方案，多条时交由界面选择
    func fetchRouteChoices(to name: String, lat: Double, lon: Double) {
        guard let start = currentLocation else {
            status = "请先定位后再规划路线"
            return
        }
        destName = name; destLat = lat; destLon = lon
        addHistory(name)
        status = "正在规划到「\(name)」…"
        let from = start
        let end = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        Task {
            let choices = await RouteFetcher.fetchAll(from: from, to: end)
            if choices.isEmpty {
                route = [from, end]
                routePois = nearbyPoisOnRoute(route)
                routeTurns = []
                fitTick += 1
                status = "路线服务不可用，已显示直线到「\(name)」"
            } else if choices.count == 1 {
                applyRouteChoice(choices[0], name: name)
            } else {
                routeChoices = choices
            }
        }
    }

    /// 应用所选路线方案（地图严格绘制该方案折线）
    func applyRouteChoice(_ c: RouteChoice, name: String? = nil) {
        let n = name ?? destName
        route = c.points
        routeTurns = c.turns
        lastTurnSpoken = -1
        let near = nearbyPoisOnRoute(c.points)
        routePois = near
        routeChoices = []
        fitTick += 1
        status = String(
            format: "到「%@」约%.1f公里，预计%d分钟，沿途抓拍点%d处，请留意",
            n, Double(c.distanceM) / 1000.0, c.durationS / 60, near.count)
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
