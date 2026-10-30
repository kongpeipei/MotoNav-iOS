import SwiftUI
import MapKit
import UIKit

/// 轻量地图封装：用户位置 + 按类型着色的点位标注 + 导航路线 + 沿途点位高亮 + 长按选点
struct MapViewRepresentable: UIViewRepresentable {
    let pois: [Poi]
    let userLocation: CLLocationCoordinate2D?
    let route: [CLLocationCoordinate2D]
    let routePois: [Poi]
    /// 定位请求计数（点击定位按钮 +1，触发地图回中）
    let locateTick: Int
    var onLongPress: ((CLLocationCoordinate2D) -> Void)?

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.showsUserLocation = true
        map.delegate = context.coordinator
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.6
        map.addGestureRecognizer(longPress)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onLongPress = onLongPress
        if let loc = userLocation {
            // locateTick 变化时强制回中；否则仅在初始/首次定位时设置区域
            if locateTick > 0 || map.region.span.latitudeDelta > 0.5 {
                map.setRegion(
                    MKCoordinateRegion(center: loc, latitudinalMeters: 3000, longitudinalMeters: 3000),
                    animated: true)
            }
        }
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
        map.removeOverlays(map.overlays)
        if route.count > 1 {
            map.addOverlay(MKPolyline(coordinates: route, count: route.count))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onLongPress: ((CLLocationCoordinate2D) -> Void)?

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                  let map = gesture.view as? MKMapView else { return }
            let pt = gesture.location(in: map)
            let coord = map.convert(pt, toCoordinateFrom: map)
            onLongPress?(coord)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
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

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}
