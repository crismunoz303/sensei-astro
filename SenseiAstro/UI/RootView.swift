import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AstroStore

    var body: some View {
        TabView(selection: $store.selectedTab) {
            NavigationStack {
                if store.hasLoaded { TonightView() }
                else { ProgressView("Calculating your sky…") }
            }
                .tabItem { Label("Tonight", systemImage: "moon.stars.fill") }
                .tag(AstroTab.tonight)

            NavigationStack {
                if store.hasLoaded { TargetsView() }
                else { ProgressView("Calculating target windows…") }
            }
                .tabItem { Label("Targets", systemImage: "scope") }
                .tag(AstroTab.targets)

            NavigationStack { PhotoLabView() }
                .tabItem { Label("True Edit", systemImage: "slider.horizontal.3") }
                .tag(AstroTab.lab)
        }
        .tint(AstroTheme.red)
        .task {
            store.start()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(900))
                await store.refreshIfStale()
            }
        }
    }
}
