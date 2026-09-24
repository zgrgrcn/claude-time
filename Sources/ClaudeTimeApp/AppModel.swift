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

    static let idleOptions: [Double] = [5, 10, 15, 30, 60, 120, 240]
    let detailDays = 14
    /// Transcripts folder being scanned.
    let root: URL

    private let store: TranscriptStore
    private let settings: UserDefaults?
    private var timer: Timer?

    /// - Parameters:
    ///   - root: transcripts folder; defaults to `$CLAUDE_TIME_ROOT` or `~/.claude/projects`.
    ///   - useCache: reuse per-file scan results from the on-disk cache.
    ///   - settings: where the idle threshold is remembered; `nil` keeps it in memory only.
    ///   - autoRefresh: scan right away and then every minute.
    init(root: URL = TranscriptStore.resolveRoot(), useCache: Bool = true,
         settings: UserDefaults? = .standard, autoRefresh: Bool = true) {
        self.root = root
        self.store = TranscriptStore(root: root, useCache: useCache)
        self.settings = settings
        let saved = settings?.double(forKey: "idleMinutes") ?? 0
        idleMinutes = saved > 0 ? saved : 15
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
            .filter { stats($0).total >= 60 }
            .sorted { ($0.timestamps.last ?? 0) > ($1.timestamps.last ?? 0) }
    }

    var selectedProject: Project? { projects.first { $0.id == selectedID } }

    func stats(_ p: Project) -> Stats { Activity.stats(p.timestamps, idle: idle, windows: windows) }

    var allStats: Stats { Activity.stats(Activity.merged(projects), idle: idle, windows: windows) }

    func daily(_ p: Project) -> [DayStat] { Activity.daily(p.timestamps, idle: idle, days: detailDays) }

    var menuTitle: String { Format.duration(allStats.today, zero: "0m") }

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        let store = self.store
        Task.detached(priority: .utility) {
            let outcome = Result { try store.scan() }
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
            }
        }
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
