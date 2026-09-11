import SwiftUI

struct TargetDetailView: View {
    let plan: CapturePlan
    let sky: SkyContext
    @AppStorage("favoriteTargetIDs") private var favoriteTargetIDs = ""

    private var isFavorite: Bool {
        Set(favoriteTargetIDs.split(separator: "|").map(String.init)).contains(plan.target.id)
    }

    var body: some View {
        ZStack {
            AstroTheme.backgroundGradient.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("SENSEI // S30 PRO CAPTURE PLAN").font(.caption.bold().monospaced()).foregroundStyle(AstroTheme.red)
                    Text("\(plan.target.id) - \(plan.target.name)").font(.largeTitle.bold()).foregroundStyle(AstroTheme.text)
                    Text("\(plan.target.type) | \(plan.condition) / \(plan.score)").foregroundStyle(AstroTheme.scoreColor(plan.score))

                    detailGrid
                    sequencePanel
                    notesPanel
                    conditionsPanel
                    ShareLink(item: shareText) {
                        Label("SHARE CAPTURE PLAN", systemImage: "square.and.arrow.up")
                            .font(.subheadline.bold().monospaced())
                            .frame(maxWidth: .infinity)
                            .padding(12)
                            .foregroundStyle(AstroTheme.text)
                            .background(AstroTheme.panel, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(AstroTheme.red.opacity(0.4)))
                    }
                    openSeestarButton
                }
                .padding()
            }
        }
        .navigationTitle(plan.target.id)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: toggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundStyle(isFavorite ? AstroTheme.amber : AstroTheme.muted)
                }
            }
        }
    }

    private var detailGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
            MetricView(title: "SESSION WINDOW", value: "\(plan.start.astroTime)-\(plan.end.astroTime)", detail: "Peak \(plan.bestTime.astroTime)")
            MetricView(title: "SKY POSITION", value: "\(Int(plan.altitude.rounded())) DEG \(plan.direction)", detail: "Azimuth \(Int(plan.azimuth.rounded())) DEG")
            MetricView(title: "MOUNT", value: "ALT-AZ", detail: "Standard tripod")
            MetricView(title: "LENS / FRAME", value: plan.target.lens, detail: plan.target.framing)
            MetricView(title: "FILTER", value: plan.filterText, detail: "Auto dark calibration")
            MetricView(title: "EXPOSURE", value: "\(plan.exposureSeconds) SEC x \(plan.acceptedFrames)", detail: "Goal: \(plan.integrationMinutes) min accepted")
            MetricView(title: "TIME BUDGET", value: "\(plan.sessionMinutes) MIN", detail: "\(plan.visibleMinutes) min usable window")
            MetricView(title: "MOON", value: "\(Int(sky.moonIllumination * 100))% LIT", detail: "\(Int(plan.moonSeparation.rounded())) DEG separation")
            MetricView(title: "DEW CONTROL", value: plan.antiDewText, detail: "Inspect lens during session")
        }
    }

    private var sequencePanel: some View {
        AstroPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text("EXACT SHOOTING SEQUENCE").font(.caption.bold().monospaced()).foregroundStyle(AstroTheme.red)
                step(1, "Place the standard tripod on firm ground, level it, and provide at least 45 degrees of clear sky.")
                step(2, "Power on the S30 Pro, connect in Seestar, and enter Stargazing mode.")
                step(3, "Search for \(plan.target.id), tap GoTo, and let plate solving, centering, and autofocus finish.")
                step(4, "Set \(plan.filterText). Use \(plan.target.lens) with \(plan.target.framing.lowercased()).")
                step(5, "Use \(plan.exposureSeconds)-second sub-exposures. Begin near \(plan.start.astroTime); allow \(plan.sessionMinutes) minutes to collect \(plan.integrationMinutes) accepted minutes.")
                step(6, "Watch accepted versus rejected frames for five minutes. Re-level or shelter from wind if rejection rises.")
                step(7, "Stop near \(plan.end.astroTime), or continue only while the target remains high and conditions stay clear.")
            }
        }
    }

    private var notesPanel: some View {
        AstroPanel {
            VStack(alignment: .leading, spacing: 6) {
                Text("TARGET NOTE").font(.caption.bold().monospaced()).foregroundStyle(AstroTheme.red)
                Text(plan.target.note).foregroundStyle(AstroTheme.text)
            }
        }
    }

    private var conditionsPanel: some View {
        AstroPanel {
            VStack(alignment: .leading, spacing: 6) {
                Text("WEATHER AT BEST TIME").font(.caption.bold().monospaced()).foregroundStyle(AstroTheme.red)
                if let weather = plan.weather {
                    Text("\(Int(weather.cloudPercent))% clouds | \(Int(weather.precipitationPercent))% rain chance")
                    Text("\(Int(weather.windMPH)) mph wind, gusts \(Int(weather.gustMPH)) mph")
                    Text("\(Int(weather.temperatureF)) F | \(Int(weather.humidityPercent))% humidity | dew point \(Int(weather.dewPointF)) F")
                } else {
                    Text("Forecast unavailable. Verify conditions before setup.")
                }
            }
            .foregroundStyle(AstroTheme.text)
        }
    }

    private var openSeestarButton: some View {
        Link(destination: URL(string: "shortcuts://run-shortcut?name=Open%20Seestar")!) {
            Label("OPEN SEESTAR", systemImage: "scope")
                .font(.headline.bold().monospaced())
                .frame(maxWidth: .infinity)
                .padding()
                .foregroundStyle(.white)
                .background(AstroTheme.red, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(number)").font(.caption.bold().monospaced()).foregroundStyle(AstroTheme.red).frame(width: 22, height: 22).background(AstroTheme.red.opacity(0.14), in: Circle())
            Text(text).foregroundStyle(AstroTheme.text)
        }
    }

    private func toggleFavorite() {
        var values = Set(favoriteTargetIDs.split(separator: "|").map(String.init))
        if values.contains(plan.target.id) { values.remove(plan.target.id) } else { values.insert(plan.target.id) }
        favoriteTargetIDs = values.sorted().joined(separator: "|")
    }

    private var shareText: String {
        """
        SENSEI ASTRO // \(plan.target.id) \(plan.target.name)
        Session: \(plan.start.astroTime)-\(plan.end.astroTime) (peak \(plan.bestTime.astroTime))
        Goal: \(plan.integrationMinutes) accepted minutes, \(plan.exposureSeconds)s x \(plan.acceptedFrames)
        Position: \(Int(plan.altitude.rounded()))° \(plan.direction), azimuth \(Int(plan.azimuth.rounded()))°
        Filter: \(plan.filterText)
        Mount: standard tripod / Alt-Az
        Dew: \(plan.antiDewText)
        """
    }
}
