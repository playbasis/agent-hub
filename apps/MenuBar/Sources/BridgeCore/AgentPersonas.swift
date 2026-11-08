import Foundation
import Darwin

/// WorkspaceOps-style roles, inferred from what an agent session actually did.
public enum AgentRole: String, CaseIterable, Codable, Sendable {
    case coordinator, analyst, `operator`, reviewer, specialist

    public var title: String {
        switch self {
        case .coordinator: return "Coordinator"
        case .analyst: return "Analyst"
        case .`operator`: return "Operator"
        case .reviewer: return "Reviewer"
        case .specialist: return "Specialist"
        }
    }

    /// SF Symbol shown beside the role label.
    public var symbol: String {
        switch self {
        case .coordinator: return "point.3.connected.trianglepath.dotted"
        case .analyst: return "magnifyingglass"
        case .`operator`: return "hammer"
        case .reviewer: return "checkmark.shield"
        case .specialist: return "sparkles"
        }
    }

    /// What the role means in Bridge terms, for help text.
    public var explanation: String {
        switch self {
        case .coordinator: return "Owns a goal or delegates to other agents."
        case .analyst: return "Mostly research and inspection tool calls."
        case .`operator`: return "Mostly command execution and implementation."
        case .reviewer: return "Mostly review and test tool calls."
        case .specialist: return "No dominant category was observed."
        }
    }

    /// Role from observed evidence. A session that owns a goal or has child
    /// agents coordinates; otherwise the dominant tool-category group wins.
    /// Ties resolve in declaration order for determinism.
    public static func infer(_ session: ActivitySession, hasChildren: Bool) -> AgentRole {
        if session.goal != nil || hasChildren { return .coordinator }
        // Decimal avoids overflow when malformed/native counters contain very
        // large values; converting each count to Double would also lose ties.
        var score: [AgentRole: Decimal] = [:]
        for turn in session.turns {
            for (category, count) in turn.categories where count > 0 {
                guard let role = role(forCategory: category) else { continue }
                score[role, default: 0] += Decimal(count)
            }
        }
        let ranked = AgentRole.allCases.compactMap { role in score[role].map { (role, $0) } }
        guard let best = ranked.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return .specialist }
        // Prefer the earliest declared role among equals.
        return ranked.first { $0.1 == best.1 }?.0 ?? best.0
    }

    static func role(forCategory category: String) -> AgentRole? {
        switch category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "coordination", "delegation": return .coordinator
        case "research", "inspection": return .analyst
        case "execution", "implementation": return .`operator`
        case "review", "tests": return .reviewer
        default: return nil
        }
    }
}

public struct AgentPersona: Equatable, Hashable, Identifiable, Sendable {
    /// Resource file name without extension, e.g. "studio-operator-hana-tanaka".
    public var slug: String
    public var role: AgentRole
    public var firstName: String
    public var fullName: String
    public var id: String { slug }
}

