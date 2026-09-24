import XCTest
@testable import ClaudeTimeCore

final class FormatTests: XCTestCase {
    func testDuration() {
        XCTAssertEqual(Format.duration(0), "–")
        XCTAssertEqual(Format.duration(0, zero: "0m"), "0m")
        XCTAssertEqual(Format.duration(-5), "–")
        XCTAssertEqual(Format.duration(59), "<1m")
        XCTAssertEqual(Format.duration(60), "1m")
        XCTAssertEqual(Format.duration(32 * 60), "32m")
        XCTAssertEqual(Format.duration(3600), "1h 00m")
        XCTAssertEqual(Format.duration(3900), "1h 05m")
        XCTAssertEqual(Format.duration(5 * 3600 + 42 * 60 + 59), "5h 42m")  // seconds are dropped
        XCTAssertEqual(Format.duration(123 * 3600), "123h 00m")
    }

    func testThresholdLabels() {
        XCTAssertEqual([5.0, 10, 15, 30, 60, 120, 240].map { Format.threshold(minutes: $0) },
                       ["5m", "10m", "15m", "30m", "1h", "2h", "4h"])
        XCTAssertEqual(Format.threshold(minutes: 90), "1h 30m")
        XCTAssertEqual(Format.threshold(minutes: 0.5), "30s")
        XCTAssertEqual(Format.threshold(minutes: 1.5), "1m 30s")
    }

    func testCount() {
        XCTAssertEqual(Format.count(0, "project"), "0 projects")
        XCTAssertEqual(Format.count(1, "project"), "1 project")
        XCTAssertEqual(Format.count(14, "day"), "14 days")
    }

    private let utc = TimeZone(identifier: "UTC")!
    private let thursday = ISO8601DateFormatter().date(from: "2026-09-24T12:45:00Z")!

    func testDatesFollowTheGivenLocale() {
        let us = DateFormats(locale: Locale(identifier: "en_US"), timeZone: utc)
        XCTAssertTrue(us.dateTime(thursday).hasPrefix("9/24/26"), us.dateTime(thursday))
        XCTAssertTrue(us.dateTime(thursday).contains("12:45"), us.dateTime(thursday))
        XCTAssertTrue(us.time(thursday).hasPrefix("12:45") && us.time(thursday).hasSuffix("PM"), us.time(thursday))
        XCTAssertEqual(us.day(thursday), "Thu, Sep 24")
        XCTAssertEqual(us.dateTime(nil), "–")

        let gb = DateFormats(locale: Locale(identifier: "en_GB"), timeZone: utc)
        XCTAssertTrue(gb.dateTime(thursday).hasPrefix("24/09/2026"), gb.dateTime(thursday))
        XCTAssertEqual(gb.time(thursday), "12:45")
        XCTAssertEqual(gb.day(thursday), "Thu 24 Sep")

        let tokyo = DateFormats(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        XCTAssertTrue(tokyo.time(thursday).hasPrefix("9:45"), tokyo.time(thursday))
    }

    func testDayKeyIsISOWhateverTheLocale() {
        XCTAssertEqual(Format.dayKey(thursday, timeZone: utc), "2026-09-24")
        XCTAssertEqual(Format.dayKey(thursday, timeZone: TimeZone(identifier: "Pacific/Kiritimati")!), "2026-09-25")
    }
}
