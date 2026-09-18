import XCTest
@testable import SenseiAstroCore

final class CloudForecastTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func point(_ offset: Double, cloud: Double = 20) -> WeatherPoint {
        WeatherPoint(time: now.addingTimeInterval(offset), cloudPercent: cloud,
            precipitationPercent: 0, humidityPercent: 50, dewPointF: 40,
            temperatureF: 60, windMPH: 3, gustMPH: 5)
    }
    func testDistantFutureSampleIsNeverNow() {
        XCTAssertNil(CloudForecast.nearNow([point(7200)], now: now))
        XCTAssertNil(CloudForecast.nearNow([point(-1801)], now: now))
        XCTAssertEqual(CloudForecast.nearNow([point(-1800), point(7200)], now: now)?.time, now.addingTimeInterval(-1800))
    }
    func testInvalidAndDuplicateSamplesAreExcluded() {
        let result = CloudForecast.points([point(0), point(0), point(3600, cloud: 101), point(-3600)],
            from: now, through: now.addingTimeInterval(7200))
        XCTAssertEqual(result.count, 1)
    }
    func testClearestHourExcludesDaylightAndElapsedHours() {
        let sky = SkyContext(start: now.addingTimeInterval(3600), end: now.addingTimeInterval(10800),
            moonPhase: "Test", moonIllumination: 0, moonrise: "", moonset: "", sunset: "",
            darknessLabel: "Test", weather: [], sourceOnline: true)
        let result = CloudForecast.clearestTonight([point(-3600, cloud: 0), point(0, cloud: 0),
            point(3600, cloud: 30), point(7200, cloud: 15), point(14400, cloud: 0)], sky: sky, now: now)
        XCTAssertEqual(result?.time, now.addingTimeInterval(7200))
        XCTAssertNil(CloudForecast.clearestTonight([point(7200)], sky: sky, now: now.addingTimeInterval(14400)))
    }
    func testFreshnessBounds() {
        XCTAssertTrue(CloudForecast.isFresh(updatedAt: now, now: now))
        XCTAssertFalse(CloudForecast.isFresh(updatedAt: now.addingTimeInterval(-1801), now: now))
        XCTAssertFalse(CloudForecast.isFresh(updatedAt: now.addingTimeInterval(120), now: now))
    }
}
