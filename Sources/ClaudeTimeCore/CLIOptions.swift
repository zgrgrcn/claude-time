import Foundation

/// The `claude-time` command line, parsed. Lives in the core module so it can be unit tested.
public struct CLIOptions: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case report, help, version }

    public var action: Action = .report
    /// Silences longer than this don't count as work.
    public var idleMinutes: Double = 15
    /// Days in the per-project daily breakdown.
    public var days: Int = 14
    public var json = false
    public var useCache = true
    /// `--root` value as typed; resolve with `TranscriptStore.resolveRoot(_:)`.
    public var root: String?
    /// `--export` destination: write a usage-only copy of the transcripts there instead of a report.
    public var export: String?
    /// Case-insensitive substring of a project's name or path.
    public var filter: String?

    public init() {}

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let message: String
        /// True when the full usage text helps (unknown option).
        public let showUsage: Bool
        public var description: String { message }
    }

    /// Parses arguments (without the program name). `--help` and `--version` stop parsing
    /// right away, like the rest of the options they are handled in order.
    public static func parse(_ arguments: [String]) throws -> CLIOptions {
        var o = CLIOptions()
        var it = arguments.makeIterator()
        while let a = it.next() {
            switch a {
            case "-h", "--help":
                o.action = .help
                return o
            case "-v", "--version":
                o.action = .version
                return o
            case "--json":
                o.json = true
            case "--no-cache":
                o.useCache = false
            case "--idle":
                guard let v = it.next(), let m = Double(v), m > 0, m.isFinite else {
                    throw ParseError(message: "--idle expects a number of minutes greater than 0", showUsage: false)
                }
                o.idleMinutes = m
            case "--days":
                guard let v = it.next(), let d = Int(v), d > 0 else {
                    throw ParseError(message: "--days expects a whole number greater than 0", showUsage: false)
                }
                o.days = d
            case "--root":
                guard let v = it.next(), !v.isEmpty else {
                    throw ParseError(message: "--root expects a directory", showUsage: false)
                }
                o.root = v
            case "--export":
                guard let v = it.next(), !v.isEmpty else {
                    throw ParseError(message: "--export expects a directory", showUsage: false)
                }
                o.export = v
            default:
                if a.hasPrefix("-") { throw ParseError(message: "unknown option: \(a)", showUsage: true) }
                o.filter = a
            }
        }
        return o
    }
}
