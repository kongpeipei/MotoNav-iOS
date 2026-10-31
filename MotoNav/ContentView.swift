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
    /// v1.81 点"搜索"后展开列表模式：搜索框与导航/我的按钮拉开，中间铺满联想地点
    @State private var searchExpanded = false
    /// v1.81 点击联想地点主体后：地图高亮该点并显示地点信息卡
    @State private var tipCard: AppModel.AmapTip?
    /// v1.81.2 退出导航确认态：点状态卡左侧×后切换为"退出导航/取消"两按钮
    @State private var showExitConfirm = false
    @State private var tipRoad: String?
    /// v1.81 地点所属区域（AOI）：名称 + 多边形（地图蓝虚线框住）
    @State private var tipAoiName: String?
    @State private var tipPolygon: [CLLocationCoordinate2D]?
    /// v1.81 地点查看时地图强制北向上
    @State private var northUpTick = 0
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
    /// v1.66 沉浸模式：轻点地图隐藏全部 UI（只留当前定位按钮），再轻点恢复（高德同款）
    @State private var uiHidden = false
    /// v1.69 搜索面板"+"选点模式（轻点地图生成快捷卡片）
    @State private var quickPickMode = false
    @State private var pendingQuickCoord: CLLocationCoordinate2D?
    @State private var showQuickNameAlert = false
    @State private var quickName = ""
    /// v1.69 地图加载失败诊断（高德 SDK 黑屏根因提示）
    @State private var mapLoadFailed = false
    @State private var mapLoadError = ""
    @State private var reloadTick = 0
    /// v1.70：加载失败自动重试一次（避免弱网/瞬时失败直接弹条）
    @State private var mapRetried = false

    var body: some View {
        ZStack {
            // v1.64：底部选项卡分离——0=导航主页（地图+搜索框），1=我的（独立菜单页），切换时选项卡常驻底部
            if selectedTab == 0 {
                mapLayer
                // v1.66：沉浸模式（uiHidden）下隐藏全部 UI，只留当前定位按钮
                if !uiHidden {
                    // v1.81.2 指南针/天气/路线胶囊/缩放/GPS/图层交通 均可自由拖动，位置持久化
                    compassOverlay
                    // 天气条（屏幕最上边；导航中隐藏，高德导航顶部只留导航信息）
                    if !model.navigating {
                        DraggableFloat(key: "weather", defaultPos: CGPoint(x: 0.5, y: 0.05)) { weatherOverlay }
                    }
                    // 规划态顶部路线胶囊（"我的位置 → 目的地"，点击重新搜索）
                    DraggableFloat(key: "routebar", defaultPos: CGPoint(x: 0.5, y: 0.10)) { routeBarOverlay }
                    // 地图缩放 + / - 按钮（含当前定位按钮）
                    DraggableFloat(key: "zoom", defaultPos: CGPoint(x: 0.90, y: 0.34)) { zoomOverlay }
                    // 右上角 GPS 信号按钮（内部已可拖动）
                    layerTrafficButtons
                } else if !model.navigating {
                    // 沉浸模式：仅保留右下角当前定位按钮
                    locateButtonOnly
                }
                // 导航中悬浮退出按钮（可拖动）
                if model.navigating {
                    DraggableFloat(key: "exitnav", defaultPos: CGPoint(x: 0.5, y: 0.84)) { exitNavOverlay }
                }
                // v1.63 导航态左侧竖排：刷新 / 极简（可拖动）
                if model.navigating {
                    DraggableFloat(key: "navside", defaultPos: CGPoint(x: 0.07, y: 0.50)) { navSideOverlay }
                }
                // 高德式顶部大数字条（剩余里程/时间，导航中显示；可拖动）
                DraggableFloat(key: "navtop", defaultPos: CGPoint(x: 0.5, y: 0.13)) { navTopBar }
                // v1.66：沉浸模式下底部内容（搜索框/规划卡/导航卡）隐藏；导航中导航卡不受影响
                if !uiHidden || model.navigating {
                    bottomOverlay
                }
                // v1.69 高德地图加载失败诊断条（黑屏根因提示 + 重试）
                if mapLoadFailed {
                    mapLoadBanner
                }
            } else {
                settingsPage
            }
            // v1.80 底部选项卡：仅"我的"页保留（导航主页已合并进底部主卡片，导航/我的按钮在卡片内）
            if !model.navigating && !uiHidden && selectedTab == 1 {
                bottomTabBar
            }
        }
        // v1.81.3 新一次导航开始时重置退出确认态
        .onChange(of: model.navigating) { _, nv in
            if nv { showExitConfirm = false }
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
        // v1.69 搜索面板"+"选点命名弹窗
        .alert("命名快捷卡片", isPresented: $showQuickNameAlert) {
            TextField("名称（如：回龙观桥下）", text: $quickName)
            Button("保存") {
                if let c = pendingQuickCoord {
                    let n = quickName.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.addQuickPoi(name: n.isEmpty ? "快捷地点" : n, lat: c.latitude, lon: c.longitude)
                    model.status = "已添加快捷卡片「\(n.isEmpty ? "快捷地点" : n)」，点击即可直接导航"
                }
                pendingQuickCoord = nil
                quickPickMode = false
            }
            Button("取消", role: .cancel) {
                pendingQuickCoord = nil
                quickPickMode = false
            }
        } message: {
            Text("保存为搜索面板快捷卡片：点击直接导航，长按卡片可删除")
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
            if nav { uiHidden = false } // v1.66：进入导航自动退出沉浸模式，恢复导航 UI
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
            onPlaceLongPress: { pl in
                // v1.81 长按地图地点名 → 高亮+北向上+地点信息卡（同搜索点击格式）
                haptic()
                showTipCard(name: pl.name, lat: pl.lat, lon: pl.lon, sub: "")
            },
            onCategorySelect: { r in
                model.planRoute(to: r.name, lat: r.lat, lon: r.lon)
                model.clearCategory()
            },
            onMapTap: { coord in
                // v1.69："+"快捷卡片选点模式优先；否则 v1.66 轻点地图沉浸切换（导航中不触发）
                guard !model.navigating else { return }
                if quickPickMode {
                    pendingQuickCoord = coord
                    quickName = placeNameNear(coord)
                    showQuickNameAlert = true
                    return
                }
                withAnimation(.easeOut(duration: 0.2)) { uiHidden.toggle() }
            },
            minimal: minimalMap,
            reloadTick: reloadTick,
            northUpTick: northUpTick,
            tipPolygon: tipPolygon,
            tipFit: tipCard.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) },
            onMapLoad: { ok, err in
                if ok {
                    mapLoadFailed = false
                } else {
                    // v1.70：首次失败自动重试一次（弱网/瞬时抖动），二次失败才亮诊断条
                    if !mapRetried {
                        mapRetried = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            reloadTick += 1
                            model.status = "地图加载异常，自动重试…"
                        }
                        return
                    }
                    mapLoadFailed = true
                    let e = err.lowercased()
                    if e.contains("invalid") || e.contains("socode") || e.contains("key") {
                        mapLoadError = "高德 Key 未生效：请到 lbs.amap.com 控制台确认「iOS 地图 SDK」服务已开通、已完成实名认证、安全码绑定 com.motonav.app.ios"
                    } else if e.contains("network") || e.contains("timed") || e.contains("timeout") {
                        mapLoadError = "地图加载超时/网络异常：请检查网络后点重试"
                    } else {
                        mapLoadError = err
                    }
                }
            }
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

    /// v1.69 地图加载失败诊断条（黑屏时提示原因 + 重试）
    private var mapLoadBanner: some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(mapLoadError)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Spacer()
                Button {
                    reloadTick += 1
                    mapLoadFailed = false
                    model.status = "正在重新加载地图…"
                } label: {
                    Text("重试")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.blue, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.2), lineWidth: 1))
            .padding(.horizontal)
            Spacer()
        }
        .padding(.top, model.navigating ? 290 : 120)
    }

    /// 右上角 ⋯ 菜单（导入/导出点位数据）- 已迁移到底部"我的"选项卡
    private var menuOverlay: some View {
        EmptyView()
    }

    /// v1.66 沉浸模式：仅右下角保留当前定位按钮（点击回到当前位置/清空路线）
    private var locateButtonOnly: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
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
                .padding(.trailing, 14)
                .padding(.bottom, 24)
            }
            Spacer()
        }
    }

    /// v1.81 右上角 GPS 信号按钮（可拖动；内容用视图+onTapGesture，避免 Button 拦截拖拽导致不跟手）
    private var layerTrafficButtons: some View {
        DraggableFloat(key: "gps", defaultPos: CGPoint(x: 0.86, y: 0.24)) {
            VStack(spacing: 8) {
                // GPS信号显示按钮（点击显示定位精度详情）
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
                .contentShape(Capsule())
                .onTapGesture {
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
                }
            }
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
                    // v1.81.1 收藏列表 = 内置点位收藏 + 联想地点收藏（共用同一收藏夹）
                    let favPois: [Poi] = {
                        var ps = model.pois.filter { model.isFavorite($0) }
                        for (key, name) in model.favorites {
                            let parts = key.split(separator: ",").compactMap { Double($0) }
                            guard parts.count == 2,
                                  !ps.contains(where: { $0.lat == parts[0] && $0.lon == parts[1] }) else { continue }
                            var h = 0
                            for b in key.utf8 { h = (h &* 31 &+ Int(b)) }
                            ps.append(Poi(id: Int64(9_000_000 + abs(h) % 900_000),
                                          type: .CUSTOM, name: name, lat: parts[0], lon: parts[1],
                                          radiusM: 0, enabled: true, note: "联想收藏"))
                        }
                        return ps
                    }()
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
                    // v1.81：App 更名为「骑士地图」（图标名同步）
                    HStack {
                        Label("骑士地图", systemImage: "map.fill")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("骑行导航")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    HStack {
                        Label("版本", systemImage: "info.circle")
                        Spacer()
                        Text("v1.81")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    // v1.80：移除黑屏排障诊断项（地图诊断/瓦片网络/高德接口）——黑屏已根治闭环
                    HStack {
                        Label("高德Key", systemImage: "key.fill")
                        Spacer()
                        Text("6fd752…0066")
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
        // v1.81.2 底部每张卡均可自由拖动，位置持久化（默认贴底序列）
        // v1.81.3 地点卡/路线规划卡出现时隐藏搜索主卡；两卡左滑关闭后恢复
        ZStack {
            if !model.navigating {
                if let t = tipCard {
                    DraggableFloat(key: "tipcard", defaultPos: CGPoint(x: 0.5, y: 0.66),
                                   onSwipeLeft: { closeTipCard() }) { tipInfoCard(t) }
                } else if !model.routeChoices.isEmpty {
                    // 路线规划卡：方案选项 + 开始导航 合并为一张白底卡（样式同地点卡）
                    DraggableFloat(key: "routeplan", defaultPos: CGPoint(x: 0.5, y: 0.60),
                                   onSwipeLeft: { closeRoutePlan() }) { routePlanCard }
                } else {
                    DraggableFloat(key: "categorybar", defaultPos: CGPoint(x: 0.5, y: 0.42)) { categoryBar }
                    // v1.69：搜索框聚焦空输入时由面板内高德样式历史列表替代（避免重复显示）
                    if !(searchFocused && searchText.isEmpty) {
                        DraggableFloat(key: "historybar", defaultPos: CGPoint(x: 0.5, y: 0.30)) { historyBar }
                    }
                }
                // 搜索主卡：地点卡或路线规划卡出现时隐藏
                if tipCard == nil && model.routeChoices.isEmpty {
                    DraggableFloat(key: "bottommain", defaultPos: CGPoint(x: 0.5, y: 0.88)) { bottomMainCard }
                }
            } else {
                // v1.65：转向/速度/距离时间已合并到顶部 navTopBar，底部仅留路口放大 + 抓拍条
                DraggableFloat(key: "turnahead", defaultPos: CGPoint(x: 0.5, y: 0.70)) { turnAheadCard }
                DraggableFloat(key: "snapalert", defaultPos: CGPoint(x: 0.5, y: 0.80)) { snapAlertCard }
            }
        }
    }

    /// v1.81.3 左滑关闭地点信息卡（搜索主卡自动恢复）
    private func closeTipCard() {
        tipCard = nil
        tipRoad = nil
        tipAoiName = nil
        tipPolygon = nil
    }

    /// v1.81.3 左滑关闭路线规划卡（清掉路线方案，搜索主卡自动恢复）
    private func closeRoutePlan() {
        model.route = []
        model.routePois = []
        model.routeTurns = []
        model.routeChoices = []
    }

    /// v1.81.3 路线规划卡：头部 + 方案选项卡 + 绿色开始导航，白底圆角（样式同地点卡）
    private var routePlanCard: some View {
        VStack(spacing: 10) {
            routeChoiceHeader
            routeChoiceCards
            Button {
                haptic()
                model.toggleNavigation()
            } label: {
                Text("开始导航")
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.green, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color(.systemBackground).opacity(0.95), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .padding(.horizontal, 14)
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
            }
            // v1.80 已移除选点"导航去此处"按钮（首页底部卡片化，选点导航入口精简）
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
        // v1.81.2 去垂直 Spacer：位置由 DraggableFloat 自由定位（HStack Spacer 仅负责右侧对齐）
        VStack {
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
        // v1.81.3 高德同款白底黑字导航状态卡（用时/里程/红绿灯/抓拍/预计到达）
        // 左侧小× → 切换为"退出导航/取消"两按钮确认
        VStack {
            if model.navigating {
                if showExitConfirm {
                    HStack(spacing: 10) {
                        Button {
                            haptic()
                            showExitConfirm = false
                            model.toggleNavigation()
                        } label: {
                            Text("退出导航")
                                .font(.headline.bold())
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        Button {
                            haptic()
                            showExitConfirm = false
                        } label: {
                            Text("取消")
                                .font(.headline.bold())
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                } else if let ns = model.navigationStatus(at: model.currentLocation), ns.remainM > 0 {
                    let minTxt = "\(max(ns.remainS, 0) / 60)"
                    let kmTxt = String(format: "%.1f", Double(max(ns.remainM, 0)) / 1000.0)
                    let lights = model.routeTurns.count
                    let snaps = model.routePois.count
                    let arriveTxt: String = {
                        let f = DateFormatter()
                        f.dateFormat = "HH:mm"
                        return f.string(from: Date().addingTimeInterval(TimeInterval(max(ns.remainS, 0))))
                    }()
                    HStack(spacing: 0) {
                        Button {
                            haptic()
                            showExitConfirm = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.black.opacity(0.45))
                                .padding(.horizontal, 10)
                        }
                        .buttonStyle(.plain)
                        exitCellDivider
                        exitStatusCell(minTxt, "分钟")
                        exitCellDivider
                        exitStatusCell(kmTxt, "公里")
                        exitCellDivider
                        exitStatusCell("\(lights)", "红绿灯")
                        exitCellDivider
                        exitStatusCell("\(snaps)", "抓拍")
                        exitCellDivider
                        exitStatusCell(arriveTxt, "到达")
                    }
                    .padding(.vertical, 8)
                    .background(Color(.systemBackground).opacity(0.97), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                    .padding(.horizontal, 14)
                }
            }
        }
    }

    /// 退出导航状态卡分格
    private var exitCellDivider: some View {
        Divider().frame(height: 34)
    }

    /// 退出导航状态卡单格（大字+小标签，白底黑字）
    private func exitStatusCell(_ big: String, _ small: String) -> some View {
        VStack(spacing: 1) {
            Text(big)
                .font(.system(size: 19, weight: .heavy))
                .foregroundStyle(.black)
            Text(small)
                .font(.caption2)
                .foregroundStyle(.black.opacity(0.55))
        }
        .frame(minWidth: 0, maxWidth: .infinity)
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
        // v1.80 指南针可自由拖动，位置持久化（下次打开保持）
        DraggableFloat(key: "compass", defaultPos: CGPoint(x: 0.10, y: 0.24)) {
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
        }
    }

    private func dismissKeyboard() {
        searchFocused = false
        // 收起键盘（同步给 focus 状态）
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// v1.81 点"搜索"：收起键盘、展开联想地点列表（搜索框与底部按钮拉开，中间铺满），按距离近→远
    private func expandSearchResults() {
        dismissKeyboard()
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { model.status = "请输入目的地"; return }
        searchExpanded = true
        showSuggestions = true
        Task {
            let tips = await model.amapInputTips(q)
            if searchText.trimmingCharacters(in: .whitespaces) == q {
                onlineTips = sortedByDistance(tips)
            }
        }
    }

    /// v1.81 距当前定位点的直线距离（米），无定位返回 nil
    private func distM(_ lat: Double, _ lon: Double) -> Double? {
        guard let loc = model.currentLocation else { return nil }
        let R = 6371000.0
        let dLat = (lat - loc.latitude) * .pi / 180
        let dLon = (lon - loc.longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat * .pi / 180) * cos(loc.latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return R * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    /// v1.81 距离文案：<1km 显示"350米"，≥1km 显示"1.2公里"；无定位返回 nil
    private func distText(_ lat: Double, _ lon: Double) -> String? {
        guard let d = distM(lat, lon) else { return nil }
        if d < 1000 { return String(format: "%.0f米", d) }
        return String(format: "%.1f公里", d / 1000)
    }

    /// v1.81 联想列表按距当前定位点 近→远 排序（无定位保持原序）
    private func sortedByDistance(_ tips: [AppModel.AmapTip]) -> [AppModel.AmapTip] {
        guard model.currentLocation != nil else { return tips }
        return tips.sorted {
            (distM($0.lat, $0.lon) ?? .greatestFiniteMagnitude)
                < (distM($1.lat, $1.lon) ?? .greatestFiniteMagnitude)
        }
    }

    /// v1.81 点击联想地点主体 / 长按地图地点名：地图定位 + 北向上 + 底部地点信息卡
    /// 注：不画黄圈高亮、不做路线规划（点卡片"路线"按钮才规划），仅地图居中 + 北向上
    private func showTipCard(name: String, lat: Double, lon: Double, sub: String) {
        tipCard = AppModel.AmapTip(name: name, sub: sub, lat: lat, lon: lon)
        tipRoad = nil
        tipAoiName = nil
        tipPolygon = nil
        // 清掉此前规划的路线/方案卡残留，只留地点卡
        model.route = []
        model.routePois = []
        model.routeTurns = []
        model.routeChoices = []
        model.fitTick += 1
        northUpTick += 1
        model.status = "已定位到「\(name)」"
        Task {
            let info = await model.amapRegeoInfo(lat: lat, lon: lon)
            if tipCard?.lat == lat && tipCard?.lon == lon {
                tipRoad = info.road
                tipAoiName = info.aoiName
                tipPolygon = info.polygon
            }
        }
    }

    /// v1.81 摩托骑行时间估算：直线距离 × 1.3 路网系数 ÷ 30km/h，向上取整（至少1分钟）
    private func motoMinutes(_ lat: Double, _ lon: Double) -> Int? {
        guard let d = distM(lat, lon) else { return nil }
        let roadM = d * 1.3
        let mins = roadM / (30.0 * 1000.0 / 60.0)
        return max(1, Int(ceil(mins)))
    }

    /// v1.81 信息卡"搜周边"：以该点为中心拉周边 POI，按距离排序展开列表
    private func aroundSearch(_ t: AppModel.AmapTip) {
        tipCard = nil
        tipRoad = nil
        tipAoiName = nil
        tipPolygon = nil
        model.clearPreview()
        searchExpanded = true
        showSuggestions = true
        model.status = "正在搜索「\(t.name)」周边…"
        Task {
            let around = await model.placeAround(lat: t.lat, lon: t.lon)
            onlineTips = sortedByDistance(around)
            if around.isEmpty { model.status = "「\(t.name)」周边暂无结果" }
        }
    }

    /// v1.81 地点信息卡：距离 / 摩托时间 / 沿途抓拍 / 所在道路
    private func tipInfoCard(_ t: AppModel.AmapTip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "mappin.circle.fill")
                    .foregroundStyle(.green)
                Text(t.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                // v1.81.3 右上角关闭按钮移除，改为整卡左滑关闭
                Text("左滑关闭")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 12) {
                if let d = distText(t.lat, t.lon) {
                    Label(d, systemImage: "location.fill")
                }
                if let mins = motoMinutes(t.lat, t.lon) {
                    Label("摩托约\(mins)分钟", systemImage: "clock.fill")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                if let loc = model.currentLocation {
                    Label("沿途抓拍 \(model.snapCountBetween(loc, CLLocationCoordinate2D(latitude: t.lat, longitude: t.lon))) 个", systemImage: "camera.fill")
                }
                if let road = tipRoad ?? (!t.sub.isEmpty ? t.sub : nil) {
                    Label("位于\(road)", systemImage: "road.lanes")
                        .lineLimit(1)
                }
                // v1.81 区域范围：显示区域名（蓝虚线框住见地图）
                if let aoi = tipAoiName {
                    Label(aoi, systemImage: "square.dashed")
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            // v1.81 操作行：搜周边 / 收藏 / 分享 + 导航 / 路线
            Divider()
                .padding(.vertical, 4)
            HStack(spacing: 6) {
                Button {
                    aroundSearch(t)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "magnifyingglass")
                            .font(.title3)
                        Text("搜周边")
                            .font(.caption2)
                    }
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                Button {
                    haptic()
                    model.toggleTipFavorite(name: t.name, lat: t.lat, lon: t.lon)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: model.isTipFavorite(lat: t.lat, lon: t.lon) ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundStyle(model.isTipFavorite(lat: t.lat, lon: t.lon) ? .orange : .primary)
                        Text("收藏")
                            .font(.caption2)
                    }
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                ShareLink(item: "\(t.name) \(tipRoad ?? (!t.sub.isEmpty ? t.sub : ""))") {
                    VStack(spacing: 2) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title3)
                        Text("分享")
                            .font(.caption2)
                    }
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                Spacer()
                // 白色"导航"：直接开始导航
                Button {
                    tipCard = nil
                    tipRoad = nil
                    tipAoiName = nil
                    tipPolygon = nil
                    model.clearPreview()
                    model.fetchRouteChoices(to: t.name, lat: t.lat, lon: t.lon, autoStart: true)
                } label: {
                    Text("导航")
                        .font(.subheadline.bold())
                        .foregroundStyle(.blue)
                        .frame(width: 76, height: 40)
                        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.blue, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                // 蓝色"路线"：开始规划路线
                Button {
                    tipCard = nil
                    tipRoad = nil
                    tipAoiName = nil
                    tipPolygon = nil
                    model.clearPreview()
                    model.fetchRouteChoices(to: t.name, lat: t.lat, lon: t.lon)
                } label: {
                    Text("路线")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .frame(width: 76, height: 40)
                        .background(Color.blue, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color(.systemBackground).opacity(0.95), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .padding(.horizontal, 14)
    }

    private func addPoiAtPending(type: PoiType) {
        guard let c = pendingCoord else { return }
        model.addPoi(type: type, name: "地图新增\(type.label)点", lat: c.latitude, lon: c.longitude)
        model.status = "已添加：地图新增\(type.label)点"
        pendingCoord = nil
    }

    /// v1.80 首页底部主卡片：搜索框 + 导航/我的 合并为一个整体卡片
    private var bottomMainCard: some View {
        VStack(spacing: 8) {
            searchInputRow
            // v1.69：搜索框聚焦且未输入 → 快捷卡片（家/公司/+）+ 历史搜索记录（高德样式）
            if searchFocused && searchText.isEmpty {
                quickAccessPanel
            }
            if showSuggestions && !suggestions.isEmpty {
                suggestionsList
            }
            // 高德 POI 联想候选（填写高德 Key 后显示，点击直接定位）
            if showSuggestions && !onlineTips.isEmpty {
                onlineTipsList
            }
            tabButtonsRow
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color(.systemBackground).opacity(0.96), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .padding(.horizontal, 14)
    }

    /// v1.80 导航/我的 选项卡按钮行（合并进底部主卡片；"我的"页仍保留独立选项卡可切回）
    private var tabButtonsRow: some View {
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
    }

    /// v1.69 搜索面板：快捷卡片行 + 高德样式历史记录
    private var quickAccessPanel: some View {
        VStack(spacing: 6) {
            quickCardsRow
            if !model.searchHistory.isEmpty {
                historyList
            }
        }
    }

    /// v1.69 单行快捷卡片：家 / 公司 / +（自定义选点） 横向滚动
    private var quickCardsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // 家
                quickCard(icon: "house.fill", color: .blue,
                          title: "家", sub: model.homePlace.map { displayName($0.name) } ?? "未设置") {
                    if let h = model.homePlace {
                        dismissKeyboard(); searchFocused = false
                        model.planRoute(to: h.name, lat: h.lat, lon: h.lon)
                    } else {
                        model.status = "家未设置：长按「家」卡片用当前位置设置，或在「我的」页设置"
                    }
                }
                .contextMenu {
                    Button("用当前位置重设家") {
                        if let loc = model.currentLocation {
                            model.setHomeCoord(loc)
                            model.status = "已用当前位置重设「家」"
                        } else { model.status = "定位中，稍后再试" }
                    }
                }
                // 公司
                quickCard(icon: "briefcase.fill", color: .blue,
                          title: "公司", sub: model.workPlace.map { displayName($0.name) } ?? "未设置") {
                    if let w = model.workPlace {
                        dismissKeyboard(); searchFocused = false
                        model.planRoute(to: w.name, lat: w.lat, lon: w.lon)
                    } else {
                        model.status = "公司未设置：长按「公司」卡片用当前位置设置，或在「我的」页设置"
                    }
                }
                .contextMenu {
                    Button("用当前位置重设公司") {
                        if let loc = model.currentLocation {
                            model.setWorkCoord(loc)
                            model.status = "已用当前位置重设「公司」"
                        } else { model.status = "定位中，稍后再试" }
                    }
                }
                // "+" 地图选点生成快捷卡片
                quickCard(icon: quickPickMode ? "mappin.circle.fill" : "plus",
                          color: quickPickMode ? .white : .blue,
                          title: quickPickMode ? "选点中" : "添加",
                          sub: quickPickMode ? "轻点地图选位置" : "地图选点") {
                    quickPickMode.toggle()
                    if quickPickMode {
                        searchFocused = false
                        model.status = "请在屏幕上轻点要保存的位置，然后命名"
                    } else {
                        model.status = "已取消添加"
                    }
                }
                // 自定义快捷卡片（长按删除）
                ForEach(model.quickPois) { qp in
                    quickCard(icon: "star.fill", color: .orange,
                              title: displayName(qp.name), sub: "快捷地点") {
                        dismissKeyboard(); searchFocused = false
                        model.planRoute(to: qp.name, lat: qp.lat, lon: qp.lon)
                    }
                    .contextMenu {
                        Button("删除「\(displayName(qp.name))」", role: .destructive) {
                            model.removeQuickPoi(id: qp.id)
                            model.status = "已删除快捷卡片「\(qp.name)」"
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    /// v1.69 高德样式历史搜索记录列表（名称 + 分隔线 + 清空）
    private var historyList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("历史搜索")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清空") {
                    model.clearHistory()
                    model.status = "搜索历史已清空"
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.searchHistory, id: \.self) { item in
                        Button {
                            searchText = item
                            showSuggestions = false
                            dismissKeyboard()
                            doSearch()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.gray)
                                Text(displayName(item))
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 38)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .background(.bar)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        .padding(.horizontal)
    }

    /// v1.69 快捷卡片通用外观
    private func quickCard(
        icon: String, color: Color, title: String, sub: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(sub)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 78, height: 58)
        .background(.bar, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.25), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { action() }
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
                .onSubmit { expandSearchResults() }
                .onChange(of: searchText) { newValue in
                    // 只使用高德Web搜索联想，删除本地联想
                    suggestions = []
                    showSuggestions = !newValue.trimmingCharacters(in: .whitespaces).isEmpty
                    // v1.81：输入时列表收起（小高度），点"搜索"才展开铺满
                    searchExpanded = false
                    // 高德搜索逻辑：输入即实时返回 POI 联想候选（带坐标，点击直接定位）
                    onlineTips = []
                    if !model.amapKey.isEmpty {
                        let q = newValue.trimmingCharacters(in: .whitespaces)
                        guard !q.isEmpty else { return }
                        Task {
                            let tips = await model.amapInputTips(q)
                            if searchText == newValue {
                                // v1.81：按距当前定位点 近→远 排序
                                onlineTips = sortedByDistance(tips)
                            }
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
                // v1.81：点搜索 → 收起键盘，展开联想地点列表（搜索框与按钮拉开，中间铺满）
                expandSearchResults()
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

    /// v1.81 高德联想候选列表：点主体→高亮+北向上+地点信息卡；点箭头→直接导航规划
    private var onlineTipsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(onlineTips) { tip in
                    VStack(spacing: 0) {
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
                            // v1.81：名称右侧、箭头左侧显示距当前定位点距离
                            if let d = distText(tip.lat, tip.lon) {
                                Text(d)
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                                    .padding(.trailing, 6)
                            }
                            // v1.81：箭头=直接规划导航；主体其他位置=高亮+信息卡
                            Button {
                                searchFocused = false
                                showSuggestions = false
                                searchExpanded = false
                                dismissKeyboard()
                                model.addHistory(tip.name)
                                model.fetchRouteChoices(to: tip.name, lat: tip.lat, lon: tip.lon)
                            } label: {
                                Image(systemName: "arrow.up.right.circle")
                                    .foregroundStyle(Color(red: 0.0, green: 0.75, blue: 0.95))
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // v1.81 主体点击：地图高亮+北向上+地点信息卡
                            searchFocused = false
                            showSuggestions = false
                            searchExpanded = false
                            dismissKeyboard()
                            model.addHistory(tip.name)
                            showTipCard(name: tip.name, lat: tip.lat, lon: tip.lon, sub: tip.sub)
                        }
                        Divider()
                    }
                }
            }
        }
        // v1.81：点"搜索"展开时铺满中间（搜索框与底部按钮拉开），输入时小高度
        .frame(maxHeight: searchExpanded ? 400 : 190)
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
        // v1.80 语音包统一列表：本地内置（vcn=""）+ 讯飞已授权发音人（实测合成成功）
        ("", "本地内置 · 默认中文女声", "iOS 内置中文语音，无需联网", "iphone"),
        ("xiaoyan", "普通话女声 · 晓燕", "标准普通话，字正腔圆", "speaker.wave.2.fill"),
        ("xiaoyu", "普通话女声 · 晓宇", "甜美普通话女声", "speaker.wave.2.fill"),
        ("xiaomei", "普通话女声 · 小美", "温柔普通话女声", "speaker.wave.2.fill"),
        ("xiaoqiang", "普通话男声 · 小强", "沉稳普通话男声", "speaker.wave.2.fill"),
        ("xiaorong", "四川话女声 · 小蓉", "亲切川味，导航更有味道", "speaker.wave.3.fill"),
        ("xiaoyue", "粤语女声 · 晓月", "标准粤语女声", "speaker.wave.2.fill"),
        ("x4_xiaolu", "普通话女声 · 讯飞小露", "特色发音人，清亮女声", "sparkles"),
        ("x4_xiaorong", "四川话女声 · 讯飞小蓉", "特色发音人，川味十足", "sparkles"),
        ("x4_yezi", "四川话女声 · 叶子", "清亮川腔，推荐", "sparkles"),
        ("x4_lingbosong", "普通话男声 · 聆伯松", "特色发音人，磁性男声", "sparkles"),
        ("x4_lingxiaoxuan_wenrou", "普通话女声 · 聆小璇-温柔", "特色发音人，温柔女声", "sparkles")
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(voices, id: \.vcn) { v in
                        HStack(spacing: 8) {
                            Image(systemName: v.icon)
                                .foregroundStyle(v.vcn.isEmpty ? .gray : .green)
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
                            if v.vcn.isEmpty ? !model.xfEnabled : (model.xfEnabled && model.xfVcn == v.vcn) {
                                Image(systemName: "checkmark").foregroundStyle(.green)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if v.vcn.isEmpty {
                                UserDefaults.standard.set(false, forKey: "xfEnabled")
                            } else {
                                UserDefaults.standard.set(true, forKey: "xfEnabled")
                                UserDefaults.standard.set(v.vcn, forKey: "xfVcn")
                            }
                            model.speak("语音已切换为\(v.name)")
                        }
                    }
                } header: {
                    Text("语音包")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if !model.xfDiag.isEmpty {
                            Text("诊断：\(model.xfDiag)")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        Text("本地内置无需联网；讯飞音色为你的应用已授权发音人，需联网合成，新增音色请到讯飞控制台「发音人授权管理」开通。")
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

/// v1.80 可拖动悬浮控件：位置以 0-1 归一化持久化到 UserDefaults，下次打开还原
/// v1.81.2 支持 onSwipeLeft：向左大幅滑动（>80pt 且横向为主）触发回调关闭，否则正常拖动记忆
private struct DraggableFloat<Content: View>: View {
    let key: String
    var onSwipeLeft: (() -> Void)? = nil
    @ViewBuilder let content: Content
    @State private var pos: CGPoint
    @State private var dragging = false

    init(key: String, defaultPos: CGPoint, onSwipeLeft: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.key = key
        self.onSwipeLeft = onSwipeLeft
        self.content = content()
        let x = UserDefaults.standard.object(forKey: "\(key).x") as? Double
        let y = UserDefaults.standard.object(forKey: "\(key).y") as? Double
        _pos = State(initialValue: CGPoint(x: x ?? defaultPos.x, y: y ?? defaultPos.y))
    }

    var body: some View {
        GeometryReader { geo in
            content
                .position(x: pos.x * geo.size.width, y: pos.y * geo.size.height)
                .shadow(color: .black.opacity(dragging ? 0.3 : 0.12), radius: 8, y: 3)
                .scaleEffect(dragging ? 1.08 : 1.0)
                .animation(.easeOut(duration: 0.12), value: dragging)
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { v in
                            dragging = true
                            pos = CGPoint(
                                x: min(0.96, max(0.04, v.location.x / geo.size.width)),
                                y: min(0.96, max(0.04, v.location.y / geo.size.height)))
                        }
                        .onEnded { v in
                            dragging = false
                            if let onSwipeLeft = onSwipeLeft,
                               v.translation.width < -80,
                               abs(v.translation.width) > abs(v.translation.height) {
                                onSwipeLeft()
                            } else {
                                UserDefaults.standard.set(pos.x, forKey: "\(key).x")
                                UserDefaults.standard.set(pos.y, forKey: "\(key).y")
                            }
                        }
                )
        }
    }
}
