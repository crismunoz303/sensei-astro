import SwiftUI

enum AstroTheme {
    static let background = Color(red: 0.025, green: 0.02, blue: 0.035)
    static let panel = Color(red: 0.09, green: 0.035, blue: 0.055)
    static let red = Color(red: 1, green: 0.14, blue: 0.28)
    static let crimson = Color(red: 0.55, green: 0.02, blue: 0.14)
    static let text = Color(red: 0.97, green: 0.93, blue: 0.95)
    static let muted = Color(red: 0.72, green: 0.61, blue: 0.64)
    static let green = Color(red: 0.41, green: 0.94, blue: 0.68)
    static let amber = Color(red: 1, green: 0.78, blue: 0.43)

    static var backgroundGradient: LinearGradient {
        LinearGradient(colors: [background, panel, Color(red: 0.15, green: 0.025, blue: 0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func scoreColor(_ score: Int) -> Color {
        score >= 70 ? green : score >= 50 ? amber : red
    }
}

struct AstroPanel<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AstroTheme.panel.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(AstroTheme.red.opacity(0.3)))
    }
}

struct MetricView: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.bold()).foregroundStyle(AstroTheme.red)
            Text(value).font(.headline.monospaced().bold()).foregroundStyle(AstroTheme.text).lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.caption2).foregroundStyle(AstroTheme.muted).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}

extension Date {
    var astroTime: String { formatted(date: .omitted, time: .shortened) }
}
