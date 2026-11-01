import Foundation
import CoreLocation
import Combine

// =============================================================================
// v1.99 组队骑行：同一队伍码的骑手互相看到位置（地图上显示队友头像点 + 距离）。
// 传输走公共 ntfy.sh 主题（免费、无需后端与密钥），队伍码随机 6 位，
// 只有知道队伍码的人才能收发。位姿每 8 秒上报一次，6 秒拉取一次。
// 仅用于骑行途中互相照应，不做长期存储。
// =============================================================================

struct TeamMember: Identifiable, Equatable {
    var id: String { name }
    let name: String
    var lat: Double
    var lon: Double
    var speedKph: Double
    var updatedAt: Date

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    var ageText: String {
        let s = Int(Date().timeIntervalSince(updatedAt))
        if s < 20 { return "刚刚" }
        if s < 60 { return "\(s) 秒前" }
        return "\(s / 60) 分钟前"
    }
}

final class TeamRide: ObservableObject {
    static let shared = TeamRide()

    @Published var active = false
    @Published var code = ""
    @Published var nickname = ""
    @Published var members: [TeamMember] = []
    @Published var status = ""
    @Published var lastError: String?

    private var timer: Timer?
    private var myLat: Double?
    private var myLon: Double?
    private var mySpeed: Double = 0
    private var lastPublish = Date.distantPast
    private var isWorking = false

    private var topic: String { "motonav-" + code.lowercased() }
    private var base: String { "https://ntfy.sh/" + topic }

    var others: [TeamMember] { members.filter { $0.name != nickname } }

    /// 生成 6 位队伍码（去掉易混字符 0/O/1/I）
    static func randomCode() -> String {
        let chars = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
        return String((0..<6).map { _ in chars.randomElement()! })
    }

    func start(code raw: String, nickname name: String) {
        let c = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard c.count >= 4 else {
            lastError = "队伍码至少 4 位"
            return
        }
        code = c
        nickname = name.isEmpty ? "骑手\(Int.random(in: 100...999))" : name
        members = []
        active = true
        lastError = nil
        status = "正在连接队伍 \(c)…"
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        active = false
        members = []
        status = ""
    }

    /// 导航/定位回调里刷新自己的位置
    func update(lat: Double, lon: Double, speedKph: Double) {
        myLat = lat
        myLon = lon
        mySpeed = speedKph
    }

    private func tick() {
        guard active, !isWorking else { return }
        isWorking = true
        Task { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastPublish) > 8 { await self.publish() }
            await self.poll()
            self.isWorking = false
        }
    }

    private func publish() async {
        guard let lat = myLat, let lon = myLon else { return }
        lastPublish = Date()
        let safeName = nickname.replacingOccurrences(of: "\"", with: "")
        let body = "{\"n\":\"\(safeName)\",\"lat\":\(lat),\"lon\":\(lon),\"s\":\(Int(mySpeed))}"
        guard let url = URL(string: base) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body.data(using: .utf8)
        req.timeoutInterval = 8
        req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        _ = try? await URLSession.shared.data(for: req)
    }

    private func poll() async {
        guard let url = URL(string: base + "/json?poll=1&since=3m") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else {
            await MainActor.run { self.lastError = "连接失败，检查网络" }
            return
        }
        var map: [String: TeamMember] = [:]
        for line in text.split(separator: "\n") {
            guard let d = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let msg = obj["message"] as? String,
                  let md = msg.data(using: .utf8),
                  let pay = try? JSONSerialization.jsonObject(with: md) as? [String: Any],
                  let n = pay["n"] as? String,
                  let lat = pay["lat"] as? Double,
                  let lon = pay["lon"] as? Double else { continue }
            let sp = (pay["s"] as? Double) ?? Double(pay["s"] as? Int ?? 0)
            map[n] = TeamMember(name: n, lat: lat, lon: lon, speedKph: sp, updatedAt: Date())
        }
        // 我自己的位置也放进列表（用本地最新值，避免延迟）
        if let lat = myLat, let lon = myLon {
            map[nickname] = TeamMember(name: nickname, lat: lat, lon: lon,
                                       speedKph: mySpeed, updatedAt: Date())
        }
        await MainActor.run {
            self.members = map.values.sorted { $0.name < $1.name }
            self.lastError = nil
            self.status = "队伍 \(self.code) · \(self.members.count) 人在线"
        }
    }
}
