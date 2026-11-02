import SwiftUI
import MapKit
import UIKit

/// v2.00 地图坐标边界层（路线"贴不上路"的根因修复）
///
/// 事实：MKMapView 在中国大陆用的是高德底图（GCJ-02），`addAnnotation` / `addOverlay` /
/// `setRegion` 传入的经纬度会**按 GCJ-02 原样铺在底图上**——系统只对 `CLLocation`
/// 定位结果在内部做 WGS→GCJ 适配（所以系统蓝点是准的），API 传进来的坐标不会替你纠偏。
///
/// 本 App 内部（存储/GPX/组队/高德接口）统一使用 WGS-84，因此：
/// ① 凡是"喂给地图"的坐标必须先转 GCJ；② 从地图取回的坐标（convert(pt,toCoordinateFrom:)）
/// 必须转回 WGS。漏转一次就整体偏 300~600 米，表现为路线画在道路旁边、定位箭头与道路分离。
enum MapGeo {
    /// WGS-84 → GCJ-02（送给地图显示）
    static func toGCJ(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let (la, lo) = CoordConv.wgs2gcj(c.latitude, c.longitude)
        return CLLocationCoordinate2D(latitude: la, longitude: lo)
    }
    static func toGCJ(_ pts: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        pts.map { toGCJ($0) }
    }
    /// GCJ-02 → WGS-84（从地图取回，交给业务层）
    static func toWGS(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let (la, lo) = CoordConv.gcj2wgs(c.latitude, c.longitude)
        return CLLocationCoordinate2D(latitude: la, longitude: lo)
    }
}

