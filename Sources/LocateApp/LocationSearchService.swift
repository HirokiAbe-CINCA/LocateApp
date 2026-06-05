import CoreLocation
import Foundation
import MapKit

struct LocationSearchResult: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D

    var coordinateText: String {
        String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
    }

    static func == (lhs: LocationSearchResult, rhs: LocationSearchResult) -> Bool {
        lhs.id == rhs.id
    }
}

struct LocationPreset: Identifiable {
    let id: String
    let title: String
    let coordinate: CLLocationCoordinate2D

    var coordinateText: String {
        String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
    }

    static let defaults: [LocationPreset] = [
        LocationPreset(
            id: "tokyo-station",
            title: "Tokyo Station",
            coordinate: CLLocationCoordinate2D(latitude: 35.681236, longitude: 139.767125)
        ),
        LocationPreset(
            id: "shibuya",
            title: "Shibuya Crossing",
            coordinate: CLLocationCoordinate2D(latitude: 35.659494, longitude: 139.70055)
        ),
        LocationPreset(
            id: "haneda",
            title: "Haneda Airport",
            coordinate: CLLocationCoordinate2D(latitude: 35.549393, longitude: 139.779839)
        ),
        LocationPreset(
            id: "apple-park",
            title: "Apple Park",
            coordinate: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.00902)
        )
    ]
}

struct LocationSearchService: Sendable {
    func search(query: String, near coordinate: CLLocationCoordinate2D) async throws -> [LocationSearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return []
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmedQuery
        request.region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 1.2, longitudeDelta: 1.2)
        )

        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.prefix(8).map { item in
            LocationSearchResult(
                title: item.name ?? trimmedQuery,
                subtitle: item.placemark.title ?? "",
                coordinate: item.placemark.coordinate
            )
        }
    }
}
