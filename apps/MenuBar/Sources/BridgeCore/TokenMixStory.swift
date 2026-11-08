import Foundation

/// The headline a token breakdown supports. Agents re-send the conversation
/// with every step, so re-read context is usually almost all of the tokens
/// and a plain 100% bar shows one colour. This keeps that share as the
/// headline and the remaining parts as their own, readable split.
/// Presentation only: it reads the canonical breakdown and never re-sums it.
public struct TokenMixStory: Equatable, Sendable {
    public struct Part: Equatable, Sendable, Identifiable {
        public enum Kind: String, Sendable { case freshInput, cacheWrites, output }
        public var kind: Kind
        public var tokens: Int
        /// Share of the tokens that were not re-read.
        public var shareOfRemainder: Double
        public var id: String { kind.rawValue }
    }

    public var total: Int
    public var rereadShare: Double
    /// Re-read tokens for every written token; nil when nothing was written.
    public var rereadPerWritten: Double?
    public var remainder: [Part]

    /// Above this share a whole-breakdown bar is a single colour.
    public static let dominantShare = 0.9
    public var rereadDominates: Bool { rereadShare >= Self.dominantShare }

    public init?(_ breakdown: ActivityAccounting.Breakdown) {
        guard let total = breakdown.total, total > 0 else { return nil }
        self.total = total
        rereadShare = Double(breakdown.rereadContext) / Double(total)
        rereadPerWritten = breakdown.output > 0 ? Double(breakdown.rereadContext) / Double(breakdown.output) : nil
        let others: [(Part.Kind, Int)] = [(.freshInput, breakdown.freshInput), (.cacheWrites, breakdown.cacheWrites), (.output, breakdown.output)]
        let rest = others.reduce(0) { $0 + $1.1 }
        remainder = rest > 0 ? others.filter { $0.1 > 0 }.map { Part(kind: $0.0, tokens: $0.1, shareOfRemainder: Double($0.1) / Double(rest)) } : []
    }

    /// A share that never rounds a partial value up to 100% or down to 0%:
    /// "99.6%" near the top, "<1%" near the bottom, whole percents between.
    public static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "—" }
        if fraction <= 0 { return "0%" }
        if fraction >= 1 { return "100%" }
        if fraction < 0.01 { return "<1%" }
        if fraction >= 0.99 {
            let tenths = (fraction * 1_000).rounded(.down) / 10
            return tenths.formatted(.number.precision(.fractionLength(1))) + "%"
        }
        return "\(Int((fraction * 100).rounded()))%"
    }
}
