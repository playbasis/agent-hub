import Foundation

/// A passive estimate from the canonical local accounting ledger. These are
/// current standard-rate credit equivalents, never provider charges, a balance
/// reconciliation, or a claim that the work consumed purchased credits.
public enum CodexCreditEstimates {
    public static let schemaVersion = "codex-credit-estimates/1"
    public static let maximumReceipts = 250_000

    public struct Rate: Codable, Equatable, Sendable {
        public let model: String
        /// Exact decimal credits per one million tokens, not USD/API prices.
        public let freshInput: String
        public let cachedInput: String
        public let output: String
        public let promotionAtLeastThrough: String?
    }

    public struct Catalog: Codable, Equatable, Sendable {
        public let id: String
        public let rateAsOf: String
        public let sourceURL: String
        public let unit: String
        /// Unknown publication/effective/expiry dates are intentionally nil.
        /// rateAsOf is a verification date, not a historical effective date.
        public let effectiveFrom: String?
        public let validUntil: String?
        public let rates: [Rate]
    }

    /// An immutable, explicit-ID snapshot. Unknown model aliases and versions
    /// do not inherit a nearby model's rate. This has no API/Azure price source.
    public static let catalog = Catalog(
        id: "openai-codex-credit-token-rates/2026-11-05",
        rateAsOf: "2026-11-05",
        sourceURL: "https://developers.openai.com/codex/pricing#token-rates",
        unit: "credits_per_million_tokens",
        effectiveFrom: nil,
        validUntil: nil,
        rates: [
            Rate(model: "gpt-6-astra", freshInput: "250", cachedInput: "25", output: "1250", promotionAtLeastThrough: nil),
            Rate(model: "gpt-6.1-sol", freshInput: "50", cachedInput: "2.5", output: "250", promotionAtLeastThrough: nil),
            Rate(model: "gpt-6.1-terra", freshInput: "25", cachedInput: "1.25", output: "125", promotionAtLeastThrough: nil),
            Rate(model: "gpt-6-sol", freshInput: "50", cachedInput: "5", output: "250", promotionAtLeastThrough: nil),
            Rate(model: "gpt-6-luna", freshInput: "2.5", cachedInput: "0.25", output: "12.5", promotionAtLeastThrough: nil),
            Rate(model: "gpt-5.6-sol", freshInput: "100", cachedInput: "10", output: "500", promotionAtLeastThrough: "2026-11-21"),
            Rate(model: "gpt-5.6-terra", freshInput: "50", cachedInput: "5", output: "300", promotionAtLeastThrough: nil),
            Rate(model: "gpt-5.6-luna", freshInput: "5", cachedInput: "0.5", output: "30", promotionAtLeastThrough: nil),
        ])

    public enum Reason: String, Codable, CaseIterable, Sendable {
        case unknownModel = "unknown_model"
        case unsupportedModel = "unsupported_model"
        case missingInput = "missing_input"
        case missingCachedInput = "missing_cached_input"
        case missingOutput = "missing_output"
        case missingTotal = "missing_total"
        case inconsistentUsage = "inconsistent_usage"
        case nonAuthoritativeUsage = "non_authoritative_usage"
        case partialNativeMeasurement = "partial_native_measurement"
        case unmeasuredUsage = "unmeasured_usage"
        case outsideAccountingWindow = "outside_accounting_window"
        case unplacedUsage = "unplaced_usage"
        case duplicateReceiptOmitted = "duplicate_receipt_omitted"
        case receiptLimit = "receipt_limit"
        case invalidAccountingReport = "invalid_accounting_report"
        case unsupportedAccountingScope = "unsupported_accounting_scope"
        case arithmeticFailure = "arithmetic_failure"

