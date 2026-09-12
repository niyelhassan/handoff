import Foundation
import MapKit
import CoreLocation

/// Real driving times from Apple's routing service (the same engine behind the Maps app).
/// Used by the `driveTime` step so a routine never has to drive a maps website by clicking.
public enum TravelTime {
    private static var cache: [String:String] = [:]

    /// Whole minutes of driving from `origin` to `destination`, both street addresses or place names.
    /// Ambiguous addresses fail with a clear message so the routine can flag that row instead of guessing.
    public static func minutes(from origin: String, to destination: String) async throws -> String {
        let key = origin.lowercased()+"|"+destination.lowercased()
        if let cached = cache[key] { return cached }
        let from = try await locate(origin); let to = try await locate(destination)
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark:MKPlacemark(coordinate:from))
        request.destination = MKMapItem(placemark:MKPlacemark(coordinate:to))
        request.transportType = .automobile
        request.requestsAlternateRoutes = false
        let response: MKDirections.Response
        do { response = try await MKDirections(request:request).calculate() }
        catch { throw ScoutError.message("No driving route from ‘\(origin)’ to ‘\(destination)’: \(error.localizedDescription)") }
        // Like a person reading Maps, take the first (recommended) route rather than averaging alternatives.
        guard let route = response.routes.first else { throw ScoutError.message("No driving route to ‘\(destination)’.") }
        let minutes = String(Int((route.expectedTravelTime/60).rounded()))
        cache[key] = minutes
        return minutes
    }

    private static func locate(_ text: String) async throws -> CLLocationCoordinate2D {
        let trimmed = text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ScoutError.message("The address is empty.") }
        let placemarks: [CLPlacemark]
        do { placemarks = try await CLGeocoder().geocodeAddressString(trimmed) }
        catch { throw ScoutError.message("Could not find ‘\(trimmed)’ on the map: \(error.localizedDescription)") }
        guard let location = placemarks.first?.location else { throw ScoutError.message("Could not find ‘\(trimmed)’ on the map.") }
        return location.coordinate
    }
}
