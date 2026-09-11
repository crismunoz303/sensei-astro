import CoreLocation
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

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        coordinate = AstroCoordinate(latitude: latest.coordinate.latitude, longitude: latest.coordinate.longitude)
        let fallbackDistance = latest.distance(from: CLLocation(latitude: AstroCoordinate.huntingtonPark.latitude, longitude: AstroCoordinate.huntingtonPark.longitude))
        locationName = fallbackDistance < 25_000 ? "HUNTINGTON PARK" : "CURRENT LOCATION"
        Task { await refresh() }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationName = "HUNTINGTON PARK"
    }
}