        public var message: String {
            switch self {
            case .unknownModel: return "No measured model identity; no model rate was guessed."
            case .unsupportedModel: return "The measured model has no exact ID in this credit-rate snapshot."
            case .missingInput: return "Input tokens are unknown; fresh input was not treated as zero."
            case .missingCachedInput: return "Cached input is unknown; the fresh/cached input split was not guessed."
            case .missingOutput: return "Output tokens are unknown, not zero."
            case .missingTotal: return "A total is missing; measured components cannot be fully reconciled."
            case .inconsistentUsage: return "Token components do not reconcile under the Codex input convention."
            case .nonAuthoritativeUsage: return "Usage is not measured provider-reported or authoritative derived usage."
            case .partialNativeMeasurement: return "Native accounting marks the measurement or its coverage as partial."
            case .unmeasuredUsage: return "The native record has no eligible measured token receipt."
            case .outsideAccountingWindow: return "The receipt is not wholly qualified for this accounting window."
            case .unplacedUsage: return "Native usage cannot be dated to this accounting window and was not priced."
            case .duplicateReceiptOmitted: return "A repeated receipt identity was omitted, not charged again."
            case .receiptLimit: return "The bounded estimate omitted additional receipts; the result is partial."
            case .invalidAccountingReport: return "The accounting report or its schema is invalid; no usage was priced."
            case .unsupportedAccountingScope: return "Only canonical local native history is eligible for this estimate."
            case .arithmeticFailure: return "The credit amount exceeded supported exact arithmetic; no combined amount is shown."
            }
        }
    }

    public struct ReasonCount: Codable, Equatable, Identifiable, Sendable {
        public let reason: Reason
        public let count: Int
        public var id: String { reason.rawValue }
        public var message: String { reason.message }
    }

    public struct Coverage: Codable, Equatable, Sendable {
        /// Canonical Codex receipts examined, including explicit unmeasured or
        /// unplaced facts. These are not an inferred number of requests.
        public let receiptCount: Int
        public let usageReceiptCount: Int
        public let pricedReceiptCount: Int
        public let completeReceiptCount: Int
        public let partialReceiptCount: Int
        public let unpricedReceiptCount: Int
        public let observedModelSteps: Int
        public let freshInputReceipts: Int
        public let cachedInputReceipts: Int
        public let outputReceipts: Int
        public let omittedReceiptCount: Int
        /// The canonical receipt schema does not record a service/speed tier.
        /// This is why even a complete token split is not a billed-credit fact.
        public let unknownSpeedReceiptCount: Int
        public var pricedFraction: Double? {
            receiptCount > 0 ? Double(pricedReceiptCount) / Double(receiptCount) : nil
        }
    }

    public struct Summary: Codable, Equatable, Sendable {
        /// Sum of only the priceable measured components. Nil means no priced
        /// component, not zero credits. Inspect isPartial and coverage.
        public let estimatedCredits: Double?
        public let estimatedCreditsExact: String?
        public let isPartial: Bool
        public let coverage: Coverage
        public let reasons: [ReasonCount]
    }

    public struct Row: Codable, Equatable, Identifiable, Sendable {
        public let id: String
        public let model: String?
        public let projectPath: String?
        public let sessionID: String?
        public let modelIDs: [String]
        public let sessionIDs: [String]
        public let estimatedCredits: Double?
        public let estimatedCreditsExact: String?
        public let isPartial: Bool
        public let coverage: Coverage
        public let reasons: [ReasonCount]
    }

    public struct Result: Codable, Equatable, Sendable {
        public let schemaVersion: String
        public let basis: String
        public let provenance: MetricProvenance
        public let catalog: Catalog
        public let scope: ActivityAccountingScope
        public let accountingEvidenceDigest: String
        public let total: Summary
        public let modelRows: [Row]
        public let projectRows: [Row]
        public let sessionRows: [Row]
        public let sourceCoverageIsPartial: Bool
        public let isValid: Bool
        public let warnings: [String]
    }

    /// Pure, bounded projection: no files, provider calls, account balances,
    /// goal counters, prompts, code, aggregate request counts or model guesses.
    /// Ownership and window allocation are inherited from ActivityAccounting.
    public static func build(report: ActivityAccounting.Report) -> Result {
        build(report: report, maximumReceiptCount: maximumReceipts)
    }

