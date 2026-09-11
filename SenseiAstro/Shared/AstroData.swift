import Foundation

struct AstroCoordinate: Hashable {
    let latitude: Double
    let longitude: Double

    static let huntingtonPark = AstroCoordinate(latitude: 33.9799942, longitude: -118.2166833)
}

enum AstroData {
    static func load(at coordinate: AstroCoordinate, locationName: String, now: Date = Date()) async -> AstroSnapshot {
        async let weather = WeatherClient.load(coordinate: coordinate)
        async let sky = SkyClient.load(now: now, coordinate: coordinate)
        let weatherResult = await weather
        let skyResult = (await sky).withWeather(weatherResult)
        let plans = PlannerEngine.rank(TargetCatalog.all, coordinate: coordinate, sky: skyResult)
        return AstroSnapshot(locationName: locationName, sky: skyResult, plans: plans, updatedAt: Date())
    }
}

private extension SkyContext {
    func withWeather(_ points: [WeatherPoint]) -> SkyContext {
        SkyContext(start: start, end: end, moonPhase: moonPhase, moonIllumination: moonIllumination, moonrise: moonrise, moonset: moonset, sunset: sunset, weather: points, sourceOnline: sourceOnline && !points.isEmpty)
    }
}

enum WeatherClient {
    private struct Response: Decodable {
        let hourly: Hourly
    }

    private struct Hourly: Decodable {
        let time: [String]
        let cloud_cover: [Double]
        let precipitation_probability: [Double]
        let relative_humidity_2m: [Double]
        let dew_point_2m: [Double]
        let temperature_2m: [Double]
        let wind_speed_10m: [Double]
        let wind_gusts_10m: [Double]
    }

    static func load(coordinate: AstroCoordinate) async -> [WeatherPoint] {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(coordinate.longitude)),
            URLQueryItem(name: "hourly", value: "cloud_cover,precipitation_probability,relative_humidity_2m,dew_point_2m,temperature_2m,wind_speed_10m,wind_gusts_10m"),
            URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
            URLQueryItem(name: "wind_speed_unit", value: "mph"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "2")
        ]
        do {
            let (data, response) = try await URLSession.shared.data(from: components.url!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            let hourly = try JSONDecoder().decode(Response.self, from: data).hourly
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
            return hourly.time.indices.compactMap { index in
                guard let date = formatter.date(from: hourly.time[index]) else { return nil }
                return WeatherPoint(
                    time: date,
                    cloudPercent: value(hourly.cloud_cover, index),
                    precipitationPercent: value(hourly.precipitation_probability, index),
                    humidityPercent: value(hourly.relative_humidity_2m, index),
                    dewPointF: value(hourly.dew_point_2m, index),
                    temperatureF: value(hourly.temperature_2m, index),
                    windMPH: value(hourly.wind_speed_10m, index),
                    gustMPH: value(hourly.wind_gusts_10m, index)
                )
            }
        } catch {
            return []
        }
    }

    private static func value(_ values: [Double], _ index: Int) -> Double {
        values.indices.contains(index) ? values[index] : 0
    }
}

enum SkyClient {
    private struct Response: Decodable {
        let properties: Properties
    }
    private struct Properties: Decodable { let data: DayData }
    private struct DayData: Decodable {
        let sundata: [Event]?
        let moondata: [Event]?
        let curphase: String?
        let fracillum: String?
    }
    private struct Event: Decodable { let phen: String; let time: String }

    static func load(now: Date, coordinate: AstroCoordinate) async -> SkyContext {
        let calendar = Calendar.current
        let base = now.localHour < 6
            ? calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
            : calendar.startOfDay(for: now)
        let next = calendar.date(byAdding: .day, value: 1, to: base)!
        async let first = day(base, coordinate: coordinate)
        async let second = day(next, coordinate: coordinate)
        let (todayData, tomorrowData) = await (first, second)

        let fallbackStart = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: base)!
        let fallbackEnd = calendar.date(bySettingHour: 5, minute: 30, second: 0, of: next)!
        let start = eventDate(todayData?.sundata, matching: "end civil twilight", day: base) ?? fallbackStart
        let end = eventDate(tomorrowData?.sundata, matching: "begin civil twilight", day: next) ?? fallbackEnd
        let moon = MoonMath.status(at: Date(timeIntervalSince1970: (start.timeIntervalSince1970 + end.timeIntervalSince1970) / 2))
        let parsedIllumination = todayData?.fracillum.flatMap { raw -> Double? in
            guard let number = Double(raw.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) else { return nil }
            return min(1, max(0, number > 1 ? number / 100 : number))
        }