/// 轻量地图封装：用户位置 + 按类型着色的点位标注 + 导航路线 + 沿途点位高亮 + 长按选点 + 搜索预览点 + 加油站
struct MapViewRepresentable: UIViewRepresentable {
    /// v2.12 外观跟随：手动浅色/深色时地图底图一起切（导航中始终深色）
    @Environment(\.colorScheme) private var colorScheme
    let pois: [Poi]
    let userLocation: CLLocationCoordinate2D?
    let route: [CLLocationCoordinate2D]
    /// 全部路线方案折线（规划态同时显示：推荐草绿 + 备选浅绿，高德式）
    let choiceRoutes: [[CLLocationCoordinate2D]]
    /// 当前选中方案下标（高德式：选中草绿实线，其余浅绿虚线）
    let selectedRouteIdx: Int
    let routePois: [Poi]
    /// 定位请求计数（点击定位按钮 +1，触发地图回中）
    let locateTick: Int
    /// 路线全览请求计数（规划完成 +1，触发地图缩放全览）
    let fitTick: Int
    /// 手机朝向（度），驱动地图跟随旋转
    let heading: Double
    /// 搜索预览点（绿色高亮）
    let preview: CLLocationCoordinate2D?
    /// 市区加油站（橙色"油"标注）
    let gasStations: [CLLocationCoordinate2D]
    /// 加油站全览请求计数（+1 触发缩放显示全部加油站 + 当前位置）
    let gasTick: Int
    /// 地图小区/商铺名称标签
    let placeLabels: [PlaceLabel]
    /// 类别搜索结果（学校/医院/加油站）
    let categoryResults: [AppModel.CategoryResult]
    /// 类别结果刷新计数
    let categoryTick: Int
    /// 导航中（3D 俯仰视角）
    let navigateFollowTick: Int
    let navigating: Bool
    /// 导航中路线全览请求计数（v1.81.4 导航退出卡"全览"）
    let overviewTick: Int
    /// v1.84 巡航模式：非导航下定位点跟随（300m 位移触发后持续）
    let cruise: Bool
    let cruiseTick: Int
    /// 地图缩放按钮计数
    let zoomInTick: Int
    let zoomOutTick: Int
    /// v2.01 地图俯仰角（0=2D / 45=3D），导航开始自动 45
    var pitchDeg: Double = 0
    /// v2.01 比例尺回调（缩放时把"58pt 代表多少米"回传给 SwiftUI 右上角比例尺）
    var onScaleChange: ((String) -> Void)?
    var onLongPress: ((CLLocationCoordinate2D) -> Void)?
    var onPoiLongPress: ((Poi) -> Void)?
    var onPoiMoved: ((Poi, Double, Double) -> Void)?
    var onPoiSelect: ((Poi) -> Void)?
    /// v2.26 电警点轻点回调（官方公示点位 → 弹出分享/删除卡片）
    var onCameraSelect: ((PoliceCamera) -> Void)?
    var onPlaceSelect: ((PlaceLabel) -> Void)?
    var onPlaceLongPress: ((PlaceLabel) -> Void)?
    var onCategorySelect: ((AppModel.CategoryResult) -> Void)?
    /// 轻点地图空白处选点（显示"导航到这里"）
    var onMapTap: ((CLLocationCoordinate2D) -> Void)?
    /// v1.98 轻点地图上的备选路线 → 切换为该方案
    var onRouteChoiceTap: ((Int) -> Void)?
    /// v1.63 极简模式：隐藏兴趣点/地名/类别标注（高德导航"极简"）
    let minimal: Bool
    /// v1.69 地图重载计数（加载失败重试 +1，触发瓦片强制重绘）
    let reloadTick: Int
    /// v1.81 地点查看时地图强制北向上（tick 变化触发一次）
    let northUpTick: Int
    /// v1.81 地点所属区域多边形（AOI，蓝色虚线框）
    let tipPolygon: [CLLocationCoordinate2D]?
    /// v1.81.1 地点信息卡定位点（fitTick 变化时优先移到这里，不画高亮圈）
    let tipFit: CLLocationCoordinate2D?
    /// v1.99 实时路况分段（高德 tmc：缓行黄 / 拥堵红，叠在选中方案之上）
    var trafficSpans: [TrafficSpan] = []
    /// v1.99 足迹回放轨迹（我的-足迹 → 点一条记录）
    var footprint: [CLLocationCoordinate2D] = []
    /// v1.99 组队队友位置
    var teamMembers: [TeamMember] = []
    /// v1.69 地图加载回调（ok=true 渲染完成 / ok=false 失败原因）
    var onMapLoad: ((Bool, String) -> Void)?
    /// v2.04 官方电警点位（图层开启时传入，关闭传空数组）
    var cameraMarks: [PoliceCamera] = []
    /// v2.04 刚触发语音提醒的点位 id（地图上该点放大高亮 2 秒，视觉与语音对齐）
    var hotCameraId: Int = 0
    /// v2.19 路线途经点（WGS-84，橙色"途"标注，随卡片增删同步）
    var waypointMarks: [CLLocationCoordinate2D] = []
    /// v2.20 电警点被手动拖动后的新坐标（WGS-84，id + lat + lon）
    var onCameraMoved: ((Int, Double, Double) -> Void)?
    /// v2.23 搜索选点连线：当前定位点 → 搜索选点（WGS-84）。nil = 不画。
    /// 用于"点联想地点后地图跳到该点，并用黑线连回我的位置"，一眼看出直线距离。
    var searchLinkFrom: CLLocationCoordinate2D? = nil
    /// v2.23 搜索选点连线终点（搜索选点，WGS-84）
    var searchLinkTo: CLLocationCoordinate2D? = nil
    /// v2.25 搜索选点高亮：坐标（WGS-84）+ 名称。nil = 不显示高亮。
    var searchHit: SearchHit? = nil
    /// v2.25 搜索选点后地图是否跟随朝向（保持 followWithHeading，不被关掉）
    var keepHeadingFollow: Bool = false
    /// v2.21 地图聚焦到指定坐标（点击途经点时用；WGS-84）
    var focusCoord: CLLocationCoordinate2D? = nil
    /// v2.21 聚焦触发计数（内容不变不重复移动地图）
    var focusTick: Int = 0
    /// v2.22 导航中已行驶折线点索引（之前的部分画灰）
    var traveledIdx: Int = 0
    /// v2.22 导航视野档位：1 厘米对应多少米（50 近 / 500 远）
    var navScaleTarget: Int = 50
    var navScaleTick: Int = 0
    /// v2.22 用户手动移动了地图（通知业务层）
    var onUserMovedChanged: ((Bool) -> Void)?
    /// v2.22 起点内部道路：定位点 → 道路入口（WGS）
    var routeStartLink: RouteLink?
    /// v2.22 终点内部道路：道路出口 → 终点（WGS）
    var routeEndLink: RouteLink?
    /// v2.22 入口箭头：起点入口朝向（"left"/"straight"/"right"）
    var routeStartArrow: String = "straight"
    /// v2.22 出口箭头：终点入口朝向
    var routeEndArrow: String = "straight"

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.showsUserLocation = true
        map.showsCompass = false // 使用自绘指南针（左上角）
        map.isPitchEnabled = true   // 双指俯仰调节 3D 角度
        map.isRotateEnabled = true  // 双指旋转地图
        map.delegate = context.coordinator
        // v1.67 高德瓦片底图（纯高德视觉）：插入 .aboveRoads 最底层——
        // 路线折线/点位标注都叠在瓦片之上（v1.62 灰罩+盖路线问题已修复：
        // ①层级由 aboveLabels 改 aboveRoads ②未加载瓦片透明露出苹果底图兜底 ③多子域轮询防限流)
        // v1.78：黑屏回归苹果 MapKit 引擎（3D Metal 渲染与设备不兼容），高德瓦片视觉保留
        // v2.14 关键：overlay 先不插，等首帧渲染完成后再插。
        //
        // 崩溃报告是 0x8BADF00D「scene-update watchdog」：应用启动后 10 秒内没交出首帧，
        // 系统直接 SIGKILL。而 overlay 一插入，首帧渲染就必须等整屏高德瓦片就位
        // （旧实现在渲染线程里同步读磁盘），首帧永远交不出来 —— 这就是"卡在这不能动"。
        // 现在首帧先让苹果底图出图（毫秒级），起来之后再叠高德瓦片，watchdog 无从触发。
        context.coordinator.amapOverlay = AmapTileOverlay()
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.6
        map.addGestureRecognizer(longPress)
        // 轻点地图：空白处选点（命中点位/地点标注时不触发，交给 didSelect）
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleMapTap(_:)))
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)
        // v1.98 双击地图放大（以双击点为锚点），并让单击等双击失败再响应，
        // 否则双击的第一下会被当成轻点 → 弹出地点卡/隐藏界面
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = context.coordinator
        map.addGestureRecognizer(doubleTap)
        tap.require(toFail: doubleTap)

        let coord = context.coordinator
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak map] in
            guard let map else { return }
            coord.insertAmapOverlayIfNeeded(map)
        }
        // v2.14 底图兜底：15 秒内一张高德瓦片都没成功（服务被限流/被墙/无网），
        // 就把 overlay 撤掉，露出苹果底图，至少地图上有内容、能拖动。
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak map] in
            guard let map else { return }
            let renderer = map.overlays
                .compactMap { map.renderer(for: $0) as? AmapTileRenderer }
                .first
            guard let renderer, renderer.loadedTiles == 0 else { return }
            for ov in map.overlays where ov is AmapTileOverlay {
                map.removeOverlay(ov)
            }
        }
        return map
    }

    /// v2.02 折线重建键：路线/方案/路况/足迹/AOI 任一变化才重建
    private func routeRenderKey() -> String {
        var parts: [String] = [
            "\(route.count)", navigating ? "nav" : "plan", "\(selectedRouteIdx)",
            "\(choiceRoutes.count)", "\(trafficSpans.count)", "\(footprint.count)",
            "\(tipPolygon?.count ?? 0)"
        ]
        if let f = route.first { parts.append("\(f.latitude),\(f.longitude)") }
        if let l = route.last { parts.append("\(l.latitude),\(l.longitude)") }
        if let t = tipPolygon?.first { parts.append("\(t.latitude),\(t.longitude)") }
        return parts.joined(separator: "|")
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onLongPress = onLongPress
        context.coordinator.onPoiLongPress = onPoiLongPress
        context.coordinator.onPoiMoved = onPoiMoved
        context.coordinator.onCameraMoved = onCameraMoved
        context.coordinator.traveledIdx = traveledIdx
        context.coordinator.onUserMovedChanged = onUserMovedChanged
        context.coordinator.onPoiSelect = onPoiSelect
        // v2.26 电警点轻点 → 分享/删除卡片
        context.coordinator.onCameraSelect = onCameraSelect
        context.coordinator.onPlaceSelect = onPlaceSelect
        context.coordinator.onPlaceLongPress = onPlaceLongPress
        context.coordinator.onCategorySelect = onCategorySelect
        context.coordinator.onMapTap = onMapTap
        context.coordinator.onRouteChoiceTap = onRouteChoiceTap
        context.coordinator.onScaleChange = onScaleChange
        context.coordinator.choiceRoutes = choiceRoutes
        context.coordinator.selectedRouteIdx = selectedRouteIdx
        context.coordinator.planning = !choiceRoutes.isEmpty && !navigating
        context.coordinator.onMapLoad = onMapLoad
        // v1.69 地图加载失败重试（v1.78：移除重插瓦片 overlay 强制重绘）
        if reloadTick != context.coordinator.lastReloadTick {
            context.coordinator.lastReloadTick = reloadTick
            if reloadTick > 0 {
                let ov = map.overlays.first { $0 is AmapTileOverlay }
                if let ov {
                    map.removeOverlay(ov)
                    // v2.14 重建时同步给 coordinator，否则延迟插入逻辑会拿着旧的 overlay 对象
                    let fresh = AmapTileOverlay()
                    context.coordinator.amapOverlay = fresh
                    map.insertOverlay(fresh, at: 0, level: .aboveRoads)
                }
            }
        }
        // 定位按钮：跟随手机朝向模式（地图自动旋转 + 回中，不重置缩放级别）
        if locateTick != context.coordinator.lastLocateTick {
            context.coordinator.lastLocateTick = locateTick
            if locateTick > 0 {
                context.coordinator.userMoved = false // 恢复跟随/自动旋转
                context.coordinator.setRegionProgrammatically {
                    map.userTrackingMode = .followWithHeading
                }
            }
        } else if !context.coordinator.hasCentered, let loc = userLocation {
            // 首次定位：设置初始区域
            context.coordinator.hasCentered = true
            context.coordinator.setRegionProgrammatically {
                map.setRegion(
                    MKCoordinateRegion(center: MapGeo.toGCJ(loc), latitudinalMeters: 3000, longitudinalMeters: 3000),
                    animated: false)
            }
        }
        // 路线全览（仅在新规划完成时触发一次，避免定位更新反复拉回；包含全部方案路线）
        if fitTick != context.coordinator.lastFitTick {
            context.coordinator.lastFitTick = fitTick
            if let tf = tipFit {
                // v1.81.1 地点信息卡：地图定位到该点（不画黄圈，卡片沉底展示）
                context.coordinator.setRegionProgrammatically {
                    map.setRegion(MKCoordinateRegion(center: MapGeo.toGCJ(tf), latitudinalMeters: 3000, longitudinalMeters: 3000), animated: true)
                }
            } else if route.count > 1 {
                var rect = MKMapRect.null
                var pts = route
                for r in choiceRoutes { pts.append(contentsOf: r) }
                for c in MapGeo.toGCJ(pts) {
                    let p = MKMapPoint(c)
                    rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
                }
                map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 60, left: 40, bottom: 60, right: 40), animated: true)
            }
        }
        // 加油站全览（仅在新请求时触发一次）
        if gasTick != context.coordinator.lastGasTick && !gasStations.isEmpty {
            context.coordinator.lastGasTick = gasTick
            context.coordinator.setRegionProgrammatically {
                var rect = MKMapRect.null
                var pts = gasStations
                if let u = userLocation { pts.append(u) }
                for c in MapGeo.toGCJ(pts) {
                    let p = MKMapPoint(c)
                    rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
                }
                map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 60, left: 40, bottom: 60, right: 40), animated: true)
            }
        }
        // 【v2.12 性能】标注同步：内容键 + 一次性索引
        // 旧写法是 `for p in pois { map.annotations.contains { ... } }` —— O(点位 × 全部标注)。
        // 内置点位 300+、地名标签最多 600、电警 56，一帧就是几十万次比较；
        // 而 updateUIView 每秒会被定位/状态变化触发多次，这是地图页卡顿的主因。
        // 现在先算内容键，没变直接跳过；变了才遍历一次 annotations 建索引。
        var poiHasher = Hasher()
        poiHasher.combine(pois.count)
        poiHasher.combine(minimal)
        for p in pois {
            poiHasher.combine(p.id); poiHasher.combine(p.enabled); poiHasher.combine(p.lat)
            poiHasher.combine(p.lon); poiHasher.combine(p.type.rawValue); poiHasher.combine(p.isCustom)
        }
        for p in routePois { poiHasher.combine(p.id) }
        let poiKey = poiHasher.finalize()

        if poiKey != context.coordinator.lastPoiKey {
            context.coordinator.lastPoiKey = poiKey
            var index: [Int64: PoiAnnotation] = [:]
            for a in map.annotations {
                if let x = a as? PoiAnnotation { index[x.poi.id] = x }
            }
            let ids = Set(pois.map(\.id))
            let onRouteIds = Set(routePois.map(\.id))
            for (id, a) in index where !ids.contains(id) {
                map.removeAnnotation(a)
                index[id] = nil
            }
            for p in pois {
                let onRoute = onRouteIds.contains(p.id)
                if let a = index[p.id] {
                    if a.poi.coordinate != p.coordinate || a.poi.isCustom != p.isCustom {
                        // 坐标/自定义标记变化（拖动或编辑后）：移除重建以刷新 marker 视图
                        map.removeAnnotation(a)
                        let na = PoiAnnotation(poi: p, onRoute: onRoute)
                        map.addAnnotation(na)
                        index[p.id] = na
                    } else {
                        a.poi = p
                        a.onRoute = onRoute
                    }
                } else {
                    let na = PoiAnnotation(poi: p, onRoute: onRoute)
                    map.addAnnotation(na)
                    index[p.id] = na
                }
            }
        }

        // v2.04 官方电警点位图层（按 id 增量同步）
        var camHasher = Hasher()
        camHasher.combine(cameraMarks.count)
        for c in cameraMarks { camHasher.combine(c.id); camHasher.combine(c.lat); camHasher.combine(c.lon) }
        let camKey = camHasher.finalize()
        if camKey != context.coordinator.lastCamKey {
            context.coordinator.lastCamKey = camKey
            let camIds = Set(cameraMarks.map(\.id))
            var existing: [Int: CameraAnnotation] = [:]
            for a in map.annotations {
                if let x = a as? CameraAnnotation { existing[x.cameraId] = x }
            }
            for (id, a) in existing where !camIds.contains(id) {
                map.removeAnnotation(a)
                existing[id] = nil
            }
            for c in cameraMarks {
                if let a = existing[c.id] {
                    // v2.20 人工校准/恢复官方坐标后，把标注挪到新位置
                    // （拖动中的那个点跳过，否则会被拉回旧坐标）
                    if context.coordinator.draggingCameraId != c.id {
                        let want = MapGeo.toGCJ(c.coordinate)
                        if abs(a.coordinate.latitude - want.latitude) > 1e-7
                            || abs(a.coordinate.longitude - want.longitude) > 1e-7 {
                            a.setCoordinate(want)
                        }
                    }
                } else {
                    let na = CameraAnnotation(camera: c, hot: 0)
                    map.addAnnotation(na)
                    existing[c.id] = na
                }
            }
        }
        // 刚播报的点位：外圈加粗 + 放大，让"听到的"和"看到的"是同一个点
        // v2.12：只在 hotCameraId 变化时扫一遍，不再每帧遍历全部标注
        if hotCameraId != context.coordinator.lastHotCameraId {
            context.coordinator.lastHotCameraId = hotCameraId
            for a in map.annotations.compactMap({ $0 as? CameraAnnotation }) {
                let want = (a.cameraId == hotCameraId && hotCameraId != 0)
                if a.isHot != want {
                    a.isHot = want
                    (map.view(for: a) as? CameraPinView)?.setHot(want)
                }
            }
        }
        // v2.19 途经点标注（高德式橙色"途"，内容键相同跳过）
        var viaHasher = Hasher()
        for c in waypointMarks { viaHasher.combine(c.latitude); viaHasher.combine(c.longitude) }
        let viaKey = viaHasher.finalize()
        if viaKey != context.coordinator.lastViaKey {
            context.coordinator.lastViaKey = viaKey
            let existing = map.annotations.compactMap { $0 as? RouteEndAnnotation }
                .filter { $0.kind == "via" }
            let want = waypointMarks.map { MapGeo.toGCJ($0) }
            if want.isEmpty {
                existing.forEach { map.removeAnnotation($0) }
            } else {
                // 逐一复用/新增/删除：数量通常 1~3 个，直接按索引对齐即可
                for (i, coord) in want.enumerated() {
                    if i < existing.count {
                        existing[i].setCoordinateGCJ(coord)
                    } else {
                        map.addAnnotation(RouteEndAnnotation(kind: "via", coordinate: coord))
                    }
                }
                for j in want.count..<existing.count {
                    map.removeAnnotation(existing[j])
                }
            }
        }
        // 终点标记（高德式：起点=当前定位蓝箭头，不再画"起"标记；终点保留"终"）
        // v2.12：路线没变就跳过（原来每帧都要遍历全部标注找终点标记）
        let endKey = route.count < 2 ? "none"
            : "end|\(route.last!.latitude),\(route.last!.longitude)"
        if endKey != context.coordinator.lastEndKey {
            context.coordinator.lastEndKey = endKey
            let existingEnds = map.annotations.compactMap { $0 as? RouteEndAnnotation }
            if route.count < 2 {
                existingEnds.forEach { map.removeAnnotation($0) }
            } else {
                existingEnds.filter { $0.kind == "start" }.forEach { map.removeAnnotation($0) }
                if !existingEnds.contains(where: { $0.kind == "end" }) {
                    map.addAnnotation(RouteEndAnnotation(kind: "end", coordinate: route.last!))
                }
            }
        }
        // 搜索预览点（绿色高亮）+ 跳转到搜索结果
        let previews = map.annotations.compactMap { $0 as? PreviewAnnotation }
        let previewKey = preview.map { "\($0.latitude),\($0.longitude)" } ?? ""
        if previewKey != context.coordinator.lastPreviewKey {
            context.coordinator.lastPreviewKey = previewKey
            if let p = preview {
                context.coordinator.setRegionProgrammatically {
                    map.userTrackingMode = .none
                    map.setRegion(
                        MKCoordinateRegion(center: MapGeo.toGCJ(p), latitudinalMeters: 3000, longitudinalMeters: 3000),
                        animated: true)
                }
            }
        }
        if let p = preview {
            if previews.isEmpty {
                map.addAnnotation(PreviewAnnotation(coordinate: p))
            } else if let a = previews.first {
                a.update(p)
            }
        } else {
            previews.forEach { map.removeAnnotation($0) }
        }
        // 加油站标注（v2.12：内容键相同直接跳过）
        var gasHasher = Hasher()
        gasHasher.combine(gasStations.count)
        for c in gasStations { gasHasher.combine(c.latitude); gasHasher.combine(c.longitude) }
        let gasKey = gasHasher.finalize()
        if gasKey != context.coordinator.lastGasKey {
            context.coordinator.lastGasKey = gasKey
            var existing: [String: GasAnnotation] = [:]
            for a in map.annotations {
                if let g = a as? GasAnnotation { existing[g.wgsKey] = g }
            }
            let want = Set(gasStations.map { "\($0.latitude),\($0.longitude)" })
            for (k, a) in existing where !want.contains(k) {
                map.removeAnnotation(a)
                existing[k] = nil
            }
            for c in gasStations {
                let k = "\(c.latitude),\(c.longitude)"
                if existing[k] == nil {
                    let na = GasAnnotation(id: k, coordinate: c)
                    map.addAnnotation(na)
                    existing[k] = na
                }
            }
        }
        // 小区/商铺名称标签（v2.12：内容键 + 极简开关共同决定）
        var placeHasher = Hasher()
        placeHasher.combine(minimal)
        placeHasher.combine(placeLabels.count)
        for pl in placeLabels { placeHasher.combine(pl.id); placeHasher.combine(pl.lat); placeHasher.combine(pl.lon) }
        let placeKey = placeHasher.finalize()
        if placeKey != context.coordinator.lastPlaceKey {
            context.coordinator.lastPlaceKey = placeKey
            var existing: [String: PlaceAnnotation] = [:]
            for a in map.annotations {
                if let x = a as? PlaceAnnotation { existing[x.place.id] = x }
            }
            // 极简模式：一个都不留（旧版只不再添加，已显示的仍挂在图上）
            let want = minimal ? Set<String>() : Set(placeLabels.map(\.id))
            for (k, a) in existing where !want.contains(k) {
                map.removeAnnotation(a)
                existing[k] = nil
            }
            if !minimal {
                for pl in placeLabels where existing[pl.id] == nil {
                    let na = PlaceAnnotation(place: pl)
                    map.addAnnotation(na)
                    existing[pl.id] = na
                }
            }
        }
        // 类别搜索结果（学校/医院/加油站）
        var catHasher = Hasher()
        catHasher.combine(minimal)
        catHasher.combine(categoryResults.count)
        for r in categoryResults { catHasher.combine(r.id) }
        let catKey = catHasher.finalize()
        if catKey != context.coordinator.lastCatKey {
            context.coordinator.lastCatKey = catKey
            var existing: [String: CategoryAnnotation] = [:]
            for a in map.annotations {
                if let x = a as? CategoryAnnotation { existing[x.result.id] = x }
            }
            let want = minimal ? Set<String>() : Set(categoryResults.map(\.id))
            for (k, a) in existing where !want.contains(k) {
                map.removeAnnotation(a)
                existing[k] = nil
            }
            if !minimal {
                for r in categoryResults where existing[r.id] == nil {
                    let na = CategoryAnnotation(result: r)
                    map.addAnnotation(na)
                    existing[r.id] = na
                }
            }
        }
        // v2.02 折线只在"真的变了"时重建
        // 旧实现每次 updateUIView 都 removeOverlays + 重建全部 MKPolyline，而 updateUIView 每秒
        // 会被定位/状态更新触发多次（一次导航卡刷新就可能几十次）→ 折线反复消失重现（雪花闪烁）
        // + 上千点折线反复分配（卡顿）。这里按内容做键，不变就直接跳过。
        let routeKey = routeRenderKey()
        if routeKey != context.coordinator.lastRouteKey {
            context.coordinator.lastRouteKey = routeKey
            // v2.00 只移除折线/多边形，保留高德瓦片 overlay
            // （旧写法 removeOverlays(map.overlays) 会把底图瓦片一起删掉，且再也没插回来，
            //  结果整张底图退回苹果原生地图——这也是"路线压不到路"的观感来源之一）
            map.removeOverlays(map.overlays.filter { !($0 is AmapTileOverlay) })
            context.coordinator.underPolyline = nil
            context.coordinator.mainPolyline = nil
            context.coordinator.traveledPolyline = nil
            context.coordinator.alternatePolylines = []
            context.coordinator.trafficPolylines = []
            context.coordinator.trafficColors = []
            context.coordinator.footprintPolyline = nil
            // v1.81 地点区域多边形（AOI 蓝色虚线框；随 tipPolygon 变化重建，每次重画路线后补加）
            let polyKey = tipPolygon.map { pts in
                pts.map { "\($0.latitude),\($0.longitude)" }.joined(separator: ":")
            } ?? ""
            if polyKey != context.coordinator.lastTipPolygonKey {
                context.coordinator.lastTipPolygonKey = polyKey
                if let pts = tipPolygon, pts.count >= 3 {
                    let gpts = MapGeo.toGCJ(pts)
                    context.coordinator.tipPolygonOverlay = MKPolygon(coordinates: gpts, count: gpts.count)
                } else {
                    context.coordinator.tipPolygonOverlay = nil
                }
            }
            if let pg = context.coordinator.tipPolygonOverlay {
                map.addOverlay(pg)
            }
            if route.count > 1 {
                let gRoute = MapGeo.toGCJ(route)
                if navigating {
                    // v2.22 导航中：未走的部分画草绿双层；已走过的部分单独画灰
                    let ti = min(max(traveledIdx, 0), gRoute.count - 1)
                    if ti > 0 {
                        // 已走过：灰色实线（叠在绿色下层之上）
                        let done = Array(gRoute[0...ti])
                        let dp = MKPolyline(coordinates: done, count: done.count)
                        context.coordinator.traveledPolyline = dp
                        map.addOverlay(dp)
                    } else {
                        context.coordinator.traveledPolyline = nil
                    }
                    // 未走过部分
                    let rest = Array(gRoute[ti...])
                    let rRoute = rest.count >= 2 ? rest : gRoute
                    let under = MKPolyline(coordinates: rRoute, count: rRoute.count)
                    context.coordinator.underPolyline = under
                    let main = MKPolyline(coordinates: rRoute, count: rRoute.count)
                    context.coordinator.mainPolyline = main
                    map.addOverlay(under)
                    map.addOverlay(main)
                } else {
                    // 规划态：备选方案浅绿虚线 + 当前方案草绿双层（高德式同屏多路线）
                    for (idx, pts) in choiceRoutes.enumerated() where idx != selectedRouteIdx && pts.count > 1 {
                        let gpts = MapGeo.toGCJ(pts)
                        let alt = MKPolyline(coordinates: gpts, count: gpts.count)
                        context.coordinator.alternatePolylines.append(alt)
                        map.addOverlay(alt)
                    }
                    let under = MKPolyline(coordinates: gRoute, count: gRoute.count)
                    context.coordinator.underPolyline = under
                    let main = MKPolyline(coordinates: gRoute, count: gRoute.count)
                    context.coordinator.mainPolyline = main
                    map.addOverlay(under)
                    map.addOverlay(main)
                }
                // v1.99 路况：缓行黄 / 拥堵红，叠在当前方案之上（高德式）
                for span in trafficSpans where span.points.count >= 2 {
                    let gpts = MapGeo.toGCJ(span.points)
                    let poly = MKPolyline(coordinates: gpts, count: gpts.count)
                    context.coordinator.trafficPolylines.append(poly)
                    context.coordinator.trafficColors.append(span.color)
                    map.addOverlay(poly)
                }
            }
            // v1.99 足迹回放：蓝色虚线（不受路线清空影响）
            if footprint.count >= 2 {
                let gpts = MapGeo.toGCJ(footprint)
                let poly = MKPolyline(coordinates: gpts, count: gpts.count)
                context.coordinator.footprintPolyline = poly
                map.addOverlay(poly)
            }
        }
        // v1.99 组队队友标注：按 名称+坐标 做键，变化才重建
        let teamKey = teamMembers.map { "\($0.name)@\(String(format: "%.5f", $0.lat)),\(String(format: "%.5f", $0.lon))" }
            .sorted().joined(separator: "|")
        if teamKey != context.coordinator.lastTeamKey {
            context.coordinator.lastTeamKey = teamKey
            map.annotations.compactMap { $0 as? TeamAnnotation }
                .forEach { map.removeAnnotation($0) }
            for m in teamMembers {
                map.addAnnotation(TeamAnnotation(name: m.name, speedKph: m.speedKph,
                                                 coordinate: m.coordinate))
            }
        }
        // v2.22 起终点内部道路：蓝色虚线连接定位点↔道路入口，并标入口转向箭头
        let connKey = "\(routeStartLink?.from.latitude ?? 0)-\(routeStartLink?.to.longitude ?? 0)-\(routeEndLink?.from.latitude ?? 0)-\(routeEndLink?.to.longitude ?? 0)-\(routeStartArrow)-\(routeEndArrow)"
        if connKey != context.coordinator.lastConnKey {
            context.coordinator.lastConnKey = connKey
            for p in context.coordinator.connectorPolylines { map.removeOverlay(p) }
            context.coordinator.connectorPolylines = []
            for a in context.coordinator.entryArrowAnnotations { map.removeAnnotation(a) }
            context.coordinator.entryArrowAnnotations = []
            if let sl = routeStartLink {
                let pts = [MapGeo.toGCJ(sl.from), MapGeo.toGCJ(sl.to)]
                let poly = MKPolyline(coordinates: pts, count: pts.count)
                context.coordinator.connectorPolylines.append(poly)
                map.addOverlay(poly)
                let ann = RouteEndAnnotation(kind: "arrow_\(routeStartArrow)", coordinate: sl.to)
                context.coordinator.entryArrowAnnotations.append(ann)
                map.addAnnotation(ann)
            }
            if let el = routeEndLink {
                let pts = [MapGeo.toGCJ(el.from), MapGeo.toGCJ(el.to)]
                let poly = MKPolyline(coordinates: pts, count: pts.count)
                context.coordinator.connectorPolylines.append(poly)
                map.addOverlay(poly)
                let ann = RouteEndAnnotation(kind: "arrow_\(routeEndArrow)", coordinate: el.from)
                context.coordinator.entryArrowAnnotations.append(ann)
                map.addAnnotation(ann)
            }
        }
        // v2.25 搜索选点高亮：橙色定位环 + 名称气泡
        let hitKey = searchHit.map { "\($0.coord.latitude)-\($0.coord.longitude)-\($0.title)" } ?? ""
        if hitKey != context.coordinator.lastSearchHitKey {
            context.coordinator.lastSearchHitKey = hitKey
            if let old = context.coordinator.searchHitAnnotation {
                map.removeAnnotation(old)
                context.coordinator.searchHitAnnotation = nil
            }
            if let h = searchHit {
                let ann = SearchHitAnnotation(coordinate: h.coord, title: h.title)
                context.coordinator.searchHitAnnotation = ann
                map.addAnnotation(ann)
            }
        }
        // v2.25 搜索选点后：地图跳到该点并**保持朝向跟随**
        // （旧版用 userTrackingMode = .none 把跟随关掉，转动手机地图就不跟了）
        if let h = searchHit, let loc = userLocation {
            let linkKey2 = "\(h.coord.latitude)-\(h.coord.longitude)-\(loc.latitude)-\(loc.longitude)"
            if linkKey2 != context.coordinator.lastSearchHitViewKey {
                context.coordinator.lastSearchHitViewKey = linkKey2
                context.coordinator.setRegionProgrammatically {
                    if keepHeadingFollow {
                        map.userTrackingMode = .followWithHeading
                    } else {
                        map.userTrackingMode = .none
                    }
                    // 视野同时装下"我的位置"和"搜索点"，黑线两端都在屏内
                    let a = MapGeo.toGCJ(loc)
                    let b = MapGeo.toGCJ(h.coord)
                    let midLat = (a.latitude + b.latitude) / 2
                    let midLon = (a.longitude + b.longitude) / 2
                    let spanLat = max(abs(a.latitude - b.latitude) * 1.6, 0.004)
                    let spanLon = max(abs(a.longitude - b.longitude) * 1.6, 0.004)
                    map.setRegion(
                        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: midLat, longitude: midLon),
                                           latitudinalMeters: spanLat * 111_320,
                                           longitudinalMeters: spanLon * 111_320 * cos(midLat * .pi / 180)),
                        animated: true)
                }
            }
        }
        // v2.23 搜索选点黑线：我的位置 ↔ 搜索选点
        let linkKey = "\(searchLinkFrom?.latitude ?? 0)-\(searchLinkFrom?.longitude ?? 0)-\(searchLinkTo?.latitude ?? 0)-\(searchLinkTo?.longitude ?? 0)"
        if linkKey != context.coordinator.lastSearchLinkKey {
            context.coordinator.lastSearchLinkKey = linkKey
            if let old = context.coordinator.searchLinkPolyline {
                map.removeOverlay(old)
                context.coordinator.searchLinkPolyline = nil
            }
            if let a = searchLinkFrom, let b = searchLinkTo {
                let pts = [MapGeo.toGCJ(a), MapGeo.toGCJ(b)]
                let poly = MKPolyline(coordinates: pts, count: pts.count)
                context.coordinator.searchLinkPolyline = poly
                map.addOverlay(poly)
            }
        }
        // v2.21 途经点定位：地图移到该点并暂停朝向跟随
        if focusTick != context.coordinator.lastFocusTick {
            context.coordinator.lastFocusTick = focusTick
            if focusTick > 0, let fc = focusCoord {
                context.coordinator.userMoved = true
                context.coordinator.setRegionProgrammatically {
                    map.userTrackingMode = .none
                    map.setRegion(
                        MKCoordinateRegion(center: MapGeo.toGCJ(fc),
                                           latitudinalMeters: 600,
                                           longitudinalMeters: 600),
                        animated: true)
                }
            }
        }
        // 地图自适应旋转：地图始终与手机朝向一致（箭头固定朝屏幕上方=手机朝向，避免双重旋转）
        // 用户手动拖动/旋转地图后暂停跟随（高德式：点定位按钮恢复）
        if !context.coordinator.userMoved {
            map.camera.heading = CLLocationDirection(heading)
        }
        // v1.81 地点查看：强制北向上一次（暂停朝向跟随，避免下一帧转回）
        if northUpTick != context.coordinator.lastNorthUpTick {
            context.coordinator.lastNorthUpTick = northUpTick
            if northUpTick > 0 {
                context.coordinator.userMoved = true
                map.camera.heading = 0
            }
        }
        // v2.22 导航视野档位：按"比例尺 1 厘米 = N 米"设定相机高度
        //
        // 屏幕上 1 厘米 ≈ 38 pt（@3x 屏 1cm≈113px，除以 scale≈3）
        // 目标比例 N 米/厘米 → 每 pt 代表 N/38 米
        // 地图高度对应的米数 = 每 pt 米数 × 屏幕高度(pt)
        // 用 altitude（相机到地面的距离）反推：正交俯视时 altitude ≈ 视野米数
        if navScaleTick != context.coordinator.lastNavScaleTick {
            context.coordinator.lastNavScaleTick = navScaleTick
            if navScaleTick > 0, let loc = userLocation {
                context.coordinator.userMoved = false
                let ptPerCm: Double = 38.0
                let metersPerPoint = Double(navScaleTarget) / ptPerCm
                let screenH = Double(map.bounds.height)
                let spanMeters = metersPerPoint * max(screenH, 1)
                // altitude ≈ 视野高度 / (2*tan(fov/2))，俯角 45° 时取经验系数 1.15
                let altitude = max(spanMeters * 0.62, 120)
                context.coordinator.setRegionProgrammatically {
                    map.userTrackingMode = .followWithHeading
                    var cam = map.camera
                    cam.centerCoordinate = MapGeo.toGCJ(loc)
                    cam.altitude = altitude
                    cam.pitch = CGFloat(pitchDeg > 0 ? pitchDeg : 45)
                    map.camera = cam
                }
            }
        }
        // 导航跟随：导航开始/结束/到达时进入跟随（高德式：地图随车移动+自动旋转）
        if navigateFollowTick != context.coordinator.lastNavFollowTick {
            context.coordinator.lastNavFollowTick = navigateFollowTick
            context.coordinator.userMoved = false
            if let loc = userLocation {
                context.coordinator.navLastFollow = loc
            }
            context.coordinator.setRegionProgrammatically {
                map.userTrackingMode = .followWithHeading
                if navigating {
                    // v2.22 导航视野改为按"比例尺 1 厘米 = N 米"反推（默认 50 米/厘米）
                    var cam = map.camera
                    cam.pitch = CGFloat(pitchDeg > 0 ? pitchDeg : 45)
                    let ptPerCm: Double = 38.0
                    let metersPerPoint = Double(navScaleTarget) / ptPerCm
                    let screenH = Double(map.bounds.height)
                    let spanMeters = metersPerPoint * max(screenH, 1)
                    cam.centerCoordinateDistance = max(spanMeters * 0.62, 120)
                    map.camera = cam
                }
            }
        }
        // v1.81.4 导航中全览：缩放显示当前路线全程，暂停跟随（取消/固定恢复由 navigateFollowTick 接管）
        if overviewTick != context.coordinator.lastOverviewTick {
            context.coordinator.lastOverviewTick = overviewTick
            if overviewTick > 0, route.count > 1 {
                context.coordinator.userMoved = true
                var rect = MKMapRect.null
                for c in MapGeo.toGCJ(route) {
                    let p = MKMapPoint(c)
                    rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
                }
                context.coordinator.setRegionProgrammatically {
                    map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 90, left: 50, bottom: 120, right: 50), animated: true)
                }
            }
        }
        // v2.22 用户手动移动地图 → 通知业务层（提示卡收起，只留"继续导航"）
        if navigating, context.coordinator.userMoved != context.coordinator.lastUserMovedFlag {
            context.coordinator.lastUserMovedFlag = context.coordinator.userMoved
            onUserMovedChanged?(context.coordinator.userMoved)
        }
        // 导航中拖动/旋转地图后，车开远（>100米）自动拉回跟随（高德导航行为）
        if navigating && context.coordinator.userMoved {
            if let loc = userLocation, let last = context.coordinator.navLastFollow,
               CLLocation(latitude: loc.latitude, longitude: loc.longitude)
                .distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude)) > 100 {
                context.coordinator.userMoved = false
                context.coordinator.navLastFollow = loc
                context.coordinator.setRegionProgrammatically {
                    map.userTrackingMode = .followWithHeading
                }
            }
        } else if navigating, let loc = userLocation {
            context.coordinator.navLastFollow = loc
        }
        // v1.84 巡航模式：进入时缩放巡航视野（约 3000m 高，平视），随后定位点跟随（GPS 抖动 >25m 才更新相机）
        if cruise != context.coordinator.lastCruise {
            context.coordinator.lastCruise = cruise
            if cruise, let loc = userLocation {
                context.coordinator.userMoved = false
                context.coordinator.cruiseLastLoc = loc
                context.coordinator.setRegionProgrammatically {
                    var cam = map.camera
                    cam.centerCoordinate = MapGeo.toGCJ(loc)
                    cam.altitude = 3000
                    cam.pitch = 0
                    map.camera = cam
                }
            }
        } else if cruise, cruiseTick != context.coordinator.lastCruiseTick {
            context.coordinator.lastCruiseTick = cruiseTick
            if let loc = userLocation {
                let last = context.coordinator.cruiseLastLoc
                if last == nil ||
                    CLLocation(latitude: loc.latitude, longitude: loc.longitude)
                        .distance(from: CLLocation(latitude: last!.latitude, longitude: last!.longitude)) > 25 {
                    context.coordinator.cruiseLastLoc = loc
                    context.coordinator.setRegionProgrammatically {
                        var cam = map.camera
                        cam.centerCoordinate = MapGeo.toGCJ(loc)
                        map.camera = cam
                    }
                }
            }
        }
        // v2.01 俯仰角由 AppModel.pitchDeg 驱动（导航开始 45°，退出 0°，右侧 3D 按钮切换）
        if pitchDeg != context.coordinator.lastPitchDeg {
            context.coordinator.lastPitchDeg = pitchDeg
            let target = CGFloat(max(0, min(70, pitchDeg)))
            context.coordinator.setRegionProgrammatically {
                var cam = map.camera
                cam.pitch = target
                map.camera = cam
            }
        }
        // v1.63 深色模式：导航中强制深色底图（高德夜间效果）；非导航跟随外观设置
        // v2.12：外观可手动切换（自动/浅色/深色），这里跟随 SwiftUI 的 colorScheme，
        // 导航中仍然强制深色，保证路口和电子眼看得到
        let wantDark = navigating || colorScheme == .dark
        if wantDark != context.coordinator.lastDarkState {
            context.coordinator.lastDarkState = wantDark
            map.overrideUserInterfaceStyle = wantDark ? .dark : .light
            // v1.67 高德瓦片随深色切换夜间样式（style=8 深色 / style=7 浅色）
            context.coordinator.amapDark = wantDark
            context.coordinator.amapRenderer?.dark = wantDark
        }
        // 缩放按钮（+/-）：以地图中心缩放 0.5x / 2x
        // v1.98 修复"点 +/- 没反应"：跟随模式（.follow/.followWithHeading）下 MapKit 会
        // 立刻把镜头拉回定位点，setRegion 被覆盖；先退出跟随再缩放
        if zoomInTick != context.coordinator.lastZoomInTick {
            context.coordinator.lastZoomInTick = zoomInTick
            if zoomInTick > 0 {
                let reg = map.region
                context.coordinator.zoom(map, by: 0.5, center: reg.center)
            }
        }
        if zoomOutTick != context.coordinator.lastZoomOutTick {
            context.coordinator.lastZoomOutTick = zoomOutTick
            if zoomOutTick > 0 {
                let reg = map.region
                context.coordinator.zoom(map, by: 2.0, center: reg.center)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var onLongPress: ((CLLocationCoordinate2D) -> Void)?
        var onPoiLongPress: ((Poi) -> Void)?
        var onPoiMoved: ((Poi, Double, Double) -> Void)?
        /// v2.20 电警点拖动落点回调（id, lat, lon —— WGS）
        var onCameraMoved: ((Int, Double, Double) -> Void)?
        /// v2.20 正在被拖动的电警点 id（拖动中不覆盖坐标）
        var draggingCameraId: Int = 0
        /// 长按拖动校准状态
        private var dragAnnotation: PoiAnnotation?
        private var dragStartPt: CGPoint = .zero
        private var dragStartCoord: CLLocationCoordinate2D?
        var onPoiSelect: ((Poi) -> Void)?
        /// v2.26 电警点轻点回调（官方公示点位 → 弹出分享/删除卡片）
        var onCameraSelect: ((PoliceCamera) -> Void)?
        var onPlaceSelect: ((PlaceLabel) -> Void)?
        var onPlaceLongPress: ((PlaceLabel) -> Void)?
        var onCategorySelect: ((AppModel.CategoryResult) -> Void)?
        var onMapTap: ((CLLocationCoordinate2D) -> Void)?
        /// v2.01 比例尺文本回调
        var onScaleChange: ((String) -> Void)?
        /// v1.98 备选路线点击切换
        var onRouteChoiceTap: ((Int) -> Void)?

        /// v2.02 比例尺（重写）
        ///
        /// 旧实现有两个致命问题，直接导致启动卡顿/闪退与比例尺乱跳：
        /// ① 在 updateUIView 里调用 → 回调改 SwiftUI @State → 触发新一轮 updateUIView → 循环；
        /// ② 在 mapViewDidChangeVisibleRegion 里调用（每帧一次）→ 状态高频抖动。
        /// 现在：只在"地图停止变化"后计算，0.25 秒去抖，且用 lastScaleText 去重。
        private var scaleWork: DispatchWorkItem?

        func scheduleScale(_ map: MKMapView, delay: TimeInterval = 0.25) {
            scaleWork?.cancel()
            let w = DispatchWorkItem { [weak self, weak map] in
                guard let self, let map else { return }
                self.reportScale(map)
            }
            scaleWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
        }

        func reportScale(_ map: MKMapView) {
            guard map.bounds.height > 0 else { return }
            let metersPerPoint = map.region.span.latitudeDelta * 111_000.0 / Double(map.bounds.height)
            guard metersPerPoint > 0, metersPerPoint.isFinite else { return }
            let target = metersPerPoint * 58.0
            let nice: [Double] = [1, 2, 5, 10, 20, 50, 100, 200, 500,
                                  1_000, 2_000, 5_000, 10_000, 20_000, 50_000, 100_000]
            var pick = nice.last ?? 100_000
            for v in nice where v >= target { pick = v; break }
            let text = pick >= 1000
                ? "\(Int(pick / 1000)) 公里"
                : "\(Int(pick)) 米"
            guard text != lastScaleText else { return }
            lastScaleText = text
            onScaleChange?(text)
        }
        var choiceRoutes: [[CLLocationCoordinate2D]] = []
        var selectedRouteIdx = 0
        /// v1.98 规划态：此时轻点地图任何位置（含地名标签）都应退出规划回首页
        var planning = false
        /// v1.69 地图加载回调（MKMapView 渲染完成/失败）
        var onMapLoad: ((Bool, String) -> Void)?
        /// v1.69 重载计数记忆
        var lastReloadTick = 0
        /// 是否已做过首次定位居中
        var hasCentered = false
        /// 定位/全览/预览请求记忆（只响应新请求，避免定位更新反复重置地图）
        var lastLocateTick = 0
        var lastFitTick = 0
        var lastGasTick = 0
        var lastZoomInTick = 0
        /// v1.81 地点查看北向上记忆
        var lastNorthUpTick = 0
        /// v1.81 地点区域多边形（AOI）记忆
        var lastTipPolygonKey = ""
        var tipPolygonOverlay: MKPolygon?
        var lastZoomOutTick = 0
        var lastPreviewKey = ""
        var lastViaKey: Int?
        /// v2.21 已处理过的聚焦计数
        var lastFocusTick = -1
        /// v2.22 已处理过的视野档位
        var lastNavScaleTick = -1
        /// v2.22 已走过的折线索引（灰色部分）
        var traveledIdx = 0
        /// v2.22 已走过的折线（灰色层）
        var traveledPolyline: MKPolyline?
        /// v2.22 起点/终点内部道路的蓝色虚线连接段
        var connectorPolylines: [MKPolyline] = []
        /// v2.23 搜索选点到我的位置的黑色连线
        var searchLinkPolyline: MKPolyline?
        /// v2.25 搜索选点高亮标注
        var searchHitAnnotation: SearchHitAnnotation?
        /// v2.25 高亮内容键（标注增删）
        var lastSearchHitKey = ""
        /// v2.25 视野跳转内容键（与标注分开，避免互相覆盖）
        var lastSearchHitViewKey = ""
        /// v2.23 黑线内容键（坐标变化才重建）
        var lastSearchLinkKey = ""
        /// v2.22 起点/终点入口箭头标注
        var entryArrowAnnotations: [RouteEndAnnotation] = []
        /// v2.22 内部道路虚线的内容键
        var lastConnKey = ""
        /// v2.22 上次上报给业务层的"用户移动了地图"状态
        var lastUserMovedFlag = false
        /// v2.22 用户手动移动了地图（回调给业务层）
        var onUserMovedChanged: ((Bool) -> Void)?
        /// v2.01 俯仰角记忆（pitchDeg 变化才应用，避免覆盖用户双指俯仰）
        var lastPitchDeg: Double = 0
        /// v2.01 比例尺上次文本（只在变化时回调，避免每帧刷新 SwiftUI）
        var lastScaleText = ""
        /// v2.02 折线重建键（内容不变就不重建，避免闪烁/卡顿）
        var lastRouteKey = ""
        /// v2.12 标注同步键：点位/电警/加油站/地名/类别内容不变就整段跳过，
        /// 避免每秒多次全表扫描（原来一帧要几十万次比较，是地图页卡顿的主因）
        var lastPoiKey: Int?
        var lastCamKey: Int?
        var lastGasKey: Int?
        var lastPlaceKey: Int?
        var lastCatKey: Int?
        var lastHotCameraId: Int?
        var lastEndKey = ""
        /// v2.14 首屏加载完成只上报一次（详见 mapViewDidFinishRenderingMap）
        var loadReadyReported = false
        /// v1.84 巡航模式状态记忆（巡航开关切换/跟随 tick/上次相机中心节流）
        var lastCruise: Bool?
        var lastCruiseTick = 0
        var cruiseLastLoc: CLLocationCoordinate2D?
        /// 导航深色底图状态记忆
        var lastDarkState: Bool?
        /// v1.67 高德瓦片 renderer 引用 + 深色（夜间瓦片 style=8）状态
        var amapRenderer: AmapTileRenderer?
        /// v2.14 高德瓦片 overlay 延迟插入（首帧交给苹果底图，避免启动被 watchdog 杀）
        var amapOverlay: AmapTileOverlay?
        private var amapOverlayInserted = false
        func insertAmapOverlayIfNeeded(_ map: MKMapView) {
            guard !amapOverlayInserted, let ov = amapOverlay else { return }
            amapOverlayInserted = true
            map.insertOverlay(ov, at: 0, level: .aboveRoads)
        }
        var amapDark = false
        /// 路线白色描边底层引用（renderer 区分双层）
        var underPolyline: MKPolyline?
        /// 当前方案主层（草绿色，renderer 区分）
        var mainPolyline: MKPolyline?
        /// 备选方案折线（浅绿色虚线，renderer 区分）
        var alternatePolylines: [MKPolyline] = []
        /// v1.99 路况分段折线与对应颜色（按下标一一对应）
        var trafficPolylines: [MKPolyline] = []
        var trafficColors: [UIColor] = []
        var footprintPolyline: MKPolyline?
        var lastTeamKey = ""
        /// 用户手动移动/旋转地图（暂停跟随与自动旋转，点定位按钮恢复）
        var userMoved = false
        /// 导航跟随触发记忆
        var lastNavFollowTick = 0
        var lastOverviewTick = 0
        /// 导航中最后跟随位置（开远自动拉回）
        var navLastFollow: CLLocationCoordinate2D?
        /// 程序主动设置区域（避免被标记为用户移动）
        private var programmaticMove = false

        func setRegionProgrammatically(_ block: () -> Void) {
            programmaticMove = true
            block()
        }

        /// v1.98 统一缩放入口：先脱离跟随（否则 MapKit 会立刻回中，表现为按钮点了没反应）
        func zoom(_ map: MKMapView, by factor: Double, center: CLLocationCoordinate2D) {
            if map.userTrackingMode != .none {
                map.setUserTrackingMode(.none, animated: false)
            }
            userMoved = true
            let span = map.region.span
            let lat = min(89.0, max(0.0005, span.latitudeDelta * factor))
            let lon = min(179.0, max(0.0005, span.longitudeDelta * factor))
            setRegionProgrammatically {
                map.setRegion(MKCoordinateRegion(center: center,
                                                 span: MKCoordinateSpan(latitudeDelta: lat, longitudeDelta: lon)),
                              animated: true)
            }
        }

        /// v1.98 双击地图放大：以双击位置为中心，缩放步长比点按钮略缓（2 倍 → 0.55 倍跨度）
        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let map = gesture.view as? MKMapView else { return }
            let pt = gesture.location(in: map)
            let center = map.convert(pt, toCoordinateFrom: map)
            zoom(map, by: 0.55, center: center)
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else { return }
            let pt = gesture.location(in: map)
            switch gesture.state {
            case .began:
                // v2.20 电警点用 MapKit 原生拖拽（跟手），长按别去抢它：
                // 命中电警标注时直接放行，避免拖动时又弹出地点卡
                for a in map.annotations {
                    if let ca = a as? CameraAnnotation {
                        let ap = map.convert(ca.coordinate, toPointTo: map)
                        if hypot(pt.x - ap.x, pt.y - ap.y) < 34 { return }
                    }
                }
                // 命中已有点位标注 → 进入拖动校准；否则空白长按菜单
                var best: Poi?
                var bestDist = CGFloat.greatestFiniteMagnitude
                for a in map.annotations {
                    if let pa = a as? PoiAnnotation {
                        let ap = map.convert(pa.coordinate, toPointTo: map)
                        let d = hypot(pt.x - ap.x, pt.y - ap.y)
                        if d < 40 && d < bestDist { bestDist = d; best = pa.poi }
                    }
                }
                if let p = best {
                    dragStartPt = pt
                    dragStartCoord = p.coordinate
                    dragAnnotation = map.annotations
                        .compactMap { $0 as? PoiAnnotation }
                        .first { $0.poi.id == p.id }
                } else {
                    // v1.81：长按地点名标签 → 地图高亮+北向上+地点信息卡
                    var bestPlace: PlaceLabel?
                    var bestPlaceDist = CGFloat.greatestFiniteMagnitude
                    for a in map.annotations {
                        if let pla = a as? PlaceAnnotation {
                            let ap = map.convert(pla.coordinate, toPointTo: map)
                            let d = hypot(pt.x - ap.x, pt.y - ap.y)
                            if d < 44 && d < bestPlaceDist { bestPlaceDist = d; bestPlace = pla.place }
                        }
                    }
                    if let p = bestPlace {
                        onPlaceLongPress?(p)
                    } else {
                        // v2.00 地图返回 GCJ，业务层要 WGS
                        let coord = MapGeo.toWGS(map.convert(pt, toCoordinateFrom: map))
                        onLongPress?(coord)
                    }
                }
            case .changed:
                if let ann = dragAnnotation {
                    // v2.00 dragCoordinate 存 WGS（coordinate 输出时会再转 GCJ）
                    let newCoord = MapGeo.toWGS(map.convert(pt, toCoordinateFrom: map))
                    ann.dragCoordinate = newCoord
                    // 地图跟随平移（高德拖拽标记行为）：标注始终保持在手指下，可拖出屏幕范围继续移动
                    let ap = map.convert(ann.coordinate, toPointTo: map)
                    let dx = pt.x - ap.x
                    let dy = pt.y - ap.y
                    if abs(dx) > 1 || abs(dy) > 1 {
                        let center = map.convert(
                            CGPoint(x: map.bounds.midX + dx, y: map.bounds.midY + dy),
                            toCoordinateFrom: map)
                        setRegionProgrammatically {
                            map.setCenter(center, animated: false)
                        }
                    }
                }
            case .ended, .cancelled:
                guard let ann = dragAnnotation, let poi = dragStartCoord != nil ? ann.poi : nil else { return }
                let moved = hypot(pt.x - dragStartPt.x, pt.y - dragStartPt.y) > 20
                let final = ann.dragCoordinate ?? dragStartCoord!
                ann.dragCoordinate = nil
                dragAnnotation = nil
                if moved && gesture.state == .ended {
                    onPoiMoved?(poi, final.latitude, final.longitude)
                } else if gesture.state == .ended {
                    onPoiLongPress?(poi)
                }
            default: break
            }
        }

        /// 轻点地图空白处：选点（命中标注时不触发，避免与点位/地点选择冲突）
        @objc func handleMapTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended,
                  let map = gesture.view as? MKMapView else { return }
            let pt = gesture.location(in: map)
            // v1.96 命中判断改为直接派发回调：didSelect 只在点中图标本身时触发，
            // 而"地点名文字"渲染在图标下方，常落在图标 frame 之外，
            // 只靠 didSelect 会出现"点了文字没反应"的死区。
            var hit: MKAnnotation?
            var hitDist = CGFloat.greatestFiniteMagnitude
            for a in map.annotations where !(a is MKUserLocation) {
                let isPlace = a is PlaceAnnotation
                // 被碰撞隐藏的地点标签不参与命中：缩小时大量标签被 MapKit 隐藏，
                // 若仍参与命中，点空地会弹出看不见的地名卡
                if isPlace {
                    guard let v = map.view(for: a), !v.isHidden, v.alpha > 0.05 else { continue }
                }
                let ap = map.convert(a.coordinate, toPointTo: map)
                let d = hypot(pt.x - ap.x, pt.y - ap.y)
                // 地点名标签的文字范围更大，热区放宽到 46pt
                let limit: CGFloat = isPlace ? 46 : 40
                if d < limit && d < hitDist {
                    hitDist = d
                    hit = a
                }
            }
            // v1.98 先判断是否点到备选路线（屏幕 28pt 内）→ 切换方案，和点方案卡等价
            if choiceRoutes.count > 1 {
                var bestIdx = -1
                var bestD = CGFloat.greatestFiniteMagnitude
                for (i, pts) in choiceRoutes.enumerated() where i != selectedRouteIdx && pts.count > 1 {
                    let d = Self.pointDistance(pts, to: pt, in: map)
                    if d < bestD { bestD = d; bestIdx = i }
                }
                if bestIdx >= 0, bestD <= 28 {
                    onRouteChoiceTap?(bestIdx)
                    return
                }
            }
            let coord = MapGeo.toWGS(map.convert(pt, toCoordinateFrom: map))
            // v1.98 规划态：点地图任何位置（含地名标签）都退出规划回首页
            if planning {
                onMapTap?(coord)
                return
            }
            if let a = hit {
                // 地点名文字 → 地点介绍卡；类别结果 → 直接规划路线
                if let pla = a as? PlaceAnnotation {
                    onPlaceSelect?(pla.place)
                } else if let ca = a as? CategoryAnnotation {
                    onCategorySelect?(ca.result)
                }
                // 其它标注（拍照点位/起终点/加油站）维持原样：吞掉点击，不当作空白
                return
            }
            onMapTap?(coord)
        }

        /// 点到折线的最短屏幕距离（每 2 个点抽样，兼顾精度与开销）
        /// v2.00 入参是业务层 WGS 坐标，转 GCJ 后再换算屏幕点
        static func pointDistance(_ pts: [CLLocationCoordinate2D], to p: CGPoint, in map: MKMapView) -> CGFloat {
            guard pts.count > 1 else { return .greatestFiniteMagnitude }
            let g = MapGeo.toGCJ(pts)
            var best = CGFloat.greatestFiniteMagnitude
            var prev = map.convert(g[0], toPointTo: map)
            var i = 1
            while i < g.count {
                let cur = map.convert(g[i], toPointTo: map)
                let d = segmentDistance(p, prev, cur)
                if d < best { best = d }
                prev = cur
                i += 2
            }
            return best
        }

        static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            if len2 < 0.0001 { return hypot(p.x - a.x, p.y - a.y) }
            var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
            t = max(0, min(1, t))
            return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { false }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            scheduleScale(mapView)   // v2.02 地图稳定后再算比例尺（去抖，避免每帧改状态）
            // 程序 setRegion 触发时不标记用户移动
            if programmaticMove {
                programmaticMove = false
            } else if !animated {
                // 用户手势（拖动/旋转/缩放）触发的区域变化 → 暂停跟随与自动旋转
                userMoved = true
            }
        }

        // v1.69 地图加载回调（MKMapView：渲染完成 / 加载失败）
        func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
            // v2.14 只回调第一次。
            //
            // 这个代理在地图**每完成一次渲染**时都会调用，而我们的瓦片 overlay 每批瓦片到达
            // 都会 setNeedsDisplay → 又一次渲染完成 → 又一次回调。
            // 回调到 SwiftUI 就是「写 @State → ContentView.body 全量重算 → updateUIView」，
            // 而 body 是 4000 行的一整棵树 —— 于是「渲染→重算→再渲染」自激放大，
            // 主线程被占满：画面完整但点不动、拖不动，瓦片下载回调也排不上队（一直灰格子）。
            // 这个通知对 UI 只有「首屏是否就绪」一个语义，重复发没有意义。
            // v2.14 首帧已交出 → 现在才叠高德瓦片（此时再慢也不会被打 watchdog）
            insertAmapOverlayIfNeeded(mapView)
            if !loadReadyReported {
                loadReadyReported = true
                onMapLoad?(true, "地图渲染完成")
            }
            if lastScaleText.isEmpty { scheduleScale(mapView, delay: 0.1) }  // v2.02 首屏补一次
        }

        func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: Error) {
            onMapLoad?(false, error.localizedDescription)
        }

        /// v2.20 电警点拖动：跟手移动 → 松手落点 → 回写坐标（持久化）
        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
                     didChange newState: MKAnnotationView.DragState,
                     fromOldState oldState: MKAnnotationView.DragState) {
            guard let cam = view.annotation as? CameraAnnotation else { return }
            switch newState {
            case .starting:
                cam.beginDrag()
                draggingCameraId = cam.cameraId
            case .dragging:
                // MapKit 已把 annotation.coordinate 更新为新位置（GCJ）
                // v2.20 拖到屏幕边缘时地图跟着走，避免标注被拖出可视区找不回来
                let p = mapView.convert(cam.coordinate, toPointTo: mapView)
                let b = mapView.bounds
                let margin: CGFloat = 90
                var dx: CGFloat = 0, dy: CGFloat = 0
                if p.x < b.minX + margin { dx = p.x - (b.minX + margin) }
                else if p.x > b.maxX - margin { dx = p.x - (b.maxX - margin) }
                if p.y < b.minY + margin { dy = p.y - (b.minY + margin) }
                else if p.y > b.maxY - margin { dy = p.y - (b.maxY - margin) }
                if dx != 0 || dy != 0 {
                    let center = mapView.convert(CGPoint(x: b.midX + dx, y: b.midY + dy),
                                                toCoordinateFrom: mapView)
                    mapView.setCenter(center, animated: false)
                }
            case .ending:
                draggingCameraId = 0
                // 以"图钉最终屏幕位置"反算坐标（不依赖 MapKit 是否回写 annotation.coordinate），
                // 保证松手落点与手指位置一致
                let gcj = mapView.convert(view.center, toCoordinateFrom: mapView)
                cam.setCoordinate(gcj)
                let wgs = MapGeo.toWGS(gcj)
                // 几乎没动就不写覆盖表（避免误触产生一堆无效校准）
                let dx = (wgs.latitude - cam.originWGS.latitude) * 111_000
                let dy = (wgs.longitude - cam.originWGS.longitude) * 94_000
                if hypot(dx, dy) > 3 {
                    onCameraMoved?(cam.cameraId, wgs.latitude, wgs.longitude)
                }
            case .canceling:
                draggingCameraId = 0
                cam.cancelDrag()
            case .none:
                draggingCameraId = 0
            @unknown default:
                draggingCameraId = 0
            }
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            // 点击地点：高亮显示名称并回调（取消系统选中态，避免遮挡）
            if let pa = view.annotation as? PoiAnnotation {
                mapView.deselectAnnotation(view.annotation, animated: false)
                onPoiSelect?(pa.poi)
            } else if let pla = view.annotation as? PlaceAnnotation {
                mapView.deselectAnnotation(view.annotation, animated: false)
                onPlaceSelect?(pla.place)
            } else if let ca = view.annotation as? CategoryAnnotation {
                mapView.deselectAnnotation(view.annotation, animated: false)
                onCategorySelect?(ca.result)
            } else if let cam = view.annotation as? CameraAnnotation {
                // v2.26 轻点官方电警点 → 弹出"分享 + 删除"卡片（此前点击完全没反应）
                mapView.deselectAnnotation(view.annotation, animated: false)
                if let c = cam.camera {
                    onCameraSelect?(c)
                }
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            // 当前位置：缩小版指南针图标（玻璃圆底 + 红色指北针）
            if annotation is MKUserLocation {
                let id = "userLoc"
                var v = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                if v == nil {
                    v = MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                }
                v?.image = MapViewRepresentable.makeUserIcon()
                v?.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
                v?.centerOffset = .zero
                v?.canShowCallout = false
                return v
            }
            if let re = annotation as? RouteEndAnnotation {
                // v2.22 起终点入口箭头：白色圆形 + 左转/直行/右转箭头（高德式）
                if re.kind.hasPrefix("arrow_") {
                    let id = "routeArrow"
                    let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                        ?? MKMarkerAnnotationView(annotation: re, reuseIdentifier: id)
                    v.annotation = re
                    v.canShowCallout = false
                    v.markerTintColor = .white
                    v.glyphImage = UIImage(systemName: arrowGlyph(for: re.kind))
                    v.displayPriority = .required
                    return v
                }
                let id = "routeEnd"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: re, reuseIdentifier: id)
                switch re.kind {
                case "start": v.markerTintColor = .systemGreen; v.glyphText = "起"
                case "via": v.markerTintColor = .systemOrange; v.glyphText = "途"
                default: v.markerTintColor = .systemRed; v.glyphText = "终"
                }
                v.titleVisibility = .adaptive
                return v
            }
            if let ta = annotation as? TeamAnnotation {
                let id = "team"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: ta, reuseIdentifier: id)
                v.markerTintColor = .systemTeal
                v.glyphText = String(ta.name.prefix(1))
                v.titleVisibility = .visible
                v.canShowCallout = false
                return v
            }
            if let pa = annotation as? PreviewAnnotation {
                let id = "preview"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: pa, reuseIdentifier: id)
                v.markerTintColor = .systemGreen
                v.glyphText = "✓"
                v.titleVisibility = .adaptive
                return v
            }
            if let sh = annotation as? SearchHitAnnotation {
                // v2.25 搜索选点高亮：橙色定位环 + 名称气泡
                let id = "searchHit"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: sh, reuseIdentifier: id)
                v.annotation = sh
                v.markerTintColor = UIColor(red: 1.0, green: 0.45, blue: 0.0, alpha: 1.0)
                v.glyphText = "📍"
                v.displayPriority = .required
                v.titleVisibility = .adaptive
                v.canShowCallout = false
                return v
            }
            if let ga = annotation as? GasAnnotation {
                let id = "gas"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: ga, reuseIdentifier: id)
                v.markerTintColor = .systemOrange
                v.glyphText = "油"
                v.titleVisibility = .hidden
                return v
            }
            if let pla = annotation as? PlaceAnnotation {
                let id = "place"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: pla, reuseIdentifier: id)
                v.markerTintColor = .systemGray
                v.glyphText = nil
                v.titleVisibility = .visible // 直接显示小区/商铺名称
                v.canShowCallout = false
                v.displayPriority = .defaultLow
                return v
            }
            if let ca = annotation as? CategoryAnnotation {
                let id = "category"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: ca, reuseIdentifier: id)
                // 按类别着色：学校蓝 / 医院红 / 加油站橙
                switch ca.result.kind {
                case "医院": v.markerTintColor = .systemRed
                case "加油站": v.markerTintColor = .systemOrange
                default: v.markerTintColor = .systemBlue
                }
                v.glyphText = ca.result.kind == "加油站" ? "油" : "点"
                v.titleVisibility = .visible
                v.canShowCallout = false
                v.displayPriority = .required
                return v
            }
            // v2.04 官方电警点位：红底相机图标（比 MKMarker 轻，几十个点也不拖慢瓦片）
            if let cam = annotation as? CameraAnnotation {
                let id = "policeCam"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? CameraPinView
                    ?? CameraPinView(annotation: cam, reuseIdentifier: id)
                v.annotation = cam
                // v2.27（建议 #29）网络同步的点位标成"待校准"样式（缩小一号，提示可拖动修正）
                v.configure(kind: cam.kind, pending: cam.isPending)
                v.setHot(cam.isHot)
                // v2.20 电警点可跟手拖动：MapKit 原生拖拽，手指点哪落到哪
                v.isDraggable = true
                return v
            }
            guard let pa = annotation as? PoiAnnotation else { return nil }
            let id = "poi"
            let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: pa, reuseIdentifier: id)
            v.markerTintColor = pa.poi.type.color
            v.titleVisibility = .adaptive
            v.glyphText = String(pa.poi.type.label.prefix(1))
            // 沿途点位：白色描边高亮（优先）；用户自定义/移动过的点位：橙色描边（可与内置点位区分）
            if pa.onRoute {
                v.layer.borderWidth = 2.5
                v.layer.borderColor = UIColor.white.cgColor
            } else if pa.poi.isCustom {
                v.layer.borderWidth = 2
                v.layer.borderColor = UIColor.orange.cgColor
            } else {
                v.layer.borderWidth = 0
            }
            return v
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let poly = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: poly)
                r.lineCap = .round
                // v1.99 路况分段优先着色（缓行黄 / 拥堵红）
                if let ti = self.trafficPolylines.firstIndex(where: { $0 === poly }) {
                    // 防御：数组若因并发/重建短暂不同步，越界会直接崩（crash 日志里的常见项）
                    r.strokeColor = ti < self.trafficColors.count ? self.trafficColors[ti] : UIColor.systemOrange
                    r.lineWidth = 7
                    return r
                }
                if poly === self.traveledPolyline {
                    // v2.22 已走过的路段：灰色实线（未走的保持草绿）
                    r.strokeColor = UIColor(white: 0.55, alpha: 0.95)
                    r.lineWidth = 6
                    return r
                }
                if self.connectorPolylines.contains(where: { $0 === poly }) {
                    // v2.22 起点/终点内部道路：蓝色虚线（连接定位点与道路入口）
                    r.strokeColor = UIColor(red: 0.20, green: 0.55, blue: 1.0, alpha: 0.95)
                    r.lineWidth = 4
                    r.lineDashPattern = [4, 5]
                    return r
                }
                if poly === self.searchLinkPolyline {
                    // v2.23 搜索选点连线：黑色实线（我的位置 → 搜索选点）
                    r.strokeColor = UIColor(white: 0.05, alpha: 0.85)
                    r.lineWidth = 3
                    return r
                }
                if poly === self.footprintPolyline {
                    r.strokeColor = UIColor(red: 0.16, green: 0.45, blue: 0.98, alpha: 0.9)
                    r.lineWidth = 5
                    r.lineDashPattern = [8, 6]
                    return r
                }
                if poly === self.underPolyline {
                    // v1.66 高德式绿色并行线：深绿外框（路线更贴路、双线视觉）
                    r.strokeColor = UIColor(red: 0.10, green: 0.55, blue: 0.22, alpha: 1.0)
                    r.lineWidth = 9
                } else if poly === self.mainPolyline {
                    // 推荐路线：浅绿内芯（高德绿路线双线效果）
                    r.strokeColor = UIColor(red: 0.42, green: 0.84, blue: 0.46, alpha: 1.0)
                    r.lineWidth = 5
                } else if self.alternatePolylines.contains(where: { $0 === poly }) {
                    // v2.01 备选路线：灰色实线（高德同款）——点了哪条，哪条变绿，其余保持灰
                    r.strokeColor = UIColor(white: 0.62, alpha: 1.0)
                    r.lineWidth = 6
                } else {
                    r.strokeColor = UIColor(red: 0.32, green: 0.74, blue: 0.35, alpha: 1.0)
                    r.lineWidth = 4
                }
                return r
            }
            if let pg = overlay as? MKPolygon {
                // v1.81 地点区域范围：蓝色虚线框 + 淡蓝填充
                let r = MKPolygonRenderer(polygon: pg)
                r.strokeColor = UIColor(red: 0.16, green: 0.45, blue: 0.98, alpha: 0.95)
                r.fillColor = UIColor(red: 0.16, green: 0.45, blue: 0.98, alpha: 0.08)
                r.lineWidth = 2.5
                r.lineDashPattern = [7, 6]
                return r
            }
            if let amap = overlay as? AmapTileOverlay {
                // v1.67：高德瓦片底图 renderer（浅色 style=7 / 导航深色 style=8 随导航态切换）
                let renderer = AmapTileRenderer(overlay: amap)
                amapRenderer = renderer
                renderer.dark = amapDark
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

/// v1.99 组队队友标注（地图上的"骑手点"）
/// v2.00 内部保存 WGS，`coordinate` 输出 GCJ（地图只认 GCJ）
final class TeamAnnotation: NSObject, MKAnnotation {
    let name: String
    let speedKph: Double
    private let wgs: CLLocationCoordinate2D
    var coordinate: CLLocationCoordinate2D { MapGeo.toGCJ(wgs) }

    init(name: String, speedKph: Double, coordinate: CLLocationCoordinate2D) {
        self.name = name
        self.speedKph = speedKph
        self.wgs = coordinate
        super.init()
    }
    var title: String? { name }
    var subtitle: String? { String(format: "%.0f km/h", speedKph) }
}

/// 路线起点/终点标记
/// v2.22 入口箭头图标名（kind 形如 "arrow_left" / "arrow_straight" / "arrow_right"）
func arrowGlyph(for kind: String) -> String {
    switch kind {
    case "arrow_left": return "arrow.turn.up.left"
    case "arrow_right": return "arrow.turn.up.right"
    default: return "arrow.up"
    }
}

/// 路线起点/终点/途经点标注
///
/// v2.21 关键修复：coordinate 之前是**只读计算属性**（`MapGeo.toGCJ(wgs)`）。
/// MKAnnotation 只要求有 getter，但 MapKit 内部会观察并在某些路径下
/// 用 KVC（setValue:forKey:"coordinate"）回写坐标 —— 对只读计算属性这么写会抛
/// NSUnknownKeyException，表现为"点一下地图上的途经点就闪退"。
/// 现在改成 `@objc dynamic var` 存储属性（存 GCJ-02），赋值自带 KVO，MapKit 随便写都不炸。
final class RouteEndAnnotation: NSObject, MKAnnotation {
    let kind: String
    /// v2.21 可写坐标（GCJ-02，MapKit 坐标系）；@objc dynamic 保证 KVO + KVC 安全
    @objc dynamic var coordinate: CLLocationCoordinate2D
    /// 原始 WGS-84 坐标（业务层用）
    private var wgs: CLLocationCoordinate2D

    init(kind: String, coordinate: CLLocationCoordinate2D) {
        self.kind = kind
        self.wgs = coordinate
        self.coordinate = MapGeo.toGCJ(coordinate)
        super.init()
    }

    var title: String? {
        switch kind {
        case "start": return "起点"
        case "via": return "途经点"
        default: return "终点"
        }
    }

    var subtitle: String? {
        kind == "via" ? "点击可移除该途经点" : nil
    }

    /// v2.19/v2.21 途经点复用标注时更新坐标（GCJ 输入）
    func setCoordinateGCJ(_ gcj: CLLocationCoordinate2D) {
        coordinate = gcj
        wgs = MapGeo.toWGS(gcj)
    }
}

final class PoiAnnotation: NSObject, MKAnnotation {
    var poi: Poi
    var onRoute: Bool
    /// 拖动校准中的临时坐标（nil = 使用点位原始坐标）；v2.00 起存 WGS
    var dragCoordinate: CLLocationCoordinate2D?
    init(poi: Poi, onRoute: Bool = false) {
        self.poi = poi
        self.onRoute = onRoute
        super.init()
    }
    var coordinate: CLLocationCoordinate2D { MapGeo.toGCJ(dragCoordinate ?? poi.coordinate) }
    var title: String? { poi.name }
    var subtitle: String? { poi.type.label }
}

/// 搜索预览点（绿色高亮）
final class PreviewAnnotation: NSObject, MKAnnotation {
    private var wgs: CLLocationCoordinate2D
    var coordinate: CLLocationCoordinate2D { MapGeo.toGCJ(wgs) }
    init(coordinate: CLLocationCoordinate2D) {
        self.wgs = coordinate
        super.init()
    }
    /// 坐标变化时手动发 KVO（计算属性不会自动通知，MapKit 靠 KVO 移动标注）
    func update(_ c: CLLocationCoordinate2D) {
        willChangeValue(forKey: "coordinate")
        wgs = c
        didChangeValue(forKey: "coordinate")
    }
    var title: String? { "搜索目标" }
}

/// v2.25 搜索选点高亮（坐标 + 名称）
/// 用结构体而不是元组 —— Swift 的 memberwise init 对元组标签的处理容易出坑
struct SearchHit {
    let coord: CLLocationCoordinate2D
    let title: String
}

/// v2.25 搜索选点高亮标注
///
/// 需求：搜索框搜到地点后，除了弹地点卡，地图还要跳到该点并**高亮显示**，
/// 同时用黑线把"我的位置"和该点连起来。
/// 用 MKMarkerAnnotationView + 自定义光圈视图实现"定位环 + 名称气泡"。
final class SearchHitAnnotation: NSObject, MKAnnotation {
    private var wgs: CLLocationCoordinate2D
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let titleText: String

    init(coordinate: CLLocationCoordinate2D, title: String) {
        self.wgs = coordinate
        self.coordinate = MapGeo.toGCJ(coordinate)
        self.titleText = title
        super.init()
    }

    var title: String? { titleText }

    func update(_ c: CLLocationCoordinate2D) {
        wgs = c
        coordinate = MapGeo.toGCJ(c)
    }
}

/// 加油站标注（橙色"油"）
final class GasAnnotation: NSObject, MKAnnotation {
    let id: String
    private var wgs: CLLocationCoordinate2D
    var coordinate: CLLocationCoordinate2D { MapGeo.toGCJ(wgs) }
    init(id: String, coordinate: CLLocationCoordinate2D) {
        self.id = id
        self.wgs = coordinate
        super.init()
    }
    /// 业务层用的 WGS 键（coordinate 已转 GCJ，不能再用它比较）
    var wgsKey: String { "\(wgs.latitude),\(wgs.longitude)" }
    var title: String? { "加油站" }
}

/// 小区/商铺名称标签标注
final class PlaceAnnotation: NSObject, MKAnnotation {
    let place: PlaceLabel
    init(place: PlaceLabel) {
        self.place = place
        super.init()
    }
    var coordinate: CLLocationCoordinate2D {
        MapGeo.toGCJ(CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon))
    }
    var title: String? { place.name }
}

