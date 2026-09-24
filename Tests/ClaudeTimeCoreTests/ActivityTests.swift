import XCTest
@testable import ClaudeTimeCore

final class ActivityTests: XCTestCase {
    func testBlocksSplitOnIdleGap() {
        let ts: [Double] = [0, 60, 120, 2000, 2060]
        let b = Activity.blocks(ts, idle: 900)
        XCTAssertEqual(b, [Block(start: 0, end: 120), Block(start: 2000, end: 2060)])
        XCTAssertEqual(Activity.seconds(b, from: -1, to: 1e9), 180)
        XCTAssertEqual(Activity.seconds(b, from: 100, to: 2030), 20 + 30)
    }

    func testISOParse() {
        let s = Array("2026-08-23T13:06:43.782Z".utf8)
        let t: Double? = s.withUnsafeBytes { TranscriptStore.parseISO8601($0.baseAddress!, $0.count, at: 0) }
        XCTAssertNotNil(t)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(f.date(from: "2026-08-23T13:06:43.782Z")!.timeIntervalSince1970, t!, accuracy: 0.001)
    }

    func testScanFileExtractsFields() throws {
        let line1 = #"{"type":"user","cwd":"/Users/x/github/foo-bar","timestamp":"2026-08-23T13:06:43.782Z","message":{"role":"user","content":"hi"}}"# + "\n"
        let line2 = #"{"type":"assistant","cwd":"/Users/x/github/foo-bar","timestamp":"2026-08-23T13:06:50.000Z","message":{"role":"assistant","content":[{"type":"text","text":"x"}]}}"# + "\n"
        let line3 = #"{"type":"user","timestamp":"2026-08-23T13:07:00.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"y"}]}}"# + "\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ct-test-\(UUID()).jsonl")
        try (line1 + line2 + line3).write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let f = try TranscriptStore.scanFile(url)
        XCTAssertEqual(f.timestamps.count, 3)
        XCTAssertEqual(f.cwd, "/Users/x/github/foo-bar")
        XCTAssertEqual(f.prompts, 1)
    }

    func testMergedTimelineDoesNotDoubleCountParallelSessions() {
        // Two projects worked on in parallel from t=0 to t=600, then only one of them until t=900.
        let a = Project(id: "a", path: "/a", name: "a", sessionCount: 1, fileCount: 1, prompts: 1,
                        timestamps: stride(from: 0.0, through: 900, by: 60).map { $0 })
        let b = Project(id: "b", path: "/b", name: "b", sessionCount: 1, fileCount: 1, prompts: 1,
                        timestamps: stride(from: 30.0, through: 570, by: 60).map { $0 })
        let w = TimeWindows(now: Date(timeIntervalSince1970: 1000))
        let sum = Activity.stats(a.timestamps, idle: 900, windows: w).total
            + Activity.stats(b.timestamps, idle: 900, windows: w).total
        let merged = Activity.stats(Activity.merged([a, b]), idle: 900, windows: w).total
        XCTAssertEqual(merged, 900)
        XCTAssertEqual(sum, 900 + 540)
    }

    func testTimeWindowsStartOnMonday() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 2
        let thursday = ISO8601DateFormatter().date(from: "2026-09-24T12:45:00Z")!
        let w = TimeWindows(now: thursday, calendar: cal)
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(iso.string(from: Date(timeIntervalSince1970: w.todayStart)), "2026-09-24T00:00:00Z")
        XCTAssertEqual(iso.string(from: Date(timeIntervalSince1970: w.weekStart)), "2026-09-21T00:00:00Z")
        XCTAssertEqual(iso.string(from: Date(timeIntervalSince1970: w.monthStart)), "2026-09-01T00:00:00Z")
    }
}
