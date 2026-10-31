import SwiftUI
import AMap2DMap
import AMapFoundationKit
import UIKit
import CoreLocation

/// 轻量地图封装（v1.68 B档：高德官方 3D 地图 SDK 渲染引擎，真·高德底图；坐标 WGS84 存储、GCJ 显示）
/// 保留全部对外参数签名，ContentView 无需改动。
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
    /// 轻点地图空白处（高德 SDK 坐标系 GCJ，回调前转回 WGS84）
    var onMapTap: ((CLLocationCoordinate2D) -> Void)?
    /// v1.63 极简模式：隐藏兴趣点/地名/类别标注（高德导航"极简"）
    let minimal: Bool
    /// v1.69 地图重载计数（加载失败重试 +1，触发 MAMapView.reloadMap）
    let reloadTick: Int
    /// v1.69 地图加载状态回调：(是否成功, 错误描述)
    var onMapLoad: ((Bool, String) -> Void)?

    func makeUIView(context: Context) -> MAMapView {
        let map = MAMapView(frame: .zero)
        // 高德 SDK 正式 Key（AppDelegate 已设，此处幂等兜底）
        AMapServices.shared().apiKey = "6fd752bc12caa258f066729617db0066"
        // v1.70：浅灰兜底背景——瓦片/渲染层未就绪时显示浅灰而非纯黑，便于区分"Key/服务问题"
        map.backgroundColor = UIColor(white: 0.93, alpha: 1)
        map.showsCompass = false // 使用自绘指南针（左上角）
        map.delegate = context.coordinator
        // v1.70：加载 watchdog——高德失败回调可能静默不触发，6 秒未完成视为加载卡住
        context.coordinator.startLoadWatchdog()
        // 当前定位箭头标注（高德 SDK 不启用内置定位，避免双定位；用我们自己的 CLLocationManager 数据）
        let userAnn = UserLocationAnnotation(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0))
        context.coordinator.userAnnotation = userAnn
        map.addAnnotation(userAnn)
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.6
        map.addGestureRecognizer(longPress)
        // 轻点地图：空白处（命中点位/地点标注时不触发，交给 didSelect）
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleMapTap(_:)))
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)
        return map
    }

    func updateUIView(_ map: MAMapView, context: Context) {
        context.coordinator.onLongPress = onLongPress
        context.coordinator.onPoiLongPress = onPoiLongPress
        context.coordinator.onPoiMoved = onPoiMoved
        context.coordinator.onPoiSelect = onPoiSelect
        context.coordinator.onPlaceSelect = onPlaceSelect
        context.coordinator.onCategorySelect = onCategorySelect
        context.coordinator.onMapTap = onMapTap
        context.coordinator.onMapLoad = onMapLoad
        // v1.69 地图加载失败重试
        if reloadTick != context.coordinator.lastReloadTick {
            context.coordinator.lastReloadTick = reloadTick
            if reloadTick > 0 { map.reloadMap() }
        }
        // 当前定位箭头：坐标（WGS84→GCJ 显示）；变化时重建刷新位置
        if let loc = userLocation {
            let g = CoordConv.wgs2gcj(loc.latitude, loc.longitude)
            let newC = CLLocationCoordinate2D(latitude: g.0, longitude: g.1)
            if let ua = context.coordinator.userAnnotation {
                if fabs(ua.coordinate.latitude - newC.latitude) > 1e-6
                    || fabs(ua.coordinate.longitude - newC.longitude) > 1e-6 {
                    ua.coordinate = newC
                    map.removeAnnotation(ua)
                    map.addAnnotation(ua)
                }
            }
        }
        // 定位按钮：跟随手机朝向模式（地图自动旋转 + 回中，不重置缩放级别）
        if locateTick != context.coordinator.lastLocateTick {
            context.coordinator.lastLocateTick = locateTick
            if locateTick > 0, let loc = userLocation {
                context.coordinator.userMoved = false // 恢复跟随/自动旋转
                let g = CoordConv.wgs2gcj(loc.latitude, loc.longitude)
                context.coordinator.setRegionProgrammatically {
                    map.setCenter(CLLocationCoordinate2D(latitude: g.0, longitude: g.1), animated: true)
                }
            }
        } else if !context.coordinator.hasCentered, let loc = userLocation {
            // 首次定位：设置初始区域（合肥周边 3km）
            context.coordinator.hasCentered = true
            let g = CoordConv.wgs2gcj(loc.latitude, loc.longitude)
            context.coordinator.setRegionProgrammatically {
                map.setRegion(MACoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: g.0, longitude: g.1),
                    span: MACoordinateSpan(latitudeDelta: 0.045, longitudeDelta: 0.045)),
                    animated: false)
            }
        }
        // 路线全览（仅在新规划完成时触发一次，包含全部方案路线）
        if fitTick != context.coordinator.lastFitTick && route.count > 1 {
            context.coordinator.lastFitTick = fitTick
            context.coordinator.setRegionProgrammatically {
                var pts: [CLLocationCoordinate2D] = route.map { gcj($0) }
                for r in choiceRoutes { pts.append(contentsOf: r.map { gcj($0) }) }
                context.coordinator.fitRegion(pts, map: map)
            }
        }
        // 加油站全览（仅在新请求时触发一次）
        if gasTick != context.coordinator.lastGasTick && !gasStations.isEmpty {
            context.coordinator.lastGasTick = gasTick
            context.coordinator.setRegionProgrammatically {
                var pts = gasStations.map { gcj($0) }
                if let u = userLocation { pts.append(gcj(u)) }
                context.coordinator.fitRegion(pts, map: map)
            }
        }
        // 点位标注增删（PoiAnnotation.coordinate 返回 GCJ 显示坐标）
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
                    map.removeAnnotation(a)
                    map.addAnnotation(PoiAnnotation(poi: p, onRoute: routePois.contains { $0.id == p.id }))
                } else {
                    a.poi = p
                    a.onRoute = routePois.contains { $0.id == p.id }
                }
            }
        }
        // 终点标记（高德式：起点=当前定位蓝箭头，终点保留"终"）
        map.annotations
            .compactMap { $0 as? RouteEndAnnotation }
            .filter { $0.kind == "start" }
            .forEach { map.removeAnnotation($0) }
        let endPresent = map.annotations.contains { ($0 as? RouteEndAnnotation)?.kind == "end" }
        if let last = route.last, !endPresent {
            map.addAnnotation(RouteEndAnnotation(kind: "end", coordinate: gcj(last)))
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
                    let g = gcj(p)
                    map.setRegion(MACoordinateRegion(
                        center: g,
                        span: MACoordinateSpan(latitudeDelta: 0.045, longitudeDelta: 0.045)),
                        animated: true)
                }
            }
        }
        if let p = preview {
            let g = gcj(p)
            if previews.isEmpty {
                map.addAnnotation(PreviewAnnotation(coordinate: g))
            } else if let a = previews.first {
                a.coordinate = g
            }
        } else {
            previews.forEach { map.removeAnnotation($0) }
        }
        // 加油站标注
        let wantGas = Set(gasStations.map { "\($0.latitude),\($0.longitude)" })
        map.annotations
            .compactMap { $0 as? GasAnnotation }
            .filter { !wantGas.contains("\($0.wgsLat),\($0.wgsLon)") }
            .forEach { map.removeAnnotation($0) }
        for c in gasStations {
            let key = "\(c.latitude),\(c.longitude)"
            if !map.annotations.contains(where: { ($0 as? GasAnnotation)?.id == key }) {
                map.addAnnotation(GasAnnotation(id: key, coordinate: gcj(c)))
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
        // 路线折线（GCJ 坐标；导航中仅当前路线，规划态含备选虚线）
        map.removeOverlays(map.overlays)
        context.coordinator.underPolyline = nil
        context.coordinator.mainPolyline = nil
        context.coordinator.alternatePolylines = []
        if route.count > 1 {
            let gcjRoute = route.map { gcj($0) }
            if navigating {
                let under = polyline(gcjRoute)
                context.coordinator.underPolyline = under
                let main = polyline(gcjRoute)
                context.coordinator.mainPolyline = main
                map.add(under)
                map.add(main)
            } else {
                for (idx, pts) in choiceRoutes.enumerated() where idx != selectedRouteIdx && pts.count > 1 {
                    let alt = polyline(pts.map { gcj($0) })
                    context.coordinator.alternatePolylines.append(alt)
                    map.add(alt)
                }
                let under = polyline(gcjRoute)
                context.coordinator.underPolyline = under
                let main = polyline(gcjRoute)
                context.coordinator.mainPolyline = main
                map.add(under)
                map.add(main)
            }
        }
        // 地图自适应旋转：地图始终与手机朝向一致（箭头固定朝屏幕上方=手机朝向，避免双重旋转）
        if !context.coordinator.userMoved {
            map.rotationDegree = CLLocationDirection(heading)
        }
        // 导航跟随：导航开始/结束/到达时进入跟随（高德式：地图随车移动+自动旋转）
        if navigateFollowTick != context.coordinator.lastNavFollowTick {
            context.coordinator.lastNavFollowTick = navigateFollowTick
            context.coordinator.userMoved = false
            if let loc = userLocation {
                context.coordinator.navLastFollow = loc
                let g = CoordConv.wgs2gcj(loc.latitude, loc.longitude)
                context.coordinator.setRegionProgrammatically {
                    map.setCenter(CLLocationCoordinate2D(latitude: g.0, longitude: g.1), animated: true)
                }
            }
        }
        // 导航中跟随车动（每帧回中）；用户拖动后暂停，开远（>100米）自动拉回
        if navigating, let loc = userLocation {
            if context.coordinator.userMoved {
                if let last = context.coordinator.navLastFollow,
                   CLLocation(latitude: loc.latitude, longitude: loc.longitude)
                    .distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude)) > 100 {
                    context.coordinator.userMoved = false
                }
            }
            context.coordinator.navLastFollow = loc
            if !context.coordinator.userMoved {
                let g = CoordConv.wgs2gcj(loc.latitude, loc.longitude)
                map.setCenter(CLLocationCoordinate2D(latitude: g.0, longitude: g.1), animated: true)
            }
        }
        // v1.72：2D SDK 无俯仰（骑行导航 2D 顶视即高德骑行风格）；导航不倾斜
        let isNav = navigating
        if isNav != context.coordinator.lastPitchState {
            context.coordinator.lastPitchState = isNav
        }
        // 缩放按钮（+/-）：按地图中心缩放
        if zoomInTick != context.coordinator.lastZoomInTick {
            context.coordinator.lastZoomInTick = zoomInTick
            if zoomInTick > 0 {
                context.coordinator.setRegionProgrammatically {
                    map.setZoomLevel(map.zoomLevel + 1, animated: true)
                }
            }
        }
        if zoomOutTick != context.coordinator.lastZoomOutTick {
            context.coordinator.lastZoomOutTick = zoomOutTick
            if zoomOutTick > 0 {
                context.coordinator.setRegionProgrammatically {
                    map.setZoomLevel(max(map.zoomLevel - 1, 3), animated: true)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// GCJ 坐标转换辅助（WGS84 → GCJ-02 显示）
    private func gcj(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let g = CoordConv.wgs2gcj(c.latitude, c.longitude)
        return CLLocationCoordinate2D(latitude: g.0, longitude: g.1)
    }

    /// MAPolyline 构造（Swift 指针接口）
    private func polyline(_ pts: [CLLocationCoordinate2D]) -> MAPolyline {
        var coords = pts
        return MAPolyline(coordinates: &coords, count: UInt(coords.count))
    }

    final class Coordinator: NSObject, MAMapViewDelegate, UIGestureRecognizerDelegate {
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
        /// v1.69 地图加载状态回调
        var onMapLoad: ((Bool, String) -> Void)?
        var lastReloadTick = 0
        /// 当前定位箭头标注
        var userAnnotation: UserLocationAnnotation?
        /// 是否已做过首次定位居中
        var hasCentered = false
        /// 定位/全览/预览请求记忆（只响应新请求，避免定位更新反复重置地图）
        var lastLocateTick = 0
        var lastFitTick = 0
        var lastGasTick = 0
        var lastZoomInTick = 0
        var lastZoomOutTick = 0
        var lastPreviewKey = ""
        /// 导航 3D 俯仰状态记忆（仅状态切换时设置 cameraDegree）
        var lastPitchState: Bool?
        /// 路线绿色描边底层引用（renderer 区分双层）
        var underPolyline: MAPolyline?
        /// 当前方案主层（草绿色，renderer 区分）
        var mainPolyline: MAPolyline?
        /// 备选方案折线（浅绿色虚线，renderer 区分）
        var alternatePolylines: [MAPolyline] = []
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

        /// 全览一组点（GCJ 已转换）：计算 bbox 并 setRegion
        func fitRegion(_ pts: [CLLocationCoordinate2D], map: MAMapView) {
            guard let first = pts.first else { return }
            var minLat = first.latitude, maxLat = first.latitude
            var minLon = first.longitude, maxLon = first.longitude
            for p in pts {
                minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude)
                minLon = min(minLon, p.longitude); maxLon = max(maxLon, p.longitude)
            }
            let dLat = max(maxLat - minLat, 0.01)
            let dLon = max(maxLon - minLon, 0.01)
            map.setRegion(MACoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: (minLat + maxLat) / 2,
                    longitude: (minLon + maxLon) / 2),
                span: MACoordinateSpan(latitudeDelta: dLat * 1.4, longitudeDelta: dLon * 1.4)),
                animated: true)
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let map = gesture.view as? MAMapView else { return }
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
                    // 高德 SDK 返回 GCJ 坐标 → 转回 WGS84 存库
                    let coord = map.convert(pt, toCoordinateFrom: map)
                    let w = CoordConv.gcj2wgs(coord.latitude, coord.longitude)
                    onLongPress?(CLLocationCoordinate2D(latitude: w.0, longitude: w.1))
                }
            case .changed:
                if let ann = dragAnnotation {
                    let newCoord = map.convert(pt, toCoordinateFrom: map)
                    // 拖动临时坐标存 WGS84（与 poi.coordinate 同体系）
                    let w = CoordConv.gcj2wgs(newCoord.latitude, newCoord.longitude)
                    ann.dragCoordinate = CLLocationCoordinate2D(latitude: w.0, longitude: w.1)
                    // 地图跟随平移（高德拖拽标记行为）：标注始终保持在手指下
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

        /// 轻点地图空白处（命中标注时不触发，避免与点位/地点选择冲突）
        @objc func handleMapTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended,
                  let map = gesture.view as? MAMapView else { return }
            let pt = gesture.location(in: map)
            for a in map.annotations {
                guard !(a is UserLocationAnnotation), let ann = a as? MAAnnotation else { continue }
                let ap = map.convert(ann.coordinate, toPointTo: map)
                let d = hypot(pt.x - ap.x, pt.y - ap.y)
                // 命中任何标注（点位/地点/类别/起点终点）→ 交给 didSelect
                if d < 40 {
                    return
                }
            }
            let coord = map.convert(pt, toCoordinateFrom: map)
            let w = CoordConv.gcj2wgs(coord.latitude, coord.longitude)
            onMapTap?(CLLocationCoordinate2D(latitude: w.0, longitude: w.1))
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }

        func mapView(_ mapView: MAMapView, regionDidChangeAnimated animated: Bool) {
            // 程序 setRegion/setCenter 触发时不标记用户移动
            if programmaticMove {
                programmaticMove = false
            } else if !animated {
                userMoved = true
            }
        }

        /// v1.69 地图加载成功（高德底图渲染就绪）
        func mapViewDidFinishLoadingMap(_ mapView: MAMapView) {
            cancelLoadWatchdog()
            onMapLoad?(true, "")
        }

        /// v1.69 地图加载失败（Key 未生效/网络异常/服务未开通），给出诊断
        func mapViewDidFailLoadingMap(_ mapView: MAMapView, withError error: Error) {
            cancelLoadWatchdog()
            onMapLoad?(false, error.localizedDescription)
        }

        // MARK: - v1.70 加载 watchdog（高德失败回调可能静默不触发）

        private var loadWatchdog: Timer?

        func startLoadWatchdog() {
            cancelLoadWatchdog()
            loadWatchdog = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
                self?.loadWatchdog = nil
                self?.onMapLoad?(false, "TIMEOUT: 地图 6 秒未加载完成")
            }
        }

        func cancelLoadWatchdog() {
            loadWatchdog?.invalidate()
            loadWatchdog = nil
        }

        func mapView(_ mapView: MAMapView, didSelect view: MAAnnotationView) {
            // 点击点位/地点/类别：回调（取消系统选中态，避免遮挡）
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

        func mapView(_ mapView: MAMapView, viewFor annotation: MAAnnotation) -> MAAnnotationView? {
            // 当前位置：高德同款实心蓝色指向箭头
            if annotation is UserLocationAnnotation {
                let id = "userLoc"
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MAAnnotationView(annotation: annotation, reuseIdentifier: id))!
                v.image = MapViewRepresentable.makeUserIcon()
                v.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
                v.centerOffset = .zero
                v.canShowCallout = false
                return v
            }
            if let re = annotation as? RouteEndAnnotation {
                let id = "routeEnd"
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MAAnnotationView(annotation: re, reuseIdentifier: id))!
                v.image = MapViewRepresentable.markerImage(
                    color: re.kind == "start" ? .systemGreen : .systemRed,
                    text: re.kind == "start" ? "起" : "终")
                v.canShowCallout = false
                return v
            }
            if let pa = annotation as? PreviewAnnotation {
                let id = "preview"
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MAAnnotationView(annotation: pa, reuseIdentifier: id))!
                v.image = MapViewRepresentable.markerImage(color: .systemGreen, text: "✓")
                v.canShowCallout = false
                return v
            }
            if let ga = annotation as? GasAnnotation {
                let id = "gas"
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MAAnnotationView(annotation: ga, reuseIdentifier: id))!
                v.image = MapViewRepresentable.markerImage(color: .systemOrange, text: "油")
                v.canShowCallout = false
                return v
            }
            if let pla = annotation as? PlaceAnnotation {
                let id = "place"
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MAAnnotationView(annotation: pla, reuseIdentifier: id))!
                v.image = MapViewRepresentable.placeLabelImage(pla.place.name)
                v.centerOffset = CGPoint(x: 0, y: -10)
                v.canShowCallout = false
                return v
            }
            if let ca = annotation as? CategoryAnnotation {
                let id = "category"
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MAAnnotationView(annotation: ca, reuseIdentifier: id))!
                let color: UIColor
                switch ca.result.kind {
                case "医院": color = .systemRed
                case "加油站": color = .systemOrange
                default: color = .systemBlue
                }
                v.image = MapViewRepresentable.markerImage(
                    color: color, text: ca.result.kind == "加油站" ? "油" : "点")
                v.canShowCallout = false
                return v
            }
            guard let pa = annotation as? PoiAnnotation else { return nil }
            let id = "poi"
            let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id)
                ?? MAAnnotationView(annotation: pa, reuseIdentifier: id))!
            // 沿途点位：白色描边高亮（优先）；用户自定义/移动过的点位：橙色描边
            let border: UIColor? = pa.onRoute ? .white : (pa.poi.isCustom ? .orange : nil)
            v.image = MapViewRepresentable.markerImage(
                color: pa.poi.type.color,
                text: String(pa.poi.type.label.prefix(1)),
                border: border)
            v.canShowCallout = false
            return v
        }

        func mapView(_ mapView: MAMapView, rendererFor overlay: MAOverlay) -> MAOverlayRenderer? {
            guard let poly = overlay as? MAPolyline else { return nil }
            let r = MAPolylineRenderer(polyline: poly)!
            r.lineWidth = 4
            if poly === self.underPolyline {
                // v1.66 高德式绿色并行线：深绿外框（路线更贴路、双线视觉）
                r.strokeColor = UIColor(red: 0.10, green: 0.55, blue: 0.22, alpha: 1.0)
                r.lineWidth = 9
            } else if poly === self.mainPolyline {
                // 推荐路线：浅绿内芯（高德绿路线双线效果）
                r.strokeColor = UIColor(red: 0.42, green: 0.84, blue: 0.46, alpha: 1.0)
                r.lineWidth = 5
            } else if self.alternatePolylines.contains(where: { $0 === poly }) {
                // 备选路线：浅绿色（高德 11.x 无公开虚线类型，用实线浅绿区分）
                r.strokeColor = UIColor(red: 0.60, green: 0.85, blue: 0.62, alpha: 0.95)
                r.lineWidth = 4
            } else {
                r.strokeColor = UIColor(red: 0.32, green: 0.74, blue: 0.35, alpha: 1.0)
                r.lineWidth = 4
            }
            return r
        }
    }
}