/// 类别搜索结果标注（学校/医院/加油站）
final class CategoryAnnotation: NSObject, MKAnnotation {
    let result: AppModel.CategoryResult
    init(result: AppModel.CategoryResult) {
        self.result = result
        super.init()
    }
    var coordinate: CLLocationCoordinate2D {
        MapGeo.toGCJ(CLLocationCoordinate2D(latitude: result.lat, longitude: result.lon))
    }
    var title: String? { result.name }
}

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}

extension MapViewRepresentable {
    /// v1.63 精简定位图标：高德同款实心蓝色指向箭头（无光晕/无中心点/无装饰，保留指向功能）
    static func makeUserIcon() -> UIImage {
        let size: CGFloat = 40
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            let c = ctx.cgContext
            let cx = size / 2
            // 实心宽胖箭头：尖端朝上（=手机/行进朝向），圆润底部
            let arrow = UIBezierPath()
            arrow.move(to: CGPoint(x: cx, y: 3))                          // 尖端
            arrow.addLine(to: CGPoint(x: cx - 11, y: 29))                 // 左腰
            arrow.addQuadCurve(to: CGPoint(x: cx + 11, y: 29),
                               controlPoint: CGPoint(x: cx, y: 21))       // 圆润箭尾
            arrow.close()
            // 白色细描边（任何底图上清晰）
            c.saveGState()
            c.setLineWidth(2)
            c.setLineJoin(.round)
            UIColor.white.setStroke()
            c.addPath(arrow.cgPath)
            c.strokePath()
            // 实心蓝色填充（高德蓝）
            c.setFillColor(UIColor.systemBlue.cgColor)
            c.addPath(arrow.cgPath)
            c.fillPath()
            c.restoreGState()
        }
    }
}

