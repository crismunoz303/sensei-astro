import SwiftUI
import WebKit

struct CloudMapView: View {
    @EnvironmentObject private var store: AstroStore
    @State private var mapReloadID = UUID()

    private var mapURL: URL {
        VentuskyURL.clouds(at: store.observingCoordinate)
    }

    private var forecast: [WeatherPoint] {
        let earliest = Date().addingTimeInterval(-30 * 60)
        let latest = Date().addingTimeInterval(24 * 60 * 60)
        return store.snapshot.sky.weather
            .filter { $0.time >= earliest && $0.time <= latest }
            .sorted { $0.time < $1.time }
    }

    private var currentPoint: WeatherPoint? {
        forecast.min { abs($0.time.timeIntervalSinceNow) < abs($1.time.timeIntervalSinceNow) }
    }

    private var clearestPoint: WeatherPoint? {
        forecast.min {
            if $0.cloudPercent == $1.cloudPercent {
                return $0.precipitationPercent < $1.precipitationPercent
            }
            return $0.cloudPercent < $1.cloudPercent
        }
    }

    var body: some View {
        ZStack {
            AstroTheme.backgroundGradient.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    header
                    map
                    forecastSummary
                    hourlyForecast
                    sourceNote
                }
                .padding(16)
            }
            .refreshable {
                await store.refresh()
                mapReloadID = UUID()
            }
        }
        .navigationTitle("Cloud Map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AstroTheme.background, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private var header: some View {
        AstroPanel {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "cloud.moon.fill")
                    .font(.title2)
                    .foregroundStyle(AstroTheme.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.snapshot.locationName)
                        .font(.headline.monospaced().bold())
                        .foregroundStyle(AstroTheme.text)
                    Text("Interactive total cloud cover")
                        .font(.caption)
                        .foregroundStyle(AstroTheme.muted)
                }
                Spacer()
                if store.isLoading {
                    ProgressView().tint(AstroTheme.red)
                }
            }
        }
    }

    private var map: some View {
        VStack(spacing: 10) {
            VentuskyWebView(url: mapURL)
                .id(mapReloadID)
                .frame(height: 390)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(AstroTheme.red.opacity(0.45)))

            HStack(spacing: 12) {
                Button {
                    mapReloadID = UUID()
                } label: {
                    Label("Reload Map", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)

                Link(destination: mapURL) {
                    Label("Open Full Map", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderedProminent)
                .tint(AstroTheme.crimson)
            }
            .font(.caption.bold())
        }
    }

    private var forecastSummary: some View {
        AstroPanel {
            Text("LOCAL CLOUD CHECK")
                .font(.caption.bold())
                .foregroundStyle(AstroTheme.red)
            if let currentPoint, let clearestPoint {
                HStack(spacing: 10) {
                    MetricView(
                        title: "NOW",
                        value: "\(Int(currentPoint.cloudPercent.rounded()))%",
                        detail: cloudLabel(currentPoint.cloudPercent)
                    )
                    MetricView(
                        title: "CLEAREST 24H",
                        value: "\(Int(clearestPoint.cloudPercent.rounded()))%",
                        detail: clearestPoint.time.astroTime
                    )
                }
                .padding(.top, 8)
            } else {
                Text("Live hourly cloud percentages are unavailable. The interactive map may still load.")
                    .font(.caption)
                    .foregroundStyle(AstroTheme.muted)
                    .padding(.top, 6)
            }
        }
    }

    private var hourlyForecast: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HOURLY CLOUD COVER")
                .font(.caption.bold())
                .foregroundStyle(AstroTheme.red)

            if forecast.isEmpty {
                AstroPanel {
                    Text("Pull down to retry the weather forecast.")
                        .font(.caption)
                        .foregroundStyle(AstroTheme.muted)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 9) {
                        ForEach(forecast, id: \.time) { point in
                            cloudCard(point)
                        }
                    }
                }
            }
        }
    }

    private func cloudCard(_ point: WeatherPoint) -> some View {
        let duringDarkness = point.time >= store.snapshot.sky.start && point.time <= store.snapshot.sky.end
        return VStack(spacing: 5) {
            Text(point.time.astroTime)
                .font(.caption2.monospaced().bold())
                .foregroundStyle(AstroTheme.muted)
            Image(systemName: cloudSymbol(point.cloudPercent))
                .font(.title3)
                .foregroundStyle(cloudColor(point.cloudPercent))
            Text("\(Int(point.cloudPercent.rounded()))%")
                .font(.headline.monospaced().bold())
                .foregroundStyle(AstroTheme.text)
            Text(duringDarkness ? "DARK" : "LIGHT")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(duringDarkness ? AstroTheme.red : AstroTheme.muted)
        }
        .padding(.vertical, 10)
        .frame(width: 76)
        .background(AstroTheme.panel.opacity(0.9), in: RoundedRectangle(cornerRadius: 13))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(duringDarkness ? AstroTheme.red.opacity(0.55) : Color.white.opacity(0.08))
        )
    }

    private var sourceNote: some View {
        Text("Interactive map: Ventusky total cloud cover. Hourly percentages: Open-Meteo, the same forecast used by the Sensei Astro planner. Forecast clouds are estimates—check the live sky before setting up your S30 Pro.")
            .font(.caption2)
            .foregroundStyle(AstroTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cloudLabel(_ value: Double) -> String {
        if value <= 20 { return "CLEAR" }
        if value <= 40 { return "WORKABLE" }
        if value <= 65 { return "MIXED" }
        return "POOR"
    }

    private func cloudSymbol(_ value: Double) -> String {
        if value <= 20 { return "moon.stars.fill" }
        if value <= 55 { return "cloud.moon.fill" }
        return "cloud.fill"
    }

    private func cloudColor(_ value: Double) -> Color {
        if value <= 20 { return AstroTheme.green }
        if value <= 55 { return AstroTheme.amber }
        return AstroTheme.red
    }
}

private enum VentuskyURL {
    static func clouds(at coordinate: AstroCoordinate) -> URL {
        let position = String(format: "%.5f;%.5f;8", coordinate.latitude, coordinate.longitude)
        let pin = String(format: "%.5f;%.5f;dot;Sensei", coordinate.latitude, coordinate.longitude)
        var components = URLComponents(string: "https://embed.ventusky.com/")!
        components.queryItems = [
            URLQueryItem(name: "p", value: position),
            URLQueryItem(name: "l", value: "clouds-total"),
            URLQueryItem(name: "pin", value: pin)
        ]
        return components.url!
    }
}

private struct VentuskyWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.allowsBackForwardNavigationGestures = true
        load(url, in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        load(url, in: webView, coordinator: context.coordinator)
    }

    private func load(_ url: URL, in webView: WKWebView, coordinator: Coordinator) {
        coordinator.loadedURL = url
        webView.load(URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 30))
    }

    final class Coordinator {
        var loadedURL: URL?
    }
}
