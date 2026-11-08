import Foundation

/// Which period and scope an economic report covers. Resolving it reads
/// nothing from disk or providers.
public struct EconomicReportQuery: Equatable, Sendable {
    public enum Period: String, CaseIterable, Sendable {
        case last24Hours = "24h", last7Days = "7d", last30Days = "30d"
        case day, week, month, year, all
        var isCalendar: Bool { [.day, .week, .month, .year].contains(self) }
    }

    public var period: Period
    /// The calendar period before the current one (yesterday, last week…).
    public var previous: Bool
    public var from: Date?
    public var to: Date?
    public var provider: AgentName?
    /// A repository folder: sessions in it, below it, or that edited it.
    public var project: String?

    public init(period: Period = .last7Days, previous: Bool = false, from: Date? = nil, to: Date? = nil, provider: AgentName? = nil, project: String? = nil) {
        self.period = period; self.previous = previous; self.from = from; self.to = to; self.provider = provider; self.project = project
    }

    public init(queryItems: [URLQueryItem]) throws {
        let allowed = Set(["period", "previous", "from", "to", "provider", "project"])
        var fields: [String: String] = [:]
        for item in queryItems {
            guard allowed.contains(item.name), fields[item.name] == nil, let value = item.value, !value.isEmpty, value.utf8.count <= 4_096 else {
                throw BridgeError.invalidRequest("Use period, previous, from, to, provider or project once each, with a value.")
            }
            fields[item.name] = value
        }
        self.init()
        if let raw = fields["period"] {
            guard let value = Period(rawValue: raw) else { throw BridgeError.invalidRequest("Period must be 24h, 7d, 30d, day, week, month, year or all.") }
            period = value
        }
        if let raw = fields["previous"] {
            guard ["true", "false"].contains(raw) else { throw BridgeError.invalidRequest("previous must be true or false.") }
            previous = raw == "true"
        }
        if let raw = fields["from"] { from = try ActivityAccountingQuery.parseDate(raw) }
        if let raw = fields["to"] { to = try ActivityAccountingQuery.parseDate(raw) }
        if let raw = fields["provider"] {
            guard let value = AgentName(rawValue: raw), value != .none else { throw BridgeError.invalidRequest("Provider must be claude, codex or grok.") }
            provider = value
        }
        project = fields["project"]
        try validate()
    }

    public static func parse(target: String) throws -> Self {
        guard let components = URLComponents(string: "http://localhost" + target), components.fragment == nil else {
            throw BridgeError.invalidRequest("Invalid economics query.")
        }
        return try Self(queryItems: components.queryItems ?? [])
    }

    public func validate() throws {
        if previous { guard period.isCalendar, from == nil, to == nil else { throw BridgeError.invalidRequest("previous applies to day, week, month or year.") } }
        if let project { guard project.hasPrefix("/"), !project.contains("\0"), project.utf8.count <= 4_096 else { throw BridgeError.invalidRequest("Project must be an absolute folder path.") } }
    }

    /// The half-open period the report covers. Calendar periods use the
    /// Gregorian calendar with weeks starting on Monday in `timeZone`; the
    /// current period ends at the snapshot time.
    public func resolvePeriod(asOf: Date, timeZone: TimeZone) throws -> EconomicReport.Period {
        try validate()
        guard let asOf = ContractTime.normalized(asOf) else { throw BridgeError.invalidRequest("The activity snapshot has no valid time.") }
        if from != nil || to != nil {
            guard let end = ContractTime.normalized(to ?? asOf), end <= asOf else { throw BridgeError.invalidRequest("The period must end by the snapshot time.") }
            let start = from.flatMap(ContractTime.normalized)
            if let start { guard start < end else { throw BridgeError.invalidRequest("The period must start before it ends.") } }
            return .init(from: start, to: end, timeZone: timeZone.identifier, granularity: .custom, label: "Custom period")
        }
        switch period {
        case .last24Hours: return .init(from: asOf.addingTimeInterval(-86_400), to: asOf, timeZone: timeZone.identifier, granularity: .rolling, label: "Last 24 hours")
        case .last7Days: return .init(from: asOf.addingTimeInterval(-7 * 86_400), to: asOf, timeZone: timeZone.identifier, granularity: .rolling, label: "Last 7 days")
        case .last30Days: return .init(from: asOf.addingTimeInterval(-30 * 86_400), to: asOf, timeZone: timeZone.identifier, granularity: .rolling, label: "Last 30 days")
        case .all: return .init(from: nil, to: asOf, timeZone: timeZone.identifier, granularity: .all, label: "All saved history")
        case .day, .week, .month, .year:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            calendar.firstWeekday = 2
            calendar.minimumDaysInFirstWeek = 4
            let component: Calendar.Component, granularity: EconomicReport.Period.Granularity, labels: (String, String)
            switch period {
            case .day: component = .day; granularity = .day; labels = ("Today", "Yesterday")
            case .week: component = .weekOfYear; granularity = .week; labels = ("This week", "Last week")
            case .month: component = .month; granularity = .month; labels = ("This month", "Last month")
            default: component = .year; granularity = .year; labels = ("This year", "Last year")
            }
            // A boundary instant belongs to the period it starts.
            guard let current = calendar.dateInterval(of: component, for: asOf.addingTimeInterval(-0.001)) else {
                throw BridgeError.invalidRequest("The calendar period couldn't be resolved.")
            }
            if previous {
                guard let start = calendar.date(byAdding: component, value: -1, to: current.start) else { throw BridgeError.invalidRequest("The calendar period couldn't be resolved.") }
                return .init(from: start, to: current.start, timeZone: timeZone.identifier, granularity: granularity, label: labels.1)
            }
            return .init(from: current.start, to: min(current.end, asOf), timeZone: timeZone.identifier, granularity: granularity, label: labels.0)
        }
    }
}