// MARK: - v1.67 高德瓦片底图（纯高德视觉；GCJ→WGS 重投影 + NSLock 防渲染线程数据竞争闪退）
// v1.62 曾因灰罩/盖路线移除，本轮修复：①层级 .aboveRoads（路线折线/标注在其上，不再被盖）
// ②未加载瓦片透明占位（露出苹果底图兜底，不再大片灰色遮挡）③webrd01-04 多子域轮询防限流

/// 高德标准底图瓦片 overlay（世界网格全屏覆盖）
final class AmapTileOverlay: NSObject, MKOverlay {
    /// 高德标准底图瓦片模板（公开服务，无需 Key；style=7 日间 / 8 夜间）
    static let tileURL = "https://webrd0{SD}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style={STYLE}&x={x}&y={y}&z={z}"
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
}

/// 瓦片重投影 renderer：在 WGS 网格上逐瓦片请求 GCJ 瓦片并按中心对齐绘制
/// 关键：cache/pending/inflight 会被主线程（下载回调）与 VectorKit 渲染线程（draw）并发访问，
/// 必须用 NSLock 保护，否则数据竞争导致 EXC_BAD_ACCESS（真机启动闪退根因）
final class AmapTileRenderer: MKOverlayRenderer {
    private static let zMin = 3, zMax = 19
    private let lock = NSLock()
    private var cache: [String: UIImage] = [:]
    private var pending: Set<String> = []
    /// v2.14 失败瓦片冷却（网络不通时避免每次重绘都重发请求）
    private var failedCooling: Set<String> = []
    /// v2.14 成功加载过的瓦片数（用于底图兜底判断）
    private(set) var loadedTiles = 0
    private var inflight = 0
    /// 夜间瓦片（导航中 style=8）
    var dark = false
    /// v1.90 瓦片磁盘缓存目录（Caches/Tiles）：常用区域瓦片自动落盘，离线可用、省流量
    ///
    /// v2.27（优化建议 #14）按 style 分目录：
    /// 白天（style=7）与夜间（style=8）的瓦片内容完全不同，
    /// 旧版共用一个目录 → 夜间瓦片把白天的覆盖掉，白天来了又覆盖夜间的，
    /// 结果就是"切换昼夜时刚看过的区域又要重新下一遍"。
    /// 分目录后两套缓存互不干扰。
    private static let diskDir: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    /// v2.27 某个 style 的瓦片缓存目录（style=7 白天 / 8 夜间）
    static func diskDirFor(style: Int) -> URL {
        let u = diskDir.appendingPathComponent("style\(style)", isDirectory: true)
        if !FileManager.default.fileExists(atPath: u.path) {
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        }
        return u
    }
    /// v2.27 瓦片缓存统计（诊断页用）
    private static let statLock = NSLock()
    private static var _hitCount = 0
    private static var _missCount = 0
    /// 缓存命中次数（磁盘/内存命中）
    static var hitCount: Int {
        statLock.lock(); defer { statLock.unlock() }
        return _hitCount
    }
    /// 缓存未命中次数（需要走网络）
    static var missCount: Int {
        statLock.lock(); defer { statLock.unlock() }
        return _missCount
    }
    static func noteHit() {
        statLock.lock(); _hitCount += 1; statLock.unlock()
    }
    static func noteMiss() {
        statLock.lock(); _missCount += 1; statLock.unlock()
    }

