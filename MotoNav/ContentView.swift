import SwiftUI
import MapKit
import UIKit
import UniformTypeIdentifiers

/// v2.12 外观设置：跟随系统 / 强制浅色 / 强制深色
enum AppearanceMode: String, CaseIterable, Identifiable {
    case auto
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// nil = 跟随系统
    var colorScheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    /// v1.99 组队骑行（地图队友点 + 我的页队伍面板）
    @StateObject private var team = TeamRide.shared
    /// v1.99 足迹（我的-足迹）
    @StateObject private var footprints = FootprintStore.shared
    /// v1.99 离线地图包
    @StateObject private var offline = OfflineMapManager.shared
    /// v2.04 官方电警点位库（合肥交警公示）
    @StateObject private var camStore = PoliceCameraStore.shared
    /// v1.90 省电模式总开关（"我的"页可关；关闭后低电量也不再降频/调暗）
    @AppStorage("powerSaveEnabled") private var powerSaveEnabled = true
    /// v2.12 外观：auto / light / dark（"我的"页省电下方三段式切换）
    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.auto.rawValue
    @State private var searchText = ""
    @State private var suggestions: [String] = []
    @State private var showSuggestions = false
    /// 高德「输入提示」联想候选（填写高德 Key 后启用，点击直接定位跳转）
    @State private var onlineTips: [AppModel.AmapTip] = []
    /// v1.81 点"搜索"后展开列表模式：搜索框与导航/我的按钮拉开，中间铺满联想地点
    @State private var searchExpanded = false
    /// v1.81 点击联想地点主体后：地图高亮该点并显示地点信息卡
    @State private var tipCard: AppModel.AmapTip?
    /// v1.95 轻点地图任意位置 → 地点介绍卡（逆地理编码结果）
    @State private var tapPlace: TapPlaceInfo?
    /// v1.81.2 退出导航确认态：点状态卡左侧×后切换为"退出导航/取消"两按钮
    @State private var showExitConfirm = false
    // v1.81.4 导航全览：导航退出卡"全览"→ 缩放显示全程路线 + 固定全览/取消全览(13s倒计时) 操作条
    @State private var showRouteOverview = false
    @State private var overviewCountdown = 13
    @State private var overviewPinned = false
    @State private var overviewTask: Task<Void, Never>?
    @State private var tipRoad: String?
    /// v1.81 地点所属区域（AOI）：名称 + 多边形（地图蓝虚线框住）
    @State private var tipAoiName: String?
    @State private var tipPolygon: [CLLocationCoordinate2D]?
    /// v1.81 地点查看时地图强制北向上
    @State private var northUpTick = 0
    /// 高德搜索 Key 输入弹窗
    @State private var showAmapKeyInput = false
    @State private var amapKeyInput = ""
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
    /// v2.15 长按「违法拍照点」弹出的专用卡片：只做删除 / 更改类型 / 分享
    @State private var cameraPoiCard: Poi?
    /// 更改拍照类型的选择框
    @State private var showCameraKindPicker = false
    /// 删除拍照点前的二次确认
    @State private var showCameraPoiDeleteConfirm = false
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
    /// v1.82 "我的-收藏"搜索过滤
    @State private var favSearch = ""
    /// v1.97 "我的-常用地点"编辑目标（点铅笔后进入搜索选点，卡片收藏键确认）
    @State private var slotTarget: CommonPlaceSlot?
    /// v2.19 途经点选择模式（点规划卡"+"后搜索选点，卡片收藏键"设为途经点"确认）
    @State private var waypointSelecting = false
    /// v1.86 行程卡自动收起任务（出现 5 秒后回首页）
    @State private var tripAutoDismissTask: Task<Void, Never>?
    /// v1.87 天气动画按外观模式取色（浅色背景用深色雨丝/雪花，保证可见）
    @Environment(\.colorScheme) private var colorScheme
    /// 语音包设置页弹出（"我的"→语音播报）
    @State private var showVoiceSettings = false
    /// v1.99 足迹 / 离线地图 / 组队 面板
    @State private var showFootprints = false
    @State private var showOfflineMaps = false
    @State private var showTeamRide = false
    /// v1.99 搜索结果排序（0 距离 / 1 名称）
    @State private var tipSort = 0
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
                AnyView(mapLayer)
                // v1.81.4 全屏天气动画（高德同款）：下雨雨丝/下雪飘雪，透明覆盖不拦截手势
                // v1.86 仅初始地图页/导航态渲染：沉浸模式与巡航模式暂停（省电、不挡视野）
                if !uiHidden && !model.cruiseMode {
                    AnyView(weatherFX)
                }
                // v1.92 省电调暗：仅非导航态盖轻黑罩（OLED 上省电），
                // 导航中不再遮挡——骑行户外阳光 + 头盔镜片下，地图变暗会看不清路口与电子眼
                if model.powerSaving && !model.navigating {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
                // v1.66：沉浸模式（uiHidden）下隐藏全部 UI，只留当前定位按钮
                if !uiHidden {
                    // v1.85 指南针/GPS 默认位置统一上移到最高处（屏幕顶部，与导航/巡航/初始各界面一致）
                    // v1.86 全览时一并隐藏（贴高德全览界面），取消全览恢复
                    if !showRouteOverview {
                        AnyView(compassOverlay)
                        // v1.90 顶部居中道路名胶囊（高德式：导航中显示当前道路名，一目了然）
                        if model.navigating { AnyView(roadNamePill) }
                        // 规划态顶部路线胶囊（"我的位置 → 目的地"，点击重新搜索）
                        DraggableFloat(key: "routebar", defaultPos: CGPoint(x: 0.5, y: 0.10)) { AnyView(routeBarOverlay) }
                        // 地图缩放 + / - 按钮（含当前定位按钮）
                        // v1.99 默认位置改为搜索框右上方（底部搜索卡上沿右侧），符合常见地图习惯；
                        // 地点卡出现时暂时收起，避免整组压在卡片上
                        if tapPlace == nil && tipCard == nil {
                            DraggableFloat(key: "zoom", defaultPos: CGPoint(x: 0.885, y: 0.655)) { AnyView(zoomOverlay) }
                        }
                        // v2.01 右上角比例尺（随缩放实时变化；原 GPS 按钮已移除）
                        AnyView(scaleOverlay)
                    }
                    // v1.97 常用地点设置提示条（从"我的"点铅笔后回到地图时显示）
                    if slotTarget != nil && !model.navigating {
                        AnyView(slotEditBanner)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .padding(.top, 6)
                    }
                } else if !model.navigating {
                    // 沉浸模式：仅保留右下角当前定位按钮
                    AnyView(locateButtonOnly)
                }
                // v2.04 接近电警横幅：沉浸/导航状态下也要显示（安全提醒优先于界面整洁）
                if let alert = model.cameraAlert {
                    AnyView(cameraAlertBanner(alert))
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 96)
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .allowsHitTesting(false)
                        .zIndex(20)
                }
                // 导航中悬浮退出按钮（仅上下移动；v1.85 取消左滑删除，全览时隐藏，取消全览恢复）
                if model.navigating && !showRouteOverview {
                    // v2.02 贴底摆放（高德导航卡片位置）；key 变更以清掉旧版记住的偏高位置
                    DraggableFloat(key: "exitnav2", defaultPos: CGPoint(x: 0.5, y: 0.925), lockX: true) { AnyView(exitNavOverlay) }
                }
                // v1.81.4 导航全览操作条（高德同款：固定全览 / 取消全览(13s)）
                if model.navigating && showRouteOverview {
                    DraggableFloat(key: "overviewbar", defaultPos: CGPoint(x: 0.5, y: 0.70), lockX: true) { AnyView(routeOverviewBar) }
                }
                // v1.63 导航态左侧竖排：刷新 / 极简（可拖动；v1.84 全览时隐藏）
                if model.navigating && !showRouteOverview {
                    DraggableFloat(key: "navside", defaultPos: CGPoint(x: 0.07, y: 0.50)) { AnyView(navSideOverlay) }
                }
                // v1.90 导航数据已全部合并进底部白底卡片（分钟/公里/红绿灯/抓拍/速度/道路/预计到达），
                // 移除顶部重复的大数字条 navTopBar，避免信息分散（高德同款单卡片式导航状态）
                // v1.84 巡航模式顶部卡片（白底：速度 + 最近拍照点）
                if model.cruiseMode && !model.navigating {
                    AnyView(cruiseCard)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                // v1.66：沉浸模式下底部内容隐藏（v2.02 导航中同样可收起，导航卡单独渲染不受影响）
                if !uiHidden {
                    AnyView(bottomOverlay)
                } else if !model.navigating {
                    // v2.16 沉浸态长按：整套 UI 继续隐藏，只把"长按出来的那张卡"亮出来
                    // （旧版沉浸态把 bottomOverlay 整块藏了，长按后卡片被一起藏掉，看起来像没反应）
                    AnyView(immersiveCardLayer)
                }
                // v1.85 行程卡显示期间：轻点卡片以外任意位置回首页（透明拦截层，卡片之上渲染在下方）
                if model.tripSummary != nil {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture { haptic(); dismissTripAndReset() }
                }
                // v1.81.4 本次行程卡：结束导航后显示（白底卡，可上下移动；v1.85 保留左滑关闭，另支持轻点卡片外回首页）
                if let s = model.tripSummary {
                    DraggableFloat(key: "tripsummary", defaultPos: CGPoint(x: 0.5, y: 0.62), lockX: true,
                                   deleteLabel: "删除",
                                   onSwipeLeft: { dismissTripAndReset() }) { AnyView(tripSummaryCard(s)) }
                }
                // v1.69 高德地图加载失败诊断条（黑屏根因提示 + 重试）
                if mapLoadFailed {
                    AnyView(mapLoadBanner)
                }
            } else {
                AnyView(settingsPage)
            }
            // v1.80 底部选项卡：仅"我的"页保留（导航主页已合并进底部主卡片，导航/我的按钮在卡片内）
            if !model.navigating && !uiHidden && selectedTab == 1 {
                AnyView(bottomTabBar)
            }
        }
        // v1.81.3 新一次导航开始时重置退出确认态；导航结束时清理全览态
        .onChange(of: model.navigating) { _, nv in
            if nv {
                showExitConfirm = false
                tapPlace = nil          // v1.95 进入导航时收起地点卡，避免和导航卡叠在一起
                slotTarget = nil        // v1.97 开始导航即退出常用地点设置态
            } else {
                endRouteOverview()
            }
        }
        // v1.97 开始规划路线（点卡片"路线"）时也退出常用地点设置态
        .onChange(of: model.routeChoices.isEmpty) { _, empty in
            if !empty {
                slotTarget = nil
                // v2.16 沉浸态下点了"导航"：路线卡不在沉浸层里渲染，
                // 必须先把整套 UI 恢复，否则点完像没反应
                if uiHidden { withAnimation(.easeOut(duration: 0.2)) { uiHidden = false } }
            }
        }
        // v2.16 同理：沉浸态下点了"搜周边"，类别结果条要能看到
        .onChange(of: model.categoryResults.isEmpty) { _, empty in
            if !empty, uiHidden { withAnimation(.easeOut(duration: 0.2)) { uiHidden = false } }
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
        // v1.99 足迹 / 离线地图 / 组队
        .sheet(isPresented: $showFootprints) {
            FootprintSheet(store: footprints) { f in
                showFootprints = false
                selectedTab = 0
                model.footprintPreview = f.coordinateList
                model.status = "足迹回放：\(f.destName) · \(f.distanceText)"
            }
        }
        .sheet(isPresented: $showOfflineMaps) {
            OfflineMapSheet(manager: offline, model: model)
        }
        .sheet(isPresented: $showTeamRide) {
            TeamRideSheet(team: team)
        }
        .sheet(item: $editPoi) { p in
            PoiEditSheet(mode: .edit, poi: p) { type, name, lat, lon, r in
                model.updatePoi(id: p.id, type: type, name: name, lat: lat, lon: lon, radiusM: r)
            }
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
        // v2.15 长按拍照点 →「更改」：四种类型（顺序按骑手最常被拍的来排）
        .confirmationDialog("更改拍照类型", isPresented: $showCameraKindPicker) {
            ForEach(cameraKindsForPicker, id: \.self) { t in
                Button(cameraKindTitle(t)) { changeCameraPoiType(t) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(cameraPoiCard.map { "当前：\(cameraKindTitle($0.type))" } ?? "")
        }
        // v2.15 长按拍照点 →「删除」：不可撤销，先确认一次
        .confirmationDialog("删除这个拍照点？", isPresented: $showCameraPoiDeleteConfirm) {
            Button("删除", role: .destructive) { deleteCameraPoi() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后不再提醒，且无法恢复")
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
            // v1.85 指南针/GPS 默认位置上移到最高处：仅一次重置旧拖动记忆（之后用户拖动仍会持久化）
            if !UserDefaults.standard.bool(forKey: "uiPosV185Applied") {
                for k in ["compass.x", "compass.y", "zoom.x", "zoom.y"] {
                    UserDefaults.standard.removeObject(forKey: k)
                }
                UserDefaults.standard.set(true, forKey: "uiPosV185Applied")
            }
            // v1.90 GPS 上移到最上方：仅一次重置 gps 旧拖动记忆（之后用户拖动仍会持久化）
            if !UserDefaults.standard.bool(forKey: "uiPosV190Applied") {
                for k in ["gps.x", "gps.y"] {
                    UserDefaults.standard.removeObject(forKey: k)
                }
                UserDefaults.standard.set(true, forKey: "uiPosV190Applied")
            }
        }
        // v1.86 行程卡出现 5 秒后自动收起回首页（高德式；用户已操作则取消）
        .onChange(of: model.tripSummary != nil) { _, showing in
            tripAutoDismissTask?.cancel()
            if showing {
                tripAutoDismissTask = Task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    await MainActor.run {
                        if model.tripSummary != nil {
                            dismissTripAndReset()
                        }
                    }
                }
            }
        }
        // 切回前台时再检查剪贴板（微信复制位置 → 打开摩卫士自动识别）
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                model.checkClipboard()
            } else if phase == .background {
                // v1.92 进后台才做瓦片缓存清理（IO 放到后台，前台滚动地图不卡）
                AmapTileRenderer.trimDiskNow()
            }
        }
        // 导航中保持屏幕常亮（骑行看导航不被锁屏；退出导航恢复）
        .onChange(of: model.navigating) { nav in
            UIApplication.shared.isIdleTimerDisabled = nav
            if nav { uiHidden = false } // v1.66：进入导航自动退出沉浸模式，恢复导航 UI
        }
        // v1.81.4：行程总结改为底部行程卡（结束导航后显示，非弹窗）
        // 预览点变化（含在线搜索兜底）→ 同步"导航去此处"按钮
        .onChange(of: model.searchPreview) { p in
            if let p = p {
                goHereLabel = "导航去此处"
                goHereName = model.searchPreviewName
                goHereLat = p.latitude
                goHereLon = p.longitude
            }
        }
        // v2.12 外观三段式：自动跟随系统 / 强制浅色 / 强制深色
        // 放在根视图上，sheet、设置页、地图底图（MapView 读同一个 colorScheme）一起生效
        .preferredColorScheme((AppearanceMode(rawValue: appearanceMode) ?? .auto).colorScheme)
    }

    /// 地图全屏层（高德式：地图在上，搜索框下置）
    private var mapLayer: some View {
        MapViewRepresentable(
            pois: model.pois,
            userLocation: model.currentLocation,
            route: model.route,
            waypointMarks: model.waypoints.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) },
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
            overviewTick: model.overviewTick,
            cruise: model.cruiseMode,
            cruiseTick: model.cruiseTick,
            zoomInTick: model.zoomInTick,
            zoomOutTick: model.zoomOutTick,
            pitchDeg: model.pitchDeg,
            onScaleChange: { t in
                // v2.02 写进 AppModel（@Published）而不是 View 的 @State：
                // 地图回调在 SwiftUI 更新周期内改 @State 会触发下一轮 updateUIView → 循环卡死
                model.setScale(t)
            },
            onLongPress: { coord in
                // v2.02 长按只做一件事：出地点卡（添加违法拍照已移到卡片最下方）
                showTapPlace(coord)
            },
            onPoiLongPress: { p in
                // v2.15：长按「违法拍照点」走专用卡片（删除 / 更改类型 / 分享），
                // 其它点位仍用原来的「点位操作」菜单（导航 / 收藏 / 编辑 / 删除）
                if p.type.isCamera {
                    haptic()
                    cameraPoiCard = p
                } else {
                    poiManagePoi = p
                }
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
                // v1.96 轻点地点名文字 → 直接弹地点介绍卡（原先是只设"去这里"预览，点了几乎没反应）
                // v2.16 沉浸态下不再强制退出沉浸：卡片单独渲染，其余 UI 保持隐藏
                showTapPlace(CLLocationCoordinate2D(latitude: pl.lat, longitude: pl.lon), seed: pl.name)
            },
            onPlaceLongPress: { pl in
                // v2.02 长按地点名标签 → 同一张地点卡（统一入口）
                showTapPlace(CLLocationCoordinate2D(latitude: pl.lat, longitude: pl.lon), seed: pl.name)
            },
            onCategorySelect: { r in
                model.planRoute(to: r.name, lat: r.lat, lon: r.lon)
                model.clearCategory()
            },
            onMapTap: { coord in
                // v1.96 轻点地图：
                //   命中地点名文字 → 地点介绍卡（在 MapView 里已派发 onPlaceSelect）
                //   点到非地点区域 → 收起所有卡片并隐藏全部界面（再轻点一次恢复）
                // v2.02 导航中轻点也收起浮层（导航卡保留），再轻点一次恢复
                // v1.99 足迹回放中：轻点地图先退出回放
                if !model.footprintPreview.isEmpty {
                    model.footprintPreview = []
                    model.status = "已退出足迹回放"
                    return
                }
                if quickPickMode {
                    pendingQuickCoord = coord
                    quickName = placeNameNear(coord)
                    showQuickNameAlert = true
                    return
                }
                // 沉浸态下轻点＝恢复界面（否则隐藏 UI 后没有出口）
                // v2.16：若此时正亮着长按卡，先把卡收掉（沉浸保持），再点一次才恢复整套 UI
                if uiHidden {
                    if tapPlace != nil || cameraPoiCard != nil || tipCard != nil {
                        cameraPoiCard = nil
                        closeTapPlace()
                        closeTipCard()
                        return
                    }
                    withAnimation(.easeOut(duration: 0.2)) { uiHidden = false }
                    return
                }
                // v1.98 规划态轻点地图：退出规划回首页（清路线、恢复底部主卡），
                // 不再弹地点卡——旧版在这里会叠一张地点介绍卡，挡住"回首页"的预期
                if !model.routeChoices.isEmpty {
                    haptic()
                    closeRoutePlan()
                    model.status = "已退出路线规划"
                    return
                }
                // v2.02 轻点 = 收起浮层，长按 = 出地点卡（两条路径职责分开，不再互相顶替）
                hideAllOnBlankTap()
            },
            onRouteChoiceTap: { idx in
                guard idx >= 0, idx < model.routeChoices.count else { return }
                haptic()
                model.selectedRouteIdx = idx
                model.applyRouteChoice(model.routeChoices[idx])
            },
            minimal: minimalMap,
            reloadTick: reloadTick,
            northUpTick: northUpTick,
            tipPolygon: tipPolygon,
            tipFit: tipCard.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) },
            trafficSpans: model.trafficSpans,
            footprint: model.footprintPreview,
            teamMembers: team.others,
            onMapLoad: { ok, err in
                if ok {
                    // v2.14 相同值不再赋值：@State 赋相同值同样会让 body 全量重算
                    if mapLoadFailed { mapLoadFailed = false }
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
            },
            // v2.04 官方电警点位图层（关闭时传空数组，地图上立即消失）
            cameraMarks: camStore.layerOn ? camStore.all : [],
            hotCameraId: model.hotCameraId,
            onCameraMoved: { id, lat, lon in
                // v2.20 电警点手动拖动 → 落点写回仓库（持久化，重启仍生效）
                camStore.adjust(id: id, lat: lat, lon: lon)
                if let c = camStore.all.first(where: { $0.id == id }) {
                    model.status = "已校准「\(c.name)」位置"
                }
            },
            waypointMarks: model.waypoints.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        )
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { dismissKeyboard() }
    }

    /// v1.95 全屏天气动画（Apple 天气同款分层粒子）
    /// 透明 Canvas 覆盖地图，不拦截任何手势；沉浸模式与巡航模式暂停（省电、不挡视野）
    private var weatherFX: some View {
        Group {
            if let code = model.weatherCode {
                WeatherOverlay(code: code, lightMode: colorScheme == .light)
            }
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

    /// v2.04 接近官方电警的横幅（红底白字，与地图上放大的那个点位一一对应）
    private func cameraAlertBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "camera.fill")
                .font(.system(size: 15, weight: .black))
            Text(text)
                .font(.system(size: 14, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(red: 0.86, green: 0.15, blue: 0.18), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 6, y: 3)
    }

    /// v2.01 右上角比例尺：白底半透明胶囊 + 一段 58pt 比例尺线（数值随缩放变化）
    private var scaleOverlay: some View {
        VStack {
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(model.scaleText)
                        .font(.caption2.bold())
                        .foregroundStyle(.primary)
                    ZStack(alignment: .bottomTrailing) {
                        // 比例尺线（固定 58pt，右侧加两个端点竖线）
                        Rectangle()
                            .fill(Color.primary.opacity(0.75))
                            .frame(width: 58, height: 2)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(Color.primary.opacity(0.75))
                                    .frame(width: 2, height: 7)
                            }
                            .overlay(alignment: .trailing) {
                                Rectangle().fill(Color.primary.opacity(0.75))
                                    .frame(width: 2, height: 7)
                            }
                    }
                    .frame(width: 58, height: 7)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            }
            Spacer()
        }
        .padding(.top, 8)
        .padding(.trailing, 14)
        .allowsHitTesting(false)
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

    /// v1.97 "我的"页：省电置顶 → 常用地点（家/公司/收藏/+/自定义 合并）→ 搜索设置 → 关于（语音包并入）
    private var settingsPage: some View {
        NavigationStack {
            List {
                powerSection
                appearanceSection
                commonPlacesSection
                rideSection
                dataSection
                searchKeySection
                aboutSection
            }
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 8)
            }
        }
    }

    // MARK: - 我的页分区（v1.97 顺序调整）

    /// 省电模式（放到最上方）
    private var powerSection: some View {
        Section {
            Toggle("省电模式", isOn: $powerSaveEnabled)
                .onChange(of: powerSaveEnabled) { _, _ in
                    model.applyPowerSaving()
                }
        } header: {
            Text("省电")
        } footer: {
            Text("电量低于 20% 或系统低电量模式时，自动降低定位频率并调暗地图节省电量；恢复后自动还原。")
        }
    }

    /// v2.12 外观：自动 / 浅色 / 深色（放在省电下方，三段式）
    private var appearanceSection: some View {
        Section {
            Picker(selection: Binding(
                get: { AppearanceMode(rawValue: appearanceMode) ?? .auto },
                set: { appearanceMode = $0.rawValue })) {
                ForEach(AppearanceMode.allCases) { m in
                    Text(m.title).tag(m)
                }
            } label: {
                Label("外观", systemImage: "circle.lefthalf.filled")
            }
            .pickerStyle(.segmented)
        } header: {
            Text("显示")
        } footer: {
            Text("自动跟随系统深浅色；手动切换立即生效。导航中地图始终使用深色底图，保证路口与电子眼清晰可辨。")
        }
    }

    /// 常用地点：家 / 公司 / 收藏 / + / 自定义 合并为同一组
    private var commonPlacesSection: some View {
        Section {
            commonPlaceRow(icon: "house.fill", title: "家",
                           place: model.commonPlace(for: .home), slot: .home)
            commonPlaceRow(icon: "briefcase.fill", title: "公司",
                           place: model.commonPlace(for: .work), slot: .work)
            ForEach(favoriteEntries, id: \.key) { f in
                favoriteRow(f)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            model.removeFavorite(lat: f.lat, lon: f.lon)
                            model.status = "已删除收藏「\(displayName(f.name))」"
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }
            // "+"新增：走首页搜索联想选点，新选项排在收藏项与"+"下方
            Button {
                haptic()
                beginSlotEdit(.newCustom)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.blue)
                        .frame(width: 22)
                    Text("添加常用地点")
                        .foregroundStyle(.blue)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ForEach(model.quickPois) { qp in
                customRow(qp)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            model.removeQuickPoi(id: qp.id)
                            model.status = "已删除常用地点「\(displayName(qp.name))」"
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }
        } header: {
            VStack(alignment: .leading, spacing: 6) {
                Text("常用地点")
                // 收藏量多时才出搜索框，避免挤占列表
                if model.favorites.count > 4 {
                    TextField("搜索收藏", text: $favSearch)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                        .textInputAutocapitalization(.never)
                }
            }
        } footer: {
            Text("点右侧铅笔可重新搜索选择地点；除「家」「公司」和「添加常用地点」外，其余选项左滑可删除。")
        }
    }

    /// v1.99 骑行偏好：播报分级 + 摩托车优先（避开高速/高架）
    private var rideSection: some View {
        Section {
            Picker(selection: Binding(
                get: { model.speechLevel },
                set: { model.speechLevel = $0 })) {
                ForEach(SpeechLevel.allCases) { lv in
                    Text(lv.title).tag(lv.rawValue)
                }
            } label: {
                Label("语音播报", systemImage: "speaker.wave.2.fill")
            }
            .pickerStyle(.segmented)

            Toggle(isOn: Binding(
                get: { model.avoidHighway },
                set: { model.avoidHighway = $0 }
            )) {
                Label("避开高速/高架", systemImage: "road.lanes")
            }

            if !model.riderRisks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.riderRisks.prefix(3)) { r in
                        HStack(spacing: 6) {
                            Image(systemName: r.kind.icon)
                                .foregroundStyle(r.kind.motoBlocked ? .red : .orange)
                            Text("\(r.kind.title)·\(r.roadName)")
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text("\(r.fromM / 1000)km 起")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("骑行偏好")
        } footer: {
            Text("播报：简洁只报转弯；标准加电子眼；详细再加路名与剩余里程。开启「避开高速/高架」后，规划会优先选择禁摩风险更少的方案，导航到风险路段前会语音提醒。")
        }
    }

    /// v1.99 足迹 / 离线地图 / 组队
    private var dataSection: some View {
        Section("骑行数据") {
            Button {
                haptic()
                showFootprints = true
            } label: {
                HStack {
                    Label("足迹", systemImage: "figure.run.circle")
                    Spacer()
                    Text("\(footprints.items.count) 条 · \(distanceText(footprints.totalDistanceM))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                haptic()
                showOfflineMaps = true
            } label: {
                HStack {
                    Label("离线地图", systemImage: "square.and.arrow.down")
                    Spacer()
                    Text(offline.packs.isEmpty ? "未下载" : offline.totalText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                haptic()
                showTeamRide = true
            } label: {
                HStack {
                    Label("组队骑行", systemImage: "person.2.wave.2")
                    Spacer()
                    Text(team.active ? "队伍 \(team.code) · \(team.members.count) 人" : "未组队")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func distanceText(_ m: Int) -> String {
        m >= 1000 ? String(format: "%.1f km", Double(m) / 1000) : "\(m) m"
    }

    /// v2.12 Key 展示：只露首尾 4 位，中间打点（避免整串 Key 明晃晃挂在界面上）
    private var amapKeyMask: String {
        let k = model.amapKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return "未设置" }
        guard k.count > 10 else { return k }
        return "\(k.prefix(4))…\(k.suffix(4))"
    }

    /// 搜索 Key 设置
    private var searchKeySection: some View {
        Section("搜索设置") {
            Button {
                amapKeyInput = model.amapKey
                showAmapKeyInput = true
            } label: {
                HStack {
                    Label("高德搜索 Key", systemImage: "key")
                    Spacer()
                    Text(amapKeyMask)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
    }

    /// 关于（v1.97 语音包并入）
    private var aboutSection: some View {
        Section("关于") {
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
                Text("v2.09")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            Button {
                amapKeyInput = model.amapKey
                showAmapKeyInput = true
            } label: {
                HStack {
                    Label("高德搜索 Key", systemImage: "key.horizontal")
                    Spacer()
                    Text(amapKeyMask)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - 常用地点行

    /// 家 / 公司：点主体弹地点卡，点铅笔进入改点
    private func commonPlaceRow(icon: String, title: String,
                                place: AppModel.SavedPlace?, slot: CommonPlaceSlot) -> some View {
        HStack(spacing: 2) {
            Button {
                haptic()
                if let p = place {
                    openCommonPlace(name: p.name, lat: p.lat, lon: p.lon)
                } else {
                    beginSlotEdit(slot)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .foregroundStyle(.blue)
                        .frame(width: 22)
                    Text(title)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text(place.map { displayName($0.name) } ?? "未设置")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            editSlotButton(slot)
        }
    }

    /// 收藏行
    private func favoriteRow(_ f: FavoriteEntry) -> some View {
        HStack(spacing: 2) {
            Button {
                haptic()
                openCommonPlace(name: f.name, lat: f.lat, lon: f.lon)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.orange)
                        .frame(width: 22)
                    Text(displayName(f.name))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("收藏")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            editSlotButton(.favorite(f.key))
        }
    }

    /// 自定义常用地点行
    private func customRow(_ qp: AppModel.QuickPoi) -> some View {
        HStack(spacing: 2) {
            Button {
                haptic()
                openCommonPlace(name: qp.name, lat: qp.lat, lon: qp.lon)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundStyle(.orange)
                        .frame(width: 22)
                    Text(displayName(qp.name))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("常用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            editSlotButton(.custom(qp.id))
        }
    }

    /// 每行末尾的编辑铅笔
    private func editSlotButton(_ slot: CommonPlaceSlot) -> some View {
        Button {
            haptic()
            beginSlotEdit(slot)
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.subheadline)
                .foregroundStyle(.blue)
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }

    /// v1.97 收藏项（收藏时间倒序 + 搜索过滤）
    private var favoriteEntries: [FavoriteEntry] {
        model.favorites.compactMap { key, name -> FavoriteEntry? in
            let parts = key.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { return nil }
            return FavoriteEntry(key: key, name: name, lat: parts[0], lon: parts[1],
                                 time: model.favoriteTimes[key] ?? 0)
        }
        .filter { favSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(favSearch) }
        .sorted { $0.time > $1.time }
    }

    /// 点常用地点选项：切回地图页，定位到该点并弹出地点卡（不直接开始导航）
    private func openCommonPlace(name: String, lat: Double, lon: Double) {
        selectedTab = 0
        slotTarget = nil
        searchFocused = false
        searchExpanded = false
        showSuggestions = false
        uiHidden = false
        showTipCard(name: name, lat: lat, lon: lon, sub: "常用地点")
    }

    /// 点铅笔：回到首页搜索（联想 + 地图选点），选定后在卡片收藏键确认
    private func beginSlotEdit(_ slot: CommonPlaceSlot) {
        haptic()
        slotTarget = slot
        selectedTab = 0
        uiHidden = false
        tapPlace = nil
        tipCard = nil
        closeRoutePlan()
        model.clearPreview()
        onlineTips = []
        let cur = model.commonPlace(for: slot)
        searchText = cur.map { displayName($0.name) } ?? ""
        showSuggestions = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        searchExpanded = false
        showSearchField = true
        model.status = "设置「\(slot.title)」：搜索或点地图地点，再点地点卡收藏键确认"
        // 等搜索框挂载后再聚焦，键盘/联想才会弹出
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard slotTarget != nil else { return }
            searchFocused = true
            // 搜索框刚挂载时 onChange 不会补触发，这里手动拉一次联想
            let q = searchText.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { return }
            showSuggestions = true
            Task {
                let tips = await model.amapInputTips(q)
                if searchText.trimmingCharacters(in: .whitespaces) == q {
                    onlineTips = sortedByDistance(tips)
                }
            }
        }
    }

    /// 地点卡收藏键（编辑态）：把当前地点写入所点选项；再点一次则取消并删除该选项
    private func toggleSlotAssignment(name: String, lat: Double, lon: Double) {
        // v2.19 途经点选择模式：同一地点再点一次 = 取消；加完自动退出选择态
        if waypointSelecting {
            if let existing = model.waypoints.first(where: { nearSamePlace($0, lat, lon) }) {
                model.removeWaypoint(existing)
            } else {
                model.addWaypoint(name: name, lat: lat, lon: lon)
            }
            waypointSelecting = false
            searchFocused = false
            dismissKeyboard()
            return
        }
        guard let slot = slotTarget else { return }
        haptic()
        if model.commonPlaceMatches(slot, lat: lat, lon: lon) {
            let removed = model.clearCommonPlace(slot)
            model.status = removed ? "已删除「\(slot.title)」选项" : "已取消「\(slot.title)」"
        } else {
            model.assignCommonPlace(slot, name: name, lat: lat, lon: lon)
            model.status = "已将「\(displayName(name))」设为\(slot.title)"
            // 收藏/自定义项改点后 key 会变，编辑目标跟随，便于再次点击取消
            switch slot {
            case .favorite:
                slotTarget = .favorite("\(lat),\(lon)")
            case .custom, .newCustom:
                if let id = model.quickPois.first(where: { abs($0.lat - lat) < 1e-9 && abs($0.lon - lon) < 1e-9 })?.id {
                    slotTarget = .custom(id)
                }
            case .home, .work:
                break
            }
        }
    }

    /// 卡片收藏键文字（编辑态显示"设为家/设为公司/设为常用/取消"）
    private func favoriteActionTitle(lat: Double, lon: Double) -> String {
        // v2.19 途经点选择模式：卡片键显示"设为途经点 / 取消途经"
        if waypointSelecting {
            return model.waypoints.contains(where: { nearSamePlace($0, lat, lon) }) ? "取消途经" : "设为途经点"
        }
        guard let slot = slotTarget else { return "收藏" }
        if model.commonPlaceMatches(slot, lat: lat, lon: lon) {
            switch slot {
            case .home: return "取消家"
            case .work: return "取消公司"
            default: return "取消"
            }
        }
        switch slot {
        case .home: return "设为家"
        case .work: return "设为公司"
        case .favorite: return "改到此地"
        case .custom, .newCustom: return "设为常用"
        }
    }

    /// v2.19 判断途经点与给定坐标是否为同一地点（20 米内）
    private func nearSamePlace(_ wp: RouteWaypoint, _ lat: Double, _ lon: Double) -> Bool {
        model.distanceM(CLLocationCoordinate2D(latitude: wp.lat, longitude: wp.lon),
                        CLLocationCoordinate2D(latitude: lat, longitude: lon)) < 20
    }

    /// 编辑态下该地点是否就是选项当前地点（星星实心）
    private func slotStarOn(lat: Double, lon: Double) -> Bool {
        guard let slot = slotTarget else { return false }
        return model.commonPlaceMatches(slot, lat: lat, lon: lon)
    }

    /// v1.97 常用地点编辑提示条
    private var slotEditBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
                .foregroundStyle(.blue)
            Text("设置「\(slotTarget?.title ?? "")」：选点后点卡片收藏键")
                .font(.caption.bold())
                .foregroundStyle(.primary)
                .lineLimit(1)
            Button {
                haptic()
                slotTarget = nil
                searchFocused = false
                dismissKeyboard()
                selectedTab = 1          // 完成后退回"我的"，直接看到更新后的常用地点列表
                model.status = "已退出常用地点设置"
            } label: {
                Text("完成")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.blue, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(.systemBackground).opacity(0.96), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.blue.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .fixedSize()
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
                            Text(model.originName)
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
        // v1.86 巡航模式下隐藏底部搜索卡（巡航视野干净，退出巡航恢复）
        ZStack {
            if !model.navigating && !model.cruiseMode {
                if cameraPoiCard != nil || tapPlace != nil || tipCard != nil {
                    AnyView(poiCardStack)
                } else if !model.routeChoices.isEmpty {
                    // 路线规划卡：方案选项 + 开始导航 合并为一张白底卡（样式同地点卡），默认贴底
                    // v1.84 仅上下移动，除非左拉删除（左拉时允许左右移动触发删除）
                    DraggableFloat(key: "routeplan", defaultPos: CGPoint(x: 0.5, y: 0.90), lockX: true,
                                   deleteLabel: "删除",
                                   onSwipeLeft: { closeRoutePlan() }) { AnyView(routePlanCard) }
                } else {
                    DraggableFloat(key: "categorybar", defaultPos: CGPoint(x: 0.5, y: 0.42)) { AnyView(categoryBar) }
                    // v1.99 移除地图上浮动的"历史搜索"横条：搜索框聚焦时面板内已有历史列表，
                    // 地图上再挂一条既挡视线又重复
                }
                // 搜索主卡：地点卡或路线规划卡出现时隐藏；仅上下移动
                if tapPlace == nil && tipCard == nil && cameraPoiCard == nil && model.routeChoices.isEmpty {
                    DraggableFloat(key: "bottommain", defaultPos: CGPoint(x: 0.5, y: 0.88), lockX: true) { AnyView(bottomMainCard) }
                }
            } else {
                // v1.65：转向/速度/距离时间已合并到顶部 navTopBar，底部仅留路口放大 + 抓拍条
                DraggableFloat(key: "turnahead", defaultPos: CGPoint(x: 0.5, y: 0.70)) { AnyView(turnAheadCard) }
                DraggableFloat(key: "snapalert", defaultPos: CGPoint(x: 0.5, y: 0.80)) { AnyView(snapAlertCard) }
            }
        }
    }

    /// 长按/轻点出来的卡（拍照点卡 / 地点卡 / 提示点卡）——三者互斥，只出一张。
    /// v2.16 抽成独立视图，好让「沉浸态」也能单独把这张卡亮出来而不带其它 UI。
    @ViewBuilder private var poiCardStack: some View {
        if let cp = cameraPoiCard {
            // v2.15 长按违法拍照点：专用卡（分享在右上角，下面只有「更改类型」「删除」）
            DraggableFloat(key: "campoicard", defaultPos: CGPoint(x: 0.5, y: 0.66), lockX: true,
                           deleteLabel: "关闭",
                           onSwipeLeft: { cameraPoiCard = nil }) { AnyView(cameraPoiCardView(cp)) }
        } else if let tp = tapPlace {
            // v1.95 轻点地图地点卡：与搜索地点卡同位置、同样式，左滑或点×关闭
            DraggableFloat(key: "tapplace", defaultPos: CGPoint(x: 0.5, y: 0.66), lockX: true,
                           deleteLabel: "关闭",
                           onSwipeLeft: { closeTapPlace() }) { AnyView(tapPlaceCard(tp)) }
        } else if let t = tipCard {
            DraggableFloat(key: "tipcard", defaultPos: CGPoint(x: 0.5, y: 0.66), lockX: true,
                           deleteLabel: "删除",
                           onSwipeLeft: { closeTipCard() }) { AnyView(tipInfoCard(t)) }
        }
    }

    /// v2.16 沉浸态卡片层：沉浸模式下长按地图（或点地点名）依然要出完整卡片，
    /// 但搜索卡、类别条、底部导航按钮一律不恢复——骑手不被打断视野。
    @ViewBuilder private var immersiveCardLayer: some View {
        ZStack {
            AnyView(poiCardStack)
        }
    }

    /// v1.81.3 左滑关闭地点信息卡（搜索主卡自动恢复）
    private func closeTipCard() {
        tipCard = nil
        tipRoad = nil
        tipAoiName = nil
        tipPolygon = nil
    }

    // MARK: - v1.95 轻点地图 → 地点介绍卡

    /// 关闭地点介绍卡
    private func closeTapPlace() {
        tapPlace = nil
    }

    /// 轻点地点名文字：先用本地名称出卡（不等网络），再异步替换为高德解析结果
    /// - Parameter seed: 已知名称（点地点标签时传入标签名）；为空时按坐标就近取本地标签兜底
    private func showTapPlace(_ coord: CLLocationCoordinate2D, seed known: String? = nil) {
        haptic()
        searchFocused = false      // 收起键盘，避免挡住地点卡
        model.clearPreview()       // 清掉搜索预览点，只留当前这张卡的选点
        let lat = coord.latitude
        let lon = coord.longitude
        let seed = (known?.isEmpty == false ? known! : placeNameNear(coord))
        tapPlace = TapPlaceInfo(lat: lat, lon: lon, name: seed.isEmpty ? "地图选点" : seed, loading: true)
        Task {
            let info = await model.amapTapPlace(lat: lat, lon: lon)
            guard var cur = tapPlace, cur.lat == lat, cur.lon == lon else { return }
            if let info = info {
                // 已有地点名（点标签得到的）就保留，避免高德返回的邻近 POI 把名字换掉
                if known?.isEmpty != false, !info.name.isEmpty { cur.name = info.name }
                cur.address = info.address
                cur.poiType = info.type
                cur.road = info.road
            }
            cur.loading = false
            tapPlace = cur
        }
    }

    /// v1.96 轻点非地点区域：收起全部卡片 + 隐藏所有浮层（只留右下角定位按钮），再轻点恢复
    private func hideAllOnBlankTap() {
        haptic()
        // v1.97 常用地点设置中：只收卡片，不进入沉浸模式（否则设置提示条和搜索框都会消失）
        if slotTarget != nil {
            tapPlace = nil
            tipCard = nil
            tipRoad = nil
            tipAoiName = nil
            tipPolygon = nil
            searchFocused = false
            return
        }
        tapPlace = nil
        tipCard = nil
        tipRoad = nil
        tipAoiName = nil
        tipPolygon = nil
        searchFocused = false
        withAnimation(.easeOut(duration: 0.2)) { uiHidden = true }
    }

    /// 地点介绍卡：名称 / 类型 / 地址 / 距离 / 收藏·搜周边·标记·分享 / 导航
    /// v2.15 更改类型时的候选，顺序按骑手最常被拍的来排：闯红灯 → 超速 → 压线 → 禁摩
    private var cameraKindsForPicker: [PoiType] { [.RED_LIGHT, .SPEED, .LANE, .RESTRICTION] }

    /// v2.15 四个短标签（"限行/禁摩"在骑手语境里就是"禁摩"，列表和卡片统一用短词）
    private func cameraKindTitle(_ t: PoiType) -> String {
        switch t {
        case .RED_LIGHT: return "闯红灯"
        case .SPEED: return "超速"
        case .LANE: return "压线"
        case .RESTRICTION: return "禁摩"
        default: return t.label
        }
    }

    /// v2.15 长按「违法拍照点」专用卡。
    ///
    /// 与地点卡分开做的原因：地点卡是"去看看/去那里"的语义（收藏、导航、设为家/公司），
    /// 而自己新增的拍照点只关心三件事 —— 这个点拍什么、改类型、删掉。
    /// 分享按钮保留，按用户要求放在卡片右上角（关闭键左边）。
    private func cameraPoiCardView(_ p: Poi) -> some View {
        // 用 model.pois 里的最新值，改动类型后卡片能立刻反映出来
        let live = model.pois.first(where: { $0.id == p.id }) ?? p
        let tint = Color(live.type.color)
        return VStack(spacing: 0) {
            // ── 头部：类型图标 + 名称 + 右上角分享/关闭 ──
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tint.opacity(0.14))
                    Image(systemName: live.type.alertIcon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(live.name)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(cameraKindTitle(live.type))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(tint.opacity(0.12), in: Capsule())
                        if let d = distText(live.lat, live.lon) {
                            Text(d)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 4)

                // 分享（保留原功能，位置按用户要求放到卡片右上方）
                Button {
                    haptic()
                    PlaceShare.present(PlaceShare.payload(name: live.name,
                                                          address: "",
                                                          type: live.type.label,
                                                          road: "",
                                                          lat: live.lat, lon: live.lon))
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    haptic()
                    cameraPoiCard = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()

            // ── 操作：更改类型 / 删除 ──
            HStack(spacing: 10) {
                Button {
                    haptic()
                    showCameraKindPicker = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 14, weight: .bold))
                        Text("更改类型")
                            .font(.subheadline.bold())
                    }
                    .foregroundStyle(tint)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)

                Button {
                    haptic()
                    showCameraPoiDeleteConfirm = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 14, weight: .bold))
                        Text("删除")
                            .font(.subheadline.bold())
                    }
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.black.opacity(0.06))
        )
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        .padding(.horizontal, 16)
    }

    /// v2.15 改类型：写回模型后卡片跟着刷新（Poi 是值类型，重新赋一次）
    private func changeCameraPoiType(_ t: PoiType) {
        guard let p = cameraPoiCard else { return }
        guard p.type != t else { return }
        let newName = autoRenameForType(p.name, to: t)
        model.updatePoi(id: p.id, type: t, name: newName, lat: p.lat, lon: p.lon, radiusM: p.radiusM)
        var updated = p
        updated.type = t
        updated.name = newName
        cameraPoiCard = updated
        model.status = "已改为「\(cameraKindTitle(t))」拍照"
    }

    /// 点位如果是「添加违法拍照」时自动命名的（地图新增闯红灯拍照点），
    /// 改类型时把名字里的类型一起换掉，否则会出现标题写"闯红灯"、标签标"超速"的矛盾。
    /// 用户自己改过名字的（不以"地图新增"开头）一律不动。
    private func autoRenameForType(_ name: String, to t: PoiType) -> String {
        guard name.hasPrefix("地图新增") else { return name }
        return "地图新增\(t.label)点"
    }

    /// v2.15 删除拍照点
    private func deleteCameraPoi() {
        guard let p = cameraPoiCard else { return }
        model.deletePoi(id: p.id)
        cameraPoiCard = nil
        model.status = "已删除拍照点「\(p.name)」"
    }

    private func tapPlaceCard(_ p: TapPlaceInfo) -> some View {
        // v2.02 重排：信息（名称/地址/距离）在上，操作按"次要图标 → 主按钮 → 上报"三层，
        // 「添加违法拍照」固定放在卡片最下方（原来藏在地图长按菜单里，几乎没人发现）
        let starOn = slotTarget != nil
            ? slotStarOn(lat: p.lat, lon: p.lon)
            : model.isTipFavorite(lat: p.lat, lon: p.lon)
        return VStack(spacing: 0) {
            // ── 头部：类别图标 + 名称 + 关闭 ──
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.blue.opacity(0.12))
                    Image(systemName: p.icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.blue)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(p.name)
                            .font(.headline)
                            .lineLimit(1)
                        if p.loading {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                        }
                    }
                    Text(placeSubtitle(p))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button {
                    haptic()
                    closeTapPlace()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 9)

            // ── 地址 ──
            if !p.address.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)
                    Text(p.address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }

            // ── 距离 / 骑行时间 ──
            HStack(spacing: 6) {
                if let d = distText(p.lat, p.lon) {
                    placeChip(d, icon: "location.fill")
                }
                if let mins = motoMinutes(p.lat, p.lon) {
                    placeChip("摩托约 \(mins) 分钟", icon: "clock.fill")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Divider()

            // ── 次要操作：收藏 / 搜周边 / 标记 / 分享 ──
            HStack(spacing: 0) {
                placeAction(icon: starOn ? "star.fill" : "star",
                            title: favoriteActionTitle(lat: p.lat, lon: p.lon),
                            tint: starOn ? .orange : .primary) {
                    haptic()
                    if slotTarget != nil {
                        toggleSlotAssignment(name: p.name, lat: p.lat, lon: p.lon)
                    } else {
                        model.toggleTipFavorite(name: p.name, lat: p.lat, lon: p.lon)
                    }
                }
                placeAction(icon: "magnifyingglass", title: "搜周边") {
                    haptic()
                    let tip = AppModel.AmapTip(name: p.name, sub: p.road, lat: p.lat, lon: p.lon)
                    closeTapPlace()
                    aroundSearch(tip)
                }
                placeAction(icon: "mappin.and.ellipse", title: "标记") {
                    haptic()
                    pendingMarkCoord = p.coordinate
                    markName = p.name
                    showMarkNameAlert = true
                }
                placeAction(icon: "square.and.arrow.up", title: "分享") {
                    haptic()
                    PlaceShare.present(PlaceShare.payload(name: p.name,
                                                          address: p.address,
                                                          type: p.poiType,
                                                          road: p.road,
                                                          lat: p.lat, lon: p.lon))
                }
            }
            .padding(.vertical, 7)

            // ── 主操作：路线（次要）/ 导航（主要） ──
            HStack(spacing: 10) {
                Button {
                    haptic()
                    let name = p.name
                    let lat = p.lat
                    let lon = p.lon
                    closeTapPlace()
                    model.clearPreview()
                    model.fetchRouteChoices(to: name, lat: lat, lon: lon, autoStart: false)
                } label: {
                    Text("路线")
                        .font(.subheadline.bold())
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)

                Button {
                    haptic()
                    let name = p.name
                    let lat = p.lat
                    let lon = p.lon
                    closeTapPlace()
                    model.clearPreview()
                    model.fetchRouteChoices(to: name, lat: lat, lon: lon, autoStart: true)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                            .font(.system(size: 15, weight: .bold))
                        Text("导航")
                            .font(.subheadline.bold())
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .padding(.bottom, 12)

            Divider()

            // ── 最下方：添加违法拍照（从地图长按菜单移过来，位置固定好找） ──
            Button {
                haptic()
                pendingCoord = p.coordinate
                showTypePicker = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(red: 0.86, green: 0.36, blue: 0.16))
                    Text("添加违法拍照")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("限速 · 压线 · 禁摩")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption2.bold())
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.black.opacity(0.06))
        )
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        .padding(.horizontal, 16)
    }

    /// v2.02 地点卡副标题：类型 · 道路（缺一项时只显示另一项）
    private func placeSubtitle(_ p: TapPlaceInfo) -> String {
        if p.loading && p.poiType.isEmpty && p.road.isEmpty { return "正在解析地点…" }
        let parts = [p.poiType, p.road].filter { !$0.isEmpty }
        return parts.isEmpty ? "地图选点" : parts.joined(separator: " · ")
    }

    /// v2.02 地点卡信息胶囊（距离/时间）
    private func placeChip(_ text: String, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    /// v2.02 地点卡次要操作按钮（等分四列）
    private func placeAction(icon: String, title: String, tint: Color = .primary,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(tint)
                    .frame(height: 20)
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// v1.81.3 左滑关闭路线规划卡（清掉路线方案，搜索主卡自动恢复）
    private func closeRoutePlan() {
        waypointSelecting = false
        model.route = []
        model.routePois = []
        model.routeTurns = []
        model.routeChoices = []
    }

    /// v2.19 路线规划卡（高德式）：上半 = 起点上/途经中/终点下 + 右侧(交换/加号) + 服务小卡；
    /// 下半 = 横排方案卡 + 绿色开始导航。任何改动（交换/加途经/删途经）地图同步重规划。
    private var routePlanCard: some View {
        VStack(spacing: 10) {
            routePlanHeader
            routeChoiceCards
            // v1.99 骑行风险 + 路况摘要（骑士专属）
            if !model.riderRisks.isEmpty || !model.trafficSpans.isEmpty {
                HStack(spacing: 6) {
                    if let worst = model.riderRisks.first(where: { $0.kind.motoBlocked }) ?? model.riderRisks.first {
                        Image(systemName: worst.kind.icon)
                            .font(.caption2.bold())
                            .foregroundStyle(worst.kind.motoBlocked ? .red : .orange)
                        Text(RiderAnalyzer.summary(model.riderRisks))
                            .font(.caption2)
                            .foregroundStyle(worst.kind.motoBlocked ? .red : .secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if jamCount + slowCount > 0 {
                        HStack(spacing: 3) {
                            Circle().fill(Color.red).frame(width: 6, height: 6)
                            Text("拥堵\(jamCount)").font(.caption2).foregroundStyle(.secondary)
                            if slowCount > 0 {
                                Circle().fill(Color.yellow).frame(width: 6, height: 6)
                                Text("缓行\(slowCount)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            }
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

    /// v2.19 规划卡头部（高德式）：出发点在上、途经点居中、终点在下；
    /// 右侧竖排「交换」「添加途径点」；服务小卡（加油/充电…）贴在终点下方，
    /// 点类别 → 点结果即作为途经点加入，路线立刻重新规划并穿过该点。
    private var routePlanHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 9) {
                // 出发点（绿点）
                HStack(spacing: 7) {
                    Circle().fill(Color.green).frame(width: 9, height: 9)
                    Text(model.originName)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                // 途经 1、2、3…（橙点 + x 删除）
                ForEach(Array(model.waypoints.enumerated()), id: \.element.id) { i, wp in
                    HStack(spacing: 7) {
                        Circle().fill(Color.orange).frame(width: 9, height: 9)
                        Text("途经\(i + 1)：\(wp.name)")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Button {
                            haptic()
                            model.removeWaypoint(wp)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                // 终点（红点）
                HStack(spacing: 7) {
                    Circle().fill(Color.red).frame(width: 9, height: 9)
                    Text(model.destName)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                // v2.19 服务小卡移到终点下方（同高德"驾车/公交/打车"一排的选择条）
                serviceChipsRow
            }
            // 右侧：交换 / 添加途径点
            VStack(spacing: 14) {
                Button {
                    haptic()
                    model.swapOriginDest()
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.body.bold())
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                Button {
                    haptic()
                    beginWaypointSelect()
                } label: {
                    Image(systemName: "plus")
                        .font(.body.bold())
                        .foregroundStyle(.blue)
                        .frame(width: 34, height: 34)
                        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
    }

    /// v2.19 点"+"：进入途经点选择模式——搜索或点地图地点，点地点卡「设为途经点」确认
    private func beginWaypointSelect() {
        selectedTab = 0
        uiHidden = false
        tapPlace = nil
        tipCard = nil
        onlineTips = []
        searchText = ""
        showSuggestions = false
        searchExpanded = false
        waypointSelecting = true
        showSearchField = true
        model.status = "选择途经点：搜索或点地图地点，再点卡片「设为途经点」"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard waypointSelecting else { return }
            searchFocused = true
        }
    }

    /// 拥堵段 / 缓行段数量（规划卡摘要）
    private var jamCount: Int { model.trafficSpans.filter { $0.level >= 2 }.count }
    private var slowCount: Int { model.trafficSpans.filter { $0.level == 1 }.count }

    /// v1.99 沿途服务设施快捷条：点类别搜路线附近，结果点一下即"顺路加一站"
    private var serviceChipsRow: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ServiceKind.allCases) { k in
                        Button {
                            haptic()
                            if model.serviceKindActive == k {
                                model.clearServices()
                            } else {
                                Task { await model.loadServices(k) }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: k.icon).font(.caption2)
                                Text(k.title).font(.caption2)
                            }
                            .foregroundStyle(model.serviceKindActive == k ? .white : k.tint)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(model.serviceKindActive == k ? k.tint : k.tint.opacity(0.12),
                                        in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if model.serviceKindLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在搜索沿途\(model.serviceKindActive?.title ?? "设施")…")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if !model.serviceTips.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.serviceTips.prefix(6)) { tip in
                            Button {
                                haptic()
                                model.addWaypoint(name: tip.name, lat: tip.lat, lon: tip.lon)
                                model.clearServices()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(tip.name).font(.caption).lineLimit(1)
                                            .foregroundStyle(.primary)
                                        Text(tip.sub).font(.caption2).lineLimit(1)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if tip.id != model.serviceTips.prefix(6).last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxHeight: 130)
            }
        }
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
                    Image(systemName: navTurnIcon(t))
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
                            // v1.90 电子眼图标按类型细分（红绿灯/测速/压线/限行）
                            Image(systemName: n.type.alertIcon)
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

    /// v1.81.4 车道兜底：路线无车道数据时按转向生成默认车道组（首个为需走车道，绿色高亮）
    private func navLaneFallback(_ modifier: String) -> [String] {
        switch modifier {
        case "left", "sharp left": return ["left", "straight"]
        case "right", "sharp right": return ["straight", "right"]
        case "slight left": return ["left", "straight"]
        case "slight right": return ["straight", "right"]
        case "uturn": return ["uturn"]
        default: return ["straight"]
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

    /// v2.01 转向图标（优先 modifier，高德中文 action 兜底）
    private func navTurnIcon(_ t: RouteTurn) -> String {
        if !t.modifier.isEmpty { return navTurnIcon(t.modifier) }
        let a = t.action
        if a.contains("掉头") { return "arrow.uturn.up.left" }
        if a.contains("左") { return "arrow.turn.up.left" }
        if a.contains("右") { return "arrow.turn.up.right" }
        return "arrow.up"
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
        default: break
        }
        // v2.01 高德只给中文 action（左转/右转/直行…），用它兜底
        return t.action.isEmpty ? "继续" : t.action
    }

    private func navDist(_ m: Int) -> String {
        m >= 1000 ? String(format: "%.1f公里", Double(m) / 1000.0) : "\(m)米"
    }

    /// 类别搜索结果横条（学校/医院/加油站，点击直接规划路线）
    private var categoryBar: some View {
        return Group {
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

    /// 横排方案卡（高德式并列，超过 3 条可横向滑动）
    private var routeChoiceCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
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
            .padding(.vertical, 1)
        }
        .frame(height: 86)
    }

    /// v1.87 用时格式化：<60秒"1分钟内"，<60分钟"x 分钟"，≥60分钟"x 小时y 分钟"（不出现"100分钟"）
    private func durationTxt(_ sec: Int) -> String {
        if sec < 60 { return "1分钟内" }
        let m = sec / 60
        if m < 60 { return "\(m) 分钟" }
        let h = m / 60
        let rm = m % 60
        return rm == 0 ? "\(h) 小时" : "\(h) 小时\(rm) 分钟"
    }

    /// 单张高德式方案卡：大分钟 + 里程·抓拍 + 标签，选中蓝框高亮
    private func routeChoiceCard(_ c: RouteChoice, selected: Bool) -> some View {
        let sel = selected
        let distTxt = c.distanceM < 1000
            ? "\(c.distanceM)米"
            : String(format: "%.1f公里", Double(c.distanceM) / 1000.0)
        return VStack(alignment: .leading, spacing: 3) {
            Text(durationTxt(c.durationS))
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("\(distTxt) · 抓拍\(c.poiCount)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(c.label)
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                // v2.01 选中=绿（与地图上的绿色路线一致），未选中=灰
                .background(sel ? Color(red: 0.13, green: 0.62, blue: 0.30) : Color.gray, in: Capsule())
        }
        .frame(width: 104, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(sel ? AnyShapeStyle(Color(red: 0.13, green: 0.62, blue: 0.30).opacity(0.15)) : AnyShapeStyle(.ultraThinMaterial), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(
            sel ? Color(red: 0.13, green: 0.62, blue: 0.30) : Color.gray.opacity(0.45),
            lineWidth: sel ? 2 : 0.8))
    }

    /// 地图缩放 + / - 按钮（右下角，高德式；定位按钮在放大按钮上方）
    private var zoomOverlay: some View {
        // v1.97 修复定位按钮消失：旧版内容带 150 底部内边距，配合 6% 的顶部锚点会把整组顶出屏幕；
        // 改为紧凑竖排（定位 / + / -），位置由 DraggableFloat 负责
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
                        // v1.98 巡航跟随中先退出，否则地图会被定位点立刻拉回，看着像"按钮没反应"
                        if model.cruiseMode { model.exitCruise() }
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
                        if model.cruiseMode { model.exitCruise() }
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
                    // v2.01 3D / 2D 切换（与 +/- 同一竖列，紧挨着）
                    Button {
                        haptic()
                        if model.cruiseMode { model.exitCruise() }
                        model.togglePitch()
                    } label: {
                        Text(model.pitchDeg > 0 ? "2D" : "3D")
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundStyle(model.pitchDeg > 0 ? .white : .primary)
                            .frame(width: 44, height: 44)
                            .background(model.pitchDeg > 0
                                        ? AnyShapeStyle(Color(red: 0.16, green: 0.38, blue: 1.0))
                                        : AnyShapeStyle(Color.white), in: Circle())
                            .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 1))
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                    }
                    // v2.04 官方电警点位（点开小菜单：图层 / 语音 / 看最近的）
                    Menu {
                        Toggle(isOn: $camStore.layerOn) {
                            Label("地图显示电警点位", systemImage: "camera.fill")
                        }
                        Toggle(isOn: $camStore.voiceOn) {
                            Label("接近时语音提醒", systemImage: "speaker.wave.2.fill")
                        }
                        Divider()
                        Button {
                            model.describeNearbyCameras()
                        } label: {
                            Label("看离我最近的拍照点", systemImage: "location.circle")
                        }
                        Divider()
                        Button {
                            camStore.restoreAll()
                            model.status = "已恢复全部电警点的官方公示坐标"
                        } label: {
                            Label("恢复全部官方坐标", systemImage: "arrow.uturn.backward.circle")
                        }
                        .disabled(camStore.adjustedCount == 0)
                        Divider()
                        Text("已收录 \(camStore.all.count) 个点位")
                        if camStore.adjustedCount > 0 {
                            Text("已人工校准 \(camStore.adjustedCount) 个（可长按拖动修正）")
                        }
                        Text("来源：合肥市公安局交警支队公示")
                    } label: {
                        ZStack {
                            Circle().fill(camStore.layerOn
                                          ? Color(red: 0.90, green: 0.16, blue: 0.20)
                                          : Color.white)
                            Image(systemName: camStore.layerOn ? "camera.fill" : "camera")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(camStore.layerOn ? .white : .primary)
                        }
                        .frame(width: 44, height: 44)
                        .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 1))
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                    }
        }
    }

    /// 高德式顶部导航条：剩余里程 + 时间 + 下一转向预告（<500米显示，高德顶部主条样式）
    /// v1.65 顶部导航综合条（高德式合并布局，自上而下不重叠）：
    /// 第一行：剩余距离 + 剩余时间 + 实时速度；第二行：下一转向指示（图标+距离+路名+车道）
    /// v1.84 巡航模式顶部卡片（白底，高德同款）：实时速度 + 最近拍照点，右上角×关闭巡航
    private var cruiseCard: some View {
        let cam = model.nearestCruiseCamera
        let speed = Int(model.currentSpeed * 3.6)
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "location.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.blue)
                    Text("巡航模式")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(speed)")
                        .font(.system(size: 34, weight: .heavy))
                        .foregroundStyle(.black)
                    Text("km/h")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("最近拍照")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(cam.name)
                    .font(.subheadline.bold())
                    .foregroundStyle(.black)
                    .lineLimit(1)
                Text(cam.dist > 0 ? "约\(cam.dist)米" : "附近暂无")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Button {
                haptic()
                withAnimation(.easeOut(duration: 0.2)) { model.exitCruise() }
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color(.systemGray6), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemBackground).opacity(0.97), in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .top)
        .position(x: UIScreen.main.bounds.width / 2, y: 150)
    }

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
                            Text(durationTxt(max(ns.remainS, 0)))
                                .font(.system(size: 24, weight: .heavy))
                                .foregroundStyle(.white)
                            Text("剩余时间")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        // v1.82 顶部当前道路名（高德式，随导航推进更新）
                        VStack(spacing: 2) {
                            Text(model.currentRoadName.isEmpty ? "导航中" : model.currentRoadName)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text("当前道路")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .frame(maxWidth: .infinity)
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
                    // v1.81.4 车道卡（<500米时显示，高德同款）：左侧上方动作文字+车道图标(需走车道绿色高亮)，右侧距离+道路名称
                    if let t = ns.nextTurn, ns.distToTurnM < 500, ns.distToTurnM > 0 {
                        HStack(alignment: .top, spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(navTurnText(t))
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white.opacity(0.72))
                                HStack(spacing: 5) {
                                    let lanes = t.lanes.isEmpty ? navLaneFallback(t.modifier) : t.lanes
                                    ForEach(Array(lanes.enumerated()), id: \.offset) { idx, lane in
                                        Image(systemName: navLaneIcon(lane))
                                            .font(.subheadline.bold())
                                            .foregroundStyle(idx == 0 ? Color.green : .white.opacity(0.42))
                                    }
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 0) {
                                Text("\(navDist(ns.distToTurnM))")
                                    .font(.system(size: 24, weight: .heavy))
                                    .foregroundStyle(.white)
                                if !t.roadName.isEmpty {
                                    Text(t.roadName)
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.92))
                                        .lineLimit(1)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
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
        // v2.02 按高德导航底部卡片重做：
        //   位置贴底、高度固定（旧版红绿灯/车道行"有就插、没有就撤"→ 卡片高度反复跳变）
        //   左侧灰色圆形 ×、右侧浅灰圆角"全览"，中间三段大数字（剩余/用时/到达）
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
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color(red: 0.85, green: 0.20, blue: 0.18),
                                            in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        Button {
                            haptic()
                            showExitConfirm = false
                        } label: {
                            Text("继续导航")
                                .font(.headline.bold())
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                    .padding(.horizontal, 12)
                } else if let ns = model.navigationStatus(at: model.currentLocation), ns.remainM > 0 {
                    navBottomCard(ns)
                }
            }
        }
    }

    /// v2.02 高德式导航底部卡（内容分三层，总高度恒定 → 不再跳动）
    private func navBottomCard(_ ns: AppModel.NavStatus) -> some View {
        let dimFg = Color.black.opacity(0.42)
        let mainFg = Color.black.opacity(0.88)
        let kmTxt = String(format: "%.1f", Double(max(ns.remainM, 0)) / 1000.0)
        let minTxt = "\(max(ns.remainS, 0) / 60)"
        let arriveTxt: String = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return f.string(from: Date().addingTimeInterval(TimeInterval(max(ns.remainS, 0))))
        }()
        return VStack(spacing: 0) {
            // ── 第一层：退出 / 三段数据 / 全览 ──
            HStack(spacing: 0) {
                Button {
                    haptic()
                    showExitConfirm = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(mainFg)
                        .frame(width: 32, height: 32)
                        .background(Color.black.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 12)

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(kmTxt)
                        .font(.system(size: 24, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(mainFg)
                    Text("公里")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(dimFg)
                }
                .padding(.leading, 14)

                Spacer(minLength: 6)

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(minTxt)
                        .font(.system(size: 24, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(mainFg)
                    Text("分钟")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(dimFg)
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 0) {
                    Text(arriveTxt)
                        .font(.system(size: 17, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(mainFg)
                    Text("预计到达")
                        .font(.system(size: 10))
                        .foregroundStyle(dimFg)
                }

                Button {
                    haptic()
                    startRouteOverview()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(mainFg)
                        .frame(width: 40, height: 34)
                        .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 12)
                .padding(.leading, 10)
            }
            .frame(height: 52)

            Divider().padding(.horizontal, 12)

            // ── 第二层：下一动作 + 当前车速 ──
            HStack(spacing: 8) {
                if let t = ns.nextTurn, ns.distToTurnM > 0 {
                    Image(systemName: navTurnIcon(t))
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(Color(red: 0.16, green: 0.38, blue: 1.0))
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(navDist(ns.distToTurnM))\(navTurnText(t))")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(mainFg)
                            .lineLimit(1)
                        if !t.roadName.isEmpty {
                            Text(t.roadName)
                                .font(.system(size: 11))
                                .foregroundStyle(dimFg)
                                .lineLimit(1)
                        }
                    }
                } else {
                    Text("继续直行")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(mainFg)
                }
                Spacer(minLength: 4)
                Text("\(Int(ns.speedKph))")
                    .font(.system(size: 17, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(mainFg)
                Text("km/h")
                    .font(.system(size: 10))
                    .foregroundStyle(dimFg)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)

            // ── 第三层：固定高度槽位（红绿灯 / 车道 / 空）──
            // 旧版是"有内容才插入"，高度在 0/34 之间来回变 → 整张卡片上下跳
            ZStack {
                if let nl = model.nextTrafficLight {
                    lightCountdownRow(nl)
                } else if let t = ns.nextTurn, ns.distToTurnM > 0, ns.distToTurnM < 300 {
                    laneGuideRow(t, dimFg: dimFg, mainFg: mainFg)
                }
            }
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.02))
        }
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.black.opacity(0.07), lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
        .padding(.horizontal, 12)
    }

    /// v2.01 红绿灯倒计时行（导航卡顶部）：信号灯图形 + 红/绿 + 剩余秒 + 距离
    private func lightCountdownRow(_ nl: (light: TrafficLight, dist: Int)) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let st = nl.light.state(at: ctx.date)
            HStack(spacing: 8) {
                VStack(spacing: 3) {
                    Circle()
                        .fill(st.red ? Color.red : Color.red.opacity(0.18))
                        .frame(width: 9, height: 9)
                    Circle()
                        .fill(st.red ? Color.green.opacity(0.18) : Color.green)
                        .frame(width: 9, height: 9)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 5))
                Text(st.red ? "红灯" : "绿灯")
                    .font(.caption.bold())
                    .foregroundStyle(st.red ? Color.red : Color(red: 0.13, green: 0.62, blue: 0.30))
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(st.remain)")
                        .font(.system(size: 18, weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(Color.black.opacity(0.78))
                    Text("秒")
                        .font(.caption2)
                        .foregroundStyle(Color.black.opacity(0.45))
                }
                Spacer()
                Text(nl.dist > 8 ? "前方 \(nl.dist) 米 · 预计" : "已到路口")
                    .font(.caption2)
                    .foregroundStyle(Color.black.opacity(0.45))
            }
            .padding(.horizontal, 14)
            .background((st.red ? Color.red : Color.green).opacity(0.07))
        }
    }

    /// v2.01 车道级引导行：推荐车道绿色高亮，其余灰显
    private func laneGuideRow(_ t: RouteTurn, dimFg: Color, mainFg: Color) -> some View {
        let lanes = LaneGuideBuilder.guides(turn: t)
        return HStack(spacing: 5) {
            Text("车道")
                .font(.caption2)
                .foregroundStyle(dimFg)
            ForEach(lanes) { l in
                Image(systemName: l.icon)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(l.recommended ? Color.white : mainFg.opacity(0.32))
                    .frame(width: 26, height: 26)
                    .background(l.recommended
                                ? Color(red: 0.13, green: 0.62, blue: 0.30)
                                : Color.black.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 6))
            }
            Spacer()
            Text(navTurnText(t))
                .font(.caption2.bold())
                .foregroundStyle(dimFg)
        }
        .padding(.horizontal, 14)
    }

    /// v1.81.4 全览操作条（高德同款）：固定全览 / 取消全览(倒计时)
    private var routeOverviewBar: some View {
        HStack(spacing: 12) {
            Button {
                haptic()
                overviewPinned = true
            } label: {
                Text("固定全览")
                    .font(.subheadline.bold())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color(.systemBackground).opacity(0.97), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.green.opacity(overviewPinned ? 0.9 : 0.0), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            Button {
                haptic()
                endRouteOverview()
            } label: {
                Text("取消全览 (\(max(overviewCountdown, 0))s)")
                    .font(.subheadline.bold())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color(.systemBackground).opacity(0.97), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }

    /// v1.81.4 启动全览：缩放全程路线 + 13 秒倒计时自动恢复跟随
    private func startRouteOverview() {
        showRouteOverview = true
        overviewPinned = false
        overviewCountdown = 13
        model.overviewTick += 1
        overviewTask?.cancel()
        overviewTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if overviewPinned { continue } // 固定全览：倒计时暂停
                await MainActor.run { overviewCountdown -= 1 }
                if overviewCountdown <= 0 {
                    await MainActor.run { endRouteOverview() }
                    break
                }
            }
        }
    }

    /// v1.81.4 结束全览：恢复导航跟随
    private func endRouteOverview() {
        guard showRouteOverview else { return }
        showRouteOverview = false
        overviewCountdown = 13
        overviewTask?.cancel()
        overviewTask = nil
        model.navigateFollowTick += 1
    }

    /// v1.81.4 关闭本次行程卡并回到初始界面（清空路线/方案/地点卡等全部残留状态）
    private func dismissTripAndReset() {
        model.tripSummary = nil
        tipCard = nil
        tipRoad = nil
        tipAoiName = nil
        tipPolygon = nil
        model.clearRoute()
    }

    /// 退出导航状态卡分格（v1.85 高度扩大 1.5 倍，对齐高德底部大卡）
    private var exitCellDivider: some View {
        Divider().frame(height: 69)
    }

    /// v1.81.4 本次行程卡（结束导航后显示）：目的地 + 里程/用时/平均速度，字号同退出导航卡
    private func tripSummaryCard(_ s: AppModel.TripSummary) -> some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "flag.checkered.circle.fill")
                    .foregroundStyle(.green)
                Text("本次行程")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Spacer()
                Text(s.destName)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 0) {
                exitStatusCell(String(format: "%.1f", Double(s.distanceM) / 1000.0), "公里")
                exitCellDivider
                exitStatusCell("\(s.durationS / 60)", "分钟")
                exitCellDivider
                exitStatusCell(String(format: "%.1f", s.avgSpeedKmh), "公里/小时")
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(Color(.systemBackground).opacity(0.97), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .padding(.horizontal, 14)
    }

    /// 退出导航状态卡单格（大字+小标签；v1.85 字号随卡片放大，v1.87 深色模式白字，v1.90 白底卡用 forceBlack）
    private func exitStatusCell(_ big: String, _ small: String, forceBlack: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(big)
                .font(.system(size: 28, weight: .heavy))
                .foregroundStyle(forceBlack ? Color.black : (colorScheme == .light ? .black : .white))
            Text(small)
                .font(.caption)
                .foregroundStyle(forceBlack ? Color.black.opacity(0.55) : (colorScheme == .light ? .black.opacity(0.55) : .white.opacity(0.7)))
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

    /// 分享点位（v1.96 统一走 PlaceShare：给的是高德/苹果/百度三条通用导航链接，
    /// 对方没装本 App 也能直接导航；原先的 motonav:// 深链对方打不开，微信也会拒收）
    private func sharePoi(_ p: Poi) {
        PlaceShare.present(PlaceShare.payload(name: p.name,
                                              address: "",
                                              type: p.type.label,
                                              road: "",
                                              lat: p.lat, lon: p.lon))
    }

    /// 左上角指南针：圆盘四方位（东南西北）+ 红色指针指示正北（液态玻璃）
    /// v1.90 顶部居中道路名胶囊（高德式）：导航中显示当前道路名，黑色半透明底，不挡地图
    /// 道路名为空时隐藏（不再显示"导航中"占位）
    private var roadNamePill: some View {
        VStack {
            if !model.currentRoadName.isEmpty {
                Text(model.currentRoadName)
                    .font(.footnote.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(.top, 58)
            }
            Spacer()
        }
    }

    private var compassOverlay: some View {
        // v1.80 指南针可自由拖动，位置持久化（下次打开保持）
        // v1.85 默认位置移到最高处（屏幕顶部）
        // v2.13：内容换成独立子视图 CompassDial，朝向走它自己的 ObservableObject，
        //        这样 10~20Hz 的磁力计回调只重算这 56pt，不会拖垮整个 ContentView。
        DraggableFloat(key: "compass", defaultPos: CGPoint(x: 0.10, y: 0.05)) {
            CompassDial(compass: model.compass)
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
        tapPlace = nil
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
                    if slotTarget != nil {
                        toggleSlotAssignment(name: t.name, lat: t.lat, lon: t.lon)
                    } else {
                        model.toggleTipFavorite(name: t.name, lat: t.lat, lon: t.lon)
                    }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: (slotTarget != nil ? slotStarOn(lat: t.lat, lon: t.lon) : model.isTipFavorite(lat: t.lat, lon: t.lon)) ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundStyle((slotTarget != nil ? slotStarOn(lat: t.lat, lon: t.lon) : model.isTipFavorite(lat: t.lat, lon: t.lon)) ? .orange : .primary)
                        Text(favoriteActionTitle(lat: t.lat, lon: t.lon))
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                Button {
                    haptic()
                    // v1.96 与地点介绍卡统一：文本 + 有效 http(s) 链接，微信才肯接收
                    PlaceShare.present(PlaceShare.payload(name: t.name,
                                                          address: t.sub,
                                                          type: "",
                                                          road: tipRoad ?? "",
                                                          lat: t.lat, lon: t.lon))
                } label: {
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
        return VStack(spacing: 6) {
            // v1.99 快捷词：未聚焦时一行"回家 / 去公司"，省一次输入
            if !searchFocused, model.homePlace != nil || model.workPlace != nil {
                HStack(spacing: 6) {
                    if let h = model.homePlace {
                        quickWordChip("回家", icon: "house.fill", name: h.name, lat: h.lat, lon: h.lon)
                    }
                    if let w = model.workPlace {
                        quickWordChip("去公司", icon: "briefcase.fill", name: w.name, lat: w.lat, lon: w.lon)
                    }
                    Spacer(minLength: 0)
                }
            }
            AnyView(searchInputRow)
            // v1.69：搜索框聚焦且未输入 → 快捷卡片（家/公司/+）+ 历史搜索记录（高德样式）
            // v1.97 常用地点设置态不弹快捷卡片（避免误点跳到导航）
            if searchFocused && searchText.isEmpty && slotTarget == nil {
                AnyView(quickAccessPanel)
            }
            if showSuggestions && !suggestions.isEmpty && !model.navigating {
                AnyView(suggestionsList)
            }
            // 高德 POI 联想候选（填写高德 Key 后显示，点击直接定位；v1.86 导航中不弹出避免挡导航）
            if showSuggestions && !onlineTips.isEmpty && !model.navigating {
                AnyView(onlineTipsList)
            }
            AnyView(tabButtonsRow)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(Color(.systemBackground).opacity(0.96), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .padding(.horizontal, 14)
    }

    /// v1.99 搜索框快捷词（回家 / 去公司）
    private func quickWordChip(_ title: String, icon: String,
                               name: String, lat: Double, lon: Double) -> some View {
        Button {
            haptic()
            searchFocused = false
            dismissKeyboard()
            model.fetchRouteChoices(to: name, lat: lat, lon: lon)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.caption2)
                Text(title).font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
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
                .padding(.vertical, 6)
                .background(selectedTab == 0 ? Color.blue : .clear, in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                selectedTab = 1
                slotTarget = nil
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
            // v1.81.4 搜索历史小字提醒：显示在搜索框卡片内，与搜索框状态同步
            //（搜索框聚焦且空输入时显示，输入内容后自动隐藏；点击任一历史词可快速搜索）
            if !model.searchHistory.isEmpty {
                historyHintRow
            }
        }
    }

    /// v1.81.4 搜索历史小字提醒（高德式小字行：最近搜索 + 清空）
    private var historyHintRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.searchHistory, id: \.self) { name in
                        Button {
                            searchText = name
                            showSuggestions = false
                            dismissKeyboard()
                            doSearch(name)
                        } label: {
                            Text(name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer()
            Button("清空") {
                model.clearHistory()
            }
            .font(.caption2)
            .foregroundStyle(.blue)
        }
        .padding(.horizontal, 4)
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
        return HStack(spacing: 8) {
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
    /// v1.99 联想结果排序：距离最近 / 名称
    private var sortedTips: [AppModel.AmapTip] {
        guard tipSort == 0 else {
            return onlineTips.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
        guard let loc = model.currentLocation else { return onlineTips }
        return onlineTips.sorted {
            CLLocation(latitude: $0.lat, longitude: $0.lon)
                .distance(from: CLLocation(latitude: loc.latitude, longitude: loc.longitude))
                < CLLocation(latitude: $1.lat, longitude: $1.lon)
                .distance(from: CLLocation(latitude: loc.latitude, longitude: loc.longitude))
        }
    }

    private var onlineTipsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // v1.99 搜索结果排序（距离 / 名称）
                HStack(spacing: 8) {
                    Text("结果 \(onlineTips.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    ForEach([0, 1], id: \.self) { idx in
                        Button {
                            tipSort = idx
                        } label: {
                            Text(idx == 0 ? "距离最近" : "名称")
                                .font(.caption2)
                                .foregroundStyle(tipSort == idx ? .white : .secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(tipSort == idx ? Color.blue : Color(.secondarySystemBackground),
                                            in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                ForEach(sortedTips) { tip in
                    // v1.82 常搜项（历史搜索记录）左拉单个删除，其余项正常
                    let row = VStack(spacing: 0) {
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
                    if model.searchHistory.contains(tip.name) {
                        SwipeDeleteRow(onDelete: { model.removeHistory(tip.name) }) { row }
                    } else {
                        row
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
        var bestD = 250.0 // v1.98 收紧到 250 米：旧版 800 米会把远处小区名安到点击点上
        for pl in model.placeLabels {
            let d = c.distance(from: CLLocation(latitude: pl.lat, longitude: pl.lon))
            if d < bestD { bestD = d; best = pl }
        }
        return best?.name ?? ""
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

/// v1.97 "我的-常用地点"收藏项（ForEach 需要 Identifiable，不能用元组）
private struct FavoriteEntry: Identifiable {
    let key: String
    let name: String
    let lat: Double
    let lon: Double
    let time: Double
    var id: String { key }
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
                    // v1.96 统一分享格式（文本 + http 链接），微信可正常接收
                    PlaceShare.present(PlaceShare.payload(name: poi.name,
                                                          address: "",
                                                          type: poi.type.label,
                                                          road: "",
                                                          lat: poi.lat, lon: poi.lon))
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

/// v1.82 列表行左滑删除（联想"常搜"项用）：左拉露出右侧红色删除按钮块（高度同行），滑过一半触发删除
private struct SwipeDeleteRow<Content: View>: View {
    let onDelete: () -> Void
    @ViewBuilder let content: Content
    @State private var offset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                Spacer()
                Button {
                    onDelete()
                } label: {
                    Text("删除")
                        .font(.headline.bold())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 92)
                .background(Color.red)
            }
            .opacity(offset < -8 ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: offset < -8)
            content
                .offset(x: offset)
        }
        .clipped()
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { v in
                    if v.translation.width < 0 { offset = v.translation.width }
                }
                .onEnded { v in
                    if offset < -46 {
                        onDelete()
                    } else {
                        withAnimation(.spring(duration: 0.3)) { offset = 0 }
                    }
                }
        )
    }
}

/// v1.80 可拖动悬浮控件：位置以 0-1 归一化持久化到 UserDefaults，下次打开还原
/// v1.81.2 支持 onSwipeLeft：向左大幅滑动（>80pt 且横向为主）触发回调关闭，否则正常拖动记忆
/// v1.81.4 支持 lockX：仅上下移动（横向锁定在初始 x）
/// v1.81.4 支持 deleteLabel：左滑时卡片后跟红色"左拉删除"卡（大小同卡片），滑过一半触发删除回调
/// v2.13 指南针表盘（独立子视图）。
///
/// 朝向单独走 `CompassState`：磁力计 10~20Hz，若由 ContentView 直接观察，
/// 每次回调都会让 4000 行的 body 整体重算一次；拆出来以后只有这 56pt 重算。
private struct CompassDial: View {
    @ObservedObject var compass: CompassState

    var body: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1.5)
            // 红色指北针（随手机朝向旋转）
            Image(systemName: "location.north.fill")
                .font(.title3)
                .foregroundStyle(.red)
                .rotationEffect(.degrees(compass.angle))
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

private struct DraggableFloat<Content: View>: View {
    let key: String
    var lockX: Bool = false
    var deleteLabel: String? = nil
    var onSwipeLeft: (() -> Void)? = nil
    @ViewBuilder let content: Content
    @State private var pos: CGPoint
    @State private var initialX: CGFloat
    @State private var dragging = false
    @State private var deleting = false
    @State private var dragOffset: CGFloat = 0
    /// v1.99 拖动起点（手指按下时的中心点）：旧版直接把中心设为手指位置，
    /// 一按下去整块就"跳"到手指下，滑动时始终慢半拍、像甩不动的橡皮筋
    @State private var dragStartPos: CGPoint? = nil

    init(key: String, defaultPos: CGPoint, lockX: Bool = false, deleteLabel: String? = nil,
         onSwipeLeft: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.key = key
        self.lockX = lockX
        self.deleteLabel = deleteLabel
        self.onSwipeLeft = onSwipeLeft
        self.content = content()
        let x = UserDefaults.standard.object(forKey: "\(key).x") as? Double
        let y = UserDefaults.standard.object(forKey: "\(key).y") as? Double
        // v1.99 缩放/定位按钮默认位置改到"搜索框右上方"：一次性作废旧坐标，
        // 否则装过旧版的手机会继续用存储在 UserDefaults 里的右上角位置
        let posVersion = UserDefaults.standard.integer(forKey: "\(key).posV")
        let stale = key == "zoom" && posVersion < 2
        if stale { UserDefaults.standard.set(2, forKey: "\(key).posV") }
        let savedX = stale ? nil : x
        let savedY = stale ? nil : y
        // v1.97 兜底钳制：历史拖动位置可能落在屏幕外（如旧版缩放键 6%），这里拉回可视区
        let px = min(0.96, max(0.04, savedX ?? defaultPos.x))
        let py = min(0.93, max(0.10, savedY ?? defaultPos.y))
        _pos = State(initialValue: CGPoint(x: px, y: py))
        _initialX = State(initialValue: px)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                // v1.81.4 红色删除按钮块（模仿高德样式）：固定宽度、高度同卡片、仅左拉时出现
                if let lbl = deleteLabel {
                    HStack(spacing: 0) {
                        Spacer()
                        Text(lbl)
                            .font(.headline.bold())
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: 92)
                    .background(Color.red)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .opacity(dragOffset < -8 ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: dragOffset < -8)
                }
                content
                    .offset(x: dragOffset)
            }
            .position(x: pos.x * geo.size.width, y: pos.y * geo.size.height)
            .shadow(color: .black.opacity(dragging ? 0.3 : 0.12), radius: 8, y: 3)
            .scaleEffect(dragging ? 1.08 : 1.0)
            .animation(.easeOut(duration: 0.12), value: dragging)
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { v in
                        if deleteLabel != nil, v.translation.width < -8,
                           abs(v.translation.width) > abs(v.translation.height) {
                            // 左滑删除模式：卡片跟随左移，露出红色删除卡
                            deleting = true
                            dragOffset = v.translation.width
                        } else {
                            // 正常拖动：按位移增量移动，手指与卡片严格同步（不再跳到手指中心）
                            deleting = false
                            dragOffset = 0
                            dragging = true
                            let base = dragStartPos ?? pos
                            if dragStartPos == nil { dragStartPos = base }
                            let w = max(1, geo.size.width)
                            let h = max(1, geo.size.height)
                            pos = CGPoint(
                                x: lockX ? initialX : min(0.96, max(0.04, base.x + v.translation.width / w)),
                                y: min(0.96, max(0.04, base.y + v.translation.height / h)))
                        }
                    }
                    .onEnded { v in
                        dragging = false
                        dragStartPos = nil
                        if deleting {
                            // 左拉过卡片一半宽度即完成删除
                            let cardW = geo.size.width - 28
                            if dragOffset < -cardW * 0.5 {
                                onSwipeLeft?()
                            } else {
                                withAnimation(.spring(duration: 0.3)) { dragOffset = 0 }
                            }
                        } else if let onSwipeLeft = onSwipeLeft,
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

// =============================================================================
// v1.99 三个数据面板：足迹 / 离线地图 / 组队骑行
// =============================================================================

/// 足迹列表：里程、时长、均速/最高速，支持回放、导出 GPX、删除
private struct FootprintSheet: View {
    @ObservedObject var store: FootprintStore
    var onReplay: (Footprint) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var exporting: Footprint?

    var body: some View {
        NavigationStack {
            List {
                if store.items.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("还没有足迹").font(.headline)
                            Text("每次结束导航会自动存档：里程、时长、均速、最高速和轨迹。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                } else {
                    Section {
                        HStack {
                            statBlock("总里程", String(format: "%.1f km", Double(store.totalDistanceM) / 1000))
                            Divider()
                            statBlock("总时长", "\(store.totalDurationS / 3600) 小时")
                            Divider()
                            statBlock("记录", "\(store.items.count) 次")
                        }
                    }
                    Section("行程") {
                        ForEach(store.items) { f in
                            Button {
                                onReplay(f)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(f.destName)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(f.dateText)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("\(f.distanceText) · \(f.durationText) · 均速 \(String(format: "%.0f", f.avgSpeed)) · 最高 \(String(format: "%.0f", f.maxSpeed)) km/h")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    store.remove(f.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                Button {
                                    exporting = f
                                } label: {
                                    Label("导出", systemImage: "square.and.arrow.up")
                                }
                                .tint(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("足迹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !store.items.isEmpty {
                        Button("清空", role: .destructive) { store.clear() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $exporting) { f in
                GPXShareSheet(items: [store.gpx(for: f)])
            }
        }
    }

    private func statBlock(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.weight(.bold))
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 离线地图：按当前位置下载指定半径的瓦片包
private struct OfflineMapSheet: View {
    @ObservedObject var manager: OfflineMapManager
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var radius: Double = 10

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("范围", selection: $radius) {
                        Text("5 km").tag(5.0)
                        Text("10 km").tag(10.0)
                        Text("20 km").tag(20.0)
                        Text("40 km").tag(40.0)
                    }
                    .pickerStyle(.segmented)

                    Button {
                        guard let c = model.currentLocation else {
                            model.status = "请先定位再下载离线地图"
                            return
                        }
                        Task {
                            await manager.download(name: "当前位置 \(Int(radius))km",
                                                   lat: c.latitude, lon: c.longitude,
                                                   radiusKm: radius)
                        }
                    } label: {
                        HStack {
                            Label("下载当前位置周边", systemImage: "arrow.down.circle")
                            Spacer()
                            Text(manager.busy ? "下载中…" : "约 \(OfflineMapManager.estimateTileCount(radiusKm: radius)) 张")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(manager.busy)

                    if manager.busy {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: manager.progress)
                            Text(manager.progressText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Button("取消下载", role: .destructive) { manager.cancel() }
                                .font(.caption)
                        }
                    }
                    if let e = manager.lastError {
                        Text(e).font(.caption).foregroundStyle(.red)
                    }
                } footer: {
                    Text("离线包会把该范围内的地图瓦片存到本机，进山没信号时仍有底图；下载后在线缓存也会复用这些瓦片，更省流量。")
                }

                Section("已下载") {
                    if manager.packs.isEmpty {
                        Text("暂无离线包").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(manager.packs) { p in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.subheadline)
                                Text(p.subtitle).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                manager.delete(p)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("离线地图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

/// 组队骑行：队伍码 + 昵称，实时显示队友距离
private struct TeamRideSheet: View {
    @ObservedObject var team: TeamRide
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var nickname = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("昵称（如：老王）", text: $nickname)
                    TextField("队伍码（4-6 位，同伴输入同一个）", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    HStack {
                        Button {
                            code = TeamRide.randomCode()
                        } label: {
                            Label("随机生成", systemImage: "dice")
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        if team.active {
                            Button("退出队伍", role: .destructive) {
                                team.stop()
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button("开始组队") {
                                team.start(code: code, nickname: nickname)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(code.trimmingCharacters(in: .whitespaces).count < 4)
                        }
                    }
                } footer: {
                    Text("把队伍码发给同伴，各自输入同一个码即可互相看到位置（约 6 秒刷新一次）。仅共享位置与速度，不做长期存储。")
                }

                if team.active {
                    Section("队伍 \(team.code)") {
                        if let e = team.lastError {
                            Text(e).font(.caption).foregroundStyle(.red)
                        }
                        ForEach(team.members) { m in
                            HStack {
                                Image(systemName: m.name == team.nickname ? "location.fill" : "person.fill")
                                    .foregroundStyle(m.name == team.nickname ? .blue : .teal)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.name + (m.name == team.nickname ? "（我）" : ""))
                                        .font(.subheadline)
                                    Text("\(String(format: "%.0f", m.speedKph)) km/h · \(m.ageText)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        if team.members.count <= 1 {
                            Text("等待同伴加入…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("组队骑行")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
