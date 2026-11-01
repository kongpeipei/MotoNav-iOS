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

    func makeUIView(context: Context) -> MKMapView {
        StartupLog.markSync("map-make")
        let map = MKMapView()
        StartupLog.markSync("map-init-done")
        map.showsUserLocation = true
        map.showsCompass = false // 使用自绘指南针（左上角）
        map.isPitchEnabled = true   // 双指俯仰调节 3D 角度
        map.isRotateEnabled = true  // 双指旋转地图
        map.delegate = context.coordinator
        // v1.67 高德瓦片底图（纯高德视觉）：插入 .aboveRoads 最底层——
        // 路线折线/点位标注都叠在瓦片之上（v1.62 灰罩+盖路线问题已修复：
        // ①层级由 aboveLabels 改 aboveRoads ②未加载瓦片透明露出苹果底图兜底 ③多子域轮询防限流)
        // v1.78：黑屏回归苹果 MapKit 引擎（3D Metal 渲染与设备不兼容），高德瓦片视觉保留
        StartupLog.markSync("tile-overlay-before")
        let amapOverlay = AmapTileOverlay()
        StartupLog.markSync("tile-overlay-inited")
        map.insertOverlay(amapOverlay, at: 0, level: .aboveRoads)
        StartupLog.markSync("tile-overlay-added")
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
        StartupLog.markSync("map-make-done")
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
        StartupLog.markOnce("map-update")
        context.coordinator.onLongPress = onLongPress
        context.coordinator.onPoiLongPress = onPoiLongPress
        context.coordinator.onPoiMoved = onPoiMoved
        context.coordinator.onPoiSelect = onPoiSelect
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
                    map.insertOverlay(AmapTileOverlay(), at: 0, level: .aboveRoads)
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
        // 点位标注增删
        let ids = Set(pois.map(\.id))
        map.annotations
            .compactMap { $0 as? PoiAnnotation }
            .filter { !ids.contains($0.poi.id) }
            .forEach { map.removeAnnotation($0) }
        for p in pois {
            if !map.annotations.contains(where: { ($0 as? PoiAnnotation)?.poi.id == p.id }) {
                map.addAnnotation(PoiAnnotation(poi: p, onRoute: routePois.contains { $0.id == p.id }))
            } else if let a = map.annotations.first(where: { ($0 as? PoiAnnotation)?.poi.id == p.id }) as? PoiAnnotation {
                if a.poi.coordinate != p.coordinate || a.poi.isCustom != p.isCustom {
                    // 坐标/自定义标记变化（拖动或编辑后）：移除重建以刷新 marker 视图（新位置 + 橙色描边）
                    map.removeAnnotation(a)
                    map.addAnnotation(PoiAnnotation(poi: p, onRoute: routePois.contains { $0.id == p.id }))
                } else {
                    a.poi = p
                    a.onRoute = routePois.contains { $0.id == p.id }
                }
            }
        }
        // v2.04 官方电警点位图层（按 id 增量同步，避免每次重建几十个 annotation）
        let camIds = Set(cameraMarks.map(\.id))
        map.annotations
            .compactMap { $0 as? CameraAnnotation }
            .filter { !camIds.contains($0.cameraId) }
            .forEach { map.removeAnnotation($0) }
        let existingCam = Set(map.annotations.compactMap { ($0 as? CameraAnnotation)?.cameraId })
        for c in cameraMarks where !existingCam.contains(c.id) {
            map.addAnnotation(CameraAnnotation(camera: c, hot: 0))
        }
        // 刚播报的点位：外圈加粗 + 放大，让"听到的"和"看到的"是同一个点
        for a in map.annotations.compactMap({ $0 as? CameraAnnotation }) {
            let want = (a.cameraId == hotCameraId && hotCameraId != 0)
            if a.isHot != want {
                a.isHot = want
                (map.view(for: a) as? CameraPinView)?.setHot(want)
            }
        }
        // 终点标记（高德式：起点=当前定位蓝箭头，不再画"起"标记；终点保留"终"）
        map.annotations
            .compactMap { $0 as? RouteEndAnnotation }
            .filter { $0.kind == "start" }
            .forEach { map.removeAnnotation($0) }
        let ends = Set(map.annotations.compactMap { ($0 as? RouteEndAnnotation)?.kind })
        let endPresent = ends.contains("end")
        if let last = route.last, !endPresent {
            map.addAnnotation(RouteEndAnnotation(kind: "end", coordinate: last))
        }
        if route.count < 2 {
            map.annotations
                .compactMap { $0 as? RouteEndAnnotation }
                .forEach { map.removeAnnotation($0) }
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
        // 加油站标注
        let gasIds = Set(map.annotations.compactMap { ($0 as? GasAnnotation)?.id })
        let wantGas = Set(gasStations.map { "\($0.latitude),\($0.longitude)" })
        map.annotations
            .compactMap { $0 as? GasAnnotation }
            .filter { !wantGas.contains($0.wgsKey) }
            .forEach { map.removeAnnotation($0) }
        for c in gasStations {
            let key = "\(c.latitude),\(c.longitude)"
            if !gasIds.contains(key) {
                map.addAnnotation(GasAnnotation(id: key, coordinate: c))
            }
        }
        // 小区/商铺名称标签
        let wantPlaces = Set(placeLabels.map(\.id))
        map.annotations
            .compactMap { $0 as? PlaceAnnotation }
            .filter { !wantPlaces.contains($0.place.id) }
            .forEach { map.removeAnnotation($0) }
        if !minimal {
            for pl in placeLabels where !map.annotations.contains(where: { ($0 as? PlaceAnnotation)?.place.id == pl.id }) {
                map.addAnnotation(PlaceAnnotation(place: pl))
            }
        }
        // 类别搜索结果（学校/医院/加油站）
        let wantCats = Set(categoryResults.map(\.id))
        map.annotations
            .compactMap { $0 as? CategoryAnnotation }
            .filter { !wantCats.contains($0.result.id) }
            .forEach { map.removeAnnotation($0) }
        if !minimal {
            for r in categoryResults where !map.annotations.contains(where: { ($0 as? CategoryAnnotation)?.result.id == r.id }) {
                map.addAnnotation(CategoryAnnotation(result: r))
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
                    // 导航中只画当前路线（草绿双层，高德导航推荐色）
                    let under = MKPolyline(coordinates: gRoute, count: gRoute.count)
                    context.coordinator.underPolyline = under
                    let main = MKPolyline(coordinates: gRoute, count: gRoute.count)
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
                    // v2.01 高德式导航视野：3D 45° 俯视，纵向约 200 米（≈三四栋楼）
                    var cam = map.camera
                    cam.pitch = CGFloat(pitchDeg > 0 ? pitchDeg : 45)
                    // centerCoordinateDistance 380m + 45° 俯角 ≈ 屏幕纵向 200 米
                    cam.centerCoordinateDistance = 380
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
        let isNav = navigating
        // v1.63 深色模式：导航中强制深色底图（高德夜间效果）；非导航跟随系统深浅
        if isNav != context.coordinator.lastDarkState {
            context.coordinator.lastDarkState = isNav
            map.overrideUserInterfaceStyle = isNav ? .dark : .unspecified
            // v1.67 高德瓦片随导航切换夜间样式（style=8 深色 / style=7 浅色）
            context.coordinator.amapDark = isNav
            context.coordinator.amapRenderer?.dark = isNav
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
        StartupLog.markOnce("map-update-done")
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var onLongPress: ((CLLocationCoordinate2D) -> Void)?
        var onPoiLongPress: ((Poi) -> Void)?
        var onPoiMoved: ((Poi, Double, Double) -> Void)?
        /// 长按拖动校准状态
        private var dragAnnotation: PoiAnnotation?
        private var dragStartPt: CGPoint = .zero
        private var dragStartCoord: CLLocationCoordinate2D?
        var onPoiSelect: ((Poi) -> Void)?
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
        /// v2.01 俯仰角记忆（pitchDeg 变化才应用，避免覆盖用户双指俯仰）
        var lastPitchDeg: Double = 0
        /// v2.01 比例尺上次文本（只在变化时回调，避免每帧刷新 SwiftUI）
        var lastScaleText = ""
        /// v2.02 折线重建键（内容不变就不重建，避免闪烁/卡顿）
        var lastRouteKey = ""
        /// v1.84 巡航模式状态记忆（巡航开关切换/跟随 tick/上次相机中心节流）
        var lastCruise: Bool?
        var lastCruiseTick = 0
        var cruiseLastLoc: CLLocationCoordinate2D?
        /// 导航深色底图状态记忆
        var lastDarkState: Bool?
        /// v1.67 高德瓦片 renderer 引用 + 深色（夜间瓦片 style=8）状态
        var amapRenderer: AmapTileRenderer?
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
            onMapLoad?(true, "地图渲染完成")
            if lastScaleText.isEmpty { scheduleScale(mapView, delay: 0.1) }  // v2.02 首屏补一次
        }

        func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: Error) {
            onMapLoad?(false, error.localizedDescription)
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
                let id = "routeEnd"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: re, reuseIdentifier: id)
                v.markerTintColor = re.kind == "start" ? .systemGreen : .systemRed
                v.glyphText = re.kind == "start" ? "起" : "终"
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
                v.configure(kind: cam.kind)
                v.setHot(cam.isHot)
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
final class RouteEndAnnotation: NSObject, MKAnnotation {
    let kind: String
    private let wgs: CLLocationCoordinate2D
    var coordinate: CLLocationCoordinate2D { MapGeo.toGCJ(wgs) }
    init(kind: String, coordinate: CLLocationCoordinate2D) {
        self.kind = kind
        self.wgs = coordinate
        super.init()
    }
    var title: String? { kind == "start" ? "起点" : "终点" }
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
    private var inflight = 0
    /// 夜间瓦片（导航中 style=8）
    var dark = false
    /// v1.90 瓦片磁盘缓存目录（Caches/Tiles）：常用区域瓦片自动落盘，离线可用、省流量
    private static let diskDir: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    /// v1.99 离线包目录（OfflineMapManager 下载到这里）
    private static let offlineDir: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tiles/offline", isDirectory: true)
        return u
    }()
    private let ioQueue = DispatchQueue(label: "amap.tile.io")
    private static let diskMaxFiles = 1200

    /// v2.00 瓦片直铺（关键修复）
    ///
    /// 高德瓦片本身就是 GCJ-02 网格，而 MKMapView 的 overlay 坐标 / 标注坐标在本 App 里
    /// 已统一转成 GCJ（见 MapGeo），所以瓦片必须**按原索引原样铺回同一张 GCJ 网格**。
    ///
    /// v1.98 曾经反过来：把 GCJ 瓦片平移半个瓦片去"对齐"WGS 网格，不仅漏了半瓦片偏移，
    /// 还与已转 GCJ 的折线形成了双重错位——这正是"路线永远压不到路上"的直接原因。
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in ctx: CGContext) {
        let z = min(AmapTileRenderer.zMax, max(AmapTileRenderer.zMin, Int((20.0 - log2(zoomScale)).rounded())))
        let n = 1 << z
        let per = MKMapRect.world.size.width / Double(n)
        let x0 = max(0, Int(floor(mapRect.minX / per)))
        let x1 = min(n - 1, Int(floor(mapRect.maxX / per)))
        let y0 = max(0, Int(floor(mapRect.minY / per)))
        let y1 = min(n - 1, Int(floor(mapRect.maxY / per)))
        guard x1 >= x0, y1 >= y0 else { return }
        for x in x0...x1 {
            for y in y0...y1 {
                let key = "\(dark ? "n" : "d")-\(z)-\(x)-\(y)" // 深浅样式分开缓存，切换即时生效
                let rect = self.rect(for: MKMapRect(
                    x: Double(x) * per, y: Double(y) * per,
                    width: per, height: per))
                lock.lock()
                let hit = cache[key]
                let needFetch = hit == nil && !pending.contains(key)
                if needFetch { pending.insert(key) }
                lock.unlock()
                if let hit, let cg = hit.cgImage {
                    ctx.draw(cg, in: rect)
                } else if needFetch {
                    // 先请求靠近屏幕中心的瓦片：旧实现按行列顺序，中心往往最后才到，
                    // 3D 俯视时表现为中间一片空白（"雪花点"）
                    let cx = Double(x0 + x1) / 2, cy = Double(y0 + y1) / 2
                    let d = (Double(x) - cx) * (Double(x) - cx) + (Double(y) - cy) * (Double(y) - cy)
                    if d < 25 { fetchTile(x, y, z, key) }
                    else { queueTile(x, y, z, key) }
                }
            }
        }
    }

    /// v2.02 重绘合并：一帧内最多触发一次 setNeedsDisplay（旧实现每张瓦片到达都全图重绘）
    private var redrawScheduled = false
    private func markNeedsRedraw() {
        guard !redrawScheduled else { return }
        redrawScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.redrawScheduled = false
            self.setNeedsDisplay()
        }
    }

    /// v2.02 边缘瓦片延迟加载队列（优先保证屏幕中心先出图）
    private var queuedTiles: Set<String> = []
    private func queueTile(_ x: Int, _ y: Int, _ z: Int, _ key: String) {
        // draw() 跑在 VectorKit 渲染线程，主线程也会插队 → queuedTiles 必须加锁，
        // 否则 Set 并发写入会 EXC_BAD_ACCESS（本文件历史上就踩过同类闪退）
        lock.lock()
        if queuedTiles.contains(key) { lock.unlock(); return }
        queuedTiles.insert(key)
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.queuedTiles.remove(key)
            let cached = self.cache[key] != nil
            self.lock.unlock()
            if !cached { self.fetchTile(x, y, z, key) }
        }
    }

    private func fetchTile(_ x: Int, _ y: Int, _ z: Int, _ key: String) {
        // v1.90 磁盘缓存命中直接使用（离线可用）：读盘 → 入内存缓存 → 触发重绘，不再发网络请求
        let diskURL = Self.diskDir.appendingPathComponent("\(key).png")
        // v1.99 离线地图包优先（手动下载的区域，无网也能出图）
        let offlineURL = Self.offlineDir.appendingPathComponent("\(key).png")
        for url in [offlineURL, diskURL] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            lock.lock()
            if cache[key] == nil, let img = UIImage(contentsOfFile: url.path) {
                cache[key] = img
                pending.remove(key)
                lock.unlock()
                markNeedsRedraw()
                return
            }
            lock.unlock()
        }
        lock.lock()
        if inflight >= 16 {
            pending.remove(key)
            lock.unlock()
            return
        }
        // v1.67 多子域轮询：webrd01-04 按瓦片坐标取模，降低单域限流概率
        let sd = ((x + y) % 4) + 1
        let style = dark ? "8" : "7"
        guard let url = URL(string: AmapTileOverlay.tileURL
            .replacingOccurrences(of: "{SD}", with: "\(sd)")
            .replacingOccurrences(of: "{STYLE}", with: style)
            .replacingOccurrences(of: "{x}", with: "\(x)")
            .replacingOccurrences(of: "{y}", with: "\(y)")
            .replacingOccurrences(of: "{z}", with: "\(z)")) else {
            pending.remove(key)
            lock.unlock()
            return
        }
        inflight += 1
        lock.unlock()
        URLSession.shared.dataTask(with: url) { [weak self] data, resp, err in
            guard let self else { return }
            DispatchQueue.main.async {
                self.lock.lock()
                self.inflight -= 1
                if let data, let img = UIImage(data: data) {
                    self.cache[key] = img
                    self.pending.remove(key)
                    // v1.90 瓦片落盘（后台队列，不阻塞渲染；离线/无网时命中磁盘直接显示）
                    let url = Self.diskDir.appendingPathComponent("\(key).png")
                    self.ioQueue.async {
                        if !FileManager.default.fileExists(atPath: url.path) {
                            try? data.write(to: url)
                        }
                        // v1.92 节流：原实现每张瓦片落盘都全量枚举目录+排序一次，
                        // 骑行滚动地图会连续下载数百张 → 数百次目录枚举。改为每 50 张清一次
                        Self.trimDiskIfNeeded()
                    }
                    // v2.02 缓存上限 200 → 1200：3D 45° 俯视时包围盒覆盖的瓦片数是 2D 的 3~5 倍，
                    // 200 张会被瞬间冲掉 → 同屏瓦片反复"加载-淘汰-再加载"，表现为雪花点与卡顿
                    if self.cache.count > 1200 {
                        var drop = 300
                        while drop > 0, let k = self.cache.keys.first {
                            self.cache.removeValue(forKey: k)
                            drop -= 1
                        }
                    }
                    self.markNeedsRedraw()
                } else if err != nil || (resp as? HTTPURLResponse)?.statusCode != 200 {
                    self.pending.remove(key) // 失败瓦片：移出待下载，滚动/重绘后自然重试
                }
                self.lock.unlock()
            }
        }.resume()
    }

    /// v1.92 磁盘瓦片超量清理：超过上限时删除最旧的，避免缓存无限膨胀
    /// 节流：每落盘 50 张才真正扫描一次目录（App 进后台时也会补清一次）
    private static var tileWritesSinceTrim = 0
    /// 清理专用串行队列（与落盘队列分离，主线程进后台时也能安全触发）
    private static let trimQueue = DispatchQueue(label: "amap.tile.trim")
    private static func trimDiskIfNeeded() {
        tileWritesSinceTrim += 1
        if tileWritesSinceTrim < 50 { return }
        tileWritesSinceTrim = 0
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
    /// 是否处于"刚播报"高亮态
    var isHot = false

    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(camera: PoliceCamera, hot: Int) {
        self.cameraId = camera.id
        self.kind = camera.type
        self.cameraName = camera.name
        self.dirs = camera.dirs
        self.coordinate = MapGeo.toGCJ(camera.coordinate)
        self.isHot = (hot == camera.id && hot != 0)
        super.init()
    }

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

    func configure(kind: CameraKind) {
        // 复用时会反复调 viewFor，样式没变就不要重设 frame（每次重设会让地图重新布局）
        guard configuredKind != kind else { return }
        configuredKind = kind
        badge.backgroundColor = kind.color
        icon.image = UIImage(systemName: kind.icon,
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold))
        frame = CGRect(x: 0, y: 0, width: 30, height: 30)
        badge.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
        badge.center = CGPoint(x: 15, y: 15)
        icon.frame = CGRect(x: 0, y: 0, width: 16, height: 16)
        icon.center = CGPoint(x: 15, y: 15)
        centerOffset = .zero
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
