import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AstroStore

    var body: some View {
        TabView(selection: $store.selectedTab) {
            NavigationStack { TonightView() }
                .tabItem { Label("Tonight", systemImage: "moon.stars.fill") }
                .tag(AstroTab.tonight)

            NavigationStack { TargetsView() }
                .tabItem { Label("Targets", systemImage: "scope") }
                .tag(AstroTab.targets)
        }
        .tint(AstroTheme.red)
        .overlay {
            if !store.hasLoaded {
                ZStack {
                    AstroTheme.background.ignoresSafeArea()
                    ProgressView("Calculating your sky…")
                        .tint(AstroTheme.red)
                }
            }
        }
        .task {
            store.start()
            while !Task.isCancelled {
                try? await Task.sleep(for: .minutes(15))
                await store.refreshIfStale()
            }
        }
    }
}
