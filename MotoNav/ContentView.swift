import SwiftUI
import MapKit
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var searchText = ""
    @State private var suggestions: [String] = []
    @State private var showSuggestions = false
    /// 高德「输入提示」联想候选（填写高德 Key 后启用，点击直接定位跳转）
    @State private var onlineTips: [AppModel.AmapTip] = []
    /// 高德搜索 Key 输入弹窗
    @State private var showAmapKeyInput = false
    @State private var amapKeyInput = ""
    @State private var longPressCoord: CLLocationCoordinate2D?
    @State private var showLongPressMenu = false
    /// 标记该点：待标记坐标 + 备注输入
    @State private var pendingMarkCoord: CLLocationCoordinate2D?
    @State private var showMarkNameAlert = false
    @State private var markName = ""
    /// 点位详情气泡（点击点位弹出：距离/收藏/分享/导航）
    @State private var poiDetail: Poi?
    @State private var editPoi: Poi?
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
    /// 底部选项卡：0=导航主页，1=我的
    @State private var selectedTab = 0
    /// 语音包设置页弹出（"我的"→语音播报）
    @State private var showVoiceSettings = false
    /// v1.63 极简模式（导航中左侧按钮切换：隐藏兴趣点标注）
    @State private var minimalMap = false

    var body: some View {
        ZStack {
            // v1.64：底部选项卡分离——0=导航主页（地图+搜索框），1=我的（独立菜单页），切换时选项卡常驻底部
            if selectedTab == 0 {
                mapLayer
                // 左上角指南针（手机朝向即指针指向）
                compassOverlay
                // 天气条（屏幕最上边；导航中隐藏，高德导航顶部只留导航信息）
                if !model.navigating {
                    weatherOverlay
                }
                // 规划态顶部路线胶囊（"我的位置 → 目的地"，点击重新搜索）
                routeBarOverlay
                // 地图缩放 + / - 按钮
                zoomOverlay
                // 图层/路况文字按钮（右上角）
                layerTrafficButtons
                // 导航中悬浮退出按钮
                exitNavOverlay
                // v1.63 导航态左侧竖排：刷新 / 极简（高德导航特征）
                if model.navigating {
                    navSideOverlay
                }
                // 高德式顶部大数字条（剩余里程/时间，导航中显示）
                navTopBar
                bottomOverlay
            } else {
                settingsPage
            }
            // 底部选项卡（导航中隐藏，切换界面常驻下方）
            if !model.navigating {
                bottomTabBar
            }
        }
        .sheet(item: $poiDetail) { p in
            PoiDetailSheet(poi: p, model: model) { close in
                poiDetail = nil
            }
        }
        // v1.61 恢复：语音包设置（"我的"→语音播报，讯飞音色选择）
        .sheet(isPresented: $showVoiceSettings) {
            VoiceSettingsSheet(model: model)
        }
        .sheet(item: $editPoi) { p in
            PoiEditSheet(mode: .edit, poi: p) { type, name, lat, lon, r in
                model.updatePoi(id: p.id, type: type, name: name, lat: lat, lon: lon, radiusM: r)
            }
        }
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
        .onAppear {
            model.authorizeAndStart()
            model.fetchPlaceLabels()
            model.checkClipboard()
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
                    + "平均速度：\(String(format: "%.1f", s.avgSpeedKmh)) 公里/小时\n"
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
                goHereLabel = "导航去此处"
                goHereName = pl.name
                goHereLat = pl.lat
                goHereLon = pl.lon
                model.clearPreview()
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
            Spacer()
        }
    }

    /// 右上角 ⋯ 菜单（导入/导出点位数据）- 已迁移到底部"我的"选项卡
    private var menuOverlay: some View {
        EmptyView()
    }

    /// 右上角竖排文字按钮：GPS信号 + 图层（高德瓦片）+ 路况（实时路况）
    private var layerTrafficButtons: some View {
        VStack {
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    // GPS信号显示按钮
                    Button {
                        // 点击显示定位精度详情
                        let acc = model.locationAccuracy
                        let signalLevel: String
                        if acc <= 10 {
                            signalLevel = "强（\(Int(acc))米）"
                        } else if acc <= 50 {
                            signalLevel = "中（\(Int(acc))米）"
                        } else {
                            signalLevel = "弱（\(Int(acc))米）"
                        }
                        model.status = "GPS信号：\(signalLevel)"
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "scope")
                                .font(.caption2.bold())
                            Text(gpsSignalText())
                                .font(.caption.bold())
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(gpsSignalColor(), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.4), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.trailing, 12)
                .padding(.top, 40)
            }
            Spacer()
        }
    }
    
    /// GPS信号文字
    private func gpsSignalText() -> String {
        let acc = model.locationAccuracy
        if acc <= 0 { return "定位中" }
        if acc <= 10 { return "GPS·强" }
        if acc <= 50 { return "GPS·中" }
        return "GPS·弱"
    }
    
    /// GPS信号颜色
    private func gpsSignalColor() -> Color {
        let acc = model.locationAccuracy
        if acc <= 0 { return Color.gray }
        if acc <= 10 { return Color.green }
        if acc <= 50 { return Color.orange }
        return Color.red
    }

    /// v1.65 底部选项卡：导航 / 我的（白底、缩小、选中蓝色铺满整个按钮）
    private var bottomTabBar: some View {
        VStack {
            Spacer()
            HStack(spacing: 6) {
                Button {
                    selectedTab = 0
                    haptic()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: selectedTab == 0 ? "location.north.circle.fill" : "location.north.circle")
                            .font(.body)
                        Text("导航")
                            .font(.caption)
                            .fontWeight(selectedTab == 0 ? .semibold : .regular)
                    }
                    .foregroundStyle(selectedTab == 0 ? .white : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(selectedTab == 0 ? Color.blue : .clear, in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    selectedTab = 1
                    haptic()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: selectedTab == 1 ? "person.fill" : "person")
                            .font(.body)
                        Text("我的")
                            .font(.caption)
                            .fontWeight(selectedTab == 1 ? .semibold : .regular)
                    }
                    .foregroundStyle(selectedTab == 1 ? .white : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(selectedTab == 1 ? Color.blue : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(height: 54)
            .background(Color(.systemBackground).opacity(0.96), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .padding(.horizontal, 20)
        }
    }

    /// "我的"页面：导入/导出JSON、高德Key设置
    /// v1.64 "我的"独立菜单页（底部选项卡切换进入，选项卡常驻下方）
    private var settingsPage: some View {
        NavigationStack {
            List {
                // v1.61：语音包选项卡（讯飞四川话/普通话女声，从旧版"语音"入口迁入"我的"）
                Section {
                    Button {
                        showVoiceSettings = true
                    } label: {
                        HStack {
                            Label("语音包", systemImage: "waveform")
                            Spacer()
                            Text(model.xfVcnName)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                } header: {
                    Text("语音播报")
                }
                // v1.63：常用地点分组（家/公司/收藏），主界面不再放快捷按钮
                Section {
                    Button {
                        if let h = model.homePlace {
                            goHereLabel = "导航去此处"
                            goHereName = h.name
                            goHereLat = h.lat
                            goHereLon = h.lon
                            selectedTab = 0
                            model.planRoute(to: h.name, lat: h.lat, lon: h.lon)
                        } else if let loc = model.currentLocation {
                            // v1.65：未设置时用当前位置一键设置
                            model.setHomeCoord(loc)
                            model.status = "已用当前位置设为家"
                        } else {
                            model.status = "等待定位后再设置家"
                        }
                    } label: {
                        HStack {
                            Label("家", systemImage: "house.fill")
                            Spacer()
                            Text(model.homePlace?.name ?? "未设置（点此用当前位置设置）")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                    Button {
                        if let w = model.workPlace {
                            goHereLabel = "导航去此处"
                            goHereName = w.name
                            goHereLat = w.lat
                            goHereLon = w.lon
                            selectedTab = 0
                            model.planRoute(to: w.name, lat: w.lat, lon: w.lon)
                        } else if let loc = model.currentLocation {
                            model.setWorkCoord(loc)
                            model.status = "已用当前位置设为公司"
                        } else {
                            model.status = "等待定位后再设置公司"
                        }
                    } label: {
                        HStack {
                            Label("公司", systemImage: "briefcase.fill")
                            Spacer()
                            Text(model.workPlace?.name ?? "未设置（点此用当前位置设置）")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                } header: {
                    Text("常用地点")
                }
                Section {
                    let favPois = model.pois.filter { model.isFavorite($0) }
                    if favPois.isEmpty {
                        Text("暂无收藏点位（点位详情里点⭐收藏）")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    } else {
                        ForEach(favPois.prefix(8)) { p in
                            Button {
                                goHereLabel = "导航去此处"
                                goHereName = p.name
                                goHereLat = p.lat
                                goHereLon = p.lon
                                selectedTab = 0
                                model.planRoute(to: p.name, lat: p.lat, lon: p.lon)
                            } label: {
                                HStack {
                                    Label(p.name, systemImage: "star.fill")
                                    Spacer()
                                    Text(p.type.label)
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                            }
                        }
                        .onDelete { idxs in
                            for i in idxs where i < favPois.count {
                                let p = favPois[i]
                                model.toggleFavorite(p)
                            }
                            model.status = "已取消收藏"
                        }
                    }
                } header: {
                    Text("收藏")
                }
                Section("搜索设置") {
                    Button {
                        amapKeyInput = model.amapKey
                        showAmapKeyInput = true
                    } label: {
                        HStack {
                            Label("高德搜索 Key", systemImage: "key")
                            Spacer()
                            Text(model.amapKey.isEmpty ? "未设置" : "已启用")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                }
                Section("关于") {
                    HStack {
                        Label("版本", systemImage: "info.circle")
                        Spacer()
                        Text("v1.65")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            // v1.64：底部选项卡常驻，列表底部留出空间不被遮挡
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 8)
            }
        }
    }

    /// 规划态顶部路线胶囊：显示"我的位置 → 目的地"，点击重新搜索（高德规划态顶部搜索框）
    private var routeBarOverlay: some View {
        VStack {
            HStack {
                Spacer()
                if !model.navigating, !model.routeChoices.isEmpty, !showSearchField {
                    Button {
                        haptic()
                        showSearchField = true
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
                historyBar
                routeChoiceList
                goHereBar
                // 搜索框始终显示（底部选项卡上方）
                searchBar
            } else {
                // v1.65：转向/速度/距离时间已合并到顶部 navTopBar，底部仅留路口放大 + 抓拍条
                turnAheadCard
                snapAlertCard
            }
        }
        .padding(.bottom, model.navigating ? 88 : 80) // v1.65：导航中给底部居中"退出导航"留空间
    }

    /// v1.65：原底部转向大卡 navInfoCard 已合并进顶部 navTopBar（道路指示/速度/距离时间三合一）

    /// 高德式路口放大示意图：接近下一转向（<200米）时显示交叉路口 + 转弯箭头 + 路名
    private var turnAheadCard: some View {
        Group {
            if let ns = model.navigationStatus(at: model.currentLocation),
               let t = ns.nextTurn, ns.distToTurnM < 200 {
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
                // 方案已选 → 绿色"开始导航"
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
                        .padding(.horizontal)
                }
                .padding(.bottom, 4)
            } else if goHereName != nil || (goHereLat != 0 && goHereLon != 0) {
                Button {
                    haptic()
                    showSearchField = false
                    model.fetchRouteChoices(to: goHereName ?? "地图选点", lat: goHereLat, lon: goHereLon)
                    goHereName = nil
                    goHereLat = 0
                    goHereLon = 0
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

    /// 规划头部（高德式：出发地 → 目的地）
    private var routeChoiceHeader: some View {
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
    /// v1.65 顶部导航综合条（高德式合并布局，自上而下不重叠）：
    /// 第一行：剩余距离 + 剩余时间 + 实时速度；第二行：下一转向指示（图标+距离+路名+车道）
    private var navTopBar: some View {
        VStack {
            if model.navigating, let ns = model.navigationStatus(at: model.currentLocation), ns.remainM > 0 {
                VStack(spacing: 8) {
                    // 第一行：剩余距离 / 剩余时间 / 速度
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(String(format: "%.1f", Double(max(ns.remainM, 0)) / 1000.0))
                                .font(.system(size: 34, weight: .heavy))
                                .foregroundStyle(.white)
                            Text("剩余公里")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(max(ns.remainS, 0) / 60) 分钟")
                                .font(.system(size: 24, weight: .heavy))
                                .foregroundStyle(.white)
                            Text("剩余时间")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("\(Int(ns.speedKph))")
                                .font(.system(size: 34, weight: .heavy))
                                .foregroundStyle(.white)
                            Text("km/h")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    // 第二行：下一转向指示（<500米时显示，高德"前方X米右转 进入XX路"）
                    if let t = ns.nextTurn, ns.distToTurnM < 500, ns.distToTurnM > 0 {
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
                    }
                    // 车道指引（<500米时随转向显示）
                    if let t = ns.nextTurn, ns.distToTurnM < 500, ns.distToTurnM > 0, !t.lanes.isEmpty {
                        HStack(spacing: 3) {
                            ForEach(t.lanes, id: \.self) { lane in
                                Image(systemName: navLaneIcon(lane))
                                    .font(.footnote.bold())
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .padding(.top, 52)
            }
            Spacer()
        }
    }

    /// v1.65 退出导航按钮：最下方中间，加大红色胶囊（骑行时单手易点）
    private var exitNavOverlay: some View {
        VStack {
            Spacer()
            if model.navigating {
                Button {
                    haptic()
                    model.toggleNavigation()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark")
                            .font(.body.bold())
                        Text("退出导航")
                            .font(.body.bold())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 56)
                    .padding(.vertical, 15)
                    .background(Color.red, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.4), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 10)
    }

    /// 触感反馈（iOS Haptic）
    private func haptic() {
        let g = UIImpactFeedbackGenerator(style: .medium)
        g.impactOccurred()
    }

    /// v1.63 导航态左侧竖排按钮（高德式）：刷新（重新规划路线）/ 极简（隐藏兴趣点）
    private var navSideOverlay: some View {
        VStack {
            HStack {
                VStack(spacing: 10) {
                    Button {
                        haptic()
                        model.refreshRoute()
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "arrow.clockwise")
                                .font(.body.bold())
                            Text("刷新")
                                .font(.caption2.bold())
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.35), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    Button {
                        haptic()
                        minimalMap.toggle()
                        model.status = minimalMap ? "极简模式：已隐藏兴趣点标注" : "极简模式：已关闭"
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "eye.slash")
                                .font(.body.bold())
                            Text("极简")
                                .font(.caption2.bold())
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(minimalMap ? Color.blue : Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.35), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 10)
                .padding(.top, 200)
                Spacer()
            }
            Spacer()
        }
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

    /// 目的地搜索框（输入时智能联想，高德式底部胶囊；导航时被退出按钮替代）
    private var searchBar: some View {
        VStack(spacing: 4) {
            searchInputRow
            if showSuggestions && !suggestions.isEmpty {
                suggestionsList
            }
            // 高德 POI 联想候选（填写高德 Key 后显示，点击直接定位）
            if showSuggestions && !onlineTips.isEmpty {
                onlineTipsList
            }
        }
        .background(.black.opacity(0.18))
    }

    /// 搜索输入行：高德样式白底大圆角（放大镜 + 输入 + ✕ + 搜索按钮为一体）
    private var searchInputRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(.gray)
            TextField("查找地点、公交、地铁", text: $searchText)
                .font(.subheadline)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { showSuggestions = false; dismissKeyboard(); doSearch() }
                .onChange(of: searchText) { newValue in
                    // 只使用高德Web搜索联想，删除本地联想
                    suggestions = []
                    showSuggestions = !newValue.trimmingCharacters(in: .whitespaces).isEmpty
                    // 高德搜索逻辑：输入即实时返回 POI 联想候选（带坐标，点击直接定位）
                    onlineTips = []
                    if !model.amapKey.isEmpty {
                        let q = newValue.trimmingCharacters(in: .whitespaces)
                        guard !q.isEmpty else { return }
                        Task {
                            let tips = await model.amapInputTips(q)
                            if searchText == newValue { onlineTips = tips }
                        }
                    }
                }
            // 一键清除输入内容（有内容时显示）
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    suggestions = []
                    showSuggestions = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
            }
            // 麦克风图标
            Button {
                // 语音搜索（暂未实现）
                model.status = "语音搜索功能开发中"
            } label: {
                Image(systemName: "mic.fill")
                    .font(.subheadline)
                    .foregroundStyle(.gray)
            }
            .buttonStyle(.plain)
            // 搜索按钮（与输入框同一胶囊内，右侧）
            Button {
                showSuggestions = false
                dismissKeyboard()
                doSearch()
            } label: {
                Text("搜索")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(red: 0.0, green: 0.75, blue: 0.95), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        // v1.63：跟随系统深浅色（浅色白底/深色深底，夜间骑行不刺眼）
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 26))
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
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

    /// 联想条目按钮（含分隔线）
    private func suggestionButton(_ idx: Int, _ s: String) -> some View {
        VStack(spacing: 0) {
            Button {
                searchFocused = false
                showSuggestions = false
                if s.hasPrefix("🔍") {
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

    /// 联想条目行（收藏 ⭐ 优先展示，点击用原名）
    private func suggestionRow(_ s: String) -> some View {
        let isFav = !s.hasPrefix("🔍") && model.favorites.values.contains(s)
        return HStack {
            Image(systemName: suggestionIcon(s))
                .foregroundStyle(suggestionIconColor(s))
            Text(isFav ? "⭐ \(s)" : s).foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func suggestionIcon(_ s: String) -> String {
        if s.hasPrefix("🔍") { return "magnifyingglass" }
        return "mappin.and.ellipse"
    }

    private func suggestionIconColor(_ s: String) -> Color {
        if s.hasPrefix("🔍") { return .orange }
        return .secondary
    }

    /// 历史搜索记录（横滑标签，带清空按钮）
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
                        // 清空按钮
                        Button {
                            model.clearHistory()
                            model.status = "搜索历史已清空"
                        } label: {
                            Text("清空")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .buttonStyle(.bordered)
                        .tint(.gray)
                        .controlSize(.small)
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

    /// 从「🔍 在线搜索「XX」」提取 XX
    private func extractOnlineQuery(_ s: String) -> String {
        if let start = s.firstIndex(of: "「"), let end = s.lastIndex(of: "」"), start < end {
            return String(s[s.index(after: start)..<end])
        }
        return s
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
            // v1.65：设为家 / 设为公司（我的页常用地点一键调用）
            HStack(spacing: 10) {
                Button {
                    model.setHome(poi)
                    onClose(true)
                } label: {
                    Label("设为家", systemImage: "house.fill")
                        .font(.footnote.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                }
                Button {
                    model.setWork(poi)
                    onClose(true)
                } label: {
                    Label("设为公司", systemImage: "briefcase.fill")
                        .font(.footnote.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(20)
        .presentationDetents([.height(380)])
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

/// v1.61 恢复：语音包设置（高德式：语音引擎 + 音色列表 + 喇叭试听 + 选中勾）
/// 入口："我的"→语音播报
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
