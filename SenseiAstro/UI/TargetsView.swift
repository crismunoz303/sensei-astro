import SwiftUI

struct TargetsView: View {
    @EnvironmentObject private var store: AstroStore
    @State private var searchText = ""
    @State private var favoritesOnly = false
    @AppStorage("favoriteTargetIDs") private var favoriteTargetIDs = ""

    private var favorites: Set<String> {
        Set(favoriteTargetIDs.split(separator: "|").map(String.init))
    }

    private var filteredPlans: [CapturePlan] {
        let candidates = store.snapshot.plans.filter { !favoritesOnly || favorites.contains($0.target.id) }
        guard !searchText.isEmpty else { return candidates }
        return candidates.filter {
            $0.target.id.localizedCaseInsensitiveContains(searchText) ||
            $0.target.name.localizedCaseInsensitiveContains(searchText) ||
            $0.target.type.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ZStack {
            AstroTheme.backgroundGradient.ignoresSafeArea()
            ScrollView {
                LazyVStack(spacing: 9) {
                    Toggle("Favorites only", isOn: $favoritesOnly)
                        .tint(AstroTheme.red).padding(.bottom, 8)
                    if filteredPlans.isEmpty {
                        ContentUnavailableView("No matching targets", systemImage: "scope",
                            description: Text("Try another search or turn off Favorites only. Targets also need a usable window tonight."))
                    }
                    ForEach(filteredPlans) { plan in
                        HStack(spacing: 6) {
                            NavigationLink(value: plan) { TargetRow(plan: plan) }
                                .buttonStyle(.plain)
                            Button { toggleFavorite(plan.target.id) } label: {
                                Image(systemName: favorites.contains(plan.target.id) ? "star.fill" : "star")
                                    .foregroundStyle(favorites.contains(plan.target.id) ? AstroTheme.amber : AstroTheme.muted)
                                    .frame(width: 36, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(favorites.contains(plan.target.id) ? "Remove favorite" : "Add favorite")
                        }
                    }
                }
                .padding()
            }
            .refreshable { await store.refresh() }
        }
        .navigationTitle("Tonight's Targets")
        .searchable(text: $searchText, prompt: "M31, nebula, galaxy...")
        .navigationDestination(for: CapturePlan.self) { TargetDetailView(plan: $0, sky: store.snapshot.sky) }
    }

    private func toggleFavorite(_ id: String) {
        var updated = favorites
        if updated.contains(id) { updated.remove(id) } else { updated.insert(id) }
        favoriteTargetIDs = updated.sorted().joined(separator: "|")
    }
}
