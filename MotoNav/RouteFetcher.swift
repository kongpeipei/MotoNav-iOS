import Foundation
import CoreLocation

/// 高德瓦片/接口坐标转换（v1.47 独立静态方法，避免 @MainActor 隔离问题）
enum CoordConv {
    private static func outOfChina(_ lat: Double, _ lon: Double) -> Bool {
        if lon < 72.004 || lon > 137.8347 { return true }
        if lat < 0.8293 || lat > 55.8271 { return true }
        return false
    }
    private static func transformLat(_ x: Double, _ y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * .pi) + 320.0 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return ret
    }
    private static func transformLon(_ x: Double, _ y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return ret
    }
    /// WGS-84 → GCJ-02（请求高德接口前转换）
    static func wgs2gcj(_ lat: Double, _ lon: Double) -> (Double, Double) {
        if outOfChina(lat, lon) { return (lat, lon) }
        let dLat = transformLat(lon - 105.0, lat - 35.0)
        let dLon = transformLon(lon - 105.0, lat - 35.0)
        let radLat = lat / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - 0.00669342162296594323 * magic * magic
        let sqrtMagic = sqrt(magic)
        let dLat2 = (dLat * 180.0) / ((6378245.0 * (1 - 0.00669342162296594323)) / (magic * sqrtMagic) * .pi)
        let dLon2 = (dLon * 180.0) / (6378245.0 / sqrtMagic * cos(radLat) * .pi)
        return (lat + dLat2, lon + dLon2)
    }
    /// GCJ-02 → WGS-84（高德接口返回后转换，用于苹果地图显示）
    /// v1.98 改为迭代逼近：旧版一次性反解（lat*2-glat）误差 1~5 米，
    /// 长路线累积后会出现"路线压不到路中心"的观感
    static func gcj2wgs(_ lat: Double, _ lon: Double) -> (Double, Double) {
        if outOfChina(lat, lon) { return (lat, lon) }
        var wlat = lat
        var wlon = lon
        for _ in 0..<3 {
            let (glat, glon) = wgs2gcj(wlat, wlon)
            wlat += lat - glat
            wlon += lon - glon
        }
        return (wlat, wlon)
    }
}

/// 转向步骤：距起点里程(米) + 动作 + 方向修饰 + 转入道路名 + 车道指引 + 位置
struct RouteTurn {
    let fromStartM: Int
    let action: String
    let modifier: String
    let roadName: String
    let lanes: [String]
    let coordinate: CLLocationCoordinate2D
}

/// 路由结果：折线点 + 距离 + 耗时 + 转向步骤
struct RouteResult {
    let points: [CLLocationCoordinate2D]
    let distanceM: Int
    let durationS: Int
    let turns: [RouteTurn]
}

/// 路线方案：折线 + 距离 + 用时 + 优点标签 + 途经抓拍点数（供方案选择列表展示）
struct RouteChoice {
    let points: [CLLocationCoordinate2D]
    let distanceM: Int
    let durationS: Int
    let turns: [RouteTurn]
    let label: String
    let poiCount: Int
    /// v1.99 路况分段（高德 tmc），只在拥堵/缓行段有值
    var traffic: [TrafficSpan] = []
    /// v2.18 红绿灯个数（高德 path.traffic_lights；拿不到为 -1）
    var trafficLights: Int = -1
}

/// 免费骑行/驾车路径规划（OSRM 公共服务，无需 API Key），
/// 与安卓端保持一致。失败返回 nil，调用方降级为直线。
enum RouteFetcher {

    static func fetch(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) async -> RouteResult? {
        await fetchAll(from: start, to: end).first.map {
            RouteResult(points: $0.points, distanceM: $0.distanceM, durationS: $0.durationS, turns: $0.turns)
        }
    }

