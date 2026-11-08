import BridgeCore
import Foundation
import SwiftUI

struct DailyBriefOperations: Sendable {
    var load: @Sendable () async throws -> [ActivityJournalEntry]
    var publish: @Sendable () async throws -> ActivityJournalEntry

    init(client: BridgeAPIClient) {
        load = { try await client.activityJournal() }
        publish = { try await client.publishActivityJournal() }
    }

    init(load: @escaping @Sendable () async throws -> [ActivityJournalEntry],
         publish: @escaping @Sendable () async throws -> ActivityJournalEntry) {
        self.load = load; self.publish = publish
    }
}

/// Publication is independent of project scans and pins. An acknowledged
/// report is shown immediately; a stale list read cannot hide a saved report.
@MainActor
final class DailyBriefModel: ObservableObject {
    @Published private(set) var entries: [ActivityJournalEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isPublishing = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var notice: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var openedID: String?
    @Published private(set) var openRevision: UInt64 = 0
    private var operations: DailyBriefOperations?
    private var connectionID: UUID?
    private var loadID: UUID?
    private var publishID: UUID?
    private var mutationRevision: UInt64 = 0

    init(operations: DailyBriefOperations? = nil) { self.operations = operations }
    var isConnected: Bool { operations != nil }

    func connect(client: BridgeAPIClient, id: UUID) {
        connect(operations: DailyBriefOperations(client: client), id: id)
    }

    func connect(operations: DailyBriefOperations, id: UUID) {
        guard connectionID != id else { return }
        connectionID = id
        self.operations = operations
        loadID = nil; isLoading = false
        publishID = nil; isPublishing = false
        notice = nil; errorMessage = nil
        mutationRevision &+= 1
    }

    func load() async {
        guard !isPublishing else { return }
        guard let operations else {
            errorMessage = "Agent Hub is still connecting. Try refreshing in a moment."
            return
        }
        let id = UUID(), revision = mutationRevision
        loadID = id; isLoading = true; errorMessage = nil
        defer { if loadID == id { loadID = nil; isLoading = false } }
        do {
            let loaded = try await operations.load()
            guard !Task.isCancelled, loadID == id, mutationRevision == revision else { return }
            entries = Self.unique(loaded)
            hasLoaded = true
            if openedID == nil, let first = entries.first { open(first.id) }
        } catch {
            guard !Task.isCancelled, loadID == id, mutationRevision == revision else { return }
            errorMessage = "Couldn't load saved briefs. " + BridgeLogPresentation.text(error.localizedDescription)
        }
    }

    func publish() async {
        guard !isPublishing else { return }
        guard let operations else {
            errorMessage = "Agent Hub is still connecting. Your brief hasn't been created yet."
            return
        }
        let id = UUID(), connection = connectionID
        publishID = id; isPublishing = true; errorMessage = nil; notice = nil
        mutationRevision &+= 1
        let revision = mutationRevision
        loadID = nil; isLoading = false
        defer { if publishID == id { publishID = nil; isPublishing = false } }
        do {
            let entry = try await operations.publish()
            guard publishID == id, connectionID == connection, mutationRevision == revision else { return }
            // A returned receipt is an authoritative acknowledgement even if
            // the caller was cancelled after the server committed the save.
            let alreadySaved = entries.contains { $0.id == entry.id }
            entries = Self.unique(entries.filter { $0.id != entry.id } + [entry])
            hasLoaded = true; open(entry.id)
            notice = alreadySaved ? "Today's brief is already up to date."
                : "Brief saved · revision \(entry.revision). Earlier versions are kept."
        } catch {
            guard publishID == id, connectionID == connection, mutationRevision == revision else { return }
            errorMessage = Task.isCancelled || error is CancellationError
                ? "Creation was interrupted. Refresh to check whether your brief was saved."
                : "Couldn't create the brief. " + BridgeLogPresentation.text(error.localizedDescription)
        }
    }

    private func open(_ id: String) { openedID = id; openRevision &+= 1 }

    func reportExport(_ result: Result<Void, Error>) {
        switch result {
        case .success: notice = "Brief exported."; errorMessage = nil
        case let .failure(error): errorMessage = "Couldn't export the brief. " + BridgeLogPresentation.text(error.localizedDescription)
        }
    }

    private static func unique(_ values: [ActivityJournalEntry]) -> [ActivityJournalEntry] {
        Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { first, last in
            last.generatedAt >= first.generatedAt ? last : first
        }).values.sorted { $0.generatedAt == $1.generatedAt ? $0.id > $1.id : $0.generatedAt > $1.generatedAt }
    }
}

