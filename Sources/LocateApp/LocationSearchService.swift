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
