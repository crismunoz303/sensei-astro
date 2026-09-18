import XCTest
@testable import SenseiAstroCore

final class LocationPolicyTests: XCTestCase {
    func testRejectsCachedInvalidAndFutureFixes() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(LocationPolicy.accepts(accuracy: 100, timestamp: now, now: now))
        XCTAssertTrue(LocationPolicy.accepts(accuracy: 5_000, timestamp: now, now: now))
        XCTAssertFalse(LocationPolicy.accepts(accuracy: -1, timestamp: now, now: now))
        XCTAssertFalse(LocationPolicy.accepts(accuracy: .nan, timestamp: now, now: now))
        XCTAssertFalse(LocationPolicy.accepts(accuracy: 100, timestamp: now.addingTimeInterval(-61), now: now))
        XCTAssertFalse(LocationPolicy.accepts(accuracy: 100, timestamp: now.addingTimeInterval(11), now: now))
    }

    func testMovementAndImprovedAccuracyTriggerUpdatesWithoutGPSJitter() {
        XCTAssertFalse(LocationPolicy.shouldUpdate(distance: 50, oldAccuracy: 100, newAccuracy: 80))
        XCTAssertTrue(LocationPolicy.shouldUpdate(distance: 500, oldAccuracy: 100, newAccuracy: 100))
        XCTAssertTrue(LocationPolicy.shouldUpdate(distance: 100, oldAccuracy: 5_000, newAccuracy: 100))
    }
}