/// Decode inline report formatting into a String, never a rich-text view.
/// Dropping every attribute means links, images and HTML cannot turn into
/// interactions; escaped provider punctuation still reads as literal text.
enum DailyBriefText {
    static func plain(_ source: String) -> String {
        let isBullet = source.hasPrefix("- ")
        let content = isBullet ? String(source.dropFirst(2)) : source
        // Protect intentional literal punctuation before Markdown sees it.
        // In particular, its URL parser can otherwise retain a trailing
        // escape in an entirely escaped `[label](url)` provider string.
        var nonce = "HUBLITERAL" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        while content.contains(nonce) { nonce += "X" }
        var protected = "", literals: [(token: String, value: String)] = []
        var index = content.startIndex
        while index < content.endIndex {
            let next = content.index(after: index)
            if content[index] == "\\", next < content.endIndex,
               content[next].unicodeScalars.count == 1,
               let scalar = content[next].unicodeScalars.first,
               (33...47).contains(scalar.value) || (58...64).contains(scalar.value)
                    || (91...96).contains(scalar.value) || (123...126).contains(scalar.value) {
                let token = nonce + "L" + String(literals.count) + "Z"
                literals.append((token, String(content[next])))
                protected += token
                index = content.index(after: next)
            } else {
                protected.append(content[index])
                index = next
            }
        }
        // Foundation Markdown does not support image attachments consistently
        // across OS releases. Preserve their caption without retaining a URL
        // or attachment placeholder. Escaped provider text is not rewritten.
        let withoutImages = protected.replacingOccurrences(
            of: #"(?<!\\)!\[([^\]]*)\]\((?:[^()]|\([^()]*\))*\)"#,
            with: "$1", options: .regularExpression
        )
        var decoded = (try? AttributedString(markdown: withoutImages, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            .map { String($0.characters) } ?? withoutImages
        for literal in literals { decoded = decoded.replacingOccurrences(of: literal.token, with: literal.value) }
        return (isBullet ? "• " : "") + decoded
    }
}

struct DailyBriefSection: Identifiable, Equatable {
    var title: String
    var lines: [String]
    var id: String { title }
    var isTechnical: Bool {
        ["Source coverage", "Outputs and evidence", "Report continuity", "Unresolved carry-forward"].contains(title)
    }

    static func parse(_ markdown: String) -> [DailyBriefSection] {
        var sections: [DailyBriefSection] = []
        var current: Int?
        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                let title = String(line.dropFirst(3))
                // Duplicate headings are merged so UI identity stays stable.
                if !sections.contains(where: { $0.title == title }) { sections.append(.init(title: title, lines: [])) }
                current = sections.firstIndex { $0.title == title }
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty, !line.hasPrefix("# "), let current {
                sections[current].lines.append(line)
            }
        }
        return sections
    }
}

/// The headline figures of a saved brief, read back from its own text so every
/// revision, old or new, gets the same at-a-glance card. The saved record is
/// never rewritten; anything the text doesn't state stays nil and isn't shown.
struct DailyBriefDigest: Equatable {
    struct Project: Equatable, Identifiable {
        var name: String
        var sessions: Int?
        var models: [String]
        var id: String { name }
    }
    struct Goal: Equatable, Identifiable {
        var objective: String
        var minutes: Int?
        var id: String { objective }
    }

    var activeMinutes: Int?
    var activeTimeBelowMinute = false
    var tokens: Int?
    var requests: Int?
    var modelSteps: Int?
    var nativeRecordsFinished: Int?
    var modelStepsArePartial = false
    var tokensArePartial = false
    var toolUses: Int?
    var sessions: Int?
    var stepsFinished: Int?
    var fileChanges: Int?
    var commits: Int?
    var projects: [Project] = []
    var goals: [Goal] = []

