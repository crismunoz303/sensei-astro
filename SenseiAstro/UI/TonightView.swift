import SwiftUI

struct TonightView: View {
    @EnvironmentObject private var store: AstroStore

    private var snapshot: AstroSnapshot { store.snapshot }
    private var best: CapturePlan? { snapshot.plans.first }

    var body: some View {
        ZStack {
            AstroTheme.backgroundGradient.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    commandHeader
                    verdictPanel
                    if let message = store.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(AstroTheme.amber)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(AstroTheme.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                    conditions
                    if let best { featuredTarget(best) }
                    targetList
                    updatedFooter
                }
                .padding()
            }
            .refreshable { await store.refresh() }
        }
        .navigationTitle("Sensei Astro")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await store.refresh() } } label: {
                    if store.isLoading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
            }
        }
    }

    private var commandHeader: some View {
        HStack {
            Label("S30 PRO // MISSION CONTROL", systemImage: "camera.aperture")
                .font(.caption.bold().monospaced())
                .foregroundStyle(AstroTheme.text)
            Spacer()
            Text("ALT-AZ").font(.caption2.bold().monospaced()).foregroundStyle(AstroTheme.red)
        }
    }

    private var verdictPanel: some View {
        AstroPanel {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(verdict.title).font(.system(size: 26, weight: .black, design: .monospaced)).foregroundStyle(verdict.color)
                    Text(verdict.detail).font(.subheadline).foregroundStyle(AstroTheme.muted)
                    Text(snapshot.locationName).font(.caption.bold().monospaced()).foregroundStyle(AstroTheme.red)
                }
                Spacer()
                Image(systemName: verdict.icon).font(.system(size: 32)).foregroundStyle(verdict.color)
            }
        }
    }

    private var conditions: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            MetricView(title: "DARK SKY", value: "\(snapshot.sky.start.astroTime)-\(snapshot.sky.end.astroTime)", detail: snapshot.sky.darknessLabel.capitalized)
            MetricView(title: "MOON", value: "\(Int(snapshot.sky.moonIllumination * 100))%", detail: snapshot.sky.moonPhase)
            MetricView(title: "FORECAST", value: best?.weather.map { "\(Int($0.cloudPercent))% CLOUD" } ?? "OFFLINE", detail: best?.weather.map { "\(Int($0.windMPH)) MPH WIND" } ?? "Check sky")
            MetricView(title: "SUNSET", value: snapshot.sky.sunset, detail: "Moonrise \(snapshot.sky.moonrise)")
        }
    }

    private var targetList: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(best == nil ? "TONIGHT'S TARGETS" : "NEXT BEST TARGETS").font(.caption.bold().monospaced()).foregroundStyle(AstroTheme.red)
            ForEach(Array(snapshot.plans.dropFirst().prefix(4))) { plan in
                NavigationLink(value: plan) { TargetRow(plan: plan) }
                    .buttonStyle(.plain)
            }
            if snapshot.plans.count <= 1 {
                Text("No additional targets clear tonight's safety and altitude checks.")
                    .font(.caption)
                    .foregroundStyle(AstroTheme.muted)
            }
        }
        .navigationDestination(for: CapturePlan.self) { TargetDetailView(plan: $0, sky: snapshot.sky) }
    }

    private func featuredTarget(_ plan: CapturePlan) -> some View {
        NavigationLink(value: plan) {
            AstroPanel {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("#1 TARGET TONIGHT", systemImage: "scope")
                            .font(.caption.bold().monospaced())
                            .foregroundStyle(AstroTheme.red)
                        Spacer()
                        Text("\(plan.condition) // \(plan.score)")
                            .font(.caption2.bold().monospaced())
                            .foregroundStyle(AstroTheme.scoreColor(plan.score))
                    }
                    Text("\(plan.target.id) // \(plan.target.name)")
                        .font(.title2.bold())
                        .foregroundStyle(AstroTheme.text)
                    Text("START \(plan.start.astroTime)  •  PEAK \(plan.bestTime.astroTime)  •  STOP \(plan.end.astroTime)")
                        .font(.caption.bold().monospaced())
                        .foregroundStyle(AstroTheme.text)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    Text("Best because it \(plan.rankReason)")
                        .font(.subheadline)
                        .foregroundStyle(AstroTheme.muted)
                    HStack {
                        Label("\(plan.integrationMinutes) MIN STACK", systemImage: "timer")
                        Spacer()
                        Label(plan.filterText.uppercased(), systemImage: "camera.filters")
                    }
                    .font(.caption2.bold().monospaced())
                    .foregroundStyle(AstroTheme.red)
                    Text("Tap for the complete S30 Pro capture plan")
                        .font(.caption2.bold())
                        .foregroundStyle(AstroTheme.text)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Number one target tonight, \(plan.target.id), \(plan.target.name). Tap for capture plan.")
    }

    private var updatedFooter: some View {
        HStack {
            Text("UPDATED \(snapshot.updatedAt.astroTime)")
            Spacer()
            Text(snapshot.sky.sourceOnline ? "DATA ONLINE" : "PARTIAL DATA")
        }
        .font(.caption2.bold().monospaced())
        .foregroundStyle(snapshot.sky.sourceOnline ? AstroTheme.green : AstroTheme.amber)
    }

    private var verdict: (title: String, detail: String, icon: String, color: Color) {
        if snapshot.sky.weather.isEmpty {
            return ("CHECK CONDITIONS", "Weather unavailable. Target rankings are provisional.", "exclamationmark.triangle.fill", AstroTheme.amber)
        }
        guard let best else { return ("SKIP TONIGHT", "No catalog targets clear the minimum altitude.", "xmark.circle.fill", AstroTheme.amber) }
        if let weather = best.weather, weather.cloudPercent >= 70 || weather.precipitationPercent >= 50 || weather.gustMPH >= 22 {
            return ("SKIP TONIGHT", "Forecast conditions are unfavorable near the best window.", "cloud.rain.fill", AstroTheme.amber)
        }
        if best.score >= 80 { return ("GO TONIGHT", "Strong conditions for \(best.target.id) starting near \(best.start.astroTime).", "checkmark.circle.fill", AstroTheme.green) }
        if best.score >= 60 { return ("MAYBE TONIGHT", "Usable window for \(best.target.id); verify the sky first.", "questionmark.circle.fill", AstroTheme.amber) }
        return ("SKIP TONIGHT", "Low target quality tonight; check again tomorrow.", "xmark.circle.fill", AstroTheme.amber)
    }
}

struct TargetRow: View {
    let plan: CapturePlan

    var body: some View {
        HStack(spacing: 12) {
            Text("\(plan.rank)")
                .font(.headline.bold().monospaced())
                .foregroundStyle(AstroTheme.red)
                .frame(width: 34, height: 34)
                .background(AstroTheme.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(plan.target.id) // \(plan.target.name)").font(.subheadline.bold()).foregroundStyle(AstroTheme.text).lineLimit(1)
                Text("\(plan.condition) - SCORE \(plan.score)").font(.caption2.bold().monospaced()).foregroundStyle(AstroTheme.scoreColor(plan.score))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(Int(plan.altitude.rounded())) DEG \(plan.direction)").font(.caption.bold().monospaced()).foregroundStyle(AstroTheme.text)
                Text("\(plan.start.astroTime) - \(plan.sessionMinutes) MIN SESSION").font(.caption2).foregroundStyle(AstroTheme.muted)
            }
        }
        .padding(11)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(AstroTheme.red.opacity(0.25)))
    }
}
