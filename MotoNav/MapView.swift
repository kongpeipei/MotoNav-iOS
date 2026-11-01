import SwiftUI
import MapKit
import UIKit

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
    /// v1.69 地图加载回调（ok=true 渲染完成 / ok=false 失败原因）
    var onMapLoad: ((Bool, String) -> Void)?

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
        let amapOverlay = AmapTileOverlay()
        map.insertOverlay(amapOverlay, at: 0, level: .aboveRoads)
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
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onLongPress = onLongPress
        context.coordinator.onPoiLongPress = onPoiLongPress
        context.coordinator.onPoiMoved = onPoiMoved
        context.coordinator.onPoiSelect = onPoiSelect
        context.coordinator.onPlaceSelect = onPlaceSelect
        context.coordinator.onPlaceLongPress = onPlaceLongPress
        context.coordinator.onCategorySelect = onCategorySelect
        context.coordinator.onMapTap = onMapTap
        context.coordinator.onRouteChoiceTap = onRouteChoiceTap
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
                    MKCoordinateRegion(center: loc, latitudinalMeters: 3000, longitudinalMeters: 3000),
                    animated: false)
            }
        }
        // 路线全览（仅在新规划完成时触发一次，避免定位更新反复拉回；包含全部方案路线）
        if fitTick != context.coordinator.lastFitTick {
            context.coordinator.lastFitTick = fitTick
            if let tf = tipFit {
                // v1.81.1 地点信息卡：地图定位到该点（不画黄圈，卡片沉底展示）
                context.coordinator.setRegionProgrammatically {
                    map.setRegion(MKCoordinateRegion(center: tf, latitudinalMeters: 3000, longitudinalMeters: 3000), animated: true)
                }
            } else if route.count > 1 {
                var rect = MKMapRect.null
                var pts = route
                for r in choiceRoutes { pts.append(contentsOf: r) }
                for c in pts {
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
                for c in pts {
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
                        MKCoordinateRegion(center: p, latitudinalMeters: 3000, longitudinalMeters: 3000),
                        animated: true)
                }
            }
        }
        if let p = preview {
            if previews.isEmpty {
                map.addAnnotation(PreviewAnnotation(coordinate: p))
            } else if let a = previews.first {
                a.coordinate = p
            }
        } else {
            previews.forEach { map.removeAnnotation($0) }
        }
        // 加油站标注
        let gasIds = Set(map.annotations.compactMap { ($0 as? GasAnnotation)?.id })
        let wantGas = Set(gasStations.map { "\($0.latitude),\($0.longitude)" })
        map.annotations
            .compactMap { $0 as? GasAnnotation }
            .filter { !wantGas.contains("\($0.coordinate.latitude),\($0.coordinate.longitude)") }
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
        map.removeOverlays(map.overlays)
        context.coordinator.underPolyline = nil
        context.coordinator.mainPolyline = nil
        context.coordinator.alternatePolylines = []
        // v1.81 地点区域多边形（AOI 蓝色虚线框；随 tipPolygon 变化重建，每次重画路线后补加）
        let polyKey = tipPolygon.map { pts in
            pts.map { "\($0.latitude),\($0.longitude)" }.joined(separator: ":")
        } ?? ""
        if polyKey != context.coordinator.lastTipPolygonKey {
            context.coordinator.lastTipPolygonKey = polyKey
            if let pts = tipPolygon, pts.count >= 3 {
                context.coordinator.tipPolygonOverlay = MKPolygon(coordinates: pts, count: pts.count)
            } else {
                context.coordinator.tipPolygonOverlay = nil
            }
        }
        if let pg = context.coordinator.tipPolygonOverlay {
            map.addOverlay(pg)
        }
        if route.count > 1 {
            if navigating {
                // 导航中只画当前路线（草绿双层，高德导航推荐色）
                let under = MKPolyline(coordinates: route, count: route.count)
                context.coordinator.underPolyline = under
                let main = MKPolyline(coordinates: route, count: route.count)
                context.coordinator.mainPolyline = main
                map.addOverlay(under)
                map.addOverlay(main)
            } else {
                // 规划态：备选方案浅绿虚线 + 当前方案草绿双层（高德式同屏多路线）
                for (idx, pts) in choiceRoutes.enumerated() where idx != selectedRouteIdx && pts.count > 1 {
                    let alt = MKPolyline(coordinates: pts, count: pts.count)
                    context.coordinator.alternatePolylines.append(alt)
                    map.addOverlay(alt)
                }
                let under = MKPolyline(coordinates: route, count: route.count)
                context.coordinator.underPolyline = under
                let main = MKPolyline(coordinates: route, count: route.count)
                context.coordinator.mainPolyline = main
                map.addOverlay(under)
                map.addOverlay(main)
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
                    // v1.81.4 开始导航时地图缩放到合适程度（高德导航视野：相机约 750m 高）
                    var cam = map.camera
                    cam.altitude = 750
                    cam.pitch = 55
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
                for c in route {
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
                    cam.centerCoordinate = loc
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
                        cam.centerCoordinate = loc
                        map.camera = cam
                    }
                }
            }
        }
        // 导航 3D 俯视视角（高德导航默认倾斜），非导航恢复平视；仅在状态切换时设置，不干扰双指俯仰
        let isNav = navigating
        if isNav != context.coordinator.lastPitchState {
            context.coordinator.lastPitchState = isNav
            map.camera.pitch = isNav ? 55 : 0
        }
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
        /// v1.98 备选路线点击切换
        var onRouteChoiceTap: ((Int) -> Void)?
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
        /// 导航 3D 俯仰状态记忆（仅状态切换时设置 pitch）
        var lastPitchState: Bool?
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
                        let coord = map.convert(pt, toCoordinateFrom: map)
                        onLongPress?(coord)
                    }
                }
            case .changed:
                if let ann = dragAnnotation {
                    let newCoord = map.convert(pt, toCoordinateFrom: map)
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
            let coord = map.convert(pt, toCoordinateFrom: map)
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
        static func pointDistance(_ pts: [CLLocationCoordinate2D], to p: CGPoint, in map: MKMapView) -> CGFloat {
            guard pts.count > 1 else { return .greatestFiniteMagnitude }
            var best = CGFloat.greatestFiniteMagnitude
            var prev = map.convert(pts[0], toPointTo: map)
            var i = 1
            while i < pts.count {
                let cur = map.convert(pts[i], toPointTo: map)
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
                if poly === self.underPolyline {
                    // v1.66 高德式绿色并行线：深绿外框（路线更贴路、双线视觉）
                    r.strokeColor = UIColor(red: 0.10, green: 0.55, blue: 0.22, alpha: 1.0)
                    r.lineWidth = 9
                } else if poly === self.mainPolyline {
                    // 推荐路线：浅绿内芯（高德绿路线双线效果）
                    r.strokeColor = UIColor(red: 0.42, green: 0.84, blue: 0.46, alpha: 1.0)
                    r.lineWidth = 5
                } else if self.alternatePolylines.contains(where: { $0 === poly }) {
                    // 备选路线：浅绿色虚线
                    r.strokeColor = UIColor(red: 0.60, green: 0.85, blue: 0.62, alpha: 0.95)
                    r.lineWidth = 4
                    r.lineDashPattern = [6, 6]
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

/// 路线起点/终点标记
final class RouteEndAnnotation: NSObject, MKAnnotation {
    let kind: String
    let coordinate: CLLocationCoordinate2D
    init(kind: String, coordinate: CLLocationCoordinate2D) {
        self.kind = kind
        self.coordinate = coordinate
        super.init()
    }
    var title: String? { kind == "start" ? "起点" : "终点" }
}

final class PoiAnnotation: NSObject, MKAnnotation {
    var poi: Poi
    var onRoute: Bool
    /// 拖动校准中的临时坐标（nil = 使用点位原始坐标）
    var dragCoordinate: CLLocationCoordinate2D?
    init(poi: Poi, onRoute: Bool = false) {
        self.poi = poi
        self.onRoute = onRoute
        super.init()
    }
    var coordinate: CLLocationCoordinate2D { dragCoordinate ?? poi.coordinate }
    var title: String? { poi.name }
    var subtitle: String? { poi.type.label }
}

/// 搜索预览点（绿色高亮）
final class PreviewAnnotation: NSObject, MKAnnotation {
    var coordinate: CLLocationCoordinate2D
    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        super.init()
    }
    var title: String? { "搜索目标" }
}

/// 加油站标注（橙色"油"）
final class GasAnnotation: NSObject, MKAnnotation {
    let id: String
    var coordinate: CLLocationCoordinate2D
    init(id: String, coordinate: CLLocationCoordinate2D) {
        self.id = id
        self.coordinate = coordinate
        super.init()
    }
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
        CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon)
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
        CLLocationCoordinate2D(latitude: result.lat, longitude: result.lon)
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
    /// v1.98 屏幕瓦片 → 高德瓦片索引与像素偏移缓存（每块瓦片恒定，避免每帧重算三角函数）
    private var offsetCache: [String: (gx: Int, gy: Int, dx: Double, dy: Double)] = [:]
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
    private let ioQueue = DispatchQueue(label: "amap.tile.io")
    private static let diskMaxFiles = 1200

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in ctx: CGContext) {
        let z = min(AmapTileRenderer.zMax, max(AmapTileRenderer.zMin, Int((20.0 - log2(zoomScale)).rounded())))
        let n = 1 << z
        let per = MKMapRect.world.size.width / Double(n)
        let x0 = max(0, Int(floor(mapRect.minX / per)))
        let x1 = min(n - 1, Int(floor(mapRect.maxX / per)))
        let y0 = max(0, Int(floor(mapRect.minY / per)))
        let y1 = min(n - 1, Int(floor(mapRect.maxY / per)))
        guard x1 >= x0, y1 >= y0 else { return }
        // v1.98 瓦片重投影修正：
        // 屏幕按 WGS-84 网格切瓦片，高德瓦片内容却是 GCJ-02，两者相差约 500 米。
        // 旧版只把"取瓦片的索引"做了偏移，却把图像对齐到原矩形，没算"瓦片内偏移"，
        // 结果底图整体错位（最多一个瓦片宽），叠加的路线/标注因此永远压不到路上。
        // 这里按每块瓦片中心的 GCJ 坐标算出它在 GCJ 瓦片内的像素偏移量，反向平移绘制。
        for x in x0...x1 {
            let lonC = (Double(x) + 0.5) / Double(n) * 360.0 - 180.0
            for y in y0...y1 {
                let off = tileOffset(x: x, y: y, z: z, lonC: lonC)
                let gx = off.gx, gy = off.gy
                let key = "\(dark ? "n" : "d")-\(z)-\(gx)-\(gy)" // 深浅样式分开缓存，切换即时生效
                let rect = self.rect(for: MKMapRect(
                    x: Double(x) * per - off.dx,
                    y: Double(y) * per - off.dy,
                    width: per, height: per))
                lock.lock()
                let hit = cache[key]
                let needFetch = hit == nil && !pending.contains(key)
                if needFetch { pending.insert(key) }
                lock.unlock()
                if let hit, let cg = hit.cgImage {
                    ctx.draw(cg, in: rect)
                } else if needFetch {
                    fetchTile(gx, gy, z, key)
                }
            }
        }
    }

    /// 单块屏幕瓦片 → 对应的高德 GCJ 瓦片索引 + 瓦片内像素偏移（世界坐标单位）
    private func tileOffset(x: Int, y: Int, z: Int, lonC: Double) -> (gx: Int, gy: Int, dx: Double, dy: Double) {
        let key = "\(z)-\(x)-\(y)"
        lock.lock()
        if let c = offsetCache[key] { lock.unlock(); return c }
        lock.unlock()
        let n = Double(1 << z)
        let latC = tileLat(y, z)
        let (gLat, gLon) = CoordConv.wgs2gcj(latC, lonC)
        let gx = min(Int(n) - 1, max(0, Int(floor((gLon + 180.0) / 360.0 * n))))
        let gy = min(Int(n) - 1, max(0, tileY(gLat, z)))
        let wx = (gLon + 180.0) / 360.0 * MKMapRect.world.size.width
        let wy = worldY(gLat) * MKMapRect.world.size.height
        let res = (gx, gy, wx - Double(gx) * MKMapRect.world.size.width / n,
                   wy - Double(gy) * MKMapRect.world.size.height / n)
        lock.lock()
        if offsetCache.count > 4000 { offsetCache.removeAll(keepingCapacity: true) }
        offsetCache[key] = res
        lock.unlock()
        return res
    }

    /// 纬度 → 墨卡托归一化 y（0 顶部）
    private func worldY(_ lat: Double) -> Double {
        let r = lat / 180.0 * .pi
        return (1.0 - log(tan(r) + 1.0 / cos(r)) / .pi) / 2.0
    }

    private func fetchTile(_ x: Int, _ y: Int, _ z: Int, _ key: String) {
        // v1.90 磁盘缓存命中直接使用（离线可用）：读盘 → 入内存缓存 → 触发重绘，不再发网络请求
        let diskURL = Self.diskDir.appendingPathComponent("\(key).png")
        if FileManager.default.fileExists(atPath: diskURL.path) {
            lock.lock()
            if cache[key] == nil, let img = UIImage(contentsOfFile: diskURL.path) {
                cache[key] = img
                pending.remove(key)
                lock.unlock()
                setNeedsDisplay()
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
                    if self.cache.count > 200 {
                        var drop = 50
                        while drop > 0, let k = self.cache.keys.first {
                            self.cache.removeValue(forKey: k)
                            drop -= 1
                        }
                    }
                    self.setNeedsDisplay()
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

    /// 瓦片 y → 中心纬度（Web Mercator）
    private func tileLat(_ y: Int, _ z: Int) -> Double {
        let n = Double(1 << z)
        return atan(sinh(.pi * (1 - 2.0 * (Double(y) + 0.5) / n))) * 180.0 / .pi
    }
    /// 纬度 → 瓦片 y
    private func tileY(_ lat: Double, _ z: Int) -> Int {
        let n = Double(1 << z)
        let r = lat / 180.0 * .pi
        return Int(floor((1.0 - log(tan(r) + 1.0 / cos(r)) / .pi) / 2.0 * n))
    }
}

