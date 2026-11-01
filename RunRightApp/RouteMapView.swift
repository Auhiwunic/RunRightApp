//
//  RouteMapView.swift
//  ActivityTrackerApp
//

import SwiftUI
import MapKit

struct RouteMapView: UIViewRepresentable {
    let coordinates: [CLLocationCoordinate2D]
    let isTracking: Bool
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.userTrackingMode = .follow
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        return mapView
    }
    
    func updateUIView(_ mapView: MKMapView, context: Context) {
        // SwiftUI re-runs this on every tracker tick during a run. Rebuilding
        // the overlay AND calling setRegion each tick — while the map was also
        // in .follow mode — made two camera owners fight, so the Run tab map
        // zoomed in and out in a glitchy loop mid-run. Only touch the map when
        // the route actually gained points, and take camera ownership away from
        // follow mode once a route exists.
        guard coordinates.count != context.coordinator.renderedCount else { return }
        context.coordinator.renderedCount = coordinates.count

        mapView.removeOverlays(mapView.overlays)
        guard coordinates.count > 1 else { return }
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        mapView.addOverlay(polyline)

        if mapView.userTrackingMode != .none {
            mapView.setUserTrackingMode(.none, animated: false)
        }
        if let last = coordinates.last {
            let region = MKCoordinateRegion(center: last, latitudinalMeters: 300, longitudinalMeters: 300)
            mapView.setRegion(region, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var renderedCount = -1

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor(red: 0.45, green: 0.74, blue: 0.98, alpha: 1.0)
                renderer.lineWidth = 4
                renderer.lineCap = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

