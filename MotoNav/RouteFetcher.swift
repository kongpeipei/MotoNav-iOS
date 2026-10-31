import Foundation
import CoreLocation

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
        to end: CLLocationCoordinate2D,
        amapKey: String = AppModel.builtinAmapKey
    ) async -> RouteResult? {
        await fetchAll(from: start, to: end, amapKey: amapKey).first.map {
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

    /// 获取多条路线方案（alternatives=3），按用时升序 + 分配优点标签
    /// v1.26：增加请求超时与一次重试，公共实例不稳定时降低"直线降级"概率
    /// v1.46：优先走高德路径规划（实际道路更准确），失败回退 OSRM；高德成功时补充 OSRM 备选
    static func fetchAll(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        amapKey: String = AppModel.builtinAmapKey
    ) async -> [RouteChoice] {
        var out: [RouteChoice] = []
        // 高德通道：真实道路路网 + 官方耗时估算
        if !amapKey.isEmpty {
            let amapChoices = await amapFetchAll(from: start, to: end, key: amapKey)
            if !amapChoices.isEmpty {
                out.append(contentsOf: amapChoices)
            }
        }
        // OSRM 备选（高德未给满 3 条时补充，保证方案卡可选）
        let osrmChoices = await osrmFetchAll(from: start, to: end)
        for c in osrmChoices {
            if out.count >= 3 { break }
            // 跳过与高德路线起点终点完全一致的重复
            let dup = out.contains { existing in
                existing.distanceM == c.distanceM && abs(existing.durationS - c.durationS) < 30
            }
            if !dup {
                out.append(RouteChoice(points: c.points, distanceM: c.distanceM,
                                       durationS: c.durationS, turns: c.turns,
                                       label: "备选", poiCount: c.poiCount))
            }
        }
        // v1.47：截断 3 条 + 用时升序（推荐最前）；保留高德策略标签（躲避拥堵/少收费/高速优先）
        if out.count > 3 { out = Array(out.prefix(3)) }
        out.sort { $0.durationS < $1.durationS }
        if out.count == 1 {
            out[0] = RouteChoice(points: out[0].points, distanceM: out[0].distanceM,
                                 durationS: out[0].durationS, turns: out[0].turns,
                                 label: "推荐", poiCount: 0)
        }
        return out
    }

    // MARK: - 高德路径规划通道（v1.46/v1.47）

    /// 高德驾车路径规划：多策略并行（推荐/躲避拥堵/少收费/高速优先），真实道路 polyline + 转向指令
    private static func amapFetchAll(from start: CLLocationCoordinate2D,
                                     to end: CLLocationCoordinate2D,
                                     key: String) async -> [RouteChoice] {
        // 请求前转 GCJ-02（高德坐标系）
        let s = AppModel.shared.wgs2gcj(start.latitude, start.longitude)
        let e = AppModel.shared.wgs2gcj(end.latitude, end.longitude)
        let origin = "\(s.1),\(s.0)"
        let dest = "\(e.1),\(e.0)"
        // v1.47 多策略：0 推荐 / 4 躲避拥堵 / 11 少收费 / 10 高速优先
        let strategies: [(String, String)] = [
            ("0", "推荐"), ("4", "躲避拥堵"), ("11", "少收费"), ("10", "高速优先")
        ]
        var out: [RouteChoice] = []
        await withTaskGroup(of: (String, RouteChoice?).self) { group in
            for (strategy, label) in strategies {
                group.addTask {
                    guard let url = URL(string:
                        "https://restapi.amap.com/v3/direction/driving?key=\(key)"
                        + "&origin=\(origin)&destination=\(dest)&extensions=all&strategy=\(strategy)"
                    ) else { return (label, nil) }
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 12
                    for _ in 0..<2 {
                        if let (data, _) = try? await URLSession.shared.data(for: req),
                           let choice = parseAmap(data, label: label) {
                            return (label, choice)
                        }
                    }
                    return (label, nil)
                }
            }
            for await (_, choice) in group {
                if let c = choice { out.append(c) }
            }
        }
        return out
    }

    /// 解析高德 driving 响应（paths[0]：steps.polyline 拼接 + instruction 转向），坐标转 WGS-84
    private static func parseAmap(_ data: Data, label: String) -> RouteChoice? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let route = root["route"] as? [String: Any],
              let paths = route["paths"] as? [[String: Any]],
              let p = paths.first
        else { return nil }
        var points: [CLLocationCoordinate2D] = []
        var turns: [RouteTurn] = []
        var acc = 0
        if let steps = p["steps"] as? [[String: Any]] {
            for step in steps {
                guard let poly = step["polyline"] as? String else { continue }
                for pair in poly.split(separator: ";") {
                    let ll = pair.split(separator: ",")
                    guard ll.count == 2, let lon = Double(ll[0]), let lat = Double(ll[1]) else { continue }
                    // v1.47 坐标纠偏：高德 GCJ-02 → WGS-84（苹果地图显示）
                    let w = AppModel.shared.gcj2wgs(lat, lon)
                    points.append(CLLocationCoordinate2D(latitude: w.0, longitude: w.1))
                }
                // 转向指令解析（instruction 如"沿学林路向西行驶420米，左转"）
                let instruction = step["instruction"] as? String ?? ""
                if let firstPt = points.last, !instruction.isEmpty {
                    let act = amapAction(instruction)
                    if act != "继续" {
                        acc += step["distance"] as? Int ?? 0
                        let road = amapRoadName(instruction)
                        turns.append(RouteTurn(fromStartM: acc, action: act,
                                               modifier: amapModifier(act), roadName: road,
                                               lanes: [], coordinate: firstPt))
                    }
                }
            }
        }
        guard !points.isEmpty else { return nil }
        return RouteChoice(
            points: points,
            distanceM: p["distance"] as? Int ?? 0,
            durationS: p["duration"] as? Int ?? 0,
            turns: turns,
            label: label,
            poiCount: 0)
    }

    /// 从高德 instruction 提取转向动作
    private static func amapAction(_ s: String) -> String {
        if s.contains("左转") { return "left" }
        if s.contains("右转") { return "right" }
        if s.contains("掉头") { return "uturn" }
        if s.contains("到达") || s.contains("终点") { return "arrive" }
        if s.contains("进入环岛") { return "roundabout" }
        if s.contains("上高速") || s.contains("进入高速") { return "motorway" }
        if s.contains("驶出") || s.contains("离开高速") { return "exit" }
        return "continue"
    }

    private static func amapModifier(_ action: String) -> String {
        switch action {
        case "left": return "左转"
        case "right": return "右转"
        case "uturn": return "掉头"
        case "arrive": return "到达"
        case "roundabout": return "环岛"
        case "motorway": return "高速"
        case "exit": return "出口"
        default: return "直行"
        }
    }

    /// 提取"进入/沿 XX路"的道路名
    private static func amapRoadName(_ s: String) -> String {
        for kw in ["沿", "进入", "直行进入", "向右前方行驶"] {
            if let r = s.range(of: kw) {
                let tail = String(s[r.upperBound...])
                let road = tail.split(whereSeparator: { $0 == "向" || $0 == "，" || $0 == "，" }).first.map(String.init) ?? ""
                if !road.isEmpty { return road }
            }
        }
        return ""
    }

    private static func osrmFetchAll(
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