public enum AgentPersonaCatalog {
    /// Every bundled portrait. Generated from Resources/AgentPersonas.
    static let slugs: [String] = [
        "analyst-david-okafor",
        "clearledger-analyst-victor-shah",
        "clearledger-coordinator-helen-brooks",
        "clearledger-operator-samir-iqbal",
        "clearledger-reviewer-june-wallace",
        "clearledger-specialist-noor-haddad",
        "coordinator-maya-chen",
        "harborgrid-analyst-mateo-cruz",
        "harborgrid-coordinator-elise-romero",
        "harborgrid-operator-jordan-kim",
        "harborgrid-reviewer-rina-das",
        "harborgrid-specialist-pavel-novak",
        "meridian-analyst-marcus-reed",
        "meridian-coordinator-chloe-nguyen",
        "meridian-operator-imani-cross",
        "meridian-reviewer-caleb-ortiz",
        "meridian-specialist-yuki-tan",
        "novafiber-analyst-benoit-laurent",
        "novafiber-coordinator-lila-park",
        "novafiber-operator-tessa-lin",
        "novafiber-reviewer-idris-bell",
        "novafiber-specialist-farah-saleh",
        "operator-priya-sharma",
        "pulsecart-analyst-devin-cole",
        "pulsecart-coordinator-airi-hayashi",
        "pulsecart-coordinator-sora-hayashi",
        "pulsecart-operator-mila-petrov",
        "pulsecart-reviewer-priyank-rao",
        "pulsecart-specialist-zoe-alvarez",
        "reviewer-james-whitfield",
        "specialist-banking-sophie-laurent",
        "specialist-commerce-carlos-mendez",
        "specialist-education-lena-nakamura",
        "specialist-generic-tomoko-hayashi",
        "specialist-healthcare-aisha-rahman",
        "specialist-insurance-margaret-liu",
        "specialist-investing-henrik-johansson",
        "specialist-logistics-erik-lindqvist",
        "specialist-service-nadia-petrova",
        "specialist-travel-rafael-santos",
        "specialist-workforce-amara-osei",
        "studio-analyst-amira-hasan",
        "studio-analyst-minh-chau-tran",
        "studio-analyst-nattawut-chaiyo",
        "studio-analyst-rex-navarro",
        "studio-coordinator-alicia-tan",
        "studio-coordinator-valeria-solis",
        "studio-operator-ethan-goh",
        "studio-operator-hana-tanaka",
        "studio-operator-kanya-souvannavong",
        "studio-operator-lucia-ferreira",
        "studio-operator-siriporn-vattanakul",
        "studio-operator-tobias-engel",
        "studio-reviewer-eitan-barak",
        "studio-reviewer-faris-rahman",
        "studio-reviewer-kwame-asante",
        "studio-reviewer-rompho-isaiah",
        "studio-specialist-aina-ismail",
        "studio-specialist-darius-cole",
        "studio-specialist-rena-matsuda",
    ]

    public static let all: [AgentPersona] = slugs.compactMap(parse)

    public static func personas(for role: AgentRole) -> [AgentPersona] {
        all.filter { $0.role == role }
    }

    /// "[team-]role-first-last[-more]" → persona. Specialist files may carry a
    /// domain segment ("specialist-healthcare-aisha-rahman"), which is skipped.
    static func parse(_ slug: String) -> AgentPersona? {
        // Slugs are resource names, never paths. Reject empty components and
        // punctuation instead of silently normalizing an invalid catalog entry.
        guard !slug.isEmpty, slug.utf8.count <= 180,
              slug.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
              !slug.hasPrefix("-"), !slug.hasSuffix("-"), !slug.contains("--") else { return nil }
        let parts = slug.split(separator: "-").map(String.init)
        guard let roleIndex = parts.firstIndex(where: { AgentRole(rawValue: $0) != nil }),
              roleIndex <= 1,
              let role = AgentRole(rawValue: parts[roleIndex]) else { return nil }
        var nameParts = Array(parts[(roleIndex + 1)...])
        let domains: Set<String> = ["banking", "commerce", "education", "generic", "healthcare", "insurance", "investing", "logistics", "service", "travel", "workforce"]
        if role == .specialist, roleIndex == 0, let domain = nameParts.first, domains.contains(domain) { nameParts.removeFirst() }
        guard nameParts.count >= 2, let first = nameParts.first else { return nil }
        let full = nameParts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return AgentPersona(slug: slug, role: role, firstName: first.prefix(1).uppercased() + first.dropFirst(), fullName: full)
    }

    /// Process-independent FNV-1a hash. Swift's hashValue is seeded per launch,
    /// which would reshuffle every face on restart.
    static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    public struct Assignment: Equatable, Sendable {
        public var role: AgentRole
        public var persona: AgentPersona?
    }

    /// Deterministic assignment for a single snapshot. For stable identities
    /// across changing history and restarts, use AgentPersonaAssignmentStore.
    public static func assign(_ sessions: [ActivitySession]) -> [String: Assignment] {
        var identities: [String: String] = [:]
        return assign(sessions, identities: &identities)
    }

