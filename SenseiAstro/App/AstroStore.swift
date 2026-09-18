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
    @Published private(set) var observingCoordinate = AstroCoordinate.huntingtonPark
    @Published private(set) var observingLocationName = "HUNTINGTON PARK"
    @Published private(set) var locationStatus = "Default location · Huntington Park"
    private var snapshotCoordinate: AstroCoordinate?
    var forecastIsCurrent: Bool {
        hasLoaded && snapshotCoordinate == observingCoordinate
            && CloudForecast.isFresh(updatedAt: snapshot.updatedAt, now: Date())
    }

    private let locationManager = CLLocationManager()
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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--photo-ui-test") { selectedTab = .lab; return }
        #endif
        locationManager.requestWhenInUseAuthorization()
        locationManager.requestLocation()
        Task { await refresh() }
    }

    func refresh() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--photo-ui-test") { return }
        #endif
        guard !isLoading else { return }
        isLoading = true
        lastRefreshAttempt = Date()
        errorMessage = nil
        let usedCoordinate = observingCoordinate
        let usedName = observingLocationName
        let result = await AstroData.load(at: usedCoordinate, locationName: usedName)
        if usedCoordinate != observingCoordinate {
            isLoading = false
            await refresh()
            return
        }
        snapshot = result
        snapshotCoordinate = usedCoordinate
        hasLoaded = true
        if result.plans.isEmpty {
            errorMessage = "No catalog target has a long enough window meeting the altitude and weather criteria."
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
        guard latest.horizontalAccuracy >= 0,
              abs(latest.timestamp.timeIntervalSinceNow) <= 5 * 60,
              CLLocationCoordinate2DIsValid(latest.coordinate) else { return }
        observingCoordinate = AstroCoordinate(latitude: latest.coordinate.latitude, longitude: latest.coordinate.longitude)
        let fallbackDistance = latest.distance(from: CLLocation(latitude: AstroCoordinate.huntingtonPark.latitude, longitude: AstroCoordinate.huntingtonPark.longitude))
        observingLocationName = fallbackDistance < 25_000 ? "HUNTINGTON PARK AREA" : "CURRENT LOCATION"
        locationStatus = "Phone location · approximate"
        let requestedCoordinate = observingCoordinate
        Task {
            if fallbackDistance >= 25_000,
               let placemark = try? await CLGeocoder().reverseGeocodeLocation(latest).first {
                let locality = placemark.locality ?? placemark.subAdministrativeArea
                let region = placemark.administrativeArea
                guard requestedCoordinate == observingCoordinate else { return }
                let name = [locality, region].compactMap { $0 }.joined(separator: ", ").uppercased()
                if !name.isEmpty { observingLocationName = name }
            }
            await refresh()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.locationStatus = self.observingCoordinate == .huntingtonPark
                ? "Location unavailable · Huntington Park fallback"
                : "Last known phone location"
        }
    }
}
