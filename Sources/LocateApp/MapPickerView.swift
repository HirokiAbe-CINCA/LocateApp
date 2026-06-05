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
        context.coordinator.updateFixedAnnotation(on: mapView)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MapPickerView
        private let annotation = MKPointAnnotation()
        private let fixedAnnotation = MKPointAnnotation()
        private var renderedCoordinate: CLLocationCoordinate2D?

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
            annotation.title = "Selected Location"
            if !mapView.annotations.contains(where: { $0 === annotation }) {
                mapView.addAnnotation(annotation)
            }
        }

        func updateFixedAnnotation(on mapView: MKMapView) {
            guard let activeCoordinate = parent.activeCoordinate else {
                if mapView.annotations.contains(where: { $0 === fixedAnnotation }) {
                    mapView.removeAnnotation(fixedAnnotation)
                }
                return
            }

            fixedAnnotation.coordinate = CLLocationCoordinate2D(
                latitude: activeCoordinate.latitude,
                longitude: activeCoordinate.longitude
            )
            fixedAnnotation.title = "Fixed Location"
            if !mapView.annotations.contains(where: { $0 === fixedAnnotation }) {
                mapView.addAnnotation(fixedAnnotation)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation === self.annotation || annotation === fixedAnnotation else {
                return nil
            }

            let isFixed = annotation === fixedAnnotation
            let identifier = isFixed ? "fixed-location-pin" : "selected-location-pin"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.canShowCallout = true
            view.markerTintColor = isFixed ? .systemOrange : .systemBlue
            view.glyphText = isFixed ? "F" : "S"
            return view
        }
    }
}
