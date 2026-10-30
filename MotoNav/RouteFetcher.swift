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

    /// 获取多条路线方案（alternatives=3），按用时升序 + 分配优点标签
    /// v1.26：增加请求超时与一次重试，公共实例不稳定时降低"直线降级"概率
    static func fetchAll(
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