    /// v2.27（优化建议 #13）瓦片失败指数退避：5s → 10s → 30s → 60s 封顶
    ///
    /// 用失败次数决定等待时长：偶尔失败快速重试（网络抖动），
    /// 持续失败拉长间隔（真的断网，避免请求风暴）。
    private static let backoffLock = NSLock()
    private static var backoffCounts: [String: Int] = [:]
    private static let backoffLadder: [TimeInterval] = [5, 10, 30, 60]
    private static func backoffDelay(for key: String) -> TimeInterval {
        backoffLock.lock()
        let n = backoffCounts[key] ?? 0
        backoffCounts[key] = n + 1
        backoffLock.unlock()
        return backoffLadder[min(n, backoffLadder.count - 1)]
    }

    /// 瓦片磁盘缓存总大小（字节）
    static func diskCacheSize() -> UInt64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: diskDir, includingPropertiesForKeys: [.fileSizeKey], options: []) else { return 0 }
        var total: UInt64 = 0
        for f in files {
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += UInt64(size)
            // style 子目录要递归统计
            if let sub = try? fm.contentsOfDirectory(at: f, includingPropertiesForKeys: [.fileSizeKey], options: []) {
                for g in sub {
                    let s2 = (try? g.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    total += UInt64(s2)
                }
            }
        }
        return total
    }
    /// v1.99 离线包目录（OfflineMapManager 下载到这里）
    private static let offlineDir: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tiles/offline", isDirectory: true)
        return u
    }()
    /// v2.16 并发队列：旧版是串行队列，一屏 200 块瓦片要排队做 200 次"查磁盘缓存"，
    /// 排在后面的瓦片要等前面全部 stat/read 完才开始发请求，放大时白白多等几百毫秒。
    private let ioQueue = DispatchQueue(label: "amap.tile.io", qos: .userInitiated,
                                       attributes: .concurrent)
    private static let diskMaxFiles = 1200
    /// v2.16 并发上限 12 → 24：4 个子域各 6 个并发，正好吃满 URLSession 单域默认连接数
    private static let maxInflight = 24

    /// v2.00 瓦片直铺（关键修复）
    ///
    /// 高德瓦片本身就是 GCJ-02 网格，而 MKMapView 的 overlay 坐标 / 标注坐标在本 App 里
    /// 已统一转成 GCJ（见 MapGeo），所以瓦片必须**按原索引原样铺回同一张 GCJ 网格**。
    ///
    /// v1.98 曾经反过来：把 GCJ 瓦片平移半个瓦片去"对齐"WGS 网格，不仅漏了半瓦片偏移，
    /// 还与已转 GCJ 的折线形成了双重错位——这正是"路线永远压不到路上"的直接原因。
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in ctx: CGContext) {
        // v2.21 层级公式修正（白花根源）
        //
        // 旧代码：z = 20 - log2(zoomScale) —— 符号反了。
        // MKMapView 的 zoomScale 随"放大"而增大，而瓦片层级 z 也随放大而增大，
        // 所以两者必须同向：z = log2(zoomScale) + K。
        // 反向计算的后果：地图一缩小，zoomScale 变小 → z 算成 19（顶格），
        // 一屏要展开 (2^19 级别的网格) 上万块瓦片 → 超过单帧上限后整帧直接不画，
        // 露出的就是苹果底图，表现为"缩小后白花花一片"。
        //
        // K=20 对应 zoomScale=1（MKMapView 默认视野约为 z=20 级别的密度）。
        let zRaw = log2(Double(zoomScale)) + 20.0
        let z = min(AmapTileRenderer.zMax, max(AmapTileRenderer.zMin, Int(zRaw.rounded())))
        let n = 1 << z
        let per = MKMapRect.world.size.width / Double(n)
        var x0 = max(0, Int(floor(mapRect.minX / per)))
        var x1 = min(n - 1, Int(floor(mapRect.maxX / per)))
        var y0 = max(0, Int(floor(mapRect.minY / per)))
        var y1 = min(n - 1, Int(floor(mapRect.maxY / per)))
        guard x1 >= x0, y1 >= y0 else { return }

        // v2.14 上限保护：极端缩放或初始 mapRect 抖动时，可见范围可能大到离谱。
        // 旧实现在这里会展开成上万次循环（每块拼字符串 + 两次加锁），
        // 渲染线程和主线程一起被拖死。
        // v2.16 阈值 400 → 600：3D 俯视/全览时 400 很容易被打到，整帧直接不画，
        // 表现出来就是"一放大/一倾斜就白屏好几秒"。
        // v2.21 单帧上限：修正层级公式后一屏通常是几十块；
        // 但 3D 俯视 + 大跨度时仍可能上百块，旧版超过 600 就**整帧不画**，
        // 露出的就是苹果底图，表现为"缩小后白花花一片"。
        // 现在超限时不再整帧放弃，而是**只画中心区域**（屏幕中央永远有图）。
        if (x1 - x0 + 1) * (y1 - y0 + 1) > 900 {
            let maxSide = 30
            let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2
            x0 = max(0, cx - maxSide / 2); x1 = min(n - 1, x0 + maxSide - 1)
            y0 = max(0, cy - maxSide / 2); y1 = min(n - 1, y0 + maxSide - 1)
        }
        let total = (x1 - x0 + 1) * (y1 - y0 + 1)

        // v2.14 一次加锁收集整帧需求。
        //
        // 旧实现每块瓦片都要 lock/unlock 两次，一屏 200 块就是 400 次锁竞争；
        // 而 draw() 同时在 VectorKit 渲染线程和主线程被调用 —— 崩溃报告里主线程正是停在
        // `_os_unfair_lock_lock_slow → __ulock_wait2`（等锁），配合 21.7 秒系统态 CPU，
        // 说明主线程的绝大部分时间耗在锁和同步 IO 上，首帧始终出不来。
        var drawList: [(CGImage, CGRect)] = []
        drawList.reserveCapacity(total)
        /// v2.16 父级兜底：本层瓦片没到之前，用已缓存的上一级（最多上溯 3 级）放大铺上
        var upscaleList: [(CGImage, CGRect)] = []
        var upscaleSeen = Set<Int>()
        upscaleList.reserveCapacity(64)
        var fetchList: [(x: Int, y: Int, key: String, rect: MKMapRect)] = []
        lock.lock()
        let night = dark
        for x in x0...x1 {
            for y in y0...y1 {
                let key = "\(night ? "n" : "d")-\(z)-\(x)-\(y)"
                let mrect = MKMapRect(x: Double(x) * per, y: Double(y) * per,
                                      width: per, height: per)
                if let img = cache[key], let cg = img.cgImage {
                    drawList.append((cg, rect(for: mrect)))
                    continue
                }
                // 放大时新一层的瓦片全都要重新下载，网络往返期间屏幕上就是一片空白。
                // 这里退一步用上一层的图放大顶住（同一张父瓦片只画一次，4 个子块共用），
                // 清图一到就被本层瓦片盖回去 —— 用户看到的是"先糊后清"，而不是"先白后清"。
                if let a = ancestorLocked(z: z, x: x, y: y, night: night) {
                    let id = (a.z << 42) ^ (a.y << 21) ^ a.x
                    if upscaleSeen.insert(id).inserted {
                        let aper = per * Double(1 << a.depth)
                        let arect = MKMapRect(x: Double(a.x) * aper, y: Double(a.y) * aper,
                                              width: aper, height: aper)
                        upscaleList.append((a.image, rect(for: arect)))
                    }
                }
                if !pending.contains(key) && !failedCooling.contains(key) {
                    pending.insert(key)
                    fetchList.append((x, y, key, mrect))
                }
            }
        }
        lock.unlock()

        // 顺序：先父级放大图打底，再盖本层已缓存的清晰瓦片
        if !upscaleList.isEmpty {
            ctx.interpolationQuality = .low
            for (cg, r) in upscaleList { ctx.draw(cg, in: r) }
        }
        for (cg, r) in drawList { ctx.draw(cg, in: r) }
        guard !fetchList.isEmpty else { return }

        // v2.16 由近及远：中心一圈立即发（旧版只发中心 5×5，其余全部压 0.15s 延迟，
        // 放大后必然先看到中心一小块、四周长时间空白），剩下的才排延迟队列。
        let cx = Double(x0 + x1) / 2, cy = Double(y0 + y1) / 2
        func dist(_ f: (x: Int, y: Int, key: String, rect: MKMapRect)) -> Double {
            let dx = Double(f.x) - cx, dy = Double(f.y) - cy
            return dx * dx + dy * dy
        }
        let ordered = fetchList.sorted { dist($0) < dist($1) }
        let immediateCap = 48
        for (i, f) in ordered.enumerated() {
            if i < immediateCap {
                fetchTile(f.x, f.y, z, f.key, f.rect)
            } else {
                queueTile(f.x, f.y, z, f.key, f.rect)
            }
        }
    }

    /// v2.16 往上找最近一层已缓存的瓦片（z-1 / z-2 / z-3），用于放大时的低清兜底。
    /// 调用方必须已持锁。
    private func ancestorLocked(z: Int, x: Int, y: Int, night: Bool) -> AncestorTile? {
        var cz = z, cx = x, cy = y, depth = 0
        while depth < 3, cz > Self.zMin {
            cz -= 1; cx /= 2; cy /= 2; depth += 1
            if let cg = cache["\(night ? "n" : "d")-\(cz)-\(cx)-\(cy)"]?.cgImage {
                return AncestorTile(image: cg, x: cx, y: cy, z: cz, depth: depth)
            }
        }
        return nil
    }

    private struct AncestorTile {
        let image: CGImage
        let x: Int, y: Int, z: Int
        /// 与当前层的层数差（1 = 父级，2 = 祖父级…），用于把父瓦片画到正确的 mapRect
        let depth: Int
    }

    /// v2.14 重绘合并：一帧内最多触发一次，并且只重绘变化的那一小块。
    ///
    /// 旧实现每张瓦片到达都全屏 `setNeedsDisplay()`，一屏 200 张就是 200 次全屏重绘，
    /// 每次重绘又要走一遍上面的循环 —— 越下载越卡，正是"灰格子 + 卡死"的来源。
    private var redrawScheduled = false
    private var pendingRedraw: MKMapRect?
    private func markNeedsRedraw(_ rect: MKMapRect?) {
        lock.lock()
        if let r = rect {
            pendingRedraw = pendingRedraw.map { $0.union(r) } ?? r
        } else {
            pendingRedraw = .world
        }
        let already = redrawScheduled
        redrawScheduled = true
        lock.unlock()
        guard !already else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let r = self.pendingRedraw
            self.pendingRedraw = nil
            self.redrawScheduled = false
            self.lock.unlock()
            if let r = r {
                self.setNeedsDisplay(r)
            } else {
                self.setNeedsDisplay()
            }
        }
    }

    /// v2.14 边缘瓦片延迟加载：改在 ioQueue 上排队，不再往主队列塞块。
    ///
    /// 旧实现每块边缘瓦片都 `DispatchQueue.main.asyncAfter(0.06)`：一屏上百块 →
    /// 主队列瞬间堆上百个定时块，每个醒来还要加锁查缓存、拼 URL。
    /// 首帧渲染期间主线程被这些块塞满，就是 0x8BADF00D（首帧 10 秒超时）的直接成因。
    private var queuedTiles: Set<String> = []
    private func queueTile(_ x: Int, _ y: Int, _ z: Int, _ key: String, _ rect: MKMapRect) {
        lock.lock()
        if queuedTiles.contains(key) { lock.unlock(); return }
        queuedTiles.insert(key)
        lock.unlock()
        ioQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.queuedTiles.remove(key)
            let cached = self.cache[key] != nil
            self.lock.unlock()
            if !cached { self.fetchTile(x, y, z, key, rect) }
        }
    }

    private func fetchTile(_ x: Int, _ y: Int, _ z: Int, _ key: String, _ rect: MKMapRect) {
        // v2.14 关键修复：draw() 会在渲染线程**和主线程**被调用，这里绝不能做磁盘 IO。
        //
        // 旧实现在 draw() 里直接 `fileExists` + `UIImage(contentsOfFile:)`：
        // 一屏上百张缺失瓦片就是两三百次同步 stat/read 落在主线程上，地图每重绘一次
        // 就把主线程占满一次 —— 表现正是「停在灰格子、整个 App 点不动」。
        // 现在磁盘、网络、解码、落盘全部丢到 ioQueue，draw() 只查内存缓存。
        ioQueue.async { [weak self] in
            guard let self else { return }

            // 别的路径刚下完就不用再走一遍
            self.lock.lock()
            let done = self.cache[key] != nil
            self.lock.unlock()
            if done { return }

            // 1) 离线包 / 磁盘缓存（后台读，命中即用，不再发网络请求）
            // v2.27（优化建议 #14）按 style 分目录：白天/夜间瓦片互不覆盖
            // 变量名用 styleDir，与下面 URL 拼接用的 styleStr 区分开
            // （原来两处都叫 style，同作用域重复声明 → invalid redeclaration）
            let styleDir = key.hasPrefix("n-") ? 8 : 7
            let diskURL = Self.diskDirFor(style: styleDir).appendingPathComponent("\(key).png")
            let offlineURL = Self.offlineDir.appendingPathComponent("\(key).png")
            for url in [offlineURL, diskURL] {
                guard let img = UIImage(contentsOfFile: url.path) else { continue }
                self.lock.lock()
                let already = self.cache[key] != nil
                if !already {
                    self.cache[key] = img
                    self.pending.remove(key)
                }
                self.lock.unlock()
                if !already { self.markNeedsRedraw(rect) }
                Self.noteHit()   // v2.27 诊断用
                return
            }
            Self.noteMiss()      // v2.27 诊断用

            // 2) 网络
            self.lock.lock()
            if self.inflight >= Self.maxInflight {
                // 并发满了：撤掉 pending 让下一帧重投（不发定时器，避免一屏几百个定时块）
                self.pending.remove(key)
                self.lock.unlock()
                return
            }
            self.inflight += 1
            // v2.27：变量改名 styleStr —— 同作用域里已有一个 style（瓦片样式编号 Int），
            // 重复声明会报 "invalid redeclaration of 'style'"
            let styleStr = self.dark ? "8" : "7"
            self.lock.unlock()

            // v2.14 多子域轮询：webrd01-04 按瓦片坐标取模，降低单域限流概率
            let sd = ((x + y) % 4) + 1
            guard let url = URL(string: AmapTileOverlay.tileURL
                .replacingOccurrences(of: "{SD}", with: "\(sd)")
                .replacingOccurrences(of: "{STYLE}", with: styleStr)
                .replacingOccurrences(of: "{x}", with: "\(x)")
                .replacingOccurrences(of: "{y}", with: "\(y)")
                .replacingOccurrences(of: "{z}", with: "\(z)")) else {
                self.lock.lock()
                self.inflight -= 1
                self.pending.remove(key)
                self.lock.unlock()
                return
            }
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            req.cachePolicy = .returnCacheDataElseLoad

            URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                guard let self else { return }
                // v2.14 解码放后台：UIImage(data:) 是 CPU 密集操作（PNG 解压 + 位图生成），
                // 旧实现在主线程的锁内做，一屏几十张同时返回就是几百毫秒的主线程占用。
                let img = data.flatMap { UIImage(data: $0) }

                self.ioQueue.async {
                    self.lock.lock()
                    self.inflight -= 1
                    if let img = img {
                        self.cache[key] = img
                        self.pending.remove(key)
                        self.loadedTiles += 1
                        self.trimMemoryCacheLocked()
                    } else {
                        self.pending.remove(key)
                        self.failedCooling.insert(key)
                    }
                    self.lock.unlock()

                    guard let img = img else {
                        // v2.14 失败退避：网络不通时旧实现会在下一帧立刻重试，
                        // 屏幕上百张瓦片 → 每秒几百个失败请求，CPU 与电量全耗在这上面。
                        // 记下来 30 秒内不再请求同一张（地图重绘不会再触发重试风暴）。
                        //
                        // v2.27（优化建议 #13）改成**指数退避**：5s → 10s → 30s → 60s 封顶。
                        // 旧版固定 30 秒的问题：弱网下用户干等 30 秒才能看到地图恢复，
                        // 而网络抖动往往几秒就恢复了 —— 白白让用户盯着空白地图。
                        // 指数退避让"偶尔抖一下"快速恢复，"持续断网"又不会变成请求风暴。
                        let delay = Self.backoffDelay(for: key)
                        self.ioQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                            guard let self else { return }
                            self.lock.lock()
                            self.failedCooling.remove(key)
                            self.lock.unlock()
                        }
                        return
                    }
                    self.markNeedsRedraw(rect)
                    // 瓦片落盘（同一队列，不阻塞渲染；离线/无网时命中磁盘直接显示）
                    // v2.27（建议 #14）按 style 分目录写入
                    let styleDir = key.hasPrefix("n-") ? 8 : 7
                    let durl = Self.diskDirFor(style: styleDir).appendingPathComponent("\(key).png")
                    if let data = data, !FileManager.default.fileExists(atPath: durl.path) {
                        try? data.write(to: durl)
                    }
                    Self.trimDiskIfNeeded()
                }
            }.resume()
        }
    }

    /// 内存缓存淘汰（调用方必须已持锁）
    private func trimMemoryCacheLocked() {
        // 缓存上限 1000：3D 俯视覆盖瓦片是 2D 的 3~5 倍，太小会反复加载/淘汰
        guard cache.count > 1000 else { return }
        // 先拷一份 key 再删，不能边遍历边改字典
        let drop = Array(cache.keys.prefix(300))
        for k in drop { cache.removeValue(forKey: k) }
    }

    /// v1.92 磁盘瓦片超量清理：超过上限时删除最旧的，避免缓存无限膨胀
    /// 节流：每落盘 50 张才真正扫描一次目录（App 进后台时也会补清一次）
    private static var tileWritesSinceTrim = 0
    /// v2.14 计数锁：这个 static 变量会被多个 renderer 的 ioQueue 并发改写
    private static let trimCountLock = NSLock()
    /// 清理专用串行队列（与落盘队列分离，主线程进后台时也能安全触发）
    private static let trimQueue = DispatchQueue(label: "amap.tile.trim")
    private static func trimDiskIfNeeded() {
        trimCountLock.lock()
        tileWritesSinceTrim += 1
        let hit = tileWritesSinceTrim >= 50
        if hit { tileWritesSinceTrim = 0 }
        trimCountLock.unlock()
        guard hit else { return }
        trimDiskNow()
    }
    /// 立即清理一次（App 进后台时调用；内部派发到串行队列，不与瓦片落盘争抢 IO）
    static func trimDiskNow() {
        trimQueue.async {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(
                at: diskDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: []) else { return }
            guard files.count > diskMaxFiles else { return }
            let sorted = files.sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                return da < db
            }
            for f in sorted.prefix(files.count - diskMaxFiles + 200) {
                try? fm.removeItem(at: f)
            }
        }
    }
}