    /// For on-screen totals only: skips the source report's fingerprint, which
    /// encodes every receipt and takes seconds on a long history. The
    /// fingerprint field is left empty, so these results are never exported.
    public static func buildForDisplay(report: ActivityAccounting.Report) -> Result {
        build(report: report, maximumReceiptCount: maximumReceipts, includeEvidenceDigest: false)
    }

    /// Smaller bounds are useful for deterministic limit verification. A caller
    /// inside BridgeCore cannot expand the production memory bound.
    static func build(report: ActivityAccounting.Report, maximumReceiptCount: Int, includeEvidenceDigest: Bool = true) -> Result {
        let scopeSupported = report.scope.source == .localNativeHistory
        let datesValid = report.scope.to.timeIntervalSinceReferenceDate.isFinite
            && report.scope.asOf.timeIntervalSinceReferenceDate.isFinite
            && (report.scope.from.map { $0.timeIntervalSinceReferenceDate.isFinite && $0 < report.scope.to } ?? true)
        let reportValid = report.isValid && report.schemaVersion == "accounting/1" && datesValid
        let valid = reportValid && scopeSupported
        let limit = min(maximumReceipts, max(0, maximumReceiptCount))
        var total = Accumulator()
        var models: [String: Accumulator] = [:]
        var projects: [String: Accumulator] = [:]
        var sessions: [String: Accumulator] = [:]
        var seen = Set<String>()
        if !reportValid { total.addReason(.invalidAccountingReport) }
        if !scopeSupported { total.addReason(.unsupportedAccountingScope) }
        if valid {
            let rates = Dictionary(uniqueKeysWithValues: catalog.rates.map { ($0.model, $0) })
            for receipt in report.receipts where receipt.provider == .codex {
                guard total.receipts < limit else {
                    total.omitted += 1; total.addReason(.receiptLimit); continue
                }
                guard seen.insert(receipt.id).inserted else {
                    total.omitted += 1; total.addReason(.duplicateReceiptOmitted); continue
                }
                let model = ActivityModelAccounting.normalized(receipt.model)
                let project = report.sessionProjects[receipt.sessionID] ?? receipt.projectPath
                let fact = estimate(receipt, rate: model.flatMap { rates[$0] }, scope: report.scope)
                total.add(fact, receipt: receipt, model: model)
                let modelKey = model.map { "model:" + $0 } ?? "unknown-model"
                models[modelKey, default: Accumulator()].add(fact, receipt: receipt, model: model)
                let projectKey = project.map { "project:" + $0 } ?? "unknown-project"
                projects[projectKey, default: Accumulator()].add(fact, receipt: receipt, model: model)
                projects[projectKey]?.projectPath = project
                sessions[receipt.sessionID, default: Accumulator()].add(fact, receipt: receipt, model: model)
                sessions[receipt.sessionID]?.projectPath = project
            }
        }
        let partial = report.sourceCoverageIsPartial || !valid || total.omitted > 0
        var warnings = [
            "Estimated local standard-rate credit equivalent, not actual or billed credits. Usage may have been included in a subscription rather than purchased credits.",
            "Uses the credit-rate snapshot verified \(catalog.rateAsOf) for all selected receipts. This is not a claim about historical rates; effective and expiry dates are not known. The gpt-5.6-sol promotional rate was stated to last at least through 2026-11-21, not to expire on that date.",
            "Codex input includes cached input. Cached tokens are subtracted once from fresh input; reasoning is a subset of output and is never added again. No separate cache-write charge is added.",
            "Speed/service tier is not present in these receipts. Fast or Ultrafast multipliers are not applied or inferred from reasoning effort, including ultra.",
            "This Mac's saved, date-qualified receipts are not account-wide usage. Other devices, omitted history, tools and images may not be represented or priced. Estimates are never scaled to a credit-balance decline.",
            "Model, project and session tables are alternative groupings of the same receipts; do not add the tables together. Missing measurements remain unknown, not zero.",
        ]
        if report.sourceCoverageIsPartial { warnings.append("The source accounting report has partial native-history coverage.") }
        if total.omitted > 0 { warnings.append("\(total.omitted) repeated or over-limit receipts were omitted; the estimate is partial.") }
        if !valid { warnings.append("The accounting report was not eligible; no credits were estimated.") }
        return Result(schemaVersion: schemaVersion, basis: "standard_rate_equivalent", provenance: .estimated,
                      catalog: catalog, scope: report.scope, accountingEvidenceDigest: includeEvidenceDigest ? report.evidenceDigest : "",
                      total: total.summary(forcePartial: partial),
                      modelRows: rows(models, dimension: .model, sourcePartial: partial),
                      projectRows: rows(projects, dimension: .project, sourcePartial: partial),
                      sessionRows: rows(sessions, dimension: .session, sourcePartial: partial),
                      sourceCoverageIsPartial: partial, isValid: valid, warnings: warnings)
    }

