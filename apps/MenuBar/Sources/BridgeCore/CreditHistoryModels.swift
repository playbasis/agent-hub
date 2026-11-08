import Foundation

/// A local history partition, not a verified person's identity. Identifiers are
/// re-hashed so exports contain neither account addresses nor process IDs.
public struct CreditHistoryScope: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case account, anonymous, imported }
    public var kind: Kind
    public var id: String

    public static func account(_ hash: String) -> Self { make(.account, hash) }
    public static func anonymous(_ epoch: String) -> Self { make(.anonymous, epoch) }
    public static func imported(_ identifier: String) -> Self { make(.imported, identifier) }
    private static func make(_ kind: Kind, _ value: String) -> Self {
        Self(kind: kind, id: TraceCrypto.digest("credit-history/1:" + kind.rawValue + ":" + value))
    }
}

public struct CreditHistoryRecord: Codable, Equatable, Identifiable, Sendable {
    public var schemaVersion: String = "credit-history/1"
    public var sequence: Int
    public var scope: CreditHistoryScope
    public var observedAt: Date
    /// Exact provider text; omission is never converted to zero.
    public var reportedBalance: String?
    public var hasCredits: Bool?
    public var unlimited: Bool?
    public var source: QuotaSource = .live
    public var limitID: String = "codex"
    public var warnings: [String]
    public var previousHash: String?
    public var recordHash: String
    public var id: String { recordHash }
}

public struct CreditHistoryRecordResult: Equatable, Sendable {
    public enum Disposition: String, Sendable { case appended, duplicate, rejected }
    public var disposition: Disposition
    public var reason: String?
    public var scope: CreditHistoryScope?
    public var warnings: [String]
}

public struct CreditHistoryScopeSummary: Codable, Equatable, Identifiable, Sendable {
    public var scope: CreditHistoryScope
    public var readingCount: Int
    public var firstObservedAt: Date
    public var lastObservedAt: Date
    public var id: String { scope.id }
}

public struct CreditHistoryBalancePoint: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var observedAt: Date
    public var reportedBalance: String?
    public var hasCredits: Bool?
    public var unlimited: Bool?
    public var isConsistent: Bool
}

public struct CreditHistoryInterval: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case decrease, unchanged, fundingOrAdjustment, gap, unavailable, conflicting, clockAnomaly
    }
    public var id: String
    public var from: Date
    public var to: Date
    public var kind: Kind
    /// Exact mathematical change in the reported balance, not a usage receipt.
    public var derivedBalanceDelta: String?
    /// Positive net decline, estimated as drawdown; not invoiced consumption.
    public var estimatedDrawdown: String?
    public var eligibleForRate: Bool
}

public struct CreditHistoryRate: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var from: Date
    public var to: Date
    public var estimatedDrawdown: String
    /// Approximate model output. Exact balances and deltas remain strings.
    public var estimatedCreditsPerHour: Double
}

public struct CreditHistoryForecast: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case estimated, insufficientEvidence, unavailable }
    public var state: State
    public var reason: String
    public var reportedBalance: String?
    public var observedAt: Date?
    public var estimatedCreditsPerHour: Double?
    public var estimatedSecondsRemaining: Double?
    public var fasterPaceSecondsRemaining: Double?
    /// Nil when observed pauses make the slower-pace bound open-ended.
    public var slowerPaceSecondsRemaining: Double?
    public var eligiblePairCount: Int
    public var observedDurationSeconds: Double
    public var coverageRatio: Double
    public var caveat: String = "Estimate from account-wide net balance declines, not an invoice or measured consumption. Adjustments and other devices may affect it. Future pace can change."
}

public struct CreditHistoryCompleteness: Codable, Equatable, Sendable {
    public var integrityVerified: Bool
    public var retainedRecordCount: Int
    public var selectedRecordCount: Int
    public var invalidLineCount: Int
    public var tornFinalLine: Bool
    public var firstObservedAt: Date?
    public var lastObservedAt: Date?
    public var eligibleDurationSeconds: Double
    /// Coverage between the first and last selected readings, not a claim of
    /// continuous collection throughout the entire requested calendar window.
    public var coverageRatio: Double
}

public struct CreditHistoryReport: Codable, Equatable, Sendable {
    public var schemaVersion: String = "credit-history/1"
    public var generatedAt: Date
    public var from: Date
    public var to: Date
    public var selectedScope: CreditHistoryScope?
    public var scopes: [CreditHistoryScopeSummary]
    public var records: [CreditHistoryRecord]
    public var balancePoints: [CreditHistoryBalancePoint]
    public var intervals: [CreditHistoryInterval]
    public var rates: [CreditHistoryRate]
    public var forecast: CreditHistoryForecast
    public var completeness: CreditHistoryCompleteness
    /// Stable machine-readable codes; presentation can explain them plainly.
    public var warnings: [String]
}

public enum CreditHistoryError: Error, LocalizedError {
    case io(String), unsafeFile, limitExceeded, corruptHistory
    public var errorDescription: String? {
        switch self {
        case .io(let action): return "Credit history could not \(action)."
        case .unsafeFile: return "Credit history is not an owner-only regular file."
        case .limitExceeded: return "Credit history reached its safe read or storage limit; history was not rewritten."
        case .corruptHistory: return "Credit history has an invalid, conflicting, or incomplete record; history was not rewritten."
        }
    }
}
