import SwiftUI
import MapKit
import UIKit
import UniformTypeIdentifiers
import Speech          // v2.52 语音搜索（SFSpeechRecognizer）
import AVFoundation     // v2.52 语音搜索录音 / 音频会话

/// v2.12 外观设置：跟随系统 / 强制浅色 / 强制深色
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    /// v2.28 共用的「时:分」格式化器（静态复用）
    ///
    /// DateFormatter 的初始化很贵 —— 它要解析格式串、读用户的地区设置、建内部日历。
    /// 而导航底卡的"预计到达时间"在 body 求值期每次都要格式化一次，
    /// 导航中每秒重算几十次 → 一次新建几十个 DateFormatter，纯浪费。
    /// 静态复用一个实例即可（DateFormatter 本身线程安全，SwiftUI 全在主线程）。
    private static let hhmmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// v1.99 组队骑行（地图队友点 + 我的页队伍面板）
    @StateObject private var team = TeamRide.shared
    /// v1.99 足迹（我的-足迹）
    @StateObject private var footprints = FootprintStore.shared
    /// v2.27 开发者诊断页
    @State private var showDiagnostics = false
    /// v2.33 选项说明卡片（问号点击弹出；说明小字不再直接铺在页面上）
    @State private var explainTitle = ""
    /// v2.34 快捷卡片重命名（长按菜单触发，TextField 弹窗）
    @State private var renamingQuickPoiId: String?
    @State private var renamingQuickPoiName = ""
    /// v2.34 E9 首次使用引导横幅（见一次后关闭，不再打扰）
    @State private var showIntro = !UserDefaults.standard.bool(forKey: "hasSeenIntro")
    @State private var explainBody = ""
    @State private var showExplain = false
    /// v2.27 版本号连点计数（连点 7 次进入诊断页）
    @State private var versionTapCount = 0
    @State private var versionTapResetTask: Task<Void, Never>?
    /// v2.27 同步提示框的自动倒计时（秒）；0 = 不倒计时
    @State private var syncCountdown = 0
    /// v2.27 倒计时任务
    @State private var syncCountdownTask: Task<Void, Never>?

    /// v2.27（优化建议 #25）连点版本号进入诊断页
    ///
    /// 7 次连点触发，2 秒内不连点就重置计数。
    /// 隐藏入口的好处：普通用户看不到"诊断"这种让人困惑的菜单项，
    /// 但真出问题时（用户截图反馈）能自助打开，把诊断信息发给开发者。
    private func handleVersionTap() {
        versionTapCount += 1
        // 重置计时：每次点击都重新给 2 秒窗口
        versionTapResetTask?.cancel()
        versionTapResetTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { versionTapCount = 0 }
        }
        if versionTapCount >= 7 {
            versionTapCount = 0
            versionTapResetTask?.cancel()
            showDiagnostics = true
            haptic()
        } else if versionTapCount >= 5 {
            haptic()   // 接近时给触感反馈，提示"再点几下"
        }
    }

    /// v2.26 同步提示框状态机

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
    /// v2.54 搜索态整屏：只要搜索框聚焦、或点了「搜索」展开，就进入整屏搜索页
    /// （对齐高德：搜索时不显示地图，整屏都是搜索界面）。
    /// 导航中不进入（导航时点搜索是"换目的地"，仍要看着地图）。
    private var searchActive: Bool { (searchFocused || searchExpanded) && !model.navigating }
    /// v1.81 点击联想地点主体后：地图高亮该点并显示地点信息卡
    @State private var tipCard: AppModel.AmapTip?
    /// v1.95 轻点地图任意位置 → 地点介绍卡（逆地理编码结果）
    @State private var tapPlace: TapPlaceInfo?
    /// v1.81.2 退出导航确认态：点状态卡左侧×后切换为"退出导航/取消"两按钮
    @State private var showExitConfirm = false
    /// v2.51 从导航底卡"搜索"进入退出确认：确认后要回到首页并聚焦搜索框
    @State private var pendingSearchAfterExit = false
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
    @FocusState private var searchFocused: Bool
    @State private var pendingCoord: CLLocationCoordinate2D?
    @State private var headingNeedleTick = 0
    /// 待导航目标（搜索预览 / 点击地图地点）
    @State private var goHereName: String?
    @State private var goHereLat = 0.0
    @State private var goHereLon = 0.0
    @State private var goHereLabel = ""
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
    /// v2.23 搜索选点黑线：我的位置 → 搜索选点（WGS-84）；非 nil 时地图画黑线
    @State private var searchLinkFrom: CLLocationCoordinate2D?
    /// v2.23 搜索选点黑线终点（搜索选点，WGS-84）
    @State private var searchLinkTo: CLLocationCoordinate2D?
    /// v2.25 搜索选点高亮（坐标 + 名称），地图上显示橙色定位环
    @State private var searchHitCoord: CLLocationCoordinate2D?
    @State private var searchHitTitle: String = ""
    /// v2.23 边缘滑动返回：手指起点 x（用于判断是否从屏幕边缘起手）
    @State private var edgeDragStartX: CGFloat = 0
    /// v1.86 行程卡自动收起任务（出现 5 秒后回首页）
    @State private var tripAutoDismissTask: Task<Void, Never>?
    /// v2.37 G1 状态反馈 toast：model.status 赋值后显示 2.5s（操作反馈不再不可见）
    @State private var statusVisible = false
    @State private var statusDismissTask: Task<Void, Never>?
    /// v2.39 I2 导航中切换备选路线（高德式：导航页可换方案）
    @State private var showRouteSwap = false
    /// v2.48 规划卡实测屏幕框（全屏坐标）：地图路线全览按卡片真实遮挡位置留白，
    /// 否则路线起终点正好被上下两卡遮住（用户反馈"规划了但看不到地图上的路线"）
    @State private var planTopCardFrame: CGRect = .zero
    @State private var planBottomCardFrame: CGRect = .zero
    /// v2.55 行程卡实测屏幕框：右侧 −/3D 的避让量改由它真实推导（原来写死 215 是按估算卡高拍的）
    @State private var tripCardFrame: CGRect = .zero
    /// v2.58 搜索卡实测框：卡片能自由上下拖，右侧缩放组要按它实时避让
    @State private var bottomMainCardFrame: CGRect = .zero
    /// v2.70 浏览态自动回跟的序号（作废旧计时任务）
    @State private var browseSeq = 0
    /// v1.87 天气动画按外观模式取色（浅色背景用深色雨丝/雪花，保证可见）
    @Environment(\.colorScheme) private var colorScheme
    /// 语音包设置页弹出（"我的"→语音播报）
    @State private var showVoiceSettings = false
    /// v1.99 足迹 / 离线地图 / 组队 面板
    @State private var showFootprints = false
    @State private var showTeamRide = false
    /// v1.99 搜索结果排序（0 距离 / 1 名称）
    @State private var tipSort = 0
    /// v2.51 键盘高度（搜索聚焦时卡片坐在键盘上方；由通知驱动，不靠手写 offset）
    @State private var keyboardHeight: CGFloat = 0
    /// v2.51 输入联想请求句柄（防抖 + 取消旧请求）
    @State private var tipTask: Task<Void, Never>? = nil
    /// v2.51 联想请求进行中（无结果占位不要误报"未找到"）
    @State private var searchLoading = false
    /// v2.52 语音搜索服务（说话即填搜索框）
    @StateObject private var voiceSearch = VoiceSearchService()
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

    /// v2.25 body 的 ZStack 主体（单独抽出来降低类型推断复杂度）
    ///
    /// Swift 的类型检查超时按表达式计预算：body 里 20+ 分支的 ZStack
    /// 再叠上 230 行修饰符链（13 个弹窗 + 一堆 onChange），单次推断必然超时，
    /// 报 "unable to type-check this expression in reasonable time"。
    /// 把 ZStack 主体与修饰符链拆成两个表达式后，各自独立推断，问题消失。
    private var bodyCore: some View {
        ZStack {
            // v1.64：底部选项卡分离——0=导航主页（地图+搜索框），1=我的（独立菜单页），切换时选项卡常驻底部
            if selectedTab == 0 {
                AnyView(mapLayer)
                // v1.81.4 全屏天气动画（高德同款）：下雨雨丝/下雪飘雪，透明覆盖不拦截手势
                // v1.86 仅初始地图页/导航态渲染：沉浸模式与巡航模式暂停（省电、不挡视野）
                // v2.27 优化建议 #23：巡航模式也停掉。
                // 巡航是"看路"的场景（骑手正在找路），任何全屏动画都是干扰，
                // 之前只停了导航态，漏了巡航态。
                if !uiHidden && !model.cruiseMode && !model.navigating {
                    AnyView(weatherFX)
                }
                // v1.92 省电调暗：仅非导航态盖轻黑罩（OLED 上省电），
                // 导航中不再遮挡——骑行户外阳光 + 头盔镜片下，地图变暗会看不清路口与电子眼
                // v2.34 E1：巡航同样是骑行看路场景，一并豁免调暗（与天气动画同款口径）
                if model.powerSaving && !model.navigating && !model.cruiseMode {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
                // v1.66：沉浸模式（uiHidden）下隐藏全部 UI，只留当前定位按钮
                if !uiHidden {
                    // v2.25 抽出为子视图：body 表达式过大时 Swift 编译器会
                    // "unable to type-check this expression in reasonable time"，
                    // 拆成独立 ViewBuilder 属性可显著降低单次推断的复杂度。
                    AnyView(mapTopOverlayGroup)
                    // v1.97 常用地点设置提示条（从"我的"点铅笔后回到地图时显示）
                    if slotTarget != nil && !model.navigating {
                        AnyView(slotEditBanner)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .padding(.top, 6)
                    }
                    // v2.34 E3 定位权限被拒：顶部横幅引导去系统设置
                    if model.locationDenied {
                        AnyView(locationDeniedBanner)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .padding(.top, slotTarget != nil ? 62 : 8)
                    }
                    // v2.34 E9 首次使用引导（仅地图页、非导航、非沉浸时显示）
                    if showIntro && !model.navigating && !uiHidden && !model.cruiseMode {
                        AnyView(introBanner)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .padding(.top, (model.locationDenied ? 64 : 6))
                    }
                } else if !model.navigating {
                    // 沉浸模式：仅保留右下角当前定位按钮
                    AnyView(locateButtonOnly)
                }
                // v2.25 抽出为子视图（见 mapTopOverlayGroup 的说明：降低 body 推断复杂度）
                AnyView(navOverlayGroup)
                // v2.54 搜索态整屏化：地图整块被不透明页面盖住（对齐高德"搜索时不显示地图"）。
                //
                // 关键取舍：**不卸载 MapView**。历史上 MapView 卸载重挂会重建 overlay
                // （启动首帧 watchdog 黑屏就出在这条链上），相机/路线/标注也全部要重算；
                // 盖一层不透明页面是风险最低的做法，退出搜索时地图原样恢复、不闪不跳。
                // 位置：navOverlayGroup 之后 —— 顺带盖住定位按钮/路名胶囊等地图浮件，
                // 但 bottomLayerGroup 在其上，搜索卡仍然显示。
                if searchActive {
                    Color(.systemBackground)
                        .ignoresSafeArea()
                        // v2.54 修正：这层只是视觉遮罩，绝不能吃触摸 ——
                        // 否则进搜索态后地图手势全被它拦住（表现"地图不动了"）
                        .allowsHitTesting(false)
                }
                // v1.90 导航数据已全部合并进底部白底卡片（分钟/公里/红绿灯/速度/道路/预计到达），
                // 移除顶部重复的大数字条 navTopBar，避免信息分散（高德同款单卡片式导航状态）
                // v1.84 巡航模式顶部卡片（白底：实时速度）
                if model.cruiseMode && !model.navigating && !uiHidden {
                    AnyView(cruiseCard)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                // v2.25 抽出为子视图（降低 body 推断复杂度，见 mapTopOverlayGroup 说明）
                AnyView(bottomLayerGroup)
            } else {
                AnyView(settingsPage)
            }
            // v2.56 底部选项卡改成常驻贴底（两个页面同一套样式）：
            // 搜索卡不再内嵌"导航/我的"，搜索框与 tab 彻底分离；
            // 搜索整屏态仍隐藏（高德搜索页同样没有底部 tab）；
            // 地点卡贴底后同样让位 —— 卡片和 tab 挤在同一块屏幕上谁也点不好。
            // v2.59 导航结束时（行程卡"本次行程"在屏上）隐藏底部 tab：
            // 那一刻屏幕的焦点是行程结果，底下再挂一条导航/我的，既抢注意力
            // 又和行程卡的下沿挤在一起。关掉行程卡后 tab 自动回来。
            // v2.60 规划页（方案卡在屏）也隐藏 tab：下卡改成贴底后，
            // 卡片底边就在 tab 条上沿，tab 露在下面既没用又会被卡压住。
            // v2.68 首页的 tab 已合并进搜索卡；这条常驻 tab 只在「我的」页保留
            // （那一页整页替换，卡不在屏上，需要一个回「导航」的入口）。
            if selectedTab == 1 {
                AnyView(bottomTabBar)
            }
        }
    }

    var body: some View {
        rootWithMods
    }

    /// v2.47 拆分：body 链过长（onChange+手势+sheet+modifier 混合）导致 Xcode 16.1
    /// type-check 超时 —— 拆成 rootWithMods（sheet/modifier 组）与 rootCore（onChange 组）两段
    private var rootWithMods: some View {
        rootCore
        .modifier(SheetGroup1Modifier(showVoiceSettings: $showVoiceSettings, showFootprints: $showFootprints, showTeamRide: $showTeamRide, footprints: footprints, team: team, selectedTab: $selectedTab))
        // v2.39 I2 导航中切换路线 sheet：导航底卡"换路"按钮弹出
        .sheet(isPresented: $showRouteSwap) {
            if !model.routeChoices.isEmpty {
                NavigationStack {
                    List(Array(model.routeChoices.enumerated()), id: \.offset) { idx, c in
                        Button {
                            haptic()
                            model.applyRouteChoice(c)
                            showRouteSwap = false
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(idx == 0 ? "推荐" : "备选\(idx)") · \(c.durationS / 60) 分钟 · \(String(format: "%.1f", Double(c.distanceM) / 1000.0)) 公里")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(c.label)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: idx == 0 ? "checkmark.circle.fill" : "arrow.right.circle")
                                    .foregroundStyle(idx == 0 ? .green : .blue)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .navigationTitle("切换路线")
                    .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.medium])
            }
        }
        .modifier(SheetGroup2Modifier(showAmapKeyInput: $showAmapKeyInput, amapKeyInput: $amapKeyInput))
        .modifier(SheetGroup3Modifier(pendingQuickCoord: $pendingQuickCoord, quickPickMode: $quickPickMode, showQuickNameAlert: $showQuickNameAlert, quickName: $quickName))
        .modifier(SheetGroup4Modifier(showDiagnostics: $showDiagnostics))
        // v1.61 恢复：语音包设置（"我的"→语音播报，讯飞音色选择）
        // v1.99 足迹 / 离线地图 / 组队
        // v1.69 搜索面板"+"选点命名弹窗
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
        // v2.37 G4 行程卡常驻：到达统计（距离/均速/时长）停车后要看清，
        // 不再 5 秒自动收起；轻点卡外或左滑手动关闭（dismissTripAndReset）
        .onChange(of: model.tripSummary != nil) { _, showing in
            tripAutoDismissTask?.cancel()
        }
        // v2.37 G1 状态反馈 toast：任何 model.status 赋值（操作结果/异常提示）
        // 顶部胶囊显示 2.5s 后自动消失；地图加载类提示由 mapLoadBanner 专用横幅承担
        .onChange(of: model.status) { _, newStatus in
            statusDismissTask?.cancel()
            guard !newStatus.isEmpty,
                  newStatus != "等待定位…",
                  newStatus != "地图加载异常，自动重试…",
                  newStatus != "正在重新加载地图…",
                  newStatus != "路线已重新规划，请按新路线行驶" else { return }
            statusVisible = true
            statusDismissTask = Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await MainActor.run { statusVisible = false }
            }
        }
        // 切回前台时再检查剪贴板（微信复制位置 → 打开摩卫士自动识别）
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                model.checkClipboard()
            } else if phase == .background {
                // v2.31 底图已换 MapKit 原生，不再需要手动瓦片缓存清理
            }
        }
        // 导航中保持屏幕常亮（骑行看导航不被锁屏；退出导航恢复）
        // v2.70 浏览态自动回跟：手一碰地图就把跟随停了，旧版只能手动点「继续导航」。
        // 骑行时腾手点按钮不安全，这里改成 8 秒无新操作自动回跟。
        // browseSeq 用来作废旧任务：用户连续多次拖动时，只有最后一次的计时有效。
        .onChange(of: model.navUserMoved) { _, moved in
            guard moved else { return }
            browseSeq += 1
            let seq = browseSeq
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard seq == browseSeq, model.navUserMoved else { return }
                model.navUserMoved = false
                model.navigateFollowTick += 1
            }
        }
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

    /// v2.47 拆分：bodyCore + onChange/手势组（短链，编译器可快速推断）
    private var rootCore: some View {
            bodyCore
        // v2.25 我的位置移动时，黑线起点跟着更新（线始终连着当前定位点）
        // 顺带兜底：搜索时如果定位还没出来（nil），定位一有值就补上黑线起点
        .onChange(of: model.currentLocation?.latitude ?? 0) { _, _ in
            if searchHitCoord != nil {
                searchLinkFrom = model.currentLocation
            }
        }
        // v2.23 全局边缘滑动返回：手指从屏幕左/右边缘往中间滑 → 返回上一级
        // 放在最外层 ZStack 上（覆盖地图），用 simultaneousGesture 避免抢地图自身手势；
        // 地图区域内的横向拖动（平移）依然可用 —— 只有起手点在边缘 40pt 内才触发。
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { v in
                    if edgeDragStartX == 0 { edgeDragStartX = v.startLocation.x }
                }
                .onEnded { v in
                    let startX = edgeDragStartX
                    edgeDragStartX = 0
                    let screenW = UIScreen.main.bounds.width
                    if handleEdgeSwipe(startX: startX, translation: v.translation.width, screenW: screenW) {
                        haptic()
                    }
                }
        )
        // v2.54 修正搜索态两个连环坑（用户实机反馈"搜索框不能输入、地图不能移动"）：
        //  ① 搜索整屏把搜索卡从 DraggableFloat 换成 VStack 顶对齐 —— 容器一变，
        //     内部 TextField 就是新实例，@FocusState 跟着丢，键盘永远弹不出来；
        //  ② 而 searchActive 本身依赖 searchFocused：一旦失焦就切回原容器、再重建，
        //     来回抖动，用户看到的就是"点了搜索框毫无反应"。
        // 修法：焦点一进就钉住 searchExpanded（容器不再随焦点抖动），
        // 并在切换完成后延迟一次，把焦点交还给新建出来的 TextField。
        .onChange(of: searchFocused) { _, focused in
            if focused && !searchExpanded { searchExpanded = true }
        }
        .onChange(of: searchActive) { _, active in
            guard active else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if searchActive && !searchFocused { searchFocused = true }
            }
        }
        // v1.81.3 新一次导航开始时重置退出确认态；导航结束时清理全览态
        .onChange(of: model.navigating) { _, nv in
            if nv {
                showExitConfirm = false
                pendingSearchAfterExit = false   // v2.51 防残留：下次退出导航时误触发"回首页+搜索"
                tapPlace = nil          // v1.95 进入导航时收起地点卡，避免和导航卡叠在一起
                slotTarget = nil        // v1.97 开始导航即退出常用地点设置态
            } else {
                pendingSearchAfterExit = false
                endRouteOverview()
                // v2.56 导航一结束（到达 / 主动退出都一样）就收起搜索选点黑线。
                // 这条黑线是"搜索点 → 我的位置"的直线提示，只在选点时有用；
                // 结束导航后继续挂在图上，就是用户看到的"起点终点还连着一条线"。
                clearSearchLink()
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
        // v2.52 语音失败（未授权 / 无麦克风）用状态栏提示，避免按钮"点了没反应"
        .onChange(of: voiceSearch.errorText) { _, e in
            if !e.isEmpty { model.status = e }
        }
        // v2.51 键盘高度：搜索主卡靠它坐在键盘上方
        //（替代旧版手写 offset(-300)，那套不受浮层钳制约束，会把卡片顶出屏幕）
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let f = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let h = max(0, UIScreen.main.bounds.height - f.minY)
            if abs(h - keyboardHeight) > 1 { keyboardHeight = h }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            if keyboardHeight != 0 { keyboardHeight = 0 }
        }
    }


    /// v2.48 规划态地图全览留白：路线 fit 时按上下卡实际高度避让。
    ///
    /// 旧版固定 edgePadding 60pt，规划页两张卡（上卡贴顶、下卡锚底）把路线
    /// 起终点正好盖住 —— 用户"看得到卡片、看不到地图上的路线"。
    /// 这里用 DraggableFloat 实测的卡高算留白；卡还没测完时用保守估值兜底，
    /// 测完会由 MapView 的 insets 变化触发一次补 fit。
    private var planFitInsets: UIEdgeInsets {
        let h = UIScreen.main.bounds.height
        // 上卡：取卡片真实顶边到屏幕顶的距离（= 卡底 y），比"6% 屏高 + 估算卡高"更准
        // v2.54 兜底估值按瘦身后的卡高（上卡约 196、下卡约 246）调低；
        // 实测帧一旦到达就以实测为准
        var top = planTopCardFrame.maxY > 0 ? planTopCardFrame.maxY + 6 : h * 0.06 + 196
        // 下卡：屏底到卡片顶边的距离
        var bottom = planBottomCardFrame.minY > 0 ? h - planBottomCardFrame.minY + 8 : 246
        // 地图可见带至少保留屏高 22%（否则 MapKit 缩得太狠，路线细得看不清）
        let availMin = h * 0.22
        if top + bottom > h - availMin {
            bottom = max(h - availMin - top, 110)
        }
        top = min(top, h * 0.46)
        return UIEdgeInsets(top: top, left: 36, bottom: bottom, right: 36)
    }

    /// v2.50 地图可视区留白（全场景统一）
    ///
    /// 各入口的 edgePadding 之前各写一套魔法数（导航 90/120、加油站 60/60），
    /// 卡片一高就会遮住路线端点（尤其导航态的路口放大图 110pt、加油站的底部结果条）。
    /// 这里按"当前场景真实卡片"统一给一套：规划态直接复用实测卡框，
    /// 其余场景用卡片布局的固定高度（这些卡本身高度恒定）。
    private var mapViewportInsets: UIEdgeInsets {
        // 导航态：顶部路名提示 + 底部导航卡 + 路口放大图
        if model.navigating {
            // top 150 = 安全区顶(47/59) + 提示卡（顶 8 + 高约 78）
            return UIEdgeInsets(top: 150, left: 36, bottom: 320, right: 36)
        }
        // 规划态：上下两张规划卡的真实屏幕框（v2.48）
        if !model.routeChoices.isEmpty, model.tripSummary == nil {
            return planFitInsets
        }
        // 加油站：底部类别结果横条
        if !model.gasStations.isEmpty {
            return UIEdgeInsets(top: 90, left: 36, bottom: 260, right: 36)
        }
        // 其它（地点信息卡 / 搜索预览）：底部信息卡
        return UIEdgeInsets(top: 90, left: 36, bottom: 240, right: 36)
    }

    /// 地图全屏层（高德式：地图在上，搜索框下置）
    private var mapLayer: some View {
        MapViewRepresentable(
            userLocation: model.currentLocation,
            route: model.route,
            choiceRoutes: model.routeChoices.map(\.points),
            selectedRouteIdx: model.selectedRouteIdx,
            locateTick: model.locateTick,
            fitTick: model.fitTick,
            viewportInsets: mapViewportInsets,
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
                // v2.02 长按只做一件事：出地点卡
                showTapPlace(coord)
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
                // v1.69 搜索面板"+"选点模式：轻点地图即命名生成快捷卡片
                //（v2.33 删除电警时误删此分支，功能链断开，已恢复）
                if quickPickMode {
                    pendingQuickCoord = coord
                    quickName = placeNameNear(coord)
                    showQuickNameAlert = true
                    return
                }
                // 沉浸态下轻点＝恢复界面（否则隐藏 UI 后没有出口）
                // v2.16：若此时正亮着长按卡，先把卡收掉（沉浸保持），再点一次才恢复整套 UI
                if uiHidden {
                    if tapPlace != nil || tipCard != nil {
                        closeTapPlace()
                        closeTipCard()
                        return
                    }
                    withAnimation(.easeOut(duration: 0.2)) { uiHidden = false }
                    return
                }
                // v1.98 规划态轻点地图：退出规划回首页（清路线、恢复底部主卡），
                // 不再弹地点卡——旧版在这里会叠一张地点介绍卡，挡住"回首页"的预期
                //
                // v2.56 必须排除导航态：导航是从方案卡点进来的，routeChoices 一直保留
                //（退出导航要回到预览页）。旧条件不排除导航，导致导航中点一下空白
                // 就被当成"退出规划"→ closeRoutePlan() 清空 route，
                // 而 navigating 还是 true，画面变成"导航卡还在、绿线没了"。
                if !model.routeChoices.isEmpty && !model.navigating {
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
            waypointMarks: model.waypoints.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) },
            searchLinkFrom: searchLinkFrom,
            searchLinkTo: searchLinkTo,
            searchHit: searchHitCoord.map { SearchHit(coord: $0, title: searchHitTitle) },
            keepHeadingFollow: true,
            focusCoord: model.focusCoord,
            focusTick: model.focusTick,
            traveledIdx: model.traveledIdx,
            navScaleTarget: model.navScaleTarget,
            navScaleTick: model.navScaleTick,
            onUserMovedChanged: { moved in
                // v2.22 导航中移动地图 → 收起提示卡，只留"继续导航"
                model.navUserMoved = moved
            },
            routeStartLink: model.routeStartLink,
            routeEndLink: model.routeEndLink,
            routeStartArrow: model.routeStartArrow,
            routeEndArrow: model.routeEndArrow
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
            .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 1))
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
                    // v2.23 只回中地图，不清路线（见 zoomOverlay 里的同名按钮）
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
            // v2.56 外形改成整颗胶囊（对齐"我的"页截图：外层是一整条圆头药丸，
            // 选中的一半在里面铺成蓝色胶囊），旧版是 22 圆角矩形，两头不是圆的
            // v2.57 白底：旧版 .ultraThinMaterial 是半透明毛玻璃，叠在浅色底图上透成灰白，
            // 跟"我的"页那条干净的白色 tab 条不是一个观感。改成 systemBackground
            //（浅色=纯白、深色=深灰，跟随系统），并去掉透过底图的那层脏色。
            .background(Color(.systemBackground), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
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
                parkingSection
                dataSection
                searchKeySection
                aboutSection
            }
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .alert("重命名常用地点", isPresented: Binding(
                get: { renamingQuickPoiId != nil },
                set: { if !$0 { renamingQuickPoiId = nil } }
            )) {
                TextField("名称", text: $renamingQuickPoiName)
                Button("保存") {
                    if let id = renamingQuickPoiId {
                        model.renameQuickPoi(id: id, newName: renamingQuickPoiName)
                        model.status = "已重命名"
                    }
                    renamingQuickPoiId = nil
                }
                Button("取消", role: .cancel) { renamingQuickPoiId = nil }
            } message: {
                Text("输入新的名称")
            }
            .alert(explainTitle, isPresented: $showExplain) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(explainBody)
            }
            .safeAreaInset(edge: .bottom) {
                // v2.56 底部常驻 tab 现在是浮在页面上的，列表末行（"到达目的地后自动记录…"）
                // 会被它压住一半 —— 这里补足 tab 高度，让最后一行能滚到它上面
                Color.clear.frame(height: 74)
            }
        }
    }

    // MARK: - 我的页分区（v1.97 顺序调整）

    /// 省电模式（放到最上方）
    private var powerSection: some View {
        Section {
            HStack {
                Toggle("省电模式", isOn: $powerSaveEnabled)
                    .onChange(of: powerSaveEnabled) { _, _ in
                        model.applyPowerSaving()
                    }
                explainButton("省电模式", "电量低于 20% 或系统低电量模式时，自动降低定位频率并调暗地图节省电量；恢复后自动还原。")
            }
        } header: {
            Text("省电")
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
        }
    }

    /// 常用地点：家 / 公司 / 收藏 / + / 自定义 合并为同一组
    private var commonPlacesSection: some View {
        Section {
            commonPlaceRow(icon: "house.fill", title: "家",
                           place: model.commonPlace(for: .home), slot: .home)
            commonPlaceRow(icon: "briefcase.fill", title: "公司",
                           place: model.commonPlace(for: .work), slot: .work)
            // v2.52 收藏搜索无结果提示（旧版列表直接变空，看不出是搜错了还是没收藏）
            if !favSearch.trimmingCharacters(in: .whitespaces).isEmpty && favoriteEntries.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text("未找到「\(favSearch)」")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
            }
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
                        .font(.subheadline)      // v2.51 11→15
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)   // v2.51 高度 30→36
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .textInputAutocapitalization(.never)
                }
            }
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
                HStack {
                    Label("语音播报", systemImage: "speaker.wave.2.fill")
                    Spacer()
                    explainButton("语音播报", "简洁：只报转弯与到达；标准：再加前方 800 米级提醒；详细：再加路名与剩余里程。")
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Toggle(isOn: Binding(
                    get: { model.avoidHighway },
                    set: { model.avoidHighway = $0 }
                )) {
                    Label("避开高速/高架", systemImage: "road.lanes")
                }
                explainButton("避开高速/高架", "规划时优先选择禁摩风险更少的方案；导航到风险路段前会语音提醒。")
            }

            // v2.29 自动视野（按速度切换近/中/远景）
            HStack {
                Toggle(isOn: Binding(
                    get: { model.autoNavScale },
                    set: { model.autoNavScale = $0 }
                )) {
                    Label("按速度自动切换视野", systemImage: "speedometer")
                }
                explainButton("按速度自动切换视野", "慢速看清下一个路口，上了快速路自动拉远看前方排队；手动调过视野后 20 秒内不会自动覆盖。")
            }

            // v2.34 E8 限速提醒阈值（无路网限速数据，统一阈值兜底；0=关闭）
            HStack {
                Menu {
                    ForEach([0, 40, 60, 80, 100, 120], id: \.self) { v in
                        Button(v == 0 ? "关闭" : "\(v) km/h") { model.speedLimitKph = v }
                    }
                } label: {
                    HStack {
                        Label("限速提醒", systemImage: "speedometer")
                        Spacer()
                        Text(model.speedLimitKph == 0 ? "关闭" : "\(model.speedLimitKph) km/h")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                explainButton("限速提醒", "超过设定速度时，导航底卡的速度数字变红提醒。没有路网限速数据，用统一阈值；设为关闭则不提示。")
            }

            // v2.29 骑行极简模式（竞品空白点）
            //
            // 调研发现：高德/百度只有"播报分级"，**没有一家做骑行视觉精简**。
            // 但摩托车骑手戴头盔，视野只有一条缝 —— 底卡塞满信息反而看不清。
            // 开启后：底卡只留「下一动作 + 距离 + 车速」，字号放大，
            // 隐藏车道图、红绿灯读秒、地图缩放组与比例尺。
            HStack {
                Toggle(isOn: Binding(
                    get: { model.ridingMinimalUI },
                    set: { model.ridingMinimalUI = $0 }
                )) {
                    Label("骑行极简界面", systemImage: "rectangle.on.rectangle.angled")
                }
                explainButton("骑行极简界面", "把屏幕信息降到最少、字号放大：只留下一动作、距离与车速，隐藏车道图、红绿灯读秒、缩放组与比例尺，适合戴头盔用余光看。")
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
        }
    }

    /// v1.99 足迹 / 离线地图 / 组队
    /// v2.39 I4 停车位置记忆：到达时自动记录，一键规划回程找车
    private var parkingSection: some View {
        let lat = UserDefaults.standard.object(forKey: "lastParkedLat") as? Double
        let lon = UserDefaults.standard.object(forKey: "lastParkedLon") as? Double
        let name = UserDefaults.standard.string(forKey: "lastParkedName") ?? ""
        let ts = UserDefaults.standard.object(forKey: "lastParkedTime") as? Double ?? 0
        return Section {
            if let lat, let lon, !name.isEmpty {
                Button {
                    haptic()
                    model.planRoute(to: name, lat: lat, lon: lon)
                    selectedTab = 0
                } label: {
                    HStack {
                        Label("上次停车位置", systemImage: "parkingsign.circle")
                            .foregroundStyle(.primary)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(name)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if ts > 0 {
                                Text(Date(timeIntervalSince1970: ts), style: .date)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            } else {
                Text("到达目的地后自动记录，可一键导航回程")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("停车")
        }
    }

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
            // v2.34 对比高德：误拖乱浮层后一键复位全部悬浮控件（罗盘/缩放/卡片回到默认位）
            Button {
                haptic()
                for k in ["routeplantop", "routeplanbottom", "categorybar", "bottommain",
                          "turnahead", "tapplace", "tipcard", "tripsummary",
                          "zoom", "exitnav2", "overviewbar", "navside"] {
                    UserDefaults.standard.removeObject(forKey: "\(k).x")
                    UserDefaults.standard.removeObject(forKey: "\(k).y")
                }
                NotificationCenter.default.post(name: .floatResetAll, object: nil)
                model.status = "悬浮控件位置已重置"
            } label: {
                HStack {
                    Label("重置悬浮控件位置", systemImage: "arrow.counterclockwise")
                    Spacer()
                    Text("一键复位")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func distanceText(_ m: Int) -> String {
        m >= 1000 ? String(format: "%.1f km", Double(m) / 1000) : "\(m) m"
    }

    /// v2.33 选项说明问号：点击弹出说明卡片（说明小字不再直接铺在设置页）
    private func explainButton(_ title: String, _ body: String) -> some View {
        Button {
            haptic()
            explainTitle = title
            explainBody = body
            showExplain = true
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 15))
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
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
                Label("机车地图", systemImage: "map.fill")
                    .foregroundStyle(.primary)
                Spacer()
                Text("骑行导航")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            HStack {
                Label("版本", systemImage: "info.circle")
                Spacer()
                // v2.24 取 Info.plist 的真实版本号（原来硬编码 "v2.09"，早就过期了）
                Text(appVersionText)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            // v2.27 优化建议 #25：开发者诊断隐藏入口 —— 连点版本号 7 次进入
            // （不用放进可见菜单里，普通用户不需要看到；但出了问题要能自助查看）
            .contentShape(Rectangle())
            .onTapGesture { handleVersionTap() }
            // v2.26 按要求删除「关于」分区底部的高德搜索 Key 选项
            // （Key 的设置入口保留在上面的「搜索设置」分区里，不再在页尾重复出现）
        }
    }

    // MARK: - v2.26 手动同步点位信息

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
        // v2.34 对比高德：长按常用地点 → 重命名 / 删除（删除也可左滑）
        .contextMenu {
            Button {
                haptic()
                renamingQuickPoiId = qp.id
                renamingQuickPoiName = displayName(qp.name)
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button(role: .destructive) {
                haptic()
                model.removeQuickPoi(id: qp.id)
                model.status = "已删除常用地点「\(displayName(qp.name))」"
            } label: {
                Label("删除", systemImage: "trash")
            }
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
                .padding(5)                 // v2.51 热区 34×30 → 44×40
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
        // v2.23 途经点选择模式：选中的点先成为"候选"（可对比时长、右侧确认后才加入）
        if waypointSelecting {
            selectWaypointCandidate(name: name, lat: lat, lon: lon)
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

            // v2.33 已删除规划态顶部路线胶囊：点击后搜索框不可见（规划卡遮挡 bottomMainCard），
            // 只会弹出键盘且无输入框，属无效按钮；改终点走返回箭头→重新搜索。
            // 地图缩放 + / - 按钮（含当前定位按钮）
            // 地点卡出现时暂时收起，避免整组压在卡片上

    /// 底部浮层：类别结果 + 历史 + 导航信息卡 + 去这里 + 搜索框/退出导航 + 清空路线
    private var bottomOverlay: some View {
        // v1.81.2 底部每张卡均可自由拖动，位置持久化（默认贴底序列）
        // v1.81.3 地点卡/路线规划卡出现时隐藏搜索主卡；两卡左滑关闭后恢复
        // v1.86 巡航模式下隐藏底部搜索卡（巡航视野干净，退出巡航恢复）
        ZStack {
            if !model.navigating && !model.cruiseMode {
                // v2.36 F1 到达/退出后行程卡显示期间：隐藏规划卡与类别条，
                // 避免"行程卡+起终点卡+方案卡"三卡叠屏、到达后误触"开始导航"
                if tapPlace != nil || tipCard != nil {
                    AnyView(poiCardStack)
                } else if !model.routeChoices.isEmpty && model.tripSummary == nil {
                    // v2.21 路线规划卡拆成上下两张（高德式）：
                    //   上卡 = 出发点/途经点/终点 + 服务小卡 + 沿途设施结果
                    //   下卡 = 方案卡 + 骑行风险 + 开始导航
                    // 两张卡都可独立上下拖动；下卡左滑关闭整条路线。
                    // v2.23 上卡固定在屏幕顶部：只能下拉，不能上拉顶出屏幕；
                    // 下次启动位置不记忆，永远回到顶部。
                    // v2.56 顶部卡下拖上限：旧版只钳到屏幕底部，用户几次斜向滑动（右滑带一点
                    // 下移会累积）就能把起终点卡拖到屏幕中部，压在方案卡上 —— 两张卡叠成一片，
                    // 下面那张还从半透明里透出字。这里按方案卡高度（约 250pt + 间隙）留出避让，
                    // 顶部卡最多下拖到方案卡上沿，两张卡永远不重叠。
                    // v2.60 起终点卡改为"硬贴顶"：不再做卡片间挤压，
                    // 默认位压到 0.04（约 35pt），层级抬到 60（高于下卡的 50），
                    // 用户实机里它长期整条不显示，先保证它在最上面稳定可见。
                    // v2.64 起终点卡：默认贴顶，全屏范围自由拖动（不再与下卡互斥）
                    DraggableFloat(key: "routeplantop", defaultPos: CGPoint(x: 0.5, y: 0.10),
                                   lockX: true, topLocked: true,
                                   onFrameChange: { planTopCardFrame = $0 },
                                   // v2.66 松手吸附：拖的时候和方案卡随便叠，
                                   // 松手后如果压住了方案卡，弹回方案卡顶边上方 8pt
                                   onDragEnded: { y in
                                       let sh = UIScreen.main.bounds.height
                                       guard planBottomCardFrame.minY > 0,
                                             planTopCardFrame.height > 0 else { return nil }
                                       let bottomEdge = y * sh + planTopCardFrame.height
                                       let limit = planBottomCardFrame.minY - 8
                                       guard bottomEdge > limit else { return nil }
                                       return (limit - planTopCardFrame.height) / sh
                                   }) {
                        AnyView(routePlanTopCard)
                    }
                    .zIndex(60)
                    // v2.23 底部锚定：pos.y 是卡片底边位置，卡片向上生长。
                    // 之前按中心定位（0.88），"开始导航"绿色按钮被屏幕下缘裁掉 → 点不动。
                    // v2.27：加 zIndex(50) 保证下卡永远盖在上卡之上。
                    // 上卡曾经因为内部一个 .frame(maxHeight: .infinity) 撑成巨大面板，
                    // 虽然 ZStack 顺序在下，但 .position() 的布局会让上卡的点击区域
                    // 覆盖到下卡按钮上 —— 按钮看得见却点不动。显式抬层级更稳。
                    // v2.60 resetOnAppear：方案卡每次进规划页都回贴底位。
                    // 它此前和地点卡同病 —— 拖过一次就被记忆在半空（用户截图里停在
                    // 屏幕中部、把下面的路线挡掉一半），作废机制几次都没彻底解决。
                    DraggableFloat(key: "routeplanbottom", defaultPos: CGPoint(x: 0.5, y: 0.97),
                                   lockX: true, bottomAnchor: true,
                                   deleteLabel: "删除",
                                   onSwipeLeft: { closeRoutePlan() },
                                   onFrameChange: { planBottomCardFrame = $0 },
                                   resetOnAppear: true,
                                   // v2.66 松手吸附：压住上卡时弹回，拖的过程不设限
                                   onDragEnded: { y in
                                       let sh = UIScreen.main.bounds.height
                                       guard planTopCardFrame.maxY > 0,
                                             planBottomCardFrame.height > 0 else { return nil }
                                       let topEdge = y * sh - planBottomCardFrame.height
                                       let limit = planTopCardFrame.maxY + 8
                                       guard topEdge < limit else { return nil }
                                       return (limit + planBottomCardFrame.height) / sh
                                   }) { AnyView(routePlanBottomCard) }
                        .zIndex(50)
                } else if model.tripSummary == nil {
                    // v2.66 删除地图常驻「分类条」：和搜索面板里的 6 宫格是同一批
                    // ServiceKind，两个入口做同一件事；高德只在搜索页给一次分类入口。
                    // categoryBar 定义保留，需要时可再挂。
                    // v1.99 移除地图上浮动的"历史搜索"横条：搜索框聚焦时面板内已有历史列表，
                    // 地图上再挂一条既挡视线又重复
                }
                // 搜索主卡：地点卡/路线规划卡/行程卡出现时隐藏；仅上下移动
                if searchActive {
                    // v2.54 搜索整屏：搜索框贴顶（安全区内），列表向下铺满整屏。
                    // 这里不再用 DraggableFloat —— 整屏搜索页不该能拖动，
                    // 也不该跟随键盘上下浮（键盘从底部弹出时列表自身滚动即可）。
                    VStack(spacing: 0) {
                        AnyView(bottomMainCard)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else if tapPlace == nil && tipCard == nil && model.routeChoices.isEmpty && model.tripSummary == nil {
                    // v2.51 键盘避让交给 DraggableFloat 的 extraBottomInset：
                    // 旧版手写 .offset(y: -300) 不受钳制约束，键盘高时会把卡片整个顶出屏幕上半，
                    // 且与安全区钳制叠加（卡片顶部跑出屏幕）
                    // v2.56 搜索卡上避让底部常驻 tab：卡片可以自由上下拖，
                    // 但不许拖到 tab 底下（原来 tab 在卡里，没有这个约束）
                    // v2.60 搜索卡改"底边锚定 0.89"（778pt）：底边与卡片高度无关，
                    // 无论有没有"回家/去公司"那一行、键盘弹不弹，卡底都压在 tab 条上沿上方 9pt。
                    // 上一版的"中心定位 0.88"在卡变高时底边会跟着往下探、压到 tab 上。
                    // v2.74 按用户要求：整张卡必须常驻屏幕最下方（高德首页就是贴底），
                    // 0.89 → 0.97（底边锚定，钳制会自动落在安全区底） + resetOnAppear
                    // 保证每次回首页都在底部，不会记住上次被拖到半空的位置。
                    DraggableFloat(key: "bottommain", defaultPos: CGPoint(x: 0.5, y: 0.97),
                                   lockX: true, bottomAnchor: true,
                                   resetOnAppear: true,
                                   onFrameChange: { bottomMainCardFrame = $0 },
                                   extraBottomInset: keyboardHeight,
                                   // v2.64 去掉"不许压 tab 条"的底部避让：卡片要能拖到屏幕最下
                                   // v2.62 去掉"搜索卡躲避定位点"（用户明确要求）：
                                   // 旧版为了不让卡片盖住定位蓝点，把卡片最高位置限在
                                   // 半屏 + 28pt，碰上卡片较高/实测高度异常时整张卡被推到底边外。
                                   // 定位点由系统跟随恒定在屏幕正中，卡片盖住它是可接受的，
                                   // 位置约束只保留"不许压 tab 条"这一条。
                                   ) {
                        AnyView(bottomMainCard)
                    }
                }
            } else {
                // v1.65：转向/速度/距离时间已合并到顶部 navTopBar，底部仅留路口放大
                // v2.32 默认位置上移 0.70→0.66：与退出卡清晰分层（路口放大图在上、退出卡贴底）。
                // v2.32 全览时一并隐藏：全览条在 y0.70，不清掉这两卡会叠在全览条上
                if !showRouteOverview {
                    // v2.63 位置 0.66 → 0.20：这个 110x110 的路口方块和顶部提示条
                    // 报的是同一件事（下一步怎么转、多远），却悬在屏幕中段，
                    // 正好横在中轴线把整条路线切成两截。高德的路口放大图只出现在屏幕上部，
                    // 这里跟着上移，中下部留给路线和定位箭头。
                    DraggableFloat(key: "turnahead", defaultPos: CGPoint(x: 0.5, y: 0.20)) { AnyView(turnAheadCard) }
                }
            }
        }
    }

    /// 长按/轻点出来的卡（地点卡 / 提示点卡）——互斥，只出一张。
    /// v2.16 抽成独立视图，好让「沉浸态」也能单独把这张卡亮出来而不带其它 UI。
    @ViewBuilder private var poiCardStack: some View {
        if let tp = tapPlace {
            // v1.95 轻点地图地点卡：与搜索地点卡同位置、同样式，左滑或点×关闭
            // v2.56 地点卡原来停在屏幕中部（0.66 屏高），横切在"我的位置→搜索点"的黑线中间，
            // 把连线和当前位置箭头都压住了。改成贴底悬浮（对齐高德地点卡），
            // 地图中上部完整露出，黑线一眼看全；左右可拖、上滑仍在。
            // v2.60 resetOnAppear：地点卡是"选中后临时弹出"的一次性卡片，
            // 不该记住被拖到哪儿 —— 历史上只要拖过一次，之后每次点搜索结果都会停在
            // 半空（用户实机里长期卡在 57% 屏高，压着路线）。改成每次出现都贴底。
            DraggableFloat(key: "tapplace", defaultPos: CGPoint(x: 0.5, y: 0.97), lockX: true,
                           bottomAnchor: true,
                           deleteLabel: "关闭",
                           onSwipeLeft: { closeTapPlace() },
                           resetOnAppear: true) { AnyView(tapPlaceCard(tp)) }
        } else if let t = tipCard {
            // v2.56 同 tapplace：贴底，不再横在画面中间遮路线
            DraggableFloat(key: "tipcard", defaultPos: CGPoint(x: 0.5, y: 0.97), lockX: true,
                           bottomAnchor: true,
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
    /// v2.23 收起搜索选点黑线（回到首页/清路线时）
    private func clearSearchLink() {
        searchLinkFrom = nil
        searchLinkTo = nil
        searchHitCoord = nil
        searchHitTitle = ""
    }

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

    /// v2.23 全局「返回上一级」（屏幕左右边缘往中间滑动触发）
    ///
    /// 按层级从最上往下退：
    ///   途经点选择态 → 退出选择；搜索联想/键盘 → 收起；
    ///   地点卡 → 关闭；路线规划 → 清除；"我的"页 → 回地图；
    ///   规划态顶部搜索框 → 回到地图首页；沉浸态 → 先恢复 UI。
    /// 导航中不响应（避免手势和导航操作打架）。
    @discardableResult
    private func goBackOneLevel() -> Bool {
        guard !model.navigating else { return false }
        if quickPickMode {
            quickPickMode = false
            pendingQuickCoord = nil
            showQuickNameAlert = false
            model.status = "已取消地图选点"
            return true
        }
        if waypointSelecting {
            waypointSelecting = false
            searchFocused = false
            dismissKeyboard()
            model.status = "已退出途经点选择"
            return true
        }
        if slotTarget != nil {
            slotTarget = nil
            model.status = "已退出常用地点设置"
            return true
        }
        if searchFocused || showSuggestions {
            searchFocused = false
            showSuggestions = false
            searchExpanded = false
            dismissKeyboard()
            return true
        }
        if tapPlace != nil {
            closeTapPlace()
            return true
        }
        if tipCard != nil {
            tipCard = nil
            tipRoad = nil
            tipAoiName = nil
            tipPolygon = nil
            return true
        }
        // v2.58 行程卡显示期间（导航已结束）任何返回动作都应退回首页：
        // 旧版这里缺分支，会落进下面的"退出规划"，只清了路线规划卡，
        // 行程卡还挂在屏幕上 —— 点地图/滑返都没有"回到首页"的效果。
        if model.tripSummary != nil {
            dismissTripAndReset()
            return true
        }
        // v2.56 同 onBlankTap：导航态不清路线（routeChoices 在导航中是有意保留的）
        if !model.routeChoices.isEmpty && !model.navigating {
            closeRoutePlan()
            clearSearchLink()
            model.status = "已退出路线规划"
            return true
        }
        if selectedTab == 1 {
            selectedTab = 0
            return true
        }
        if uiHidden {
            withAnimation(.easeOut(duration: 0.2)) { uiHidden = false }
            return true
        }
        return false
    }

    /// v2.23 边缘滑动返回：手指从屏幕左/右边缘（40pt 内）起手并向中间滑过 60pt 触发返回
    private func handleEdgeSwipe(startX: CGFloat, translation: CGFloat, screenW: CGFloat) -> Bool {
        let edge: CGFloat = 40
        let threshold: CGFloat = 60
        let fromLeft = startX <= edge
        let fromRight = startX >= screenW - edge
        guard fromLeft || fromRight else { return false }
        let inward = fromLeft ? translation : -translation
        guard inward > threshold else { return false }
        return goBackOneLevel()
    }

    /// v1.96 轻点非地点区域：收起全部卡片 + 隐藏所有浮层（只留右下角定位按钮），再轻点恢复
    private func hideAllOnBlankTap() {
        // v2.51 退出搜索时取消在途联想请求，避免旧响应回来覆盖/闪现
        if showSuggestions || searchFocused { tipTask?.cancel() }
        haptic()
        // 编辑态（常用地点设置 / 途经点选择）：只收卡片，不进入沉浸模式
        //（v1.97 常用地点设置；v2.33 途经点选择同语义——否则编辑提示条与搜索框会一起消失）
        if slotTarget != nil || waypointSelecting {
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





    /// v2.33 电警点位已移除（原「添加违法拍照」自动命名逻辑一并删除）
    /// 改类型时把名字里的类型一起换掉，否则会出现标题写"闯红灯"、标签标"超速"的矛盾。
    /// 用户自己改过名字的（不以"地图新增"开头）一律不动。


    private func tapPlaceCard(_ p: TapPlaceInfo) -> some View {
        // v2.02 重排：信息（名称/地址/距离）在上，操作按"次要图标 → 主按钮 → 上报"三层，
        // v2.33 电警点位已移除（原「添加违法拍照」入口一并删除）
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
                        .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    haptic()
                    let name = p.name
                    let lat = p.lat
                    let lon = p.lon
                    closeTapPlace()
                    model.clearPreview()
                    // v2.23 直接进导航，不经过路线规划界面
                    model.navigateDirect(to: name, lat: lat, lon: lon)
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
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .padding(.bottom, 12)

            Divider()

        }
        .background(Color(.systemBackground).opacity(0.94), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.black.opacity(0.06))
        )
        .shadow(color: .black.opacity(0.10), radius: 9, y: 4)
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
    /// v2.52 规划页"改目的地"：点终点行 → 清路线回首页并聚焦搜索
    /// （与导航底卡"搜索"入口同一套收尾，避免退出后停在一个没有搜索框的页面上）
    private func beginDestReselect() {
        haptic()
        closeRoutePlan()
        searchText = ""
        suggestions = []
        onlineTips = []
        searchLoading = false
        showSuggestions = false
        searchExpanded = false
        tipTask?.cancel()
        model.status = "请选择新的目的地"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            searchFocused = true
            uiHidden = false
        }
    }

    private func closeRoutePlan() {
        waypointSelecting = false
        model.route = []
        model.routeTurns = []
        model.routeChoices = []
        // v2.48 清掉规划卡屏幕框测量值：下次规划重新上报，避免用旧框算留白
        planTopCardFrame = .zero
        planBottomCardFrame = .zero
    }

    /// v2.28 路线规划卡（上）——按高德样式重做
    ///
    /// 参照高德 iOS 的路线规划态布局（用户截图）：
    ///   ┌────────────────────────────────────────┐
    ///   │ ‹   ● 我的位置                    ⇅  ＋ │  ← 返回 + 起终点 + 交换/加途经
    ///   │     ● 金辉锦绣云庭                       │
    ///   │ [🚗 苏U**A ▾] [🏍 摩托车] [🚌 公交] [偏好 ▾] │  ← 出行方式选择器
    ///   └────────────────────────────────────────┘
    ///
    /// 与旧版的差别：
    ///  · 起点/终点两行更紧凑（行距 8），左侧留出返回箭头的位置
    ///  · 右侧 ⇅ 与 ＋ 竖排（高德是横排，但竖排在窄屏更不容易和文字挤在一起）
    ///  · 新增「出行方式」选择器行：摩托车 / 汽车 / 公交 / 偏好
    ///    摩托车是本 App 的核心场景（禁摩路段规避、红绿灯播报），放第一个
    private var routePlanTopCard: some View {
        // v2.54 上卡瘦身：行距 10→8、纵向内边距 12→10，配合"贴顶"让地图可见带更大
        VStack(spacing: 8) {
            routePlanHeader
            // v2.29 起点被手动固定时的明示（竞品都没做好的机会点）
            originFixedNotice
            travelModeRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.systemBackground).opacity(0.94), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .padding(.horizontal, 14)
        // v2.27 兜底：上卡高度不许超过屏幕的 45%。
        // 之前按钮列写了 .frame(maxHeight: .infinity)，
        // 把上卡拉成从屏幕顶盖到下方的巨大白色面板，
        // 既挡住地图、又把下卡的"开始导航"按钮埋住导致点不动。
        // 加了这条上限，即便将来卡片内容再变多，也不会再撑爆。
        // v2.60 加 minHeight：内容一旦因为某个子行临时为空而塌缩，整卡会变成
        // 一条看不见的细缝（用户实机里"起终点卡整条不见"最像这个）。
        .frame(minHeight: 96, maxHeight: UIScreen.main.bounds.height * 0.45)
    }

    /// v2.29 「起点不是当前位置」的明示条
    ///
    /// 调研发现：Google 强制"起点必须是当前位置，否则降级为预览"；
    /// 高德/百度允许手动起点但**不告诉用户导航实际从哪开始**。
    /// 用户在规划卡上看到"出发点：XX"，实际导航要从那个点起步 ——
    /// 中间几公里他并没有意识到，到了那儿才被提示"请先去往出口"。
    ///
    /// 这里把这件事说清楚，并给一个一键纠正的按钮。
    /// 只有距离超过 300 米才提示（就在附近时提示是噪声）。
    @ViewBuilder
    private var originFixedNotice: some View {
        if let d = model.originDistanceFromUser(), d > 300 {
            HStack(spacing: 8) {
                Image(systemName: "figure.walk.departure")
                    .font(.caption2.bold())
                    .foregroundStyle(.orange)
                Text("将从「\(model.originName)」出发，距您约 \(d >= 1000 ? "\(d / 1000) 公里" : "\(d) 米")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    haptic()
                    model.resetOriginToCurrentLocation()
                } label: {
                    Text("从我这出发")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    /// v2.28 出行方式选择器（高德样式的一排胶囊按钮）
    ///
    /// 摩托车 / 汽车 切换会重新规划（摩托车走"避开禁摩路段"的策略）；
    /// 公共交通与代驾本 App 没有对应数据源，点击给出明确说明而不是静默无效。
    /// 「偏好」展开常用路线偏好（不走高速 / 躲避拥堵 / 少红绿灯）。
    private var travelModeRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach([AppModel.TravelMode.moto, .car], id: \.self) { m in
                    Button {
                        haptic()
                        guard model.travelMode != m else { return }
                        model.travelMode = m
                        model.replan()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: m.icon).font(.caption2)
                            Text(m.title).font(.caption2)
                        }
                        .foregroundStyle(model.travelMode == m ? .white : .blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(model.travelMode == m ? Color.blue : Color.blue.opacity(0.10),
                                    in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                // 偏好（展开常用路线偏好）
                Menu {
                    Toggle(isOn: Binding(
                        get: { model.avoidHighway },
                        set: { model.avoidHighway = $0; model.replan() }
                    )) {
                        Label("不走高速/高架", systemImage: "road.lanes")
                    }
                    Toggle(isOn: Binding(
                        get: { model.preferFewLights },
                        set: { model.preferFewLights = $0; model.replan() }
                    )) {
                        Label("优先少红绿灯", systemImage: "trafficlight")
                    }
                    Toggle(isOn: Binding(
                        get: { model.preferShortest },
                        set: { model.preferShortest = $0; model.replan() }
                    )) {
                        Label("优先距离最短", systemImage: "ruler")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3").font(.caption2)
                        Text("偏好").font(.caption2)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                }
            }
            .padding(.horizontal, 2)
        }
    }

    /// v2.28 路线规划卡（下）——按高德样式重做
    ///
    /// 参照高德 iOS（用户截图）：
    ///   ┌──────────────────────────────────────────┐
    ///   │ [1小时24分 ][1小时20分 ][306元起 ]  ← 横滑方案卡
    ///   │ 59公里 ⊕29   71公里 ⊕42   61.6公里       │
    ///   │ 距离短        备选二        代驾          │
    ///   ├──────────────────────────────────────────┤
    ///   │ ✦ 实时路况早知道，避开拥堵路段      更多 › │  ← 路况提示条
    ///   ├──────────────────────────────────────────┤
    ///   │ [全程1小时24分出发][全程1小时24分到达]   │  ← 两种出发方式
    ///   │ [省钱信息][更多]  [      开始导航      ]   │  ← 底部工具条
    ///   └──────────────────────────────────────────┘
    private var routePlanBottomCard: some View {
        // v2.54 卡片瘦身：删掉常驻路况行后，行距与内边距各收 2pt
        VStack(spacing: 8) {
            // ① 横滑方案卡
            routeChoiceCards

            // ② 路况 / 风险提示条（高德："实时路况早知道，避开拥堵路段"）
            routeStatusHintRow

            // ③ 沿路服务设施（加油/充电…）——高德放在方案区下方
            // v2.58 右边缘渐隐：这一行是横滑列表，屏幕窄时最后一项会被硬裁半个图标
            //（用户截图里"餐饮"只剩半个碗），看着像排版出错。垫一层 20pt 的同色渐变，
            // 视觉上变成"还有更多，往左滑"。
            serviceChipsRow
                .overlay(alignment: .trailing) {
                    LinearGradient(colors: [Color(.systemBackground).opacity(0),
                                            Color(.systemBackground)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 20)
                        .allowsHitTesting(false)
                }

            // ④ 底部工具条：省钱信息 / 更多 / 开始导航
            routePlanActionBar
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // v2.56 方案卡改成完全不透明：旧版是 0.96，和顶部起终点卡一旦重叠，
        // 下层卡片的白字就从这 4% 里透出来，整片糊在一起分不清哪张是哪张
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .padding(.horizontal, 14)
        // v2.48 高度上限：下卡内容最多占屏高一半，保证规划页始终留有看地图的可见带
        .frame(maxHeight: UIScreen.main.bounds.height * 0.5)
    }

    /// v2.28 路况 / 风险提示条（高德："✦ 实时路况早知道，避开拥堵路段  更多 ›"）
    ///
    /// 三种提示按优先级排：
    /// 1. 禁摩风险（红）—— 骑行场景最要紧，宁可多绕路
    /// 2. 拥堵/缓行段（橙）—— 高德同款提示
    /// 3. 无异常时给一句"实时路况早知道"（灰）
    /// v2.54 只在真有风险/拥堵时出现，无异常时整行不渲染。
    ///
    /// 用户对照高德截图指出：这条"✦ 实时路况早知道，避开拥堵路段"是常驻占位，
    /// 每个方案都白占约 34pt，把下卡撑得臃肿、地图可见带被压窄。
    /// 改成"有禁摩风险或有拥堵/缓行段"才提示 —— 该提示的价值就在异常时，正常时是噪声。
    @ViewBuilder
    private var routeStatusHintRow: some View {
        if !model.riderRisks.isEmpty || jamCount + slowCount > 0 {
            routeStatusHintContent
        }
    }

    private var routeStatusHintContent: some View {
        HStack(spacing: 6) {
            let blocked = model.riderRisks.first(where: { $0.kind.motoBlocked })
            let anyRisk = model.riderRisks.first
            let hasJam = jamCount + slowCount > 0

            Image(systemName: blocked != nil ? "exclamationmark.triangle.fill"
                  : (hasJam ? "car.fill" : "sparkles"))
                .font(.caption2.bold())
                .foregroundStyle(blocked != nil ? .red : (hasJam ? .orange : .secondary))

            Text(hintText(blocked: blocked, anyRisk: anyRisk, hasJam: hasJam))
                .font(.caption2)
                .foregroundStyle(blocked != nil ? .red : .secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if jamCount + slowCount > 0 {
                HStack(spacing: 3) {
                    Circle().fill(Color.red).frame(width: 5, height: 5)
                    Text("拥堵\(jamCount)").font(.caption2).foregroundStyle(.secondary)
                    if slowCount > 0 {
                        Circle().fill(Color.yellow).frame(width: 5, height: 5)
                        Text("缓行\(slowCount)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// 提示条文案（抽出来避免 ViewBuilder 里堆逻辑）
    private func hintText(blocked: RoadRisk?, anyRisk: RoadRisk?, hasJam: Bool) -> String {
        if let blocked {
            return "含禁摩路段：" + RiderAnalyzer.summary([blocked])
        }
        if let anyRisk {
            return RiderAnalyzer.summary(model.riderRisks)
        }
        if hasJam {
            return "实时路况早知道，已避开拥堵路段"
        }
        return "实时路况早知道，避开拥堵路段"
    }

    /// v2.28 底部工具条（高德：省钱信息 / 更多 / 发送车机 / 开始导航）
    ///
    /// 「开始导航」用高德蓝而不是旧版的绿色 —— 与地图上的路线色、定位点颜色统一，
    /// 视觉上更接近截图的整体观感。
    private var routePlanActionBar: some View {
        HStack(spacing: 10) {
            // v2.54 原叫"省钱信息"，但点开的实际内容是禁摩/限行风险摘要
            //（model.riderRisks），名不副实 —— 改名并把角标换成警示三角
            Button {
                haptic()
                model.status = model.riderRisks.isEmpty
                    ? "本方案无禁摩风险路段"
                    : RiderAnalyzer.summary(model.riderRisks)
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.footnote)
                    Text("禁摩提示")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
                .frame(width: 52)
            }
            .buttonStyle(.plain)

            // 更多（分享方案）
            Button {
                haptic()
                shareRoutePlan()
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "ellipsis")
                        .font(.footnote)
                    Text("更多")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
                .frame(width: 44)
            }
            .buttonStyle(.plain)

            // 开始导航（高德蓝大按钮）
            Button {
                haptic()
                model.toggleNavigation()
            } label: {
                Text("开始导航")
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)   // v2.51 43→约 47
                    .background(Color(red: 0.10, green: 0.42, blue: 0.92),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    /// v2.28 分享当前路线方案（文本 + 高德链接，可直接粘给车友）
    private func shareRoutePlan() {
        // v2.28：先取下标再取值，避免 guard let + 三元里 nil 与非 nil 分支混排
        // （那种写法 Swift 类型推断容易报错）
        let idx = model.selectedRouteIdx
        guard model.routeChoices.indices.contains(idx) else {
            model.status = "还没有可分享的路线"
            return
        }
        let c = model.routeChoices[idx]
        let km = String(format: "%.1f公里", Double(c.distanceM) / 1000.0)
        let text = "【\(model.destName)】\(durationTxt(c.durationS)) · \(km)"
            + (c.trafficLights >= 0 ? " · 红绿灯\(c.trafficLights)个" : "")
            + "（\(c.label)）"
        UIPasteboard.general.string = text
        model.status = "路线已复制到剪贴板"
    }

    /// v2.19 规划卡头部（高德式）：出发点在上、途经点居中、终点在下；
    /// 右侧竖排「交换」「添加途径点」；服务小卡（加油/充电…）贴在终点下方，
    /// 点类别 → 点结果即作为途经点加入，路线立刻重新规划并穿过该点。
    private var routePlanHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            // v2.28 返回箭头（高德截图最左侧的 ‹）
            // 作用：清掉当前路线规划，回到搜索态。
            Button {
                haptic()
                closeRoutePlan()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 28, height: 28)
                    .padding(8)                 // v2.51 热区 28 → 44
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 7) {
                // 出发点（绿点）
                HStack(spacing: 7) {
                    Circle().fill(Color.green).frame(width: 9, height: 9)
                    Text(model.originName)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                // 途经 1、2、3…（橙点 + 序号徽标 + 点击定位 + x 删除）
                ForEach(Array(model.waypoints.enumerated()), id: \.element.id) { i, wp in
                    HStack(spacing: 7) {
                        Circle().fill(Color.orange).frame(width: 9, height: 9)
                        // 序号徽标（高德式）
                        Text("\(i + 1)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 15, height: 15)
                            .background(Color.orange, in: Circle())
                        Text(wp.name)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        // v2.27 优化建议 #17：显示「距我 1.2 km」，方便判断顺序是否合理
                        let distText = model.waypointDistanceText(wp)
                        if !distText.isEmpty {
                            Text(distText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        // v2.27 优化建议 #15：上移/下移调序
                        // （iOS 上长按拖动排序成本高且易与卡片拖动手势冲突，按钮更稳）
                        Button {
                            haptic()
                            model.moveWaypoint(wp, offset: -1)
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.caption.bold())
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                        Button {
                            haptic()
                            model.moveWaypoint(wp, offset: 1)
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.caption.bold())
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                        // 点击途经点 → 地图定位到该点
                        Button {
                            haptic()
                            model.focusWaypoint(wp)
                        } label: {
                            Image(systemName: "scope")
                                .font(.footnote)
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
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
                    .contentShape(Rectangle())
                    .onTapGesture {
                        haptic()
                        model.focusWaypoint(wp)
                    }
                }
                // 终点（红点）—— v2.52 点这一行可改目的地（高德规划页同款入口）
                HStack(spacing: 7) {
                    Circle().fill(Color.red).frame(width: 9, height: 9)
                    Text(model.destName)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { beginDestReselect() }
                // v2.23 服务小卡只在 routePlanTopCard 里渲染一次（这里曾重复渲染一次，
                // 导致"加油/充电"小卡和设施列表出现两遍）
            }
            // 右侧按钮组（v2.23）：
            //   「＋」与起点/终点文字区**垂直居中对齐**（正后方），「⇅」放在其下方
            //
            // v2.27 修复：这里原来写的是 .frame(maxHeight: .infinity, alignment: .center)。
            // 那个"无限高"是致命的 —— HStack 的高度由最高的子视图决定，
            // 按钮列被撑到无限高后，整个上卡变成了一个巨大的白色面板，
            // 从屏幕顶部一路盖到下方，把"开始导航"按钮整个埋住了（点不动），
            // 同时上卡看起来"太大"。
            //
            // 正确做法：让按钮列按内容取高（不撑高），
            // 垂直居中交给 HStack 自身的 alignment: .center 来做。
            VStack(spacing: 12) {
                Button {
                    haptic()
                    beginWaypointSelect()
                } label: {
                    Image(systemName: "plus")
                        .font(.body.bold())
                        .foregroundStyle(.blue)
                        .frame(width: 32, height: 32)
                        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(Rectangle().inset(by: -6))   // v2.51 热区 32→44
                }
                .buttonStyle(.plain)
                Button {
                    haptic()
                    model.swapOriginDest()
                } label: {
                    // v2.54 上下箭头读不出"交换"，换成 swap 符号（同文件 3612 行已在用）
                    Image(systemName: "arrow.triangle.swap")
                        .font(.body.bold())
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 32)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(Rectangle().inset(by: -6))   // v2.51 热区 32→44
                }
                .buttonStyle(.plain)
            }
            // v2.27：固定为内容高度 + 垂直居中（HStack alignment 已保证居中，这里只是明确不撑高）
            .fixedSize(horizontal: false, vertical: true)
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
        model.cancelWaypointCandidate()
        model.status = "添加途经点：搜索地点或点地图选点，选完可对比时长再确认"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard waypointSelecting else { return }
            searchFocused = true
        }
    }

    /// v2.23 选中的搜索点 → 变成"候选途经点"（地图跳转 + 黑线 + 时长对比），不直接加入
    private func selectWaypointCandidate(name: String, lat: Double, lon: Double) {
        waypointSelecting = false
        searchFocused = false
        showSuggestions = false
        searchExpanded = false
        dismissKeyboard()
        let wp = RouteWaypoint(name: name, lat: lat, lon: lon)
        model.previewWaypointCandidate(wp)
        // 地图跳到该搜索点并居中 + 黑线连回我的位置
        let target = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        searchLinkTo = target
        searchLinkFrom = model.currentLocation
        model.focusCoord = target
        model.focusTick += 1
        model.status = "已选「\(name)」，对比时长后点右侧「添加」"
    }

    /// v2.23 候选途经点对比卡（点 ➕ 选点后出现）
    /// 左侧：候选点名称 + 「添加前 → 添加后」时长变化；右侧：「添加」确认按钮 + ✕ 取消
    private var waypointCandidateCard: some View {
        Group {
            if let cand = model.waypointCandidate {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Circle().fill(Color.orange).frame(width: 8, height: 8)
                            Text("途经点：\(cand.name)")
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        if model.viaCompareLoading {
                            HStack(spacing: 5) {
                                ProgressView().controlSize(.mini)
                                Text("正在计算时长…")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        } else {
                            // 添加前 → 添加后 时长变化（绿色=更快，橙色=更慢）
                            HStack(spacing: 5) {
                                Text("添加前 \(durationTxt(model.durationBeforeVia))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                Text("添加后 \(durationTxt(model.durationAfterVia))")
                                    .font(.caption2.bold())
                                    .foregroundStyle(viaDeltaColor)
                                if model.durationBeforeVia > 0 && model.durationAfterVia > 0 {
                                    Text(viaDeltaText)
                                        .font(.caption2.bold())
                                        .foregroundStyle(viaDeltaColor)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 4)
                    Button {
                        haptic()
                        model.confirmWaypointCandidate()
                        // 确认后：地图全览 起点→途经点→终点 的整条路线
                        model.overviewTick += 1
                        model.status = "已添加途经点，正在全览规划路线"
                    } label: {
                        Text("添加")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .frame(width: 62, height: 44)   // v2.51 38→44
                            .background(Color.blue, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    Button {
                        haptic()
                        model.cancelWaypointCandidate()
                        clearSearchLink()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(Color(.systemBackground).opacity(0.96), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .padding(.horizontal, 14)
            }
        }
    }

    /// v2.23 时长变化颜色：更快=绿，更慢=橙
    private var viaDeltaColor: Color {
        guard model.durationBeforeVia > 0, model.durationAfterVia > 0 else { return .secondary }
        return model.durationAfterVia <= model.durationBeforeVia ? .green : .orange
    }

    /// v2.23 时长变化文案
    private var viaDeltaText: String {
        guard model.durationBeforeVia > 0, model.durationAfterVia > 0 else { return "" }
        let d = model.durationAfterVia - model.durationBeforeVia
        if d == 0 { return "持平" }
        let m = abs(d) / 60
        let s = abs(d) % 60
        let txt = m > 0 ? "\(m)分\(s)秒" : "\(s)秒"
        return d < 0 ? "快\(txt)" : "慢\(txt)"
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

    /// 高德式路口放大示意图：接近下一转向时显示交叉路口 + 转弯箭头 + 路名
    /// v2.34 触发距离按车速动态调整：基准 200m + 当前车速(m/s)×3 秒行驶距离（上限 350m），
    /// 高速提前亮、低速贴近才亮，避免高速路口一闪而过或低速时卡片过早占屏。
    private var turnAheadCard: some View {
        Group {
            if let ns = model.navStatusCache,
               let t = ns.nextTurn,
               ns.distToTurnM < min(350, 200 + Int(model.currentSpeed * 3.0)) {
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
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .offset(y: 54)
                    }
                }
                .frame(width: 110, height: 110)
                .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal)
                .padding(.bottom, 4)
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
    /// v2.22 实现上移到 AppModel（顶部提示卡也要用），这里直接复用
    private func navTurnIcon(_ t: RouteTurn) -> String {
        model.navTurnIcon(t)
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
                        .padding(.vertical, 13)   // v2.51 43→约 47
                        .background(Color.green, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.horizontal)
                }
                .padding(.bottom, 4)
            }
            // v1.80 已移除选点"导航去此处"按钮（首页底部卡片化，选点导航入口精简）
        }
    }

    /// 高德式多路线方案：顶部"我的位置→目的地"，下方横排方案卡（大分钟+里程+标签）
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
        Group {
            if model.routeChoices.count == 1, let only = model.routeChoices.first {
                // v2.58 单方案铺满整行：旧版每张卡固定 116pt 宽，只有一条路线时
                // 左边一小块蓝框、右边空出 2/3 的白，看着像"还有方案没加载出来"。
                Button {
                    haptic()
                    model.selectedRouteIdx = 0
                    model.applyRouteChoice(only)
                } label: {
                    routeChoiceCard(only, index: 0, selected: true, fill: true)
                }
                .buttonStyle(.plain)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(model.routeChoices.enumerated()), id: \.offset) { idx, c in
                            Button {
                                haptic()
                                model.selectedRouteIdx = idx
                                model.applyRouteChoice(c)
                            } label: {
                                routeChoiceCard(c, index: idx, selected: model.selectedRouteIdx == idx)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
        .frame(height: 88)   // v2.54 100→88：方案卡瘦身，给地图多让出 12pt
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

    /// v2.28 单张方案卡（高德样式）
    ///
    /// 截图里的结构是三行：
    ///   1小时24分        ← 大字时长
    ///   59公里 ⊕29      ← 里程 + 红绿灯数（⊕ 是小红绿灯图标）
    ///   距离短           ← 标签（推荐/距离最短/等灯少/备选）
    ///
    /// 选中态用**高德蓝**描边（截图里选中的那张是蓝框），
    /// 不再用旧版的绿色 —— 绿色会和地图上的路线色撞色，看不出哪个被选中。
    private func routeChoiceCard(_ c: RouteChoice, index: Int, selected: Bool, fill: Bool = false) -> some View {
        let sel = selected
        // v2.29 禁摩风险徽标（竞品方案卡没有这个维度，但对摩托车最关键）
        let risk = model.choiceRisk(c, index: index)
        let distTxt = c.distanceM < 1000
            ? "\(c.distanceM)米"
            : String(format: "%.1f公里", Double(c.distanceM) / 1000.0)
        let accent = Color(red: 0.10, green: 0.42, blue: 0.92)
        return VStack(alignment: .leading, spacing: 4) {
            // 时长（大字）
            Text(durationTxt(c.durationS))
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(sel ? accent : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            // 里程 + 红绿灯数
            HStack(spacing: 5) {
                Text(distTxt)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                // 红绿灯个数（高德没给数据时不显示这一项）
                if c.trafficLights >= 0 {
                    // v2.58 旧版用 Image(systemName: "trafficlight")，这个符号在部分系统版本
                    // 上没有字形，渲染成 0 宽空白 —— 用户看到的就是里程后面孤零零一个"17"。
                    // 换成 emoji 保证一定有字形，并在数字后加单位"个"，语义不再悬空。
                    HStack(spacing: 2) {
                        Text("🚦").font(.system(size: 10))
                        Text("\(c.trafficLights)个")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
            }
            // 标签 + 禁摩风险徽标
            HStack(spacing: 4) {
                Text(c.label)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(sel ? .white : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(sel ? accent : Color(.tertiarySystemFill), in: Capsule())
                // 禁摩风险（只在有风险时显示，避免给用户添噪）
                if risk != .none {
                    Text(risk.shortLabel)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(risk.isBlocked ? Color.red : Color.orange, in: Capsule())
                }
            }
        }
        .frame(minWidth: 116, maxWidth: fill ? .infinity : 116, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(sel ? AnyShapeStyle(accent.opacity(0.07)) : AnyShapeStyle(Color(.secondarySystemBackground)),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(
            sel ? accent : Color.clear,
            lineWidth: sel ? 2 : 0))
    }

    /// 地图缩放 + / - 按钮（右下角，高德式；定位按钮在放大按钮上方）
    private var zoomOverlay: some View {
        // v1.97 修复定位按钮消失：旧版内容带 150 底部内边距，配合 6% 的顶部锚点会把整组顶出屏幕；
        // 改为紧凑竖排（定位 / + / -），位置由 DraggableFloat 负责
        VStack(spacing: 5) {
                    // 当前定位按钮（放大按钮上方，非导航中显示；点击清空路线规划回到主页）
                    if !model.navigating {
                        Button {
                            haptic()
                            // v2.23 只做"地图回到我的位置"，不再清路线/退出规划界面。
                            // 旧版这里调 clearRoute()，一点定位就把用户踢回首页，
                            // 规划中的路线和卡片全没了。
                            model.centerOnUser()
                        } label: {
                            ZStack {
                                Circle().fill(.white)
                                Circle().strokeBorder(.black.opacity(0.08), lineWidth: 1)
                                Image(systemName: "scope")
                                    .font(.title3)
                                    .foregroundStyle(Color(red: 0.16, green: 0.38, blue: 1.0))
                            }
                            .frame(width: 40, height: 40)
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
                            .frame(width: 40, height: 40)
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
                            .frame(width: 40, height: 40)
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
        }
    }

    /// 高德式顶部导航条：剩余里程 + 时间 + 下一转向预告（<500米显示，高德顶部主条样式）
    /// v1.65 顶部导航综合条（高德式合并布局，自上而下不重叠）：
    /// 第一行：剩余距离 + 剩余时间 + 实时速度；第二行：下一转向指示（图标+距离+路名+车道）
    /// v1.84 巡航模式顶部卡片（白底，高德同款）：实时速度，右上角×关闭巡航
    /// v2.34 E3 定位权限被拒横幅（点"去设置"跳系统设置）
    private var locationDeniedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "location.slash.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.red)
            Text("需要定位权限才能导航")
                .font(.caption.bold())
                .foregroundStyle(.white)
            Spacer(minLength: 4)
            Button {
                haptic()
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("去设置")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.red.opacity(0.9), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 14)
    }

    /// v2.34 E9 首次使用轻量引导（见一次即关）
    private var introBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "helmet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("首次使用提示")
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
                Text("① 上滑搜索目的地  ② 点地图地点直接规划  ③ 骑行 300 米自动巡航")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Button {
                haptic()
                UserDefaults.standard.set(true, forKey: "hasSeenIntro")
                showIntro = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color(.systemGray6), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground).opacity(0.96), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
        .padding(.horizontal, 14)
    }

    private var cruiseCard: some View {
        // v2.38 H2 速度读数四舍五入（Int 截断会少显示 1 km/h：82.9→82）
        let speed = Int((model.currentSpeed * 3.6).rounded())
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
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        // v2.37 G2 深色模式黑底黑字修复：跟随外观
                        .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                    Text("km/h")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            // v2.34 E6 巡航中想搜索/改目的地：点放大镜直接进搜索（退出巡航并聚焦搜索框）
            // v2.36 F3 改用 exitCruise：搜索是临时让位，不应抑制巡航自动进入
            //（否则搜完不导航，本次会话巡航再也回不来）；只有 × 才是明确"不要巡航"
            Button {
                haptic()
                model.exitCruise()
                // v2.51 保险：巡航时若残留规划路线，先回首页（否则搜索卡不显示，按钮等于失效）
                if !model.routeChoices.isEmpty { closeRoutePlan() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    searchFocused = true
                    searchExpanded = false
                    uiHidden = false
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline.bold())
                    .foregroundStyle(.blue)
                    .frame(width: 28, height: 28)
                    .background(Color.blue.opacity(0.1), in: Circle())
                    .padding(6)                 // v2.51 热区 28→40（视觉不变）
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // v2.34 E5 手动退出巡航：本次使用内不再自动进入
            Button {
                haptic()
                withAnimation(.easeOut(duration: 0.2)) { model.dismissCruiseManually() }
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .top)
        // v2.32 固定 150pt → 屏幕高度 18%：iPhone SE(667) 与 17 Pro Max(874) 上位置比例一致
        .position(x: UIScreen.main.bounds.width / 2, y: UIScreen.main.bounds.height * 0.18)
    }


    @ViewBuilder private var bottomLayerGroup: some View {
        // v2.23 候选途经点对比卡（点 ➕ 选点后出现，右侧「添加」确认）
        if !model.navigating && model.waypointCandidate != nil {
            AnyView(waypointCandidateCard)
                .frame(maxHeight: .infinity, alignment: .bottom)
                // v2.50 改用规划下卡实测高度：固定 96 在"下卡内容多/极简模式"时会压住
                // "开始导航"按钮（两层浮卡重叠）；高德是让候选卡始终浮在底卡上沿外 8pt
                // 基准换算：候选卡容器底在安全区内（= 屏底上移 home indicator 34pt），
                // 而 planBottomCardFrame 是屏幕坐标，所以要减掉这一段
                .padding(.bottom, planBottomCardFrame.minY > 0
                         ? max(96, UIScreen.main.bounds.height - 34 - planBottomCardFrame.minY + 8)
                         : 96)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(15)
        }
        // v1.66：沉浸模式下底部内容隐藏（导航中同样可收起，导航卡单独渲染不受影响）
        if !uiHidden {
            AnyView(bottomOverlay)
        } else if !model.navigating {
            // v2.16 沉浸态长按：整套 UI 继续隐藏，只把"长按出来的那张卡"亮出来
            AnyView(immersiveCardLayer)
        }
        // v2.37 G1 状态反馈 toast：顶部居中胶囊（安全区内），不拦截手势
        if statusVisible {
            VStack {
                Text(model.status)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.78), in: Capsule())
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                Spacer()
            }
            .safeAreaPadding(.top, 8)   // v2.50 状态胶囊不压状态栏
            .frame(maxWidth: .infinity, alignment: .center)
            .allowsHitTesting(false)
            .zIndex(150)
            .transition(.opacity)
        }
        // v1.85 行程卡显示期间：轻点卡片以外任意位置回首页（透明拦截层）
        if model.tripSummary != nil {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { haptic(); dismissTripAndReset() }
        }
        // v1.81.4 本次行程卡：结束导航后显示
        if let s = model.tripSummary {
            DraggableFloat(key: "tripsummary", defaultPos: CGPoint(x: 0.5, y: 0.62), lockX: true,
                           deleteLabel: "删除",
                           onSwipeLeft: { dismissTripAndReset() },
                           onFrameChange: { tripCardFrame = $0 }) { AnyView(tripSummaryCard(s)) }
        }
        // v1.69 高德地图加载失败诊断条（黑屏根因提示 + 重试）
        if mapLoadFailed {
            AnyView(mapLoadBanner)
        }
    }

    /// v2.25 地图页顶部浮层组（指南针 / 路名胶囊 / 路线胶囊 / 缩放 / 比例尺）
    ///
    /// 抽出来的原因：body 里的 ZStack 分支太多（导航 + 巡航 + 沉浸 + 规划 + 我的），
    /// Swift 编译器在单次表达式里推断不出类型，会报
    /// "the compiler is unable to type-check this expression in reasonable time"。
    /// 拆成独立 ViewBuilder 属性后，每段单独推断，问题消失。
    @ViewBuilder
    private var mapTopOverlayGroup: some View {
        // v1.85 指南针/GPS 默认位置统一上移到最高处（屏幕顶部）
        // v1.86 全览时一并隐藏（贴高德全览界面），取消全览恢复
        if !showRouteOverview {
            // v2.28 按用户要求删除界面指南针（原 compassOverlay 挂载点）。
            // 朝向数据本身保留 —— 导航时地图仍跟随手机方向自动旋转。
            // v1.90 顶部居中道路名胶囊（导航中显示当前道路名）
            if model.navigating { AnyView(roadNamePill) }
            // v2.33 已删除规划态顶部路线胶囊：点击后搜索框不可见（规划卡遮挡 bottomMainCard），
            // 只会弹出键盘且无输入框，属无效按钮；改终点走返回箭头→重新搜索。
            // 地图缩放 + / - 按钮（含当前定位按钮）
            // 地点卡出现时暂时收起，避免整组压在卡片上
            //
            // v2.29 骑行极简模式：隐藏缩放组与比例尺。
            // 头盔视野下这两块是纯视觉噪声，而且缩放按钮在骑行中几乎不用
            //（有"视野"档位按钮就够了）。屏幕上少两块，地图信息更干净。
            if !model.ridingMinimalUI {
                // v2.63 规划态也显示缩放组：旧条件只认"没地点卡、没提示卡"，
                // 而选中地点进入规划后 tapPlace 仍在，整组 +/−/3D 被一起隐藏 ——
                // 用户 v2.58 截图里"起终点卡与缩放组同时不见"就是这条。
                if (tapPlace == nil && tipCard == nil) || !model.routeChoices.isEmpty {
                    // v2.54 底部卡片避让：规划态下卡约 250pt、行程卡约 215pt，
                    // 否则右侧 +/−/3D 会被卡片压住半个（看着在、点不到）
                    // v2.55 避让量改成"卡片实测屏幕框"推导。
                    // 旧版写死 215/250 是按瘦身前的估算卡高拍的：卡片内容一变高
                    //（多方案、加禁摩提示行、途经点变多），−/3D 就重新被压住半个。
                    // 卡片占据的底部高度 = 屏幕高 − 卡片顶边 y，这个值恒等于真实占位。
                    // v2.64 缩放组不再按卡片实测框避让（卡片要全屏自由拖）
                    DraggableFloat(key: "zoom", defaultPos: CGPoint(x: 0.885, y: 0.22),
                                   ) { AnyView(zoomOverlay) }
                }
                // v2.72 按用户要求彻底删除右上角比例尺（不再挂载）。
                // 它此前占着右上角、还逼着导航顶部条留 92pt 让位；
                // 距离感由顶部条的"还多久/多远"和地图本身表达，比例尺是重复信息。
                // scaleOverlay 定义保留，需要时可再挂回。
            }
        }
    }

    /// v2.54 导航态方位环
    ///
    /// 用极淡的白色环（填充 7%、描边 20%）＋ 10pt 方位字，避免挡住路线与箭头 ——
    /// 用户在头盔镜片下看的是路，这个环只是"北在哪"的一次性参照，不该抢视觉。
    /// 圆环固定画在屏幕 0.65 高度（导航跟随态用户点所在位置）。

    /// v2.54 高德同款速度表：导航态左上角独立圆形（白底、蓝字大数字、下方 km/h）
    ///
    /// 高德这个表并不在底部卡里 —— 底部卡只放"剩余时间/里程/到达时刻"，
    /// 速度是卡外左上角的一个圆（用户对比截图确认）。旧版把速度塞在底部卡
    /// 第二层最右侧 19pt，属于"底部卡里的一条小读数"，位置和形态都不对。
    /// 位置按安全区顶 + 72 偏移，正好落在顶部提示条下沿。
    private var navSpeedGauge: some View {
        let d: CGFloat = 68
        let speed = Int((model.navStatusCache?.speedKph ?? 0).rounded())
        let overSpeed = model.speedLimitKph > 0 && speed > model.speedLimitKph
        return GeometryReader { geo in
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.95))
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.07), lineWidth: 1))
                    .shadow(color: .black.opacity(0.20), radius: 5, y: 2)
                VStack(spacing: -3) {
                    Text("\(speed)")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(overSpeed ? Color.red
                                         : Color(red: 0.16, green: 0.38, blue: 1.0))
                    Text("km/h")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.55))
                }
            }
            .frame(width: d, height: d)
            // v2.55 遮挡修正：原偏移 72 时圆盘顶边落在提示卡"双行"状态下会压进去 12pt
            //（提示卡顶 55 + 高 56 单行 / 76 双行）。量高德截图：提示卡底到圆盘顶留 13pt，
            // 这里取 88 让双行时也留 4pt，单行时 8→24pt 略松但绝不再压。
            .position(x: 12 + d / 2, y: geo.safeAreaInsets.top + 88 + d / 2)
        }
        .allowsHitTesting(false)
    }

    /// v2.54 高德同款路程进度条：贴屏幕右边缘的竖直细线（起点在上、终点在下）
    ///
    /// 和 v2.22 那一版（v2.33 已删）的区别，正是它被当成"灰条纹"的原因：
    /// - 旧版轨道 5pt + white.opacity(0.22)，叠在深色底图上呈蓝灰，整条像一道划痕；
    ///   现在轨道压到 3pt / opacity 0.10，只有绿段经过的地方才看得出"这条线存在"。
    /// - 旧版已走段是 max(4, h*p)，起步 27 米 / 6.8 公里 = 0.4% 时只有 4pt，
    ///   被 5pt 轨道整个盖住 → 屏幕上只剩一条灰线，用户根本认不出这是进度条。
    ///   现在已走段最小 6pt 且与轨道同宽，起步就是一段可见的绿线。
    /// - 补了当前位置白点（带阴影）和终点空心圆：零进度时白点停在顶部起点，
    ///   整条线因此"有起点、有终点、有当前位置"，语义完整。
    /// v2.74 导航 HUD 的统一显隐口径：原来这一串条件在 3 处各写一遍，
    /// 以后加任何一种"临时收起 HUD"的原因都要记得改 3 个地方，漏一处就出现半截状态。
    private var navHUDVisible: Bool {
        model.navigating && !showRouteOverview && !uiHidden
    }

    private var navProgressBar: some View {
        GeometryReader { geo in
            // v2.56 语义反转 —— 对齐高德：绿色代表「剩余路程」，不是「已走过」。
            //
            // 高德实机（导航刚开始）是「一整条绿 + 底部一个蓝点」：绿色是还没走的路，
            // 蓝点是你的位置。越往前蓝点越往上爬、绿条越短，一眼看出"还剩这么长"。
            // 上一版做成了「绿条从底部往上长 = 已走部分」，方向对了但语义反了 ——
            // 刚出发时整条是灰的，看着像"还没开始"。
            //
            // 现在：绿段贴顶（高度 = h × 剩余比例），轨道灰段即已走部分，
            // 蓝点贴在绿灰分界处自下而上移动。
            let h = geo.size.height * 0.60
            let p = max(0, min(1, model.navProgress))
            let left = h * (1 - p)          // 剩余路程（绿，贴顶）
            let w: CGFloat = 12             // v2.70 6→12：高德那条绿竖线在实机上是 12pt 量级，6pt 太细看不清进度
            ZStack(alignment: .top) {
                // v2.58 白色底衬：这条竖线与主路线同为绿色、又恰好挨在右边缘，
                // 两条绿线贴一起时用户分不清哪个是路线、哪个是进度。
                // 垫一层不透明白底把进度条从底图上"抠"出来。
                Capsule()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: w + 3, height: h + 3)
                    .offset(y: -1.5)
                // 轨道（整条路程；已走部分就露出这层灰）
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: w, height: h)
                    .overlay(
                        Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                    )
                // 剩余路程（绿，从顶端往下）
                Capsule()
                    .fill(Color(red: 0.20, green: 0.80, blue: 0.36))
                    .frame(width: w, height: left)
                    .animation(.easeOut(duration: 0.6), value: left)
                // 当前位置：蓝圆 + 白边（高德同款，比纯白点在浅色底图上清楚得多）
                Circle()
                    .fill(Color(red: 0.16, green: 0.38, blue: 1.0))
                    .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                    .frame(width: 11, height: 11)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(y: left - 5.5)
                // 终点（顶端）：白圆底 + 蓝色前进箭头
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: 13, height: 13)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(Color(red: 0.16, green: 0.38, blue: 1.0))
                }
                .offset(y: -1)
            }
            .frame(width: 16, height: h)
            .position(x: geo.size.width - 15, y: geo.size.height * 0.44)
        }
        .allowsHitTesting(false)
    }

    /// v2.25 导航浮层组（顶部提示卡 / 退出按钮 / 全览条 / 左侧竖排）
    /// v2.33 曾按要求移除右侧竖直路程进度条；v2.54 按"高德同款"重做并加回
    @ViewBuilder
    private var navOverlayGroup: some View {
        // v2.54 导航态方位环（对齐高德）：定位点周围一圈极淡的环 + 东南西北四方位字
        // 作用：导航态地图跟着车头转，屏幕上方不等于正北，转弯/岔路时容易搞丢方向；
        // 环上四个方位字随 heading 实时旋转，一眼能看出"北在哪"。
        //
        // 位置是固定的（导航跟随态用户点就稳定落在屏幕下方这一带），
        // 所以不需要把用户坐标反投影成屏幕点、也就不需要 MapView 每帧回调 SwiftUI
        //（那种回路在 v2.02 踩过：回调里改 @State 触发 updateUIView 循环卡死）。
        // heading 直接用已有的 model.heading。
        // v2.58 浏览态（navUserMoved）整套导航 HUD 收起：只留底部卡上的"继续导航"，
        // 否则方位环/进度条/速度表会停在"车在 65% 屏高"的旧假设位置上，
        // 与真实车位置脱节，看着像几个飘着的孤儿控件。
        // v2.74 定位环（compassRing）连同定义一起删除。
        // v2.65 已关掉挂载，但留下了 `if false, …` 和一个完整的视图定义 ——
        // 那种写法最坑人：以后想改"导航态方位显示"，搜到 compassRing 改完，
        // 屏幕上不会有任何变化。高德的方位环是围绕车画的，我们的是写死屏高 65%，
        // 要重做必须走真实投影，旧代码本身没有复用价值。
        // v2.70 平移地图只暂停"跟随"，不再把 HUD 一起收走：
        // 旧版一碰地图 speed/进度条就全消失，只看一眼路线就得点「继续导航」才回来。
        // 高德导航态平移时这些常驻，速度是骑行最不该消失的信息。
        if navHUDVisible {
            AnyView(navProgressBar)
        }
        if navHUDVisible {
            AnyView(navSpeedGauge)
        }
        // v2.22 顶部路线提示卡（"请先去往出口"/"前方xx米路口直行"）
        // v2.58 浏览态同样收起：旧版只切了状态卡，结果"前方直行到达终点"和
        // "继续导航"两个黑条同屏并存，逻辑上互相矛盾。
        if model.navigating && !showRouteOverview && !model.navUserMoved {
            AnyView(navTopHintBar)
                // v2.72 比例尺已删，92pt 的让位一起撤掉：顶部条回到贴边全宽
                .padding(.trailing, 4)
                .frame(maxHeight: .infinity, alignment: .top)
                // v2.50 用 safeAreaPadding：ZStack 里既有全屏地图（ignoresSafeArea）
                // 也有安全区内容，固定 8 在"全屏坐标系"下会压到状态栏/灵动岛下面
                .safeAreaPadding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
        // 导航中悬浮退出按钮（仅上下移动；全览时隐藏）
        if model.navigating && !showRouteOverview {
            // v2.02 贴底摆放（高德导航卡片位置）
            // v2.56 导航底卡强制贴底（对齐高德导航底栏）：
            // 卡片一旦被拖到屏幕中部，就会横切整条路线、压住右下角当前位置和 −/3D，
            // 而且位置会记进 UserDefaults，之后每次导航都停在半空。
            // 改成 bottomAnchor 常驻贴底，旧坐标由 DraggableFloat 的 posV 一并作废。
            DraggableFloat(key: "exitnav2", defaultPos: CGPoint(x: 0.5, y: 0.97), lockX: true,
                           bottomAnchor: true) { AnyView(exitNavOverlay) }
        }
        // v1.81.4 导航全览操作条（固定全览 / 取消全览）
        if model.navigating && showRouteOverview {
            DraggableFloat(key: "overviewbar", defaultPos: CGPoint(x: 0.5, y: 0.70), lockX: true) { AnyView(routeOverviewBar) }
        }
        // v1.63 导航态左侧竖排：刷新 / 极简
        // v2.58 默认位置 0.50 → 0.72：原来这排正好落在屏幕中部左侧，
        // 加上右上角的 +/− 把前方路线的可视区从两边各切掉一条。下移让开中轴。
        // v2.66 用户要求：删除导航态左侧「刷新 / 极简 / 远景」三个按钮。
        // 它们压在屏幕左侧 7% 位置，正是车与前方路线最常经过的一带；
        // 而且刷新用尾部转向自动重算、极简在「我的」页有设置项、视野档位本就按速度自动切，
        // 三个常驻按钮都在替已经自动化的东西重复提供手动入口。
        // navSideOverlay 定义保留（含 navScaleTitle / navScaleIcon），需要时再挂回。
    }

    /// v2.22 导航顶部路线提示卡（高德式）
    ///
    /// 文案规则（自定义刷新）：
    /// · 起步阶段（还没驶入主线）→ "请先去往出口"
    /// · 行驶中 → "前方xx米路口直行/右转/左转"，xx = 当前位置到该路口的距离
    ///   距离 > 60 米时只报动作不报米数（米数每秒都在变，读起来跳）
    /// v2.63 顶部条距离文案：与播报同一套分级（>300 米不显示个位，避免读数每秒跳）
    private func topHintDistance(_ m: Int) -> String {
        if m >= 1000 { return String(format: "%.1f公里", Double(m) / 1000.0) }
        if m >= 100 { return "\((m / 10) * 10)米" }
        if m >= 60 { return "\((m / 10) * 10)米" }
        return "\(max(1, m))米"
    }

    private var navTopHintBar: some View {
        // v2.27（优化建议 #8/#9/#10）：
        //   · 数据源从 navTopHintText 换成 currentGuidanceEvent()，
        //     与语音播报共用同一份事件（两者不会再出现"说的和显示的不一样"）；
        //   · 距离分级：>300 米不显示米数；60~300 米取整到 10 米；≤60 米精确；
        //   · 副行显示「进入 XX 路 · 走第 N 车道」（车道数据高德本来就有，之前没用上）。
        let event = model.currentGuidanceEvent()
        return Group {
            if !event.text.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: event.icon)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 1) {
                        // v2.63 主次分离（对齐高德）：把"还多远"抽出来单独放大，
                        // 动作文字退居第二视觉。高德那条里 28 比路名大一倍，
                        // 骑行时眼睛只扫一眼数字就知道该准备转没有。
                        HStack(spacing: 6) {
                            if event.distanceM > 0 {
                                Text(topHintDistance(event.distanceM))
                                    .font(.system(size: 27, weight: .heavy))
                                    .foregroundStyle(.white)
                                    .monospacedDigit()
                            }
                            Text(event.action.isEmpty ? event.text : event.action)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white.opacity(0.95))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        // 副行：进入哪条路 + 走第几车道
                        if !event.subtitle.isEmpty || !event.laneHint.isEmpty {
                            HStack(spacing: 6) {
                                if !event.subtitle.isEmpty {
                                    Text(event.subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.82))
                                        .lineLimit(1)
                                }
                                if !event.laneHint.isEmpty {
                                    Text("· \(event.laneHint)")
                                        .font(.caption2)
                                        .foregroundStyle(.green.opacity(0.95))
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    // 车道图标（推荐车道高亮）
                    if !event.laneIcons.isEmpty {
                        HStack(spacing: 3) {
                            ForEach(Array(event.laneIcons.enumerated()), id: \.offset) { idx, icon in
                                Image(systemName: icon)
                                    .font(.caption2.bold())
                                    .foregroundStyle(idx == event.recommendedLane ? Color.green : .white.opacity(0.45))
                            }
                        }
                    }
                    // v2.63 顶部条右端播报开关（对齐高德）：旧版只有底部卡第二行有喇叭，
                    // 骑行中想一键静音得先低头找底卡。这里顶部常驻一个，位置和手都够得着。
                    Button {
                        haptic()
                        model.toggleVoice()
                    } label: {
                        Image(systemName: model.voiceMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(model.voiceMuted ? Color.white.opacity(0.45) : .white)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.86), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
                .padding(.horizontal, 12)   // v2.72 比例尺已删，顶部条不再让位，改为贴边全宽
            }
        }
    }

    /// v1.65 退出导航按钮：最下方中间，加大红色胶囊（骑行时单手易点）
    private var exitNavOverlay: some View {
        // v2.02 按高德导航底部卡片重做：
        //   位置贴底、高度固定（旧版红绿灯/车道行"有就插、没有就撤"→ 卡片高度反复跳变）
        //   左侧灰色圆形 ×、右侧浅灰圆角"全览"，中间三段大数字（剩余/用时/到达）
        // v2.60 贴底：这个 VStack 没有 Spacer，默认按内容垂直居中 ——
        // 导航底卡（6.5 公里 / 14 分钟 / 预计到达）因此在屏幕正中悬着，
        // 下方露出一整条地图。补 Spacer 撑满后内容自然沉到最下方。
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if model.navigating {
                if showExitConfirm {
                    HStack(spacing: 10) {
                        Button {
                            haptic()
                            showExitConfirm = false
                            model.toggleNavigation()
                            // v2.51 从"搜索"入口进来的退出：再回首页并把搜索框叫起来
                            //（只 toggleNavigation 会停在规划页，而规划页不显示搜索框）
                            if pendingSearchAfterExit {
                                pendingSearchAfterExit = false
                                closeRoutePlan()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                    searchFocused = true
                                    searchExpanded = false
                                    uiHidden = false
                                }
                            }
                        } label: {
                            Text("退出导航")
                                .font(.headline.bold())
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color(red: 0.85, green: 0.20, blue: 0.18),
                                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        Button {
                            haptic()
                            showExitConfirm = false
                            pendingSearchAfterExit = false
                        } label: {
                            Text("继续导航")
                                .font(.headline.bold())
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                    .padding(.horizontal, 12)
                } else if model.navUserMoved {
                    // v2.22 用户在导航中移动了地图：整张提示卡收起，
                    // 只在底部正中留一个"继续导航"按钮（点它回到定位点并恢复视野）
                    Button {
                        haptic()
                        model.navUserMoved = false
                        // v2.49 恢复导航视野：按当前速度重新定档。
                        // （旧版写死 500 米/厘米 = 整屏近 15km，等于把地图拉到看不见路）
                        model.setNavScale(model.autoNavScaleTarget(snap: true))
                        model.navigateFollowTick += 1
                    } label: {
                        Text("继续导航")
                            .font(.headline.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 26)
                            .padding(.vertical, 12)
                            .background(Color.black.opacity(0.72), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                } else if let ns = model.navStatusCache, ns.remainM > 0 {
                    navBottomCard(ns)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 贴底但不压 home indicator：34pt 安全区 + 10pt 呼吸位
        .safeAreaPadding(.bottom, 10)
    }

    /// v2.02 高德式导航底部卡（内容分三层，总高度恒定 → 不再跳动）
    private func navBottomCard(_ ns: AppModel.NavStatus) -> some View {
        // v2.29 修复「底部提示卡纯黑」（用户截图）
        //
        // 根因：背景用的是 Color(.systemBackground)，**深色模式下它就是纯黑**；
        // 而卡内所有文字用的是 Color.black.opacity(0.88)（mainFg/dimFg）——
        // 于是变成"黑底黑字"，一个字都看不见，屏幕上只剩一块纯黑矩形。
        //
        // 高德的做法是导航底卡**始终用浅色**（夜间也不反色），
        // 这样骑行时无论系统主题如何，读数都清晰。
        // 这里跟随外观设置：浅色模式用 systemBackground（白），
        // 深色模式用固定深灰（不用纯黑，避免和地图底图糊在一起）。
        let isDark = colorScheme == .dark
        // v2.73 用户反馈"卡片比地图显眼"：底色由完全不透明降到 0.94，
        // 让底图纹理透一点出来，卡片不再是一块硬白板
        let cardBg = isDark ? Color(white: 0.16).opacity(0.94) : Color(.systemBackground).opacity(0.94)
        let dimFg = isDark ? Color.white.opacity(0.62) : Color.black.opacity(0.42)
        let mainFg = isDark ? Color.white.opacity(0.95) : Color.black.opacity(0.88)
        // v2.29 骑行极简模式：字号放大（头盔视野窄，字要更大才看得清）
        let minimal = model.ridingMinimalUI
        let actionFontSize: CGFloat = minimal ? 18 : 14
        // v2.37 G3 速度是骑行最核心读数，层级不应低于公里/分钟：
        // 普通 17→19，极简 21→22（极简档已整体放大）
        // v2.54 速度读数移出底部卡，改为左上角独立圆形表（高德同款，见 navSpeedGauge）
        // v2.47 Q2 剩余 <1km 显示米（高德式）：800 米比 0.8 公里直观
        let remainMv = max(ns.remainM, 0)
        let kmTxt = remainMv < 1000 ? "\(remainMv)" : String(format: "%.1f", Double(remainMv) / 1000.0)
        let kmUnit = remainMv < 1000 ? "米" : "公里"
        let minTxt = "\(max(ns.remainS, 0) / 60)"
        let arriveTxt: String = {
            // v2.28：DateFormatter 创建成本很高（每次都要解析格式串、读系统设置），
            // 而这段在 body 求值期执行 —— 导航中每秒重算几十次，纯浪费。
            // 改成静态复用。
            Self.hhmmFormatter.string(from: Date().addingTimeInterval(TimeInterval(max(ns.remainS, 0))))
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
                    Text(kmUnit)
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
                        .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                // v2.39 I2 导航中切换备选路线（高德式）：方案列表 sheet，applyRouteChoice 应用
                if model.routeChoices.count > 1 {
                    Button {
                        haptic()
                        showRouteSwap = true
                    } label: {
                        Image(systemName: "arrow.triangle.swap")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(mainFg)
                            .frame(width: 40, height: 34)
                            .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.trailing, 12)
            .padding(.leading, 10)
            .frame(height: 46)

            // v2.45 O1 全程路况概览条（高德式）：一眼看全程哪里拥堵
            // 绿底 + 黄/红覆盖拥堵段；trafficSpans 为高德路线真实路况
            if !model.trafficSpans.isEmpty, ns.remainM > 0 {
                trafficOverviewBar(spans: model.trafficSpans,
                                   totalM: Double(max(model.routeDistanceM, 1)))
            }

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
                            .font(.system(size: actionFontSize, weight: .semibold))
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
                    // v2.22 去掉"继续直行"提示（无转向时这一层留空即可）
                    EmptyView()
                }
                Spacer(minLength: 4)
                // v2.34 E7 播报中指示：最近 2.5s 内有播报 → 喇叭亮（风噪大时也能确认播报发生）
                // v2.39 I3 喇叭改可点按钮：导航中一键静音/恢复（高德式），静音态灰色斜杠
                Button {
                    haptic()
                    model.toggleVoice()
                } label: {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let speaking = Date().timeIntervalSince(model.lastSpeakAt) < 2.5
                        Image(systemName: model.voiceMuted ? "speaker.slash.fill"
                               : (speaking ? "speaker.wave.2.fill" : "speaker.wave.2"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(model.voiceMuted ? .gray
                                             : (speaking ? Color(red: 0.16, green: 0.38, blue: 1.0) : dimFg))
                    }
                }
                .buttonStyle(.plain)
                // v2.42 L1 导航中搜索入口移到第二层（原第一层 5 段在 iPhone SE 375pt 宽溢出，
                // 放大镜被挤出屏外；第二层转弯文字可压缩，放得下）
                Button {
                    haptic()
                    // v2.51 旧版直接 toggleNavigation：一按导航就没了（误触即丢导航），
                    // 而且退出后停在规划页 —— 规划页不显示搜索框，这个"搜索"按钮实际半个失效。
                    // 改为与"×"同一套确认：确认后结束导航 + 回首页 + 聚焦搜索。
                    pendingSearchAfterExit = true
                    showExitConfirm = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(mainFg)
                        .frame(width: 34, height: 30)
                        .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .padding(5)                 // v2.51 热区 34×30 → 44×40
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(height: 32)

            // ── 第三层：固定高度槽位（红绿灯 / 车道 / 空）──
            // 旧版是"有内容才插入"，高度在 0/34 之间来回变 → 整张卡片上下跳
            //
            // v2.29 骑行极简模式：这一层整体不渲染。
            // 头盔视野下车道图和红绿灯读秒都是视觉噪声（调研确认竞品都还在显示这些），
            // 极简档把它们全交给语音，屏幕只留"下一步做什么 + 多远 + 多快"。
            if !minimal {
                ZStack {
                    if let nl = model.nextTrafficLight {
                        lightCountdownRow(nl)
                    } else if let t = ns.nextTurn, ns.distToTurnM > 0, ns.distToTurnM < 300 {
                        laneGuideRow(t, dimFg: dimFg, mainFg: mainFg)
                    }
                }
                .frame(height: 32)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.02))
            }
        }
        // v2.63 圆角 18 → 28（高德导航底卡是胶囊级圆角），并加一条顶部拖动指示条：
        // 高德那条细灰线不装饰，是"这张卡能上滑展开"的提示，缺了它用户不知道能拉。
        .background(cardBg, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(
            isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.07), lineWidth: 1))
        .overlay(alignment: .top) {
            Capsule()
                .fill(isDark ? Color.white.opacity(0.28) : Color.black.opacity(0.14))
                .frame(width: 36, height: 4)
                .padding(.top, 6)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)   // v2.73 0.28/12 → 0.16/8：投影轻了卡片才"浮"而不"压"
        .padding(.horizontal, 12)
    }

    /// v2.01 红绿灯倒计时行（导航卡顶部）：信号灯图形 + 红/绿 + 剩余秒 + 距离
    ///
    /// v2.29：文字颜色原先硬编码为黑色，深色模式下又是"黑底黑字"。
    /// 改为跟随底卡配色（浅色模式黑字、深色模式白字）。
    /// v2.45 O1 全程路况概览条：按里程比例把缓行黄/拥堵红画在绿底上
    private func trafficOverviewBar(spans: [TrafficSpan], totalM: Double) -> some View {
        // 预计算每段起止里程（沿路线方向累计），避免在视图闭包里可变累计
        let ranges: [(start: Double, end: Double, level: Int)] = {
            var acc = 0.0
            var out: [(Double, Double, Int)] = []
            for sp in spans {
                var d = 0.0
                for i in 0..<max(0, sp.points.count - 1) {
                    d += model.distanceM(sp.points[i], sp.points[i + 1])
                }
                out.append((acc, acc + d, sp.level))
                acc += d
            }
            return out
        }()
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.green.opacity(0.22)).frame(height: 6)
                ForEach(ranges, id: \.start) { r in
                    if r.level >= 1 {
                        let w = max(4, geo.size.width * (r.end - r.start) / totalM)
                        Capsule()
                            .fill(Color([UIColor(red: 0.94, green: 0.36, blue: 0.20, alpha: 1),
                                         UIColor(red: 0.98, green: 0.76, blue: 0.18, alpha: 1),
                                         UIColor(red: 0.94, green: 0.36, blue: 0.20, alpha: 1),
                                         UIColor(red: 0.62, green: 0.10, blue: 0.10, alpha: 1)][max(0, min(3, r.level))]))
                            .frame(width: w, height: 6)
                            .offset(x: geo.size.width * r.start / totalM)
                    }
                }
            }
        }
        .frame(height: 6)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func lightCountdownRow(_ nl: (light: TrafficLight, dist: Int)) -> some View {
        // v2.44 N1 红绿灯状态/秒数原是固定周期推算（非实时信号灯数据），
        // 显示"红灯 23 秒"会给骑手错误预期（实际灯色与周期完全不同）。
        // 改为只显示高德路线数据中的真实信息：路口有信号灯 + 距离。
        let isDark = colorScheme == .dark
        let subFg = isDark ? Color.white.opacity(0.6) : Color.black.opacity(0.45)
        let lampBg = isDark ? Color.black.opacity(0.55) : Color.black.opacity(0.85)
        return HStack(spacing: 6) {
            Image(systemName: "light.beacon.max.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 0.13, green: 0.62, blue: 0.30))
            Text(nl.dist > 8 ? "前方 \(nl.dist) 米 · 红绿灯" : "已到路口 · 注意信号灯")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(subFg)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .background(lampBg, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
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
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
                    .background(Color(.systemBackground).opacity(0.97), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
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
                    .background(Color(.systemBackground).opacity(0.97), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }

    /// v2.24 App 版本号（读 Info.plist，构建时注入 MARKETING_VERSION）
    private var appVersionText: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return b.isEmpty ? "v\(v)" : "v\(v) (\(b))"
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
        // v2.55 清掉行程卡实测框：否则下次行程开始前，−/3D 会按上一张卡的旧高度提前上移
        tripCardFrame = .zero
        // v2.56 修"导航结束后起点终点还连着黑线"：
        // 搜索选点时挂上的 searchLink（黑线 + 命中点彩点）只在两处清，都不覆盖
        // "导航结束→行程卡→关闭"这条路，所以回到首页后黑线和彩点一直留在图上。
        clearSearchLink()
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
    /// v2.54：目的地从标题行右侧的小灰字改为独立一行（层级太弱读不出"这是去哪"）；
    ///        第三格"公里/小时"改"平均时速"（原标签会被读成瞬时速度）；
    ///        标题行右侧补起止时间（原卡只给里程/用时，回看时不知道是哪一段）。
    private func tripSummaryCard(_ s: AppModel.TripSummary) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "flag.checkered.circle.fill")
                    .foregroundStyle(.green)
                Text("本次行程")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Text(tripTimeRange(s))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: 4) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(s.destName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            HStack(spacing: 0) {
                exitStatusCell(String(format: "%.1f", Double(s.distanceM) / 1000.0), "公里")
                exitCellDivider
                exitStatusCell("\(s.durationS / 60)", "分钟")
                exitCellDivider
                exitStatusCell(String(format: "%.1f", s.avgSpeedKmh), "平均时速")
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(Color(.systemBackground).opacity(0.97), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .padding(.horizontal, 14)
    }

    /// v2.54 行程卡起止时间（09:48–09:53）。formatter 只建一次——
    /// 这项目曾有"body 求值期反复格式化导致卡顿"的老坑（见文件头 16 行注释）。
    private static let tripClockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func tripTimeRange(_ s: AppModel.TripSummary) -> String {
        let f = Self.tripClockFormatter
        let end = s.startAt.addingTimeInterval(TimeInterval(s.durationS))
        return "\(f.string(from: s.startAt))–\(f.string(from: end))"
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
                    // v2.32 顶部下移到提示卡下方：提示卡(top 8, 高约66~78)与路名胶囊(top 58)重叠约16pt，
                    // 深色导航中白卡叠黑胶囊视觉糊成一团；移到 88 后两者垂直排开。
                    .safeAreaPadding(.top, 88)
            }
            Spacer()
        }
    }


    private func dismissKeyboard() {
        searchFocused = false
        voiceSearch.stop()   // v2.52 收起键盘时同时结束录音，避免后台持续占用麦克风
        // 收起键盘（同步给 focus 状态）
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// v2.51 搜索框"取消"（高德同款）：清空输入、收起列表与键盘、回到首页地图
    private func cancelSearch() {
        searchText = ""
        suggestions = []
        onlineTips = []
        searchLoading = false
        showSuggestions = false
        searchExpanded = false
        searchFocused = false
        tipTask?.cancel()
        dismissKeyboard()
    }

    /// v1.81 点"搜索"：收起键盘、展开联想地点列表（搜索框与底部按钮拉开，中间铺满），按距离近→远
    private func expandSearchResults() {
        dismissKeyboard()
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { model.status = "请输入目的地"; return }
        searchExpanded = true
        showSuggestions = true
        searchLoading = true   // v2.51 占位行显示"正在搜索…"
        Task {
            let tips = await model.amapInputTips(q)
            if searchText.trimmingCharacters(in: .whitespaces) == q {
                onlineTips = sortedByDistance(tips)
                searchLoading = false
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
        model.routeTurns = []
        model.routeChoices = []
        // v2.25 地图跳转到该搜索点并保持居中，同时：
        //   · 高亮显示该点（橙色定位环 + 名称）
        //   · 用黑线把"我的位置"和"搜索点"连起来，一眼看出直线距离与方位
        //   · 保持 followWithHeading —— 转动手机时地图继续跟随朝向变化
        let target = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        searchLinkTo = target
        searchLinkFrom = model.currentLocation
        searchHitCoord = target
        searchHitTitle = name
        // v2.58 选中搜索结果后把目的地推到「地图可用区」正中：
        // 旧版只换了标注和连线，地图没动，命中点常常落在屏幕上方甚至被卡片压住。
        // focusTick 那条路径用的是 setVisibleMapRect + edgePadding(mapViewportInsets)，
        // 会把点放在"扣掉底部卡片之后"的可见区域中心，而不是整屏中心。
        model.focusCoord = target
        model.focusTick += 1
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
        searchLoading = true   // v2.51 占位行显示"正在搜索…"
        model.status = "正在搜索「\(t.name)」周边…"
        Task {
            let around = await model.placeAround(lat: t.lat, lon: t.lon)
            onlineTips = sortedByDistance(around)
            searchLoading = false
            if around.isEmpty { model.status = "「\(t.name)」周边暂无结果" }
        }
    }

    /// v1.81 地点信息卡：距离 / 摩托时间 / 所在道路
    private func tipInfoCard(_ t: AppModel.AmapTip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "mappin.circle.fill")
                    .foregroundStyle(.green)
                Text(t.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()

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
                    // v2.23 直接进导航，不经过路线规划界面
                    model.navigateDirect(to: t.name, lat: t.lat, lon: t.lon)
                } label: {
                    Text("导航")
                        .font(.subheadline.bold())
                        .foregroundStyle(.blue)
                        .frame(width: 76, height: 44)   // v2.51 40→44
                        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.blue, lineWidth: 1.5))
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
                        .frame(width: 76, height: 44)   // v2.51 40→44
                        .background(Color.blue, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color(.systemBackground).opacity(0.95), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .padding(.horizontal, 14)
    }


    /// v1.80 首页底部主卡片：搜索框 + 导航/我的 合并为一个整体卡片
    private var bottomMainCard: some View {
        return VStack(spacing: 6) {
            // v2.74 删掉这一行"回家 / 去公司"：它和聚焦后的快捷卡片行（家 / 公司 / 收藏 / ＋）
            // 是同一批数据的两种呈现，一个在卡内一个在卡外，用户会以为进了两个不同的面板。
            // 快捷目的地只在搜索面板里出现一次（高德也是这个做法）。
            AnyView(searchInputRow)
            // v2.63 高德式 6 宫格：搜索框下面一排彩色圆分类，点一下直接搜周边。
            // 旧版只有键盘上方的横向 chips 条，一是要滚，二是颜色没分层，
            // 骑行停在路边想找加油站要滑两下才看到。
            if searchFocused && searchText.isEmpty && slotTarget == nil {
                AnyView(quickCategoryGrid)
            }
            // v1.69：搜索框聚焦且未输入 → 快捷卡片（家/公司/+）+ 历史搜索记录（高德样式）
            // v1.97 常用地点设置态不弹快捷卡片（避免误点跳到导航）
            if searchFocused && searchText.isEmpty && slotTarget == nil {
                AnyView(quickAccessPanel)
            }
            if showSuggestions && !suggestions.isEmpty && !model.navigating {
                AnyView(suggestionsList)
            }
            // 高德 POI 联想候选（填写高德 Key 后显示，点击直接定位；v1.86 导航中不弹出避免挡导航）
            if showSuggestions && !model.navigating {
                if onlineTips.isEmpty {
                    // v2.51 占位：旧版列表为空就直接消失，用户分不清"没搜到"还是"还在搜"
                    if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        AnyView(searchPlaceholderRow)
                    }
                } else {
                    AnyView(onlineTipsList)
                }
            }
            // v2.68 用户要求把「搜索框」和「tab 按钮」合并成一张卡（高德首页就是这种）：
            // 搜索框在上，导航/我的 一行在下，整块一起上下拖。
            // 搜索整屏页不挂 tab（高德搜索页也没有）。
            if !searchActive {
                // 普通态整卡是透明底（只留搜索胶囊），tab 行必须自带白底胶囊，
                // 否则未选中的"我的"是透明按钮、文字直接压在地图上读不清。
                // 已在整卡白底之内，tab 行不再自带胶囊（否则卡里套一层壳，边线打架），
                // 只留一条极细分割线做层次
                Divider().opacity(0.35)
                AnyView(tabButtonsRow)
                    .padding(.top, 2)
            }
        }
        // v2.74 一张卡的内部留白：左右 10、上 10、下 8
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
        // v2.54 搜索整屏态：卡片退成整面白色面板（不透明、无圆角、无投影），
        // 普通态保持原来的毛玻璃浮卡
        // v2.58 普通态去掉外层卡片底：旧版 .ultraThinMaterial 会在搜索胶囊外围
        // 再糊一层灰白矩形，把底图压暗一圈。去掉后只剩里面那条白色搜索胶囊浮在地图上，
        // 跟高德首页一致；搜整屏态仍铺白面板（列表要有实底可读）。
        // v2.66 搜索整屏从"整块铺白到屏幕四边"改成顶部圆角 28 的大卡：
        // 高德搜索页是"顶部白卡 + 四角露出地图"，白色压满全屏会让人失去位置感。
        // v2.74 搜索框与 tab 合成"一张卡"：整块白底 + 圆角，不再是两个分开的白胶囊。
        // 底色同样取 0.94（v2.73 的降重逻辑），透一点底图纹理，不硬压在地图上。
        .background(searchActive ? AnyShapeStyle(Color(.systemBackground))
                                 : AnyShapeStyle(Color(.systemBackground).opacity(0.94)),
                    in: RoundedRectangle(cornerRadius: searchActive ? 28 : 26, style: .continuous))
        // 透明底上再描边/投影会在胶囊外围画出一个空矩形，一并去掉
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color.black.opacity(0), lineWidth: 1))
        .shadow(color: .black.opacity(0), radius: 0, y: 0)
        // 背景透明后命中区不能只依赖可见内容，否则拖动时手指落在胶囊两侧的空白会落空
        .contentShape(Rectangle())
        // v2.59 这里原来还有一条 .padding(.horizontal, searchActive ? 0 : 4)，
        // 和上面的 20 叠成 24pt，卡片比底部 tab 条窄 8pt、左边缘不齐 —— 已删。
    }

    /// v2.63 高德式 6 宫格（彩色实心圆 + 名称，一行铺满）
    private var quickCategoryGrid: some View {
        HStack(spacing: 0) {
            ForEach(ServiceKind.allCases) { k in
                Button {
                    haptic()
                    searchFocused = false
                    dismissKeyboard()
                    if model.serviceKindActive == k {
                        model.clearServices()
                    } else {
                        Task { await model.loadServices(k) }
                    }
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(LinearGradient(colors: [k.tint.opacity(0.92), k.tint],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 46, height: 46)
                            Image(systemName: k.icon)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        Text(k.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(model.serviceKindActive == k ? k.tint : .primary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10)
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
            .padding(.horizontal, 10)
            .padding(.vertical, 7)     // v2.51 chip 高 25→32
            .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// v1.80 导航/我的 选项卡按钮行（合并进底部主卡片；"我的"页仍保留独立选项卡可切回）
    private var tabButtonsRow: some View {
        HStack(spacing: 6) {
            Button {
                selectedTab = 0
                searchFocused = false
                showSuggestions = false
                searchExpanded = false
                dismissKeyboard()
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
                .frame(maxWidth: .infinity, minHeight: 44)   // v2.51 两栏统一 44（旧版 43/47 不齐）
                .padding(.vertical, 2)
                .background(selectedTab == 0 ? Color.blue : .clear, in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                selectedTab = 1
                slotTarget = nil
                // v2.51 切页复位搜索态：否则切到「我的」页键盘/联想列表仍挂在屏幕上
                searchFocused = false
                showSuggestions = false
                searchExpanded = false
                dismissKeyboard()
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
                            // v2.23 历史记录项加大：字号 caption→subheadline，
                            // 加水平内边距与最小点击高度，手指在车上也点得准
                            Text(name)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)   // v2.51 chip 高 32→38
                                .background(Color(.secondarySystemBackground), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
            Spacer(minLength: 6)
            Button("清空") {
                model.clearHistory()
            }
            .font(.caption)
            .foregroundStyle(.blue)
            .padding(.horizontal, 8)
            .frame(minHeight: 40)          // v2.51 热区 22×14 → 40
            .contentShape(Rectangle())
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
        // v2.23 缩小：78×58 → 64×48（输入时"家/公司/+"卡不再抢地方，留给历史记录）
        VStack(spacing: 1) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(sub)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 64, height: 48)
        .background(.bar, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { action() }
    }

    /// 搜索输入行：高德样式白底大圆角（放大镜 + 输入 + ✕ + 搜索按钮为一体）
    /// v2.51 搜索框右侧动作按钮：聚焦态 =「取消」（高德同款），未聚焦态 =「搜索」
    /// 单独成 View：searchInputRow 的 ViewBuilder 分支已够多，再塞 if/else 有类型推断超时风险
    @ViewBuilder
    private var searchActionButton: some View {
        // v2.54 修正：整屏搜索态必须始终给"取消"。
        // 原来只判 searchFocused，而点"搜索"进整屏时 expandSearchResults() 会先
        // dismissKeyboard()（focus 变 false），按钮就退回成"搜索"——再点还是"搜索"，
        // 整屏搜索页永远退不出去（用户实机"点了没反应"的另一半就在这里）。
        if searchActive || searchFocused {
            Button {
                haptic()
                cancelSearch()
            } label: {
                Text("取消")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                    .frame(minWidth: 44, minHeight: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Button {
                // v1.81：点搜索 → 收起键盘，展开联想地点列表（搜索框与按钮拉开，中间铺满）
                expandSearchResults()
            } label: {
                Text("搜索")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .frame(minHeight: 40)   // v2.51 按钮高 31→40
                    .background(Color(red: 0.0, green: 0.75, blue: 0.95), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    /// v2.52 搜索框右侧控件组：清空 / 麦克风 / 搜索·取消
    /// 抽出来是为了让 searchInputRow 只剩「图标 + 输入框 + 控件组」，避免 ViewBuilder 分支过多
    /// 触发 Xcode 16 的 type-check 超时（v2.47 那次踩过）
    @ViewBuilder
    private var searchTrailingControls: some View {
        if !searchText.isEmpty {
            Button {
                searchText = ""
                suggestions = []
                onlineTips = []
                searchLoading = false
                showSuggestions = false
                searchExpanded = false   // v2.51 清空同时复位展开高度（旧版会留 400pt 空白面板）
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 21))
                    .foregroundStyle(.gray)
                    .frame(width: 40, height: 40)   // v2.51 热区 40pt（旧版图标仅 15pt，骑车点不准）
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        // v2.52 麦克风：v2.23 曾因"语音搜索未实现"摘掉，现已接入 iOS 原生识别
        if !searchFocused {
            Button {
                haptic()
                if voiceSearch.isListening {
                    voiceSearch.stop()
                } else {
                    model.invalidateAudioSession()   // 让 TTS 播报之后重新激活播放会话
                    voiceSearch.start { text in
                        searchText = text
                        suggestions = []
                        showSuggestions = !text.trimmingCharacters(in: .whitespaces).isEmpty
                        searchExpanded = false
                    }
                }
            } label: {
                Image(systemName: voiceSearch.isListening ? "waveform" : "mic.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(voiceSearch.isListening ? .red : .gray)
                    .frame(width: 40, height: 40)   // v2.52 40pt 热区
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(voiceSearch.isListening ? "停止语音输入" : "语音输入目的地")
        }
        searchActionButton
    }

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
                    onlineTips = []
                    // v2.51 300ms 防抖 + 取消旧请求：旧版每敲一个字就发一次高德请求，
                    // 快速输入/删字时并发多请求，弱网下卡顿且耗流量
                    tipTask?.cancel()
                    let q = newValue.trimmingCharacters(in: .whitespaces)
                    guard !model.amapKey.isEmpty, !q.isEmpty else {
                        searchLoading = false
                        return
                    }
                    searchLoading = true
                    tipTask = Task {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        if Task.isCancelled { return }
                        let tips = await model.amapInputTips(q)
                        if Task.isCancelled { return }
                        if searchText == newValue {
                            // v1.81：按距当前定位点 近→远 排序
                            onlineTips = sortedByDistance(tips)
                            searchLoading = false
                        }
                    }
                }
            // 清除 / 麦克风 / 搜索·取消（v2.52 抽成一组，见 searchTrailingControls）
            searchTrailingControls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)      // v2.51 40pt 高按钮 + 6 上下 = 52，保持搜索框原高度
        .frame(maxWidth: .infinity)
        .frame(minHeight: 58)
        // v1.63：跟随系统深浅色（浅色白底/深色深底，夜间骑行不刺眼）
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    /// v2.51 联想占位行：搜索中转圈 / 未找到文案
    private var searchPlaceholderRow: some View {
        HStack(spacing: 8) {
            if searchLoading {
                ProgressView().controlSize(.small)
                Text("正在搜索…")
            } else {
                Image(systemName: "magnifyingglass")
                Text("未找到「\(searchText.trimmingCharacters(in: .whitespaces))」相关地点")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.quaternary))
        .padding(.horizontal)
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
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.quaternary))
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
                                .font(.caption)          // v2.51 字号 11→12
                                .foregroundStyle(tipSort == idx ? .white : .secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)   // v2.51 点击区 22→28
                                .frame(minHeight: 28)
                                .contentShape(Rectangle())
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
                                    .font(.callout)      // v2.51 15→16，头盔里主标题要看得清
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(tip.sub)
                                    .font(.caption)      // v2.51 11→12
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            // v1.81：名称右侧、箭头左侧显示距当前定位点距离
                            if let d = distText(tip.lat, tip.lon) {
                                Text(d)
                                    .font(.caption.bold())   // v2.51 11→12
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
                                // v2.23 途经点选择模式：箭头也走候选流程（不直接规划）
                                if waypointSelecting {
                                    selectWaypointCandidate(name: tip.name, lat: tip.lat, lon: tip.lon)
                                } else {
                                    model.fetchRouteChoices(to: tip.name, lat: tip.lat, lon: tip.lon)
                                }
                            } label: {
                                Image(systemName: "arrow.up.right.circle")
                                    .foregroundStyle(Color(red: 0.0, green: 0.75, blue: 0.95))
                                    .font(.title3)
                                    .frame(width: 36, height: 36)   // v2.51 热区 20→36
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)   // v2.51 行高 32→约 48
                        .contentShape(Rectangle())
                        .onTapGesture {
                            searchFocused = false
                            showSuggestions = false
                            searchExpanded = false
                            dismissKeyboard()
                            model.addHistory(tip.name)
                            // v2.23 途经点选择模式：选中的点变成"候选途经点"
                            // （地图跳转 + 黑线 + 时长对比），不直接弹地点卡
                            if waypointSelecting {
                                selectWaypointCandidate(name: tip.name, lat: tip.lat, lon: tip.lon)
                            } else {
                                // v1.81 主体点击：地图高亮+北向上+地点信息卡
                                showTipCard(name: tip.name, lat: tip.lat, lon: tip.lon, sub: tip.sub)
                            }
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
        // v2.54 搜索态按屏高铺满（852pt 屏约 580、SE 667pt 约 454），仍有上限防溢出
        .frame(maxHeight: searchActive ? UIScreen.main.bounds.height * 0.68
                                       : (searchExpanded ? 400 : 190))
        .background(.bar)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.quaternary))
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
        .padding(.vertical, 12)   // v2.51 行高 34→约 44
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
        // 合肥小区/商铺：地图标签联想命中则在线查询坐标（精确）后预览
        if model.placeLabels.contains(where: { $0.name.localizedCaseInsensitiveContains(q) }) {
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

// MARK: - v2.52 语音搜索（iOS 原生 Speech，不依赖第三方 ASR）

/// 说话即搜索：SFSpeechRecognizer（zh-CN）+ AVAudioEngine 实时转写。
///
/// v2.23 曾因为"语音搜索未实现"把搜索框里的麦克风图标摘掉（占位按钮会误导用户）；
/// 这一版补上真实实现，凭 iOS 自带能力，不用再引入讯飞 IAT。
///
/// 并发处理：这个类**不标 @MainActor**（避开 SwiftUI View 方法同步调用时的隔离冲突），
/// 而是把所有状态写入与 AVAudioEngine 操作统一回到主线程（onMain）。
/// 权限回调、识别回调天然在后台线程，必须先 hop 回主线程再碰 engine / @Published。
///
/// 音频会话：TTS 播报用的是 .playback（由 AppModel 管理并缓存激活态）。
/// 录音必须切到 .record，因此：
///   ① 启动前由调用方先 `model.invalidateAudioSession()`，让 TTS 下次播报重新激活；
///   ② 结束时恢复 .playback 并 setActive(false)，把路由还给系统。
final class VoiceSearchService: ObservableObject {
    @Published var isListening = false
    @Published var errorText = ""

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onText: ((String) -> Void)?
    /// 只有真的装过 tap 才 removeTap —— 对没装 tap 的 bus 调 removeTap 会抛异常直接崩
    private var tapInstalled = false

    /// 统一切回主线程执行（已在主线程则直接执行，保持同步语义）
    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    func start(onText: @escaping (String) -> Void) {
        guard !isListening else { return }
        self.onText = onText
        errorText = ""
        guard let recognizer, recognizer.isAvailable else {
            errorText = "语音识别暂不可用，请检查网络"
            return
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            requestMicThenBegin()
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                guard let self else { return }
                self.onMain {
                    if status == .authorized { self.requestMicThenBegin() }
                    else { self.errorText = "未授权语音识别：设置 → 机车地图 → 语音识别" }
                }
            }
        default:
            errorText = "未授权语音识别：设置 → 机车地图 → 语音识别"
        }
    }

    /// 结束录音并把音频会话还给 TTS
    func stop() { finishSession() }

    // MARK: - 内部

    private func requestMicThenBegin() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            guard let self else { return }
            self.onMain {
                if granted { self.begin() }
                else { self.errorText = "未授权麦克风：设置 → 机车地图 → 麦克风" }
            }
        }
    }

    private func begin() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorText = "麦克风启动失败：\(error.localizedDescription)"
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            errorText = "语音识别暂不可用，请检查网络"
            restoreSession()
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .search
        request = req

        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else {
            errorText = "当前设备没有可用麦克风"
            restoreSession()
            return
        }
        if tapInstalled { input.removeTap(onBus: 0) }
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in
            req.append(buf)
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            errorText = "录音启动失败：\(error.localizedDescription)"
            if tapInstalled { input.removeTap(onBus: 0); tapInstalled = false }
            restoreSession()
            return
        }

        isListening = true
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            // 识别回调在后台线程：先取出值，再回主线程更新状态
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            self.onMain {
                if let transcript, !transcript.isEmpty { self.onText?(transcript) }
                if isFinal || failed { self.finishSession() }
            }
        }
    }

    private func finishSession() {
        // 从 UI 调 stop() 时已在主线程；从识别回调过来时调用方已 hop 回主线程
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        if isListening { isListening = false }
        restoreSession()
    }

    private func restoreSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setActive(false, options: .notifyOthersOnDeactivation)
        // 还给 TTS：AppModel 的 audioSessionActive 已置 false，下次播报会重新激活 Playback
        try? s.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    }
}
