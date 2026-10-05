import SwiftUI
import AppKit
import Charts
import ClaudeTimeCore

// MARK: - Layout constants

private enum L {
    static let width: CGFloat = 520
    static let nameW: CGFloat = 170
    static let colW: CGFloat = 74
    /// Width of a project row (name + four columns + padding); the expanded detail matches it.
    static let rowW: CGFloat = nameW + 4 * colW + 16
    static let listMaxH: CGFloat = 440
    static let corner: CGFloat = 9
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    /// The project list scrolls beyond this height. Snapshots raise it to show every row.
    var listMaxHeight: CGFloat = L.listMaxH
    @State private var listHeight: CGFloat = 0
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if showSettings {
                ProjectNames()
            } else {
                thresholdRow
                SummaryTiles(stats: model.allStats)
                projectSection
            }
            footer
        }
        .padding(14)
        .frame(width: L.width)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude Time").font(.headline)
                Text("Time spent in Claude Code").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showSettings.toggle()
                if !showSettings { model.refresh() }  // apply renamed projects
            } label: {
                Image(systemName: showSettings ? "checkmark" : "gearshape")
            }
            .controlSize(.small)
            .help(showSettings ? "Done" : "Settings")
            Button {
                model.refresh()
            } label: {
                if model.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .controlSize(.small)
            .disabled(model.isScanning)
            .help("Refresh")
        }
    }

    // MARK: Idle threshold

    private var thresholdRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Idle threshold").textCase(.uppercase)
                    .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
                Spacer()
                Text("Silences longer than this don't count as work")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Picker("Idle threshold", selection: $model.idleMinutes) {
                ForEach(AppModel.idleOptions, id: \.self) { Text(Format.threshold(minutes: $0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
    }

    // MARK: Projects

    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text("Projects").textCase(.uppercase)
                    .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
                    .frame(width: L.nameW, alignment: .leading)
                ForEach(["Today", "This week", "This month", "Total"], id: \.self) {
                    Text($0).font(.caption).foregroundStyle(.secondary)
                        .frame(width: L.colW, alignment: .trailing)
                }
            }
            .padding(.horizontal, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.sortedProjects) { p in
                        ProjectRow(project: p, stats: model.stats(p),
                                   expanded: model.selectedID == p.id) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                model.selectedID = model.selectedID == p.id ? nil : p.id
                            }
                        }
                        if model.selectedID == p.id {
                            ProjectDetail(project: p, stats: model.stats(p), daily: model.daily(p))
                        }
                    }
                    if model.projects.isEmpty && !model.isScanning {
                        Text("No transcripts found yet (\(ProjectRow.shortPath(model.root.path))).")
                            .font(.caption).foregroundStyle(.secondary).padding()
                            .frame(maxWidth: .infinity)
                    }
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: HeightKey.self, value: g.size.height)
                })
            }
            .onPreferenceChange(HeightKey.self) { listHeight = $0 }
            .frame(height: min(max(listHeight, 28), listMaxHeight))
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let e = model.errorText {
                Label(e, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            Divider()
            HStack {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox).controlSize(.small)
                Spacer()
                Text(model.lastScan.map { "Updated \(Format.time($0))" } ?? "Scanning…")
                    .font(.caption).foregroundStyle(.tertiary)
                    .help(model.scanInfo)
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Settings

/// Renames projects. A name applies to every folder with that name, and folders given the same
/// name count as one project.
private struct ProjectNames: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Project names").textCase(.uppercase)
                    .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
                Spacer()
                Text("Leave empty to use the folder name")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.folderNames, id: \.self) { folder in
                        HStack {
                            Text(folder).lineLimit(1).truncationMode(.middle)
                                .frame(width: L.nameW, alignment: .leading)
                            TextField(folder, text: binding(folder))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(maxHeight: L.listMaxH)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func binding(_ folder: String) -> Binding<String> {
        Binding(get: { model.names[folder] ?? "" },
                set: { model.names[folder] = $0.isEmpty ? nil : $0 })
    }
}

// MARK: - Summary tiles

private struct SummaryTiles: View {
    let stats: Stats

    var body: some View {
        HStack(spacing: 8) {
            tile("Today", stats.today, accent: true)
            tile("This week", stats.week)
            tile("This month", stats.month)
            tile("Total", stats.total)
        }
    }

    private func tile(_ label: String, _ seconds: Double, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.caption2).fontWeight(.semibold)
                .foregroundStyle(accent ? Color.accentColor : Color.secondary)
            Text(Format.duration(seconds, zero: "0m"))
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: L.corner)
                .fill(accent ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: L.corner)
                .strokeBorder(accent ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06))
        )
    }
}

// MARK: - Project row

private struct ProjectRow: View {
    let project: Project
    let stats: Stats
    let expanded: Bool
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name).fontWeight(.medium).lineLimit(1)
                Text(Self.shortPath(project.path))
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(width: L.nameW - 16, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 16)
            ForEach([stats.today, stats.week, stats.month, stats.total], id: \.self) { s in
                Text(Format.duration(s))
                    .monospacedDigit()
                    .foregroundStyle(s > 0 ? Color.primary : Color.secondary.opacity(0.6))
                    .frame(width: L.colW, alignment: .trailing)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(expanded ? Color.accentColor.opacity(0.12)
                      : hovered ? Color.primary.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: onTap)
        .help(project.path)
    }

    static func shortPath(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p == home || p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
    }
}

// MARK: - Expanded detail

private struct ProjectDetail: View {
    let project: Project
    let stats: Stats
    let daily: [DayStat]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                meta("calendar", "First", Format.dateTime(stats.firstSeen))
                meta("clock.arrow.circlepath", "Last", Format.dateTime(stats.lastSeen))
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .controlSize(.mini)
                .help(project.path)
            }
            HStack(spacing: 14) {
                meta("rectangle.stack", "Sessions", "\(project.sessionCount)")
                meta("text.bubble", "Prompts", "\(project.prompts)")
                meta("rectangle.split.3x1", "Work blocks", "\(stats.blocks)")
            }

            Text("Last \(Format.count(daily.count, "day"))").textCase(.uppercase)
                .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
                .padding(.top, 2)
            Chart(daily) { d in
                BarMark(x: .value("Day", d.day, unit: .day),
                        y: .value("Minutes", d.seconds / 60))
                    .foregroundStyle(TimeWindows.calendar.isDateInToday(d.day)
                                     ? Color.accentColor : Color.accentColor.opacity(0.55))
                    .cornerRadius(2)
                    .annotation(position: .top, spacing: 2) {
                        if d.seconds >= 60 {
                            Text(Format.duration(d.seconds))
                                .font(.system(size: 8)).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 1)) { v in
                    AxisValueLabel(centered: true) {
                        if let d = v.as(Date.self) {
                            Text(d, format: .dateTime.day())
                                .font(.system(size: 9))
                                .foregroundStyle(TimeWindows.calendar.isDateInToday(d) ? Color.accentColor : Color.secondary)
                        }
                    }
                }
            }
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...max(1, (daily.map(\.seconds).max() ?? 0) / 60 * 1.3))
            .chartPlotStyle { $0.background(Color.primary.opacity(0.03)) }
            .frame(height: 96)
        }
        .padding(10)
        .frame(width: L.rowW - 8)
        .background(RoundedRectangle(cornerRadius: L.corner).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: L.corner).strokeBorder(Color.primary.opacity(0.06)))
        .padding(.horizontal, 4).padding(.bottom, 4)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func meta(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2).foregroundStyle(.secondary)
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.caption).monospacedDigit()
        }
    }
}