    fileprivate static func assign(_ sessions: [ActivitySession], identities: inout [String: String]) -> [String: Assignment] {
        // Late provider replays can repeat an ID. Select the latest observation
        // deterministically, rather than allowing input order to consume two
        // portraits and overwrite the first result.
        var canonical: [String: ActivitySession] = [:]
        for session in sessions where validSessionID(session.id) {
            if let prior = canonical[session.id], precedes(session, prior) { continue }
            canonical[session.id] = session
        }
        let values = canonical.values.sorted(by: precedes)
        let parents = Set(values.compactMap { session -> String? in
            guard let parent = session.parentSessionID, !parent.isEmpty else { return nil }
            let qualified = AgentName.allCases.contains { parent.hasPrefix($0.rawValue + ":") }
            return qualified ? parent : session.provider.rawValue + ":" + parent
        })
        let bySlug = Dictionary(all.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        var counts: [String: Int] = [:]
        for slug in identities.values where bySlug[slug] != nil { counts[slug, default: 0] += 1 }
        var visibleCounts: [String: Int] = [:]
        for session in values {
            if let slug = identities[session.id], bySlug[slug] != nil { visibleCounts[slug, default: 0] += 1 }
        }
        var result: [String: Assignment] = [:]
        let owned = ActivityAnalytics.ownedTurnsBySession(in: values)
        for session in values {
            let hasChildren = parents.contains(session.provider.rawValue + ":" + session.nativeID) || parents.contains(session.id)
            // Forked native transcripts retain ancestor receipts. Role labels
            // must describe this session's own work, using the full snapshot
            // even when its ancestor is outside the visible roster filter.
            var evidence = session
            evidence.turns = owned[session.id] ?? []
            let role = AgentRole.infer(evidence, hasChildren: hasChildren)
            // A portrait identifies a session; its current role describes the
            // latest evidence. New tools or newly discovered children may
            // change the role without changing the face.
            if let slug = identities[session.id], let persona = bySlug[slug] {
                result[session.id] = Assignment(role: role, persona: persona)
                continue
            }
            let pool = personas(for: role)
            guard !pool.isEmpty else {
                result[session.id] = Assignment(role: role, persona: nil)
                continue
            }
            let start = Int(stableHash(session.id) % UInt64(pool.count))
            // Prefer distinct faces in this snapshot before balancing reuse
            // across inactive historical sessions.
            let leastVisible = pool.map { visibleCounts[$0.slug, default: 0] }.min() ?? 0
            let leastUsed = pool.filter { visibleCounts[$0.slug, default: 0] == leastVisible }.map { counts[$0.slug, default: 0] }.min() ?? 0
            let choice = (0 ..< pool.count).lazy.map { pool[(start + $0) % pool.count] }.first { visibleCounts[$0.slug, default: 0] == leastVisible && counts[$0.slug, default: 0] == leastUsed } ?? pool[start]
            counts[choice.slug, default: 0] += 1
            visibleCounts[choice.slug, default: 0] += 1
            identities[session.id] = choice.slug
            result[session.id] = Assignment(role: role, persona: choice)
        }
        return result
    }

    fileprivate static func validSessionID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 1_024 && !id.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func precedes(_ lhs: ActivitySession, _ rhs: ActivitySession) -> Bool {
        func time(_ date: Date) -> Double { date.timeIntervalSince1970.isFinite ? date.timeIntervalSince1970 : 0 }
        if lhs.id != rhs.id {
            if time(lhs.createdAt) != time(rhs.createdAt) { return time(lhs.createdAt) < time(rhs.createdAt) }
            return lhs.id < rhs.id
        }
        if time(lhs.updatedAt) != time(rhs.updatedAt) { return time(lhs.updatedAt) < time(rhs.updatedAt) }
        if time(lhs.observedAt) != time(rhs.observedAt) { return time(lhs.observedAt) < time(rhs.observedAt) }
        let left = AgentRole.infer(lhs, hasChildren: false).rawValue
        let right = AgentRole.infer(rhs, hasChildren: false).rawValue
        if left != right { return left < right }
        if lhs.parentSessionID != rhs.parentSessionID { return (lhs.parentSessionID ?? "") < (rhs.parentSessionID ?? "") }
        return time(lhs.createdAt) < time(rhs.createdAt)
    }
}

/// App-owned portrait identity map. Writes are atomic, private, and coordinated
/// across processes. A failed write keeps the in-memory identity and exposes a
/// diagnostic; unsupported/corrupt files are preserved for recovery.
public final class AgentPersonaAssignmentStore: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL?
    private let persistenceRetryInterval: TimeInterval
    private var retryAfter: TimeInterval = 0
    private var identities: [String: String] = [:]
    private var cachedInput: [ActivitySession]?
    private var cachedResult: [String: AgentPersonaCatalog.Assignment] = [:]
    private var errorMessage: String?

