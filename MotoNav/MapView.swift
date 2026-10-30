import SwiftUI
import MapKit
import UIKit

/// 轻量地图封装：用户位置 + 按类型着色的点位标注 + 导航路线 + 沿途点位高亮 + 长按选点 + 搜索预览点 + 加油站
struct MapViewRepresentable: UIViewRepresentable {
    let pois: [Poi]
    let userLocation: CLLocationCoordinate2D?
    let route: [CLLocationCoordinate2D]
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
    var onLongPress: ((CLLocationCoordinate2D) -> Void)?
    var onPoiLongPress: ((Poi) -> Void)?
    var onPoiSelect: ((Poi) -> Void)?
    var onPlaceSelect: ((PlaceLabel) -> Void)?
    var onCategorySelect: ((AppModel.CategoryResult) -> Void)?

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.showsUserLocation = true
        map.showsCompass = false // 使用自绘指南针（左上角）
        map.delegate = context.coordinator
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.6
        map.addGestureRecognizer(longPress)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onLongPress = onLongPress
        context.coordinator.onPoiLongPress = onPoiLongPress
        context.coordinator.onPoiSelect = onPoiSelect
        context.coordinator.onPlaceSelect = onPlaceSelect
        context.coordinator.onCategorySelect = onCategorySelect
        // 定位按钮：跟随手机朝向模式（地图自动旋转 + 蓝点方向指示 + 回中）
        if locateTick > 0 {
            context.coordinator.setRegionProgrammatically {
                map.userTrackingMode = .followWithHeading
                if let loc = userLocation {
                    map.setRegion(
                        MKCoordinateRegion(center: loc, latitudinalMeters: 3000, longitudinalMeters: 3000),
                        animated: true)
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
        // 路线全览
        if fitTick > 0 && route.count > 1 {
            context.coordinator.setRegionProgrammatically {
                var rect = MKMapRect.null
                for c in route {
                    let p = MKMapPoint(c)
                    rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
                }
                map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 60, left: 40, bottom: 60, right: 40), animated: true)
            }
        }
        // 加油站全览（含当前位置）
        if gasTick > 0 && !gasStations.isEmpty {
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
                a.onRoute = routePois.contains { $0.id == p.id }
            }
        }
        // 起终点标记
        let ends = Set(map.annotations.compactMap { ($0 as? RouteEndAnnotation)?.kind })
        let startPresent = ends.contains("start"), endPresent = ends.contains("end")
        if let first = route.first, !startPresent {
            map.addAnnotation(RouteEndAnnotation(kind: "start", coordinate: first))
        }
        if let last = route.last, !endPresent {
            map.addAnnotation(RouteEndAnnotation(kind: "end", coordinate: last))
        }
        if route.count < 2 {
            map.annotations
                .compactMap { $0 as? RouteEndAnnotation }
                .forEach { map.removeAnnotation($0) }
        }
        // 搜索预览点（绿色高亮）
        let previews = map.annotations.compactMap { $0 as? PreviewAnnotation }
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
        if route.count > 1 {
            map.addOverlay(MKPolyline(coordinates: route, count: route.count))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onLongPress: ((CLLocationCoordinate2D) -> Void)?
        var onPoiLongPress: ((Poi) -> Void)?
        var onPoiSelect: ((Poi) -> Void)?
        var onPlaceSelect: ((PlaceLabel) -> Void)?
        var onCategorySelect: ((AppModel.CategoryResult) -> Void)?
        /// 是否已做过首次定位居中
        var hasCentered = false
        /// 程序主动设置区域（避免被标记为用户移动）
        private var programmaticMove = false

        func setRegionProgrammatically(_ block: () -> Void) {
            programmaticMove = true
            block()
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                  let map = gesture.view as? MKMapView else { return }
            let pt = gesture.location(in: map)
            // 优先命中已有点位标注（屏幕距离 < 40pt）
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
                onPoiLongPress?(p)
                return
            }
            let coord = map.convert(pt, toCoordinateFrom: map)
            onLongPress?(coord)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // 程序 setRegion 触发时不标记用户移动
            if programmaticMove {
                programmaticMove = false
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
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
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
            // 沿途点位：白色描边高亮
            if pa.onRoute {
                v.layer.borderWidth = 2.5
                v.layer.borderColor = UIColor.white.cgColor
            } else {
                v.layer.borderWidth = 0
            }
            return v
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let poly = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: poly)
                r.strokeColor = .systemBlue
                r.lineWidth = 5
                return r
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
    let poi: Poi
    var onRoute: Bool
    init(poi: Poi, onRoute: Bool = false) {
        self.poi = poi
        self.onRoute = onRoute
        super.init()
    }
    var coordinate: CLLocationCoordinate2D { poi.coordinate }
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