    var hasFigures: Bool {
        [activeMinutes, tokens, requests, modelSteps, nativeRecordsFinished, toolUses, sessions, stepsFinished, fileChanges].contains { $0 != nil }
    }

    static func parse(_ entry: ActivityJournalEntry) -> DailyBriefDigest {
        var digest = DailyBriefDigest()
        for outcome in entry.outcomes {
            digest.sessions = digest.sessions ?? int(outcome, #"([\d,]+) (?:observed )?sessions?\b"#)
            // Current wording first, then the first format ("daily report").
            digest.stepsFinished = digest.stepsFinished ?? int(outcome, #"([\d,]+) recorded (?:steps? finished|turns? completed)"#)
            digest.modelSteps = digest.modelSteps ?? int(outcome, #"([\d,]+) observed model steps"#)
            digest.nativeRecordsFinished = digest.nativeRecordsFinished ?? int(outcome, #"([\d,]+) native records finished"#)
            digest.fileChanges = digest.fileChanges ?? int(outcome, #"([\d,]+) (?:recorded file changes?|file-change receipts?)"#)
            digest.commits = digest.commits ?? int(outcome, #"([\d,]+) (?:observed Git commits?|repository commits?)"#)
        }
        for section in DailyBriefSection.parse(entry.markdown) {
            let lines = section.lines.map { line -> String in
                let plain = DailyBriefText.plain(line)
                return plain.hasPrefix("• ") ? String(plain.dropFirst(2)) : plain
            }
            switch section.title {
            case "Time and usage":
                for line in lines {
                    if line.hasPrefix("Recorded time") || line.hasPrefix("Closed-turn elapsed time") {
                        digest.activeTimeBelowMinute = line.contains("less than 1 min")
                        digest.activeMinutes = digest.activeTimeBelowMinute ? 0 : int(line, #":\s*([\d,]+) min"#)
                    } else if line.hasPrefix("Recorded tokens") || line.hasPrefix("Recorded token total") {
                        digest.tokens = int(line, #":\s*([\d,]+)"#)
                        digest.tokensArePartial = line.contains("known subtotal")
                    } else if line.hasPrefix("Observed model steps") {
                        digest.modelSteps = int(line, #":\s*([\d,]+)"#)
                        digest.modelStepsArePartial = line.contains("known lower bound")
                    } else if line.hasPrefix("Requests sent") || line.hasPrefix("Prompt submissions") {
                        digest.requests = int(line, #":\s*([\d,]+)"#)
                    } else if line.hasPrefix("Recorded tool uses") || line.hasPrefix("Observed tool calls") {
                        digest.toolUses = int(line, #":\s*([\d,]+)"#)
                    }
                }
            case "Project activity":
                digest.projects = lines.compactMap { line in
                    guard let match = groups(line, #"^(.+): ([\d,]+) sessions?; models(?: reported today)?: (.*?)\.?$"#), match.count == 3 else { return nil }
                    let models = match[2] == "not reported" ? [] : match[2].components(separatedBy: ", ").filter { !$0.isEmpty }
                    return Project(name: match[0], sessions: Int(match[1].replacingOccurrences(of: ",", with: "")), models: models)
                }
            case "Goals and carry-forward":
                digest.goals = lines.compactMap { line in
                    guard let match = groups(line, #"^(?:\[[^\]]*\]\s*)?(.+?) — (?:[^;]*; )?provider(?:-reported)? time(?: so far)?:?\s*([^;]*);"#),
                          match.count == 2 else { return nil }
                    return Goal(objective: match[0], minutes: int(match[1], #"([\d,]+) min"#))
                }
            default:
                break
            }
        }
        if let finished = digest.nativeRecordsFinished { digest.stepsFinished = finished }
        return digest
    }

    private static func int(_ text: String, _ pattern: String) -> Int? {
        groups(text, pattern)?.first.flatMap { Int($0.replacingOccurrences(of: ",", with: "")) }
    }

    private static func groups(_ text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1 ..< match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}
