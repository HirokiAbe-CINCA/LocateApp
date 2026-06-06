import CoreLocation
import LocateAppCore
import MapKit
import SwiftUI

struct MapPickerView: NSViewRepresentable {
    @Binding var coordinate: CLLocationCoordinate2D
    let activeCoordinate: Coordinate?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.pointOfInterestFilter = .includingAll

        let region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
        )
        mapView.setRegion(region, animated: false)

        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.mapClicked(_:)))
        mapView.addGestureRecognizer(click)

        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.centerMapIfNeeded(mapView)
        context.coordinator.updateAnnotation(on: mapView)
        context.coordinator.updateActiveAnnotation(on: mapView)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MapPickerView
        private let annotation = MKPointAnnotation()
        private let activeAnnotation = MKPointAnnotation()
        private var renderedCoordinate: CLLocationCoordinate2D?
        private var renderedActiveCoordinate: Coordinate?

        init(parent: MapPickerView) {
            self.parent = parent
            super.init()
        }

        @objc func mapClicked(_ recognizer: NSClickGestureRecognizer) {
            guard let mapView = recognizer.view as? MKMapView else {
                return
            }
            let point = recognizer.location(in: mapView)
            parent.coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            renderedCoordinate = parent.coordinate
            updateAnnotation(on: mapView)
        }

        func centerMapIfNeeded(_ mapView: MKMapView) {
            if let renderedCoordinate,
               abs(renderedCoordinate.latitude - parent.coordinate.latitude) < 0.000_001,
               abs(renderedCoordinate.longitude - parent.coordinate.longitude) < 0.000_001 {
                return
            }

            renderedCoordinate = parent.coordinate
            let region = MKCoordinateRegion(
                center: parent.coordinate,
                span: mapView.region.span.latitudeDelta.isFinite
                    ? mapView.region.span
                    : MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
            )
            mapView.setRegion(region, animated: true)
        }

        func updateAnnotation(on mapView: MKMapView) {
            annotation.coordinate = parent.coordinate
            annotation.title = "選択中の移動先"
            if !mapView.annotations.contains(where: { $0 === annotation }) {
                mapView.addAnnotation(annotation)
            }
        }

        func updateActiveAnnotation(on mapView: MKMapView) {
            guard let activeCoordinate = parent.activeCoordinate else {
                if mapView.annotations.contains(where: { $0 === activeAnnotation }) {
                    mapView.removeAnnotation(activeAnnotation)
                }
                renderedActiveCoordinate = nil
                return
            }

            centerMapOnActiveCoordinateIfNeeded(mapView, activeCoordinate: activeCoordinate)
            activeAnnotation.coordinate = CLLocationCoordinate2D(
                latitude: activeCoordinate.latitude,
                longitude: activeCoordinate.longitude
            )
            activeAnnotation.title = "現在の移動先"
            if !mapView.annotations.contains(where: { $0 === activeAnnotation }) {
                mapView.addAnnotation(activeAnnotation)
            }
        }

        func centerMapOnActiveCoordinateIfNeeded(_ mapView: MKMapView, activeCoordinate: Coordinate) {
            if renderedActiveCoordinate == activeCoordinate {
                return
            }

            renderedActiveCoordinate = activeCoordinate
            let coordinate = CLLocationCoordinate2D(
                latitude: activeCoordinate.latitude,
                longitude: activeCoordinate.longitude
            )
            let region = MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            )
            mapView.setRegion(region, animated: true)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation === self.annotation || annotation === activeAnnotation else {
                return nil
            }

            let isActive = annotation === activeAnnotation
            let identifier = isActive ? "active-location-pin" : "selected-location-pin"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.canShowCallout = true
            view.markerTintColor = isActive ? .systemOrange : .systemBlue
            view.glyphText = isActive ? "移" : "選"
            return view
        }
    }
}
