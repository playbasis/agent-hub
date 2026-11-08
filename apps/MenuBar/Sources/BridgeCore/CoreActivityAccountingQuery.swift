import Darwin
import Foundation

/// Shared API/CLI selector rules. Resolving a selector performs no filesystem,
/// provider or credential probes; paths are matched against saved metadata.
public struct ActivityAccountingQuery: Equatable, Sendable {
    /// `project=__unattributed__` selects saved sessions whose projectPath is
    /// nil. It is a reserved selector, not a filesystem path or an all fallback.
    public static let unattributedProjectID = "__unattributed__"
    public enum Window: String, Sendable { case rolling24Hours = "24h", calendar14Days = "14d", all }
    public var from: Date?
    public var to: Date?
    public var window: Window?
    public var provider: AgentName?
    public var project: String?
    public var session: String?

    public init(from: Date? = nil, to: Date? = nil, window: Window? = nil, provider: AgentName? = nil, project: String? = nil, session: String? = nil) {
        self.from = from; self.to = to; self.window = window; self.provider = provider; self.project = project; self.session = session
    }

    public init(queryItems: [URLQueryItem]) throws {
        let allowed = Set(["from", "to", "window", "provider", "project", "session"])
        var fields: [String: String] = [:]
        for item in queryItems {
            guard allowed.contains(item.name), fields[item.name] == nil,
                  let value = item.value, !value.isEmpty, value.utf8.count <= 8_192 else {
                throw BridgeError.invalidRequest("Use each supported metrics selector once, with a nonempty value.")
            }
            fields[item.name] = value
        }
        self.init()
        if let raw = fields["from"] { from = try Self.parseDate(raw) }
        if let raw = fields["to"] { to = try Self.parseDate(raw) }
        if let raw = fields["window"] {
            guard let value = Window(rawValue: raw) else { throw BridgeError.invalidRequest("Metrics window must be 24h, 14d, or all.") }
            window = value
        }
        if let raw = fields["provider"] {
            guard let value = AgentName(rawValue: raw), value != .none else { throw BridgeError.invalidRequest("Metrics provider must be claude, codex, or grok.") }
            provider = value
        }
        project = fields["project"]; session = fields["session"]
        try validateShape()
    }

    public static func parse(target: String) throws -> Self {
        guard let components = URLComponents(string: "http://localhost" + target), components.fragment == nil else {
            throw BridgeError.invalidRequest("Invalid metrics query.")
        }
        return try Self(queryItems: components.queryItems ?? [])
    }