// MARK: - v2.04 官方电警点位标注

/// 合肥交警公示的电警/卡口点位标注。
/// 注意坐标空间：MapKit 国内按 GCJ-02 解释 addAnnotation，内部存 WGS，
/// 所以这里统一走 MapGeo.toGCJ，和路线折线用同一层转换，不会出现"路线对齐了、点位偏了"。
final class CameraAnnotation: NSObject, MKAnnotation {
    let cameraId: Int
    let kind: CameraKind
    let cameraName: String
    let dirs: String
    /// v2.26 保留原始 PoliceCamera，点击电警点时要把完整点位信息交给上层（分享/删除要用）
    let camera: PoliceCamera?
    /// v2.27（建议 #29）是否"待校准"（网络同步 / 估算位置）—— 决定标注用不用缩小样式
    let isPending: Bool
    /// 是否处于"刚播报"高亮态
    var isHot = false

    @objc dynamic var coordinate: CLLocationCoordinate2D
    /// v2.20 拖动前的坐标（取消拖动时回滚）
    private var originCoordinate: CLLocationCoordinate2D
    /// v2.20 拖动前的 WGS 坐标（判断是否真的移动过）；Coordinator 里要用，故 fileprivate
    fileprivate var originWGS: CLLocationCoordinate2D

    init(camera: PoliceCamera, hot: Int) {
        self.cameraId = camera.id
        self.kind = camera.type
        self.cameraName = camera.name
        self.dirs = camera.dirs
        self.camera = camera
        // v2.27（建议 #29）网络同步 / 估算位置的点位标为"待校准"
        self.isPending = camera.isFromWeb || camera.accuracyGrade.isEstimated
        let gcj = MapGeo.toGCJ(camera.coordinate)
        self.coordinate = gcj
        self.originCoordinate = gcj
        self.originWGS = camera.coordinate
        self.isHot = (hot == camera.id && hot != 0)
        super.init()
    }

