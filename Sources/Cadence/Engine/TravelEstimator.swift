import CoreLocation
import MapKit

/// Resolves a free-text location to a place and estimates travel time from the user's current location.
@MainActor
final class TravelEstimator: NSObject, CLLocationManagerDelegate {
    static let shared = TravelEstimator()

    private let manager = CLLocationManager()
    private var placeCache: [String: MKMapItem] = [:]
    private var locationWaiters: [CheckedContinuation<CLLocation?, Never>] = []
    private var authWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastLocation: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var isLocationDenied: Bool {
        let s = manager.authorizationStatus
        return s == .denied || s == .restricted
    }

    // MARK: Places

    func place(for query: String) async -> MKMapItem? {
        if let cached = placeCache[query] { return cached }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        if let near = lastLocation {
            request.region = MKCoordinateRegion(center: near.coordinate, latitudinalMeters: 200_000, longitudinalMeters: 200_000)
        }
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        placeCache[query] = item
        return item
    }

    static func coordinate(of item: MKMapItem) -> CLLocationCoordinate2D {
        if #available(macOS 26.0, *) {
            return item.location.coordinate
        } else {
            return item.placemark.coordinate
        }
    }

    // MARK: ETA

    func eta(to destination: MKMapItem, mode: TravelMode, departing: Date) async -> TimeInterval? {
        guard let here = await currentLocation() else { return nil }
        let request = MKDirections.Request()
        request.source = Self.mapItem(for: here)
        request.destination = destination
        request.transportType = switch mode {
        case .driving: .automobile
        case .walking: .walking
        case .transit: .transit
        }
        if departing > Date() { request.departureDate = departing }
        return try? await MKDirections(request: request).calculateETA().expectedTravelTime
    }

    private static func mapItem(for location: CLLocation) -> MKMapItem {
        if #available(macOS 26.0, *) {
            return MKMapItem(location: location, address: nil)
        } else {
            return MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
        }
    }

    // MARK: Location

    func currentLocation() async -> CLLocation? {
        if let last = lastLocation, last.timestamp.timeIntervalSinceNow > -600 { return last }
        if manager.authorizationStatus == .notDetermined {
            await withCheckedContinuation { cont in
                authWaiters.append(cont)
                manager.requestWhenInUseAuthorization()
            }
        }
        guard manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorized else {
            return nil
        }
        return await withCheckedContinuation { cont in
            locationWaiters.append(cont)
            if locationWaiters.count == 1 { manager.requestLocation() }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard manager.authorizationStatus != .notDetermined else { return }
            let waiters = authWaiters
            authWaiters = []
            waiters.forEach { $0.resume() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            lastLocation = locations.last ?? lastLocation
            finishLocation(lastLocation)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { finishLocation(lastLocation) }
    }

    private func finishLocation(_ location: CLLocation?) {
        let waiters = locationWaiters
        locationWaiters = []
        waiters.forEach { $0.resume(returning: location) }
    }
}