    private struct Fact {
        var amount: Decimal?
        var reasons = Set<Reason>()
        var usage = false
        var fresh = false
        var cached = false
        var output = false
        var isComplete: Bool { usage && amount != nil && reasons.isEmpty && fresh && cached && output }
    }

    private static func estimate(_ receipt: ActivityAccountingReceipt, rate: Rate?, scope: ActivityAccountingScope) -> Fact {
        var fact = Fact()
        guard receipt.includedInTotals, receipt.kind == .modelStep || receipt.kind == .nativeUsageRemainder else {
            fact.reasons.insert(receipt.kind == .unplacedNativeUsage ? .unplacedUsage : .unmeasuredUsage)
            return fact
        }
        // Reject a malformed decoded report without moving or clipping its
        // usage. In particular, observedAt is never a substitute for event time.
        guard dateQualified(receipt, scope: scope) else {
            fact.reasons.insert(.outsideAccountingWindow); return fact
        }
        fact.usage = true
        if receipt.usageIsPartial == true || receipt.countIsPartial { fact.reasons.insert(.partialNativeMeasurement) }
        guard receipt.usage.hasAuthoritativeProvenance else {
            fact.reasons.insert(.nonAuthoritativeUsage); return fact
        }
        guard let model = ActivityModelAccounting.normalized(receipt.model) else {
            fact.reasons.insert(.unknownModel); return fact
        }
        guard let rate, rate.model == model else {
            fact.reasons.insert(.unsupportedModel); return fact
        }
        let usage = receipt.usage
        func nonnegative(_ value: Int?) -> Int? { value.flatMap { $0 >= 0 ? $0 : nil } }
        let input = nonnegative(usage.input), cached = nonnegative(usage.cachedInput)
        let output = nonnegative(usage.output), total = nonnegative(usage.total)
        if input == nil { fact.reasons.insert(.missingInput) }
        if cached == nil { fact.reasons.insert(.missingCachedInput) }
        if output == nil { fact.reasons.insert(.missingOutput) }
        if total == nil { fact.reasons.insert(.missingTotal) }
        if [usage.input, usage.cachedInput, usage.output, usage.total, usage.reasoning, usage.cacheWriteInput].contains(where: { ($0 ?? 0) < 0 }) {
            fact.reasons.insert(.inconsistentUsage)
        }
        var inputConsistent = true
        if let input, let cached, cached > input { inputConsistent = false; fact.reasons.insert(.inconsistentUsage) }
        if let input, let output, let total {
            let sum = input.addingReportingOverflow(output)
            if sum.overflow || sum.partialValue != total { inputConsistent = false; fact.reasons.insert(.inconsistentUsage) }
        }
        if let reasoning = usage.reasoning, let output, reasoning > output { fact.reasons.insert(.inconsistentUsage) }

        var parts: [(Int, String)] = []
        if inputConsistent {
            if let input, let cached {
                // Use the existing canonical normalizer where it can reconcile
                // the entire split. Cache writes have no independent Codex rate:
                // folding them back into fresh input preserves input − cache.
                if let normalized = ActivityAnalytics.composition(usages: [usage]), normalized.receipts == 1,
                   normalized.freshInput.addingReportingOverflow(normalized.cacheWrites).overflow == false,
                   normalized.freshInput + normalized.cacheWrites == input - cached {
                    parts.append((normalized.freshInput + normalized.cacheWrites, rate.freshInput))
                } else {
                    parts.append((input - cached, rate.freshInput))
                }
                fact.fresh = true
            }
            if let cached { parts.append((cached, rate.cachedInput)); fact.cached = true }
        }
        if let output { parts.append((output, rate.output)); fact.output = true }
        if !parts.isEmpty {
            var amount = Decimal.zero
            for (tokens, rate) in parts {
                guard let component = creditAmount(tokens: tokens, rate: rate), let combined = add(amount, component) else {
                    fact.amount = nil; fact.reasons.insert(.arithmeticFailure); return fact
                }
                amount = combined
            }
            fact.amount = amount
        }
        return fact
    }

