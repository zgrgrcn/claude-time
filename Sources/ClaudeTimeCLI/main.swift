import Foundation
import ClaudeTimeCore

let usage = """
claude-time \(ClaudeTime.version) — time spent in Claude Code, per project

USAGE
  claude-time                    all projects (today / this week / this month / total)
  claude-time <filter>           daily breakdown of projects whose name or path contains <filter>
  claude-time --json [filter]    machine-readable output

OPTIONS
  --idle <minutes>  idle threshold; silences longer than this don't count as work (default 15)
  --days <n>        days to show in the daily breakdown (default 14)
  --root <dir>      transcripts folder to read (default ~/.claude/projects)
  --export <dir>    copy only usage data (cwd, timestamps, prompt count) of every transcript to <dir>,
                    e.g. iCloud Drive; then read all your Macs with --root <dir>
  --no-cache        don't read or write the scan cache; rescan every file
  -v, --version     print the version
  -h, --help        show this help

ENVIRONMENT
  CLAUDE_TIME_ROOT  transcripts folder to read when --root isn't given

Time = the sum of the gaps between transcript timestamps that don't exceed the idle threshold.
Source: ~/.claude/projects/**/*.jsonl, read locally. Nothing leaves your machine.
"""

let options: CLIOptions
do {
    options = try CLIOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    fputs("claude-time: \(error)\n", stderr)
    if (error as? CLIOptions.ParseError)?.showUsage == true { fputs("\n\(usage)\n", stderr) }
    exit(2)
}

switch options.action {
case .help: print(usage); exit(0)
case .version: print("claude-time \(ClaudeTime.version)"); exit(0)
case .report: break
}

var root = TranscriptStore.resolveRoot(options.root)
let defaults = UserDefaults(suiteName: TranscriptStore.defaultsSuite)
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
    fputs("claude-time: no transcripts folder at \(root.path)\n", stderr)
    if root == TranscriptStore.defaultRoot {
        fputs("Use --root <dir> or CLAUDE_TIME_ROOT to read a different folder.\n", stderr)
    }
    exit(1)
}

if let export = options.export {
    let destination = TranscriptStore.resolveRoot(export)
    do {
        let r = try Exporter.export(from: root, to: destination)
        print("exported \(Format.count(r.written, "file")) to \(destination.path), \(r.unchanged) unchanged")
        exit(0)
    } catch {
        fputs("claude-time: export failed: \(error.localizedDescription)\n", stderr); exit(1)
    }
}

// Like the app: with a sync folder set (and no other folder asked for), add this Mac's usage to
// it and read every Mac's usage from it.
if root == TranscriptStore.defaultRoot, let sync = defaults?.string(forKey: Exporter.syncFolderKey) {
    let syncURL = URL(fileURLWithPath: sync)
    do { _ = try Exporter.export(from: root, to: syncURL) } catch {
        fputs("claude-time: couldn't update the sync folder: \(error.localizedDescription)\n", stderr)
    }
    root = syncURL
}

let store = TranscriptStore(root: root, useCache: options.useCache)
let result: ScanResult
let names = defaults?
    .dictionary(forKey: TranscriptStore.namesKey) as? [String: String] ?? [:]  // renamed in the app
do { result = try store.scan(names: names) } catch {
    fputs("claude-time: scan failed: \(error.localizedDescription)\n", stderr); exit(1)
}
let idleMinutes = options.idleMinutes
let days = options.days
let idle = idleMinutes * 60
let windows = TimeWindows()
let projects = result.projects
    .filter { !$0.isProjectless }  // home folder, scratch workspaces, hidden folders
    .filter { Activity.stats($0.timestamps, idle: idle, windows: windows).total >= 60 }   // hide projects under a minute
    .sorted { ($0.timestamps.last ?? 0) > ($1.timestamps.last ?? 0) }

func pad(_ s: String, _ w: Int, right: Bool = false) -> String {
    let n = s.count
    if n >= w { return right ? s : String(s.prefix(w)) }
    let fill = String(repeating: " ", count: w - n)
    return right ? fill + s : s + fill
}

let selected: [Project]
if let f = options.filter?.lowercased() {
    selected = projects.filter { $0.name.lowercased().contains(f) || $0.path.lowercased().contains(f) }
    if selected.isEmpty {
        fputs("No project matches '\(options.filter!)'. Available projects:\n", stderr)
        for p in projects { fputs("  \(p.name)  (\(p.path))\n", stderr) }
        exit(1)
    }
} else {
    selected = projects
}

