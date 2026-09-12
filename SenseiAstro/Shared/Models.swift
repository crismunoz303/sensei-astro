import Foundation

struct AstroTarget: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let rightAscensionHours: Double
    let declinationDegrees: Double
    let type: String
    let filterEnabled: Bool
    let recommendedMinutes: Int
    let lens: String
    let framing: String
    let note: String
}

struct WeatherPoint: Hashable, Codable {
    let time: Date
    let cloudPercent: Double
    let precipitationPercent: Double
    let humidityPercent: Double
    let dewPointF: Double
    let temperatureF: Double
    let windMPH: Double
    let gustMPH: Double

    var isValid: Bool {
        [cloudPercent, precipitationPercent, humidityPercent].allSatisfy { $0.isFinite && (0...100).contains($0) }
            && [dewPointF, temperatureF, windMPH, gustMPH].allSatisfy { $0.isFinite }
            && windMPH >= 0 && gustMPH >= 0
    }
}

struct SkyContext: Codable {
    let start: Date
    let end: Date
    let moonPhase: String
    let moonIllumination: Double
    let moonrise: String
    let moonset: String
    let sunset: String
    let darknessLabel: String
    let weather: [WeatherPoint]
    let sourceOnline: Bool
}

struct CapturePlan: Identifiable, Hashable, Codable {
    var id: String { target.id }
    let rank: Int
    let target: AstroTarget
    let score: Int
    let condition: String
    let bestTime: Date
    let start: Date
    let end: Date
    let altitude: Double
    let azimuth: Double
    let direction: String
    let moonSeparation: Double
    let exposureSeconds: Int
    let integrationMinutes: Int
    let sessionMinutes: Int
    let visibleMinutes: Int
    let acceptedFrames: Int
    let weather: WeatherPoint?

    var filterText: String {
        target.filterEnabled ? "Duo-band ON" : "Duo-band OFF (UV/IR-cut)"
    }

    var antiDewText: String {
        guard let weather else { return "Inspect lens; enable anti-dew if moisture appears" }
        return weather.humidityPercent >= 82 || weather.temperatureF - weather.dewPointF <= 4
            ? "Anti-dew ON"
            : "Anti-dew AUTO/OFF; inspect between stacks"
    }

    var confidenceText: String {
        weather == nil ? "PROVISIONAL" : "FORECAST AVAILABLE"
    }

    var filterReason: String {
        target.filterEnabled
            ? "Passes selected emission lines while rejecting much of the background light; improves contrast at the cost of other wavelengths."
            : "Preserves broadband light and natural star/galaxy color."
    }

    var rankReason: String {
        var reasons = ["\(Int(altitude.rounded()))° altitude at the highest-rated sample"]
        if moonSeparation >= 90 { reasons.append("well separated from the Moon") }
        else if moonSeparation < 45 { reasons.append("Moon interference is a risk") }
        if let weather {
            reasons.append("\(Int(weather.cloudPercent.rounded()))% forecast cloud there")
        }
        return reasons.joined(separator: ", ") + "."
    }

    var riskWarnings: [String] {
        var values: [String] = []
        if altitude < 35 { values.append("Low altitude: haze and city glow may reduce contrast.") }
        if moonSeparation < 45 && skySensitiveToMoon {
            values.append("Moon is close to this broadband target; expect weaker contrast.")
        }
        if let weather {
            if weather.cloudPercent >= 45 { values.append("Cloud cover may interrupt stacking.") }
            if weather.gustMPH >= 16 { values.append("Wind gusts may increase rejected frames.") }
            if weather.humidityPercent >= 82 || weather.temperatureF - weather.dewPointF <= 4 {
                values.append("Dew risk is high; enable anti-dew before the session.")
            }
        } else {
            values.append("Live weather is unavailable; verify the sky before setup.")
        }
        if integrationMinutes < target.recommendedMinutes {
            values.append("Tonight's window is shorter than the ideal integration for this target.")
        }
        return values
    }

    private var skySensitiveToMoon: Bool { !target.filterEnabled }
}

enum AstroTab: Hashable {
    case tonight
    case targets
    case lab
}

struct AstroSnapshot: Codable {
    let locationName: String
    let sky: SkyContext
    let plans: [CapturePlan]
    let updatedAt: Date

    static var placeholder: AstroSnapshot {
        let now = Date()
        let target = TargetCatalog.all[0]
        let plan = CapturePlan(
            rank: 1, target: target, score: 88, condition: "EXCELLENT",
            bestTime: now.addingTimeInterval(3600), start: now.addingTimeInterval(1800),
            end: now.addingTimeInterval(6300), altitude: 72, azimuth: 35,
            direction: "NE", moonSeparation: 110, exposureSeconds: 10,
            integrationMinutes: 75, sessionMinutes: 95, visibleMinutes: 180,
            acceptedFrames: 450, weather: nil
        )
        return AstroSnapshot(
            locationName: "HUNTINGTON PARK",
            sky: SkyContext(start: now, end: now.addingTimeInterval(28_800), moonPhase: "Waxing Crescent", moonIllumination: 0.18, moonrise: "6:02 AM", moonset: "7:12 PM", sunset: "7:06 PM", darknessLabel: "ASTRONOMICAL DARKNESS", weather: [], sourceOnline: false),
            plans: [plan], updatedAt: now
        )
    }
}
