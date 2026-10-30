import SwiftUI
import MapKit
import PhotosUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var searchText = ""
    @State private var suggestions: [String] = []
    @State private var showSuggestions = false
    @State private var longPressCoord: CLLocationCoordinate2D?
    @State private var showLongPressMenu = false
    @State private var showManualAdd = false
    @State private var editPoi: Poi?
    @State private var showImport = false
    @State private var exportDoc: JsonFile?
    @State private var showExport = false
    @State private var typeFilter: Set<PoiType> = Set(PoiType.allCases)

    var body: some View {
        NavigationStack {
            ZStack {
                // 自定义背景（相册选择）
                if let img = model.bgImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .ignoresSafeArea()
                        .opacity(0.35)
                }
                VStack(spacing: 0) {
                    statusBar
                    searchBar
                    historyBar
                    ZStack(alignment: .bottomTrailing) {
                        MapViewRepresentable(
                            pois: model.pois,
                            userLocation: model.currentLocation,
                            route: model.route,
                            routePois: model.routePois,
                            locateTick: model.locateTick,
                            fitTick: model.fitTick,
                            onLongPress: { coord in
                                longPressCoord = coord
                                showLongPressMenu = true
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        // 右下角定位按钮
                        Button {
                            model.centerOnUser()
                        } label: {
                            Image(systemName: "location.fill")
                                .font(.title3)
                                .foregroundStyle(.white)
                                .padding(12)
                                .background(.blue.opacity(0.9), in: Circle())
                                .shadow(radius: 3)
                        }
                        .padding(16)
                    }
                    navControls
                }
            }
            .navigationTitle("摩托导航卫士")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(model.monitoring ? "停止监控" : "开始监控") {
                            model.toggleMonitoring()
                        }
                        Button(model.simulating ? "停止模拟" : "模拟测试") {
                            model.toggleSimulation()
                        }
                        Button("添加当前位置") {
                            guard let loc = model.currentLocation else { model.status = "请先定位"; return }
                            model.addPoi(type: .RED_LIGHT, name: "手动添加", lat: loc.latitude, lon: loc.longitude)
                            model.status = "已添加当前位置点位"
                        }
                        Button("手动添加坐标") { showManualAdd = true }
                        Divider()
                        Button(model.allPoiEnabled ? "全部点位关闭" : "全部点位开启") {
                            model.setAllPoiEnabled(!model.allPoiEnabled)
                        }
                        Menu("点位类型筛选") {
                            ForEach(PoiType.allCases, id: \.self) { t in
                                Button {
                                    let on = model.enabledTypes.contains(t)
                                    model.setTypeEnabled(t, enabled: !on)
                                } label: {
                                    if model.enabledTypes.contains(t) {
                                        Label(t.label, systemImage: "checkmark")
                                    } else {
                                        Text(t.label)
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("导入 JSON") { showImport = true }
                        Button("导出 JSON") { exportDoc = JsonFile(text: model.exportPois()); showExport = true }
                        Divider()
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Label("更换背景（相册）", systemImage: "photo")
                        }
                        Button("恢复默认背景") { model.clearBackground() }
                        Divider()
                        Button("清空历史搜索") { model.clearHistory() }
                        Button("清空路线") { model.clearRoute() }
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
            .confirmationDialog("地图选点", isPresented: $showLongPressMenu, presenting: longPressCoord) { coord in
                Button("添加违法拍照") {
                    pendingCoord = coord
                    showTypePicker = true
                }
                Button("导航到这里") {
                    model.planRoute(to: "地图选点", lat: coord.latitude, lon: coord.longitude)
                }
                Button("取消", role: .cancel) {}
            } message: { coord in
                Text(String(format: "纬度 %.5f\n经度 %.5f", coord.latitude, coord.longitude))
            }
            .confirmationDialog("选择违法拍照类型", isPresented: $showTypePicker) {
                ForEach(PoiType.allCases, id: \.self) { t in
                    Button(t.label) { addPoiAtPending(type: t) }
                }
                Button("取消", role: .cancel) {}
            }
            .onAppear { model.authorizeAndStart() }
            .onChange(of: pickerItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        model.saveBackground(data: data)
                        model.status = "背景已更换（可在 ⋯ 菜单恢复默认）"
                    }
                }
            }
        }
    }

    @State private var pendingCoord: CLLocationCoordinate2D?
    @State private var showTypePicker = false
    @State private var pickerItem: PhotosPickerItem?

    private func addPoiAtPending(type: PoiType) {
        guard let c = pendingCoord else { return }
        model.addPoi(type: type, name: "地图新增\(type.label)点", lat: c.latitude, lon: c.longitude)
        model.status = "已添加：地图新增\(type.label)点"
        pendingCoord = nil
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
                if model.navigating { Text("● 导航中").font(.caption2).foregroundStyle(.blue) }
                Text("点位 \(model.pois.count)")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// 目的地搜索框（输入时智能联想）
    private var searchBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                TextField("搜索目的地：点位名称 / 纬度,经度", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
                    .submitLabel(.search)
                    .onSubmit { showSuggestions = false; doSearch() }
                    .onChange(of: searchText) { newValue in
                        suggestions = model.searchSuggestions(newValue)
                        showSuggestions = !newValue.trimmingCharacters(in: .whitespaces).isEmpty
                    }
                Button("搜索") { showSuggestions = false; doSearch() }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)

            // 联想下拉
            if showSuggestions && !suggestions.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(suggestions, id: \.self) { s in
                            Button {
                                searchText = s
                                showSuggestions = false
                                doSearch()
                            } label: {
                                HStack {
                                    Image(systemName: "mappin.and.ellipse")
                                        .foregroundStyle(.secondary)
                                    Text(s).foregroundStyle(.primary)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 180)
                .background(.bar)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .padding(.horizontal)
            }
        }
    }

    /// 历史搜索记录（横滑标签）
    private var historyBar: some View {
        Group {
            if !model.searchHistory.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.searchHistory, id: \.self) { item in
                            Button(item) {
                                searchText = item
                                doSearch()
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 4)
            }
        }
    }

    /// 底部：导航按钮
    private var navControls: some View {
        HStack(spacing: 10) {
            Button(model.navigating ? "结束导航" : "开始导航") {
                model.toggleNavigation()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)

            Button("清除路线") { model.clearRoute() }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func doSearch() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { model.status = "请输入目的地"; return }
        // 支持 纬度,经度
        let parts = q.split(whereSeparator: { $0 == "," || $0 == "，" }).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
           (lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180) {
            model.planRoute(to: "坐标目的地 \(lat),\(lon)", lat: lat, lon: lon)
            return
        }
        let hits = model.searchPois(q)
        if !hits.isEmpty {
            if hits.count == 1 {
                let p = hits[0]
                model.selectedPoi = p
                model.planRoute(to: p.name, lat: p.lat, lon: p.lon)
            } else {
                model.status = "找到 \(hits.count) 个匹配，请点击地图点位或直接输入 纬度,经度"
                model.selectedPoi = nil
            }
            return
        }
        // 合肥小区/商铺：在线查询坐标后规划
        if model.hfPois.contains(where: { $0.localizedCaseInsensitiveContains(q) }) {
            model.status = "正在查询「\(q)」位置…"
            Task {
                if let c = await model.findHefeiCoordinate(q) {
                    model.planRoute(to: q, lat: c.latitude, lon: c.longitude)
                } else {
                    model.status = "未找到「\(q)」的坐标，可尝试地图长按选点"
                }
            }
            return
        }
        model.status = "未找到「\(q)」，请尝试点位名称或输入 纬度,经度"
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
