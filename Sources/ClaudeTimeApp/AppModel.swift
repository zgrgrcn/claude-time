import Foundation
import ServiceManagement
import ClaudeTimeCore

@MainActor
final class AppModel: ObservableObject {
    @Published var projects: [Project] = []
    @Published var selectedID: String?
    @Published var lastScan: Date?
    @Published var scanInfo = ""
    @Published var errorText: String?
    @Published var isScanning = false
    @Published var launchAtLogin: Bool
    @Published var idleMinutes: Double {
        didSet { settings?.set(idleMinutes, forKey: "idleMinutes") }
    }

    /// Display name per folder name, edited in the settings view.
    @Published var names: [String: String] {
        didSet { settings?.set(names, forKey: TranscriptStore.namesKey) }
    }

    static let idleOptions: [Double] = [5, 10, 15, 30, 60, 120, 240]
    let detailDays = 14
    /// This Mac's transcripts folder.
    let localRoot: URL
    /// Folder shared between Macs (e.g. in iCloud Drive). When set, this Mac's usage is exported
    /// into it on every refresh, and the projects are read from it.
    @Published var syncFolder: URL? {
        didSet {
            settings?.set(syncFolder?.path, forKey: Exporter.syncFolderKey)
            store = TranscriptStore(root: root, useCache: useCache)
            refresh()
        }
    }
    /// Transcripts folder being scanned.
    var root: URL { syncFolder ?? localRoot }

    private var store: TranscriptStore
    private let useCache: Bool
    private let settings: UserDefaults?
    private var timer: Timer?
    /// A refresh was asked for during a scan; run it when the scan ends (settings may have changed).
    private var pendingRefresh = false

    /// - Parameters:
    ///   - root: transcripts folder; defaults to `$CLAUDE_TIME_ROOT` or `~/.claude/projects`.
    ///   - useCache: reuse per-file scan results from the on-disk cache.
    ///   - settings: where the idle threshold is remembered; `nil` keeps it in memory only.
    ///   - autoRefresh: scan right away and then every minute.
    init(root: URL = TranscriptStore.resolveRoot(), useCache: Bool = true,
         settings: UserDefaults? = .standard, autoRefresh: Bool = true) {
        self.localRoot = root
        self.useCache = useCache
        self.settings = settings
        let sync = settings?.string(forKey: Exporter.syncFolderKey).map { URL(fileURLWithPath: $0) }
        _syncFolder = Published(initialValue: sync)
        self.store = TranscriptStore(root: sync ?? root, useCache: useCache)
        let saved = settings?.double(forKey: "idleMinutes") ?? 0
        idleMinutes = saved > 0 ? saved : 15
        names = settings?.dictionary(forKey: TranscriptStore.namesKey) as? [String: String] ?? [:]
        launchAtLogin = SMAppService.mainApp.status == .enabled
        guard autoRefresh else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var idle: Double { idleMinutes * 60 }
    var windows: TimeWindows { TimeWindows() }

    /// Projects with any measurable activity, ordered by most recent activity.
    var sortedProjects: [Project] {
        projects
            .filter { !$0.isProjectless && stats($0).total >= 60 }
            .sorted { ($0.timestamps.last ?? 0) > ($1.timestamps.last ?? 0) }
    }

    var selectedProject: Project? { projects.first { $0.id == selectedID } }

    func stats(_ p: Project) -> Stats { Activity.stats(p.timestamps, idle: idle, windows: windows) }

    var allStats: Stats {
        Activity.stats(Activity.merged(projects.filter { !$0.isProjectless }), idle: idle, windows: windows)
    }

    func daily(_ p: Project) -> [DayStat] { Activity.daily(p.timestamps, idle: idle, days: detailDays) }

    var menuTitle: String { Format.duration(allStats.today, zero: "0m") }

    func refresh() {
        guard !isScanning else { pendingRefresh = true; return }
        isScanning = true
        let store = self.store, names = self.names, localRoot = self.localRoot, sync = self.syncFolder
        Task.detached(priority: .utility) {
            let outcome = Result {
                if let sync { _ = try Exporter.export(from: localRoot, to: sync) }
                return try store.scan(names: names)
            }
            await MainActor.run {
                switch outcome {
                case .success(let r):
                    self.projects = r.projects
                    self.lastScan = Date()
                    self.errorText = nil
                    self.scanInfo = "\(Format.count(r.projects.count, "project")) · \(r.scannedFiles) scanned / "
                        + "\(r.reusedFiles) cached · " + String(format: "%.2fs", r.duration)
                case .failure(let e):
                    self.errorText = e.localizedDescription
                }
                self.isScanning = false
                if self.pendingRefresh { self.pendingRefresh = false; self.refresh() }
            }
        }
    }

    /// Folder names for the settings view: the listed projects, then the projectless sessions
    /// (naming one lists it).
    var folderNames: [String] {
        let rest = projects
            .filter { $0.isProjectless && stats($0).total >= 60 }
            .sorted { ($0.timestamps.last ?? 0) > ($1.timestamps.last ?? 0) }
        return (sortedProjects + rest).flatMap(\.folderNames)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            errorText = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            errorText = "Couldn't change Launch at login: \(error.localizedDescription) "
                + "(the app has to run from its .app bundle)"
        }
    }
}
