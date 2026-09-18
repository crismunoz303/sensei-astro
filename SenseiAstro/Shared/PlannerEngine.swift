import Foundation

enum PlannerEngine {
    private struct Sample {
        let time: Date
        let altitude: Double
        let azimuth: Double
        let moonSeparation: Double
        let weather: WeatherPoint?
        let score: Double
    }

    static func rank(_ targets: [AstroTarget], coordinate: AstroCoordinate, sky: SkyContext, now: Date = Date()) -> [CapturePlan] {
        guard now < sky.end else { return [] }
        let planningStart = max(now, sky.start)
        var samples: [Date] = []
        var cursor = planningStart
        while cursor < sky.end {
            samples.append(cursor)
            cursor = cursor.addingTimeInterval(15 * 60)
        }
        samples.append(sky.end)

        let unranked: [(AstroTarget, Sample, Int, Date, Date, Int, Int)] = targets.compactMap { target in
            let evaluated = samples.map { evaluate(target, at: $0, coordinate: coordinate, sky: sky) }
            let usable = evaluated.map { sample in
                sample.altitude >= 25 && !(sample.weather.map { $0.cloudPercent > 85 || $0.precipitationPercent > 60 || $0.gustMPH > 28 } ?? false)
            }
            // A very short high-scoring fragment must not hide a usable session.
            let segments = continuousSegments(evaluated, usable: usable).filter {
                guard let first = $0.first, let last = $0.last else { return false }
                return last.time.timeIntervalSince(first.time) >= 15 * 60
            }
            guard let window = segments.max(by: { segmentValue($0) < segmentValue($1) }),
                  let first = window.first, let last = window.last,
                  let best = window.dropLast().max(by: { $0.score < $1.score }) else { return nil }
            // Both endpoints must be usable. Never extend a sample beyond darkness.
            let possibleMinutes = Int(last.time.timeIntervalSince(first.time) / 60)
            guard possibleMinutes >= 15 else { return nil }
            let integrationCapacity = max(10, Int(Double(possibleMinutes) * 0.8) / 5 * 5)
            let integration = max(10, min(target.recommendedMinutes, integrationCapacity))
            let session = min(possibleMinutes, max(integration, Int(ceil(Double(integration) * 1.25 / 5)) * 5))
            let start = captureStart(peak: best.time, minutes: session, nightStart: first.time, nightEnd: last.time)
            let end = start.addingTimeInterval(Double(session * 60))
            let forecastComplete = window.allSatisfy { $0.weather != nil }
            let qualified = Sample(time: best.time, altitude: best.altitude, azimuth: best.azimuth,
                moonSeparation: best.moonSeparation, weather: forecastComplete ? best.weather : nil, score: best.score)
            let final = finalScore(target: target, best: qualified, possibleMinutes: possibleMinutes, moonIllumination: sky.moonIllumination)
            return (target, qualified, final, start, end, integration, possibleMinutes)
        }

        return unranked.sorted { $0.2 > $1.2 }.enumerated().map { index, item in
            CapturePlan(
                rank: index + 1,
                target: item.0,
                score: item.2,
                condition: quality(item.2),
                bestTime: item.1.time,
                start: item.3,
                end: item.4,
                altitude: item.1.altitude,
                azimuth: item.1.azimuth,
                direction: compass(item.1.azimuth),
                moonSeparation: item.1.moonSeparation,
                exposureSeconds: 10,
                integrationMinutes: item.5,
                sessionMinutes: Int(item.4.timeIntervalSince(item.3) / 60),
                visibleMinutes: item.6,
                acceptedFrames: item.5 * 60 / 10,
                weather: item.1.weather
            )
        }
    }

