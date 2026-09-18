import Foundation

/// Point forecasts, not measurements. Never label a distant sample as current.
enum CloudForecast {
    static func points(_ values: [WeatherPoint], from start: Date, through end: Date) -> [WeatherPoint] {
        var seen = Set<Date>()
        return values.filter { $0.isValid && $0.time >= start && $0.time <= end }
            .sorted { $0.time < $1.time }
            .filter { seen.insert($0.time).inserted }
    }

    static func nearNow(_ values: [WeatherPoint], now: Date) -> WeatherPoint? {
        values.filter { $0.isValid && abs($0.time.timeIntervalSince(now)) <= 30 * 60 }
            .min { abs($0.time.timeIntervalSince(now)) < abs($1.time.timeIntervalSince(now)) }
    }

    static func clearestTonight(_ values: [WeatherPoint], sky: SkyContext, now: Date) -> WeatherPoint? {
        points(values, from: max(now, sky.start), through: sky.end).min {
            if $0.cloudPercent != $1.cloudPercent { return $0.cloudPercent < $1.cloudPercent }
            if $0.precipitationPercent != $1.precipitationPercent { return $0.precipitationPercent < $1.precipitationPercent }
            return $0.time < $1.time
        }
    }

    static func isFresh(updatedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(updatedAt)
        return age >= -60 && age <= 30 * 60
    }
}
