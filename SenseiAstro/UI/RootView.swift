import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AstroStore

    var body: some View {
        TabView(selection: $store.selectedTab) {
            NavigationStack {
                if store.hasSnapshotForLocation { TonightView() }
                else { ProgressView("Calculating your sky…") }
            }
                .id(store.observingCoordinate)
                .tabItem { Label("Tonight", systemImage: "moon.stars.fill") }
                .tag(AstroTab.tonight)

            NavigationStack {
                if store.hasSnapshotForLocation { TargetsView() }
                else { ProgressView("Calculating target windows…") }
            }
                .id(store.observingCoordinate)
                .tabItem { Label("Targets", systemImage: "scope") }
                .tag(AstroTab.targets)

            NavigationStack { CloudMapView() }
                .tabItem { Label("Clouds", systemImage: "cloud.fill") }
                .tag(AstroTab.clouds)

            NavigationStack { PhotoLabView() }
                .tabItem { Label("True Edit", systemImage: "slider.horizontal.3") }
                .tag(AstroTab.lab)
        }
        .tint(AstroTheme.red)
        .safeAreaInset(edge: .top, spacing: 0) {
            if store.selectedTab != .lab {
                VStack(spacing: 3) {
                    Text(store.observingLocationName).font(.caption.bold())
                    Text(store.locationStatus).font(.caption2)
                    if let settings = URL(string: UIApplication.openSettingsURLString) {
                        Link("Location settings", destination: settings).font(.caption2)
                    }
                }
                .frame(maxWidth: .infinity).padding(8)
                .background(.ultraThinMaterial)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("observingLocation")
            }
        }
        .task {
            store.start()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(900)) }
                catch { break }
                await store.refreshIfStale()
            }
        }
    }
}
