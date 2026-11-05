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
    /// v2.28 「1 厘米 = N 米」→ 相机到地图中心的地面距离（米）
    ///
    /// 老实现用 `ptPerCm = 38.0` 硬编码 —— 但"1 厘米对应多少点"取决于
    /// 设备的物理尺寸与缩放（iPhone SE 约 38pt/cm，iPhone Pro Max 约 34pt/cm），
    /// 硬编码在不同机型上比例尺会差 10% 以上，用户看到的"1厘米=50米"名不副实。
    ///
    /// 现在用真实物理尺寸换算：pt 本身就是物理单位（1 pt = 1/72 英寸），
    /// 按 2.54 cm/英寸 算出屏幕物理高度（厘米），再推出"每 pt 对应多少米"。
    /// 任何机型都对得上。
    ///
    /// 系数说明：俯视 45°（导航态）时，屏幕竖直张开的地面距离 ≈ 1.689 × D
    ///（D = 相机到地图中心的地面距离），所以 D = span × 0.592。
    /// 旧代码用的 0.62 恰好接近，但它是设给 altitude（垂直高度）用的，
    /// 而 altitude = D × sin(45°) = 0.707D，两者是不同的量。
    ///
    /// 注：这里必须是 **static** —— 调用点在 MapViewRepresentable.updateUIView 里，
    /// 而 Coordinator 是它的嵌套类，Coordinator 的实例方法在 struct 层不可见。
    static func altitudeForScale(_ metersPerCm: Int, screenH: CGFloat) -> Double {
        // ① 屏幕物理高度（厘米）
        //    pt 本身就是物理单位（1pt = 1/72 英寸），与 nativeScale 无关。
        //    注意：不能写成 screenH / nativeScale / 2.54 —— 那会多除了一个缩放倍数，
        //    iPhone 14（844pt @3x）会算成 110cm（真实 29.8cm），差 3.7 倍。
        let physicalHeightCm = Double(screenH) / 72.0 * 2.54
        // ② 「1 厘米 = N 米」→ 屏幕竖直方向张开的地面距离
        let spanMeters = physicalHeightCm * Double(metersPerCm)
        // ③ 俯视 45°（导航态）时，屏幕张开地面距离 ≈ 1.689 × 相机到中心的地面距离，
        //    所以 D = span / 1.689 ≈ span × 0.592。
        //    这个系数由相机几何推导（俯角 45°、垂直视场 45°）：
        //      顶边射线水平距 + 底边射线水平距 = 1.689 × D
        //    旧代码用的 0.62 恰好接近，但它是设给 altitude（垂直高度）用的，
        //    而 altitude = D × sin(45°) = 0.707D，两者是不同的量。
        return max(spanMeters * 0.592, 50)
    }

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
        map.showsTraffic = true // v2.31 原生实时路况图层(替换自绘瓦片后 MapKit 自带)
        map.showsCompass = false // v2.28：按用户要求删除所有界面指南针（含系统自带的）
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
                // v2.28 修复致命崩溃（用户报告"点加油地点直接退出软件"）：
                //
                // 旧写法 `for j in want.count..<existing.count` 在 want.count > existing.count 时
                // 会构造**反向区间**。首次添加途经点时地图上还没有 "via" 标注，
                // 于是区间是 1..<0 —— Range 的下标访问会触发
                // "Fatal error: Can't get index(1) from range 1..<0"，
                // 这是硬 trap（Release 也生效），进程立即终止，用户看到的就是"闪退"。
                //
                // 修法：只有 want 比 existing 少的时候才需要删除多余标注，
                // 并且显式用 if 判断代替可能反向的区间。
                if want.count < existing.count {
                    for j in want.count..<existing.count {
                        map.removeAnnotation(existing[j])
                    }
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
            map.removeOverlays(map.overlays) // v2.31 原生底图无自绘 overlay，全删(折线/多边形)
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
                let screenH = map.bounds.height
                // v2.28：用真实物理尺寸换算（不再用 ptPerCm=38 硬编码）
                let altitude = MapViewRepresentable.altitudeForScale(navScaleTarget, screenH: screenH)
                context.coordinator.setRegionProgrammatically {
                    map.userTrackingMode = .followWithHeading
                    var cam = map.camera
                    cam.centerCoordinate = MapGeo.toGCJ(loc)
                    // v2.28：用 centerCoordinateDistance（相机到地图中心的地面距离），
                    // 不用 altitude（相机到地面的垂直高度）——
                    // 有俯角（pitch=45°）时两者不相等，而 altitudeForScale
                    // 算出来的是"中心点的地面距离"，必须用同一个量才准。
                    cam.centerCoordinateDistance = altitude
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
                    // v2.28：与 navScaleTick 用同一套换算（真实物理尺寸）
                    cam.centerCoordinateDistance = MapViewRepresentable.altitudeForScale(navScaleTarget,
                                                                           screenH: map.bounds.height)
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
        }
        // 缩放按钮（+/-）：以地图中心缩放 0.5x / 2x
        // v1.98 修复"点 +/- 没反应"：跟随模式（.follow/.followWithHeading）下 MapKit 会
        // 立刻把镜头拉回定位点，setRegion 被覆盖；先退出跟随再缩放
        if zoomInTick != context.coordinator.lastZoomInTick {
            context.coordinator.lastZoomInTick = zoomInTick
            if zoomInTick > 0 {
                let reg = map.region
                // v2.28 倍率从 0.5 调到 0.62：altitude 语义下 0.5 太猛（一下从街道跳到街区）
                context.coordinator.zoom(map, by: 0.62, center: reg.center)
            }
        }
        if zoomOutTick != context.coordinator.lastZoomOutTick {
            context.coordinator.lastZoomOutTick = zoomOutTick
            if zoomOutTick > 0 {
                let reg = map.region
                // v2.28 倍率从 2.0 调到 1.6：缩小时过猛容易越过瓦片层级导致白花
                context.coordinator.zoom(map, by: 1.6, center: reg.center)
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
            // v2.28 比例尺改用相机到中心点的地面距离（centerCoordinateDistance）
            //
            // 旧版用 map.region.span.latitudeDelta —— 那是「地图中心的地面跨度」，
            // 只在正交俯视（pitch=0）时等于「屏幕上一格对应的地面距离」。
            // 一旦 3D（导航态 pitch=45°），屏幕上下两端离相机的距离差很多，
            // 同一段比例尺线代表的实际距离会随位置变化 → 显示的数字是错的。
            //
            // centerCoordinateDistance 是相机到地图中心的地面距离，
            // 在中心点处 1pt 对应的地面距离 = 该距离 / (bounds.height/2)，
            // 2D/3D 都对。
            let cam = map.camera
            let halfHeightPoints = Double(map.bounds.height) / 2.0
            guard halfHeightPoints > 0 else { return }
            let groundDistance = cam.centerCoordinateDistance > 0
                ? cam.centerCoordinateDistance
                : Double(map.region.span.latitudeDelta) * 111_000.0
            let metersPerPoint = groundDistance / halfHeightPoints
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
        // v2.31 底图换 MapKit 原生，原瓦片 renderer 引用已删除
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
        /// v2.29 程序化移动标志：**计数器**（原来是 Bool）
        ///
        /// 旧实现用 Bool，有真实的失衡：
        /// 一次 setRegionProgrammatically 里往往做了**两件**会各自触发 region 事务的事
        /// （比如 `map.userTrackingMode = .followWithHeading` 和 `map.camera = cam`），
        /// MapKit 是否把它们合并成一个事务并不确定 ——
        /// 不合并时，第二个 regionDidChange 回调撞上 Bool 已被消费的状态，
        /// 走进 `else if !animated` 分支 → **误判成"用户手动移了地图"**（userMoved = true）。
        ///
        /// 后果：导航卡片整张塌掉，只剩一个"继续导航"按钮
        /// （ContentView 的 navUserMoved 分支），用户看到的就是"点了开始导航卡住了"。
        /// 自动回中要求位移 > 100 米，所以短距离内这个塌陷会一直持续。
        ///
        /// 改成计数器后：N 次程序化移动能吃掉 N 个回调，不会互相干扰。
        /// 再加一个"自动过期"兜底：程序化移动后 1.5 秒内没等到回调就把计数清零，
        /// 避免某次 MapKit 没回调导致后续**真实的**用户手势被误吞。
        private var programmaticMoveCount = 0
        /// 程序化移动的时间戳（用于自动过期）
        private var programmaticMoveAt = Date.distantPast

        func setRegionProgrammatically(_ block: () -> Void) {
            programmaticMoveCount += 1
            programmaticMoveAt = Date()
            block()
        }

        /// 消费一次程序化移动标记；返回 true 表示这次回调是程序化造成的
        private func consumeProgrammaticMove() -> Bool {
            // 超过 1.5 秒还没等到对应回调 → 认为 MapKit 吞掉了/合并了，清零重来
            if programmaticMoveCount > 0, Date().timeIntervalSince(programmaticMoveAt) > 1.5 {
                programmaticMoveCount = 0
            }
            if programmaticMoveCount > 0 {
                programmaticMoveCount -= 1
                return true
            }
            return false
        }

        /// v1.98 统一缩放入口：先脱离跟随（否则 MapKit 会立刻回中，表现为按钮点了没反应）
        ///
        /// v2.28 重写：**改用相机高度（altitude）缩放，而不是 region.span**
        ///
        /// 为什么必须换：
        /// region.span 是「地面上的纬经度跨度」，而用户在屏幕上看到的是「相机离地多高」。
        /// 两者只在正交俯视（pitch=0）时近似一致。一旦进入 3D（导航态 pitch=45°），
        /// 用 span 缩放会出现"点 + 屏幕几乎不变"的错觉 —— 用户会觉得按钮坏了。
        ///
        /// MKMapCamera.altitude 才是视觉缩放的正确度量：
        /// 高度减半 ≈ 画面放大一倍，2D/3D 表现一致。
        ///
        /// 另外加了上下限：太低会进入"贴地"（瓦片细节不足、看不到路网），
        /// 太高会超出瓦片层级范围（出现白花/模糊）。
        func zoom(_ map: MKMapView, by factor: Double, center: CLLocationCoordinate2D) {
            if map.userTrackingMode != .none {
                map.setUserTrackingMode(.none, animated: false)
            }
            userMoved = true
            setRegionProgrammatically {
                var cam = map.camera
                // 相机高度：点 + 用当前值，点 - 用当前值；factor < 1 = 放大
                // v2.28：用 centerCoordinateDistance 作缩放基准（与导航视野换算同一个量）。
                // altitude 是垂直高度，有俯角时与"到中心的地面距离"不等，
                // 两者混用会让"点 + 之后画面变化幅度"忽大忽小。
                let current = cam.centerCoordinateDistance > 0 ? cam.centerCoordinateDistance : 2000
                var target = current * factor
                // v2.28 上下限：50m ~ 60km
                // 下限 50m：再近也看不出更多细节（瓦片最小层级约 50m）
                // 上限 60km：再远瓦片层级不够，会出现模糊/白块
                target = min(60_000, max(50, target))
                cam.centerCoordinateDistance = target
                // v2.28 坐标系修正：center 参数**已经是 GCJ-02**（MapKit 坐标系）——
                // 两个调用点传的都是 map.region.center 或 map.convert(...)，都是 GCJ。
                // 旧版用 setRegion 时 MapKit 自己会处理坐标，
                // 改成直接设 camera.centerCoordinate 后就**不能再转一次**，
                // 否则会二次偏移（合肥约 500 米）—— 表现为"点缩放按钮地图跳到别处"。
                cam.centerCoordinate = center
                map.camera = cam
            }
        }

        /// v1.98 双击地图放大：以双击位置为中心，缩放步长比点按钮略缓（2 倍 → 0.55 倍跨度）
        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let map = gesture.view as? MKMapView else { return }
            let pt = gesture.location(in: map)
            let center = map.convert(pt, toCoordinateFrom: map)
            // v2.28 倍率与 +/- 按钮统一（altitude 语义）
            zoom(map, by: 0.62, center: center)
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
            if consumeProgrammaticMove() {
                // 程序化移动，正常
            } else if !animated {
                // 用户手势（拖动/旋转/缩放）触发的区域变化 → 暂停跟随与自动旋转
                userMoved = true
            }
        }

        // v1.69 地图加载回调（MKMapView：渲染完成 / 加载失败）
        func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
            // v2.14 只回调第一次。
            //
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
