import Foundation

/// One parsed transcript file (`*.jsonl`) under `~/.claude/projects/<project>/`.
public struct ScannedFile: Codable, Sendable, Equatable {
    public var path: String
    public var size: Int
    public var mtime: Double
    /// Working directory recorded in the transcript (first/most common `cwd`).
    public var cwd: String?
    /// Sorted, de-duplicated epoch seconds of every timestamped record.
    public var timestamps: [Double]
    /// User messages with plain-text `content` (tool results excluded). Mostly prompts you typed, but
    /// also slash-command records, compaction summaries and task prompts sent to subagents.
    public var prompts: Int
    /// True for session files directly under the project dir (sub-agent transcripts live in subdirs).
    public var isTopLevel: Bool

    public init(path: String, size: Int, mtime: Double, cwd: String?, timestamps: [Double], prompts: Int, isTopLevel: Bool) {
        self.path = path; self.size = size; self.mtime = mtime; self.cwd = cwd
        self.timestamps = timestamps; self.prompts = prompts; self.isTopLevel = isTopLevel
    }
}

/// All transcripts of one Claude Code project (one directory under `~/.claude/projects`).
public struct Project: Identifiable, Sendable, Equatable {
    /// Directory name, e.g. `-Users-you-code-my-app`.
    public var id: String
    /// Real working directory, e.g. `/Users/you/code/my-app`.
    public var path: String
    /// Last path component, e.g. `my-app`.
    public var name: String
    public var sessionCount: Int
    public var fileCount: Int
    public var prompts: Int
    /// Merged, sorted, de-duplicated epoch seconds across all files of the project.
    public var timestamps: [Double]

    public init(id: String, path: String, name: String, sessionCount: Int, fileCount: Int, prompts: Int, timestamps: [Double]) {
        self.id = id; self.path = path; self.name = name; self.sessionCount = sessionCount
        self.fileCount = fileCount; self.prompts = prompts; self.timestamps = timestamps
    }

    public var firstSeen: Date? { timestamps.first.map { Date(timeIntervalSince1970: $0) } }
    public var lastSeen: Date? { timestamps.last.map { Date(timeIntervalSince1970: $0) } }
}

public struct ScanResult: Sendable {
    public var projects: [Project]
    public var scannedFiles: Int
    public var reusedFiles: Int
    public var duration: Double
}