    private static func continuousSegments(_ samples: [Sample], usable: [Bool]) -> [[Sample]] {
        var result: [[Sample]] = []
        var current: [Sample] = []
        for (index, sample) in samples.enumerated() {
            if usable.indices.contains(index), usable[index] {
                current.append(sample)
            } else if !current.isEmpty {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func segmentValue(_ segment: [Sample]) -> Double {
        guard let best = segment.max(by: { $0.score < $1.score }) else { return -.infinity }
        return best.score + min(12, Double(segment.count) * 0.35)
    }

    private static func evaluate(_ target: AstroTarget, at date: Date, coordinate: AstroCoordinate, sky: SkyContext) -> Sample {
        let position = horizontalPosition(raHours: target.rightAscensionHours, decDegrees: target.declinationDegrees, at: date, coordinate: coordinate)
        let moon = MoonMath.equatorial(at: date)
        let separation = angularSeparation(ra1: target.rightAscensionHours * 15, dec1: target.declinationDegrees, ra2: moon.ra, dec2: moon.dec)
        let weather = nearestWeather(sky.weather, to: date)
        let cloud = weather?.cloudPercent ?? 35
        let precipitation = weather?.precipitationPercent ?? 15
        let gust = weather?.gustMPH ?? 7
        let altitudeScore = min(100, max(0, (position.altitude - 20) / 55 * 100))
        let moonPenalty = sky.moonIllumination * max(0, (80 - separation) / 80) * (target.filterEnabled ? 18 : 35)
        let score = altitudeScore * 0.58 + (100 - cloud) * 0.25 + (100 - precipitation) * 0.08 + max(0, 100 - gust * 4) * 0.09 - moonPenalty
        return Sample(time: date, altitude: position.altitude, azimuth: position.azimuth, moonSeparation: separation, weather: weather, score: score)
    }

    private static func finalScore(target: AstroTarget, best: Sample, possibleMinutes: Int, moonIllumination: Double) -> Int {
        var result = best.score
        if possibleMinutes < target.recommendedMinutes { result -= Double(target.recommendedMinutes - possibleMinutes) * 0.08 }
        if !target.filterEnabled && moonIllumination > 0.65 && best.moonSeparation < 75 { result -= 8 }
        if best.weather == nil { result = min(result, 69) }
        return Int(round(min(99, max(1, result))))
    }

    private static func quality(_ score: Int) -> String {
        if score >= 80 { return "EXCELLENT" }
        if score >= 65 { return "GOOD" }
        if score >= 50 { return "FAIR" }
        return "DIFFICULT"
    }

    private static func captureStart(peak: Date, minutes: Int, nightStart: Date, nightEnd: Date) -> Date {
        let half = Double(minutes * 30)
        var start = peak.addingTimeInterval(-half)
        if start < nightStart { start = nightStart }
        if start.addingTimeInterval(Double(minutes * 60)) > nightEnd {
            start = nightEnd.addingTimeInterval(Double(-minutes * 60))
        }
        return max(start, nightStart)
    }

    private static func nearestWeather(_ values: [WeatherPoint], to date: Date) -> WeatherPoint? {
        guard let point = values.filter({ $0.isValid }).min(by: { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }),
              abs(point.time.timeIntervalSince(date)) <= 3600 else { return nil }
        return point
    }

    private static func horizontalPosition(raHours: Double, decDegrees: Double, at date: Date, coordinate: AstroCoordinate) -> (altitude: Double, azimuth: Double) {
        let jd = julianDate(date)
        let t = (jd - 2_451_545.0) / 36_525
        let gmst = normalize(280.46061837 + 360.98564736629 * (jd - 2_451_545.0) + 0.000387933 * t * t - t * t * t / 38_710_000)
        let hourAngle = radians(normalize180(gmst + coordinate.longitude - raHours * 15))
        let latitude = radians(coordinate.latitude)
        let declination = radians(decDegrees)
        let altitude = degrees(asin(sin(latitude) * sin(declination) + cos(latitude) * cos(declination) * cos(hourAngle)))
        let azimuth = normalize(degrees(atan2(sin(hourAngle), cos(hourAngle) * sin(latitude) - tan(declination) * cos(latitude))) + 180)
        return (altitude, azimuth)
    }

    private static func angularSeparation(ra1: Double, dec1: Double, ra2: Double, dec2: Double) -> Double {
        let value = sin(radians(dec1)) * sin(radians(dec2)) + cos(radians(dec1)) * cos(radians(dec2)) * cos(radians(ra1 - ra2))
        return degrees(acos(min(1, max(-1, value))))
    }

    private static func compass(_ azimuth: Double) -> String {
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return directions[Int(round(normalize(azimuth) / 45)) % 8]
    }
}
