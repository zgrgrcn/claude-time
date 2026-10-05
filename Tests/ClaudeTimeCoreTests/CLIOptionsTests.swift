import XCTest
@testable import ClaudeTimeCore

final class CLIOptionsTests: XCTestCase {
    func testDefaults() throws {
        let o = try CLIOptions.parse([])
        XCTAssertEqual(o, CLIOptions())
        XCTAssertEqual(o.action, .report)
        XCTAssertEqual(o.idleMinutes, 15)
        XCTAssertEqual(o.days, 14)
        XCTAssertFalse(o.json)
        XCTAssertTrue(o.useCache)
        XCTAssertNil(o.root)
        XCTAssertNil(o.filter)
    }

    func testAllOptions() throws {
        let o = try CLIOptions.parse(["--idle", "30", "--days", "7", "--json", "--no-cache",
                                      "--root", "~/demo", "payments"])
        XCTAssertEqual(o.idleMinutes, 30)
        XCTAssertEqual(o.days, 7)
        XCTAssertTrue(o.json)
        XCTAssertFalse(o.useCache)
        XCTAssertEqual(o.root, "~/demo")
        XCTAssertEqual(o.filter, "payments")
        XCTAssertEqual(try CLIOptions.parse(["--idle", "2.5"]).idleMinutes, 2.5)
        XCTAssertEqual(try CLIOptions.parse(["api", "web"]).filter, "web")  // last one wins
    }

    func testHelpAndVersionStopParsing() throws {
        XCTAssertEqual(try CLIOptions.parse(["--version"]).action, .version)
        XCTAssertEqual(try CLIOptions.parse(["-v"]).action, .version)
        XCTAssertEqual(try CLIOptions.parse(["-h"]).action, .help)
        XCTAssertEqual(try CLIOptions.parse(["--help", "--bogus"]).action, .help)
        XCTAssertEqual(try CLIOptions.parse(["--json", "--version", "--idle"]).action, .version)
    }

    func testErrors() {
        func failure(_ args: [String]) -> CLIOptions.ParseError? {
            do { _ = try CLIOptions.parse(args); return nil } catch { return error as? CLIOptions.ParseError }
        }
        let idle = "--idle expects a number of minutes greater than 0"
        for args in [["--idle"], ["--idle", "0"], ["--idle", "-5"], ["--idle", "abc"], ["--idle", "inf"], ["--idle", "nan"]] {
            XCTAssertEqual(failure(args)?.message, idle, "\(args)")
        }
        let days = "--days expects a whole number greater than 0"
        for args in [["--days"], ["--days", "0"], ["--days", "1.5"], ["--days", "x"]] {
            XCTAssertEqual(failure(args)?.message, days, "\(args)")
        }
        XCTAssertEqual(failure(["--root"])?.message, "--root expects a directory")
        XCTAssertEqual(failure(["--root", ""])?.message, "--root expects a directory")
        XCTAssertEqual(failure(["--export"])?.message, "--export expects a directory")
        XCTAssertEqual(try CLIOptions.parse(["--export", "~/sync"]).export, "~/sync")
        XCTAssertEqual(failure(["--bogus"]), CLIOptions.ParseError(message: "unknown option: --bogus", showUsage: true))
        XCTAssertEqual(failure(["--idle"])?.showUsage, false)
    }
}
