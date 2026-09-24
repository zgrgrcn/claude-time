import XCTest
@testable import ClaudeTimeCore

final class TranscriptStoreTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ct-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: Root and cache location

    func testResolveRootPrecedence() {
        let env = ["CLAUDE_TIME_ROOT": "/tmp/from-env"]
        XCTAssertEqual(TranscriptStore.resolveRoot("/tmp/from-flag", environment: env).path, "/tmp/from-flag")
        XCTAssertEqual(TranscriptStore.resolveRoot(nil, environment: env).path, "/tmp/from-env")
        XCTAssertEqual(TranscriptStore.resolveRoot(nil, environment: [:]), TranscriptStore.defaultRoot)
        XCTAssertEqual(TranscriptStore.resolveRoot("", environment: ["CLAUDE_TIME_ROOT": ""]), TranscriptStore.defaultRoot)
        XCTAssertEqual(TranscriptStore.resolveRoot("", environment: env).path, "/tmp/from-env")
    }

    func testResolveRootExpandsTildeAndRelativePaths() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(TranscriptStore.resolveRoot("~/demo", environment: [:]).path, home + "/demo")
        XCTAssertEqual(TranscriptStore.resolveRoot(nil, environment: ["CLAUDE_TIME_ROOT": "~/demo"]).path, home + "/demo")
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path
        XCTAssertEqual(TranscriptStore.resolveRoot("demo/../demo2", environment: [:]).path, cwd + "/demo2")
    }

    func testEachRootGetsItsOwnCacheFile() {
        let real = TranscriptStore.defaultCacheURL(for: TranscriptStore.defaultRoot)
        XCTAssertEqual(real.lastPathComponent, "cache.json")
        let a = TranscriptStore.defaultCacheURL(for: URL(fileURLWithPath: "/tmp/demo-a"))
        let b = TranscriptStore.defaultCacheURL(for: URL(fileURLWithPath: "/tmp/demo-b"))
        XCTAssertNotEqual(a, real)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, TranscriptStore.defaultCacheURL(for: URL(fileURLWithPath: "/tmp/demo-a/")))
        XCTAssertTrue(a.lastPathComponent.hasPrefix("cache-") && a.pathExtension == "json", a.lastPathComponent)
        XCTAssertEqual(a.deletingLastPathComponent(), real.deletingLastPathComponent())
        XCTAssertEqual(TranscriptStore(root: URL(fileURLWithPath: "/tmp/demo-a")).cacheURL, a)
        XCTAssertNil(TranscriptStore(root: URL(fileURLWithPath: "/tmp/demo-a"), useCache: false).cacheURL)
    }

    // MARK: Scanning an alternate root

    private func line(_ ts: String, cwd: String?, prompt: String? = nil) -> String {
        let cwdField = cwd.map { #""cwd":"\#($0)","# } ?? ""
        let message = prompt.map { #"{"role":"user","content":"\#($0)"}"# }
            ?? #"{"role":"assistant","content":[{"type":"text","text":"ok"}]}"#
        return #"{"type":"x",\#(cwdField)"message":\#(message),"timestamp":"\#(ts)"}"# + "\n"
    }

    private func write(_ relativePath: String, _ lines: [String]) throws {
        let url = tmp.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.joined().write(to: url, atomically: true, encoding: .utf8)
    }

    func testScansProjectsSessionsAndSubagents() throws {
        let cwd = "/Users/you/code/app-a"
        try write("-Users-you-code-app-a/s1.jsonl", [
            line("2026-09-24T09:00:00.000Z", cwd: cwd, prompt: "first"),
            line("2026-09-24T09:05:00.000Z", cwd: cwd),
        ])
        try write("-Users-you-code-app-a/s2.jsonl", [  // parallel session, shares one timestamp with s1
            line("2026-09-24T09:05:00.000Z", cwd: cwd, prompt: "second"),
            line("2026-09-24T09:07:00.000Z", cwd: cwd),
        ])
        try write("-Users-you-code-app-a/s1/subagents/agent-1.jsonl", [
            line("2026-09-24T09:02:00.000Z", cwd: cwd, prompt: "task for a subagent"),
        ])
        try write("-Users-you-code-app-a/memory/ignored.jsonl", [line("2026-09-24T12:00:00.000Z", cwd: cwd)])
        try write("-Users-you-code-app-a/notes.txt", ["not a transcript"])
        try write("-Users-you-code-app-b/s3.jsonl", [line("2026-09-20T10:00:00Z", cwd: nil)])  // no cwd recorded

        let store = TranscriptStore(root: tmp, useCache: false)
        let r = try store.scan()
        XCTAssertEqual(r.projects.count, 2)
        XCTAssertEqual(r.scannedFiles, 4)
        XCTAssertEqual(r.reusedFiles, 0)

        let a = try XCTUnwrap(r.projects.first { $0.id == "-Users-you-code-app-a" })
        XCTAssertEqual(a.name, "app-a")
        XCTAssertEqual(a.path, cwd)
        XCTAssertEqual(a.sessionCount, 2)   // top-level files only
        XCTAssertEqual(a.fileCount, 3)      // plus the subagent transcript; memory/ is skipped
        XCTAssertEqual(a.prompts, 3)
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(a.timestamps.map { iso.string(from: Date(timeIntervalSince1970: $0)) },
                       ["2026-09-24T09:00:00Z", "2026-09-24T09:02:00Z", "2026-09-24T09:05:00Z", "2026-09-24T09:07:00Z"])

        let b = try XCTUnwrap(r.projects.first { $0.id == "-Users-you-code-app-b" })
        XCTAssertEqual(b.path, "/Users/you/code/app/b")  // guessed from the folder name
        XCTAssertEqual(b.prompts, 0)
    }

    func testCacheReusesUnchangedFilesAndCacheFreeModeWritesNothing() throws {
        try write("-p/s.jsonl", [line("2026-09-24T09:00:00Z", cwd: "/p", prompt: "hi")])
        let cache = tmp.appendingPathComponent("caches/cache.json")

        let first = try TranscriptStore(root: tmp, cacheURL: cache).scan()
        XCTAssertEqual(first.scannedFiles, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))

        let second = try TranscriptStore(root: tmp, cacheURL: cache).scan()
        XCTAssertEqual(second.scannedFiles, 0)
        XCTAssertEqual(second.reusedFiles, 1)
        XCTAssertEqual(first.projects, second.projects)

        // A cache-free store neither reads nor writes the cache file.
        try FileManager.default.removeItem(at: cache)
        let third = try TranscriptStore(root: tmp, cacheURL: cache, useCache: false).scan()
        XCTAssertEqual(third.scannedFiles, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }

    func testMissingRootThrows() {
        let store = TranscriptStore(root: tmp.appendingPathComponent("nope"), useCache: false)
        XCTAssertThrowsError(try store.scan())
    }
}