    /// v2.20 更新坐标（MapKit 拖拽或人工校准后调用）
    /// coordinate 是 @objc dynamic 属性，赋值自带 KVO 通知，MapKit 会自动移动大头针
    func setCoordinate(_ gcj: CLLocationCoordinate2D) {
        coordinate = gcj
    }

    /// v2.20 拖动开始：记录原坐标（用于取消回滚 / 判断是否真的移动过）
    func beginDrag() {
        originCoordinate = coordinate
        originWGS = MapGeo.toWGS(coordinate)
    }

    /// v2.20 拖动取消：回到原坐标
    func cancelDrag() { setCoordinate(originCoordinate) }

    var title: String? { "\(kind.title) · \(cameraName)" }
    var subtitle: String? { dirs.isEmpty ? "" : "抓拍方向：\(dirs)" }
}

/// 轻量点位视图：圆形色块 + 相机图标。不用 MKMarkerAnnotationView 是因为
/// 几十个 marker 一起改尺寸会触发地图重新布局，v2.02 的"雪花点"就是这么来的。
final class CameraPinView: MKAnnotationView {
    private let badge = UIView()
    private let icon = UIImageView()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        canShowCallout = true
        collisionMode = .rectangle
        displayPriority = .defaultHigh
        setUp()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setUp() {
        badge.layer.cornerRadius = 14
        badge.layer.borderWidth = 2
        badge.layer.borderColor = UIColor.white.cgColor
        badge.layer.shadowColor = UIColor.black.cgColor
        badge.layer.shadowOpacity = 0.28
        badge.layer.shadowRadius = 3
        badge.layer.shadowOffset = CGSize(width: 0, height: 1.5)
        badge.isUserInteractionEnabled = false
        addSubview(badge)

        icon.contentMode = .scaleAspectFit
        icon.tintColor = .white
        icon.isUserInteractionEnabled = false
        addSubview(icon)
    }

