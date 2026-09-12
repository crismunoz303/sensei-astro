import XCTest
@testable import SenseiAstroCore

final class PlannerEngineTests: XCTestCase {
    private let coordinate = AstroCoordinate.huntingtonPark

    func testAstronomicalNightIsOrderedAndCrossesMinusEighteenDegrees() throws {
        let base = date("2026-09-11T12:00:00Z")
        let night = try XCTUnwrap(SolarMath.astronomicalNight(base: base, coordinate: coordinate))

        XCTAssertLessThan(night.start, night.end)
        XCTAssertGreaterThan(night.end.timeIntervalSince(night.start), 5 * 3600)
        XCTAssertLessThan(night.end.timeIntervalSince(night.start), 12 * 3600)
        XCTAssertEqual(SolarMath.altitude(at: night.start, coordinate: coordinate), -18, accuracy: 0.25)
        XCTAssertEqual(SolarMath.altitude(at: night.end, coordinate: coordinate), -18, accuracy: 0.25)
    }

    func testElapsedNightReturnsNoPlan() {
        let start = date("2026-09-12T03:00:00Z")
        let end = start.addingTimeInterval(6 * 3600)
        let plans = PlannerEngine.rank([circumpolarTarget], coordinate: coordinate, sky: sky(start: start, end: end), now: end.addingTimeInterval(1))
        XCTAssertTrue(plans.isEmpty)
    }

    func testSessionNeverExtendsBeyondAstronomicalDawn() throws {
        let start = date("2026-09-12T03:00:00Z")
        let end = start.addingTimeInterval(47 * 60)
        let plan = try XCTUnwrap(PlannerEngine.rank([circumpolarTarget], coordinate: coordinate, sky: sky(start: start, end: end), now: start).first)
        XCTAssertGreaterThanOrEqual(plan.start, start)
        XCTAssertLessThanOrEqual(plan.end, end)
        XCTAssertLessThanOrEqual(plan.visibleMinutes, 47)
    }

    func testUnderFifteenMinutesRemainingDoesNotInventSession() {
        let start = date("2026-09-12T03:00:00Z")
        XCTAssertTrue(PlannerEngine.rank([circumpolarTarget], coordinate: coordinate,
            sky: sky(start: start, end: start.addingTimeInterval(14*60)), now: start).isEmpty)
    }

    func testStaleForecastIsNotUsedAsLiveWeather() throws {
        let start = date("2026-09-12T03:00:00Z")
        let stale = WeatherPoint(time: start.addingTimeInterval(-86400), cloudPercent: 0, precipitationPercent: 0, humidityPercent: 50, dewPointF: 40, temperatureF: 60, windMPH: 0, gustMPH: 0)
        let plan = try XCTUnwrap(PlannerEngine.rank([circumpolarTarget], coordinate: coordinate,
            sky: sky(start: start, end: start.addingTimeInterval(3600), weather: [stale]), now: start).first)
        XCTAssertNil(plan.weather); XCTAssertLessThanOrEqual(plan.score, 69)
    }

    func testMissingWeatherNeverBecomesZeroClouds() throws {
        let json = """
        {"hourly":{"time":[1789174800,1789178400],"cloud_cover":[null,15],
        "precipitation_probability":[0,0],"relative_humidity_2m":[50,50],
        "dew_point_2m":[40,40],"temperature_2m":[60,60],"wind_speed_10m":[3,3],"wind_gusts_10m":[5,5]}}
        """
        let points = try WeatherClient.decode(Data(json.utf8))
        XCTAssertEqual(points.count, 1); XCTAssertEqual(points.first?.cloudPercent, 15)
        XCTAssertEqual(points.first?.time.timeIntervalSince1970, 1789178400)
    }

    func testOnePercentMoonIsNotMistakenForFullMoon() {
        XCTAssertEqual(SkyClient.parseIllumination("1%"), 0.01)
        XCTAssertEqual(SkyClient.parseIllumination("0.01"), 0.01)
        XCTAssertEqual(SkyClient.parseIllumination("100%"), 1)
        XCTAssertNil(SkyClient.parseIllumination("unknown"))
        XCTAssertNil(SkyClient.parseIllumination("-1"))
    }

    func testOfflineRankIsCappedBelowExcellent() throws {
        let start = date("2026-09-12T03:00:00Z")
        let end = start.addingTimeInterval(6 * 3600)
        let plan = try XCTUnwrap(PlannerEngine.rank([circumpolarTarget], coordinate: coordinate, sky: sky(start: start, end: end), now: start).first)
        XCTAssertLessThanOrEqual(plan.score, 69)
        XCTAssertEqual(plan.exposureSeconds, 10)
        XCTAssertEqual(plan.acceptedFrames, plan.integrationMinutes * 6)
        XCTAssertGreaterThanOrEqual(plan.sessionMinutes, plan.integrationMinutes)
    }

    func testSevereForecastBreakDoesNotCreateOneLongSession() throws {
        let start = date("2026-09-12T03:00:00Z")
        let end = start.addingTimeInterval(3 * 3600)
        var weather: [WeatherPoint] = []
        for index in 0...12 {
            let severe = (4...8).contains(index)
            weather.append(WeatherPoint(
                time: start.addingTimeInterval(Double(index) * 15 * 60),
                cloudPercent: severe ? 100 : 5,
                precipitationPercent: severe ? 90 : 0,
                humidityPercent: 50,
                dewPointF: 40,
                temperatureF: 60,
                windMPH: severe ? 30 : 3,
                gustMPH: severe ? 40 : 5
            ))
        }
        let plan = try XCTUnwrap(PlannerEngine.rank([circumpolarTarget], coordinate: coordinate, sky: sky(start: start, end: end, weather: weather), now: start).first)
        XCTAssertLessThanOrEqual(plan.sessionMinutes, 60)
        XCTAssertLessThanOrEqual(plan.visibleMinutes, 60)
    }

    private var circumpolarTarget: AstroTarget {
        AstroTarget(id: "TEST", name: "Test Target", rightAscensionHours: 2.5, declinationDegrees: 89, type: "Test", filterEnabled: false, recommendedMinutes: 120, lens: "Tele 1x", framing: "Single frame", note: "Test only")
    }

    private func sky(start: Date, end: Date, weather: [WeatherPoint] = []) -> SkyContext {
        SkyContext(start: start, end: end, moonPhase: "New Moon", moonIllumination: 0, moonrise: "NONE", moonset: "NONE", sunset: "7:00 PM", darknessLabel: "ASTRONOMICAL DARKNESS", weather: weather, sourceOnline: !weather.isEmpty)
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