    public init(fileURL: URL? = BridgePaths.applicationSupport.appendingPathComponent("agent-personas.json"), persistenceRetryInterval: TimeInterval = 30) {
        self.fileURL = fileURL
        self.persistenceRetryInterval = persistenceRetryInterval.isFinite ? max(0, persistenceRetryInterval) : 30
    }

    public var persistenceError: String? {
        lock.lock(); defer { lock.unlock() }
        return errorMessage
    }

    public func assignments(for sessions: [ActivitySession]) -> [String: AgentPersonaCatalog.Assignment] {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if cachedInput == sessions, errorMessage == nil || now < retryAfter { return cachedResult }
        if errorMessage != nil, now < retryAfter {
            cachedResult = AgentPersonaCatalog.assign(sessions, identities: &identities)
            cachedInput = sessions
            return cachedResult
        }
        if let fileURL {
            var descriptor: Int32 = -1
            do {
                let directory = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                descriptor = Darwin.open(fileURL.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
                guard descriptor >= 0, Darwin.fchmod(descriptor, 0o600) == 0,
                      flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw StoreError.unavailable }
                defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor); descriptor = -1 }
                let stored = try load(fileURL)
                // Memory wins after a transient write failure so a portrait
                // already shown to the user cannot silently change.
                identities = stored.merging(identities) { _, memory in memory }
                cachedResult = AgentPersonaCatalog.assign(sessions, identities: &identities)
                if stored != identities {
                    let data = try JSONSerialization.data(withJSONObject: ["schema_version": 1, "assignments": identities], options: [.sortedKeys])
                    try data.write(to: fileURL, options: .atomic)
                }
                if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path) }
                errorMessage = nil
                retryAfter = 0
            } catch {
                if descriptor >= 0 { Darwin.close(descriptor) }
                cachedResult = AgentPersonaCatalog.assign(sessions, identities: &identities)
                errorMessage = "Portrait identities could not be saved: \(error.localizedDescription)"
                retryAfter = now + persistenceRetryInterval
            }
        } else {
            cachedResult = AgentPersonaCatalog.assign(sessions, identities: &identities)
        }
        cachedInput = sessions
        return cachedResult
    }

    private func load(_ url: URL) throws -> [String: String] {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil { throw StoreError.invalid }
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true, (values.fileSize ?? Int.max) <= 16 * 1_024 * 1_024 else { throw StoreError.invalid }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let version = object["schema_version"] as? NSNumber,
              String(cString: version.objCType) != "c", version == 1,
              let entries = object["assignments"] as? [String: Any], entries.count <= 100_000 else { throw StoreError.invalid }
        let allowed = Set(AgentPersonaCatalog.all.map(\.slug))
        return entries.reduce(into: [:]) { result, entry in
            guard AgentPersonaCatalog.validSessionID(entry.key), let slug = entry.value as? String, allowed.contains(slug) else { return }
            result[entry.key] = slug
        }
    }

    private enum StoreError: LocalizedError {
        case unavailable, invalid
        var errorDescription: String? {
            switch self {
            case .unavailable: return "The portrait store is busy or unavailable."
            case .invalid: return "The existing portrait store has an unsupported or invalid format."
            }
        }
    }
}
