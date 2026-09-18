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
    @Published private(set) var locationStatus = "Huntington Park fallback · waiting for phone location"
    @Published private(set) var isLocating = false
    private var snapshotCoordinate: AstroCoordinate?
    var hasSnapshotForLocation: Bool { hasLoaded && snapshotCoordinate == observingCoordinate }
    var forecastIsCurrent: Bool {
        !isLocating && hasSnapshotForLocation
            && CloudForecast.isFresh(updatedAt: snapshot.updatedAt, now: Date())
    }

    private let locationManager = CLLocationManager()
    private var started = false
    private var lastRefreshAttempt: Date?
    private var foreground = false
    private var acceptedLocation: CLLocation?
    private var locationTimeout: Task<Void, Never>?
    private let geocoder = CLGeocoder()
    private var isUITest: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--photo-ui-test")
            || ProcessInfo.processInfo.arguments.contains("--cloud-ui-test")
        #else
        return false
        #endif
    }

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 500
    }

    func start() {
        guard !started else { return }
        started = true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--photo-ui-test") { selectedTab = .lab; return }
        if ProcessInfo.processInfo.arguments.contains("--cloud-ui-test") { selectedTab = .clouds; return }
        #endif
        enterForeground()
    }

    func enterForeground() {
        guard !isUITest else { return }
        foreground = true
        updateLocationAuthorization()
        Task { await refreshIfStale(maxAge: 5 * 60) }
    }

    func leaveForeground() {
        foreground = false
        locationManager.stopUpdatingLocation()
        locationTimeout?.cancel()
        isLocating = false
        if acceptedLocation != nil { locationStatus = "Last known phone location" }
    }

    private func updateLocationAuthorization() {
        guard foreground, !isUITest else { return }
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationStatus = "Huntington Park fallback · allow location to use your sky"
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            isLocating = true
            locationStatus = acceptedLocation == nil
                ? "Finding phone location · Huntington Park fallback"
                : "Updating phone location · showing last known position"
            locationManager.startUpdatingLocation()
            locationTimeout?.cancel()
            locationTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                self?.locationUnavailable()
            }
        case .denied, .restricted:
            locationManager.stopUpdatingLocation()
            locationUnavailable(reason: "Location access off")
        @unknown default:
            locationUnavailable()
        }
    }

    private func locationUnavailable(reason: String = "Location unavailable") {
        locationTimeout?.cancel()
        isLocating = false
        locationStatus = acceptedLocation == nil
            ? "\(reason) · Huntington Park fallback"
            : "\(reason) · last known phone location"
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.updateLocationAuthorization() }
    }

    func refresh() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--photo-ui-test") { return }
        if ProcessInfo.processInfo.arguments.contains("--cloud-ui-test") { return }
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
        guard foreground else { return }
        guard hasSnapshotForLocation, let lastRefreshAttempt else {
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
        guard foreground, !isUITest,
              LocationPolicy.accepts(accuracy: latest.horizontalAccuracy, timestamp: latest.timestamp, now: Date()),
              CLLocationCoordinate2DIsValid(latest.coordinate) else { return }
        locationTimeout?.cancel()
        isLocating = false
        locationStatus = locationManager.accuracyAuthorization == .reducedAccuracy
            ? "Phone location · approximate"
            : "Phone location · updated \(latest.timestamp.astroTime)"
        // Keep map and calculations on one coordinate; ignore small GPS drift.
        if let previous = acceptedLocation,
           !LocationPolicy.shouldUpdate(distance: latest.distance(from: previous),
                oldAccuracy: previous.horizontalAccuracy, newAccuracy: latest.horizontalAccuracy) {
            Task { await refreshIfStale(maxAge: 5 * 60) }
            return
        }
        acceptedLocation = latest
        observingCoordinate = AstroCoordinate(latitude: latest.coordinate.latitude, longitude: latest.coordinate.longitude)
        observingLocationName = "CURRENT LOCATION"
        let requestedCoordinate = observingCoordinate
        Task { await refresh() }
        geocoder.cancelGeocode()
        Task {
            if let placemark = try? await geocoder.reverseGeocodeLocation(latest).first {
                let locality = placemark.locality ?? placemark.subAdministrativeArea
                let region = placemark.administrativeArea
                guard requestedCoordinate == observingCoordinate else { return }
                let name = [locality, region].compactMap { $0 }.joined(separator: ", ").uppercased()
                if !name.isEmpty { observingLocationName = name }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.foreground, !self.isUITest else { return }
            self.locationUnavailable()
        }
    }
}
