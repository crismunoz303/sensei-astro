import SwiftUI

@main
struct SenseiAstroApp: App {
    @StateObject private var store = AstroStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    if url.host == "planner" { store.selectedTab = .targets }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await store.refreshIfStale(maxAge: 5 * 60) }
        }
    }
}