    /// 将坐标吸附到最近可通行道路上的点（"最近出入口"），OSRM /nearest 服务；
    /// 失败返回 nil，调用方回退原坐标
    static func nearest(lat: Double, lon: Double) async -> CLLocationCoordinate2D? {
        guard let url = URL(string: "https://router.project-osrm.org/nearest/v1/driving/\(lon),\(lat)?number=1")
        else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("MotoNavHelper/1.0", forHTTPHeaderField: "User-Agent")
        for _ in 0..<2 {
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let wp = root["waypoints"] as? [[String: Any]],
               let first = wp.first,
               let loc = first["location"] as? [Double], loc.count >= 2 {
                return CLLocationCoordinate2D(latitude: loc[1], longitude: loc[0])
            }
        }
        return nil
    }

    /// v1.65 步行连接段：当前位置 → 起点吸附出入口（OSRM foot 步行路线，GPS 点在停车区/小区内时连到最近道路）；
    /// v1.82 请求失败时返回直线段兜底：保证绿线从当前位置连到出口，绝不凭空出现在路上
    static func walkPoints(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D
    ) async -> [CLLocationCoordinate2D] {
        let dist = CLLocation(latitude: from.latitude, longitude: from.longitude)
            .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
        if dist < 8 { return [] } // 起点已在路上，无需步行段
        let coord = "\(from.longitude),\(from.latitude);\(to.longitude),\(to.latitude)"
        guard let url = URL(string:
            "https://router.project-osrm.org/route/v1/foot/\(coord)"
            + "?overview=full&geometries=geojson"
        ) else { return [from, to] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("MotoNavHelper/1.0", forHTTPHeaderField: "User-Agent")
        for _ in 0..<2 {
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let routes = root["routes"] as? [[String: Any]],
               let r0 = routes.first,
               let geom = r0["geometry"] as? [String: Any],
               let coords = geom["coordinates"] as? [[Double]],
               !coords.isEmpty {
                return coords.compactMap { c in
                    c.count >= 2 ? CLLocationCoordinate2D(latitude: c[1], longitude: c[0]) : nil
                }
            }
        }
        // v1.82 直线兜底：步行服务不可用时直接用直线连接，绿线起点仍是当前位置（不悬空）
        return [from, to]
    }

    /// 获取多条路线方案，分配优点标签
    /// v1.26：增加请求超时与一次重试，公共实例不稳定时降低"直线降级"概率
    /// v1.57：优先使用高德路线规划API，失败回退OSRM
    /// v1.98：全面改为高德多策略并发（0/1/2/3/4/5/6/8），按几何形状去重，
    ///        不再混入 OSRM（OSM 路网与高德底图不同源，会画出"不在路上"的备选线）
    static func fetchAll(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        amapKey: String = "",
        via: [CLLocationCoordinate2D] = []
    ) async -> [RouteChoice] {
        var result: [RouteChoice] = []
        if !amapKey.isEmpty {
            result = await fetchAmapDriving(from: start, to: end, key: amapKey, via: via)
        }
        // 高德不可用（无 Key / 配额用尽 / 网络异常）时兜底 OSRM
        if result.isEmpty {
            result = await fetchOsrmChoices(from: start, to: end)
        }
        // 路线质量过滤：剔除异常/绕路/折返乱窜的不可用方案
        result = filterUsableChoices(result, from: start, to: end)
        // v1.98 标签重排：第一条固定"推荐"（用时最短），距离最短的一条标"距离最短"，
        // 其余保留策略优势标签（少收费/躲避拥堵/不走高速），重复的退化为"备选"
        if !result.isEmpty {
            let minDist = result.map(\.distanceM).min() ?? 0
            // v2.18 高德式第三条标签：红绿灯最少的一条标「等灯少」（数据来自 path.traffic_lights）
            let headLights = result[0].trafficLights
            let minLights = result.filter { $0.trafficLights >= 0 }.map(\.trafficLights).min()
            var used = Set<String>()
            var out: [RouteChoice] = []
            for (i, c) in result.enumerated() {
                var label = i == 0 ? "推荐" : c.label
                if i > 0 {
                    if c.distanceM == minDist && !used.contains("距离最短") {
                        label = "距离最短"
                    } else if let ml = minLights, c.trafficLights == ml,
                              (headLights < 0 || ml < headLights), !used.contains("等灯少") {
                        label = "等灯少"
                    } else if used.contains(label) || label == "推荐" {
                        label = "备选"
                    }
                }
                used.insert(label)
                out.append(RouteChoice(points: c.points, distanceM: c.distanceM,
                                       durationS: c.durationS, turns: c.turns,
                                       label: label, poiCount: c.poiCount,
                                       traffic: c.traffic, trafficLights: c.trafficLights))
            }
            result = out
        }
        return result
    }

    /// v1.84 方案质量过滤：
    /// 1) 数据异常（0 米/0 秒/折线点过少）直接剔除；
    /// 2) 距离合理性：过短（<直线40%）或严重绕路（>直线5倍）剔除；
    /// 3) 连续大幅折返（>137° 反向占比过高）→ 横穿小区/无路网乱绕特征，剔除。
    static func filterUsableChoices(
        _ choices: [RouteChoice],
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> [RouteChoice] {
        let straight = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        return choices.filter { c in
            guard c.points.count >= 2, c.distanceM >= 30, c.durationS >= 20 else { return false }
            if straight > 50 {
                if Double(c.distanceM) < straight * 0.4 || Double(c.distanceM) > straight * 5.0 {
                    return false
                }
            }
            return !hasExcessiveReversals(c)
        }
    }

    /// 折返检测：连续方向角反转 >137° 且单段长 >25m 的次数占比过高 → 路线乱绕（横穿小区/无路网）
    private static func hasExcessiveReversals(_ c: RouteChoice) -> Bool {
        let pts = c.points
        guard pts.count > 6 else { return false }
        var reversals = 0
        var segCount = 0
        var prevBearing: Double?
        for i in 1..<pts.count {
            let len = CLLocation(latitude: pts[i-1].latitude, longitude: pts[i-1].longitude)
                .distance(from: CLLocation(latitude: pts[i].latitude, longitude: pts[i].longitude))
            guard len > 25 else { continue }
            let dx = (pts[i].longitude - pts[i-1].longitude) * cos(pts[i-1].latitude * .pi / 180)
            let dy = pts[i].latitude - pts[i-1].latitude
            let bearing = atan2(dy, dx)
            if let pb = prevBearing {
                var d = abs(bearing - pb)
                if d > .pi { d = 2 * .pi - d }
                if d > 2.4 { reversals += 1 } // ~137.5°
                segCount += 1
            }
            prevBearing = bearing
        }
        return segCount > 2 && Double(reversals) / Double(segCount) > 0.35
    }

    /// OSRM alternatives 多方案（公共服务，作为高德方案不足时的补充来源）
    private static func fetchOsrmChoices(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) async -> [RouteChoice] {
        let coord = "\(start.longitude),\(start.latitude);\(end.longitude),\(end.latitude)"
        guard let url = URL(string:
            "https://router.project-osrm.org/route/v1/driving/\(coord)"
            + "?overview=full&geometries=geojson&steps=true&alternatives=3"
        ) else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("MotoNavHelper/1.0", forHTTPHeaderField: "User-Agent")
        for _ in 0..<2 {
            if let (data, _) = try? await URLSession.shared.data(for: req) {
                let parsed = parseAll(data)
                if !parsed.isEmpty { return parsed }
            }
        }
        return []
    }

    /// 高德驾车路线规划（v1.98 多策略并发）
    /// 高德 v3 单次只回主方案，不同 strategy 会给出真正不同的备选（少收费/躲拥堵/不走高速…），
    /// 并发取回后按几何形状去重，避免"策略不同但路线一样"的假备选。
    private static func fetchAmapDriving(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        key: String,
        via: [CLLocationCoordinate2D] = []
    ) async -> [RouteChoice] {
        // v1.98 坐标系：app 内地图/标注/OSM 数据都是 WGS-84（屏幕网格为 WGS 墨卡托），
        // 高德接口收发都需要 GCJ-02 → 请求前 WGS→GCJ，返回后再 GCJ→WGS 绘制
        let (glat1, glon1) = CoordConv.wgs2gcj(start.latitude, start.longitude)
        let (glat2, glon2) = CoordConv.wgs2gcj(end.latitude, end.longitude)
        let origin = String(format: "%.6f,%.6f", glon1, glat1)
        let destination = String(format: "%.6f,%.6f", glon2, glat2)
        // v1.99 途经点 / v2.19 多途经点：高德 waypoints 参数，多个用 ; 分隔，按顺序依次穿过
        var waypoints: String? = nil
        if !via.isEmpty {
            waypoints = via.map { v -> String in
                let (vlat, vlon) = CoordConv.wgs2gcj(v.latitude, v.longitude)
                return String(format: "%.6f,%.6f", vlon, vlat)
            }.joined(separator: ";")
        }

        // v2.18 方案池 = 高德 v5「默认策略 + alternative_route=3」的多备选
        //              + v3 多策略（互补：v3 每个 strategy 只回一条主方案，只能多打几次）
        //
        // 旧版只打 v3 的 5 个 strategy，每个只回 1 条，形状去重后往往只剩 2 条，
        // 而高德 App 同一 OD 能给 3 条 —— 差别就在"候选池"本身大小。
        // 与 v3 多策略并发跑，总耗时取两者较慢的一边（串行会白白多等一次往返）
        async let v5Future = requestV5(origin: origin, destination: destination, key: key,
                                       alternatives: 3, label: "推荐", waypoints: waypoints)

        // 策略：0 速度优先 / 2 距离优先 / 4 躲避拥堵 / 5 多策略 / 6 不走高速
        // （"1 费用优先"在城市短途几乎与 0 完全同一条，去掉省一次请求，避免撞 QPS 限额）
        let strategies: [(String, String)] = [
            ("0", "推荐"), ("2", "距离最短"),
            ("4", "躲避拥堵"), ("5", "多策略"), ("6", "不走高速"),
        ]
        var v3: [RouteChoice] = []
        await withTaskGroup(of: [RouteChoice].self) { group in
            for (st, label) in strategies {
                group.addTask {
                    await requestStrategy(origin: origin, destination: destination,
                                          key: key, st: st, label: label, waypoints: waypoints)
                }
            }
            for await list in group { v3.append(contentsOf: list) }
        }
        let v5 = await v5Future
        let primary = v5.first?.points

        var pool = v5 + v3
        // 用时升序 → 几何去重（形状几乎一致视为同一条，保留用时更短者）
        pool.sort { $0.durationS < $1.durationS }
        var unique: [RouteChoice] = []
        for c in pool {
            if unique.contains(where: { sameShape($0.points, c.points) }) { continue }
            unique.append(c)
        }
        // v2.18 高德 v5 的第一条就是高德 App 的「推荐」：把它顶到最前，其余按用时排。
        // 旧版一律按用时排序，等于用"纯时间最优"覆盖了高德的"综合推荐"——
        // 同一 OD 高德推荐走快速路 6.0km/13 分，我们却把 5.6km/13 分的小路排到了第一位。
        if let p = primary, let idx = unique.firstIndex(where: { sameShape($0.points, p) }), idx > 0 {
            let head = unique.remove(at: idx)
            unique.insert(head, at: 0)
        }
        return Array(unique.prefix(4))
    }

    /// v2.18 高德 v5 驾车规划：`alternative_route` 一次返回 1~4 条备选，
    /// 这才是高德 App 里并列三张卡片的来源（v3 的每个 strategy 只给一条主方案）。
    ///
    /// 兜底策略：先用 show_fields 取全量字段，若被拒（部分 Key 未开通 v5 / 字段名变更）
    /// 再不传 show_fields 重试一次；两次都失败就返回空数组，自动退回 v3 多策略。
    /// 另外只接受"能解析出转向步骤"的方案 —— v5 的 steps 字段比 v3 少，
    /// 没有 action/road 就没有转向播报，宁可不要这条候选。
    private static func requestV5(
        origin: String, destination: String, key: String,
        alternatives: Int, label: String, waypoints: String? = nil
    ) async -> [RouteChoice] {
        for useFields in [true, false] {
            var urlStr = "https://restapi.amap.com/v5/direction/driving?key=\(key)"
                + "&origin=\(origin)&destination=\(destination)"
                + "&alternative_route=\(alternatives)"
            if useFields { urlStr += "&show_fields=cost,navi,polyline" }
            if let w = waypoints, !w.isEmpty { urlStr += "&waypoints=\(w)" }
            guard let url = URL(string: urlStr) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 12
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let route = obj["route"] as? [String: Any],
                  let paths = route["paths"] as? [[String: Any]] else { continue }
            let parsed = paths.compactMap { parseAmapPath($0, label: label) }
                .filter { $0.points.count >= 2 && ($0.turns.count >= 2 || $0.distanceM < 200) }
            if !parsed.isEmpty { return parsed }
        }
        return []
    }

    /// 两条折线形状是否几乎一致（采样点平均偏差 < 70 米）
    private static func sameShape(_ a: [CLLocationCoordinate2D],
                                  _ b: [CLLocationCoordinate2D]) -> Bool {
        guard a.count > 1, b.count > 1 else { return false }
        let n = 16
        var sum = 0.0
        for i in 0..<n {
            let p = a[min(a.count - 1, i * a.count / n)]
            let q = b[min(b.count - 1, i * b.count / n)]
            sum += CLLocation(latitude: p.latitude, longitude: p.longitude)
                .distance(from: CLLocation(latitude: q.latitude, longitude: q.longitude))
        }
        return sum / Double(n) < 70
    }

    /// 单个 strategy 请求（返回该策略下所有候选 path）
    private static func requestStrategy(
        origin: String, destination: String, key: String,
        st: String, label: String, waypoints: String? = nil
    ) async -> [RouteChoice] {
        var urlStr = "https://restapi.amap.com/v3/direction/driving?key=\(key)&origin=\(origin)&destination=\(destination)&extensions=all&strategy=\(st)"
        if let w = waypoints, !w.isEmpty {
            urlStr += "&waypoints=\(w)"
        }
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let route = obj["route"] as? [String: Any],
              let paths = route["paths"] as? [[String: Any]] else { return [] }
        return paths.compactMap { parseAmapPath($0, label: label) }
    }

    /// 解析高德 v3 单条 path 为 RouteChoice（折线点 + 转向步骤 + 路况分段）
    private static func parseAmapPath(_ p: [String: Any], label: String) -> RouteChoice? {
        guard let distStr = p["distance"] as? String,
              let distanceM = Int(distStr),
              let durStr = p["duration"] as? String,
              let durationS = Int(durStr),
              let steps = p["steps"] as? [[String: Any]] else { return nil }
        var points: [CLLocationCoordinate2D] = []
        var turns: [RouteTurn] = []
        var traffic: [TrafficSpan] = []
        var acc = 0
        for step in steps {
            guard let polyline = step["polyline"] as? String else { continue }
            // v1.98 高德返回 GCJ-02 → 转 WGS-84 再绘制（屏幕网格为 WGS 墨卡托）
            var stepPts: [CLLocationCoordinate2D] = []
            for seg in polyline.split(separator: ";") {
                let parts = seg.split(separator: ",").compactMap { Double($0) }
                guard parts.count >= 2 else { continue }
                let (wlat, wlon) = CoordConv.gcj2wgs(parts[1], parts[0])
                let c = CLLocationCoordinate2D(latitude: wlat, longitude: wlon)
                // 连续重复点去掉，减少绘制抖动
                if let last = points.last,
                   abs(last.latitude - c.latitude) < 1e-7,
                   abs(last.longitude - c.longitude) < 1e-7 { continue }
                points.append(c)
                stepPts.append(c)
            }
            // v1.99 路况：v3 的 step.tmc（dict）或 v5 的 step.tmcs（数组）
            if let tmc = step["tmc"] as? [String: Any],
               let lv = statusLevel(tmc["status"] as? String), lv >= 1,
               stepPts.count >= 2 {
                traffic.append(TrafficSpan(level: lv, points: stepPts))
            } else if let tmcs = step["tmcs"] as? [[String: Any]] {
                for t in tmcs {
                    guard let poly = t["polyline"] as? String,
                          let lv = statusLevel(t["status"] as? String), lv >= 1 else { continue }
                    let pts = parsePolyline(poly)
                    if pts.count >= 2 { traffic.append(TrafficSpan(level: lv, points: pts)) }
                }
            }
            if let roadName = step["road"] as? String,
               let action = step["action"] as? String,
               let originStr = step["origin"] as? String {
                let originParts = originStr.split(separator: ",").compactMap { Double($0) }
                if originParts.count >= 2 {
                    acc += Int(step["distance"] as? String ?? "0") ?? 0
                    let (tlat, tlon) = CoordConv.gcj2wgs(originParts[1], originParts[0])
                    turns.append(RouteTurn(
                        fromStartM: acc,
                        action: action,
                        modifier: step["assist_action"] as? String ?? "",
                        roadName: roadName,
                        lanes: [],
                        coordinate: CLLocationCoordinate2D(latitude: tlat, longitude: tlon)
                    ))
                }
            }
        }
        let lights = Int(p["traffic_lights"] as? String ?? "") ?? -1
        return RouteChoice(points: points, distanceM: distanceM, durationS: durationS,
                           turns: turns, label: label, poiCount: 0, traffic: traffic,
                           trafficLights: lights)
    }

    /// 高德折线字符串 → 坐标数组（GCJ → WGS）
    private static func parsePolyline(_ s: String) -> [CLLocationCoordinate2D] {
        var out: [CLLocationCoordinate2D] = []
        for seg in s.split(separator: ";") {
            let parts = seg.split(separator: ",").compactMap { Double($0) }
            guard parts.count >= 2 else { continue }
            let (wlat, wlon) = CoordConv.gcj2wgs(parts[1], parts[0])
            out.append(CLLocationCoordinate2D(latitude: wlat, longitude: wlon))
        }
        return out
    }

    /// 高德路况文字 → 等级（0 畅通 / 1 缓行 / 2 拥堵 / 3 严重拥堵）
    private static func statusLevel(_ s: String?) -> Int? {
        guard let s = s, !s.isEmpty else { return nil }
        if s.contains("严重") { return 3 }
        if s.contains("拥堵") { return 2 }
        if s.contains("缓行") || s.contains("缓慢") { return 1 }
        if s.contains("畅通") { return 0 }
        return nil
    }

    private static func parseAll(_ data: Data) -> [RouteChoice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let routes = root["routes"] as? [[String: Any]]
        else { return [] }

        var list: [RouteResult] = []
        for r in routes {
            guard let geo = r["geometry"] as? [String: Any],
                  let coords = geo["coordinates"] as? [[Double]]
            else { continue }
            var points: [CLLocationCoordinate2D] = []
            for c in coords where c.count >= 2 {
                points.append(CLLocationCoordinate2D(latitude: c[1], longitude: c[0]))
            }
            var turns: [RouteTurn] = []
            var acc = 0
            if let legs = r["legs"] as? [[String: Any]] {
                for leg in legs {
                    guard let steps = leg["steps"] as? [[String: Any]] else { continue }
                    for step in steps {
                        guard let mv = step["maneuver"] as? [String: Any] else { continue }
                        let action = mv["type"] as? String ?? ""
                        if action == "depart" { continue }
                        let modifier = mv["modifier"] as? String ?? ""
                        var lat = 0.0, lon = 0.0
                        if let loc = mv["location"] as? [Double], loc.count >= 2 {
                            lat = loc[1]; lon = loc[0]
                        }
                        acc += step["distance"] as? Int ?? 0
                        let roadName = step["name"] as? String ?? ""
                        var lanes: [String] = []
                        if let laneArr = step["lanes"] as? [[String: Any]] {
                            for lane in laneArr {
                                if let inds = lane["indications"] as? [String], let first = inds.first {
                                    lanes.append(first)
                                }
                            }
                        }
                        turns.append(RouteTurn(
                            fromStartM: acc, action: action, modifier: modifier,
                            roadName: roadName, lanes: lanes,
                            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)))
                    }
                }
            }
            list.append(RouteResult(
                points: points,
                distanceM: r["distance"] as? Int ?? 0,
                durationS: r["duration"] as? Int ?? 0,
                turns: turns))
        }
        // 按用时升序 + 真实标签：【推荐】用时最短、【距离最短】真实最短，其余统一【备选】
        // （OSRM 无红绿灯/高速数据，"少红绿灯/不走高速"属虚假相对标注，已移除）
        list.sort { $0.durationS < $1.durationS }
        let minDist = list.map(\.distanceM).min() ?? 0
        var out: [RouteChoice] = []
        for (i, rr) in list.enumerated() {
            let label: String
            switch i {
            case 0: label = "推荐"
            case 1 where rr.distanceM == minDist: label = "距离最短"
            default: label = "备选"
            }
            out.append(RouteChoice(points: rr.points, distanceM: rr.distanceM,
                                   durationS: rr.durationS, turns: rr.turns, label: label, poiCount: 0))
        }
        if out.count == 1 {
            out[0] = RouteChoice(points: out[0].points, distanceM: out[0].distanceM,
                                 durationS: out[0].durationS, turns: out[0].turns,
                                 label: "推荐", poiCount: 0)
        }
        return out
    }

    private static func parse(_ data: Data) -> RouteResult? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let routes = root["routes"] as? [[String: Any]],
              let r = routes.first,
              let geo = r["geometry"] as? [String: Any],
              let coords = geo["coordinates"] as? [[Double]]
        else { return nil }

        var points: [CLLocationCoordinate2D] = []
        for c in coords where c.count >= 2 {
            points.append(CLLocationCoordinate2D(latitude: c[1], longitude: c[0]))
        }

        var turns: [RouteTurn] = []
        var acc = 0
        if let legs = r["legs"] as? [[String: Any]] {
            for leg in legs {
                guard let steps = leg["steps"] as? [[String: Any]] else { continue }
                for step in steps {
                    guard let mv = step["maneuver"] as? [String: Any] else { continue }
                    let action = mv["type"] as? String ?? ""
                    if action == "depart" { continue }
                    let modifier = mv["modifier"] as? String ?? ""
                    var lat = 0.0, lon = 0.0
                    if let loc = mv["location"] as? [Double], loc.count >= 2 {
                        lat = loc[1]; lon = loc[0]
                    }
                    acc += step["distance"] as? Int ?? 0
                    let roadName = step["name"] as? String ?? ""
                    var lanes: [String] = []
                    if let laneArr = step["lanes"] as? [[String: Any]] {
                        for lane in laneArr {
                            if let inds = lane["indications"] as? [String], let first = inds.first {
                                lanes.append(first)
                            }
                        }
                    }
                    turns.append(RouteTurn(
                        fromStartM: acc, action: action, modifier: modifier,
                        roadName: roadName, lanes: lanes,
                        coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)))
                }
            }
        }

        return RouteResult(
            points: points,
            distanceM: r["distance"] as? Int ?? 0,
            durationS: r["duration"] as? Int ?? 0,
            turns: turns
        )
    }
}
