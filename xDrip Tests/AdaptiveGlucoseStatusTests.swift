import XCTest
@testable import xdrip

final class AdaptiveGlucoseStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func status(_ values: [Double], age: TimeInterval = 0, interval: TimeInterval = 300) -> AdaptiveGlucoseStatus {
        let dates = values.indices.map { now.addingTimeInterval(-age - Double($0) * interval) }
        return .resolve(values: values, dates: dates, urgentLow: 60, low: 80, high: 180, urgentHigh: 250, at: now)
    }

    func testNormalAndRangeBoundaries() {
        XCTAssertEqual(status([110, 110]), .normal)
        XCTAssertEqual(status([80]), .warning)
        XCTAssertEqual(status([180]), .warning)
        XCTAssertEqual(status([60]), .critical)
        XCTAssertEqual(status([250]), .critical)
    }

    func testApproachingBothLimitsWarnsWithoutChangingMeasuredValue() {
        XCTAssertEqual(status([165, 155]), .warning)
        XCTAssertEqual(status([95, 105]), .warning)
    }

    func testStaleCriticalReadingDoesNotClaimCurrentCriticalState() {
        XCTAssertEqual(status([50], age: 420), .stale)
        XCTAssertEqual(status([110], age: 419), .normal)
    }

    func testMissingAndSensorErrorValuesNeverShowNormal() {
        for values in [[], [0], [12], [Double.nan], [Double.infinity]] {
            XCTAssertEqual(status(values), .unavailable)
        }
    }

    func testHistoryGapAndDuplicateTimestampDoNotPredict() {
        XCTAssertEqual(status([165, 100], interval: 900), .normal)
        XCTAssertEqual(status([165, 100], interval: 0), .normal)
    }

    func testInvalidLimitsNeverShowNormal() {
        XCTAssertEqual(AdaptiveGlucoseStatus.resolve(values: [110], dates: [now], urgentLow: 70, low: 200, high: 100, urgentHigh: 250, at: now), .unavailable)
    }

    func testFutureReadingIsUnavailable() {
        XCTAssertEqual(status([110], age: -120), .unavailable)
    }
}
