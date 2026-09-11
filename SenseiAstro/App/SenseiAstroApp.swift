import SwiftUI

@main
struct SenseiAstroApp: App {
    @StateObject private var store = AstroStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    if url.host == "planner" { store.selectedTab = .targets }
                }
        }
    }
}