if options.json {
    struct Out: Encodable {
        struct P: Encodable {
            var name: String, path: String, sessions: Int, prompts: Int
            var todaySeconds: Double, weekSeconds: Double, monthSeconds: Double, totalSeconds: Double
            var firstSeen: Date?, lastSeen: Date?
            var daily: [D]
        }
        struct D: Encodable { var day: String; var seconds: Double }
        var idleMinutes: Double
        var generatedAt: Date
        var projects: [P]
        var allProjects: P
    }
    func make(_ name: String, _ path: String, _ sessions: Int, _ prompts: Int, _ ts: [Double]) -> Out.P {
        let s = Activity.stats(ts, idle: idle, windows: windows)
        let d = Activity.daily(ts, idle: idle, days: days).map { Out.D(day: Format.dayKey($0.day), seconds: $0.seconds) }
        return Out.P(name: name, path: path, sessions: sessions, prompts: prompts,
                     todaySeconds: s.today, weekSeconds: s.week, monthSeconds: s.month, totalSeconds: s.total,
                     firstSeen: s.firstSeen, lastSeen: s.lastSeen, daily: d)
    }
    let out = Out(idleMinutes: idleMinutes, generatedAt: Date(),
                  projects: selected.map { make($0.name, $0.path, $0.sessionCount, $0.prompts, $0.timestamps) },
                  allProjects: make("*", "*", selected.reduce(0) { $0 + $1.sessionCount },
                                    selected.reduce(0) { $0 + $1.prompts }, Activity.merged(selected)))
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    enc.dateEncodingStrategy = .iso8601
    print(String(decoding: try! enc.encode(out), as: UTF8.self))
    exit(0)
}

let threshold = "idle threshold \(Format.threshold(minutes: idleMinutes))"

if options.filter == nil {
    // Overview table
    let totalLabel = "ALL (merged)"
    let columns = [("Today", 8), ("This week", 11), ("This month", 12), ("Total", 10)]
    let lastLabel = "Last activity"
    let nameW = max(totalLabel.count, min(32, projects.map { $0.name.count }.max() ?? 14))
    let dateW = max(lastLabel.count, projects.map { Format.dateTime($0.lastSeen).count }.max() ?? 0)
    func row(_ name: String, _ values: [String], _ last: String) -> String {
        let cells = zip(values, columns).map { pad($0, $1.1, right: true) }.joined()
        return pad(name, nameW) + "  " + cells + (last.isEmpty ? "" : "   " + last)
    }
    func durations(_ s: Stats) -> [String] { [s.today, s.week, s.month, s.total].map { Format.duration($0) } }
    let rule = String(repeating: "─", count: nameW + 2 + columns.reduce(0) { $0 + $1.1 } + 3 + dateW)

    print(row("Project", columns.map(\.0), lastLabel))
    print(rule)
    for p in projects {
        let s = Activity.stats(p.timestamps, idle: idle, windows: windows)
        print(row(p.name, durations(s), Format.dateTime(s.lastSeen)))
    }
    print(rule)
    print(row(totalLabel, durations(Activity.stats(Activity.merged(projects), idle: idle, windows: windows)), ""))
    print("\n\(threshold) · \(Format.count(projects.count, "project")) · "
          + "\(Format.count(result.scannedFiles, "file")) scanned, \(result.reusedFiles) from cache · "
          + String(format: "%.2fs", result.duration))
} else {
    for (i, p) in selected.enumerated() {
        if i > 0 { print() }
        let s = Activity.stats(p.timestamps, idle: idle, windows: windows)
        func d(_ seconds: Double) -> String { Format.duration(seconds, zero: "0m") }
        print("\(p.name)  (\(p.path))")
        print("  First: \(Format.dateTime(s.firstSeen))   Last: \(Format.dateTime(s.lastSeen))")
        print("  Sessions: \(p.sessionCount)   Prompts: \(p.prompts)   Work blocks: \(s.blocks)")
        print("  Today \(d(s.today)) · This week \(d(s.week)) · This month \(d(s.month)) · Total \(d(s.total))")
        if p.machines.count > 1 {
            print("  Macs: " + p.machines.keys.sorted().map { mac in
                let m = Activity.stats(p.machines[mac]!, idle: idle, windows: windows)
                return "\(mac) \(d(m.total)) (today \(d(m.today)))"
            }.joined(separator: " · "))
        }
        let daily = Activity.daily(p.timestamps, idle: idle, days: days)
        let maxS = daily.map(\.seconds).max() ?? 0
        let dayW = (daily.map { Format.dayLabel($0.day).count }.max() ?? 0) + 1
        print("\n  Last \(Format.count(days, "day")):")
        for day in daily {
            let bar = maxS > 0 ? String(repeating: "█", count: Int((day.seconds / maxS * 30).rounded())) : ""
            print("  " + pad(Format.dayLabel(day.day), dayW) + pad(Format.duration(day.seconds), 8, right: true)
                  + (bar.isEmpty ? "" : "  " + bar))
        }
    }
    print("\n\(threshold)")
}
