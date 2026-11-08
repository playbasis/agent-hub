import Foundation

/// Small, explainable outcome observations, not a judgment of decision quality.
/// Inspect one native turn at a time. Tool IDs are meaningful only in that
/// scope; callers combining turns must retain a distinct scopeID per turn.
/// The input's optional visible previews remain memory-only. No text, private
/// reasoning, arguments or result payloads are copied into this output.
public enum WorkOutcomeSignals {
    public static let adapterVersion = "work-outcome-signals/1"
    public static let maximumItems = 4_096
    public static let maximumHints = 128

    public enum Outcome: String, Hashable, Sendable {
        case success, failure, interrupted, unknown
        public var title: String {
            switch self {
            case .success: return "Tool completed"
            case .failure: return "Tool reported an error"
            case .interrupted: return "Tool interrupted"
            case .unknown: return "Tool outcome not established"
            }
        }
    }

    public struct ToolExecution: Identifiable, Equatable, Sendable {
        public let id: String
        public let callID: String?
        public let title: String
        public let timestamp: Date?
        public let outcome: Outcome
        public let evidenceIDs: [String]
        public let hasConflict: Bool
        public let callNotInPage: Bool
        public let adapterVersion: String
    }

    public enum HintKind: String, Hashable, CaseIterable, Sendable {
        case reportedCompletion, reportedFailure, retryMention, correctionMention, verificationMention
        public var title: String {
            switch self {
            case .reportedCompletion: return "Agent reported completion"
            case .reportedFailure: return "Agent mentioned a failure"
            case .retryMention: return "Agent mentioned another attempt"
            case .correctionMention: return "Agent mentioned a correction"
            case .verificationMention: return "Agent mentioned a check"
            }
        }
    }

    /// A language hint is an invitation to inspect a source message, never a
    /// measured outcome, root cause, confirmed retry or sentiment score.
    public struct Hint: Identifiable, Equatable, Sendable {
        public let id: String
        public let kind: HintKind
        public let evidenceIDs: [String]
        public let ruleID: String
        public let adapterVersion: String
        public var title: String { kind.title }
    }

    public struct Summary: Equatable, Sendable {
        public let scopeID: String
        public let executions: [ToolExecution]
        public let hints: [Hint]
        public let isPartial: Bool
        public let adapterVersion: String
        public var successCount: Int { executions.filter { $0.outcome == .success }.count }
        public var failureCount: Int { executions.filter { $0.outcome == .failure }.count }
        public var interruptedCount: Int { executions.filter { $0.outcome == .interrupted }.count }
        public var unknownCount: Int { executions.filter { $0.outcome == .unknown }.count }
        public var conflictCount: Int { executions.filter(\.hasConflict).count }
        public var measuredCount: Int { successCount + failureCount }
        public var totalCount: Int { executions.count }
        public var terminalOutcomeCount: Int { measuredCount + interruptedCount }
        /// Tool-execution completion ratio, not task accuracy or goal success.
        /// Missing/interrupted measurements never silently enter the denominator.
        public var successFraction: Double? { measuredCount > 0 ? Double(successCount) / Double(measuredCount) : nil }
        public var outcomeCoverageFraction: Double? { totalCount > 0 ? Double(terminalOutcomeCount) / Double(totalCount) : nil }
    }

    public static func summarize(_ items: [WorkEvidenceItem], isPartial: Bool = false,
                                 includeLexicalHints: Bool = false, scopeID: String = "page") -> Summary {
        var groups: [String: [WorkEvidenceItem]] = [:]
        for item in items.prefix(maximumItems) where item.kind == .toolCall || item.kind == .toolResult {
            let native = item.kind == .toolResult ? item.relatedID : item.nativeID
            // Only an explicit relatedID joins a result to its call. Never
            // strip a suffix from a display ID or infer from timestamps.
            let identity = native.map { "call:" + $0 } ?? "unlinked:" + item.id
            let key = providerNamespace(item.id) + ":" + identity
            groups[key, default: []].append(item)
        }
        let executions = groups.map { key, records -> ToolExecution in
            let observations = records.map(observe)
            let known = Set(observations.map(\.outcome).filter { $0 != .unknown })
            let conflict = observations.contains(where: \.conflict) || known.count > 1
            let outcome = conflict ? .unknown : known.first ?? .unknown
            let calls = records.filter { $0.kind == .toolCall }
            let selected = calls.first ?? records[0]
            let callID = calls.compactMap(\.nativeID).first ?? records.compactMap(\.relatedID).first
            let times = records.compactMap(\.timestamp).filter { $0.timeIntervalSince1970.isFinite }
            return ToolExecution(id: scopeID + ":" + key, callID: callID,
                                 title: WorkEvidencePrivacy.preview(selected.title, maximumCharacters: 100),
                                 timestamp: times.min(), outcome: outcome,
                                 evidenceIDs: Array(Set(records.map(\.id))).sorted(), hasConflict: conflict,
                                 callNotInPage: calls.isEmpty, adapterVersion: adapterVersion)
        }.sorted {
            switch ($0.timestamp, $1.timestamp) {
            case let (a?, b?): return a == b ? $0.id < $1.id : a < b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return $0.id < $1.id
            }
        }
        var hints: [Hint] = [], seen = Set<String>()
        if includeLexicalHints {
            for item in items.prefix(maximumItems) where item.kind == .response {
                guard let text = item.preview else { continue }
                let kinds = lexicalKinds(text)
                for kind in HintKind.allCases where kinds.contains(kind) && hints.count < maximumHints {
                    let id = scopeID + ":" + item.id + ":" + kind.rawValue
                    guard seen.insert(id).inserted else { continue }
                    hints.append(Hint(id: id, kind: kind, evidenceIDs: [item.id],
                                      ruleID: "visible-agent-language/1:" + kind.rawValue, adapterVersion: adapterVersion))
                }
            }
        }
        return Summary(scopeID: scopeID, executions: executions, hints: hints,
                       isPartial: isPartial || items.count > maximumItems ||
                           executions.contains { $0.hasConflict || $0.callNotInPage || $0.outcome == .unknown },
                       adapterVersion: adapterVersion)
    }

