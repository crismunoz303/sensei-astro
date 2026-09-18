import SwiftUI
import WebKit

struct CloudMapView: View {
    @EnvironmentObject private var store: AstroStore
    @State private var mapReloadID = UUID()

    private var mapURL: URL {
        VentuskyURL.clouds(at: store.observingCoordinate)
    }

    private var forecast: [WeatherPoint] {
        guard store.forecastIsCurrent else { return [] }
        return CloudForecast.points(store.snapshot.sky.weather,
            from: Date().addingTimeInterval(-30 * 60), through: Date().addingTimeInterval(24 * 3600))
    }

    private var currentPoint: WeatherPoint? {
        CloudForecast.nearNow(forecast, now: Date())
    }

    private var clearestPoint: WeatherPoint? {
        CloudForecast.clearestTonight(forecast, sky: store.snapshot.sky, now: Date())
    }

    var body: some View {
        ZStack {
            AstroTheme.backgroundGradient.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    header
                    forecastSummary
                    hourlyForecast
                    map
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
                    Text(store.observingLocationName)
                        .font(.headline.monospaced().bold())
                        .foregroundStyle(AstroTheme.text)
                    Text(store.locationStatus)
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
            VStack(alignment: .leading, spacing: 8) {
            Text("LOCAL CLOUD CHECK")
                .font(.caption.bold())
                .foregroundStyle(AstroTheme.red)
                HStack(spacing: 10) {
                    MetricView(
                        title: "NEAR NOW",
                        value: currentPoint.map { "\(Int($0.cloudPercent.rounded()))%" } ?? "—",
                        detail: currentPoint.map { "Forecast: \($0.time.astroTime)" } ?? "No nearby sample"
                    )
                    MetricView(
                        title: "CLEAREST DARK HOUR",
                        value: clearestPoint.map { "\(Int($0.cloudPercent.rounded()))%" } ?? "—",
                        detail: clearestPoint.map { $0.time.astroTime } ?? "No remaining sample"
                    )
                }
                .padding(.top, 8)
            if !store.forecastIsCurrent || forecast.isEmpty {
                Text("Local forecast unavailable or refreshing. Pull down to retry. The map uses its own forecast.")
                    .font(.caption)
                    .foregroundStyle(AstroTheme.muted)
                    .padding(.top, 6)
            }
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
            Text(point.time.formatted(.dateTime.month(.abbreviated).day()))
                .font(.caption2).foregroundStyle(AstroTheme.muted)
            Image(systemName: cloudSymbol(point.cloudPercent))
                .font(.title3)
                .foregroundStyle(cloudColor(point.cloudPercent))
            Text("\(Int(point.cloudPercent.rounded()))%")
                .font(.headline.monospaced().bold())
                .foregroundStyle(AstroTheme.text)
            Text(duringDarkness ? "DARK" : "OUTSIDE NIGHT")
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
        let position = String(format: "%.5f;%.5f;8", locale: Locale(identifier: "en_US_POSIX"), coordinate.latitude, coordinate.longitude)
        let pin = String(format: "%.5f;%.5f;dot;Sensei", locale: Locale(identifier: "en_US_POSIX"), coordinate.latitude, coordinate.longitude)
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
