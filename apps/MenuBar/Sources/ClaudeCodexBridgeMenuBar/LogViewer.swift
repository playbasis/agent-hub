import AppKit
import BridgeCore
import SwiftUI

@MainActor
final class LogViewerModel: ObservableObject {
    @Published private(set) var snapshot = BridgeLogSnapshot()
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastReloadedAt: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var copyStatus: String?
    @Published var query = ""
    @Published var level = BridgeLogPresentation.Level.all
    @Published var followLatest = true
    let fileURL: URL

    init(fileURL: URL = BridgePaths.logs.appendingPathComponent("bridge.jsonl")) { self.fileURL = fileURL }

    var filteredEntries: [BridgeLogEntry] {
        BridgeLogPresentation.entries(snapshot.entries, query: query, level: level)
    }
    var hasFilters: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || level != .all }

    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let file = fileURL
        let previousModifiedAt = lastReloadedAt == nil ? nil : snapshot.modifiedAt
        let previousSize = snapshot.fileSize
        let result = await Task.detached(priority: .utility) { () -> Result<BridgeLogSnapshot?, Error> in
            do {
                try Self.ensureLogFile(file)
                if let previousModifiedAt,
                   let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                   attributes[.modificationDate] as? Date == previousModifiedAt,
                   (attributes[.size] as? NSNumber)?.uint64Value == previousSize {
                    return .success(nil)
                }
                var snapshot = try BridgeLogReader.read(file: file)
                snapshot.entries = snapshot.entries.map(BridgeLogPresentation.sanitized)
                return .success(snapshot)
            } catch { return .failure(error) }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case let .success(value):
            if let value { snapshot = value }
            lastReloadedAt = Date()
            errorMessage = nil
        case let .failure(error):
            errorMessage = BridgeLogPresentation.text(error.localizedDescription)
        }
    }

    func clearFilters() { query = ""; level = .all }

    func copy(entries: [BridgeLogEntry]) {
        let text = BridgeLogPresentation.copyText(entries)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyStatus = "Copied \(entries.count) redacted \(entries.count == 1 ? "entry" : "entries")"
    }

    func revealInFinder() {
        do {
            try Self.ensureLogFile(fileURL)
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } catch { errorMessage = BridgeLogPresentation.text(error.localizedDescription) }
    }

    nonisolated private static func ensureLogFile(_ fileURL: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard !manager.fileExists(atPath: fileURL.path) else { return }
        if !manager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) { throw CocoaError(.fileWriteUnknown) }
    }
}

/// Compatibility entry point for menu-bar actions. Reports owns the sole
/// normal application window; logs never create another native frame.
@MainActor
final class LogViewerController {
    static let shared = LogViewerController()
    let model = LogViewerModel()
    var showHandler: (() -> Void)?
    var closeHandler: (() -> Void)?
    private(set) var isVisible = false
    var entryCount: Int { model.snapshot.entries.count }
    var displayedFileURL: URL { model.fileURL }
    private init() {}
    func show() { showHandler?() }
    func close() { closeHandler?() }
    func setVisible(_ value: Bool) { isVisible = value }
}

