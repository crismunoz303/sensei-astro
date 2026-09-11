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

struct WeatherPoint: Hashable {
    let time: Date
    let cloudPercent: Double
    let precipitationPercent: Double
    let humidityPercent: Double
    let dewPointF: Double
    let temperatureF: Double
    let windMPH: Double
    let gustMPH: Double
}

struct SkyContext {
    let start: Date
    let end: Date
    let moonPhase: String
    let moonIllumination: Double
    let moonrise: String
    let moonset: String
    let sunset: String
    let weather: [WeatherPoint]
    let sourceOnline: Bool
}

struct CapturePlan: Identifiable, Hashable {
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
    let integrationMinutes: Int
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
}

enum AstroTab: Hashable {
    case tonight
    case targets
}

struct AstroSnapshot {
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
            direction: "NE", moonSeparation: 110, integrationMinutes: 75,
            acceptedFrames: 450, weather: nil
        )
        return AstroSnapshot(
            locationName: "HUNTINGTON PARK",
            sky: SkyContext(start: now, end: now.addingTimeInterval(28_800), moonPhase: "Waxing Crescent", moonIllumination: 0.18, moonrise: "6:02 AM", moonset: "7:12 PM", sunset: "7:06 PM", weather: [], sourceOnline: false),
            plans: [plan], updatedAt: now
        )
    }
}