    public var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let from { items.append(.init(name: "from", value: Self.dateString(from))) }
        if let to { items.append(.init(name: "to", value: Self.dateString(to))) }
        if let window { items.append(.init(name: "window", value: window.rawValue)) }
        if let provider { items.append(.init(name: "provider", value: provider.rawValue)) }
        if let project { items.append(.init(name: "project", value: project)) }
        if let session { items.append(.init(name: "session", value: session)) }
        return items
    }

    public func path(_ base: String = "/activity/accounting") throws -> String {
        try validateShape()
        var components = URLComponents()
        components.path = base
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let value = components.string else { throw BridgeError.invalidRequest("Invalid metrics selectors.") }
        return value
    }

    public static func hasSnapshot(_ overview: ActivityOverview) -> Bool {
        !overview.sessions.isEmpty && ActivityAccountingPrecision.date(overview.generatedAt).map(validDate) == true
    }

    public func report(overview: ActivityOverview) throws -> ActivityAccounting.Report {
        let resolved = try resolve(overview: overview)
        return ActivityAccounting.build(overview: overview, sessionIDs: resolved.sessionIDs, from: resolved.from, to: resolved.to)
    }

    public struct Resolved: Sendable {
        public var from: Date?
        public var to: Date
        public var sessionIDs: Set<String>
    }

    public func resolve(overview: ActivityOverview) throws -> Resolved {
        try validateShape()
        guard Self.hasSnapshot(overview), let asOf = ActivityAccountingPrecision.date(overview.generatedAt) else {
            throw BridgeError.invalidRequest("No local history has been collected; refresh activity first.")
        }
        guard let end = ActivityAccountingPrecision.date(to ?? asOf) else { throw BridgeError.invalidRequest("Choose a valid metrics end date.") }
        guard Self.validDate(end), end <= asOf else { throw BridgeError.invalidRequest("Metrics end must not be later than the saved snapshot.") }
        let start: Date?
        if let from { start = ActivityAccountingPrecision.date(from) }
        else {
            switch window ?? .rolling24Hours {
            case .all: start = nil
            case .rolling24Hours: start = end.addingTimeInterval(-86_400)
            case .calendar14Days:
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = ActivityAnalytics.reportingTimeZone
                // A midnight boundary contains no portion of the new day:
                // then the window is the preceding fourteen complete days.
                let lastIncludedDay = calendar.startOfDay(for: end.addingTimeInterval(-0.001))
                guard let calendarStart = calendar.date(byAdding: .day, value: -13, to: lastIncludedDay) else {
                    throw BridgeError.invalidRequest("Metrics calendar window could not be resolved.")
                }
                start = calendarStart
            }
        }
        let normalizedStart = start.flatMap(ActivityAccountingPrecision.date)
        if start != nil && normalizedStart == nil { throw BridgeError.invalidRequest("Choose a valid metrics start date.") }
        if let normalizedStart { guard Self.validDate(normalizedStart), normalizedStart < end else { throw BridgeError.invalidRequest("Metrics start must precede its end.") } }
        if let session, !overview.sessions.contains(where: { $0.id == session }) { throw BridgeError.invalidRequest("Choose a session present in the saved activity snapshot.") }
        let unattributed = project == Self.unattributedProjectID
        let normalizedProject = unattributed ? nil : project.map(Self.normalizedPath)
        if let normalizedProject, !overview.sessions.contains(where: { $0.projectPath.map(Self.normalizedPath) == normalizedProject }) {
            throw BridgeError.invalidRequest("Choose a project present in the saved activity snapshot.")
        }
        let selected = overview.sessions.filter { value in
            (provider == nil || value.provider == provider)
                && (session == nil || value.id == session)
                && (unattributed ? value.projectPath == nil : (normalizedProject == nil || value.projectPath.map(Self.normalizedPath) == normalizedProject))
        }
        return Resolved(from: normalizedStart, to: end, sessionIDs: Set(selected.map(\.id)))
    }

    public static func parseDate(_ raw: String) throws -> Date {
        let pattern = #"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.[0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let source = raw as NSString
        guard raw.utf8.count <= 80, let match = regex.firstMatch(in: raw, range: NSRange(location: 0, length: source.length)) else {
            throw BridgeError.invalidRequest("Metrics dates must be full ISO 8601 timestamps with a time zone.")
        }
        let values = (1 ... 6).compactMap { Int(source.substring(with: match.range(at: $0))) }
        guard values.count == 6 else { throw BridgeError.invalidRequest("Invalid metrics date.") }
        let year = values[0], month = values[1], day = values[2]
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1 ... 12).contains(month), (1 ... days[month - 1]).contains(day),
              (0 ... 23).contains(values[3]), (0 ... 59).contains(values[4]), (0 ... 59).contains(values[5]) else {
            throw BridgeError.invalidRequest("Metrics date contains an invalid calendar or clock value.")
        }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let parsed = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw),
              let value = ActivityAccountingPrecision.date(parsed), validDate(value) else {
            throw BridgeError.invalidRequest("Metrics dates must be valid ISO 8601 timestamps with a time zone.")
        }
        return value
    }

    private func validateShape() throws {
        if let from { guard ActivityAccountingPrecision.date(from).map(Self.validDate) == true else { throw BridgeError.invalidRequest("Choose a valid metrics start date.") } }
        if let to { guard ActivityAccountingPrecision.date(to).map(Self.validDate) == true else { throw BridgeError.invalidRequest("Choose a valid metrics end date.") } }
        guard from == nil || window == nil else { throw BridgeError.invalidRequest("Choose a metrics window or an explicit start, not both.") }
        if let provider { guard provider != .none else { throw BridgeError.invalidRequest("Unknown metrics provider.") } }
        if let project { guard project == Self.unattributedProjectID || (project.hasPrefix("/") && project.utf8.count <= 4_096 && !project.contains("\0")) else { throw BridgeError.invalidRequest("Metrics project must be an absolute saved path or __unattributed__.") } }
        if let session { guard !session.isEmpty, session.utf8.count <= 4_096, !session.contains("\0") else { throw BridgeError.invalidRequest("Choose a valid saved session identity.") } }
    }
    private static func validDate(_ date: Date) -> Bool { date.timeIntervalSince1970.isFinite && (0.0 ... 253_402_300_799.0).contains(date.timeIntervalSince1970) }
    private static func normalizedPath(_ value: String) -> String { URL(fileURLWithPath: value).standardizedFileURL.path }
    private static func dateString(_ value: Date) -> String {
        guard let canonical = ActivityAccountingPrecision.date(value), validDate(canonical) else { return "invalid" }
        return ISO8601.withFractional.string(from: canonical)
    }
}