    private struct Observation {
        var outcome: Outcome
        var conflict = false
    }
    private static func observe(_ item: WorkEvidenceItem) -> Observation {
        let status = item.status.lowercased().filter { $0.isLetter || $0.isNumber }
        if ["interrupted", "cancelled", "canceled", "aborted", "stopped"].contains(status) {
            return Observation(outcome: .interrupted)
        }
        let success = ["completed", "succeeded", "success", "successfullycompleted"].contains(status)
        let failure = ["failed", "failure", "error", "errored", "timedout", "timeout", "completedwitherror"].contains(status)
        if let code = item.exitCode {
            let exitedSuccessfully = code == 0
            if (success && !exitedSuccessfully) || (failure && exitedSuccessfully) {
                return Observation(outcome: .unknown, conflict: true)
            }
            return Observation(outcome: exitedSuccessfully ? .success : .failure)
        }
        return Observation(outcome: success ? .success : failure ? .failure : .unknown)
    }

    private static func providerNamespace(_ id: String) -> String {
        // The supported readers prefix ids with codex:item: / claude:item:.
        // Unknown adapters retain their full source prefix instead of merging.
        if let marker = id.range(of: ":item:") { return String(id[..<marker.lowerBound]) }
        return id
    }

    private static let completion = regex(#"\b(completed|succeeded|successful|successfully|worked(?!\s+(?:on|with|for|through|alongside)\b)|passed|fixed|resolved)\b"#)
    private static let failure = regex(#"\b(failed|failure|broken|unsuccessful|did not work|didn't work|didn’t work)\b"#)
    private static let didNotWork = regex(#"\b(did not work|didn't work|didn’t work)\b"#)
    private static let retry = regex(#"\b(try again|trying again|retried|retrying|retry|redo|redoing|redid|another attempt|second attempt|re-run|rerun|rerunning)\b"#)
    private static let correction = regex(#"\b(correction|correcting|corrected|reverted|reverting|undid|undoing|wrong assumption|misunderstood|misread)\b"#)
    private static let verification = regex(#"\b(verified|verifying|verification|validated|validating|checked|checking|checks?|tests?|test suite|assertions?)\b"#)
    private static let future = regex(#"\b(will|would|should|could|might|may|plan to|planning to|going to|if|unless|when)\b"#)
    private static let negation = regex(#"\b(no|not|never|without|zero|neither|didn't|doesn't|wasn't|weren't|isn't|hasn't|haven't|didn’t|doesn’t|wasn’t|weren’t|isn’t|hasn’t|haven’t)\b|\b0\s+(failures?|errors?)\b"#)
    private static let quotedContext = regex(#"\b(user said|you said|example|quoted|quote|search for|look for|words? like|pattern|regex|instructions?)\b"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // All patterns are static compile-time literals. A failed expression
        // would be a developer error, not user-supplied executable syntax.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    private static func removing(_ pattern: String, from text: String) -> String {
        text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
    }
    private static func lexicalKinds(_ raw: String) -> Set<HintKind> {
        // Opt-in previews are already redacted. Bound work again in case a
        // caller supplies a hand-made evidence item instead of a parser item.
        var text = String(raw.prefix(8_000))
        text = removing(#"(?s)```.*?(?:```|$)|~~~.*?(?:~~~|$)"#, from: text)
        text = removing(#"(?m)^\s*>.*$"#, from: text)
        text = removing(#"`[^`\n]*`|"[^"\n]*"|“[^”\n]*”|‘[^’\n]*’|(?<![\p{L}\p{N}])'[^'\n]+'(?![\p{L}\p{N}])"#, from: text)
        // A code block cut off by the preview budget must not become prose.
        text = removing(#"(?s)```.*$|~~~.*$"#, from: text)
        let separated = text.replacingOccurrences(of: #"(?i)\bbut\b|\band then\b"#, with: "\n", options: .regularExpression)
        let clauses = separated.components(separatedBy: CharacterSet(charactersIn: ".!?;\n"))
        var kinds = Set<HintKind>()
        for rawClause in clauses {
            let clause = rawClause.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clause.isEmpty, !matches(quotedContext, clause) else { continue }
            let isFuture = matches(future, clause)
            let isNegated = matches(negation, clause)
            if !isFuture && !isNegated && matches(completion, clause) { kinds.insert(.reportedCompletion) }
            if !isFuture && matches(failure, clause) && (!isNegated || matches(didNotWork, clause)) { kinds.insert(.reportedFailure) }
            if !isFuture && !isNegated && matches(retry, clause) { kinds.insert(.retryMention) }
            if !isFuture && !isNegated && matches(correction, clause) { kinds.insert(.correctionMention) }
            if !isFuture && !isNegated && matches(verification, clause) { kinds.insert(.verificationMention) }
        }
        return kinds
    }
}
