import SwiftUI
import MapKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var searchText = ""
    @State private var suggestions: [String] = []
    @State private var showSuggestions = false
    @State private var longPressCoord: CLLocationCoordinate2D?
    @State private var showLongPressMenu = false
    @State private var editPoi: Poi?
    @State private var showImport = false
    @State private var exportDoc: JsonFile?
    @State private var showExport = false
    @State private var typeFilter: Set<PoiType> = Set(PoiType.allCases)

    @FocusState private var searchFocused: Bool
    @State private var pendingCoord: CLLocationCoordinate2D?
    @State private var showTypePicker = false
    @State private var poiManagePoi: Poi?
    @State private var headingNeedleTick = 0
    /// 待导航目标（搜索预览 / 点击地图地点）
    @State private var goHereName: String?
    @State private var goHereLat = 0.0
    @State private var goHereLon = 0.0
    @State private var goHereLabel = ""

    var body: some View {
        ZStack {
            mapLayer
            // 左上角指南针（手机朝向即指针指向）
            compassOverlay
            menuOverlay
            bottomOverlay
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
        // 长按已有点位：删除 / 编辑 / 导航
        .confirmationDialog("点位操作", isPresented: Binding(
            get: { poiManagePoi != nil },
            set: { if !$0 { poiManagePoi = nil } }
        ), presenting: poiManagePoi) { p in
            Button("导航到这里") {
                model.planRoute(to: p.name, lat: p.lat, lon: p.lon)
            }
            Button("编辑该点位") { editPoi = p }
            Button("删除该点位", role: .destructive) {
                model.deletePoi(id: p.id)
                model.status = "已删除：\(p.name)"
            }
            Button("取消", role: .cancel) {}
        } message: { p in
            Text(String(format: "%@ · %@\n纬度 %.5f 经度 %.5f", p.name, p.type.label, p.lat, p.lon))
        }
        .onAppear { model.authorizeAndStart(); model.fetchPlaceLabels() }
        // 预览点变化（含在线搜索兜底）→ 同步"去这里"按钮
        .onChange(of: model.searchPreview) { p in
            if let p = p {
                goHereLabel = "去这里：\(displayName(model.searchPreviewName))"
                goHereName = model.searchPreviewName
                goHereLat = p.latitude
                goHereLon = p.longitude
            }
        }
    }

    /// 地图全屏层（高德式：地图在上，搜索框下置）
    private var mapLayer: some View {
        MapViewRepresentable(
            pois: model.pois,
            userLocation: model.currentLocation,
            route: model.route,
            routePois: model.routePois,
            locateTick: model.locateTick,
            fitTick: model.fitTick,
            heading: model.heading,
            preview: model.searchPreview,
            gasStations: model.gasStations,
            gasTick: model.gasTick,
            placeLabels: model.placeLabels,
            onLongPress: { coord in
                longPressCoord = coord
                showLongPressMenu = true
            },
            onPoiLongPress: { p in
                poiManagePoi = p
            },
            onPoiSelect: { p in
                model.selectedPoi = p
                goHereLabel = "导航到此处：\(displayName(p.name))"
                goHereName = p.name
                goHereLat = p.lat
                goHereLon = p.lon
                model.clearPreview()
            },
            onPlaceSelect: { pl in
                goHereLabel = "导航到此处：\(displayName(pl.name))"
                goHereName = pl.name
                goHereLat = pl.lat
                goHereLon = pl.lon
                model.clearPreview()
            }
        )
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { dismissKeyboard() }
    }

    /// 右上角 ⋯ 菜单（v1.12 精简：只剩清历史/清路线/导入/导出）
    private var menuOverlay: some View {
        VStack {
            HStack {
                Spacer()
                // 天气小图标（⋯ 左侧）
                if let w = model.weatherText {
                    Text(w)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.black.opacity(0.5), in: Capsule())
                }
                Menu {
                    Button("清空历史搜索") { model.clearHistory() }
                    Button("清空路线") { model.clearRoute() }
                    Divider()
                    Button("导入 JSON") { showImport = true }
                    Button("导出 JSON") { exportDoc = JsonFile(text: model.exportPois()); showExport = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title2)
                        .foregroundStyle(.white)
                }
                .padding(8)
                .background(.black.opacity(0.5), in: Circle())
                .padding(.trailing, 12)
                .padding(.top, 6)
            }
            Spacer()
        }
    }

    /// 底部浮层：状态 + 历史 + 定位按钮 + 去这里 + 搜索框/退出导航
    private var bottomOverlay: some View {
        VStack(spacing: 0) {
            Spacer()
            statusBar
            historyBar
            if model.navigating {
                // 导航中：搜索框替换为退出导航按钮
                Button {
                    model.toggleNavigation()
                } label: {
                    Text("退出导航")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.red, in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal)
                }
                .padding(.vertical, 6)
                // 定位按钮（搜索框上侧偏右）
                locateRow
            } else {
                goHereBar
                searchBar
                locateRow
            }
        }
    }

    /// 右下角定位按钮：放在搜索框上侧偏右
    private var locateRow: some View {
        HStack {
            Spacer()
            Button {
                model.centerOnUser()
            } label: {
                Image(systemName: "location.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .padding(11)
                    .background(.black.opacity(0.85), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                    .shadow(radius: 2)
            }
            .padding(.trailing, 16)
            .padding(.bottom, 6)
        }
    }

    /// 搜索预览"去这里" / 点选地点"导航到此处"按钮（绿色）
    private var goHereBar: some View {
        Group {
            if let n = goHereName {
                Button {
                    model.planRoute(to: n, lat: goHereLat, lon: goHereLon)
                    goHereName = nil
                    model.clearPreview()
                } label: {
                    Text(goHereLabel)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.green, in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal)
                }
                .padding(.bottom, 4)
            }
        }
    }

    /// 左上角指南针：指针指示正北
    private var compassOverlay: some View {
        VStack {
            HStack {
                ZStack {
                    Circle().fill(.black.opacity(0.5))
                    Circle().strokeBorder(.white.opacity(0.75), lineWidth: 2)
                    Image(systemName: "location.north.fill")
                        .font(.title3)
                        .foregroundStyle(.red)
                        .rotationEffect(.degrees(model.heading))
                    Text("N")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .offset(y: -22)
                }
                .frame(width: 54, height: 54)
                .padding(.leading, 12)
                .padding(.top, 6)
                Spacer()
            }
            Spacer()
        }
    }

    private func dismissKeyboard() {
        searchFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func addPoiAtPending(type: PoiType) {
        guard let c = pendingCoord else { return }
        model.addPoi(type: type, name: "地图新增\(type.label)点", lat: c.latitude, lon: c.longitude)
        model.status = "已添加：地图新增\(type.label)点"
        pendingCoord = nil
    }

    private var statusBar: some View {
        Text(model.status)
            .font(.footnote)
            .foregroundStyle(.white)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.45))
    }

    /// 目的地搜索框（输入时智能联想，高德式底部胶囊；导航时被退出按钮替代）
    private var searchBar: some View {
        VStack(spacing: 4) {
            searchInputRow
            if showSuggestions && !suggestions.isEmpty {
                suggestionsList
            }
        }
        .background(.black.opacity(0.18))
    }

    /// 搜索输入行：输入框 + 搜索按钮 + 加油站按钮
    private var searchInputRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索目的地", text: $searchText)
                    .font(.subheadline)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .onSubmit { showSuggestions = false; dismissKeyboard(); doSearch() }
                    .onChange(of: searchText) { newValue in
                        suggestions = model.searchSuggestions(newValue).map { displayName($0) }
                        if !suggestions.contains(NAV_ITEM) {
                            suggestions.append(NAV_ITEM)
                        }
                        showSuggestions = !newValue.trimmingCharacters(in: .whitespaces).isEmpty
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white, in: Capsule())
            .overlay(Capsule().stroke(.quaternary))

            Button {
                showSuggestions = false
                dismissKeyboard()
                doSearch()
            } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
            .padding(6)
            .background(.black.opacity(0.55), in: Circle())

            // 加油站按钮：显示市区加油站
            Button {
                showSuggestions = false
                dismissKeyboard()
                model.fetchGasStations()
            } label: {
                Text("⛽")
                    .font(.title3)
                    .foregroundStyle(.white)
            }
            .padding(6)
            .background(.black.opacity(0.55), in: Circle())
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    /// 联想下拉列表
    private var suggestionsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { idx, s in
                    suggestionButton(idx, s)
                }
            }
        }
        .frame(maxHeight: 200)
        .background(.bar)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
        .padding(.horizontal)
    }

    /// 联想条目按钮（含分隔线）
    private func suggestionButton(_ idx: Int, _ s: String) -> some View {
        VStack(spacing: 0) {
            Button {
                searchFocused = false
                showSuggestions = false
                if s == NAV_ITEM {
                    model.toggleNavigation()
                } else if s.hasPrefix("🔍") {
                    let q = extractOnlineQuery(s)
                    doSearch(q)
                } else {
                    searchText = s
                    doSearch()
                }
            } label: {
                suggestionRow(s)
            }
            .buttonStyle(.plain)
            Divider()
        }
    }

    /// 联想条目行（图标按条目类型区分）
    private func suggestionRow(_ s: String) -> some View {
        HStack {
            Image(systemName: suggestionIcon(s))
                .foregroundStyle(suggestionIconColor(s))
            Text(s).foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func suggestionIcon(_ s: String) -> String {
        if s == NAV_ITEM { return "arrow.right.circle" }
        if s.hasPrefix("🔍") { return "magnifyingglass" }
        return "mappin.and.ellipse"
    }

    private func suggestionIconColor(_ s: String) -> Color {
        if s == NAV_ITEM { return .accentColor }
        if s.hasPrefix("🔍") { return .orange }
        return .secondary
    }

    /// 历史搜索记录（横滑标签，地址简化显示）
    private var historyBar: some View {
        Group {
            if !model.searchHistory.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.searchHistory, id: \.self) { item in
                            Button(displayName(item)) {
                                searchText = item
                                showSuggestions = false
                                dismissKeyboard()
                                doSearch()
                            }
                            .font(.caption)
                            .foregroundStyle(.white)
                            .buttonStyle(.bordered)
                            .tint(.white)
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 4)
            }
        }
    }

    /// 联想展示简化：去掉"与XX路交口"，只显示地址名称（导航目标不变）
    private func displayName(_ name: String) -> String {
        let full = #"^(.*?(大道|路|街|巷|线|口))与.*(交口|路口|交叉口)$"#
        if let regex = try? NSRegularExpression(pattern: full),
           let m = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
           let r = Range(m.range(at: 1), in: name) {
            return String(name[r])
        }
        return name.replacingOccurrences(of: #"(交口|路口|交叉口)$"#, with: "", options: .regularExpression)
    }

    private let NAV_ITEM = "▶ 开始导航"

    /// 从「🔍 在线搜索「XX」」提取 XX
    private func extractOnlineQuery(_ s: String) -> String {
        if let start = s.firstIndex(of: "「"), let end = s.lastIndex(of: "」"), start < end {
            return String(s[s.index(after: start)..<end])
        }
        return s
    }

    /// v1.12：搜索后地图绿色高亮定位点，等待"去这里"规划路线；找不到走在线模糊搜索
    private func doSearch() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { model.status = "请输入目的地"; return }
        // 支持 纬度,经度
        let parts = q.split(whereSeparator: { $0 == "," || $0 == "，" }).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
           (lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180) {
            model.addHistory("坐标目的地 \(lat),\(lon)")
            model.setPreview("坐标目的地 \(lat),\(lon)", lat: lat, lon: lon)
            goHereLabel = "去这里：坐标目的地"
            goHereName = "坐标目的地"
            goHereLat = lat; goHereLon = lon
            model.status = "已定位，点「去这里」规划路线"
            return
        }
        let hits = model.searchPois(q)
        if !hits.isEmpty {
            if hits.count == 1 {
                let p = hits[0]
                model.selectedPoi = p
                model.setPreview(p.name, lat: p.lat, lon: p.lon)
                goHereLabel = "去这里：\(displayName(p.name))"
                goHereName = p.name
                goHereLat = p.lat; goHereLon = p.lon
                model.status = "已定位到「\(p.name)」，点「去这里」规划路线"
            } else {
                model.status = "找到 \(hits.count) 个匹配，请点击地图点位或直接输入 纬度,经度"
                model.selectedPoi = nil
            }
            return
        }
        // 合肥小区/商铺：联想命中则在线查询坐标（精确）后预览
        if model.hfPois.contains(where: { $0.localizedCaseInsensitiveContains(q) }) {
            model.status = "正在查询「\(q)」位置…"
            Task {
                if let c = await model.findHefeiCoordinate(q, fuzzy: false) {
                    model.setPreview(q, lat: c.latitude, lon: c.longitude)
                    goHereLabel = "去这里：\(displayName(q))"
                    goHereName = q
                    goHereLat = c.latitude; goHereLon = c.longitude
                    model.status = "已定位到「\(q)」，点「去这里」规划路线"
                } else {
                    model.onlineSearch(q)
                }
            }
            return
        }
        // 兜底：模糊在线搜索（覆盖未收录的新小区/商铺）
        model.onlineSearch(q)
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