/// 当前定位箭头标注（GCJ 显示坐标）
final class UserLocationAnnotation: NSObject, MAAnnotation {
    var coordinate: CLLocationCoordinate2D
    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        super.init()
    }
    var title: String? { "我的位置" }
}

/// 路线起点/终点标记
final class RouteEndAnnotation: NSObject, MAAnnotation {
    let kind: String
    let coordinate: CLLocationCoordinate2D
    init(kind: String, coordinate: CLLocationCoordinate2D) {
        self.kind = kind
        self.coordinate = coordinate
        super.init()
    }
    var title: String? { kind == "start" ? "起点" : "终点" }
}

/// 违法拍照点位标注（coordinate 返回 GCJ 显示坐标；poi.coordinate 保持 WGS84 原始）
final class PoiAnnotation: NSObject, MAAnnotation {
    var poi: Poi
    var onRoute: Bool
    /// 拖动校准中的临时坐标（WGS84，nil = 使用点位原始坐标）
    var dragCoordinate: CLLocationCoordinate2D?
    init(poi: Poi, onRoute: Bool = false) {
        self.poi = poi
        self.onRoute = onRoute
        super.init()
    }
    var coordinate: CLLocationCoordinate2D {
        let src = dragCoordinate ?? poi.coordinate
        let g = CoordConv.wgs2gcj(src.latitude, src.longitude)
        return CLLocationCoordinate2D(latitude: g.0, longitude: g.1)
    }
    var title: String? { poi.name }
    var subtitle: String? { poi.type.label }
}

