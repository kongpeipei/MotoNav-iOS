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
    /// 地图缩放按钮计数
    let zoomInTick: Int
    let zoomOutTick: Int
    var onLongPress: ((CLLocationCoordinate2D) -> Void)?
    var onPoiLongPress: ((Poi) -> Void)?
    var onPoiMoved: ((Poi, Double, Double) -> Void)?
    var onPoiSelect: ((Poi) -> Void)?
    var onPlaceSelect: ((PlaceLabel) -> Void)?
    var onCategorySelect: ((AppModel.CategoryResult) -> Void)?
    /// 轻点地图空白处选点（显示"导航到这里"）
    var onMapTap: ((CLLocationCoordinate2D) -> Void)?
    /// v1.49 图层类型（标准/卫星）
    var mapType: MKMapType = .standard
    /// v1.49 实时路况线（高德红黄绿）
    var trafficRoads: [TrafficRoad] = []
    /// v1.49 历史轨迹（灰色虚线，回放）
    var tripTrackLine: [CLLocationCoordinate2D] = []
    /// v1.50 定位连接线（定位点→路线投影点，高德式步行导航线）
    var locLinkLine: [CLLocationCoordinate2D] = []
    /// v1.50 全程概览请求（开始导航时缩小到合适视野）
    var navOverviewTick: Int = 0
    /// v1.50 热门目的地 / 最近常搜索地点（橙色星标高亮）
    var hotPlaces: [PlaceLabel] = []
    var recentHot: [PlaceLabel] = []
    var hotTick: Int = 0
    var onHotPlaceSelect: ((PlaceLabel) -> Void)?
    /// v1.51 高德瓦片底图（A 选项：底图与高德路线同源，消除路网偏差）
    var useAmapTiles: Bool = false

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.showsUserLocation = true
        map.showsCompass = false // 使用自绘指南针（左上角）
        map.isPitchEnabled = true   // 双指俯仰调节 3D 角度
        map.isRotateEnabled = true  // 双指旋转地图
        map.delegate = context.coordinator
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.6
        map.addGestureRecognizer(longPress)
        // 轻点地图：空白处选点（命中点位/地点标注时不触发，交给 didSelect）
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleMapTap(_:)))
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onLongPress = onLongPress
        context.coordinator.onPoiLongPress = onPoiLongPress
        context.coordinator.onPoiMoved = onPoiMoved
        context.coordinator.onPoiSelect = onPoiSelect
        context.coordinator.onPlaceSelect = onPlaceSelect
        context.coordinator.onCategorySelect = onCategorySelect
        context.coordinator.onMapTap = onMapTap
        // v1.49 图层切换（标准/卫星）
        if map.mapType != mapType {
            map.mapType = mapType
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
        // v1.50 开始导航"全程概览"：缩小到覆盖整条路线（高德起步视野）
        if navOverviewTick != context.coordinator.lastNavOverviewTick {
            context.coordinator.lastNavOverviewTick = navOverviewTick
            if navOverviewTick > 0, route.count > 1 {
                context.coordinator.userMoved = false
                context.coordinator.setRegionProgrammatically {
                    var rect = MKMapRect.null
                    for c in route {
                        let p = MKMapPoint(c)
                        rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
                    }
                    map.setVisibleMapRect(rect,
                        edgePadding: UIEdgeInsets(top: 90, left: 50, bottom: 90, right: 50),
                        animated: true)
                    // 概览 1.2 秒后自动回到近景跟随（高德：起步概览→驾驶跟随）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        map.userTrackingMode = .followWithHeading
                        map.camera.pitch = 55
                    }
                }
            }
        }
        // v1.50 定位连接线（定位点→路线投影点，高德式步行导航线；导航中随定位实时更新）
        var needLink = false
        if navigating, locLinkLine.count == 2 {
            let a = MKMapPoint(locLinkLine[0]), b = MKMapPoint(locLinkLine[1])
            let r = MKPolyline(points: [a, b], count: 2)
            if let old = context.coordinator.locLinkPolyline {
                map.removeOverlay(old)
            }
            context.coordinator.locLinkPolyline = r
            map.addOverlay(r)
            needLink = true
        }
        if !needLink, let old = context.coordinator.locLinkPolyline {
            map.removeOverlay(old)
            context.coordinator.locLinkPolyline = nil
        }
        // v1.50 热门/最近搜索地点：橙色星标高亮（hotTick 变化时重建）
        if hotTick != context.coordinator.lastHotTick {
            context.coordinator.lastHotTick = hotTick
            let olds = map.annotations.filter { $0 is HotAnnotation }
            map.removeAnnotations(olds)
            var marks = Set<String>()
            let all = hotPlaces + recentHot
            for h in all where marks.insert(h.name).inserted {
                map.addAnnotation(HotAnnotation(name: h.name, lat: h.lat, lon: h.lon))
            }
        }
        // 路线全览（仅在新规划完成时触发一次，避免定位更新反复拉回；包含全部方案路线）
        if fitTick != context.coordinator.lastFitTick && route.count > 1 {
            context.coordinator.lastFitTick = fitTick
            context.coordinator.setRegionProgrammatically {
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
        for pl in placeLabels where !map.annotations.contains(where: { ($0 as? PlaceAnnotation)?.place.id == pl.id }) {
            map.addAnnotation(PlaceAnnotation(place: pl))
        }
        // 类别搜索结果（学校/医院/加油站）
        let wantCats = Set(categoryResults.map(\.id))
        map.annotations
            .compactMap { $0 as? CategoryAnnotation }
            .filter { !wantCats.contains($0.result.id) }
            .forEach { map.removeAnnotation($0) }
        for r in categoryResults where !map.annotations.contains(where: { ($0 as? CategoryAnnotation)?.result.id == r.id }) {
            map.addAnnotation(CategoryAnnotation(result: r))
        }
        map.removeOverlays(map.overlays)
        context.coordinator.underPolyline = nil
        context.coordinator.mainPolyline = nil
        context.coordinator.alternatePolylines = []
        // v1.51 高德瓦片底图（A 选项）：全删后重插（若开启），renderer 负责 GCJ→WGS 重投影
        if useAmapTiles {
            if let o = context.coordinator.amapTileOverlay {
                if !map.overlays.contains(where: { $0 === o }) {
                    map.insertOverlay(o, at: 0, level: .aboveLabels)
                }
            } else {
                let o = AmapTileOverlay()
                context.coordinator.amapTileOverlay = o
                map.insertOverlay(o, at: 0, level: .aboveLabels)
            }
        } else if let o = context.coordinator.amapTileOverlay {
            map.removeOverlay(o)
            context.coordinator.amapTileOverlay = nil
        }
        // v1.49 路况线（先画，路线在其上层）
        context.coordinator.trafficPolylines = []
        for r in trafficRoads where r.coords.count > 1 {
            let p = MKPolyline(coordinates: r.coords, count: r.coords.count)
            context.coordinator.trafficPolylines.append((p, r.status))
            map.addOverlay(p)
        }
        // v1.49 历史轨迹回放（灰色虚线，最底层）
        if tripTrackLine.count > 1 {
            let tp = MKPolyline(coordinates: tripTrackLine, count: tripTrackLine.count)
            context.coordinator.tripPolyline = tp
            map.addOverlay(tp)
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
                // v1.51 只画当前选中方案（高德式：卡片切换才换线），不再同屏叠加多条备选
                // （多策略线重叠交叉是"路线乱七八糟"观感的主因）
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
        // 导航跟随：导航开始/结束/到达时进入跟随（高德式：地图随车移动+自动旋转）
        if navigateFollowTick != context.coordinator.lastNavFollowTick {
            context.coordinator.lastNavFollowTick = navigateFollowTick
            context.coordinator.userMoved = false
            if let loc = userLocation {
                context.coordinator.navLastFollow = loc
            }
            context.coordinator.setRegionProgrammatically {
                map.userTrackingMode = .followWithHeading
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
        // 导航 3D 俯视视角（高德导航默认倾斜），非导航恢复平视；仅在状态切换时设置，不干扰双指俯仰
        let isNav = navigating
        if isNav != context.coordinator.lastPitchState {
            context.coordinator.lastPitchState = isNav
            map.camera.pitch = isNav ? 55 : 0
        }
        // 导航中强制深色底图（高德夜间导航效果：深色底图 + 蓝色箭头更醒目）；非导航恢复浅色
        if isNav != context.coordinator.lastDarkState {
            context.coordinator.lastDarkState = isNav
            map.overrideUserInterfaceStyle = isNav ? .dark : .light
        }
        // 缩放按钮（+/-）：以地图中心缩放 0.5x / 2x
        if zoomInTick != context.coordinator.lastZoomInTick {
            context.coordinator.lastZoomInTick = zoomInTick
            if zoomInTick > 0 {
                let reg = map.region
                context.coordinator.setRegionProgrammatically {
                    map.setRegion(MKCoordinateRegion(
                        center: reg.center,
                        span: MKCoordinateSpan(latitudeDelta: reg.span.latitudeDelta * 0.5,
                                               longitudeDelta: reg.span.longitudeDelta * 0.5)),
                        animated: true)
                }
            }
        }
        if zoomOutTick != context.coordinator.lastZoomOutTick {
            context.coordinator.lastZoomOutTick = zoomOutTick
            if zoomOutTick > 0 {
                let reg = map.region
                context.coordinator.setRegionProgrammatically {
                    map.setRegion(MKCoordinateRegion(
                        center: reg.center,
                        span: MKCoordinateSpan(latitudeDelta: reg.span.latitudeDelta * 2.0,
                                               longitudeDelta: reg.span.longitudeDelta * 2.0)),
                        animated: true)
                }
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
        var onCategorySelect: ((AppModel.CategoryResult) -> Void)?
        var onMapTap: ((CLLocationCoordinate2D) -> Void)?
        var onHotPlaceSelect: ((PlaceLabel) -> Void)?
        /// v1.50 定位连接线折线
        var locLinkPolyline: MKPolyline?
        /// v1.50 概览/热门重建记忆
        var lastNavOverviewTick = 0
        var lastHotTick = 0
        /// v1.51 高德瓦片 overlay
        var amapTileOverlay: AmapTileOverlay?
        /// 是否已做过首次定位居中
        var hasCentered = false
        /// 定位/全览/预览请求记忆（只响应新请求，避免定位更新反复重置地图）
        var lastLocateTick = 0
        var lastFitTick = 0
        var lastGasTick = 0
        var lastZoomInTick = 0
        var lastZoomOutTick = 0
        var lastPreviewKey = ""
        /// 导航 3D 俯仰状态记忆（仅状态切换时设置 pitch）
        var lastPitchState: Bool?
        /// 导航深色底图状态记忆
        var lastDarkState: Bool?
        /// 路线白色描边底层引用（renderer 区分双层）
        var underPolyline: MKPolyline?
        /// 当前方案主层（草绿色，renderer 区分）
        var mainPolyline: MKPolyline?
        /// 备选方案折线（浅绿色虚线，renderer 区分）
        var alternatePolylines: [MKPolyline] = []
        /// v1.49 路况折线（(polyline, status)）
        var trafficPolylines: [(MKPolyline, Int)] = []
        /// v1.49 历史轨迹折线（灰色虚线）
        var tripPolyline: MKPolyline?
        /// 用户手动移动/旋转地图（暂停跟随与自动旋转，点定位按钮恢复）
        var userMoved = false
        /// 导航跟随触发记忆
        var lastNavFollowTick = 0
        /// 导航中最后跟随位置（开远自动拉回）
        var navLastFollow: CLLocationCoordinate2D?
        /// 程序主动设置区域（避免被标记为用户移动）
        private var programmaticMove = false

        func setRegionProgrammatically(_ block: () -> Void) {
            programmaticMove = true
            block()
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
                    let coord = map.convert(pt, toCoordinateFrom: map)
                    onLongPress?(coord)
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
            for a in map.annotations {
                let ap = map.convert(a.coordinate, toPointTo: map)
                let d = hypot(pt.x - ap.x, pt.y - ap.y)
                // 命中任何标注（点位/地点/类别/起点终点/用户位置）→ 交给 didSelect
                if d < 40 && !(a is MKUserLocation) {
                    return
                }
            }
            let coord = map.convert(pt, toCoordinateFrom: map)
            onMapTap?(coord)
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
            } else if let ha = view.annotation as? HotAnnotation {
                // v1.50 热门/最近常搜索地点：点击直接规划路线
                mapView.deselectAnnotation(view.annotation, animated: false)
                let pl = PlaceLabel(name: ha.name, lat: ha.coordinate.latitude, lon: ha.coordinate.longitude)
                onHotPlaceSelect?(pl)
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
            // v1.50 热门/最近常搜索地点：橙色星标
            if let ha = annotation as? HotAnnotation {
                let id = "hot"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? HotAnnotationView
                    ?? HotAnnotationView(annotation: ha, reuseIdentifier: id)
                v.canShowCallout = false
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
            // v1.50 重中之重：抓拍类点位用自定义"红底白相机+呼吸光圈"高亮标，
            // 任何底图/缩放/深色模式下都醒目，且 displayPriority=.required 永不被系统隐藏
            if pa.poi.type.isCamera {
                let id = "cam"
                if let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? CameraMarkerView {
                    v.annotation = pa
                    v.canShowCallout = true
                    return v
                }
                let v = CameraMarkerView(annotation: pa, reuseIdentifier: id)
                v.canShowCallout = true
                return v
            }
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
                // v1.50 定位连接线：亮黄 3pt（高德式步行导航"贴路"线）
                if poly === self.locLinkPolyline {
                    r.strokeColor = UIColor.systemYellow
                    r.lineWidth = 3
                    r.lineDashPattern = [2, 2]
                } else
                // v1.49 历史轨迹：灰色虚线（最底）
                if poly === self.tripPolyline {
                    r.strokeColor = UIColor.gray.withAlphaComponent(0.8)
                    r.lineWidth = 5
                    r.lineDashPattern = [10, 8]
                } else if let t = self.trafficPolylines.first(where: { $0.0 === poly }) {
                    // v1.49 路况线：1绿 2黄 3橙 4红（高德路况配色）
                    switch t.1 {
                    case 1: r.strokeColor = UIColor(red: 0.25, green: 0.78, blue: 0.35, alpha: 0.75)
                    case 2: r.strokeColor = UIColor(red: 0.95, green: 0.80, blue: 0.20, alpha: 0.80)
                    case 3: r.strokeColor = UIColor(red: 1.0, green: 0.55, blue: 0.15, alpha: 0.85)
                    default: r.strokeColor = UIColor(red: 0.92, green: 0.20, blue: 0.20, alpha: 0.9)
                    }
                    r.lineWidth = 5
                } else if poly === self.underPolyline {
                    // 白色描边底层（细，路线更贴合道路）
                    r.strokeColor = .white
                    r.lineWidth = 7
                } else if poly === self.mainPolyline {
                    // 推荐路线：草绿色（高德推荐色）
                    r.strokeColor = UIColor(red: 0.32, green: 0.74, blue: 0.35, alpha: 1.0)
                    r.lineWidth = 4
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
            if overlay is AmapTileOverlay {
                // v1.51 高德瓦片：必须返回专用 renderer（GCJ→WGS 重投影），否则瓦片不绘制
                return AmapTileRenderer(overlay: overlay)
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

/// v1.51 高德在线瓦片底图（公开免费瓦片 webrd*.is.autonavi.com，无 Key）。
/// 高德瓦片为 GCJ-02 网格；自定义 renderer 把每张瓦片按 GCJ→WGS 平移绘制到 WGS 位置
/// （逐瓦片中心对齐，残差仅瓦片内偏移梯度 ≈ 数米），底图与高德路线同源，消除路网偏差。
final class AmapTileOverlay: NSObject, MKOverlay {
    /// 高德标准底图瓦片模板（公开服务，无需 Key）
    static let tileURL = "https://webrd01.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=7&x={x}&y={y}&z={z}"
    /// v1.52：coordinate 必须为有效坐标（世界网格全屏覆盖，取世界中心；invalid 会令部分系统不渲染 overlay）
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
}

/// 瓦片重投影 renderer：在 WGS 网格上逐瓦片请求 GCJ 瓦片并按中心对齐绘制
final class AmapTileRenderer: MKOverlayRenderer {
    private static let zMin = 3, zMax = 19
    private var cache: [String: UIImage] = [:]
    private var pending: Set<String> = []

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in ctx: CGContext) {
        let z = min(AmapTileRenderer.zMax, max(AmapTileRenderer.zMin, Int((20.0 - log2(zoomScale)).rounded())))
        let n = 1 << z
        let per = MKMapRect.world.size.width / Double(n)
        let x0 = max(0, Int(floor(mapRect.minX / per)))
        let x1 = min(n - 1, Int(floor(mapRect.maxX / per)))
        let y0 = max(0, Int(floor(mapRect.minY / per)))
        let y1 = min(n - 1, Int(floor(mapRect.maxY / per)))
        guard x1 >= x0, y1 >= y0 else { return }
        ctx.setFillColor(UIColor.systemGray5.cgColor)
        for x in x0...x1 {
            for y in y0...y1 {
                // WGS 瓦片中心 → GCJ 瓦片索引（中心对齐近似）
                let lat = tileLat(y, z)
                let lon = (Double(x) + 0.5) / Double(n) * 360.0 - 180.0
                let g = CoordConv.wgs2gcj(lat, lon)
                let gx = min(n - 1, max(0, Int(floor((g.1 + 180.0) / 360.0 * Double(n)))))
                let gy = min(n - 1, max(0, tileY(g.0, z)))
                let key = "\(z)-\(gx)-\(gy)"
                let rect = self.rect(for: MKMapRect(x: Double(x) * per, y: Double(y) * per,
                                                    width: per, height: per))
                if let img = cache[key], let cg = img.cgImage {
                    ctx.draw(cg, in: rect)
                } else {
                    ctx.fill(rect) // 未下载先浅色占位
                    if !pending.contains(key) {
                        pending.insert(key)
                        fetchTile(gx, gy, z, key)
                    }
                }
            }
        }
    }

    private func fetchTile(_ x: Int, _ y: Int, _ z: Int, _ key: String) {
        guard let url = URL(string: AmapTileOverlay.tileURL
            .replacingOccurrences(of: "{x}", with: "\(x)")
            .replacingOccurrences(of: "{y}", with: "\(y)")
            .replacingOccurrences(of: "{z}", with: "\(z)")) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data, let img = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                self.cache[key] = img
                self.pending.remove(key)
                if self.cache.count > 400 {
                    // Dictionary 无 removeFirst：清最旧若干条目（键序近似 FIFO）
                    var drop = 50
                    while drop > 0, let k = self.cache.keys.first {
                        self.cache.removeValue(forKey: k)
                        drop -= 1
                    }
                }
                self.setNeedsDisplay()
            }
        }.resume()
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

/// v1.50 热门/最近常搜索地点标注（点击直接规划路线）
final class HotAnnotation: NSObject, MKAnnotation {
    let name: String
    var coordinate: CLLocationCoordinate2D
    init(name: String, lat: Double, lon: Double) {
        self.name = name
        self.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        super.init()
    }
    var title: String? { name }
    var subtitle: String? { "热门/常搜" }
}

/// v1.50 热门/最近常搜索地点视图：橙色星标 + 白描边（醒目）
final class HotAnnotationView: MKMarkerAnnotationView {
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        markerTintColor = .systemOrange
        glyphText = "★"
        titleVisibility = .visible
        displayPriority = .required
        layer.borderWidth = 2
        layer.borderColor = UIColor.white.cgColor
        layer.cornerRadius = 8
    }
    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:)") }
}

/// v1.50 重中之重：抓拍点位高亮视图——红底白相机 + 白色粗描边 + 呼吸光圈，
/// displayPriority = .required 保证任何底图/缩放级别都显示
final class CameraMarkerView: MKAnnotationView {
    private let haloLayer = CAShapeLayer()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        centerOffset = CGPoint(x: 0, y: -20)
        let img = UIImageView(image: Self.makeIcon())
        img.frame = CGRect(x: 3, y: 3, width: 34, height: 34)
        addSubview(img)
        // 白色粗描边圆底
        layer.borderWidth = 3
        layer.borderColor = UIColor.white.cgColor
        layer.cornerRadius = 20
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.5
        layer.shadowRadius = 4
        layer.shadowOffset = .zero
        // 呼吸光圈（缩放+淡出动画，高德式警示脉冲）
        haloLayer.path = UIBezierPath(ovalIn: CGRect(x: -9, y: -9, width: 58, height: 58)).cgPath
        haloLayer.fillColor = UIColor.clear.cgColor
        haloLayer.strokeColor = UIColor.systemRed.cgColor
        haloLayer.lineWidth = 3
        layer.addSublayer(haloLayer)
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 0.8
        pulse.toValue = 1.4
        pulse.duration = 1.0
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.25
        fade.duration = 1.0
        fade.autoreverses = true
        fade.repeatCount = .infinity
        haloLayer.add(pulse, forKey: "pulse")
        haloLayer.add(fade, forKey: "fade")
        displayPriority = .required
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:)") }

    static func makeIcon() -> UIImage {
        let size = CGSize(width: 34, height: 34)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.systemRed.setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 34, height: 34)).fill()
            if let img = UIImage(systemName: "video.fill")?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                let t = img.size
                img.draw(in: CGRect(x: (34 - t.width) / 2, y: (34 - t.height) / 2,
                                    width: t.width, height: t.height))
            }
        }
    }
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
    /// 当前位置图标：高德同款蓝色实心箭头（宽胖箭头 + 圆尾，纯蓝渐变填充，无中心点；
    /// 白色细描边 + 底部轻投影保证深色地图上的辨识度；固定朝屏幕上方，地图随手机朝向旋转）
    static func makeUserIcon() -> UIImage {
        let size: CGFloat = 42
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            let c = ctx.cgContext
            let cx = size / 2
            let cy: CGFloat = 21
            // 高德式箭头：宽胖主体 + 圆弧尾
            let arrow = UIBezierPath()
            arrow.move(to: CGPoint(x: cx, y: cy - 21))                        // 尖端
            arrow.addQuadCurve(to: CGPoint(x: cx - 13, y: cy - 3),
                               controlPoint: CGPoint(x: cx - 12.5, y: cy - 12.5)) // 左侧
            arrow.addArc(withCenter: CGPoint(x: cx, y: cy + 8),
                         radius: 11, startAngle: .pi, endAngle: 0, clockwise: true) // 圆尾
            arrow.addQuadCurve(to: CGPoint(x: cx, y: cy - 21),
                               controlPoint: CGPoint(x: cx + 12.5, y: cy - 12.5)) // 右侧
            arrow.close()
            // 底部轻投影（高德箭头立体感）
            c.saveGState()
            c.setShadow(offset: CGSize(width: 0, height: 2.5), blur: 4,
                        color: UIColor.black.withAlphaComponent(0.35).cgColor)
            UIColor(red: 0.12, green: 0.36, blue: 0.95, alpha: 1.0).setFill()
            arrow.fill()
            c.restoreGState()
            // 蓝色渐变填充（顶部浅 → 底部深）
            c.saveGState()
            arrow.addClip()
            let colors = [
                UIColor(red: 0.38, green: 0.60, blue: 1.0, alpha: 1.0).cgColor,
                UIColor(red: 0.08, green: 0.32, blue: 0.95, alpha: 1.0).cgColor
            ] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors, locations: [0.0, 1.0]) {
                c.drawLinearGradient(grad,
                                     start: CGPoint(x: cx, y: cy - 21),
                                     end: CGPoint(x: cx, y: cy + 19),
                                     options: [])
            }
            c.restoreGState()
            // 白色细描边（高德箭头描边效果，深色底图上清晰）
            c.setStrokeColor(UIColor.white.withAlphaComponent(0.92).cgColor)
            c.setLineWidth(1.6)
            c.setLineJoin(.round)
            c.addPath(arrow.cgPath)
            c.strokePath()
        }
    }
}
