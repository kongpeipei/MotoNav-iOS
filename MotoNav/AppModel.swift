import Foundation
import CoreLocation
import AVFoundation
import UserNotifications
import UIKit
import ActivityKit

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
    /// 地图缩放按钮计数（+1 放大 / 缩小，MapView 响应）
    @Published var zoomInTick = 0
    @Published var zoomOutTick = 0
    /// 导航跟随触发（导航开始/结束/到达时递增，地图进入跟随模式）
    @Published var navigateFollowTick = 0
    /// 当前选中的路线方案下标（高德式：默认选中推荐，卡片点击切换）
    @Published var selectedRouteIdx = 0
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

    /// 高德开放平台 Web 服务 Key（v1.46 起内置官方Key，开箱即用；可在 ⋯ 菜单「高德搜索Key」修改）
    @Published var amapKey: String = AppModel.builtinAmapKey {
        didSet { UserDefaults.standard.set(amapKey, forKey: "amapKey") }
    }
    /// 内置高德 Web 服务 Key（用户提供，供搜索联想/路线规划/点位校准使用）
    static let builtinAmapKey = "9d596e8799cf037080e4d6ab8764c246"

    /// 高德周边搜索候选（点击地标「搜周边」结果）
    struct AmapPoi: Identifiable {
        let name: String
        let address: String
        let type: String
        let distance: Int
        let lat: Double
        let lon: Double
        var id: String { "\(name)#\(lat)#\(lon)" }
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
    /// 常用地点（家/公司）
    struct SavedPlace: Codable { var name: String; var lat: Double; var lon: Double }
    @Published var homePlace: SavedPlace?
    @Published var workPlace: SavedPlace?
    /// 行程总结（到达或退出导航时生成）
    struct TripSummary {
        let destName: String
        let distanceM: Int
        let durationS: Int
        let snapCount: Int
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
        if let saved = UserDefaults.standard.string(forKey: "amapKey"), !saved.isEmpty {
            amapKey = saved
        }
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        pois = repo.load()
        applyCalibrations()
        loadHistory()
        loadHefeiPois()
        loadFavorites()
        loadHomeWork()
        NotificationCenter.default.addObserver(
            self, selector: #selector(authorizeAndStart),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    // MARK: - 收藏 / 家 / 公司（v1.29）

    private let favKey = "fav_pois"
    private let homeKey = "home_place"
    private let workKey = "work_place"

    private func loadFavorites() {
        if let d = UserDefaults.standard.dictionary(forKey: favKey) as? [String: String] {
            favorites = d
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
        } else {
            favorites[key] = p.name
        }
        UserDefaults.standard.set(favorites, forKey: favKey)
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
            // v1.47：高德天气优先（更准更实时），失败回退 open-meteo
            if await fetchAmapWeather() { return }
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

    /// 高德天气（v1.47）：实时 lives + 明日 forecast，成功返回 true
    private func fetchAmapWeather() async -> Bool {
        guard !amapKey.isEmpty else { return false }
        // 实时天气（base）
        guard let baseURL = URL(string:
            "https://restapi.amap.com/v3/weather/weatherInfo?key=\(amapKey)&city=%E5%90%88%E8%82%A5&extensions=base"
        ) else { return false }
        var req = URLRequest(url: baseURL)
        req.timeoutInterval = 10
        var gotLive = false
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let lives = root["lives"] as? [[String: Any]],
           let live = lives.first {
            let weather = live["weather"] as? String ?? ""
            let temp = live["temperature"] as? String ?? ""
            let windDir = live["winddirection"] as? String ?? ""
            let windPow = live["windpower"] as? String ?? ""
            var parts: [String] = []
            if let w = amapWeatherIcon(weather) { parts.append(w) }
            if !temp.isEmpty { parts.append("\(Int(Double(temp) ?? 0))°") }
            if !weather.isEmpty && weather != "晴" && weather != "多云" {
                // 温度已含天气感，天气文字仅在非晴时补充（保持胶囊简洁）
            }
            if !windPow.isEmpty { parts.append("风\(windPow)级") }
            if !windDir.isEmpty { parts.append(windDir) }
            if parts.count >= 2 {
                weatherText = parts.joined(separator: " ")
                gotLive = true
            }
        }
        // 明日预报（all）
        if let allURL = URL(string:
            "https://restapi.amap.com/v3/weather/weatherInfo?key=\(amapKey)&city=%E5%90%88%E8%82%A5&extensions=all"
        ) {
            var req2 = URLRequest(url: allURL)
            req2.timeoutInterval = 10
            if let (data, _) = try? await URLSession.shared.data(for: req2),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let forecasts = root["forecasts"] as? [[String: Any]],
               let casts = forecasts.first?["casts"] as? [[String: Any]],
               casts.count > 1 {
                let c = casts[1]
                let day = c["dayweather"] as? String ?? ""
                let dayT = c["daytemp"] as? String ?? ""
                let nightT = c["nighttemp"] as? String ?? ""
                var t = "明日 "
                if let ic = amapWeatherIcon(day) { t += ic }
                if !nightT.isEmpty && !dayT.isEmpty {
                    t += "\(Int(Double(nightT) ?? 0))~\(Int(Double(dayT) ?? 0))°"
                }
                if !day.isEmpty && day != "晴" { t += " \(day)" }
                tomorrowText = t
            }
        }
        return gotLive
    }

    private func amapWeatherIcon(_ weather: String) -> String? {
        if weather.contains("晴") { return "☀️" }
        if weather.contains("多云") { return "🌤️" }
        if weather.contains("阴") { return "☁️" }
        if weather.contains("雷") { return "⛈️" }
        if weather.contains("雨") { return "🌧️" }
        if weather.contains("雪") { return "🌨️" }
        if weather.contains("雾") || weather.contains("霾") { return "🌫️" }
        if weather.contains("风") { return "🌬️" }
        return nil
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
            currentSpeed = loc.speed > 0 ? loc.speed : 0
            if weatherText == nil { fetchWeather() }
            checkAlerts(at: coord)
            checkNavigation(at: coord)
            // v1.47：节流更新当前道路名（高德逆地理，45秒/300米）
            await maybeUpdateCurrentRoad()
            // v1.46：首次定位后，用高德逆地理校准附近抓拍点（吸附到最近道路/路口）
            if !UserDefaults.standard.bool(forKey: "calibratedV146") {
                calibrateNearbyPois()
            }
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

    // MARK: - 语音（四川甜妹：高音调普通话女声 + 四川语气词，系统 TTS 无四川话方言）

    func speak(_ text: String) {
        let u = AVSpeechUtterance(string: sweetSichuan(text))
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = 0.48          // 稍慢，更柔
        u.pitchMultiplier = 1.18 // 音调偏高，更甜
        speech.speak(u)
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

    /// 高德周边搜索：以指定地标为中心搜周边（加油站/充电桩/餐饮等），返回 POI 列表（WGS-84 坐标）
    func amapAround(lat: Double, lon: Double, keyword: String) async -> [AmapPoi] {
        guard !amapKey.isEmpty else { return [] }
        let (glat, glon) = CoordConv.wgs2gcj(lat, lon)
        var urlStr = "https://restapi.amap.com/v3/place/around?key=\(amapKey)&location=\(glon),\(glat)&radius=3000&offset=20&page=1&extensions=all&sortrule=default"
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        if !kw.isEmpty {
            let enc = kw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            urlStr += "&keywords=\(enc)"
        }
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pois = root["pois"] as? [[String: Any]]
        else { return [] }
        var out: [AmapPoi] = []
        for p in pois {
            guard let name = p["name"] as? String, !name.isEmpty,
                  let loc = p["location"] as? String else { continue }
            let parts = loc.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { continue }
            let (wlat, wlon) = CoordConv.gcj2wgs(parts[1], parts[0])
            let dist = (p["distance"] as? String).flatMap { Int($0) } ?? 0
            out.append(AmapPoi(name: name,
                               address: p["address"] as? String ?? "",
                               type: p["type"] as? String ?? "",
                               distance: dist,
                               lat: wlat, lon: wlon))
        }
        return out
    }

    /// 定位后显示当前道路名（高德逆地理，节流调用）
    @Published var currentRoad = ""
    private var lastRoadUpdate = Date(timeIntervalSince1970: 0)
    private var lastRoadCoord: CLLocationCoordinate2D?

    func maybeUpdateCurrentRoad() async {
        guard !amapKey.isEmpty, let loc = currentLocation else { return }
        let now = Date()
        let moved = lastRoadCoord.map { hypot(loc.latitude - $0.latitude, loc.longitude - $0.longitude) * 111000 } ?? 999
        guard now.timeIntervalSince(lastRoadUpdate) > 45 || moved > 300 else { return }
        lastRoadUpdate = now
        lastRoadCoord = loc
        let (glat, glon) = CoordConv.wgs2gcj(loc.latitude, loc.longitude)
        guard let url = URL(string:
            "https://restapi.amap.com/v3/geocode/regeo?key=\(amapKey)&location=\(glon),\(glat)&radius=200"
        ) else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let regeo = root["regeocode"] as? [String: Any],
              let roads = regeo["roads"] as? [[String: Any]],
              let first = roads.first,
              let name = first["name"] as? String, !name.isEmpty
        else { return }
        currentRoad = name
    }

    /// 高德「输入提示」联想：输入关键字实时返回 POI 候选（名称+副标题+精确坐标），需用户填写高德 Web 服务 Key
    func amapInputTips(_ q: String) async -> [AmapTip] {
        guard !amapKey.isEmpty, !q.isEmpty else { return [] }
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://restapi.amap.com/v3/assistant/inputtips?key=\(amapKey)&keywords=\(enc)&city=%E5%90%88%E8%82%A5&citylimit=true") else { return [] }
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
                // v1.47 坐标纠偏：高德返回 GCJ-02，转 WGS-84 供苹果地图显示
                let (wlat, wlon) = CoordConv.gcj2wgs(parts[1], parts[0])
                out.append(AmapTip(name: name, sub: sub, lat: wlat, lon: wlon))
            }
            return Array(out.prefix(8))
        } catch {
            return []
        }
    }

    // MARK: - 高德点位校准（v1.46）

    /// 逆地理编码：把坐标吸附到最近道路/路口（抓拍点常因数据源偏移偏离道路中心线）
    private func regeoSnap(lat: Double, lon: Double) async -> (Double, Double)? {
        guard !amapKey.isEmpty else { return nil }
        let (glat, glon) = CoordConv.wgs2gcj(lat, lon)
        guard let url = URL(string:
            "https://restapi.amap.com/v3/geocode/regeo?key=\(amapKey)&location=\(glon),\(glat)"
        ) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let regeo = root["regeocode"] as? [String: Any]
        else { return nil }
        // 优先路口（抓拍多在路口），其次最近道路；返回前转 WGS-84
        if let inters = regeo["roadinters"] as? [[String: Any]],
           let inter = inters.first,
           let loc = inter["location"] as? String {
            let parts = loc.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 { return CoordConv.gcj2wgs(parts[1], parts[0]) }
        }
        if let roads = regeo["roads"] as? [[String: Any]], !roads.isEmpty {
            // 取 distance 最近的（regeo 已按距离排序）
            let road = roads[0]
            if let loc = road["location"] as? String {
                let parts = loc.split(separator: ",").compactMap { Double($0) }
                if parts.count == 2 { return CoordConv.gcj2wgs(parts[1], parts[0]) }
            }
        }
        return nil
    }

    /// 启动后一次性校准 3km 内抓拍点（QPS 限速 0.4s/个，结果持久化防版本升级覆盖）
    func calibrateNearbyPois() {
        Task {
            guard let cur = currentLocation else { return }
            let calibratedKey = "calibratedV146"
            UserDefaults.standard.set(true, forKey: calibratedKey)
            var updated = 0
            for p in pois where p.type.isCamera && p.id < 1000 {
                let d = hypot(p.lat - cur.latitude, p.lon - cur.longitude) * 111000
                guard d < 3000 else { continue }
                if UserDefaults.standard.string(forKey: "calib_v146_\(p.id)") != nil { continue }
                if let (nlat, nlon) = await regeoSnap(lat: p.lat, lon: p.lon) {
                    // 位移超过 80m 才视为校准（避免微小抖动）
                    if hypot(nlat - p.lat, nlon - p.lon) * 111000 > 80 {
                        UserDefaults.standard.set("\(nlat),\(nlon)", forKey: "calib_v146_\(p.id)")
                        updated += 1
                    } else {
                        UserDefaults.standard.set("\(p.lat),\(p.lon)", forKey: "calib_v146_\(p.id)")
                    }
                }
                try? await Task.sleep(nanoseconds: 400_000_000) // 高德 QPS 3 限速
            }
            if updated > 0 {
                applyCalibrations()
                status = "已用高德校准 \(updated) 个附近抓拍点（吸附到最近道路/路口）"
            }
        }
    }

    /// 把已校准坐标应用回当前点位（防内置点位升级被覆盖回原坐标）
    func applyCalibrations() {
        let def = UserDefaults.standard
        var newList = pois
        var changed = false
        for i in newList.indices {
            let p = newList[i]
            if let s = def.string(forKey: "calib_v146_\(p.id)") {
                let parts = s.split(separator: ",").compactMap { Double($0) }
                if parts.count == 2, parts[0] != p.lat || parts[1] != p.lon {
                    newList[i] = Poi(id: p.id, type: p.type, name: p.name,
                                     lat: parts[0], lon: parts[1],
                                     radiusM: p.radiusM, enabled: p.enabled,
                                     note: p.note, isCustom: p.isCustom)
                    changed = true
                }
            }
        }
        if changed {
            pois = newList
            NotificationCenter.default.post(name: .motoPoisChanged, object: nil)
        }
    }

    /// 右下角定位按钮：地图回中
    func centerOnUser() {
        locateTick += 1
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
            // 起点=当前定位点（蓝箭头，不吸附，避免起点偏移）；终点吸附到最近可通行出入口（失败回退原坐标）
            async let eSnap = RouteFetcher.nearest(lat: rawEnd.latitude, lon: rawEnd.longitude)
            let e = await eSnap
            let from2 = from
            let end2 = e ?? rawEnd
            let r = await RouteFetcher.fetch(from: from2, to: end2, amapKey: amapKey)
            if let r = r {
                route = r.points
                routeTurns = r.turns
                routeDistanceM = r.distanceM
                routeDurationS = r.durationS
                lastTurnSpoken = -1
        farAnnounced.removeAll()
                let near = nearbyPoisOnRoute(r.points)
                routePois = near
                fitTick += 1
                status = routeSummary(name, distanceM: r.distanceM, durationS: r.durationS, poiCount: near.count)
            } else {
                fallbackStraightLine(from: from2, to: end2, name: name, lat: lat, lon: lon)
            }
        }
    }

    /// 路线服务不可用时的兜底：画直线示意 + 明确提示（可能横穿禁行区） + 3秒后自动重试
    private func fallbackStraightLine(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D,
                                      name: String, lat: Double, lon: Double) {
        route = [from, to]
        routePois = nearbyPoisOnRoute(route)
        routeTurns = []
        routeDistanceM = 0
        routeDurationS = 0
        routeChoices = []
        fitTick += 1
        status = "路线服务不可用，直线仅为示意（可能横穿不可通行区域），正在自动重试…"
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            // 目的地未变才替换（用户可能已改目标）
            guard self.destName == name, self.destLat == lat, self.destLon == lon else { return }
            let retry = await RouteFetcher.fetchAll(from: from, to: to, amapKey: amapKey)
            if retry.isEmpty { return }
            let list = retry.map { c -> RouteChoice in
                let n = nearbyPoisOnRoute(c.points).count
                return RouteChoice(points: c.points, distanceM: c.distanceM,
                                   durationS: c.durationS, turns: c.turns,
                                   label: c.label, poiCount: n)
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
        routeDistanceM = 0
        routeDurationS = 0
        lastTurnSpoken = -1
        farAnnounced.removeAll()
        endLiveActivity()
        status = "已清除路线"
    }

    /// "去这里/导航到这里"触发：获取多路线方案（起点=当前定位点，终点吸附到最近道路出入口）
    func fetchRouteChoices(to name: String, lat: Double, lon: Double) {
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
            // 起点=当前定位点（蓝箭头，不吸附，避免起点偏移）；终点吸附到最近可通行出入口（失败回退原坐标）
            async let eSnap = RouteFetcher.nearest(lat: rawEnd.latitude, lon: rawEnd.longitude)
            let e = await eSnap
            let from2 = from
            let end2 = e ?? rawEnd
            let choices = await RouteFetcher.fetchAll(from: from2, to: end2, amapKey: amapKey)
            if choices.isEmpty {
                fallbackStraightLine(from: from2, to: end2, name: name, lat: lat, lon: lon)
            } else {
                // 高德式：默认选中推荐方案并画路线，卡片可切换，底部绿色"开始导航"
                let list = choices.map { c -> RouteChoice in
                    let n = nearbyPoisOnRoute(c.points).count
                    return RouteChoice(points: c.points, distanceM: c.distanceM,
                                       durationS: c.durationS, turns: c.turns,
                                       label: c.label, poiCount: n)
                }
                routeChoices = list
                selectedRouteIdx = 0
                applyRouteChoice(list[0], name: name)
            }
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
        status = routeSummary(n, distanceM: c.distanceM, durationS: c.durationS, poiCount: near.count)
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
            navigateFollowTick += 1
            finishTrip()
            endLiveActivity()
            speak("导航结束")
            status = "导航已结束"
        } else {
            guard route.count >= 2 else { status = "请先搜索目的地并规划路线"; return }
            navigating = true
            UIApplication.shared.isIdleTimerDisabled = true // 导航中屏幕常亮（高德式）
            navigateFollowTick += 1
            navStart = Date()
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
        tripSummary = TripSummary(
            destName: destName,
            distanceM: routeDistanceM,
            durationS: dur,
            snapCount: routePois.count)
        navStart = nil
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
            // 重规划起点=当前定位点（蓝箭头），终点仍吸附最近出入口
            let from2 = start
            let end2 = await RouteFetcher.nearest(lat: destLat, lon: destLon) ??
                CLLocationCoordinate2D(latitude: destLat, longitude: destLon)
            if let r = await RouteFetcher.fetch(
                from: from2,
                to: end2,
                amapKey: amapKey) {
                route = r.points
                routeTurns = r.turns
                routeDistanceM = r.distanceM
                routeDurationS = r.durationS
                routePois = nearbyPoisOnRoute(r.points)
                lastTurnSpoken = -1
                farAnnounced.removeAll()
                alertStage = [:]
                fitTick += 1
            }
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
        if toDest < 100 {
            speak("已到达目的地，\(destName)，导航结束")
            status = "已到达：\(destName)"
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
            if best < 900 && !farAnnounced.contains(idx) {
                farAnnounced.insert(idx)
                let road = t.roadName.isEmpty ? "" : "，进入\(t.roadName)"
                speak("前方\(Int(best))米\(text)\(road)")
                status = "导航：前方\(Int(best))米\(text)\(road) · 余\(Int(toDest / 1000))公里"
            } else if best < 150 {
                lastTurnSpoken = idx
                speak("\(text)，距您\(Int(best))米")
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

    /// 沿路线折线累计已走距离（米）：定位点到折线的最近点（含前段距离）
    private func traveledM(_ pts: [CLLocationCoordinate2D], _ loc: CLLocationCoordinate2D) -> Int {
        var bestI = 0
        var bestD = Double.greatestFiniteMagnitude
        for i in pts.indices {
            let d = distanceM(loc, pts[i])
            if d < bestD { bestD = d; bestI = i }
        }
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
