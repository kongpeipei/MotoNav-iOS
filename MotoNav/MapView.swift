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

/// v2.87 车道箭头标注
final class LaneArrowAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let heading: CLLocationDegrees
    init(coordinate: CLLocationCoordinate2D, heading: CLLocationDegrees) {
        self.coordinate = coordinate
        self.heading = heading
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
        // v2.60 首帧兜底：makeUIView 与"刚点开始导航"那一刻，map.bounds 有可能还是 .zero，
        // 传进来 0 会把物理高度算成 0、相机距离被钳到下限 50m —— 相机等于贴在地面上，
        // 一栋普通楼就盖住半个屏幕，当前位置箭头和路线整条被楼块吞掉（用户实机就是这样）。
        let sh = screenH > 200 ? screenH : UIScreen.main.bounds.height
        // ① 屏幕物理高度（厘米）
        //    pt 本身就是物理单位（1pt = 1/72 英寸），与 nativeScale 无关。
        //    注意：不能写成 screenH / nativeScale / 2.54 —— 那会多除了一个缩放倍数，
        //    iPhone 14（844pt @3x）会算成 110cm（真实 29.8cm），差 3.7 倍。
        let physicalHeightCm = Double(sh) / 72.0 * 2.54
        // ② 「1 厘米 = N 米」→ 屏幕竖直方向张开的地面距离
        let spanMeters = physicalHeightCm * Double(metersPerCm)
        // ③ 俯视 45°（导航态）时，屏幕张开地面距离 ≈ 1.689 × 相机到中心的地面距离，
        //    所以 D = span / 1.689 ≈ span × 0.592。
        //    这个系数由相机几何推导（俯角 45°、垂直视场 45°）：
        //      顶边射线水平距 + 底边射线水平距 = 1.689 × D
        //    旧代码用的 0.62 恰好接近，但它是设给 altitude（垂直高度）用的，
        //    而 altitude = D × sin(45°) = 0.707D，两者是不同的量。
        // v2.60 下限 50 → 190：50m 是"贴地视角"，任何一栋楼都能糊住线路；
        // 190m 保证即使按最内档（20 米/厘米）算错，画面上仍至少有三百米的前方视野。
        // 正常档位算出来的值（20 档约 365m）都在这个下限之上，不影响原有换算。
        return max(spanMeters * 0.592, 190)
    }

    /// v2.60 底图 POI 白名单（make 与导航态翻转重建两处共用）。
    ///
    /// 旧版只留加油/医院/药店/学校/停车/公交六类，地图画面偏空；
    /// 这里补上餐饮、购物、公园、酒店、银行，层次更接近高德。
    /// 不放电影院、夜生活、景点这类会扎堆铺满的类别。
    /// v2.76 导航态专用 POI 过滤：比普通态收紧到 5 类。
    /// 高德一进导航，底图上的饭店/酒店/学校标签几乎全消失，只留加油站、停车这类
    /// 骑行当下真用得上的点。我们过去导航和浏览共用一个 14 类的过滤器，
    /// 屏幕上满是无关的店名，路线和车反而被文字盖住。
    static let navPOIFilter = MKPointOfInterestFilter(including: [
        .gasStation, .parking, .hospital, .pharmacy, .store
    ])

    static let standardPOIFilter = MKPointOfInterestFilter(including: [
        .gasStation, .hospital, .pharmacy, .school, .parking, .publicTransport,
        .restaurant, .cafe, .bakery, .store, .park, .hotel, .bank, .atm
    ])

    /// v2.49 导航态"车位置下移"比例：相机中心落在车前 35% 视距处。
    ///
    /// 0 = 车在屏幕正中（45° 俯角下前方只剩半屏，远处还会被透视压缩）；
    /// 0.35 = 车出现在屏高约 70%，前方占 2/3 屏——高德同款布局，前方视野提升约 40%。
    // v2.65 0.35 → 0.15：0.35 时相机中心压到车前 35% 视距，车落在屏高约 70%，
    // 配上俯角 45° 和楼块遮挡，实机上经常"找不到自己在哪"。
    // 用户明确要求"开始导航时当前定位点要在屏幕中显示"，这里把前移量收窄，
    // 车落在屏高约 56%，既在屏幕中部、前方又仍留有视野。
    // v2.94 跟随模式下定位点放屏幕正中心（苹果地图那样）：从 0.15 改成 0
    // v2.86 定位点位置：高德同款，在屏幕下方（不是正中间）
    // 0.0 = 正中间，0.3 = 下方 30%，0.5 = 下方 50%
    static let navCameraForwardRatio: Double = 0.0

    /// v2.50 围绕某点构造一个"边长 meters 见方"的地图矩形。
    ///
    /// 配合 `setVisibleMapRect(_:edgePadding:)` 使用：MapKit 会把整个矩形装进
    /// 「屏幕减去 edgePadding」的可见带里，矩形中心因此落在可见带中心 ——
    /// 这正是高德"选中地点后点位在卡片之间居中"的效果，
    /// 直接 setRegion 只能把点放在全屏中心，底部会被卡片吃掉一半。
    /// v2.60 把两个坐标装进同一个矩形（含最小边长），用于"连线居中"：
    /// 两点几乎重合时矩形会退化成一个点，setVisibleMapRect 会把地图顶到最大缩放，
    /// 所以补一个 minSideMeters 的下限（约 900m 见方，城市里看得清路名与街区）。
    static func rect(between a: CLLocationCoordinate2D,
                     and b: CLLocationCoordinate2D,
                     minSideMeters: Double) -> MKMapRect {
        let pa = MKMapPoint(a)
        let pb = MKMapPoint(b)
        var r = MKMapRect(x: min(pa.x, pb.x), y: min(pa.y, pb.y),
                          width: abs(pa.x - pb.x), height: abs(pa.y - pb.y))
        let minSide = minSideMeters * MKMapPointsPerMeterAtLatitude((a.latitude + b.latitude) / 2)
        if r.size.width < minSide {
            r.origin.x -= (minSide - r.size.width) / 2
            r.size.width = minSide
        }
        if r.size.height < minSide {
            r.origin.y -= (minSide - r.size.height) / 2
            r.size.height = minSide
        }
        return r
    }

    static func centerRect(_ c: CLLocationCoordinate2D, meters: Double) -> MKMapRect {
        let p = MKMapPoint(c)
        let half = meters / 2 * MKMapPointsPerMeterAtLatitude(c.latitude)
        return MKMapRect(x: p.x - half, y: p.y - half, width: half * 2, height: half * 2)
    }

    /// 沿方位角前移若干米（球面近似）。用于把相机中心放到车前方，
    /// 这样车就落在屏幕下方 1/3，而不是正中。
    static func forwardCoordinate(_ c: CLLocationCoordinate2D,
                                  meters: Double,
                                  bearingDeg: Double) -> CLLocationCoordinate2D {
        let earthR = 6_371_000.0
        let br = bearingDeg * .pi / 180
        let lat1 = c.latitude * .pi / 180
        let lon1 = c.longitude * .pi / 180
        let d = meters / earthR
        let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(br))
        let lon2 = lon1 + atan2(sin(br) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sin(lat2))
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }

    /// v2.12 外观跟随：手动浅色/深色时地图底图一起切（导航中始终深色）
    @Environment(\.colorScheme) private var colorScheme
    let userLocation: CLLocationCoordinate2D?
    let route: [CLLocationCoordinate2D]
    /// 全部路线方案折线（规划态同时显示：推荐草绿 + 备选浅绿，高德式）
    let choiceRoutes: [[CLLocationCoordinate2D]]
    /// 当前选中方案下标（高德式：选中草绿实线，其余浅绿虚线）
    let selectedRouteIdx: Int
    /// 定位请求计数（点击定位按钮 +1，触发地图回中）
    let locateTick: Int
    /// 路线全览请求计数（规划完成 +1，触发地图缩放全览）
    let fitTick: Int
    /// v2.50 地图可视区留白（viewport padding）：屏幕上下被卡片挡住的高度。
    ///
    /// 来源统一由 ContentView 按"当前场景真实卡片"计算：
    /// · 规划态 → 上下规划卡实测屏幕框（v2.48）
    /// · 导航态 → 顶部提示 + 底部导航卡 + 路口放大图
    /// · 加油站 → 底部类别结果条
    /// 旧版各入口各写一套魔法数（90/120、60/60），卡片高度一变就遮住路线端点。
    var viewportInsets: UIEdgeInsets = UIEdgeInsets(top: 60, left: 36, bottom: 60, right: 36)
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
    /// v2.86 搜索结果标注（地图上显示所有搜索结果）
    let searchResultAnnotations: [SearchResultAnnotation]
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
    /// v2.86 点击搜索结果标注回调
    var onSearchResultSelect: ((SearchResultAnnotation) -> Void)?
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
    /// v2.19 路线途经点（WGS-84，橙色"途"标注，随卡片增删同步）
    var waypointMarks: [CLLocationCoordinate2D] = []
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
        // v2.53 关闭苹果原生路况层：本项目按高德 API 的 tmc/tmcs 自绘粗色段，
        // 两层同屏（细红线 + 粗橙带）颜色打架；高德只有一层粗色段。
        map.showsScale = true    // v2.53 左下角比例尺（视野档位收小后需要一个校验地标）
        // v2.54 底图配置集中到 MKStandardMapConfiguration，并加 emphasisStyle = .muted。
        //
        // 起因：用户实拍反馈园区里有一条"白色条纹"。实测该条宽约 5pt、
        // 中心像素 RGB≈(101,116,136)（浅蓝灰，蓝通道明显高于红绿），
        // 而旁边绿线 RGB=(107,214,117) 正好等于我们的 mainPolyline(0.42,0.84,0.46)。
        //
        // 为什么不是本项目画的：我们只有 6 类自绘线——主路线深绿13/浅绿7、备选深蓝虚线5、
        // 已走段 55% 灰12、起终点连接线 4、搜索连线黑3、足迹蓝虚线5，颜色与线宽都对不上；
        // 而且这条不在任何路线几何上（当次路线走护城路+包公大道）。
        //
        // 为什么也删不掉：MKMapView 在中国大陆的底图数据本身就是高德提供的（GCJ-02，见本文件开头
        // 第 7 行注释），这条带子是高德数据里的一条道路，由苹果的渲染层着色 ——
        // MKMapView 没有任何"按坐标删掉某个底图道路"的能力。
        // emphasisStyle = .muted 是苹果唯一能把道路/边界/建筑这类底图要素**压淡**的官方开关，
        // 也是"删除"这件事能做到的最接近的程度：路网仍在（导航要看路，不能真抹），但不再抢眼。
        // v2.60 底图强调样式 muted → default：用户实机反馈"灰呼呼看不清"。
        // muted 是苹果唯一能把道路/绿地/水系一起压淡的开关，代价就是整张图发灰、
        // 对比度低。改回 default 后道路更白、绿地更绿、水面更蓝，图层区分度明显回来
        //（历史上 muted 是为了压淡底图里一条高德色带，那条带子现在会重新显眼，取舍已记在案）。
        let cfg = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .default)
        // ① 关掉苹果原生路况层（与 v2.53 同因，迁到 configuration 上，避免两套 API 打架）
        // ① 路况层打开：用户要求对齐高德观感，主干道按拥堵程度着色
        // v2.66 用户要求删除地图上的绿色道路线：MapKit 的 showsTraffic 会把畅通路段
        // 整条染成绿色，和我们的绿色路线叠在一起，屏幕上出现两套绿。
        // 关掉后底图不再自带绿/黄/红路况着色；路况仍由我们自绘的 trafficColors 图层表达。
        cfg.showsTraffic = false
        // ② POI 白名单（v2.60 扩充）：原来只留 6 类刚需，地图显得空；补上餐饮、购物、
        // 公园、酒店、银行，层次更接近高德，同时仍不放电影院/夜生活这类扎堆的类别
        cfg.pointOfInterestFilter = MapViewRepresentable.standardPOIFilter
        map.preferredConfiguration = cfg
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
            "\(tipPolygon?.count ?? 0)",
            // v2.52 已走段灰色取决于 traveledIdx，旧键不含它 —— 路况不刷新时
            // 整条路线一直是绿的，走过的部分不会变灰。按 10 个点为粒度纳入键，
            // 避免每秒全量重建上千点折线（v2.02 的性能教训）。
            navigating ? "ti:\(traveledIdx / 10)" : "ti:0"
        ]
        if let f = route.first { parts.append("\(f.latitude),\(f.longitude)") }
        if let l = route.last { parts.append("\(l.latitude),\(l.longitude)") }
        if let t = tipPolygon?.first { parts.append("\(t.latitude),\(t.longitude)") }
        return parts.joined(separator: "|")
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onLongPress = onLongPress
        context.coordinator.traveledIdx = traveledIdx
        context.coordinator.onUserMovedChanged = onUserMovedChanged
        context.coordinator.onPlaceSelect = onPlaceSelect
        context.coordinator.onPlaceLongPress = onPlaceLongPress
        context.coordinator.onCategorySelect = onCategorySelect
        context.coordinator.onSearchResultSelect = onSearchResultSelect
        context.coordinator.onMapTap = onMapTap
        context.coordinator.onRouteChoiceTap = onRouteChoiceTap
        context.coordinator.onScaleChange = onScaleChange
        context.coordinator.choiceRoutes = choiceRoutes
        context.coordinator.selectedRouteIdx = selectedRouteIdx
        context.coordinator.planning = !choiceRoutes.isEmpty && !navigating
        context.coordinator.navigating = navigating
        // v2.58 导航态底图切 flat：realistic 会给每栋建筑画出有厚度的灰色块，
        // 导航视角下满屏都是立体灰砖，看着像调试图；高德导航用的是平整浅灰。
        // 只在状态翻转时重建 configuration（每次都建会打断地图渲染）。
        let wantRealistic = !navigating
        if context.coordinator.lastRealisticElevation != wantRealistic {
            context.coordinator.lastRealisticElevation = wantRealistic
            let navCfg = MKStandardMapConfiguration(
                elevationStyle: wantRealistic ? .realistic : .flat,
                emphasisStyle: .default)
            // v2.60 翻转重建时把路况与 POI 一起补上：旧版这里漏设，
            // 导航态一进一出重建 configuration 后白名单和路况就被打回苹果默认
            navCfg.showsTraffic = false   // v2.66 同上：底图不再自带绿色道路线
            navCfg.pointOfInterestFilter = MapViewRepresentable.navPOIFilter
            map.preferredConfiguration = navCfg
        }
        // v2.86 导航态下允许旋转和倾斜手势，用户可以手动转动地图
        // （旧版直接禁掉手势，导致导航态下无法转动地图）
        map.isRotateEnabled = true
        map.isPitchEnabled = true
        context.coordinator.onMapLoad = onMapLoad
        // 定位按钮：跟随手机朝向模式（地图自动旋转 + 回中，不重置缩放级别）
        if locateTick != context.coordinator.lastLocateTick {
            context.coordinator.lastLocateTick = locateTick
            if locateTick > 0 {
                context.coordinator.userMoved = false // 恢复跟随/自动旋转
                context.coordinator.setRegionProgrammatically {
                    if navigating {
                        // v2.49 导航态手动跟随：点定位恢复"车在下方 1/3 + 前视"，
                        // 而不是系统跟随（系统跟随只能把车放正中）
                        map.userTrackingMode = .none
                        let distance = MapViewRepresentable.altitudeForScale(navScaleTarget, screenH: map.bounds.height)
                        if let loc = userLocation {
                            var cam = map.camera
                            cam.centerCoordinate = MapGeo.toGCJ(
                                MapViewRepresentable.forwardCoordinate(
                                    loc,
                                    meters: distance * MapViewRepresentable.navCameraForwardRatio,
                                    bearingDeg: heading))
                            cam.centerCoordinateDistance = distance
                            map.setCamera(cam, animated: true)
                        }
                    } else {
                        map.userTrackingMode = .followWithHeading
                    }
                }
            }
        } else if !context.coordinator.hasCentered, let loc = userLocation {
            // 首次定位：设置初始区域（v2.33 3000m→1200m：冷启动看清街道与路口，而非城市级大视野）
            context.coordinator.hasCentered = true
            context.coordinator.setRegionProgrammatically {
                map.setRegion(
                    MKCoordinateRegion(center: MapGeo.toGCJ(loc), latitudinalMeters: 1200, longitudinalMeters: 1200),
                    animated: false)
            }
        }
        // 路线全览（仅在新规划完成时触发一次，避免定位更新反复拉回；包含全部方案路线）
        //
        // v2.48：规划页上下卡片（上卡贴顶、下卡锚底）会遮住地图；
        // 旧版固定 edgePadding 60pt 让路线起终点正好落在卡片后面，用户"看不到地图上的路线"。
        // 现在：① fit 使用 viewportInsets（按当前场景卡片高度计算）
        //      ② 卡片高度测量完成（insets 变化）后，若仍在规划态则补 fit 一次，
        //         避免首次规划时卡片还没测完就用旧留白 fit。
        let planFitChanged = context.coordinator.lastFitInsets != viewportInsets
        if fitTick != context.coordinator.lastFitTick
            || (planFitChanged && !choiceRoutes.isEmpty && !navigating) {
            context.coordinator.lastFitTick = fitTick
            context.coordinator.lastFitInsets = viewportInsets
            if let tf = tipFit {
                // v1.81.1 地点信息卡：地图定位到该点（不画黄圈，卡片沉底展示）
                // v2.50 用"围绕点的小矩形 + 可视区留白"代替居中 setRegion：
                // 点会落在两张卡之间可见带的正中，而不是被底部卡片吃掉一半
                context.coordinator.setRegionProgrammatically {
                    map.setVisibleMapRect(
                        MapViewRepresentable.centerRect(MapGeo.toGCJ(tf), meters: 1200),
                        edgePadding: viewportInsets, animated: true)
                }
            } else if route.count > 1 {
                var rect = MKMapRect.null
                var pts = route
                for r in choiceRoutes { pts.append(contentsOf: r) }
                for c in MapGeo.toGCJ(pts) {
                    let p = MKMapPoint(c)
                    rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
                }
                // v2.48 规划全览固定北向上：从导航/巡航切回来时相机可能还斜着，
                // 斜着看长路线极易误判"地图上没有路线"
                map.camera.heading = 0
                map.setVisibleMapRect(rect, edgePadding: viewportInsets, animated: true)
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
                map.setVisibleMapRect(rect, edgePadding: viewportInsets, animated: true)
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
                    // v2.50 同地点卡：点落在可见带中心，不被底部搜索卡遮住
                    map.setVisibleMapRect(
                        MapViewRepresentable.centerRect(MapGeo.toGCJ(p), meters: 1200),
                        edgePadding: viewportInsets, animated: true)
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
        // v2.86 搜索结果标注（地图上显示所有搜索结果）
        var srHasher = Hasher()
        srHasher.combine(searchResultAnnotations.count)
        for a in searchResultAnnotations { srHasher.combine(a.coordinate.latitude) }
        let srKey = srHasher.finalize()
        if srKey != context.coordinator.lastSearchResultKey {
            context.coordinator.lastSearchResultKey = srKey
            // 先删掉旧的
            for a in map.annotations {
                if a is SearchResultAnnotation { map.removeAnnotation(a) }
            }
            // 再加新的
            for a in searchResultAnnotations {
                map.addAnnotation(a)
            }
        }
        // v2.87 暂时删掉红绿灯标注功能（TrafficLight不是MKAnnotation，后续再加）
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
                    // v2.50 端点改按可视区留白：旧版 setRegion 居中，黑线两端会被
                    // 顶部搜索卡 + 底部信息卡压住（用户反馈"看不到线头在哪"）
                    let a = MapGeo.toGCJ(loc)
                    let b = MapGeo.toGCJ(h.coord)
                    let pa = MKMapPoint(a)
                    let pb = MKMapPoint(b)
                    var r = MKMapRect.null
                    r = r.union(MKMapRect(x: pa.x, y: pa.y, width: 0, height: 0))
                    r = r.union(MKMapRect(x: pb.x, y: pb.y, width: 0, height: 0))
                    // 四周留 12% 呼吸位；两点重合/极近时保底 200 米，避免放大到街道级
                    let minPad = 200 * MKMapPointsPerMeterAtLatitude(a.latitude)
                    let padX = max(r.width * 0.12, minPad)
                    let padY = max(r.height * 0.12, minPad)
                    map.setVisibleMapRect(r.insetBy(dx: -padX, dy: -padY),
                                          edgePadding: viewportInsets, animated: true)
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
            // v2.58 导航态忽略聚焦指令：这条路径会同时把 userMoved 置 true，
            // 一旦在导航中执行，相机就停在浏览态 —— 车被顶到屏幕上方、
            // 下方全是身后的路，顶部提示还会被换成"继续导航"。
            if !navigating, focusTick > 0, let fc = focusCoord {
                context.coordinator.userMoved = true; context.coordinator.lastUserMovedTime = Date()
                let from = searchLinkFrom
                let dest = MapGeo.toGCJ(fc)
                context.coordinator.setRegionProgrammatically {
                    map.userTrackingMode = .none
                    // v2.60 选中地点：把「我的位置 → 目的地」整条连线装进可见区，
                    // 而不是只把目的地居中。setVisibleMapRect 会把矩形铺满
                    // （屏幕减去 viewportInsets），矩形中心 = 可见区中心，
                    // 于是连线的中点正好落在卡片上方那块地图的正中间。
                    if let from {
                        map.setVisibleMapRect(
                            MapViewRepresentable.rect(between: MapGeo.toGCJ(from), and: dest,
                                                      minSideMeters: 900),
                            edgePadding: viewportInsets, animated: true)
                    } else {
                        // v2.50 途经点定位同样按可视区留白居中，避免贴到卡片边缘
                        map.setVisibleMapRect(
                            MapViewRepresentable.centerRect(dest, meters: 600),
                            edgePadding: viewportInsets, animated: true)
                    }
                }
            }
        }
        // 地图自适应旋转：地图始终与手机朝向一致（箭头固定朝屏幕上方=手机朝向，避免双重旋转）
        // 用户手动拖动/旋转地图后暂停跟随（高德式：点定位按钮恢复）
        // v2.34 航向平滑插值：GPS course 在静止/低速时会在 ±几十度内抖动，
        // 直接赋值会导致地图每帧瞬跳旋转。改为每帧最多转 45°；掉头（>120°）直接跟随避免迟滞。
        // v2.48 规划态不跟手机朝向：规划页要看整条路线做选择，
        // 地图跟着手机转会把路线转出视野、甚至看起来"地图不见了"（高德规划页同款北向上）
        // v2.53 航向滤波重做。旧版写法「每帧最多转 45°，≤45° 直接赋值」对 GPS 抖动
        // 完全无效：course 噪声常年在 ±30°，正好落进直接赋值区间 → 一帧内瞬跳；
        // 再叠加没有低速冻结，停车等灯时地图会左右小幅摇摆。
        // 现在：
        //   ① 车速 <5 km/h 冻结航向（高德同款，静止时地图不动）
        //   ② 按时间常数 0.25s 低通逼近目标（与帧率无关，肉眼连续）
        //   ③ 偏差 <2° 视为噪声
        //   ④ 掉头（>120°）直接跟，避免长时间指错方向
        //   ⑤ 只对导航态生效：巡航态用 .followWithHeading 由系统跟手机朝向，
        //      再手动每帧写 camera.heading 会与系统跟随打架（v2.34 的平滑在巡航上就不成立）
        // v2.90 对齐高德的 2D/3D 朝向规则：
        //   3D（pitchDeg > 0）→ 车头向上，地图随行进方向/手机朝向旋转；
        //   2D（pitchDeg == 0） → 正北向上，地图**固定不转**。
        // 高德 2D 导航截图（n1/n4）里地图文字都是水平的、路线斜向，就是北向上。
        // 旧版这里不分 2D/3D，2D 也照样每帧写 camera.heading ——
        // 用户点"2D"之后地图还在跟着手机转，等于这个按钮只换了俯角没换朝向规则。
        if navigating, !context.coordinator.userMoved, pitchDeg <= 0 {
            // 2D：只在俯角刚切到 0 或朝向还不是正北时纠正一次，之后不动
            if abs(map.camera.heading) > 0.5 {
                context.coordinator.setRegionProgrammatically {
                    map.camera.heading = 0
                }
            }
            context.coordinator.lastAppliedHeading = 0
            context.coordinator.lastHeadingTickAt = Date()
        } else if !context.coordinator.userMoved && navigating {
            let target = CLLocationDirection(heading)
            let now = Date()
            let dt = max(0.016, min(0.5, now.timeIntervalSince(context.coordinator.lastHeadingTickAt)))
            context.coordinator.lastHeadingTickAt = now
            // MKUserLocation 本身没有 speed，速度在它的 CLLocation 上（未定位时 location 为 nil）
            let mps = map.userLocation.location?.speed ?? -1
            let moving = mps > 1.4 || mps < 0   // <5 km/h 冻结；负值表示速度无效，按行驶处理
            if moving || context.coordinator.lastAppliedHeading == nil {
                var cur = context.coordinator.lastAppliedHeading ?? target
                var d = target - cur
                while d > 180 { d -= 360 }
                while d < -180 { d += 360 }
                if abs(d) > 120 {
                    cur = target
                } else if abs(d) >= 2 {
                    let k = min(1.0, dt / 0.25)
                    cur += d * k
                }
                cur = (cur.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
                context.coordinator.lastAppliedHeading = cur
            }
            if let applied = context.coordinator.lastAppliedHeading,
               abs(applied - context.coordinator.lastWrittenHeading) > 1 {
                context.coordinator.lastWrittenHeading = applied
                map.camera.heading = applied
            }
        }
        // v2.88 用户平移地图后 1 秒自动回跟随模式（导航态+巡航态）
        if (navigating || cruise), context.coordinator.userMoved,
           Date().timeIntervalSince(context.coordinator.lastUserMovedTime) > 1,
           let loc = userLocation {
            context.coordinator.userMoved = false
            let screenH = map.bounds.height
            let distance = MapViewRepresentable.altitudeForScale(navScaleTarget, screenH: screenH)
            let heading = map.camera.heading
            context.coordinator.setRegionProgrammatically {
                // 恢复跟随：把相机移回跟随位置
                map.userTrackingMode = .followWithHeading
                var cam = map.camera
                cam.centerCoordinate = MapGeo.toGCJ(
                    navigating
                        ? MapViewRepresentable.forwardCoordinate(
                            loc,
                            meters: distance * MapViewRepresentable.navCameraForwardRatio,
                            bearingDeg: heading)
                        : loc)
                cam.centerCoordinateDistance = distance
                cam.pitch = CGFloat(pitchDeg > 0 ? pitchDeg : 45)
                map.setCamera(cam, animated: true)
            }
        }
        // v2.32 MapKit 3D 俯视加固：部分机型在 followWithHeading 下会把 pitch 重置回 0
        // （MapKit known issue：3D 相机由系统接管）。导航态每 ≥3 秒检测一次，
        // 俯角被吞（<30°）就恢复 45°；不打断手势、不每次刷新。
        if (navigating || cruise), pitchDeg > 0, !context.coordinator.userMoved,
           Date().timeIntervalSince(context.coordinator.lastPitchRestoreAt) > 3,
           map.camera.pitch < 30 {
            context.coordinator.lastPitchRestoreAt = Date()
            context.coordinator.setRegionProgrammatically {
                var cam = map.camera
                cam.pitch = 45
                map.camera = cam
            }
        }
        // v2.87 3D 视角自动切换：只在巡航态自动切换，导航态保持 3D（尊重用户手势）
        if cruise, !navigating, !context.coordinator.userMoved,
           Date().timeIntervalSince(context.coordinator.lastPitchAutoSwitchAt) > 2 {
            let alt = map.camera.altitude
            var targetPitch: CGFloat = 0
            if alt < 500 {
                targetPitch = 45
            } else if alt > 1000 {
                targetPitch = 0
            } else {
                // 500~1000m 之间线性过渡
                let ratio = (1000 - alt) / 500
                targetPitch = CGFloat(45 * ratio)
            }
            // 差值大于 5 度才改，避免频繁刷新
            if abs(map.camera.pitch - targetPitch) > 5 {
                context.coordinator.lastPitchAutoSwitchAt = Date()
                context.coordinator.setRegionProgrammatically {
                    var cam = map.camera
                    cam.pitch = targetPitch
                    map.camera = cam
                }
            }
        }
        // v1.81 地点查看：强制北向上一次（暂停朝向跟随，避免下一帧转回）
        if northUpTick != context.coordinator.lastNorthUpTick {
            context.coordinator.lastNorthUpTick = northUpTick
            if northUpTick > 0 {
                context.coordinator.userMoved = true; context.coordinator.lastUserMovedTime = Date()
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
            // v2.49 切档不抢跟随：用户拖开地图看路况时只换比例尺，不把画面拽回来
            // （旧版这里把 userMoved 置 false 并重设 followWithHeading，速度一变地图就自己跳回）
            if navScaleTick > 0, let loc = userLocation, !context.coordinator.userMoved {
                let screenH = map.bounds.height
                // v2.28：用真实物理尺寸换算（不再用 ptPerCm=38 硬编码）
                let distance = MapViewRepresentable.altitudeForScale(navScaleTarget, screenH: screenH)
                context.coordinator.setRegionProgrammatically {
                    // v2.49 导航态改手动跟随（.none）：相机中心放在车前 35% 视距，
                    // 车落在屏幕下方 1/3，前方视野比"车居中"多约 40%（高德同款）
                    map.userTrackingMode = .followWithHeading
                    var cam = map.camera
                    cam.centerCoordinate = MapGeo.toGCJ(
                        navigating
                            ? MapViewRepresentable.forwardCoordinate(
                                loc,
                                meters: distance * MapViewRepresentable.navCameraForwardRatio,
                                bearingDeg: heading)
                            : loc)
                    // v2.28：用 centerCoordinateDistance（相机到地图中心的地面距离），
                    // 不用 altitude（相机到地面的垂直高度）——
                    // 有俯角（pitch=45°）时两者不相等，而 altitudeForScale
                    // 算出来的是"中心点的地面距离"，必须用同一个量才准。
                    cam.centerCoordinateDistance = distance
                    // v2.92 修复：pitchDeg = 0（2D 模式）时 cam.pitch 应该是 0，不是 45
                    // 旧版写的是 pitchDeg > 0 ? pitchDeg : 45，导致 2D 模式下俯角还是 45°，
                    // 等于"2D 按钮只换了朝向规则、没换俯角"，名不副实。
                    cam.pitch = CGFloat(pitchDeg)
                    // v2.49 平滑过渡：档位切换用 MapKit 动画，不再瞬跳（旧版直接赋值，画面硬切）
                    map.setCamera(cam, animated: true)
                }
            }
        }
        // v2.86 导航态：手指缩放地图查看路线时自动变2D，速度起来时自动变3D
        if navigating {
            var targetPitch: CGFloat = CGFloat(pitchDeg)
            if context.coordinator.userMoved {
                // 用户手动移图/缩放 → 自动切2D
                targetPitch = 0
            } else if context.coordinator.navActive, userLocation != nil {
                // 跟随中且速度起来 → 自动切3D
                targetPitch = 45
            }
            if abs(map.camera.pitch - targetPitch) > 1 {
                var cam = map.camera
                cam.pitch = targetPitch
                map.setCamera(cam, animated: true)
            }
        }
        // v2.65 导航首帧定点：进入导航那一刻必须把相机放到车上。
        // 旧版只靠 navigateFollowTick 变化 + 4m 位移阈值触发，若 tick 没变或定位还没回调，
        // 相机就停在规划页那个"全程全览"的位置 —— 视野几公里宽，车缩成看不见的点。
        if navigating != context.coordinator.lastNavigatingState {
            context.coordinator.lastNavigatingState = navigating
            context.coordinator.userMoved = false
            // v2.77 关键修复：进入导航时定位往往还没回调（userLocation 是 nil），
            // 旧版这里 if navigating, let loc = userLocation 直接把这次机会吞掉了 ——
            // 边沿检测已经消费完、标志不会再翻转，相机就永久停在规划页那个"全程全览"
            // 位置：视野几公里宽，车缩在屏幕底部 78% 处，前方一大片空白什么都没有。
            // 用户反馈的"导航开始如图所示"就是这一帧。
            // 改成只"记意图"，真正的对准推迟到定位第一次可用的那一帧。
            context.coordinator.pendingNavSnap = navigating
        }
        context.coordinator.navActive = navigating
        context.coordinator.cruise = cruise
        if context.coordinator.pendingNavSnap, navigating, let loc = userLocation {
            context.coordinator.pendingNavSnap = false
            let sh = map.bounds.height > 200 ? map.bounds.height : UIScreen.main.bounds.height
            // v2.82 刚进导航时 navScaleTarget 往往还带着规划页"全程全览"的档位
            //（一次几公里），用它对准车 = 车缩成一个小点，用户看到的就是"一进导航
            //自动变成了全览"。首帧一律不超过第二紧档（400 m 视野）。
            let scale = min(navScaleTarget, AppModel.navScaleSteps[1])
            let distance = MapViewRepresentable.altitudeForScale(scale, screenH: sh)
            var cam = map.camera
            // v2.83 对齐高德"开始导航"的入戏方式：
            //  ① 首帧就直接按前移比例把车放到屏幕下部（旧版先居中、下一个定位回调
            //    再跳下去，用户看到的是两级跳变 —— 这也是"导航态乱跳"的一部分）；
            //  ② 用动画过渡而不是瞬切。高德从规划页的俯视全览“飞”进跟随视角，
            //    全程约半秒；瞬切会让人觉得画面被硬拽了一下。
            let fwd = MapViewRepresentable.forwardCoordinate(
                loc,
                meters: distance * MapViewRepresentable.navCameraForwardRatio,
                bearingDeg: heading)
            cam.centerCoordinate = MapGeo.toGCJ(fwd)
            cam.centerCoordinateDistance = distance
            // v2.92 修复：同上述 bug
            // v2.87 恢复默认 45 度逻辑：pitchDeg=0 时默认 3D 45度
            cam.pitch = CGFloat(pitchDeg > 0 ? pitchDeg : 45)
            // v2.87 取消两段式入戏动画：导航开始直接进入跟随视角，不先全览再飞入
            context.coordinator.navIntroInProgress = false
            context.coordinator.setRegionProgrammatically {
                map.userTrackingMode = .none
                map.setCamera(cam, animated: true)
            }
        }
        // 导航跟随：导航开始/结束/到达时进入跟随（高德式：地图随车移动+自动旋转）
        if navigateFollowTick != context.coordinator.lastNavFollowTick {
            context.coordinator.lastNavFollowTick = navigateFollowTick
            context.coordinator.userMoved = false
            if let loc = userLocation {
                context.coordinator.navLastFollow = loc
            }
            // v2.89 入戏两段式期间只更新 tick，不动相机（否则第一段的全览会被当场顶掉）
            if !context.coordinator.navIntroInProgress {
            context.coordinator.setRegionProgrammatically {
                // v2.49 导航态用手动跟随（车位置下移），非导航态保持系统朝向跟随
                map.userTrackingMode = .followWithHeading
                if navigating {
                    // v2.88 导航态直接用系统的 followWithHeading，自动实时跟随，流畅不卡顿
                    map.userTrackingMode = .followWithHeading
                    var cam = map.camera
                    cam.pitch = CGFloat(pitchDeg > 0 ? pitchDeg : 45)
                    let distance = MapViewRepresentable.altitudeForScale(navScaleTarget,
                                                                        screenH: map.bounds.height)
                    cam.centerCoordinateDistance = distance
                    map.camera = cam
                } else {
                    // v2.33 退出导航/到达/清路线：回 2D 平视，导航 45° 俯视不残留
                    // （到达终点分支此前没把 pitchDeg 置 0，地图会一直停在俯视视角）
                    var cam = map.camera
                    cam.pitch = 0
                    map.camera = cam
                }
            }
            }
        }
        // v2.88 导航态跟随用系统 followWithHeading，不用手动定时更新了，更流畅
        // v1.81.4 导航中全览：缩放显示当前路线全程，暂停跟随（取消/固定恢复由 navigateFollowTick 接管）
        if overviewTick != context.coordinator.lastOverviewTick {
            context.coordinator.lastOverviewTick = overviewTick
            if overviewTick > 0, route.count > 1 {
                context.coordinator.userMoved = true; context.coordinator.lastUserMovedTime = Date()
                // v2.88 全览时关闭跟随，防止系统自动更新位置导致乱跳
                map.userTrackingMode = .none
                var rect = MKMapRect.null
                for c in MapGeo.toGCJ(route) {
                    let p = MKMapPoint(c)
                    rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
                }
                context.coordinator.setRegionProgrammatically {
                    map.setVisibleMapRect(rect, edgePadding: viewportInsets, animated: true)
                }
            }
        }
        // v2.22 用户手动移动地图 → 通知业务层（提示卡收起，只留"继续导航"）
        if navigating, context.coordinator.userMoved != context.coordinator.lastUserMovedFlag {
            context.coordinator.lastUserMovedFlag = context.coordinator.userMoved
            onUserMovedChanged?(context.coordinator.userMoved)
        }
        // v2.53 取消"拖动后开够 100m 自动拉回"：高德导航里拖开地图会停在浏览态、
        // 由用户点底部"继续导航"返回（ContentView 已有该按钮，navUserMoved 驱动）。
        // 40 km/h 开 100m 只要 9 秒 —— 用户刚拖开看前方路况就被拽回去；
        // 而且回跳只重设了 center/distance，pitch/heading 沿用旧值，动画途中会斜着飞。
        if navigating, !context.coordinator.userMoved, let loc = userLocation {
            // v2.49 手动跟随：坐标移动超过 4m 才挪相机（定位回调 1Hz，足够平滑；
            // 避免每次 updateUIView 都重设相机造成画面抖动）
            let last = context.coordinator.navLastFollow
            let movedM = last.map {
                CLLocation(latitude: loc.latitude, longitude: loc.longitude)
                    .distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
            } ?? .greatestFiniteMagnitude
            context.coordinator.navLastFollow = loc
            if !context.coordinator.userMoved, movedM > 4, map.userTrackingMode == .none {
                // v2.82 同一条约束：跟随接管时若档位还没被 autoNavScaleTarget 收敛，
                // 也会用全览档位，视野突然拉远。这里同样夹到第二紧档以内。
                let distance = MapViewRepresentable.altitudeForScale(
                    min(navScaleTarget, AppModel.navScaleSteps[1]), screenH: map.bounds.height)
                let fwd = MapViewRepresentable.forwardCoordinate(
                    loc,
                    meters: distance * MapViewRepresentable.navCameraForwardRatio,
                    bearingDeg: heading)
                context.coordinator.setRegionProgrammatically {
                    var cam = map.camera
                    cam.centerCoordinate = MapGeo.toGCJ(fwd)
                    // v2.62 补距离：旧版这里只挪中心不设距离，相机沿用的是上一次
                    // 的视距（规划页全览 2 公里 / 上一档位），车会被缩成看不见的小点，
                    // 或直接被推出屏幕 —— "导航开始看不到当前位置"的另一半原因。
                    cam.centerCoordinateDistance = distance
                    if pitchDeg > 0 { cam.pitch = CGFloat(pitchDeg) }
                    map.setCamera(cam, animated: true)
                }
            }
        }
        // v1.84 巡航模式：进入时缩放巡航视野（约 2000m 高，平视），随后定位点跟随（GPS 抖动 >25m 才更新相机）
        if cruise != context.coordinator.lastCruise {
            context.coordinator.lastCruise = cruise
            if cruise, let loc = userLocation {
                context.coordinator.userMoved = false
                context.coordinator.cruiseLastLoc = loc
                context.coordinator.setRegionProgrammatically {
                    var cam = map.camera
                    cam.centerCoordinate = MapGeo.toGCJ(loc)
                    // v2.86 巡航模式视野改小，匹配截图里比例尺250米的大小
                    cam.altitude = 800
                    cam.pitch = 30    // 巡航模式也带一点3D视角，更像高德
                    map.camera = cam
                }
            }
        } else if !context.coordinator.userMoved, cruise, cruiseTick != context.coordinator.lastCruiseTick {
            context.coordinator.lastCruiseTick = cruiseTick
            if let loc = userLocation {
                let last = context.coordinator.cruiseLastLoc
                if last == nil ||
                    CLLocation(latitude: loc.latitude, longitude: loc.longitude)
                        .distance(from: CLLocation(latitude: last!.latitude, longitude: last!.longitude)) > 5 {
                    context.coordinator.cruiseLastLoc = loc
                    context.coordinator.setRegionProgrammatically {
                        // v2.53 巡航前视偏移：车不再钉在正中，前移 20% 当前视距（导航为 35%）
                        var cam = map.camera
                        let d = cam.centerCoordinateDistance
                        cam.centerCoordinate = MapGeo.toGCJ(
                            MapViewRepresentable.forwardCoordinate(
                                loc, meters: d * 0.2, bearingDeg: heading))
                        map.camera = cam
                    }
                }
            }
        }
        // v2.34 E2 巡航跟随尊重用户平移：手动拖动/旋转地图后暂停拉回中心（同导航），
        // 点右下角定位按钮恢复跟随（locateTick 通用机制）。
        // v2.01 俯仰角由 AppModel.pitchDeg 驱动（导航开始 45°，退出 0°，右侧 3D 按钮切换）
        if pitchDeg != context.coordinator.lastPitchDeg {
            context.coordinator.lastPitchDeg = pitchDeg
            // v2.53 上限 70°→55°：3D 俯角越大地名/路名拉伸越严重，55° 是可读上限
            let target = CGFloat(max(0, min(55, pitchDeg)))
            context.coordinator.setRegionProgrammatically {
                var cam = map.camera
                cam.pitch = target
                map.camera = cam
            }
        }
        // v1.63 深色模式：导航中强制深色底图（高德夜间效果）；非导航跟随外观设置
        // v2.12：外观可手动切换（自动/浅色/深色），这里跟随 SwiftUI 的 colorScheme
        // v2.37 G5 导航不再强制深色：白天浅色外观下导航用浅色地图，
        // 与浅色底卡（systemBackground）统一，不再"白卡叠黑图"；深色外观仍深色
        let wantDark = colorScheme == .dark
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
        var onPlaceSelect: ((PlaceLabel) -> Void)?
        var onPlaceLongPress: ((PlaceLabel) -> Void)?
        var onCategorySelect: ((AppModel.CategoryResult) -> Void)?
        var onSearchResultSelect: ((SearchResultAnnotation) -> Void)?
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
            // v2.56 比例尺改成「屏幕上 58pt 两端点转坐标后算真实地面距离」。
            //
            // 旧版用 centerCoordinateDistance / (bounds.height/2) 推每 pt 米数。
            // 那个公式只在 pitch=0 时成立；导航态 pitch=45° 时，相机到中心的是「斜距」，
            // 直接除以屏幕半高会把比例尺算大好几倍 —— 实机上导航态真实前方约 300 米，
            // 比例尺却标成「5 公里」，看着像视野远得离谱，实际画面并不远。
            //
            // convert(_:toCoordinateFrom:) 是 MapKit 自己的投影，pitch / heading / 机型都无关，
            // 拿到的就是这条 58pt 线在屏幕中央位置真正跨过的地面距离。
            let midY = Double(map.bounds.midY)
            let x0 = Double(map.bounds.minX) + 40
            let p0 = map.convert(CGPoint(x: x0, y: midY), toCoordinateFrom: map)
            let p1 = map.convert(CGPoint(x: x0 + 58, y: midY), toCoordinateFrom: map)
            let target = CLLocation(latitude: p0.latitude, longitude: p0.longitude)
                .distance(from: CLLocation(latitude: p1.latitude, longitude: p1.longitude))
            guard target > 0, target.isFinite else { return }
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
        /// v2.52 导航态（渲染器按它加粗路线：导航中视距更远，9pt 线在 3D 下太细）
        var navigating = false
        /// v1.69 地图加载回调（MKMapView 渲染完成/失败）
        var onMapLoad: ((Bool, String) -> Void)?
        /// v1.69 重载计数记忆
        var lastReloadTick = 0
        /// 是否已做过首次定位居中
        var hasCentered = false
        /// 定位/全览/预览请求记忆（只响应新请求，避免定位更新反复重置地图）
        var lastLocateTick = 0
        var lastFitTick = 0
        /// v2.48 上次全览用的留白（卡片高度测量完成后触发一次补 fit）
        var lastFitInsets: UIEdgeInsets? = nil
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
        // v2.32 MapKit 3D 俯视加固：导航态节流检查 pitch 是否被系统重置
        var lastPitchRestoreAt = Date.distantPast
        var lastPitchAutoSwitchAt = Date.distantPast
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
        /// v2.58 记录上次设置的底图高度样式，避免每帧重建 configuration
        var lastRealisticElevation: Bool?
        /// v2.65 上一次的导航态：用于"进入导航首帧必须对准车"的边沿检测
        var lastNavigatingState = false
        /// v2.77 "等定位就绪再对准车"的待办标志
        var pendingNavSnap = false
        /// v2.89 开始导航的"全览 → 飞入"两段式动画进行中：
        /// 期间 navigateFollowTick 只记账、不改相机，否则飞行视角会当场被跟随视角顶掉。
        var navIntroInProgress = false
        /// 当前是否仍在导航（延迟回调里用它确认用户没中途退出）
        var navActive = false
        var cruise = false
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
        /// v2.86 航向记忆（只在变化超过1°时更新相机）
        var lastWrittenHeading: Double = 0
        /// v2.01 比例尺上次文本（只在变化时回调，避免每帧刷新 SwiftUI）
        var lastScaleText = ""
        /// v2.02 折线重建键（内容不变就不重建，避免闪烁/卡顿）
        var lastRouteKey = ""
        /// v2.12 标注同步键：加油站/地名/类别内容不变就整段跳过，
        /// 避免每秒多次全表扫描（原来一帧要几十万次比较，是地图页卡顿的主因）
        var lastGasKey: Int?
        var lastPlaceKey: Int?
        var lastCatKey: Int?
        var lastSearchResultKey = 0
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
        /// v2.87 用户最后一次手动移图的时间，3秒后自动回跟随
        var lastUserMovedTime = Date.distantPast
        /// 导航跟随触发记忆
        var lastNavFollowTick = 0
        var lastNavFollowUpdateAt = Date()
        var lastOverviewTick = 0
        /// 导航中最后跟随位置（开远自动拉回）
        var navLastFollow: CLLocationCoordinate2D?
        /// v2.34 自车航向平滑：上一次实际应用的 camera.heading，避免 GPS course 抖动导致地图瞬跳旋转
        var lastAppliedHeading: CLLocationDirection?
        /// v2.53 航向滤波的时间基准（算 dt 用，保证与帧率无关）
        var lastHeadingTickAt = Date()
        /// 程序主动设置区域（避免被标记为用户移动）
        /// v2.29 程序化移动标志：**计数器**（原来是 Bool）
        ///
        /// 旧实现用 Bool，有真实的失衡：
        /// 一次 setRegionProgrammatically 里往往做了**两件**会各自触发 region 事务的事
        /// （比如 `map.userTrackingMode = .followWithHeading` 和 `map.camera = cam`），
        /// MapKit 是否把它们合并成一个事务并不确定 ——
        /// 不合并时，第二个 regionDidChange 回调撞上 Bool 已被消费的状态，
        /// 走进 `else if !animated` 分支 → **误判成"用户手动移了地图"**（userMoved = true; lastUserMovedTime = Date()）。
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
            userMoved = true; lastUserMovedTime = Date()
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
            guard gesture.state == .began else { return }
            // 命中地点名标签 → 地点信息卡；否则空白长按
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
                // 其它标注（起终点/加油站）维持原样：吞掉点击，不当作空白
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

        /// v2.84 手指落下前的画面中心，用来判断这次到底"真拖动"了没有
        var panStartCenter: CLLocationCoordinate2D?
        var panStartSpan: MKCoordinateSpan?

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            panStartCenter = mapView.centerCoordinate
            panStartSpan = mapView.region.span
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            scheduleScale(mapView)   // v2.02 地图稳定后再算比例尺（去抖，避免每帧改状态）
            // v2.86 3D视角自动切换：缩放够近时自动从2D变45度3D，缩放够远时变回去
            // 巡航和导航跟随模式下生效
            if navActive || cruise {
                let altitude = mapView.camera.centerCoordinateDistance
                var targetPitch: CGFloat = 45
                if altitude > 1000 {
                    // 视野远 → 2D（90度俯视）
                    targetPitch = 0
                } else if altitude < 500 {
                    // 视野近 → 3D（45度）
                    targetPitch = 45
                } else {
                    // 中间区间线性过渡
                    let t = (1000 - altitude) / 500.0  // 0=1000m(2D), 1=500m(3D)
                    targetPitch = CGFloat(t * 45)
                }
                if abs(mapView.camera.pitch - targetPitch) > 2 {
                    var cam = mapView.camera
                    cam.pitch = targetPitch
                    mapView.setCamera(cam, animated: true)
                }
            }
            // 程序 setRegion 触发时不标记用户移动
            if consumeProgrammaticMove() {
                // 程序化移动，正常
            } else if !animated {
                // v2.84 旧版只要不是程序化移动就立刻 userMoved = true; lastUserMovedTime = Date() ——
                // 手指在地图上碰一下、只挪几个像素，也算"浏览态"：
                // 底卡整张消失、冒出一个"继续导航"，松手 8 秒后又自动收回去。
                // 反复碰几下就是用户看到的"界面乱跳"。
                // 现在要求真正移动过才进浏览态：中心移动 > 40 m，或缩放幅度 > 15%。
                if let c0 = panStartCenter, let s0 = panStartSpan {
                    let moved = CLLocation(latitude: c0.latitude, longitude: c0.longitude)
                        .distance(from: CLLocation(latitude: mapView.centerCoordinate.latitude,
                                                   longitude: mapView.centerCoordinate.longitude))
                    let zoomed = s0.latitudeDelta > 0
                        && abs(mapView.region.span.latitudeDelta - s0.latitudeDelta) / s0.latitudeDelta > 0.15
                    if moved > 40 || zoomed { userMoved = true; lastUserMovedTime = Date() }
                } else {
                    userMoved = true; lastUserMovedTime = Date()
                }
            }
            panStartCenter = nil
            panStartSpan = nil
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

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            // 点击标注：取消系统选中态（避免遮挡）
            if let pla = view.annotation as? PlaceAnnotation {
                mapView.deselectAnnotation(view.annotation, animated: false)
                onPlaceSelect?(pla.place)
            } else if let ca = view.annotation as? CategoryAnnotation {
                mapView.deselectAnnotation(view.annotation, animated: false)
                onCategorySelect?(ca.result)
            } else if let sra = view.annotation as? SearchResultAnnotation {
                mapView.deselectAnnotation(view.annotation, animated: false)
                onSearchResultSelect?(sra)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            // v2.87 车道箭头标注
            if let lane = annotation as? LaneArrowAnnotation {
                let id = "laneArrow"
                var v = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                if v == nil {
                    v = MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                }
                v?.annotation = annotation
                v?.canShowCallout = false
                v?.image = UIImage(systemName: "arrow.up")?.withTintColor(.white, renderingMode: .alwaysOriginal)
                v?.transform = CGAffineTransform(rotationAngle: CGFloat(lane.heading * .pi / 180))
                return v
            }
            // v2.87 加油站标注
            if annotation is GasAnnotation {
                let id = "gas"
                var v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                if v == nil {
                    v = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                }
                v?.annotation = annotation
                v?.canShowCallout = false
                v?.markerTintColor = .systemGreen
                v?.glyphText = "⛽"
                v?.displayPriority = .defaultLow
                return v
            }
            // v2.86 搜索结果标注
            if annotation is SearchResultAnnotation {
                let id = "searchResult"
                var v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                if v == nil {
                    v = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                }
                v?.annotation = annotation
                v?.canShowCallout = false
                v?.markerTintColor = .systemBlue
                v?.glyphText = String(describing: (annotation as! SearchResultAnnotation).index + 1)
                v?.displayPriority = .required
                return v
            }
            // 当前位置：缩小版指南针图标（玻璃圆底 + 红色指北针）
            if annotation is MKUserLocation {
                // v2.62 导航态换蓝色箭头：旧的指南针图标在 3D 灰楼块上几乎看不见，
                // 用户实机反馈"导航态看不到当前位置"。两种态用不同 reuse id，
                // 避免复用时 image 不刷新。
                let navMode = self.navigating
                let id = navMode ? "userLocNav" : "userLoc"
                var v = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                if v == nil {
                    v = MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                }
                v?.image = navMode ? MapViewRepresentable.makeUserArrow()
                                   : MapViewRepresentable.makeUserIcon()
                // v2.62 不再手写 frame：MapKit 会按 image 尺寸改写它，
                // 手设的 44x44 会被打回 40x40，反而让图标在 offsets 上错位
                v?.centerOffset = .zero
                v?.canShowCallout = false
                // v2.62 导航态必显：俯角 45° 时 3D 建筑会把定位点压到楼下，
                // 用户实机"导航刚开始看不到当前位置"多半就是这条。
                // required 保证它永远不被别的标注挤掉，zPosition 保证盖在楼块之上。
                v?.displayPriority = .required
                v?.layer.zPosition = 1000
                v?.isEnabled = true
                return v
            }
            if let re = annotation as? RouteEndAnnotation {
                // v2.86 删除起终点入口箭头，改为路线上显示白色大箭头
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
                // v2.58 搜索目的地改脉冲标注：绿圆 + 白勾 + 下方"搜索目标"标签 + 外圈呼吸扩散环
                let id = "previewPulse"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? PulseHitAnnotationView
                    ?? PulseHitAnnotationView(annotation: pa)
                v.annotation = pa
                v.canShowCallout = false
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
            return nil
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let poly = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: poly)
                r.lineCap = .round
                // v1.99 路况分段优先着色（缓行黄 / 拥堵红）
                if let ti = self.trafficPolylines.firstIndex(where: { $0 === poly }) {
                    // 防御：数组若因并发/重建短暂不同步，越界会直接崩（crash 日志里的常见项）
                    r.strokeColor = ti < self.trafficColors.count ? self.trafficColors[ti] : UIColor.systemOrange
                    r.lineWidth = self.navigating ? 9 : 7
                    return r
                }
                if poly === self.traveledPolyline {
                    // v2.22 已走过的路段：灰色实线（未走的保持草绿）
                    // v2.54 参照高德把已走段压细压淡：12→6pt、0.55→0.42 灰、alpha 0.95→0.8。
                    // 原先与主路线同宽(12pt)的白灰在深色底图上是全屏最抢眼的一条，观感像"灰色条纹"，
                    // 高德的已走段只是很细很淡的一条，几乎不抢视线。
                    // v2.93 已走路段再调淡一档：0.42→0.6 灰、0.8→0.5 alpha，更不抢眼
                    r.strokeColor = UIColor(white: 0.6, alpha: 0.5)
                    r.lineWidth = self.navigating ? 5 : 4
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
                    // v2.52 导航态加粗到 13/7（高德导航路线约 12~14pt；规划态保持 9/5）
                    r.lineWidth = self.navigating ? 13 : 9
                } else if poly === self.mainPolyline {
                    // 推荐路线：浅绿内芯（高德绿路线双线效果）
                    r.strokeColor = UIColor(red: 0.42, green: 0.84, blue: 0.46, alpha: 1.0)
                    r.lineWidth = self.navigating ? 7 : 5
                } else if self.alternatePolylines.contains(where: { $0 === poly }) {
                    // v2.71 备选路线改高德风：中性灰细实线，主动"退到背景层"。
                    // 旧版是深蓝 + 虚线，看着像施工绕行或禁行路段，两条备选并排时
                    // 蓝虚线比绿主路线还抢眼，主次完全颠倒。
                    // 高德的做法正好相反：备选只是一条淡淡的灰线，靠"主路线是彩色的"来区分。
                    // v2.85 备选路线改成浅天蓝
                    r.strokeColor = self.navigating
                        ? UIColor(red: 0.7, green: 0.88, blue: 1.0, alpha: 0.7)
                        : UIColor(red: 0.53, green: 0.81, blue: 0.98, alpha: 0.85)
                    r.lineWidth = 3.5
                    r.lineDashPattern = nil
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
/// v2.58 搜索目的地标注：绿圆 + 白勾 + "搜索目标"标签。
/// v2.89 按用户要求删除外圈脉冲环（连静态环一起），只留圆点与标签。
final class PulseHitAnnotationView: MKAnnotationView {
    private let dotView = UIImageView()
    private let label = UILabel()
    private static let dotSide: CGFloat = 34
    private static let canvasW: CGFloat = 108
    private static let canvasH: CGFloat = 78

    init(annotation: MKAnnotation?) {
        super.init(annotation: annotation, reuseIdentifier: "previewPulse")
        frame = CGRect(x: 0, y: 0, width: Self.canvasW, height: Self.canvasH)
        backgroundColor = .clear
        isOpaque = false
        let dotCenterY = Self.dotSide / 2 + 2
        centerOffset = CGPoint(x: 0, y: dotCenterY - Self.canvasH / 2)

        // 不用 MKAnnotationView.image：一旦设了 image，MapKit 会按图片尺寸改写 frame，
        // 108×78 的画布会被压成 34×34，标签就没地方放了。
        dotView.image = Self.makeDot()
        dotView.contentMode = .scaleAspectFit
        addSubview(dotView)

        label.text = "搜索目标"
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = UIColor(white: 0.15, alpha: 1)
        label.textAlignment = .center
        label.backgroundColor = UIColor.white.withAlphaComponent(0.92)
        label.layer.cornerRadius = 5
        label.layer.masksToBounds = true
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func makeDot() -> UIImage {
        let side: CGFloat = 34
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { _ in
            let rect = CGRect(x: 1.5, y: 1.5, width: side - 3, height: side - 3)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: (side - 3) / 2)
            UIColor(red: 0.13, green: 0.72, blue: 0.36, alpha: 1.0).setFill()
            path.fill()
            UIColor.white.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 2
            path.stroke()
            let cfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)
            if let check = UIImage(systemName: "checkmark", withConfiguration: cfg)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                let sz = check.size
                check.draw(at: CGPoint(x: (side - sz.width) / 2, y: (side - sz.height) / 2))
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let cx = bounds.midX
        let cy = Self.dotSide / 2 + 2
        dotView.frame = CGRect(x: cx - Self.dotSide / 2, y: cy - Self.dotSide / 2,
                               width: Self.dotSide, height: Self.dotSide)
        let tw = min(bounds.width, label.intrinsicContentSize.width + 10)
        label.frame = CGRect(x: (bounds.width - tw) / 2, y: cy + Self.dotSide / 2 + 3, width: tw, height: 17)
    }

    // v2.89 按用户要求删除"呼吸脉冲"循环动画：
    // 旧版外圈每 1.7 秒从 0.96 倍扩到 2.1 倍并淡出、无限循环，
    // 骑行时余光里一直有个东西在闪，比静态标注更抢注意力。
    // 现在外圈环保持静态（作为"搜索目标"的视觉强调），不再动。

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
    }

    // v2.89 脉冲环删除后这里没有需要复位的状态，prepareForReuse 一并去掉
}

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
    /// v2.62 导航态定位箭头：蓝色实心箭头 + 白色描边 + 淡投影，
    /// 保证在 45° 俯视、灰色建筑块、绿色路线三种背景上都一眼可见。
    static func makeUserArrow() -> UIImage {
        let size: CGFloat = 46
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            let c = ctx.cgContext
            // 白色描边底
            let white = UIColor.white
            c.setFillColor(white.cgColor)
            let path = UIBezierPath()
            path.move(to: CGPoint(x: size / 2, y: 4))
            path.addLine(to: CGPoint(x: size - 8, y: size - 4))
            path.addLine(to: CGPoint(x: size / 2, y: size - 14))
            path.addLine(to: CGPoint(x: 8, y: size - 4))
            path.close()
            // 先把整体填白（描边效果）
            white.setFill()
            path.fill()
            // 再内缩填蓝
            let inner = UIBezierPath()
            let inset: CGFloat = 3.2
            inner.move(to: CGPoint(x: size / 2, y: 4 + inset * 1.6))
            inner.addLine(to: CGPoint(x: size - 8 - inset, y: size - 4 - inset * 0.6))
            inner.addLine(to: CGPoint(x: size / 2, y: size - 14))
            inner.addLine(to: CGPoint(x: 8 + inset, y: size - 4 - inset * 0.6))
            inner.close()
            UIColor(red: 0.10, green: 0.42, blue: 0.92, alpha: 1.0).setFill()
            inner.fill()
        }
    }

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