/// Create the export owner-only from its first byte, then publish atomically.
/// This exports only the normalized schema, never raw native payloads.
public enum ActivityAccountingExport {
    public static func write(_ report: ActivityAccounting.Report, to url: URL, overwrite: Bool = false) throws {
        try write(BridgeJSON.encoder.encode(report), to: url, overwrite: overwrite)
    }
    static func write(_ data: Data, to url: URL, overwrite: Bool = false) throws {
        guard url.isFileURL else { throw BridgeError.invalidRequest("Metrics export needs a local file path.") }
        let destination = url.standardizedFileURL
        guard !destination.path.contains("\0"), destination.path.utf8.count <= 4_096 else { throw BridgeError.invalidRequest("Choose a valid metrics export path.") }
        var named = stat()
        if lstat(destination.path, &named) == 0 {
            guard named.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), named.st_uid == geteuid() else { throw BridgeError.invalidRequest("Refusing to replace a linked or unexpected export path.") }
            guard overwrite else { throw BridgeError.invalidRequest("Metrics export already exists; choose another path or use --overwrite.") }
        }
        let template = destination.deletingLastPathComponent().appendingPathComponent(".hub-metrics-\(UUID().uuidString).XXXXXX").path
        var bytes = Array(template.utf8CString)
        let descriptor = mkstemp(&bytes)
        guard descriptor >= 0 else { throw BridgeError.configuration("The metrics export could not be created.") }
        let temporary = String(cString: bytes)
        defer { close(descriptor); unlink(temporary) }
        guard fchmod(descriptor, 0o600) == 0, fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw BridgeError.configuration("Metrics export privacy could not be set.") }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw BridgeError.configuration("Metrics export could not be completely written.") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw BridgeError.configuration("Metrics export could not be saved reliably.") }
        let result = overwrite ? rename(temporary, destination.path) : link(temporary, destination.path)
        guard result == 0 else { throw BridgeError.configuration("Metrics export could not be published; any existing file is unchanged.") }
    }
}

/// Strict command parsing is testable without launching the CLI or a provider.
/// It intentionally offers no refresh/control/auth action.
public struct ActivityAccountingCLIRequest: Sendable {
    public enum Action: String, Sendable { case view, export }
    public var action: Action
    public var query: ActivityAccountingQuery
    public var output: String?
    public var overwrite: Bool

    public init(arguments: [String]) throws {
        var index = 0
        action = .view; query = .init(); output = nil; overwrite = false
        if let first = arguments.first, !first.hasPrefix("--") {
            guard let value = Action(rawValue: first) else { throw BridgeError.invalidRequest("Use metrics view or metrics export.") }
            action = value; index = 1
        }
        let selectors = Set(["--from", "--to", "--window", "--provider", "--project", "--session"])
        var items: [URLQueryItem] = []
        var seen = Set<String>()
        while index < arguments.count {
            let name = arguments[index]
            guard seen.insert(name).inserted else { throw BridgeError.invalidRequest("Use each metrics option only once.") }
            if name == "--overwrite" { overwrite = true; index += 1; continue }
            guard selectors.contains(name) || name == "--output", index + 1 < arguments.count,
                  !arguments[index + 1].hasPrefix("--"), !arguments[index + 1].isEmpty else {
                throw BridgeError.invalidRequest("Unknown or missing metrics option. Use --window, --from, --to, --provider, --project, --session, or export --output.")
            }
            let value = arguments[index + 1]
            if name == "--output" { output = value }
            else { items.append(.init(name: String(name.dropFirst(2)), value: value)) }
            index += 2
        }
        guard action == .export || (output == nil && !overwrite) else { throw BridgeError.invalidRequest("--output and --overwrite apply only to metrics export.") }
        query = try ActivityAccountingQuery(queryItems: items)
    }
}
