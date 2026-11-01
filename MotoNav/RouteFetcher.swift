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
    static func gcj2wgs(_ lat: Double, _ lon: Double) -> (Double, Double) {
        if outOfChina(lat, lon) { return (lat, lon) }
        let (glat, glon) = wgs2gcj(lat, lon)
        return (lat * 2 - glat, lon * 2 - glon)
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
    /// v1.82：高德多策略合并出多条不同路线；仍不足 2 条时用 OSRM alternatives 补充，保证"合理推荐多条并列出优势"
    static func fetchAll(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        amapKey: String = ""
    ) async -> [RouteChoice] {
        var result: [RouteChoice] = []
        // 优先使用高德路线规划（多策略合并）
        if !amapKey.isEmpty {
            result = await fetchAmapDriving(from: start, to: end, key: amapKey)
        }
        // v1.82 高德方案不足 4 条 → OSRM alternatives 补充（按距离差异去重，车道数据优先：
        // 高德 v3 无车道字段，OSRM 方案的 lanes 更真实，切换备选方案可获得真实车道卡）
        if result.count < 4 {
            let osrm = await fetchOsrmChoices(from: start, to: end)
            // 含真实车道的方案排在前面
            let laneFirst = osrm.filter { $0.turns.contains { !$0.lanes.isEmpty } } + osrm
            for o in laneFirst {
                if result.count >= 4 { break }
                let dup = result.contains { abs($0.distanceM - o.distanceM) < max(80, $0.distanceM / 40) }
                if !dup { result.append(o) }
            }
        }
        // 首条固定"推荐"（综合最优的第一方案）
        if !result.isEmpty {
            let f = result[0]
            result[0] = RouteChoice(points: f.points, distanceM: f.distanceM,
                                    durationS: f.durationS, turns: f.turns,
                                    label: "推荐", poiCount: 0)
        }
        return result
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

    /// 高德驾车路线规划API（v1.82 多策略合并：速度最快/距离最短 → 多条不同路线 + 真实优势标签；
    /// 不足 2 条时再补少收费/躲避拥堵，控制请求数省配额——每次规划默认 2 次高德调用）
    private static func fetchAmapDriving(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        key: String
    ) async -> [RouteChoice] {
        let origin = "\(start.longitude),\(start.latitude)"
        let destination = "\(end.longitude),\(end.latitude)"
        // v3 strategy：0=速度最快, 1=距离最短, 2=少收费, 4=躲避拥堵
        let primary: [(String, String)] = [("0", "推荐"), ("1", "最短")]
        let extra: [(String, String)] = [("2", "少收费"), ("4", "少拥堵")]
        var out: [RouteChoice] = []
        for (st, label) in primary {
            await fetchStrategy(origin: origin, destination: destination, key: key,
                                st: st, label: label, out: &out)
        }
        // 主策略仍不足 2 条 → 补后两个策略
        if out.count < 2 {
            for (st, label) in extra {
                await fetchStrategy(origin: origin, destination: destination, key: key,
                                    st: st, label: label, out: &out)
            }
        }
        return out
    }

    /// 单个 strategy 请求并去重合并（距离差异 >2% 视为不同路线）
    private static func fetchStrategy(
        origin: String, destination: String, key: String,
        st: String, label: String, out: inout [RouteChoice]
    ) async {
        let urlStr = "https://restapi.amap.com/v3/direction/driving?key=\(key)&origin=\(origin)&destination=\(destination)&extensions=all&strategy=\(st)"
        guard let url = URL(string: urlStr),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let route = obj["route"] as? [String: Any],
              let paths = route["paths"] as? [[String: Any]],
              let first = paths.first,
              let rc = parseAmapPath(first, label: label) else { return }
        let dup = out.contains { abs($0.distanceM - rc.distanceM) < max(50, rc.distanceM / 50) }
        if !dup { out.append(rc) }
    }

    /// 解析高德 v3 单条 path 为 RouteChoice（折线点 + 转向步骤）
    private static func parseAmapPath(_ p: [String: Any], label: String) -> RouteChoice? {
        guard let distStr = p["distance"] as? String,
              let distanceM = Int(distStr),
              let durStr = p["duration"] as? String,
              let durationS = Int(durStr),
              let steps = p["steps"] as? [[String: Any]] else { return nil }
        var points: [CLLocationCoordinate2D] = []
        var turns: [RouteTurn] = []
        var acc = 0
        for step in steps {
            guard let polyline = step["polyline"] as? String else { continue }
            let coords = polyline.split(separator: ";").map { seg -> CLLocationCoordinate2D in
                let parts = seg.split(separator: ",").compactMap { Double($0) }
                return CLLocationCoordinate2D(latitude: parts[1], longitude: parts[0])
            }
            points.append(contentsOf: coords)
            if let roadName = step["road"] as? String,
               let action = step["action"] as? String,
               let originStr = step["origin"] as? String {
                let originParts = originStr.split(separator: ",").compactMap { Double($0) }
                if originParts.count >= 2 {
                    acc += Int(step["distance"] as? String ?? "0") ?? 0
                    turns.append(RouteTurn(
                        fromStartM: acc,
                        action: action,
                        modifier: step["assist_action"] as? String ?? "",
                        roadName: roadName,
                        lanes: [],
                        coordinate: CLLocationCoordinate2D(latitude: originParts[1], longitude: originParts[0])
                    ))
                }
            }
        }
        return RouteChoice(points: points, distanceM: distanceM, durationS: durationS,
                           turns: turns, label: label, poiCount: 0)
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
