import Foundation

/// Writes a usage-only copy of a transcripts folder, e.g. into iCloud Drive so several Macs can
/// be read together with `--root`. Each `.jsonl` keeps its relative path, but holds only what the
/// scanner reads: the working directory, the timestamps and one marker per prompt. Prompt text,
/// replies, code and tool output are dropped.
public enum Exporter {
    /// Returns how many files were written and how many were already up to date. Files are never
    /// deleted from `destination`, so it keeps history Claude Code has since cleaned up.
    public static func export(from root: URL, to destination: URL) throws -> (written: Int, unchanged: Int) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let json = JSONEncoder()
        json.outputFormatting = .withoutEscapingSlashes
        let rootPath = root.standardizedFileURL.path
        var written = 0, unchanged = 0

        while let url = en.nextObject() as? URL {
            let rv = try url.resourceValues(forKeys: Set(keys))
            if rv.isDirectory == true {
                if url.lastPathComponent == "memory" { en.skipDescendants() }
                continue
            }
            guard url.pathExtension == "jsonl", let mtime = rv.contentModificationDate else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))
            let target = destination.appendingPathComponent(relative)
            // The copy carries the source's modification date, so an equal date means up to date.
            // Setting it rounds below a millisecond, hence the tolerance.
            if let existing = try? target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               abs(existing.timeIntervalSince(mtime)) < 0.001 {
                unchanged += 1
                continue
            }
            let f = try TranscriptStore.scanFile(url)
            var out = ""
            if let cwd = f.cwd, let quoted = try? json.encode(cwd) {
                out += #"{"cwd":"# + String(decoding: quoted, as: UTF8.self) + "}\n"
            }
            for t in f.timestamps {
                out += #"{"timestamp":""# + iso.string(from: Date(timeIntervalSince1970: t)) + "\"}\n"
            }
            out += String(repeating: #"{"message":{"role":"user","content":""}}"# + "\n", count: f.prompts)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(out.utf8).write(to: target, options: .atomic)
            try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: target.path)
            written += 1
        }
        return (written, unchanged)
    }
}
