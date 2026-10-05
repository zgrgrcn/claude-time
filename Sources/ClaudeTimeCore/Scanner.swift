import Foundation

/// Scans `~/.claude/projects/**/*.jsonl`, extracting timestamps with a byte-level search
/// (no JSON parsing — 100+ MB of transcripts take well under a second). Results are cached
/// per file (size + mtime) so repeated scans only touch files that changed.
public final class TranscriptStore: @unchecked Sendable {
    public let root: URL
    public let cacheURL: URL?
    private var cache: [String: ScannedFile] = [:]
    private let lock = NSLock()

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    /// Environment variable that points Claude Time at a different transcripts folder.
    public static let rootEnvironmentKey = "CLAUDE_TIME_ROOT"

    /// The transcripts folder to scan: an explicit `--root` value wins, then `$CLAUDE_TIME_ROOT`,
    /// then `~/.claude/projects`. A leading `~` is expanded; relative paths resolve against the
    /// current directory. Empty values are ignored.
    public static func resolveRoot(_ explicit: String? = nil,
                                   environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let candidates = [explicit, environment[rootEnvironmentKey]]
        guard let raw = candidates.compactMap({ $0 }).first(where: { !$0.isEmpty }) else { return defaultRoot }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).absoluteURL.standardizedFileURL
    }

    /// Where scan results for `root` are cached. The default folder uses `cache.json`; any other
    /// folder gets its own file, so scanning demo or test data never evicts the real cache.
    public static func defaultCacheURL(for root: URL) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("claude-time")
        let path = root.standardizedFileURL.path
        if path == defaultRoot.standardizedFileURL.path { return dir.appendingPathComponent("cache.json") }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325  // FNV-1a: stable across runs, unlike Hasher
        for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return dir.appendingPathComponent(String(format: "cache-%016llx.json", hash))
    }

    /// - Parameters:
    ///   - root: transcripts folder; `nil` means `~/.claude/projects`.
    ///   - cacheURL: cache file; `nil` means `defaultCacheURL(for: root)`.
    ///   - useCache: `false` never reads or writes a cache file.
    public init(root: URL? = nil, cacheURL: URL? = nil, useCache: Bool = true) {
        self.root = root ?? Self.defaultRoot
        self.cacheURL = useCache ? (cacheURL ?? Self.defaultCacheURL(for: self.root)) : nil
        loadCache()
    }

    /// Preferences domain of the app; the CLI reads the project names from it too.
    public static let defaultsSuite = "com.zgrgrcn.claude-time"
    /// Key of the `[folder name: display name]` dictionary in `defaultsSuite`.
    public static let namesKey = "projectNames"

    /// - Parameter names: display name per folder name (e.g. `["scratch-2026": "notes"]`).
    ///   Folders renamed to the same name count as one project.
    public func scan(names: [String: String] = [:]) throws -> ScanResult {
        lock.lock(); defer { lock.unlock() }
        let t0 = Date()
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        let dirs = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])

        var newCache: [String: ScannedFile] = [:]
        var scanned = 0, reused = 0
        // Folders are keyed by full path, so the same project checked out at different paths (or
        // synced from other machines) shows up as several folders. Group them by name.
        var byName: [String: [(folder: String, cwd: String, files: [ScannedFile])]] = [:]

        for dir in dirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let id = dir.lastPathComponent
            var files: [ScannedFile] = []

            guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { continue }
            while let url = en.nextObject() as? URL {
                let rv = try url.resourceValues(forKeys: keys)
                if rv.isDirectory == true {
                    if url.lastPathComponent == "memory" { en.skipDescendants() }
                    continue
                }
                guard url.pathExtension == "jsonl" else { continue }
                let size = rv.fileSize ?? 0
                let mtime = rv.contentModificationDate?.timeIntervalSince1970 ?? 0
                let path = url.path
                if let c = cache[path], c.size == size, c.mtime == mtime {
                    files.append(c); newCache[path] = c; reused += 1
                    continue
                }
                var f = try Self.scanFile(url)
                f.size = size; f.mtime = mtime
                f.isTopLevel = url.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path
                files.append(f); newCache[path] = f; scanned += 1
            }
            guard !files.isEmpty else { continue }

            var cwdCounts: [String: Int] = [:]
            for f in files { if let c = f.cwd { cwdCounts[c, default: 0] += 1 } }
            let cwd = cwdCounts.max { a, b in a.value < b.value }?.key ?? Self.guessPath(fromDirName: id)
            let folder = Self.projectName(cwd)
            let name = names[folder].map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 } ?? folder
            byName[name, default: []].append((folder, cwd, files))
        }

        var projects: [Project] = []
        for (name, folders) in byName {
            let files = folders.flatMap(\.files)
            var all = files.flatMap(\.timestamps)
            all.sort()
            all = Self.dedupe(all)
            // Show the path of the most recently active folder.
            let latest = folders.max { a, b in
                (a.files.compactMap(\.timestamps.last).max() ?? 0) < (b.files.compactMap(\.timestamps.last).max() ?? 0)
            }!
            projects.append(Project(
                id: name, path: latest.cwd, name: name,
                sessionCount: files.filter(\.isTopLevel).count,
                fileCount: files.count,
                prompts: files.reduce(0) { $0 + $1.prompts },
                timestamps: all,
                folderNames: Array(Set(folders.map(\.folder))).sorted()))
        }

        cache = newCache
        saveCache()
        return ScanResult(projects: projects, scannedFiles: scanned, reusedFiles: reused,
                          duration: Date().timeIntervalSince(t0))
    }

    // MARK: - File parsing

    static let timestampPattern = Array("\"timestamp\":\"".utf8)
    static let cwdPattern = Array("\"cwd\":\"".utf8)
    static let promptPattern = Array("\"role\":\"user\",\"content\":\"".utf8)

    public static func scanFile(_ url: URL) throws -> ScannedFile {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        var timestamps: [Double] = []
        var cwd: String? = nil
        var prompts = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            let n = raw.count
            forEachOccurrence(of: timestampPattern, in: base, count: n) { i in
                if let t = parseISO8601(base, n, at: i) { timestamps.append(t) }
            }
            forEachOccurrence(of: cwdPattern, in: base, count: n, stopAfterFirst: true) { i in
                cwd = readJSONString(base, n, at: i)
            }
            forEachOccurrence(of: promptPattern, in: base, count: n) { _ in prompts += 1 }
        }
        timestamps.sort()
        return ScannedFile(path: url.path, size: data.count, mtime: 0, cwd: cwd,
                           timestamps: dedupe(timestamps), prompts: prompts, isTopLevel: true)
    }

    /// Calls `body` with the byte offset immediately after each match of `pattern`.
    static func forEachOccurrence(of pattern: [UInt8], in base: UnsafeRawPointer, count n: Int,
                                  stopAfterFirst: Bool = false, _ body: (Int) -> Void) {
        let plen = pattern.count
        pattern.withUnsafeBytes { pbuf in
            var offset = 0
            while offset + plen <= n,
                  let hit = memmem(base + offset, n - offset, pbuf.baseAddress, plen) {
                let idx = base.distance(to: UnsafeRawPointer(hit))
                body(idx + plen)
                if stopAfterFirst { return }
                offset = idx + plen
            }
        }
    }

    /// Parses `YYYY-MM-DDTHH:MM:SS(.fff)?Z` starting at byte `i` into epoch seconds (UTC).
    static func parseISO8601(_ base: UnsafeRawPointer, _ n: Int, at i: Int) -> Double? {
        guard i + 19 <= n else { return nil }
        @inline(__always) func digit(_ k: Int) -> Int? {
            let c = base.load(fromByteOffset: k, as: UInt8.self)
            return (c >= 48 && c <= 57) ? Int(c - 48) : nil
        }
        func num(_ start: Int, _ len: Int) -> Int? {
            var v = 0
            for k in start..<(start + len) { guard let d = digit(k) else { return nil }; v = v * 10 + d }
            return v
        }
        guard let y = num(i, 4), let mo = num(i + 5, 2), let d = num(i + 8, 2),
              let h = num(i + 11, 2), let mi = num(i + 14, 2), let s = num(i + 17, 2),
              (1...12).contains(mo), (1...31).contains(d) else { return nil }
        var frac = 0.0
        var k = i + 19
        if k < n, base.load(fromByteOffset: k, as: UInt8.self) == 46 { // '.'
            k += 1
            var scale = 0.1
            while k < n, let x = digit(k) { frac += Double(x) * scale; scale /= 10; k += 1 }
        }
        let days = daysFromCivil(y, mo, d)
        return Double(days * 86_400 + h * 3_600 + mi * 60 + s) + frac
    }

    /// Howard Hinnant's days-from-civil (proleptic Gregorian) — days since 1970-01-01.
    static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// Reads a JSON string body starting at byte `i` (just after the opening quote).
    static func readJSONString(_ base: UnsafeRawPointer, _ n: Int, at i: Int) -> String? {
        var bytes: [UInt8] = []
        var k = i
        while k < n {
            let c = base.load(fromByteOffset: k, as: UInt8.self)
            if c == 34 { break }                  // '"'
            if c == 92, k + 1 < n {               // '\'
                let e = base.load(fromByteOffset: k + 1, as: UInt8.self)
                switch e {
                case 110: bytes.append(10)        // \n
                case 116: bytes.append(9)         // \t
                case 117:                          // \uXXXX — keep raw; rare in paths
                    bytes.append(contentsOf: [92, 117]); k += 2; continue
                default: bytes.append(e)          // \" \\ \/
                }
                k += 2; continue
            }
            bytes.append(c); k += 1
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    static func dedupe(_ sorted: [Double]) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(sorted.count)
        var last = -Double.infinity
        for t in sorted where t != last { out.append(t); last = t }
        return out
    }

    /// Display name of a working directory: its last component, or `~` for a home folder
    /// (any `/Users/<name>`, so home folders synced from other machines merge too).
    static func projectName(_ cwd: String) -> String {
        let parts = cwd.split(separator: "/")
        if parts.count == 2, parts[0] == "Users" { return "~" }
        return parts.last.map(String.init) ?? cwd
    }

    /// Fallback when no `cwd` record exists: `-Users-x-github-foo` → `/Users/x/github/foo`.
    /// Ambiguous for paths containing `-`, which is why the transcript `cwd` is preferred.
    static func guessPath(fromDirName id: String) -> String {
        if id == "-" { return "/" }
        return id.replacingOccurrences(of: "-", with: "/")
    }

    // MARK: - Cache

    private func loadCache() {
        guard let url = cacheURL, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: ScannedFile].self, from: data) else { return }
        cache = decoded
    }

    private func saveCache() {
        guard let url = cacheURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(cache)
            try data.write(to: url, options: .atomic)
        } catch {
            // Cache is an optimisation only; ignore write failures.
        }
    }
}
