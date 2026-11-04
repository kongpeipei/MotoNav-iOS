import Foundation
import CoreLocation

/// v2.30 真实矢量路网源（OpenStreetMap Overpass API）
///
/// 用途：导航时把真实道路网络画成黑色细线（"全黑道路"风格），绿色导航路线包裹其中。
///
/// 数据说明：
/// · Overpass 返回的道路坐标是 **WGS-84**；地图层会统一走 `MapGeo.toGCJ` 再铺到高德底图上，
///   因此与路线/图层坐标体系一致。
/// · 只取机动车可通行的道路（高速/主干/次干/支路/居住区/服务道路及其连接匝道），
///   跳过步道、骑行道、台阶等摩托走不了的路。
enum RoadNetworkFetcher {

    /// 拉取「路线 bbox + 外边距」内的全部机动车道路折线。
    /// - Parameter marginM: 路线四周外扩的米数（道路会画满整片视野，不能只画路线正下方）
    static func fetch(around route: [CLLocationCoordinate2D], marginM: Double = 2500) async -> [[CLLocationCoordinate2D]] {
        guard route.count >= 1 else { return [] }

        // 1) 计算路线包围盒，并按 margin 外扩成度
        var minLat = route[0].latitude, maxLat = route[0].latitude
        var minLon = route[0].longitude, maxLon = route[0].longitude
        for p in route {
            minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude)
            minLon = min(minLon, p.longitude); maxLon = max(maxLon, p.longitude)
        }
        let cosLat = max(cos((minLat + maxLat) / 2 * .pi / 180.0), 0.2)
        let dLat = marginM / 110540.0
        let dLon = marginM / (111320.0 * cosLat)
        var south = minLat - dLat, north = maxLat + dLat
        var west = minLon - dLon, east = maxLon + dLon

        // 2) 限幅：单边最大 ~0.3 度（约 33km），防止长距离路线请求爆数据
        let maxHalf = 0.3
        let cLat = (south + north) / 2, cLon = (west + east) / 2
        south = cLat - min((north - south) / 2, maxHalf)
        north = cLat + min((north - south) / 2, maxHalf)
        west = cLon - min((east - west) / 2, maxHalf)
        east = cLon + min((east - west) / 2, maxHalf)

        // 3) 拼 Overpass QL：只要机动车道路，直接返回几何（out geom）
        let bbox = "\(south),\(west),\(north),\(east)"
        let query = """
        [out:json][timeout:30];
        way["highway"~"^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|service)(_link)?$"](\(bbox));
        out geom;
        """

        // 多个 Overpass 镜像：主站 + 两个公共镜像（国内访问主站可能被墙/超时，逐个尝试）
        let endpoints = [
            "https://overpass-api.de/api/interpreter",
            "https://overpass.kumi.systems/api/interpreter",
            "https://overpass.private.coffee/api/interpreter"
        ]
        for base in endpoints {
            guard var comps = URLComponents(string: base) else { continue }
            comps.queryItems = [URLQueryItem(name: "data", value: query)]
            guard let url = comps.url else { continue }

            var req = URLRequest(url: url)
            req.timeoutInterval = 30
            req.setValue("MotoNav/1.0 (iOS; contact@motonav.app)", forHTTPHeaderField: "User-Agent")

            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                let lines = Self.parse(data)
                if !lines.isEmpty { return lines }
            } catch {
                continue
            }
        }
        return []
    }

    /// 解析 Overpass JSON，返回每条道路的折线（已做轻量抽稀）
    static func parse(_ data: Data) -> [[CLLocationCoordinate2D]] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = obj["elements"] as? [[String: Any]] else { return [] }
        var out: [[CLLocationCoordinate2D]] = []
        for el in elements {
            guard let geom = el["geometry"] as? [[String: Any]], geom.count >= 2 else { continue }
            var pts: [CLLocationCoordinate2D] = []
            for g in geom {
                guard let lat = g["lat"] as? Double, let lon = g["lon"] as? Double else { continue }
                pts.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
            let thinned = Self.thin(pts, minSpacingM: 18)
            if thinned.count >= 2 { out.append(thinned) }
        }
        return out
    }

    /// 相邻点间距 < minSpacingM 的点丢弃（降点数，线条外观几乎无损）
    private static func thin(_ pts: [CLLocationCoordinate2D], minSpacingM: Double) -> [CLLocationCoordinate2D] {
        guard pts.count > 2 else { return pts }
        var result: [CLLocationCoordinate2D] = [pts[0]]
        var last = pts[0]
        for p in pts.dropFirst() {
            let dy = (p.latitude - last.latitude) * 110540.0
            let dx = (p.longitude - last.longitude) * 111320.0 * cos(last.latitude * .pi / 180.0)
            if hypot(dx, dy) >= minSpacingM {
                result.append(p)
                last = p
            }
        }
        // 保证最后一个点不被丢（道路端点）
        if let tail = pts.last, tail.latitude != result.last?.latitude || tail.longitude != result.last?.longitude {
            result.append(tail)
        }
        return result
    }
}