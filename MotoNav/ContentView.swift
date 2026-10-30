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
    @State private var longPressCoord: CLLocationCoordinate2D?
    @State private var showLongPressMenu = false
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
    /// "导航到这里"已触发标记：仅此时显示清空路线竖条
    @State private var showClearRouteBtn = false
    /// 搜索框当前高度（手指上下滑动调整）
    @State private var searchHeight: CGFloat = 54

    var body: some View {
        ZStack {
            mapLayer
            // 等待定位/状态提示：屏幕最上边
            topOverlay
            // 左上角指南针（手机朝向即指针指向）
            compassOverlay
            if !model.navigating {
                menuOverlay
            }
            // 当前定位按钮：界面中间右侧（导航中隐藏，地图已跟随）
            locateOverlay.opacity(model.navigating ? 0 : 1)
            // 常用地点（家/公司）快捷按钮
            homeWorkOverlay
            // 地图缩放 + / - 按钮
            zoomOverlay
            // 导航中悬浮退出按钮
            exitNavOverlay
            bottomOverlay
        }
        .sheet(item: $poiDetail) { p in
            PoiDetailSheet(poi: p, model: model) { close in
                poiDetail = nil
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
            Button("设为家") {
                let p = Poi(id: 999_991, type: .SPEED, name: "家", lat: coord.latitude, lon: coord.longitude,
                            radiusM: 50, enabled: true, note: "常用地点-家")
                model.setHome(p)
                model.status = "已将当前位置设为家（长按点位可改）"
            }
            Button("设为公司") {
                let p = Poi(id: 999_992, type: .SPEED, name: "公司", lat: coord.latitude, lon: coord.longitude,
                            radiusM: 50, enabled: true, note: "常用地点-公司")
                model.setWork(p)
                model.status = "已将当前位置设为公司（长按点位可改）"
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
            Button(model.isFavorite(p) ? "取消收藏" : "收藏点位") {
                model.toggleFavorite(p)
                model.status = model.isFavorite(p) ? "已收藏：\(p.name)" : "已取消收藏：\(p.name)"
            }
            Button("设为家") { model.setHome(p); model.status = "已将「\(p.name)」设为家" }
            Button("设为公司") { model.setWork(p); model.status = "已将「\(p.name)」设为公司" }
            Button("编辑该点位") { editPoi = p }
            Button("删除该点位", role: .destructive) {
                model.deletePoi(id: p.id)
                model.status = "已删除：\(p.name)"
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
                // 轻点地图空白：该位置下方显示"导航到这里"
                goHereLabel = "导航去此处"
                goHereName = nil
                goHereLat = coord.latitude
                goHereLon = coord.longitude
                model.setPreview("地图选点", lat: coord.latitude, lon: coord.longitude)
            }
        )
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { dismissKeyboard() }
    }

    /// 右上角 ⋯ 菜单（v1.14：液态玻璃 + 天气/明日天气）
    private var menuOverlay: some View {
        VStack {
            HStack {
                Spacer()
                // 天气 + 明日天气（⋯ 左侧，纵向排列，液态玻璃）
                VStack(alignment: .trailing, spacing: 4) {
                    if let w = model.weatherText {
                        Text(w)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .padding(8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    if let t = model.tomorrowText {
                        Text(t)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .padding(6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                Menu {
                    Button("导入 JSON") { showImport = true }
                    Button("导出 JSON") { exportDoc = JsonFile(text: model.exportPois()); showExport = true }
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
                searchBar
            } else {
                navInfoCard
                snapAlertCard
            }
        }
    }

    /// 高德式导航信息卡：下一转向（大图标+距离+路名+车道）+ 剩余里程/时间 + 实时速度
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
                            Text("沿当前道路直行")
                                .font(.title3.bold())
                                .foregroundStyle(.white)
                        }
                    }
                    Spacer()
                    // 中：剩余里程/时间（大字分层）
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(String(format: "%.1f", Double(ns.remainM) / 1000.0))
                                .font(.system(size: 30, weight: .heavy))
                                .foregroundStyle(.white)
                            Text("公里")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        if ns.remainS > 0 {
                            Text("剩余 \(ns.remainS / 60) 分钟")
                                .font(.subheadline.bold())
                                .foregroundStyle(.white.opacity(0.95))
                        }
                    }
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

    /// 当前定位按钮（中间右侧）+ 其正下方的"清空路线"竖长条（仅"导航到这里"触发后显示）
    private var locateOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    // 定位按钮：白底圆圈中心点（点击后收起"导航到这里"并回中跟随）
                    Button {
                        haptic()
                        goHereName = nil
                        goHereLat = 0
                        goHereLon = 0
                        model.clearPreview()
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
                    // 清空路线：竖形长条（宽同定位按钮，长为 3 倍）
                    if showClearRouteBtn && model.route != nil {
                        Button {
                            model.clearRoute()
                            showClearRouteBtn = false
                        } label: {
                            VStack(spacing: 4) {
                                Text("清")
                                Text("空")
                                Text("路")
                                Text("线")
                            }
                            .font(.subheadline.bold())
                            .foregroundStyle(.black)
                            .frame(width: 44, height: 132)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.12), lineWidth: 1))
                        }
                        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    }
                }
                .padding(.trailing, 18) // 与搜索胶囊内"搜索"按钮居中对齐
                .offset(y: -57) // 相对中间位置向上提高 2cm
            }
            Spacer()
        }
    }

    /// 搜索预览"去这里" / 点选地点"导航到此处"按钮（绿色）
    private var goHereBar: some View {
        Group {
            if goHereName != nil || (goHereLat != 0 && goHereLon != 0) {
                Button {
                    haptic()
                    model.fetchRouteChoices(to: goHereName ?? "地图选点", lat: goHereLat, lon: goHereLon)
                    // "导航到这里"触发 → 允许显示清空路线竖条
                    showClearRouteBtn = true
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

    /// 多路线方案列表（点"去这里"后显示在搜索框上方）：优点 + 距离 + 导航用时
    private var routeChoiceList: some View {
        Group {
            if !model.routeChoices.isEmpty {
                VStack(spacing: 6) {
                    HStack {
                        Text("选择路线方案")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    ForEach(Array(model.routeChoices.enumerated()), id: \.offset) { _, c in
                        Button {
                            haptic()
                            model.applyRouteChoice(c)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("★ \(c.label)　·　\(String(format: "%.1f", Double(c.distanceM) / 1000.0)) 公里")
                                    .font(.footnote.bold())
                                    .foregroundStyle(.primary)
                                Text("导航用时约 \(c.durationS / 60) 分钟 · 途经抓拍 \(c.poiCount) 处 · 转向 \(c.turns.count) 处")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.35), lineWidth: 0.8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 4)
            }
        }
    }

    /// 常用地点快捷按钮（家/公司并排，未设置时提示长按地图设置）
    private var homeWorkOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        haptic()
                        if let h = model.homePlace {
                            model.fetchRouteChoices(to: h.name, lat: h.lat, lon: h.lon)
                        } else {
                            model.status = "请长按地图选点后「设为家」"
                        }
                    } label: {
                        Image(systemName: "house.fill")
                            .font(.headline)
                            .foregroundStyle(Color(red: 0.16, green: 0.38, blue: 1.0))
                            .frame(width: 40, height: 40)
                            .background(Color.white, in: Circle())
                            .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 1))
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                    }
                    Button {
                        haptic()
                        if let w = model.workPlace {
                            model.fetchRouteChoices(to: w.name, lat: w.lat, lon: w.lon)
                        } else {
                            model.status = "请长按地图选点后「设为公司」"
                        }
                    } label: {
                        Image(systemName: "building.2.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                            .frame(width: 40, height: 40)
                            .background(Color.white, in: Circle())
                            .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 1))
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                    }
                }
                .padding(.trailing, 18)
                .offset(y: -132)
                .opacity(model.navigating ? 0 : 1)
            }
            Spacer()
        }
    }

    /// 地图缩放 + / - 按钮（右下角，高德式）
    private var zoomOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 6) {
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

    /// 导航中悬浮退出按钮（右上角红色胶囊，高德导航式）
    private var exitNavOverlay: some View {
        VStack {
            HStack {
                Spacer()
                if model.navigating {
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

    /// 屏幕最上边的状态提示条（矩形，长度=屏宽不变，高度随行数自适应）
    private var topOverlay: some View {
        VStack {
            statusBar
            Spacer()
        }
    }

    private var statusBar: some View {
        Text(model.status)
            .font(.footnote)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.black.opacity(0.45))
            )
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
                    suggestions = model.searchSuggestions(newValue).map { displayName($0) }
                    showSuggestions = !newValue.trimmingCharacters(in: .whitespaces).isEmpty
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(.white.opacity(0.35), lineWidth: 0.8))
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
            HStack(spacing: 10) {
                Button {
                    model.setHome(poi)
                    model.status = "已将「\(poi.name)」设为家"
                } label: {
                    Text("设为家")
                        .font(.footnote.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                Button {
                    model.setWork(poi)
                    model.status = "已将「\(poi.name)」设为公司"
                } label: {
                    Text("设为公司")
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
