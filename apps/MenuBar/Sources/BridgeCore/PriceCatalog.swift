import Foundation

/// Per-million-token rates for one model, as they appear in that provider's
/// billing — not a normalized weighting.
public struct ModelPrice: Codable, Equatable, Sendable {
    public var model: String
    public var agent: String
    public var input: Double
    public var cacheRead: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double
    public var output: Double
    /// `published` = the provider's own stated rate. `derived` = computed from
    /// a user's own billing export, so it is a blended effective rate for that
    /// subscription and not a list price. The shipped catalog holds only
    /// published rates; add derived ones to a local copy, never to the repo.
    public var provenance: String
    public var source: String
    /// Set when the rate is promotional. Past this date the entry is treated as
    /// stale rather than silently applied at the wrong price.
    public var expiresAt: String?
    public var standardAfterExpiry: StandardRates?

    public struct StandardRates: Codable, Equatable, Sendable {
        public var input: Double
        public var cacheRead: Double
        public var cacheWrite5m: Double
        public var cacheWrite1h: Double
        public var output: Double

        enum CodingKeys: String, CodingKey {
            case input, output
            case cacheRead = "cache_read"
            case cacheWrite5m = "cache_write_5m"
            case cacheWrite1h = "cache_write_1h"
        }
    }

    enum CodingKeys: String, CodingKey {
        case model, agent, input, output, provenance, source
        case cacheRead = "cache_read"
        case cacheWrite5m = "cache_write_5m"
        case cacheWrite1h = "cache_write_1h"
        case expiresAt = "expires_at"
        case standardAfterExpiry = "standard_after_expiry"
    }
}

/// A versioned, per-model price table.
///
/// This exists because the two providers do not price alike. The token ledger's
/// `billableEquivalent` weights (cache read 0.1x, cache write 1.25x, output 5x)
/// are exactly Anthropic's price ratios — applying them to Codex understates
/// output by ~24%, overstates cache write by ~33%, and understates cache read
/// by ~16% against measured Codex rates. Real cost has to come
/// from a table, not a shared constant.
public struct PriceCatalog: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var catalogVersion: Int
    public var generatedAt: String
    public var models: [ModelPrice]

    enum CodingKeys: String, CodingKey {
        case models
        case schemaVersion = "schema_version"
        case catalogVersion = "catalog_version"
        case generatedAt = "generated_at"
    }

    public func price(for model: String) -> ModelPrice? {
        models.first { $0.model == model }
    }

    /// Loads the catalog bundled with the app. Returns nil when absent — the
    /// caller must then report cost as unavailable rather than guessing, which
    /// is the posture the orchestrator already takes.
    public static func bundled(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> PriceCatalog? {
        guard let url = bundle.url(forResource: "price-catalog", withExtension: "json"),
              let data = fileManager.contents(atPath: url.path)
        else { return nil }
        return try? BridgeJSON.decoder.decode(PriceCatalog.self, from: data)
    }
}

/// Cost for one turn, with the provenance of the weakest input that produced it.
public struct TurnCost: Equatable, Sendable {
    public var usd: Double?
    public var provenance: MetricProvenance
    /// Set when a price was applied that carries a caveat the caller should
    /// surface — an expired promotional rate, or a rate derived from thin volume.
    public var caveat: String?
}

public enum TurnCostCalculator {
    /// Prices a turn against the catalog.
    ///
    /// Deliberately conservative in three places:
    /// 1. An unknown model returns `.unavailable`, never an extrapolation from a
    ///    sibling model — a wrong price is worse than no price.
    /// 2. Usage that the provider did not report is not treated as zero. Codex
    ///    reports `cache_write_input_tokens` as 0 in 99.7% of readings while
    ///    Azure bills real cache-write volume, so a zero there means "not
    ///    observable", and the result is downgraded to `.estimated`.
    /// 3. An expired promotional rate is applied at its post-expiry standard
    ///    rate, not the promotional one.
    public static func cost(
        usage: TokenUsage,
        model: String?,
        catalog: PriceCatalog?,
        today: String,
        cacheWriteObservable: Bool = true
    ) -> TurnCost {
        guard let catalog, let model, let entry = catalog.price(for: model) else {
            return TurnCost(usd: nil, provenance: .unavailable)
        }
        guard usage.provenance != .unavailable else {
            return TurnCost(usd: nil, provenance: .unavailable)
        }

        var rates = (
            input: entry.input,
            cacheRead: entry.cacheRead,
            cacheWrite: entry.cacheWrite5m,
            output: entry.output
        )
        var caveat: String?

        if let expiresAt = entry.expiresAt, today > expiresAt {
            guard let standard = entry.standardAfterExpiry else {
                return TurnCost(
                    usd: nil,
                    provenance: .unavailable,
                    caveat: "\(model): promotional rate expired \(expiresAt) with no successor rate."
                )
            }
            rates = (standard.input, standard.cacheRead, standard.cacheWrite5m, standard.output)
            caveat = "\(model): promotional rate expired \(expiresAt); billed at standard rate."
        }

        // Codex folds cached tokens into its input count; the ledger has already
        // netted them out into freshInput, so the fields here are disjoint.
        let fresh = usage.input ?? 0
        let cached = usage.cachedInput ?? 0
        let written = usage.cacheWriteInput ?? 0
        let out = usage.output ?? 0

        let usd = (Double(fresh) * rates.input
            + Double(cached) * rates.cacheRead
            + Double(written) * rates.cacheWrite
            + Double(out) * rates.output) / 1_000_000

        var provenance: MetricProvenance = entry.provenance == "published" ? .derived : .estimated
        if !cacheWriteObservable {
            provenance = .estimated
            let note = "\(model): provider does not report cache-write tokens, so cost is a lower bound."
            caveat = caveat.map { "\($0) \(note)" } ?? note
        }

        return TurnCost(usd: usd, provenance: provenance, caveat: caveat)
    }
}