    private static func dateQualified(_ receipt: ActivityAccountingReceipt, scope: ActivityAccountingScope) -> Bool {
        func finite(_ date: Date) -> Bool { date.timeIntervalSinceReferenceDate.isFinite }
        func startsInWindow(_ date: Date) -> Bool {
            finite(date) && date < scope.to && (scope.from.map { date >= $0 } ?? true)
        }
        switch receipt.timeBasis {
        case .providerEvent: return receipt.timestamp.map(startsInWindow) ?? false
        case .nativeInterval:
            guard let start = receipt.intervalStart, let end = receipt.intervalEnd, finite(end), end >= start else { return false }
            return startsInWindow(start) && end < scope.to
        case .unplaced: return false
        }
    }

    private static func creditAmount(tokens: Int, rate: String) -> Decimal? {
        guard let parsedRate = Decimal(string: rate, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        var tokens = Decimal(tokens), rate = parsedRate, product = Decimal.zero
        guard NSDecimalMultiply(&product, &tokens, &rate, .plain) == .noError else { return nil }
        var million = Decimal(1_000_000), result = Decimal.zero
        guard NSDecimalDivide(&result, &product, &million, .plain) == .noError, !result.isNaN else { return nil }
        return result
    }

    private static func add(_ lhs: Decimal, _ rhs: Decimal) -> Decimal? {
        var lhs = lhs, rhs = rhs, result = Decimal.zero
        guard NSDecimalAdd(&result, &lhs, &rhs, .plain) == .noError, !result.isNaN else { return nil }
        return result
    }

    private struct Accumulator {
        var amount = Decimal.zero
        var hasAmount = false
        var arithmeticFailed = false
        var receipts = 0, usage = 0, priced = 0, complete = 0, steps = 0
        var fresh = 0, cached = 0, output = 0, omitted = 0
        var reasons: [Reason: Int] = [:]
        var models = Set<String>(), sessions = Set<String>()
        var projectPath: String?

        mutating func addReason(_ reason: Reason, count: Int = 1) { reasons[reason, default: 0] += count }
        mutating func add(_ fact: Fact, receipt: ActivityAccountingReceipt, model: String?) {
            receipts += 1
            if fact.usage { usage += 1 }
            if fact.isComplete { complete += 1 }
            if receipt.countsAsModelStep && fact.usage { steps += 1 }
            if fact.fresh { fresh += 1 }; if fact.cached { cached += 1 }; if fact.output { output += 1 }
            if let value = fact.amount {
                priced += 1; hasAmount = true
                if let sum = CodexCreditEstimates.add(amount, value) { amount = sum }
                else { arithmeticFailed = true; addReason(.arithmeticFailure) }
            }
            for reason in fact.reasons { addReason(reason) }
            if let model { models.insert(model) }
            sessions.insert(receipt.sessionID)
        }
        func summary(forcePartial: Bool) -> Summary {
            let decimal = hasAmount && !arithmeticFailed ? amount : nil
            let value = decimal.map { NSDecimalNumber(decimal: $0).doubleValue }.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let exact = value == nil ? nil : decimal.map { NSDecimalNumber(decimal: $0).stringValue }
            let coverage = Coverage(receiptCount: receipts, usageReceiptCount: usage, pricedReceiptCount: priced,
                                    completeReceiptCount: complete, partialReceiptCount: receipts - complete,
                                    unpricedReceiptCount: receipts - priced, observedModelSteps: steps,
                                    freshInputReceipts: fresh, cachedInputReceipts: cached, outputReceipts: output,
                                    omittedReceiptCount: omitted, unknownSpeedReceiptCount: usage)
            return Summary(estimatedCredits: value, estimatedCreditsExact: exact,
                           isPartial: forcePartial || complete != receipts || arithmeticFailed || !reasons.isEmpty,
                           coverage: coverage,
                           reasons: reasons.map { ReasonCount(reason: $0.key, count: $0.value) }.sorted { $0.id < $1.id })
        }
    }

    private enum Dimension: Equatable { case model, project, session }
    private static func rows(_ groups: [String: Accumulator], dimension: Dimension, sourcePartial: Bool) -> [Row] {
        groups.map { key, bucket in
            let summary = bucket.summary(forcePartial: sourcePartial)
            return Row(id: key, model: dimension == .model ? bucket.models.sorted().first : nil,
                       projectPath: dimension == .model ? nil : bucket.projectPath,
                       sessionID: dimension == .session ? key : nil,
                       modelIDs: bucket.models.sorted(), sessionIDs: bucket.sessions.sorted(),
                       estimatedCredits: summary.estimatedCredits, estimatedCreditsExact: summary.estimatedCreditsExact,
                       isPartial: summary.isPartial, coverage: summary.coverage, reasons: summary.reasons)
        }.sorted {
            if ($0.estimatedCredits == nil) != ($1.estimatedCredits == nil) { return $0.estimatedCredits != nil }
            if $0.estimatedCredits != $1.estimatedCredits { return ($0.estimatedCredits ?? 0) > ($1.estimatedCredits ?? 0) }
            return $0.id < $1.id
        }
    }
}

// Unknown values stay explicit in this new public wire contract. No legacy
// TokenUsage, accounting, audit, or credit-balance schema is changed.
extension CodexCreditEstimates.Summary {
    private enum CodingKeys: String, CodingKey { case estimatedCredits, estimatedCreditsExact, isPartial, coverage, reasons }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(estimatedCredits, forKey: .estimatedCredits); try c.encode(estimatedCreditsExact, forKey: .estimatedCreditsExact)
        try c.encode(isPartial, forKey: .isPartial); try c.encode(coverage, forKey: .coverage); try c.encode(reasons, forKey: .reasons)
    }
}

