import Foundation

/// 点位仓库：首次运行从内置 poi.json 载入，之后读写 Documents/pois.json
final class PoiRepository {
    private let fileName = "pois.json"
    private var pois: [Poi] = []
    private var nextId: Int64 = 1000

    init() { _ = load() }

    func load() -> [Poi] {
        pois = readFromDocuments() ?? readFromBundle()
        nextId = (pois.map(\.id).max() ?? 0) + 1
        return pois
    }

    func all() -> [Poi] { pois }

    @discardableResult
    func add(type: PoiType, name: String, lat: Double, lon: Double, radiusM: Double = 150) -> Poi {
        let p = Poi(id: nextId, type: type, name: name, lat: lat, lon: lon,
                    radiusM: radiusM, enabled: true, note: "")
        nextId += 1
        pois.append(p)
        persist()
        return p
    }

    func update(id: Int64, type: PoiType, name: String, lat: Double, lon: Double, radiusM: Double) {
        guard let idx = pois.firstIndex(where: { $0.id == id }) else { return }
        pois[idx] = Poi(id: id, type: type, name: name, lat: lat, lon: lon,
                        radiusM: radiusM, enabled: pois[idx].enabled, note: pois[idx].note)
        persist()
    }

    func setEnabled(id: Int64, enabled: Bool) {
        guard let idx = pois.firstIndex(where: { $0.id == id }) else { return }
        pois[idx].enabled = enabled
        persist()
    }

    func remove(id: Int64) {
        pois.removeAll { $0.id == id }
        persist()
    }

    func importJson(_ text: String) -> Int {
        guard let data = text.data(using: .utf8),
              let list = try? JSONDecoder().decode([Poi].self, from: data) else { return 0 }
        var added = 0
        for var p in list {
            p.id = nextId
            nextId += 1
            pois.append(p)
            added += 1
        }
        persist()
        return added
    }

    func exportJson() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(pois),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    // MARK: - 持久化

    private func fileURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }

    private func readFromDocuments() -> [Poi]? {
        let url = fileURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Poi].self, from: data) else { return nil }
        return list
    }

    private func readFromBundle() -> [Poi] {
        guard let url = Bundle.main.url(forResource: "poi", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Poi].self, from: data) else { return [] }
        return list
    }

    private func persist() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(pois) {
            try? data.write(to: fileURL(), options: .atomic)
        }
    }
}