/// An embeddable Reports page. SwiftUI cancels the only polling loop as soon
/// as navigation removes this page or the Reports window is closed.
struct RuntimeLogsView: View {
    var isActive = true
    @ObservedObject private var model = LogViewerController.shared.model
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if let error = model.errorMessage { errorBanner(error) }
            content
            Divider()
            footer
        }
        .background(BridgeTheme.ink)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bridge.page.logs")
        .onReceive(NotificationCenter.default.publisher(for: AcceptanceProbe.command)) { note in
            AcceptanceProbe.handleSafe(note, scope: "logs", state: {
                ["query": model.query, "level": model.level.rawValue, "followLatest": String(model.followLatest)]
            }, exercise: {
                model.query = "acceptance"
                model.level = .warnings
                model.followLatest = false
                return true
            })
        }
        .onAppear { LogViewerController.shared.setVisible(isActive) }
        .onDisappear { LogViewerController.shared.setVisible(false) }
        .onChange(of: isActive) { LogViewerController.shared.setVisible($0) }
        .task(id: isActive) {
            guard isActive else { return }
            await model.reload()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
                await model.reload()
            }
        }
        .overlay {
            Button("Search logs") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { search; levelPicker; Spacer(minLength: 0); privacyNote; actions }
                VStack(alignment: .leading, spacing: 10) { HStack(spacing: 8) { search; levelPicker }; HStack(spacing: 10) { privacyNote; Spacer(); actions } }
            }
            if !model.snapshot.entries.isEmpty { levelSummary }
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
    }

    /// Loaded events by level, as filter shortcuts: problems are visible
    /// before scrolling, and a click narrows the list to them.
    private var levelSummary: some View {
        var counts: [BridgeLogPresentation.Level: Int] = [:]
        for entry in model.snapshot.entries { counts[LogLevelStyle.level(entry.level), default: 0] += 1 }
        return HStack(spacing: 6) {
            ForEach([BridgeLogPresentation.Level.errors, .warnings, .info, .debug, .raw], id: \.self) { level in
                let count = counts[level] ?? 0
                if count > 0 || level == .errors || level == .warnings {
                    let selected = model.level == level
                    let tint = level == .errors ? BridgeTheme.danger : level == .warnings ? BridgeTheme.warning : BridgeTheme.textSecondary
                    Button { model.level = selected ? .all : level } label: {
                        HStack(spacing: 5) {
                            Image(systemName: LogLevelStyle.symbol(for: level)).font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(count > 0 ? tint : BridgeTheme.textTertiary)
                            Text(count.formatted()).font(BridgeFont.captionMedium.monospacedDigit())
                                .foregroundStyle(count > 0 ? BridgeTheme.textPrimary : BridgeTheme.textTertiary)
                            Text(level.title.lowercased()).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(selected ? tint.opacity(0.18) : Color.white.opacity(0.05)))
                        .overlay(Capsule().strokeBorder(selected ? tint.opacity(0.5) : BridgeTheme.surfaceBorder, lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(selected ? "Show all levels" : "Show only \(level.title.lowercased())")
                    .accessibilityLabel("\(count) \(level.title)")
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var privacyNote: some View {
        HStack(spacing: 5) {
            if model.isLoading { ProgressView().controlSize(.mini).accessibilityLabel("Loading logs") }
            Image(systemName: "lock.shield").font(.system(size: 10))
            Text("Sensitive values redacted")
        }
        .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
        .help("Known credential patterns and your home folder name are removed from displayed and copied events. Check an export before sharing it; the original file in Finder is unchanged.")
    }

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(BridgeTheme.textTertiary)
            TextField("Search events (⌘F)", text: $model.query).textFieldStyle(.plain).font(BridgeFont.secondary)
                .focused($searchFocused)
        }
            .padding(.horizontal, 8).frame(height: 26).bridgeWell(cornerRadius: 7)
            .frame(minWidth: 170, maxWidth: 320)
            .accessibilityLabel("Search runtime logs")
            .accessibilityIdentifier("bridge.logs.search")
    }
    private var levelPicker: some View {
        Picker("Level", selection: $model.level) {
            ForEach(BridgeLogPresentation.Level.allCases) { level in
                Label(level.title, systemImage: LogLevelStyle.symbol(for: level)).tag(level)
            }
        }
        .labelsHidden().frame(width: 140)
        .accessibilityLabel("Filter runtime logs by level")
        .accessibilityIdentifier("bridge.logs.level")
    }
    private var actions: some View {
        HStack(spacing: 10) {
            Button { Task { await model.reload() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(model.isLoading).help("Refresh logs").accessibilityLabel("Refresh runtime logs")
            Button { model.copy(entries: model.filteredEntries) } label: { Image(systemName: "doc.on.doc") }
                .disabled(model.filteredEntries.isEmpty).help("Copy filtered logs with redaction").accessibilityLabel("Copy filtered redacted logs")
            Button { model.revealInFinder() } label: { Image(systemName: "folder") }
                .help("Reveal the source log file in Finder").accessibilityLabel("Reveal source log file in Finder")
        }
        .buttonStyle(BridgeIconButtonStyle(size: 26))
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(BridgeTheme.warning)
            VStack(alignment: .leading, spacing: 3) {
                Text("Runtime logs could not refresh").font(.callout.weight(.semibold))
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if !model.snapshot.entries.isEmpty { Text("Previously loaded entries remain visible.").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button("Retry") { Task { await model.reload() } }.disabled(model.isLoading)
        }
        .padding(14)
        .background(BridgeTheme.warning.opacity(0.08))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var content: some View {
        let entries = model.filteredEntries
        if model.snapshot.entries.isEmpty && model.isLoading {
            ProgressView("Loading runtime logs…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: model.hasFilters ? "magnifyingglass" : "doc.text").font(.system(size: 28)).foregroundStyle(.secondary)
                Text(model.hasFilters ? "No matching events" : "No runtime events yet").font(.headline)
                Text(model.hasFilters ? "Try another search or level." : "New events will appear here while Agent Hub runs.").font(.callout).foregroundStyle(.secondary)
                if model.hasFilters { Button("Clear filters") { model.clearFilters() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if let header = dayHeader(at: index, entries: entries) {
                            Text(header).font(BridgeFont.micro).tracking(0.5).foregroundStyle(BridgeTheme.textTertiary)
                                .padding(.top, index == 0 ? 2 : 10).listRowSeparator(.hidden)
                        }
                        LogEntryRow(entry: entry) { model.copy(entries: [entry]) }.id(entry.id)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onAppear { scrollToLatest(using: proxy) }
                .onChange(of: entries.last?.id) { _ in scrollToLatest(using: proxy) }
                .onChange(of: model.followLatest) { _ in scrollToLatest(using: proxy) }
            }
        }
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { counts; Spacer(); Toggle("Follow latest", isOn: $model.followLatest).toggleStyle(.checkbox); timestamp }
            VStack(alignment: .leading, spacing: 8) { counts; HStack { Toggle("Follow latest", isOn: $model.followLatest).toggleStyle(.checkbox); Spacer(); timestamp } }
        }
        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 12)
    }
    private var counts: some View {
        HStack(spacing: 8) {
            Text(model.hasFilters ? "\(model.filteredEntries.count) of \(model.snapshot.entries.count) events" : "\(model.snapshot.entries.count) events")
            if model.snapshot.wasTruncated {
                Text("Recent events only").foregroundStyle(BridgeTheme.warning)
                    .help("The viewer reads up to the newest 2 MB and shows at most 2,000 events. The original file keeps older events.")
            }
            if let status = model.copyStatus { Text(status).accessibilityLabel(status) }
        }
    }
    @ViewBuilder private var timestamp: some View {
        if let date = model.lastReloadedAt { Text("Updated \(date, style: .relative)").monospacedDigit() }
    }
    /// A day label before the first event of each local day.
    private func dayHeader(at index: Int, entries: [BridgeLogEntry]) -> String? {
        guard let date = BridgeLogPresentation.date(entries[index].timestamp) else { return index == 0 ? "UNDATED" : nil }
        let calendar = Calendar.current
        if index > 0, let previous = BridgeLogPresentation.date(entries[index - 1].timestamp), calendar.isDate(previous, inSameDayAs: date) { return nil }
        if calendar.isDateInToday(date) { return "TODAY" }
        if calendar.isDateInYesterday(date) { return "YESTERDAY" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased()
    }

    private func scrollToLatest(using proxy: ScrollViewProxy) {
        guard model.followLatest, let id = model.filteredEntries.last?.id else { return }
        proxy.scrollTo(id, anchor: .bottom)
    }
}

enum LogLevelStyle {
    static func symbol(for level: BridgeLogPresentation.Level) -> String {
        switch level {
        case .all: return "line.3.horizontal.decrease.circle"
        case .errors: return "xmark.octagon.fill"
        case .warnings: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        case .debug: return "ladybug.fill"
        case .raw: return "text.alignleft"
        }
    }

    static func level(_ raw: String) -> BridgeLogPresentation.Level {
        for level in [BridgeLogPresentation.Level.errors, .warnings, .info, .debug] where level.includes(raw) { return level }
        return .raw
    }

    static func color(_ raw: String) -> Color {
        switch level(raw) {
        case .errors: return BridgeTheme.danger
        case .warnings: return BridgeTheme.warning
        case .info: return BridgeTheme.brand
        default: return BridgeTheme.textTertiary
        }
    }
}

/// One event per line: level icon, local time, message and the first few
/// fields as chips. Clicking expands every field; nothing is shown escaped.
private struct LogEntryRow: View {
    let entry: BridgeLogEntry
    let copy: () -> Void
    @State private var expanded = false

    private var pairs: [(key: String, value: String)] { BridgeLogPresentation.fieldPairs(entry.fieldsSummary) }
    private var date: Date? { BridgeLogPresentation.date(entry.timestamp) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard !pairs.isEmpty else { return }
                withAnimation(BridgeTheme.reduceMotion ? nil : .easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
              HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: LogLevelStyle.symbol(for: LogLevelStyle.level(entry.level)))
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(LogLevelStyle.color(entry.level))
                    .frame(width: 14).help(entry.level.capitalized)
                Text(date.map { $0.formatted(.dateTime.hour().minute().second()) } ?? "—")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(BridgeTheme.textTertiary)
                    .frame(width: 66, alignment: .leading)
                    .help(entry.timestamp ?? "No timestamp")
                Text(BridgeLogPresentation.displayMessage(entry.message))
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(BridgeTheme.textPrimary)
                    .lineLimit(expanded ? nil : 1)
                if !expanded && !pairs.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(pairs.prefix(2).enumerated()), id: \.offset) { _, pair in chip(pair) }
                        if pairs.count > 2 { Text("+\(pairs.count - 2)").font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary) }
                    }
                    .layoutPriority(-1)
                }
                Spacer(minLength: 0)
                if !pairs.isEmpty {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(BridgeTheme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(pairs.isEmpty)
            .accessibilityLabel("\(entry.level.capitalized): \(BridgeLogPresentation.displayMessage(entry.message))")
            .accessibilityValue(pairs.isEmpty ? "No additional fields" : (expanded ? "Details expanded" : "Details collapsed"))
            .accessibilityHint(pairs.isEmpty ? "" : "Press to show or hide event details")
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(pair.key).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary).frame(width: 110, alignment: .trailing)
                            Text(pair.value).font(.system(size: 11, design: .monospaced)).foregroundStyle(BridgeTheme.textSecondary)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 89).padding(.vertical, 4)
            }
        }
        .padding(.vertical, 3)
        .contextMenu { Button("Copy event (secrets hidden)", action: copy) }
        .accessibilityElement(children: .contain)
    }

    private func chip(_ pair: (key: String, value: String)) -> some View {
        HStack(spacing: 3) {
            Text(pair.key).foregroundStyle(BridgeTheme.textTertiary)
            Text(shortValue(pair.value)).foregroundStyle(BridgeTheme.textSecondary)
        }
        .font(.system(size: 10)).lineLimit(1)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func shortValue(_ value: String) -> String {
        let text = value.hasPrefix("/") ? URL(fileURLWithPath: value).lastPathComponent : value
        return text.count > 22 ? String(text.prefix(12)) + "…" + String(text.suffix(6)) : text
    }
}