        return SkyContext(
            start: start,
            end: end,
            moonPhase: todayData?.curphase ?? moon.name,
            moonIllumination: parsedIllumination ?? moon.illumination,
            moonrise: displayEvent(todayData?.moondata, matching: "rise"),
            moonset: displayEvent(todayData?.moondata, matching: "set"),
            sunset: displayEvent(todayData?.sundata, matching: "set"),
            weather: [],
            sourceOnline: todayData != nil && tomorrowData != nil
        )
    }

    private static func day(_ date: Date, coordinate: AstroCoordinate) async -> DayData? {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timezone = Double(TimeZone.current.secondsFromGMT(for: date)) / 3600
        var components = URLComponents(string: "https://aa.usno.navy.mil/api/rstt/oneday")!
        components.queryItems = [
            URLQueryItem(name: "date", value: dateFormatter.string(from: date)),
            URLQueryItem(name: "coords", value: String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude)),
            URLQueryItem(name: "tz", value: String(format: "%.1f", timezone)),
            URLQueryItem(name: "ID", value: "SenseiAstro")
        ]
        do {
            let (data, response) = try await URLSession.shared.data(from: components.url!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(Response.self, from: data).properties.data
        } catch {
            return nil
        }
    }

    private static func eventDate(_ events: [Event]?, matching text: String, day: Date) -> Date? {
        guard let event = events?.first(where: { $0.phen.lowercased() == text }) else { return nil }
        let parts = event.time.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
    }

    private static func displayEvent(_ events: [Event]?, matching text: String) -> String {
        guard let event = events?.first(where: { $0.phen.lowercased() == text }) else { return "NONE" }
        let input = DateFormatter()
        input.locale = Locale(identifier: "en_US_POSIX")
        input.dateFormat = "HH:mm"
        let output = DateFormatter()
        output.locale = Locale(identifier: "en_US_POSIX")
        output.dateFormat = "h:mm a"
        return input.date(from: event.time).map(output.string) ?? event.time
    }
}

private extension Date {
    var localHour: Int { Calendar.current.component(.hour, from: self) }
}

enum MoonMath {
    struct Status { let name: String; let illumination: Double }

    static func status(at date: Date) -> Status {
        let synodic = 29.530588853
        let epoch = Date(timeIntervalSince1970: 947182440)
        var age = date.timeIntervalSince(epoch) / 86_400
        age.formTruncatingRemainder(dividingBy: synodic)
        if age < 0 { age += synodic }
        let illumination = (1 - cos(age / synodic * .pi * 2)) / 2
        let names = ["New Moon", "Waxing Crescent", "First Quarter", "Waxing Gibbous", "Full Moon", "Waning Gibbous", "Last Quarter", "Waning Crescent"]
        let index = Int(floor((age + synodic / 16) / (synodic / 8))) % 8
        return Status(name: names[index], illumination: illumination)
    }

    static func equatorial(at date: Date) -> (ra: Double, dec: Double) {
        let d = julianDate(date) - 2_451_545.0
        let longitude = normalize(218.316 + 13.176396 * d + 6.289 * sin(radians(normalize(134.963 + 13.064993 * d))))
        let latitude = 5.128 * sin(radians(normalize(93.272 + 13.229350 * d)))
        let obliquity = radians(23.439 - 0.0000004 * d)
        let lambda = radians(longitude)
        let beta = radians(latitude)
        let ra = normalize(degrees(atan2(sin(lambda) * cos(obliquity) - tan(beta) * sin(obliquity), cos(lambda))))
        let dec = degrees(asin(sin(beta) * cos(obliquity) + cos(beta) * sin(obliquity) * sin(lambda)))
        return (ra, dec)
    }
}

func julianDate(_ date: Date) -> Double { date.timeIntervalSince1970 / 86_400 + 2_440_587.5 }
func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
func normalize(_ value: Double) -> Double { (value.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) }
func normalize180(_ value: Double) -> Double { let n = normalize(value); return n > 180 ? n - 360 : n }