extension CodexCreditEstimates.Row {
    private enum CodingKeys: String, CodingKey {
        case id, model, projectPath, sessionID, modelIDs, sessionIDs, estimatedCredits, estimatedCreditsExact, isPartial, coverage, reasons
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(model, forKey: .model); try c.encode(projectPath, forKey: .projectPath)
        try c.encode(sessionID, forKey: .sessionID); try c.encode(modelIDs, forKey: .modelIDs); try c.encode(sessionIDs, forKey: .sessionIDs)
        try c.encode(estimatedCredits, forKey: .estimatedCredits); try c.encode(estimatedCreditsExact, forKey: .estimatedCreditsExact)
        try c.encode(isPartial, forKey: .isPartial); try c.encode(coverage, forKey: .coverage); try c.encode(reasons, forKey: .reasons)
    }
}

extension CodexCreditEstimates.Catalog {
    private enum CodingKeys: String, CodingKey { case id, rateAsOf, sourceURL, unit, effectiveFrom, validUntil, rates }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(rateAsOf, forKey: .rateAsOf); try c.encode(sourceURL, forKey: .sourceURL)
        try c.encode(unit, forKey: .unit); try c.encode(effectiveFrom, forKey: .effectiveFrom); try c.encode(validUntil, forKey: .validUntil)
        try c.encode(rates, forKey: .rates)
    }
}
