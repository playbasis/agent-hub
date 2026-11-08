import Foundation

public enum BridgePageGroup: String, CaseIterable, Identifiable, Sendable {
    case activity = "Activity", conversations = "Conversations", app = "App"
    public var id: String { rawValue }
    public var pages: [BridgePage] { BridgePage.allCases.filter { $0.group == self } }
}

/// One catalog for sidebar destinations, restored selections and entry points.
/// Existing Reports titles remain valid preference values.
public enum BridgePage: String, CaseIterable, Identifiable, Sendable {
    case overview = "Overview", now = "Now", goals = "Goals", team = "Team"
    case projects = "Projects", models = "Models", skills = "Skills", journal = "Journal", providerProof = "Provider Proof"
    case teamChat = "Team Chat", glmChat = "GLM Chat"
    case accounts = "Accounts", credits = "Credits", logs = "Logs", settings = "Settings"

    public var id: String {
        switch self {
        case .team: return "agents"
        case .providerProof: return "provider-proof"
        case .teamChat: return "team-chat"
        case .glmChat: return "glm-chat"
        default: return rawValue.lowercased()
        }
    }
    public var title: String {
        switch self {
        case .team: return "Agents"
        case .now: return "Sessions"
        case .providerProof: return "Verification"
        default: return rawValue
        }
    }
    public var group: BridgePageGroup {
        switch self {
        case .teamChat, .glmChat: return .conversations
        case .accounts, .credits, .logs, .settings: return .app
        default: return .activity
        }
    }
    /// Outline SF Symbols: the sidebar is monochrome, so glyphs carry shape
    /// and the selected row carries the one accent colour.
    public var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .now: return "rectangle.stack"
        case .goals: return "target"
        case .team: return "person.2"
        case .projects: return "folder"
        case .models: return "cpu"
        case .skills: return "wand.and.stars"
        case .journal: return "book.closed"
        case .providerProof: return "checkmark.seal"
        case .teamChat: return "bubble.left.and.bubble.right"
        case .glmChat: return "sparkles"
        case .accounts: return "person.crop.circle"
        case .credits: return "creditcard"
        case .logs: return "doc.text"
        case .settings: return "gearshape"
        }
    }
    public var subtitle: String {
        switch self {
        case .overview: return "What your agents did, and what stands out"
        case .now: return "Who is working now, and every session"
        case .goals: return "Long-running objectives and the agents working on them"
        case .team: return "Each agent, its role and the work it did"
        case .projects: return "Where the work happened"
        case .models: return "Which models did the work and what they used"
        case .skills: return "Skills and instruction files your agents load, and what they cost"
        case .journal: return "Daily summaries you can keep and share"
        case .providerProof: return "Proof of which provider answered each request"
        case .teamChat: return "Plan and build with Claude, Codex and Gemini together"
        case .glmChat: return "Chat with GLM through DigitalOcean"
        case .accounts: return "Your linked plans, limits and sign-in"
        case .credits: return "Reported balance history, estimated pace and local usage"
        case .logs: return "What \(BridgeBrand.shortName) has been doing, stored on this Mac"
        case .settings: return "Appearance, projects, default models and limits"
        }
    }
    /// ⌘1–⌘9 follow the sidebar order; later pages have no number.
    public var shortcutNumber: Int? {
        guard let index = BridgePageGroup.allCases.flatMap(\.pages).firstIndex(of: self), index < 9 else { return nil }
        return index + 1
    }
    public var showsActivityFilters: Bool {
        [.overview, .now, .goals, .team, .projects, .models, .skills, .credits].contains(self)
    }
    public var supportsSessionInspector: Bool { showsActivityFilters && self != .credits }
    public var needsActivityCollection: Bool { showsActivityFilters || self == .journal }

    public static func restored(_ value: String?) -> BridgePage {
        guard let value else { return .overview }
        return allCases.first { $0.rawValue == value || $0.id == value || $0.title == value } ?? .overview
    }
}

public enum BridgeEntryPoint: CaseIterable, Sendable {
    case reports, teamChat, glmChat, accounts, logs, settings, providerProof
    public var destination: BridgePage {
        switch self {
        case .reports: return .overview
        case .teamChat: return .teamChat
        case .glmChat: return .glmChat
        case .accounts: return .accounts
        case .logs: return .logs
        case .settings: return .settings
        case .providerProof: return .providerProof
        }
    }
}

public struct BridgeNavigationState: Equatable, Sendable {
    public private(set) var page: BridgePage
    public private(set) var selectedSessionID: String?
    public private(set) var backHistory: [BridgePage] = []
    public private(set) var forwardHistory: [BridgePage] = []

    public init(restoredPage: String? = nil) { page = BridgePage.restored(restoredPage) }
    public var canGoBack: Bool { !backHistory.isEmpty }
    public var canGoForward: Bool { !forwardHistory.isEmpty }
    public mutating func navigate(to destination: BridgePage) {
        guard destination != page else { return }
        backHistory.append(page); backHistory = Array(backHistory.suffix(50))
        page = destination; forwardHistory = []
    }
    public mutating func selectSession(_ id: String?) { selectedSessionID = id }
    public mutating func openSession(_ id: String) {
        selectedSessionID = id; navigate(to: .goals)
    }
    public mutating func goBack() {
        guard let destination = backHistory.popLast() else { return }
        forwardHistory.append(page); page = destination
    }
    public mutating func goForward() {
        guard let destination = forwardHistory.popLast() else { return }
        backHistory.append(page); page = destination
    }
}