/// 搜索预览点（绿色高亮；coordinate 为 GCJ 显示坐标）
final class PreviewAnnotation: NSObject, MAAnnotation {
    var coordinate: CLLocationCoordinate2D
    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        super.init()
    }
    var title: String? { "搜索目标" }
}

/// 加油站标注（橙色"油"；id 用 WGS84 键，coordinate 为 GCJ 显示坐标）
final class GasAnnotation: NSObject, MAAnnotation {
    let id: String
    let wgsLat: Double
    let wgsLon: Double
    var coordinate: CLLocationCoordinate2D
    init(id: String, coordinate: CLLocationCoordinate2D) {
        self.id = id
        self.wgsLat = coordinate.latitude
        self.wgsLon = coordinate.longitude
        self.coordinate = coordinate
        super.init()
    }
    var title: String? { "加油站" }
}

/// 小区/商铺名称标签标注（GCJ 显示）
final class PlaceAnnotation: NSObject, MAAnnotation {
    let place: PlaceLabel
    init(place: PlaceLabel) {
        self.place = place
        super.init()
    }
    var coordinate: CLLocationCoordinate2D {
        let g = CoordConv.wgs2gcj(place.lat, place.lon)
        return CLLocationCoordinate2D(latitude: g.0, longitude: g.1)
    }
    var title: String? { place.name }
}