    private var configuredKind: CameraKind?
    /// v2.27（优化建议 #29）当前是否"待校准"（网络同步的点位）
    private var configuredPending = false

    /// 配置标注样式
    /// - Parameters:
    ///   - kind: 点位类型（决定图标与主色）
    ///   - pending: 是否为"待校准"（网络同步来的点位）—— 用虚线边框区分，
    ///     提示用户这个位置是估算的、可以长按拖动修正
    func configure(kind: CameraKind, pending: Bool = false) {
        // 复用时会反复调 viewFor，样式没变就不要重设 frame（每次重设会让地图重新布局）
        guard configuredKind != kind || configuredPending != pending else { return }
        configuredKind = kind
        configuredPending = pending
        badge.backgroundColor = kind.color
        icon.image = UIImage(systemName: kind.icon,
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold))
        frame = CGRect(x: 0, y: 0, width: 30, height: 30)
        badge.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
        badge.center = CGPoint(x: 15, y: 15)
        icon.frame = CGRect(x: 0, y: 0, width: 16, height: 16)
        icon.center = CGPoint(x: 15, y: 15)
        centerOffset = .zero
        applyPendingStyle()
    }

    /// v2.27（建议 #29）待校准样式：虚线边框 + 略小一号
    ///
    /// 网络同步来的点位坐标来自地名解析，可能偏差几百米。
    /// 用虚线边框把它和官方精确点位区分开，用户一眼能看出"这个点该自己校一下"。
    private func applyPendingStyle() {
        if configuredPending {
            badge.layer.borderWidth = 2
            badge.layer.borderColor = UIColor.white.cgColor
            // v2.27：CALayer 没有 borderDashPattern（那是 CAShapeLayer 才有的属性），
            // 所以"待校准"用缩小一号 + 降低不透明度来表达区别，
            // 而不是虚线边框（想用虚线得换成 CAShapeLayer，成本更高、收益不大）。
            badge.alpha = 0.75
            badge.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
            badge.center = CGPoint(x: 15, y: 15)
        } else {
            badge.layer.borderWidth = 2
            badge.layer.borderColor = UIColor.white.cgColor
            badge.alpha = 1
            badge.transform = .identity
            badge.center = CGPoint(x: 15, y: 15)
        }
    }

    /// 播报时放大并加白圈，播完缩回，避免地图上"一堆点分不清哪个在提醒"
    func setHot(_ hot: Bool) {
        let s: CGFloat = hot ? 1.45 : 1.0
        UIView.animate(withDuration: 0.22, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.badge.transform = CGAffineTransform(scaleX: s, y: s)
            self.badge.layer.borderWidth = hot ? 3 : 2
        }
    }
}
