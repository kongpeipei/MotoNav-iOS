import SwiftUI
import MapKit
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var searchText = ""
    @State private var showSuggestions = false
    /// v1.53 最近常搜"更多"展开开关
    @State private var showAllRecent = false
    /// 高德「输入提示」联想候选（填写高德 Key 后启用，点击直接定位跳转）
    @State private var onlineTips: [AppModel.AmapTip] = []
    /// 高德搜索 Key 输入弹窗
    @State private var showAmapKeyInput = false
    @State private var amapKeyInput = ""
    /// 点击地标「搜周边」（v1.47）
    @State private var aroundPlace: PlaceLabel?
    @State private var aroundPois: [AppModel.AmapPoi] = []
    @State private var aroundKeyword = "加油站"
    @State private var showAround = false
    /// v1.49：规划态搜索改用独立全屏 sheet（搜索框只在首页出现）
    @State private var showSearchSheet = false
    /// v1.49：图层切换（标准/卫星）
    @State private var mapType: MKMapType = .standard
    /// v1.49：历史轨迹列表
    @State private var showTripList = false
    @State private var showOfflineMapHint = false
    @State private var trafficTimerStarted = false
    /// v1.51：高德瓦片底图（A 选项，默认开：底图与路线同源消除偏差）
    @State private var useAmapTiles = true
    /// v1.52：语音播报设置弹窗（高德式音色选择）
    @State private var showVoiceSettings = false
    @State private var longPressCoord: CLLocationCoordinate2D?
    @State private var showLongPressMenu = false
    /// 标记该点：待标记坐标 + 备注输入
    @State private var pendingMarkCoord: CLLocationCoordinate2D?
    @State private var showMarkNameAlert = false
    @State private var markName = ""
    /// 点位详情气泡（点击点位弹出：距离/收藏/分享/导航）
    @State private var poiDetail: Poi?
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
    /// 顶部搜索胶囊展开标记（规划态搜索框移至底部时，点击顶部胶囊重新展开搜索）
    @State private var showSearchField = false
    /// 搜索框当前高度（手指上下滑动调整）
    @State private var searchHeight: CGFloat = 54
    /// v1.54 实时路况图层开关（高德式右侧控制钮）
    @State private var showTraffic = true
    /// v1.55 搜索面板"收藏夹"入口
    @State private var showFavSheet = false
    /// v1.56 路线详情（分步指引 sheet）
    @State private var showRouteDetail = false
    /// v1.56 极简模式（隐藏道路标注，高德导航"极简"）
    @State private var minimalMap = false

    var body: some View {
        ZStack {
            mapLayer
            // 左上角指南针（手机朝向即指针指向）
            compassOverlay
            if !model.navigating {
                menuOverlay
            }
            // 天气条（屏幕最上边；导航中隐藏，高德导航顶部只留导航信息）
            if !model.navigating {
                weatherOverlay
            }
            // 规划态顶部路线胶囊（"我的位置 → 目的地"，点击重新搜索）
            routeBarOverlay
            // 地图缩放 + / - 按钮
            zoomOverlay
            // v1.54 高德式右侧竖排控制钮（图层/路况/语音/缩放）
            mapControlsOverlay
            // v1.56 高德式左侧竖排（导航中：刷新路线 / 极简模式）
            navLeftOverlay
            // 导航中悬浮退出按钮
            exitNavOverlay
            // 高德式顶部大数字条（剩余里程/时间，导航中显示）
            navTopBar
            bottomOverlay
        }
        .sheet(item: $poiDetail) { p in
            PoiDetailSheet(poi: p, model: model) { close in
                poiDetail = nil
            }
        }
        // v1.52：语音播报设置（讯飞音色选择，高德式底部弹窗）
        .sheet(isPresented: $showVoiceSettings) {
            VoiceSettingsSheet(model: model)
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
            Button("标记该点") {
                pendingMarkCoord = coord
                markName = ""
                showMarkNameAlert = true
            }
            Button("取消", role: .cancel) {}
        }
        .alert("标记该点", isPresented: $showMarkNameAlert) {
            TextField("备注名称（如：前方有大坑 / 事故多发地）", text: $markName)
            Button("保存标记") {
                let name = markName.trimmingCharacters(in: .whitespacesAndNewlines)
                let final = name.isEmpty ? "自定义标记点" : name
                if let c = pendingMarkCoord {
                    model.addPoi(type: .CUSTOM, name: final, lat: c.latitude, lon: c.longitude)
                    model.status = "已标记：\(final)（长按图标可拖动微调位置）"
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("输入备注名称，保存后下次打开 App 依然保留；长按图标可拖动微调位置")
        }
        .alert("高德搜索Key", isPresented: $showAmapKeyInput) {
            TextField("粘贴高德开放平台 Web 服务 Key", text: $amapKeyInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("保存") {
                let k = amapKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                model.setAmapKey(k)
                model.status = k.isEmpty ? "高德Key已清除，恢复本地联想" : "高德Key已保存，搜索输入即显示高德联想候选"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("在高德开放平台（lbs.amap.com）注册后创建应用，获取 Web 服务 Key，粘贴后搜索联想即为高德数据（含精确坐标，点击直接定位）")
        }
        // v1.47：点击地图小区/商业标注 → 搜周边（高德周边搜索）
        .sheet(isPresented: $showAround) {
            if let pl = aroundPlace {
                aroundSheet(pl)
                    .presentationDetents([.medium, .large])
            }
        }
        // v1.55：搜索面板"收藏夹"（列出收藏点位，点击直接导航）
        .sheet(isPresented: $showFavSheet) {            NavigationStack {
                let favs = model.pois.filter { model.isFavorite($0) }
                List {
                    if favs.isEmpty {
                        Text("暂无收藏，长按地图点位 → 收藏").foregroundStyle(.secondary)
                    } else {
                        ForEach(favs) { p in
                            Button {
                                model.planRoute(to: p.name, lat: p.lat, lon: p.lon)
                                showFavSheet = false
                            } label: {
                                HStack {
                                    Text(p.name)
                                    Spacer()
                                    Text("导航").font(.subheadline).foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }
                .navigationTitle("收藏夹")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { showFavSheet = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        // v1.56：路线详情（选中方案分步指引，高德式底部按钮）
        .sheet(isPresented: $showRouteDetail) {
            NavigationStack {
                let c = model.routeChoices.indices.contains(model.selectedRouteIdx) ? model.routeChoices[model.selectedRouteIdx] : nil
                List {
                    if let c {
                        Section {
                            HStack {
                                Text("\(c.durationS / 60) 分钟")
                                Text("·")
                                Text(c.distanceM < 1000 ? "\(c.distanceM)米" : String(format: "%.1f公里", Double(c.distanceM) / 1000.0))
                                Text("·")
                                Text("抓拍\(c.poiCount)处")
                            }
                            .font(.subheadline.bold())
                        } header: {
                            Text("方案概览")
                        }
                        Section {
                            if c.turns.isEmpty {
                                Text("暂无分步指引（直线示意路线）").foregroundStyle(.secondary)
                            } else {
                                ForEach(Array(c.turns.enumerated()), id: \.offset) { i, t in
                                    HStack(spacing: 10) {
                                        Image(systemName: navTurnIcon(t.modifier))
                                            .font(.body.bold())
                                            .foregroundStyle(Color(red: 0.16, green: 0.38, blue: 1.0))
                                            .frame(width: 24)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(navTurnText(t) + (t.roadName.isEmpty ? "" : " 进入 \(t.roadName)"))
                                                .font(.subheadline)
                                            Text("距起点 \(navDist(t.fromStartM))")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        } header: {
                            Text("分步指引")
                        }
                    } else {
                        Text("暂无路线")
                    }
                }
                .navigationTitle("路线详情")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { showRouteDetail = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        // v1.49：规划态搜索 sheet（全屏，搜索框只在首页出现）
        .sheet(isPresented: $showSearchSheet) {
            NavigationStack {
                VStack(spacing: 0) {
                    searchInputRow
                    if showSuggestions && !onlineTips.isEmpty {
                        onlineTipsList
                    }
                    Spacer()
                }
                .navigationTitle("搜索目的地")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showSearchSheet = false; dismissKeyboard() }
                    }
                }
            }
            .presentationDetents([.large])
        }
        // v1.49：历史轨迹列表（骑行回放）
        .sheet(isPresented: $showTripList) {
            tripListSheet
                .presentationDetents([.medium, .large])
        }
        // v1.49：离线地图引导（iOS 17+ 系统离线地图）
        .alert("离线地图（系统）", isPresented: $showOfflineMapHint) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("iOS 17 及以上可在系统「设置 → 地图 → 离线地图 → 下载新地图」选择合肥下载。下载后本 App 在无网络时也能显示地图与导航底图（实时路况/在线搜索仍需网络）。")
        }
        .confirmationDialog("选择违法拍照类型", isPresented: $showTypePicker) {
            ForEach(PoiType.allCases.filter(\.isCamera), id: \.self) { t in
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
            Button(model.isFavorite(p) ? "取消收藏" : "收藏点位") {
                model.toggleFavorite(p)
                model.status = model.isFavorite(p) ? "已收藏：\(p.name)" : "已取消收藏：\(p.name)"
            }
            Button("编辑该点位") { editPoi = p }
            if p.isCustom {
                Button("删除该点位", role: .destructive) {
                    model.deletePoi(id: p.id)
                    model.status = "已删除：\(p.name)"
                }
            } else {
                Button("内置点位，长按图标可拖动自定义位置", systemImage: "info.circle") {}
                    .disabled(true)
            }
            Button("取消", role: .cancel) {}
        } message: { p in
            Text(String(format: "%@ · %@\n纬度 %.5f 经度 %.5f", p.name, p.type.label, p.lat, p.lon))
        }
        // v1.49：导航深色常亮（高德导航夜间效果），主界面跟随系统深浅色
        .preferredColorScheme(model.navigating ? .dark : nil)
        .onAppear {
            model.authorizeAndStart()
            model.fetchPlaceLabels()
            model.checkClipboard()
            // v1.49：首页定时刷新实时路况（60 秒）
            startTrafficTimer()
            // v1.50：热门/常搜地点标注刷新
            model.hotTick += 1
        }
        // v1.50：搜索历史变化 → 刷新常搜地点高亮
        .onReceive(model.$searchHistory) { _ in
            model.hotTick += 1
        }
        // 切回前台时再检查剪贴板（微信复制位置 → 打开摩卫士自动识别）
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                model.checkClipboard()
            }
        }
        // 导航中保持屏幕常亮（骑行看导航不被锁屏；退出导航恢复）
        .onChange(of: model.navigating) { nav in
            UIApplication.shared.isIdleTimerDisabled = nav
        }
        // 行程总结（到达/退出导航时弹出，高德式行程卡）
        .alert("本次行程", isPresented: Binding(
            get: { model.tripSummary != nil },
            set: { if !$0 { model.tripSummary = nil } }
        )) {
            Button("好", role: .cancel) { model.tripSummary = nil }
        } message: {
            if let s = model.tripSummary {
                Text("目的地：\(s.destName)\n"
                    + "里程：\(String(format: "%.1f", Double(s.distanceM) / 1000.0)) 公里\n"
                    + "用时：\(s.durationS / 60) 分钟 \(s.durationS % 60) 秒\n"
                    + "沿途抓拍点位：\(s.snapCount) 处")
            }
        }
        // 预览点变化（含在线搜索兜底）→ 同步"导航去此处"按钮
        .onChange(of: model.searchPreview) { p in
            if let p = p {
                goHereLabel = "导航去此处"
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
            choiceRoutes: model.routeChoices.map(\.points),
            selectedRouteIdx: model.selectedRouteIdx,
            routePois: model.routePois,
            locateTick: model.locateTick,
            fitTick: model.fitTick,
            heading: model.heading,
            preview: model.searchPreview,
            gasStations: model.gasStations,
            gasTick: model.gasTick,
            placeLabels: model.placeLabels,
            categoryResults: model.categoryResults,
            categoryTick: model.categoryTick,
            navigateFollowTick: model.navigateFollowTick,
            navigating: model.navigating,
            zoomInTick: model.zoomInTick,
            zoomOutTick: model.zoomOutTick,
            onLongPress: { coord in
                longPressCoord = coord
                showLongPressMenu = true
            },
            onPoiLongPress: { p in
                poiManagePoi = p
            },
            onPoiMoved: { p, nLat, nLon in
                model.updatePoi(id: p.id, type: p.type, name: p.name, lat: nLat, lon: nLon, radiusM: p.radiusM)
                model.status = "已移动「\(p.name)」到新位置（橙色=自定义点位）"
            },
            onPoiSelect: { p in
                haptic()
                poiDetail = p
            },
            onPlaceSelect: { pl in
                haptic()
                // v1.47：点击地图小区/商业标注 → 弹「搜周边」卡片（高德周边搜索）
                aroundPlace = pl
                aroundKeyword = "加油站"
                aroundPois = []
                showAround = true
                Task { await loadAround(pl, kw: "加油站") }
            },
            onCategorySelect: { r in
                model.planRoute(to: r.name, lat: r.lat, lon: r.lon)
                model.clearCategory()
            },
            onMapTap: { coord in
                // 轻点地图空白：该位置下方显示"导航到这里"（目的地名用附近地标，避免"地图选点"）
                let n = placeNameNear(coord)
                goHereLabel = "导航去此处"
                goHereName = n
                goHereLat = coord.latitude
                goHereLon = coord.longitude
                model.setPreview(n, lat: coord.latitude, lon: coord.longitude)
            },
            // v1.49：图层切换 / 实时路况 / 历史轨迹回放
            mapType: mapType,
            trafficRoads: model.trafficRoads,
            // v1.54：实时路况开关
            showTraffic: showTraffic,
            tripTrackLine: shownTripPoints,
            // v1.50：定位连接线 / 导航全程概览 / 热门与常搜地点
            locLinkLine: locLinkLine,
            navOverviewTick: model.navOverviewTick,
            hotPlaces: model.hotPlaces,
            recentHot: model.recentHot,
            hotTick: model.hotTick,
            onHotPlaceSelect: { pl in
                haptic()
                model.setPreview(pl.name, lat: pl.lat, lon: pl.lon)
                model.planRoute(to: pl.name, lat: pl.lat, lon: pl.lon)
            },
            // v1.51：高德瓦片底图（A 选项）
            useAmapTiles: useAmapTiles,
            // v1.56：极简模式（隐藏道路标注）
            minimal: minimalMap
        )
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { dismissKeyboard() }
    }

    /// 天气条：屏幕最上边居中一行（与左上角指南针分离不重复；导航中隐藏，高德导航顶部只留导航信息）
    private var weatherOverlay: some View {
        VStack {
            HStack {
                Spacer()
                if let w = model.weatherText {
                    HStack(spacing: 6) {
                        // 当前天气：图标+温度加粗，降水/风为小字
                        Text(w)
                            .font(.footnote.bold())
                            .foregroundStyle(.primary)
                        if let t = model.tomorrowText {
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            // 明日：小字次要色
                            Text(t)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                }
                Spacer()
            }
            // v1.47：当前位置道路名（高德逆地理，"沿XX路"高德式显示）
            if !model.currentRoad.isEmpty {
                Text("沿\(model.currentRoad)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            Spacer()
        }
    }

    /// 右上角 ⋯ 菜单（导入/导出点位数据）
    private var menuOverlay: some View {
        VStack {
            HStack {
                Spacer()
                Menu {
                    Button("导入 JSON") { showImport = true }
                    Button("导出 JSON") { exportDoc = JsonFile(text: model.exportPois()); showExport = true }
                    // v1.49：摩托车模式开关（禁摩前置提醒）
                    Toggle(isOn: Binding(
                        get: { model.motoMode },
                        set: { model.motoMode = $0 }
                    )) {
                        Label("摩托车模式（禁摩提醒）", systemImage: "motorcycle.fill")
                    }
                    // v1.49：超速提醒阈值
                    Menu {
                        ForEach([60, 70, 80, 100], id: \.self) { v in
                            Button(model.speedLimit == v ? "\(v) km/h ✓" : "\(v) km/h") {
                                model.speedLimit = v
                                model.status = "超速提醒阈值设为 \(v) km/h"
                            }
                        }
                        Button(model.speedLimit == 0 ? "关闭 ✓" : "关闭") {
                            model.speedLimit = 0
                            model.status = "超速提醒已关闭"
                        }
                    } label: {
                        Label("超速提醒：\(model.speedLimit == 0 ? "关" : "\(model.speedLimit) km/h")", systemImage: "speedometer")
                    }
                    // v1.52：语音播报引擎（高德式音色设置，讯飞在线 TTS）
                    Button {
                        showVoiceSettings = true
                    } label: {
                        Label("语音播报：\(model.xfEnabled ? model.xfVcnName : "系统语音")",
                              systemImage: "speaker.wave.2.fill")
                    }
                    // v1.49：图层切换（标准/卫星）
                    Button(mapType == .standard ? "图层：标准（当前）" : "图层：标准") {
                        mapType = .standard
                    }
                    Button(mapType == .satelliteFlyover || mapType == .satellite ? "图层：卫星（当前）" : "图层：卫星") {
                        mapType = .satelliteFlyover
                    }
                    // v1.51：底图数据源（高德瓦片=与高德路线同源，A 选项）
                    Toggle(isOn: $useAmapTiles) {
                        Label("底图：高德瓦片（贴合路线）", systemImage: "map.fill")
                    }
                    // v1.49：骑行轨迹
                    Button("骑行轨迹（\(model.tripTracks.count)条）") { showTripList = true }
                    // v1.49：离线地图引导
                    Button("离线地图（系统）") { showOfflineMapHint = true }
                    Button(model.amapKey.isEmpty ? "高德搜索Key（可选，填了联想更准）" : "高德搜索Key（已启用）") {
                        amapKeyInput = model.amapKey
                        showAmapKeyInput = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title2)
                        .foregroundStyle(.primary)
                }
                .padding(8)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1))
                .padding(.trailing, 12)
                .padding(.top, 40)
            }
            Spacer()
        }
    }

    /// 规划态顶部路线胶囊：显示"我的位置 → 目的地"，点击重新搜索（高德规划态顶部搜索框）
    private var routeBarOverlay: some View {
        VStack {
            HStack {
                Spacer()
                if !model.navigating, !model.routeChoices.isEmpty {
                    Button {
                        haptic()
                        // v1.49：规划态点击顶部胶囊 → 独立搜索 sheet（主页面不再出现搜索框）
                        showSearchSheet = true
                        searchFocused = true
                    } label: {
                        HStack(spacing: 6) {
                            Text("我的位置")
                                .font(.caption)
                                .foregroundStyle(.primary)
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(model.destName)
                                .font(.caption.bold())
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Image(systemName: "magnifyingglass")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.4), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 40)
                }
                Spacer()
            }
            Spacer()
        }
    }

    /// 底部浮层：类别结果 + 历史 + 导航信息卡 + 去这里 + 搜索框/退出导航 + 清空路线
    private var bottomOverlay: some View {
        VStack(spacing: 0) {
            Spacer()
            if !model.navigating {
                // 导航中自动隐藏多余 UI（高德式）：仅保留导航卡/抓拍条/悬浮退出
                categoryBar
                routeChoiceList
                goHereBar
                // v1.49：搜索框只在首页出现（无路线规划时）；规划态/导航态主页面无搜索框
                if model.routeChoices.isEmpty {
                    searchBar
                }
            } else {
                // v1.48：接近转向（<200米）只显示路口放大图，避免与下一转向卡重复
                turnAheadCard
                if !turnAheadVisible() {
                    navInfoCard
                }
                snapAlertCard
            }
        }
    }

    /// 高德式导航信息卡：下一转向（大图标+距离+路名+车道）+ 实时速度
    /// （剩余里程/时间已移到顶部大数字条 navTopBar）
    private var navInfoCard: some View {
        Group {
            if let ns = model.navigationStatus(at: model.currentLocation), ns.remainM > 0 {
                HStack(spacing: 12) {
                    // 左：下一转向（大图标 + 大字路名，高德导航主视觉）
                    VStack(alignment: .leading, spacing: 4) {
                        if let t = ns.nextTurn {
                            HStack(spacing: 8) {
                                Image(systemName: navTurnIcon(t.modifier))
                                    .font(.system(size: 34, weight: .bold))
                                    .foregroundStyle(.white)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("前方\(navDist(ns.distToTurnM))\(navTurnText(t))")
                                        .font(.title3.bold())
                                        .foregroundStyle(.white)
                                    if !t.roadName.isEmpty {
                                        Text(t.roadName)
                                            .font(.subheadline.bold())
                                            .foregroundStyle(.white.opacity(0.92))
                                    }
                                }
                            }
                            // 车道指引（高德导航侧边车道箭头）
                            if !t.lanes.isEmpty {
                                HStack(spacing: 3) {
                                    ForEach(t.lanes, id: \.self) { lane in
                                        Image(systemName: navLaneIcon(lane))
                                            .font(.footnote.bold())
                                            .foregroundStyle(.white.opacity(0.9))
                                    }
                                }
                            }
                        } else {
                            // v1.48：无下一转向时显示当前道路（高德式"沿XX路直行"）
                            Text(model.currentRoad.isEmpty ? "沿当前道路直行" : "沿\(model.currentRoad)直行")
                                .font(.title3.bold())
                                .foregroundStyle(.white)
                        }
                    }
                    Spacer()
                    // 右：实时速度
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(Int(ns.speedKph))")
                            .font(.system(size: 34, weight: .heavy))
                            .foregroundStyle(.white)
                        Text("km/h")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .padding(.bottom, 4)
                // v1.49：前方 3km 内加油站/充电桩轻提示（导航卡下小字）
                if !model.nearStationText.isEmpty {
                    Text(model.nearStationText)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.35), in: Capsule())
                        .padding(.bottom, 4)
                }
            }
        }
    }

    /// 导航中是否显示路口放大图（接近下一转向 <200米，v1.48 与下一转向卡去重）
    private func turnAheadVisible() -> Bool {
        guard let ns = model.navigationStatus(at: model.currentLocation),
              let t = ns.nextTurn, ns.distToTurnM < 200
        else { return false }
        return true
    }

    /// 高德式路口放大示意图：接近下一转向（<200米）时显示交叉路口 + 转弯箭头 + 路名
    private var turnAheadCard: some View {
        Group {
            if turnAheadVisible(),
               let ns = model.navigationStatus(at: model.currentLocation),
               let t = ns.nextTurn {
                ZStack {
                    // 当前道路（垂直）
                    Rectangle().fill(.white.opacity(0.92))
                        .frame(width: 12, height: 110)
                    // 目标道路（水平）
                    Rectangle().fill(.white.opacity(0.92))
                        .frame(width: 110, height: 12)
                    // 转弯箭头
                    Image(systemName: navTurnIcon(t.modifier))
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(Color(red: 0.25, green: 0.72, blue: 1.0))
                    // 路名标签
                    if !t.roadName.isEmpty {
                        Text(t.roadName)
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                            .offset(y: 54)
                    }
                }
                .frame(width: 110, height: 110)
                .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .padding(.bottom, 4)
            }
        }
    }

    /// 导航中抓拍预警条（最近路线点位 + 类型图标 + 距离）
    private var snapAlertCard: some View {
        Group {
            if !model.routePois.isEmpty, let loc = model.currentLocation {
                let nearest = model.routePois.min {
                    model.distance(to: $0, from: loc) < model.distance(to: $1, from: loc)
                }
                if let n = nearest {
                    let d = model.distance(to: n, from: loc)
                    if d < 900 {
                        HStack(spacing: 6) {
                            Image(systemName: n.type == .RED_LIGHT ? "stopwatch" : "camera")
                                .font(.footnote.bold())
                                .foregroundStyle(.yellow)
                            Text("前方\(Int(d))米 \(n.type.voicePrefix) · \(n.name)")
                                .font(.footnote.bold())
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(red: 0.9, green: 0.3, blue: 0.2).opacity(0.85),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal)
                        .padding(.bottom, 6)
                    }
                }
            }
        }
    }

    /// 车道箭头图标（lane indication）
    private func navLaneIcon(_ lane: String) -> String {
        switch lane {
        case "left": return "arrow.left"
        case "slight left": return "arrow.up.left"
        case "sharp left": return "arrow.left"
        case "right": return "arrow.right"
        case "slight right": return "arrow.up.right"
        case "sharp right": return "arrow.right"
        case "uturn": return "arrow.uturn.backward"
        case "straight": return "arrow.up"
        case "none": return "minus"
        default: return "arrow.up"
        }
    }

    /// 转向图标（SF Symbols）
    private func navTurnIcon(_ modifier: String) -> String {
        switch modifier {
        case "left": return "arrow.turn.up.left"
        case "right": return "arrow.turn.up.right"
        case "slight left": return "arrow.up.left"
        case "slight right": return "arrow.up.right"
        case "sharp left": return "arrow.turn.up.left"
        case "sharp right": return "arrow.turn.up.right"
        case "uturn": return "arrow.uturn.up.left"
        default: return "arrow.up"
        }
    }

    private func navTurnText(_ t: RouteTurn) -> String {
        switch t.modifier {
        case "left": return "左转"
        case "right": return "右转"
        case "slight left": return "稍向左"
        case "slight right": return "稍向右"
        case "sharp left": return "急左转"
        case "sharp right": return "急右转"
        case "uturn": return "掉头"
        default: return "继续"
        }
    }

    private func navDist(_ m: Int) -> String {
        m >= 1000 ? String(format: "%.1f公里", Double(m) / 1000.0) : "\(m)米"
    }

    /// 类别搜索结果横条（学校/医院/加油站，点击直接规划路线）
    private var categoryBar: some View {
        Group {
            if !model.categoryResults.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.categoryResults) { r in
                            Button {
                                model.planRoute(to: r.name, lat: r.lat, lon: r.lon)
                                model.clearCategory()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(displayName(r.name))
                                        .font(.footnote)
                                        .bold()
                                        .lineLimit(1)
                                    Text("\(model.categoryDistance(r)) · 导航")
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.85))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// 搜索预览"去这里" / 方案就绪后"开始导航"按钮（绿色，高德式）
    private var goHereBar: some View {
        Group {
            if !model.routeChoices.isEmpty {
                // 方案已选 → 高德式底部：路线详情 + 绿色"开始导航"
                HStack(spacing: 8) {
                    Button {
                        haptic()
                        showRouteDetail = true
                    } label: {
                        Text("路线详情")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    Button {
                        haptic()
                        model.toggleNavigation()
                    } label: {
                        Text("开始导航")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.green, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
                .padding(.bottom, 4)
            } else if model.isPlanning || goHereName != nil || (goHereLat != 0 && goHereLon != 0) {
                Button {
                    haptic()
                    showSearchField = false
                    model.fetchRouteChoices(to: goHereName ?? "地图选点", lat: goHereLat, lon: goHereLon)
                    goHereName = nil
                    goHereLat = 0
                    goHereLon = 0
                    model.clearPreview()
                } label: {
                    HStack(spacing: 6) {
                        if model.isPlanning {
                            ProgressView().tint(.white)
                            Text("规划路线中…")
                        } else {
                            Text(goHereLabel)
                        }
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.green, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal)
                }
                .disabled(model.isPlanning)
                .padding(.bottom, 4)
            }
        }
    }

    /// 高德式多路线方案：顶部"我的位置→目的地"，下方横排方案卡（大分钟+里程·抓拍+标签）
    private var routeChoiceList: some View {
        Group {
            if !model.routeChoices.isEmpty {
                VStack(spacing: 6) {
                    routeChoiceHeader
                    routeChoiceCards
                }
                .padding(.horizontal)
                .padding(.bottom, 4)
            }
        }
    }

    /// 规划头部（高德式：出发地 → 目的地 + 出行方式 Tab：摩托/驾车）
    private var routeChoiceHeader: some View {
        VStack(spacing: 7) {
            HStack {
                Text("我的位置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(model.destName)
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 4)
            // v1.56 高德式出行方式 Tab（切换后按当前目的地重新规划）
            HStack(spacing: 8) {
                modeTab(icon: "car.fill", name: "驾车", on: !model.motoMode) {
                    if model.motoMode {
                        model.motoMode = false
                        model.replanCurrent()
                    }
                }
                modeTab(icon: "motorcycle.fill", name: "摩托", on: model.motoMode) {
                    if !model.motoMode {
                        model.motoMode = true
                        model.replanCurrent()
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 4)
        }
    }

    /// 出行方式 Tab 小块（高德式选中蓝底）
    private func modeTab(icon: String, name: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            haptic()
            action()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption.bold())
                Text(name).font(.caption.bold())
            }
            .foregroundStyle(on ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(on ? Color(red: 0.16, green: 0.38, blue: 1.0) : Color(.systemBackground), in: Capsule())
            .overlay(Capsule().stroke(on ? Color.clear : Color(.systemGray4), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }

    /// 横排方案卡（高德式并列）
    private var routeChoiceCards: some View {
        HStack(spacing: 8) {
            ForEach(Array(model.routeChoices.enumerated()), id: \.offset) { idx, c in
                Button {
                    haptic()
                    model.selectedRouteIdx = idx
                    model.applyRouteChoice(c)
                } label: {
                    routeChoiceCard(c, selected: model.selectedRouteIdx == idx)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 单张高德式方案卡：大分钟 + 里程·抓拍 + 标签，选中蓝框高亮
    private func routeChoiceCard(_ c: RouteChoice, selected: Bool) -> some View {
        let sel = selected
        let distTxt = c.distanceM < 1000
            ? "\(c.distanceM)米"
            : String(format: "%.1f公里", Double(c.distanceM) / 1000.0)
        return VStack(alignment: .leading, spacing: 3) {
            Text(c.durationS < 60 ? "1分钟内" : "\(c.durationS / 60) 分钟")
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(.primary)
            Text("\(distTxt) · 抓拍\(c.poiCount)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(c.label)
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(red: 0.16, green: 0.38, blue: 1.0), in: Capsule())
            // v1.56 高德式路况色进度条（绿通畅/黄缓行/红拥堵分段示意）
            HStack(spacing: 2) {
                Rectangle().fill(Color.green.opacity(0.85)).frame(maxWidth: .infinity)
                Rectangle().fill(Color.yellow.opacity(0.9)).frame(width: 26)
                Rectangle().fill(Color.red.opacity(0.85)).frame(width: 12)
            }
            .frame(height: 4)
            .clipShape(Capsule())
            .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(sel ? AnyShapeStyle(Color(red: 0.16, green: 0.38, blue: 1.0).opacity(0.15)) : AnyShapeStyle(.ultraThinMaterial), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(
            sel ? Color(red: 0.16, green: 0.38, blue: 1.0) : .white.opacity(0.3),
            lineWidth: sel ? 2 : 0.8))
    }

    /// 地图缩放 + / - 按钮（右下角，高德式；定位按钮在放大按钮上方）
    /// v1.54 高德式右侧竖排控制钮：图层 / 实时路况 / 语音播报（常用功能直给，替代全塞 ⋯ 菜单）
    private var mapControlsOverlay: some View {
        VStack {
            Spacer()
            if !model.navigating {
                VStack(spacing: 14) {
                    // 图层切换（标准 ↔ 卫星）
                    Button {
                        haptic()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            mapType = (mapType == .satelliteFlyover || mapType == .satellite) ? .standard : .satelliteFlyover
                        }
                    } label: {
                        Image(systemName: mapType == .standard ? "globe.americas" : "map.fill")
                            .font(.body)
                            .foregroundStyle(.primary)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: 1))
                            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                    // 实时路况开关
                    Button {
                        haptic()
                        showTraffic.toggle()
                        model.status = showTraffic ? "实时路况已开启" : "实时路况已关闭"
                    } label: {
                        Image(systemName: "water.waves")
                            .font(.body)
                            .foregroundStyle(showTraffic ? Color.blue : .secondary)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(showTraffic ? Color.blue.opacity(0.7) : .white.opacity(0.45), lineWidth: 1))
                            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                    // 语音播报设置（讯飞音色）
                    Button {
                        haptic()
                        showVoiceSettings = true
                    } label: {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.body)
                            .foregroundStyle(model.xfEnabled ? Color.orange : .secondary)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(model.xfEnabled ? Color.orange.opacity(0.6) : .white.opacity(0.45), lineWidth: 1))
                            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.trailing, 8)
                .padding(.bottom, 220)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var zoomOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 6) {
                    // 当前定位按钮（放大按钮上方，非导航中显示；点击清空路线规划回到主页）
                    if !model.navigating {
                        Button {
                            haptic()
                            goHereName = nil
                            goHereLat = 0
                            goHereLon = 0
                            model.clearPreview()
                            model.clearRoute()
                            model.centerOnUser()
                        } label: {
                            ZStack {
                                Circle().fill(.white)
                                Circle().strokeBorder(.black.opacity(0.08), lineWidth: 1)
                                Image(systemName: "scope")
                                    .font(.title3)
                                    .foregroundStyle(Color(red: 0.16, green: 0.38, blue: 1.0))
                            }
                            .frame(width: 44, height: 44)
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                        }
                    }
                    Button {
                        haptic()
                        model.zoomInTick += 1
                    } label: {
                        Image(systemName: "plus")
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .background(Color.white, in: Circle())
                            .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 1))
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                    }
                    Button {
                        haptic()
                        model.zoomOutTick += 1
                    } label: {
                        Image(systemName: "minus")
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .background(Color.white, in: Circle())
                            .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 1))
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                    }
                }
                .padding(.trailing, 18)
                .padding(.bottom, 150)
            }
        }
    }

    /// 高德式顶部导航条：剩余里程 + 时间 + 下一转向预告（<500米显示，高德顶部主条样式）
    private var navTopBar: some View {
        VStack {
            if model.navigating, let ns = model.navigationStatus(at: model.currentLocation), ns.remainM > 0 {
                VStack(spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.1f", Double(max(ns.remainM, 0)) / 1000.0))
                            .font(.system(size: 34, weight: .heavy))
                            .foregroundStyle(.white)
                        Text("公里")
                            .font(.caption.bold())
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        Text("\(max(ns.remainS, 0) / 60) 分钟")
                            .font(.system(size: 26, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                    // 下一转向预告（高德顶部主条：接近转向时显示"前方X米右转 进入XX路"）
                    if let t = ns.nextTurn, ns.distToTurnM < 900, ns.distToTurnM > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: navTurnIcon(t.modifier))
                                .font(.subheadline.bold())
                            Text("前方\(navDist(ns.distToTurnM))\(navTurnText(t))")
                                .font(.subheadline.bold())
                            if !t.roadName.isEmpty {
                                Text("进入 \(t.roadName)")
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.92))
                                    .lineLimit(1)
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else if !model.currentRoad.isEmpty {
                        // v1.48：无转向预告时显示当前道路（实时道路播报文字）
                        Text("沿\(model.currentRoad) 直行")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white.opacity(0.95))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .padding(.top, 52)
            }
            Spacer()
        }
    }

    /// v1.56 导航中左侧竖排（高德式：刷新 / 极简）
    private var navLeftOverlay: some View {
        VStack {
            Spacer()
            if model.navigating {
                VStack(spacing: 12) {
                    // 刷新（按当前位置+目的地重新规划）
                    Button {
                        haptic()
                        model.replanCurrent()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.body)
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: 1))
                            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                    // 极简（隐藏道路标注）
                    Button {
                        haptic()
                        minimalMap.toggle()
                        model.status = minimalMap ? "极简模式：已隐藏道路标注" : "已恢复道路标注"
                    } label: {
                        Image(systemName: minimalMap ? "viewfinder.circle.fill" : "viewfinder.circle")
                            .font(.body)
                            .foregroundStyle(minimalMap ? Color.blue : .white)
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: 1))
                            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 8)
                .padding(.bottom, 170)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(model.navigating)
    }

    /// 导航中悬浮右上角：语音播报开关 + 退出导航（v1.48 新增高德式静音按钮）
    private var exitNavOverlay: some View {        VStack {
            HStack(spacing: 8) {
                Spacer()
                if model.navigating {
                    // 语音播报开关（高德导航标配）
                    Button {
                        haptic()
                        model.toggleVoice()
                    } label: {
                        Image(systemName: model.voiceMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.footnote.bold())
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(model.voiceMuted ? Color.gray.opacity(0.75) : Color.black.opacity(0.55),
                                        in: Circle())
                            .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                    }
                    Button {
                        haptic()
                        model.toggleNavigation()
                    } label: {
                        Text("退出导航")
                            .font(.footnote.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.red, in: Capsule())
                            .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                    }
                }
            }
            .padding(.trailing, 12)
            .padding(.top, 8)
            Spacer()
        }
    }

    /// 触感反馈（iOS Haptic）
    private func haptic() {
        let g = UIImpactFeedbackGenerator(style: .medium)
        g.impactOccurred()
    }

    /// 分享点位（motonav:// 深链，供好友点击直达）
    private func sharePoi(_ p: Poi) {
        let link = "motonav://\(p.name)@\(p.lat),\(p.lon)"
        let text = "摩卫士违法拍照点位：\(p.name)（\(p.type.label)）\n坐标 \(String(format: "%.5f,%.5f", p.lat, p.lon))\n打开链接直接导航：\(link)"
        let avc = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            root.present(avc, animated: true)
        }
    }

    /// 左上角指南针：圆盘四方位（东南西北）+ 红色指针指示正北（液态玻璃）
    private var compassOverlay: some View {
        VStack {
            HStack {
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1.5)
                    // 红色指北针（随手机朝向旋转）
                    Image(systemName: "location.north.fill")
                        .font(.title3)
                        .foregroundStyle(.red)
                        .rotationEffect(.degrees(model.heading))
                    // 四方位：北（上）东（右）南（下）西（左）
                    Text("北")
                        .font(.caption2.bold())
                        .foregroundStyle(.red)
                        .offset(y: -20)
                    Text("东")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                        .offset(x: 19)
                    Text("南")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                        .offset(y: 20)
                    Text("西")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                        .offset(x: -19)
                }
                .frame(width: 56, height: 56)
                .padding(.leading, 12)
                .padding(.top, 40)
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

    /// 目的地搜索框（高德式：最近常搜置顶 + 白色胶囊输入行 + 推荐/联想；导航时被退出按钮替代）
    private var searchBar: some View {
        VStack(spacing: 6) {
            // v1.53 最近常搜置顶（最多 3 个，可展开更多；高德"最近搜索"胶囊）
            if !model.recentHot.isEmpty {
                recentChips
            }
            searchInputRow
            // v1.52 搜索推荐：未输入 → 高德式搜索面板（分类宫格/常用/历史）；输入 → 高德 POI 联想
            if showSuggestions {
                if !onlineTips.isEmpty {
                    onlineTipsList
                } else if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    searchPanel
                }
            }
        }
    }

    /// v1.53 最近常搜置顶胶囊（最多 3 个，点"更多"展开；点标签直接定位）
    private var recentChips: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath").font(.caption2).foregroundStyle(.orange)
                Text("最近常搜").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.recentHot.count > 3 {
                    Button {
                        showAllRecent.toggle()
                    } label: {
                        Text(showAllRecent ? "收起" : "更多 \(model.recentHot.count) 个")
                            .font(.caption).foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    model.clearHistory()
                    model.status = "最近常搜已清空"
                } label: {
                    Text("清空").font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // v1.53-fix：用 offset 作 id 双保险，杜绝同名地点 ID 冲突闪退
                    ForEach(Array(model.recentHot.prefix(showAllRecent ? 12 : 3).enumerated()), id: \.offset) { _, pl in
                        Button {
                            tapRecent(pl)
                        } label: {
                            Text(displayName(pl.name))
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Color(.systemBackground), in: Capsule())
                                .overlay(Capsule().stroke(Color(.systemGray4), lineWidth: 0.6))
                                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 2)
            }
        }
    }

    /// 点最近常搜标签 → 直接定位（与推荐行同一交互）
    private func tapRecent(_ pl: PlaceLabel) {
        searchFocused = false
        showSuggestions = false
        dismissKeyboard()
        showSearchSheet = false
        model.setPreview(pl.name, lat: pl.lat, lon: pl.lon)
        goHereLabel = "导航去此处"
        goHereName = pl.name
        goHereLat = pl.lat
        goHereLon = pl.lon
        model.addHistory(pl.name)
        model.fitTick += 1
        model.status = "已定位到「\(pl.name)」，点「导航去此处」规划路线"
    }

    /// v1.55 高德式搜索面板（点击搜索框未输入时显示）：分类宫格 + 常用入口 + 历史记录 + 隐私开关
    private var searchPanel: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // 分类快捷宫格（高德式 4×2）
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(panelCategories, id: \.kind) { c in
                        Button {
                            haptic()
                            searchFocused = false
                            showSuggestions = false
                            dismissKeyboard()
                            model.fetchNearby(kind: c.kind, tag: c.tag, pattern: c.pattern)
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: c.icon)
                                    .font(.title3)
                                    .foregroundStyle(Color(red: 0.16, green: 0.38, blue: 1.0))
                                Text(c.kind).font(.caption).foregroundStyle(.primary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                // 常用入口（高德式：家/公司/收藏夹/常去前2）
                HStack(spacing: 8) {
                    panelQuick(icon: "house.fill", name: "家") { goHomeWork(home: true) }
                    panelQuick(icon: "briefcase.fill", name: "公司") { goHomeWork(home: false) }
                    panelQuick(icon: "star.fill", name: "收藏夹") { showFavSheet = true }
                    ForEach(Array(model.recentHot.prefix(2).enumerated()), id: \.offset) { _, pl in
                        panelQuick(icon: "clock.fill", name: displayName(pl.name)) { tapRecent(pl) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                // 历史记录标题 + 清空
                HStack {
                    Text("历史记录").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.clearHistory()
                        model.status = "历史记录已清空"
                    } label: {
                        Text("清空").font(.caption).foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 2)
                if model.searchHistory.isEmpty {
                    Text("暂无历史记录，搜索目的地或点击上方分类即可开始")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                } else {
                    ForEach(model.searchHistory, id: \.self) { name in
                        historyRow(name)
                    }
                }
                // 底部隐私开关（高德式右下角）
                HStack(spacing: 8) {
                    Image(systemName: model.privateMode ? "eye.slash.fill" : "eye.fill")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("常搜自动记录").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("", isOn: $model.privateMode)
                        .labelsHidden()
                        .scaleEffect(0.8)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .frame(maxHeight: 560)
        .background(.bar)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
        .padding(.horizontal)
    }

    /// 分类宫格配置（icon / kind / OSM tag / pattern）
    private var panelCategories: [(icon: String, kind: String, tag: String, pattern: String)] {
        [
            ("fork.knife", "美食", "amenity", "restaurant|fast_food|cafe"),
            ("bed.double.fill", "酒店", "amenity", "hotel|hostel|guest_house"),
            ("camera.fill", "景点", "tourism", "attraction|museum|zoo"),
            ("fuelpump.fill", "加油站", "amenity", "fuel"),
            ("bolt.fill", "充电站", "amenity", "charging_station"),
            ("cart.fill", "超市", "shop", "supermarket|convenience|mall"),
            ("cross.case.fill", "医院", "amenity", "hospital|clinic|doctors"),
            ("graduationcap.fill", "学校", "amenity", "school|kindergarten|college|university"),
        ]
    }

    /// 常用入口小块（高德式竖排图标卡）
    private func panelQuick(icon: String, name: String, action: @escaping () -> Void) -> some View {
        Button {
            haptic()
            action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.subheadline).foregroundStyle(Color(red: 0.16, green: 0.38, blue: 1.0))
                Text(name).font(.caption2).lineLimit(1).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        }
        .buttonStyle(.plain)
    }

    /// 历史记录行：名称 + "路线"直达按钮 + 删除（高德截图同款）
    private func historyRow(_ name: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    searchText = name
                    showSuggestions = false
                    dismissKeyboard()
                    doSearch()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(displayName(name)).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                            Text("合肥 · 最近搜索").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                // 路线直达（高德式右侧按钮）
                Button {
                    if let pl = model.placeByName(name) {
                        tapRecent(pl)
                    } else {
                        searchText = name
                        showSuggestions = false
                        dismissKeyboard()
                        doSearch()
                    }
                } label: {
                    Text("路线")
                        .font(.caption.bold())
                        .foregroundStyle(Color(red: 0.16, green: 0.38, blue: 1.0))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.blue.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                Button {
                    model.removeHistory(name)
                } label: {
                    Image(systemName: "trash").font(.caption).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            Divider()
        }
    }

    /// 家/公司快捷入口
    private func goHomeWork(home: Bool) {
        let sp = home ? model.homePlace : model.workPlace
        if let s = sp {
            searchFocused = false
            showSuggestions = false
            dismissKeyboard()
            model.planRoute(to: s.name, lat: s.lat, lon: s.lon)
        } else {
            model.status = home ? "尚未设置「家」：长按地图点位 → 设为家" : "尚未设置「公司」：长按地图点位 → 设为公司"
        }
    }

    /// 推荐/热门地点行（点击直接定位跳转，与高德联想同一交互；onDelete 非空显示删除按钮）
    private func row(icon: String, color: Color, name: String, sub: String, place: PlaceLabel, onDelete: (() -> Void)? = nil) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    searchFocused = false
                    showSuggestions = false
                    dismissKeyboard()
                    showSearchSheet = false
                    model.setPreview(place.name, lat: place.lat, lon: place.lon)
                    goHereLabel = "导航去此处"
                    goHereName = place.name
                    goHereLat = place.lat
                    goHereLon = place.lon
                    model.addHistory(place.name)
                    model.fitTick += 1
                    model.status = "已定位到「\(place.name)」，点「导航去此处」规划路线"
                } label: {
                    HStack {
                        Image(systemName: icon).foregroundStyle(color)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                            Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right.circle").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let onDelete {
                    // v1.52：最近常搜单条删除（垃圾桶）
                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Divider()
        }
    }

    /// 搜索输入行：高德样式通栏圆角胶囊（放大镜 + 输入 + ✕ + 搜索按钮为一体）
    private var searchInputRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("搜索目的地", text: $searchText)
                .font(.subheadline)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { showSuggestions = false; dismissKeyboard(); doSearch() }
                .onChange(of: searchText) { newValue in
                    showSuggestions = true
                    onlineTips = []
                    let q = newValue.trimmingCharacters(in: .whitespaces)
                    guard !q.isEmpty else { return }
                    // v1.46：搜索联想只使用高德 Web「输入提示」，返回真实 POI 候选（带坐标，点击直接定位）
                    Task {
                        let tips = await model.amapInputTips(q)
                        if searchText == newValue {
                            // v1.52：高德联想空/失败 → 本地合肥地点库兜底（保证搜索框始终有推荐）
                            onlineTips = tips.isEmpty ? model.localFallbackTips(q) : tips
                        }
                    }
                }
                .onChange(of: searchFocused) { f in
                    // v1.52：点击搜索框即显示推荐地区（未输入时）
                    if f { showSuggestions = true }
                }
            // 一键清除输入内容（有内容时显示）
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    onlineTips = []
                    showSuggestions = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            // 搜索按钮（与输入框同一胶囊内，右侧）
            Button {
                showSuggestions = false
                dismissKeyboard()
                doSearch()
            } label: {
                Text("搜索")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(red: 0.16, green: 0.38, blue: 1.0), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .frame(height: searchHeight)
        // v1.53 高德同款搜索框：白色圆角胶囊 + 浅灰描边 + 柔和阴影（替代原深色半透明底）
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.systemGray4), lineWidth: 0.6))
        .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
        .padding(.horizontal)
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    var h = 54 + value.translation.height
                    h = min(max(h, 48), 170)
                    if abs(h - searchHeight) > 1 { searchHeight = h }
                }
        )
        .padding(.vertical, 6)
    }

    /// 高德联想候选列表（名称 + 地址副标题 + 定位图标；点击直接定位跳转，高德式搜索体验）
    private var onlineTipsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(onlineTips) { tip in
                    VStack(spacing: 0) {
                        Button {
                            searchFocused = false
                            showSuggestions = false
                            dismissKeyboard()
                            showSearchSheet = false
                            model.setPreview(tip.name, lat: tip.lat, lon: tip.lon)
                            goHereLabel = "导航去此处"
                            goHereName = tip.name
                            goHereLat = tip.lat
                            goHereLon = tip.lon
                            model.addHistory(tip.name)
                            model.fitTick += 1
                            model.status = "已定位到「\(tip.name)」，点「导航去此处」规划路线"
                        } label: {
                            HStack {
                                Image(systemName: "mappin.circle.fill")
                                    .foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(tip.name)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(tip.sub)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right.circle")
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
        .frame(maxHeight: 190)
        .background(.bar)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
        .padding(.horizontal)
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

    /// 地图选点命名：使用 800 米内最近的地图地标（小区/商铺），无则"地图选点"
    private func placeNameNear(_ coord: CLLocationCoordinate2D) -> String {
        let c = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        var best: PlaceLabel?
        var bestD = 800.0
        for pl in model.placeLabels {
            let d = c.distance(from: CLLocation(latitude: pl.lat, longitude: pl.lon))
            if d < bestD { bestD = d; best = pl }
        }
        return best?.name ?? "地图选点"
    }

    // MARK: - 点击地标搜周边（v1.47 高德周边搜索）

    private let aroundCategories = ["加油站", "充电桩", "餐饮", "酒店", "公共厕所", "药店", "修车", "全部"]

    private func loadAround(_ pl: PlaceLabel, kw: String) async {
        let result = await model.amapAround(lat: pl.lat, lon: pl.lon, keyword: kw)
        if aroundPlace?.id == pl.id {
            aroundPois = result
        }
    }

    /// v1.49：历史轨迹列表（骑行轨迹回放/删除）
    private var tripListSheet: some View {
        NavigationStack {
            List {
                if model.tripTracks.isEmpty {
                    Text("暂无骑行轨迹。完成一次导航后自动保存（最多 20 条）")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(model.tripTracks.enumerated()), id: \.offset) { idx, t in
                    Button {
                        model.shownTripIdx = idx
                        model.status = "正在回放：\(t.name)（\(t.date)）"
                        showTripList = false
                        model.fitTick += 1
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name).font(.subheadline.bold())
                                Text("\(t.date) · \(String(format: "%.1f", Double(t.distanceM) / 1000.0))公里 · \(t.durationS / 60)分钟")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.shownTripIdx == idx {
                                Image(systemName: "eye.fill").foregroundStyle(.green)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            model.deleteTripTrack(idx)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("骑行轨迹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showTripList = false }
                }
            }
        }
    }

    /// v1.49：当前回放轨迹的点（灰色虚线显示在地图）
    private var shownTripPoints: [CLLocationCoordinate2D] {
        let list = model.tripTracks
        guard model.shownTripIdx >= 0 && model.shownTripIdx < list.count else { return [] }
        return list[model.shownTripIdx].points
    }

    /// v1.50：定位连接线（定位点→路线投影点，导航中把车"贴"到路上，高德式步行导航线）
    private var locLinkLine: [CLLocationCoordinate2D] {
        guard model.navigating, let loc = model.currentLocation,
              let proj = model.projectedOntoRoute(loc) else { return [] }
        return [loc, proj]
    }

    /// v1.49：首页定时刷新实时路况（60 秒，以当前位置为中心；只启动一次）
    private func startTrafficTimer() {
        guard !trafficTimerStarted else { return }
        trafficTimerStarted = true
        let center = model.currentLocation
            ?? CLLocationCoordinate2D(latitude: 31.8206, longitude: 117.2272) // 合肥中心
        Task { await model.fetchTraffic(near: center, spanMeters: 8000) }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            let c = model.currentLocation
                ?? CLLocationCoordinate2D(latitude: 31.8206, longitude: 117.2272)
            Task { await model.fetchTraffic(near: c, spanMeters: 8000) }
        }
    }

    private func aroundSheet(_ pl: PlaceLabel) -> some View {        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pl.name)
                        .font(.headline)
                    Text("周边搜索 · 3公里内")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showAround = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 4)
            // 分类快捷筛选
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(aroundCategories, id: \.self) { c in
                        Button {
                            aroundKeyword = c
                            aroundPois = []
                            Task { await loadAround(pl, kw: c == "全部" ? "" : c) }
                        } label: {
                            Text(c)
                                .font(.footnote)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(c == aroundKeyword ? Color.green : Color(.secondarySystemBackground),
                                            in: Capsule())
                                .foregroundStyle(c == aroundKeyword ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            // 周边结果
            if aroundPois.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    Text("正在搜索周边…")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(aroundPois) { p in
                            VStack(spacing: 0) {
                                Button {
                                    showAround = false
                                    model.setPreview(p.name, lat: p.lat, lon: p.lon)
                                    goHereLabel = "导航去此处"
                                    goHereName = p.name
                                    goHereLat = p.lat
                                    goHereLon = p.lon
                                    model.addHistory(p.name)
                                    model.fitTick += 1
                                    model.status = "已定位到「\(p.name)」，点「导航去此处」规划路线"
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "mappin.circle.fill")
                                            .foregroundStyle(.green)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(p.name)
                                                .font(.subheadline)
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Text(p.distance > 0 ? "距地标 \(p.distance)m\(p.address.isEmpty ? "" : " · \(p.address)")" : p.address)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.up.right.circle")
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    /// v1.13：搜索学校/医院/加油站 → 附近10公里类别点位高亮+直接导航；
    /// 其他 → 绿色高亮等待"去这里"；找不到走在线模糊搜索
    private func doSearch(_ q: String? = nil) {
        let q = (q ?? searchText).trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { model.status = "请输入目的地"; return }
        // 类别搜索：学校/医院/加油站
        if model.categoryKeyword(q) != nil {
            model.clearCategory()
            showSuggestions = false
            model.fetchCategory(q)
            return
        }
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
            // 点击联想的地图内地点名称 → 直接跳转并显示绿色"导航去此处"（多命中优先完全同名）
            let p = hits.first(where: { $0.name == q }) ?? hits[0]
            model.selectedPoi = p
            model.setPreview(p.name, lat: p.lat, lon: p.lon)
            goHereLabel = "导航去此处"
            goHereName = p.name
            goHereLat = p.lat; goHereLon = p.lon
            model.status = "已定位到「\(displayName(p.name))」，点「导航去此处」规划路线"
            return
        }
        // 本地地标词典命中：离线直接出结果（殡仪馆/车站/机场/医院/公园等）
        if let lm = model.matchLandmark(q) {
            showSuggestions = false
            dismissKeyboard()
            model.addHistory(lm.name)
            model.setPreview(lm.name, lat: lm.lat, lon: lm.lon)
            goHereLabel = "去这里：\(displayName(lm.name))"
            goHereName = lm.name
            goHereLat = lm.lat; goHereLon = lm.lon
            model.status = "已定位「\(lm.name)」（坐标为估算），点「去这里」规划路线"
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

/// 点位详情气泡（高德式地点卡片）：名称/类型/距我/收藏/分享/导航/设为常用
/// v1.52 语音播报设置（高德式：音色列表 + 喇叭试听 + 选中勾）
struct VoiceSettingsSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private let testText = "前方 500 米右转，进入包公大道，请注意安全"
    private let voices: [(vcn: String, name: String, sub: String, icon: String)] = [
        ("xiaorong", "四川话女声 · 小蓉", "亲切川味，导航更有味道", "speaker.wave.3.fill"),
        ("yezi", "四川话女声 · 叶子", "清亮川腔，推荐", "speaker.wave.2.fill"),
        ("xiaoyan", "普通话女声 · 晓颜", "标准普通话，字正腔圆", "speaker.wave.2.fill")
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        UserDefaults.standard.set(false, forKey: "xfEnabled")
                        model.speak("语音播报已切换为系统语音")
                    } label: {
                        HStack {
                            Image(systemName: "iphone")
                                .foregroundStyle(.gray)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("系统语音")
                                    .foregroundStyle(.primary)
                                Text("iOS 内置中文语音，无需联网")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !model.xfEnabled { Image(systemName: "checkmark").foregroundStyle(.green) }
                        }
                    }
                } header: {
                    Text("语音引擎")
                }
                Section {
                    ForEach(voices, id: \.vcn) { v in
                        HStack(spacing: 8) {
                            Image(systemName: v.icon)
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(v.name)
                                    .foregroundStyle(.primary)
                                Text(v.sub)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            // 喇叭试听（独立按钮，避免嵌套 Button）
                            Button {
                                model.speak(testText)
                            } label: {
                                Image(systemName: "play.circle")
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                            }
                            .buttonStyle(.borderless)
                            if model.xfEnabled && model.xfVcn == v.vcn {
                                Image(systemName: "checkmark").foregroundStyle(.green)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            UserDefaults.standard.set(true, forKey: "xfEnabled")
                            UserDefaults.standard.set(v.vcn, forKey: "xfVcn")
                            model.speak("语音已切换为\(v.name)")
                        }
                    }
                } header: {
                    Text("讯飞在线语音（需联网，新用户送免费额度）")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if !model.xfDiag.isEmpty {
                            Text("诊断：\(model.xfDiag)")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        Text("音色已内置你的讯飞应用（APPID/Key 已配置）；若提示 11200 请到控制台为该音色开通权限。")
                    }
                }
            }
            .navigationTitle("语音播报")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(430)])
    }
}

struct PoiDetailSheet: View {
    let poi: Poi
    @ObservedObject var model: AppModel
    let onClose: (Bool) -> Void
    @State private var favorite = false
    @State private var distText = ""

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("点位详情")
                    .font(.headline)
                Spacer()
                Button {
                    onClose(true)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 4) {
                Text(poi.name)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                Text("\(poi.type.label) · \(distText)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(String(format: "纬度 %.5f  经度 %.5f", poi.lat, poi.lon))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 10) {
                Button {
                    favorite.toggle()
                    model.toggleFavorite(poi)
                } label: {
                    Label(favorite ? "已收藏" : "收藏", systemImage: favorite ? "star.fill" : "star")
                        .font(.footnote.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(favorite ? Color.yellow.opacity(0.25) : Color.gray.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                Button {
                    let link = "motonav://\(poi.name)@\(poi.lat),\(poi.lon)"
                    let text = "摩卫士违法拍照点位：\(poi.name)（\(poi.type.label)）\n坐标 \(String(format: "%.5f,%.5f", poi.lat, poi.lon))\n打开链接直接导航：\(link)"
                    let avc = UIActivityViewController(activityItems: [text], applicationActivities: nil)
                    if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let root = scene.windows.first?.rootViewController {
                        root.present(avc, animated: true)
                    }
                } label: {
                    Label("分享", systemImage: "square.and.arrow.up")
                        .font(.footnote.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Button {
                model.fetchRouteChoices(to: poi.name, lat: poi.lat, lon: poi.lon)
                onClose(true)
            } label: {
                Text("导航去此处")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.green, in: RoundedRectangle(cornerRadius: 10))
            }
            // v1.51 新增/移动过的点位：详情气泡内直接删除（之前只能长按点位→菜单删除，太隐蔽）
            if poi.isCustom {
                Button(role: .destructive) {
                    model.deletePoi(id: poi.id)
                    model.status = "已删除：\(poi.name)"
                    onClose(true)
                } label: {
                    Label("删除该点位", systemImage: "trash")
                        .font(.footnote.bold())
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(20)
        .presentationDetents([.height(320)])
        .onAppear {
            favorite = model.isFavorite(poi)
            if let loc = model.currentLocation {
                let d = model.distance(to: poi, from: loc)
                distText = d >= 1000
                    ? String(format: "距我 %.1f 公里", d / 1000.0)
                    : String(format: "距我 %d 米", Int(d))
            } else {
                distText = "尚未定位"
            }
        }
    }
}
