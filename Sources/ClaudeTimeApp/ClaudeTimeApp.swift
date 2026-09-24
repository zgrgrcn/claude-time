import SwiftUI
import AppKit
import ClaudeTimeCore

@main
enum Main {
    /// Snapshot mode runs a bare NSApplication instead of the SwiftUI app, so no menu bar item
    /// is ever created (AppKit would remember a hidden one in the app's preferences).
    @MainActor static func main() {
        guard Snapshot.isRequested else { return ClaudeTimeApp.main() }
        let app = NSApplication.shared
        let delegate = SnapshotDelegate()  // NSApplication holds its delegate weakly
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, menu bar only (also covers `swift run`, where there is no Info.plist).
        NSApp.setActivationPolicy(.accessory)
    }
}

final class SnapshotDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Snapshot.run()
    }
}

struct ClaudeTimeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(model)
        } label: {
            Label {
                Text(model.menuTitle)
            } icon: {
                Image(systemName: "clock")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Developer aid: `ClaudeTime --snapshot out.png [--dark] [--select <name>] [--idle <minutes>] [--root <dir>]`
/// renders the popover content off-screen to a PNG (@2x) and exits. Used to eyeball the UI without
/// clicking the menu bar and to make the README screenshots. It never reads or writes the scan cache
/// or the saved settings, so it is safe to point at demo data with `--root` (or `CLAUDE_TIME_ROOT`).
enum Snapshot {
    /// Output path from `--snapshot <path>`; `nil` when not in snapshot mode.
    static let outputPath: String? = value(after: "--snapshot")
    static var isRequested: Bool { outputPath != nil }

    private static var keepAlive: (NSWindow, NSView)?

    /// `nil` if `flag` is absent, `""` if it is the last argument.
    private static func value(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag) else { return nil }
        return i + 1 < args.count ? args[i + 1] : ""
    }

    /// Like `value(after:)`, but a flag without a value is an error.
    private static func option(_ flag: String, _ expects: String) -> String? {
        guard let v = value(after: flag) else { return nil }
        if v.isEmpty || v.hasPrefix("--") { fail("\(flag) expects \(expects)") }
        return v
    }

    private static func fail(_ message: String) -> Never {
        fputs("snapshot: \(message)\n", stderr)
        exit(1)
    }

    @MainActor static func run() {
        guard let path = option("--snapshot", "an output path, e.g. --snapshot out.png") else { return }
        let out = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let dark = CommandLine.arguments.contains("--dark")
        let select = option("--select", "a project name")

        let root = TranscriptStore.resolveRoot(option("--root", "a directory"))
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            fail("no transcripts folder at \(root.path)")
        }
        let model = AppModel(root: root, useCache: false, settings: nil, autoRefresh: false)
        if let raw = option("--idle", "a number of minutes") {
            guard let m = Double(raw), m > 0 else { fail("--idle expects a number of minutes greater than 0") }
            model.idleMinutes = m
        }
        model.refresh()

        let corner: CGFloat = 12
        let host = NSHostingView(rootView: AnyView(
            ContentView(listMaxHeight: 2000).environmentObject(model)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(dark ? 0.18 : 0.12)))
                .shadow(color: .black.opacity(dark ? 0.45 : 0.18), radius: 14, y: 6)
                .padding(24)))
        let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 568, height: 400),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.contentView = host
        win.orderBack(nil)
        keepAlive = (win, host)

        Task { @MainActor in
            let deadline = Date().addingTimeInterval(120)
            while model.isScanning, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            if model.isScanning { fail("scan timed out") }
            if let e = model.errorText { fail("scan failed: \(e)") }
            if let s = select {
                guard let p = model.sortedProjects.first(where: { $0.name.localizedCaseInsensitiveContains(s) }) else {
                    fail("no project matches '\(s)'")
                }
                model.selectedID = p.id
            }
            try? await Task.sleep(for: .milliseconds(500))  // let SwiftUI lay out the list and chart
            render(host, in: win, to: out)
        }
    }

    @MainActor private static func render(_ host: NSView, in win: NSWindow, to out: URL) {
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        win.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // Always @2x, whatever the attached display, so screenshots come out the same everywhere.
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fail("can't allocate bitmap") }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { fail("PNG encoding failed") }
        do {
            try png.write(to: out)
        } catch {
            fail("can't write \(out.path): \(error.localizedDescription)")
        }
        print("snapshot: \(out.path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
        exit(0)
    }
}