/// 类别搜索结果标注（学校/医院/加油站；GCJ 显示）
final class CategoryAnnotation: NSObject, MAAnnotation {
    let result: AppModel.CategoryResult
    init(result: AppModel.CategoryResult) {
        self.result = result
        super.init()
    }
    var coordinate: CLLocationCoordinate2D {
        let g = CoordConv.wgs2gcj(result.lat, result.lon)
        return CLLocationCoordinate2D(latitude: g.0, longitude: g.1)
    }
    var title: String? { result.name }
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

    /// v1.68 高德 SDK 标注圆点：彩色圆 + 单字（替代已移除的 MAMarkerAnnotationView）
    static func markerImage(color: UIColor, text: String, border: UIColor? = nil) -> UIImage {
        let size: CGFloat = 26
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            let c = ctx.cgContext
            let rect = CGRect(x: 1.5, y: 1.5, width: size - 3, height: size - 3)
            c.setFillColor(color.cgColor)
            c.fillEllipse(in: rect)
            if let b = border {
                c.setStrokeColor(b.cgColor)
                c.setLineWidth(b.isEqual(UIColor.white) ? 2.5 : 2)
                c.strokeEllipse(in: rect)
            }
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            (text as NSString).draw(in: CGRect(x: 0, y: (size - 15) / 2, width: size, height: 15),
                withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 12),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: para,
                ])
        }
    }

    /// v1.68 小区/商铺名称标签（高德地名气泡样式）
    static func placeLabelImage(_ name: String) -> UIImage {
        let font = UIFont.systemFont(ofSize: 11)
        let w = max((name as NSString).size(withAttributes: [.font: font]).width + 12, 22)
        let h: CGFloat = 20
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
        return renderer.image { ctx in
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 6)
            UIColor(white: 1, alpha: 0.9).setFill()
            path.fill()
            UIColor.black.withAlphaComponent(0.15).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            (name as NSString).draw(in: CGRect(x: 2, y: 3, width: w - 4, height: 14),
                withAttributes: [
                    .font: font,
                    .foregroundColor: UIColor.black,
                    .paragraphStyle: para,
                ])
        }
    }
}
