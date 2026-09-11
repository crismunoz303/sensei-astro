@preconcurrency import CoreLocation
import Foundation
import Combine

@MainActor
final class AstroStore: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var snapshot: AstroSnapshot = .placeholder
    @Published var isLoading = false
    @Published var hasLoaded = false
    @Published var errorMessage: String?
    @Published var selectedTab: AstroTab = .tonight

    private let locationManager = CLLocationManager()
    private var coordinate = AstroCoordinate.huntingtonPark
    private var locationName = "HUNTINGTON PARK"
    private var started = false
    private var lastRefreshAttempt: Date?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    func start() {
        guard !started else { return }
        started = true
        locationManager.requestWhenInUseAuthorization()
        locationManager.requestLocation()
        Task { await refresh() }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        lastRefreshAttempt = Date()
        errorMessage = nil
        let usedCoordinate = coordinate
        let usedName = locationName
        let result = await AstroData.load(at: usedCoordinate, locationName: usedName)
        if usedCoordinate != coordinate {
            isLoading = false
            await refresh()
            return
        }
        snapshot = result
        hasLoaded = true
        if result.plans.isEmpty {
            errorMessage = "No catalog targets are above 25 degrees during tonight's observing window."
        }
        isLoading = false
    }

    func refreshIfStale(maxAge: TimeInterval = 15 * 60) async {
        guard let lastRefreshAttempt else {
            await refresh()
            return
        }
        if Date().timeIntervalSince(lastRefreshAttempt) >= maxAge { await refresh() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        Task { @MainActor [weak self] in
            self?.handleLocation(latest)
        }
    }

    private func handleLocation(_ latest: CLLocation) {
        coordinate = AstroCoordinate(latitude: latest.coordinate.latitude, longitude: latest.coordinate.longitude)
        let fallbackDistance = latest.distance(from: CLLocation(latitude: AstroCoordinate.huntingtonPark.latitude, longitude: AstroCoordinate.huntingtonPark.longitude))
        locationName = fallbackDistance < 25_000 ? "HUNTINGTON PARK" : "CURRENT LOCATION"
        Task {
            if fallbackDistance >= 25_000,
               let placemark = try? await CLGeocoder().reverseGeocodeLocation(latest).first {
                let locality = placemark.locality ?? placemark.subAdministrativeArea
                let region = placemark.administrativeArea
                locationName = [locality, region].compactMap { $0 }.joined(separator: ", ").uppercased()
            }
            await refresh()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.locationName = "HUNTINGTON PARK"
        }
    }
}
