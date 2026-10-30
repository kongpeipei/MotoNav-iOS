import SwiftUI
import MapKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showManualAdd = false
    @State private var editPoi: Poi?
    @State private var showImport = false
    @State private var exportDoc: JsonFile?
    @State private var showExport = false
    @State private var importText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                MapViewRepresentable(
                    pois: model.pois,
                    userLocation: model.currentLocation,
                    route: model.route
                )
                .frame(maxHeight: .infinity)
                controls
                poiList
            }
            .navigationTitle("摩托导航卫士")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("导入 JSON") { showImport = true }
                        Button("导出 JSON") { exportDoc = JsonFile(text: model.exportPois()); showExport = true }
                        Button("清空路线") { model.route = [] }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showManualAdd) {
                PoiEditSheet(mode: .add, poi: nil) { type, name, lat, lon, r in
                    model.addPoi(type: type, name: name, lat: lat, lon: lon, radiusM: r)
                }
            }
            .sheet(item: $editPoi) { p in
                PoiEditSheet(mode: .edit, poi: p) { type, name, lat, lon, r in
                    model.updatePoi(id: p.id, type: type, name: name, lat: lat, lon: lon, radiusM: r)
                }
            }
            .fileImporter(
                isPresented: $showImport, allowedContentTypes: [.json]
            ) { result in
                if case .success(let url) = result,
                   let data = try? Data(contentsOf: url),
                   let text = String(data: data, encoding: .utf8) {
                    let n = model.importPois(text)
                    model.status = "导入成功，新增 \(n) 个点位"
                } else {
                    model.status = "导入失败：JSON 格式不对"
                }
            }
            .fileExporter(
                isPresented: $showExport,
                document: exportDoc ?? JsonFile(text: "[]"),
                contentType: .json,
                defaultFilename: "pois"
            ) { _ in }
            .onAppear { model.authorizeAndStart() }
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.status)
                .font(.footnote).foregroundStyle(.secondary)
                .lineLimit(2)
            HStack {
                Text(model.monitoring ? "● 监控中" : "○ 未监控")
                    .font(.caption2).foregroundStyle(model.monitoring ? .green : .gray)
                if model.simulating { Text("● 模拟中").font(.caption2).foregroundStyle(.orange) }
                Text("点位 \(model.pois.count)")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button(model.monitoring ? "停止" : "开始") {
                model.toggleMonitoring()
            }
            .buttonStyle(.borderedProminent)

            Button(model.simulating ? "停止模拟" : "模拟") {
                model.toggleSimulation()
            }
            .buttonStyle(.bordered)

            Button("加当前位置") {
                guard let loc = model.currentLocation else { model.status = "请先定位"; return }
                model.addPoi(type: .RED_LIGHT, name: "手动添加", lat: loc.latitude, lon: loc.longitude)
                model.status = "已添加当前位置点位"
            }
            .buttonStyle(.bordered)

            Button("手动坐标") { showManualAdd = true }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var poiList: some View {
        List {
            ForEach(model.pois) { p in
                HStack {
                    Circle().fill(Color(p.type.color)).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).font(.subheadline)
                        Text("\(p.type.label) · 半径\(Int(p.radiusM))m\(p.note.isEmpty ? "" : " · \(p.note)")")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { p.enabled },
                        set: { _ in model.togglePoi(id: p.id) }
                    )).labelsHidden()
                }
                .contentShape(Rectangle())
                .onTapGesture { editPoi = p }
                .swipeActions {
                    Button(role: .destructive) { model.deletePoi(id: p.id) } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.inset)
        .frame(height: 260)
    }
}

enum EditMode { case add, edit }

struct PoiEditSheet: View {
    let mode: EditMode
    let poi: Poi?
    let onSave: (PoiType, String, Double, Double, Double) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var type: PoiType = .RED_LIGHT
    @State private var name = ""
    @State private var lat = ""
    @State private var lon = ""
    @State private var radius = "150"

    init(mode: EditMode, poi: Poi?, onSave: @escaping (PoiType, String, Double, Double, Double) -> Void) {
        self.mode = mode
        self.poi = poi
        self.onSave = onSave
        _type = State(initialValue: poi?.type ?? .RED_LIGHT)
        _name = State(initialValue: poi?.name ?? "")
        _lat = State(initialValue: poi.map { String(format: "%.6f", $0.lat) } ?? "")
        _lon = State(initialValue: poi.map { String(format: "%.6f", $0.lon) } ?? "")
        _radius = State(initialValue: poi.map { String(Int($0.radiusM)) } ?? "150")
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: $type) {
                    ForEach(PoiType.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                TextField("名称", text: $name)
                TextField("纬度", text: $lat).keyboardType(.numbersAndPunctuation)
                TextField("经度", text: $lon).keyboardType(.numbersAndPunctuation)
                TextField("提醒半径(米)", text: $radius).keyboardType(.numberPad)
            }
            .navigationTitle(mode == .add ? "添加点位" : "编辑点位")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let la = Double(lat), let lo = Double(lon), !name.isEmpty,
                           let r = Double(radius) {
                            onSave(type, name, la, lo, r)
                        }
                        dismiss()
                    }
                }
            }
        }
    }
}

struct JsonFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var text: String
    init(text: String = "") { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
