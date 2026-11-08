@testable import BridgeCore
import Foundation
import XCTest

final class PriceCatalogTests: XCTestCase {
    private func catalog() throws -> PriceCatalog {
        // The catalog shipped in packaging/ is the artifact under test — a
        // hand-written fixture here would pass while the real file was wrong.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // BridgeCoreTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // MenuBar/
            .deletingLastPathComponent()  // apps/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("packaging/price-catalog.json")
        let data = try Data(contentsOf: root)
        return try BridgeJSON.decoder.decode(PriceCatalog.self, from: data)
    }

    /// Derived rates come from a user's own billing export, so they never ship.
    /// This synthetic entry exercises how the calculator treats them; its
    /// ratios are deliberately not Anthropic's (see the ledger test below).
    private func derivedCatalog() throws -> PriceCatalog {
        let json = """
        {
          "schema_version": "1.0", "catalog_version": 1, "generated_at": "2026-08-01",
          "models": [
            {"model": "example-codex-model", "agent": "codex",
             "input": 2.0, "cache_read": 0.25, "cache_write_5m": 1.9, "cache_write_1h": 1.9, "output": 13.0,
             "provenance": "derived", "source": "Synthetic test fixture."},
            {"model": "claude-opus-5", "agent": "claude",
             "input": 5.0, "cache_read": 0.5, "cache_write_5m": 6.25, "cache_write_1h": 10.0, "output": 25.0,
             "provenance": "published", "source": "Synthetic copy of a published rate."}
          ]
        }
        """
        return try BridgeJSON.decoder.decode(PriceCatalog.self, from: Data(json.utf8))
    }

    private func usage(
        input: Int? = nil, cached: Int? = nil, written: Int? = nil, output: Int? = nil
    ) -> TokenUsage {
        TokenUsage(
            input: input, output: output, cachedInput: cached,
            cacheWriteInput: written, provenance: .providerReported
        )
    }

    func testShippedCatalogParsesAndCoversThePublishedModels() throws {
        let catalog = try catalog()
        for model in ["claude-opus-5", "claude-fable-5", "claude-sonnet-5"] {
            XCTAssertNotNil(catalog.price(for: model), "missing price for \(model)")
        }
    }

    func testShippedCatalogHoldsOnlyPublishedRates() throws {
        // Account-derived rates describe one person's subscription; they belong
        // in a local copy of the catalog, not in the shared repository.
        for price in try catalog().models {
            XCTAssertEqual(price.provenance, "published", "\(price.model) is not a published rate")
        }
    }

    func testAnthropicCacheTiersFollowThePublishedMultipliers() throws {
        let catalog = try catalog()
        for model in ["claude-opus-5", "claude-fable-5"] {
            let p = try XCTUnwrap(catalog.price(for: model))
            XCTAssertEqual(p.cacheRead, p.input * 0.1, accuracy: 0.0001, "\(model) cache read")
            XCTAssertEqual(p.cacheWrite5m, p.input * 1.25, accuracy: 0.0001, "\(model) 5m write")
            XCTAssertEqual(p.cacheWrite1h, p.input * 2.0, accuracy: 0.0001, "\(model) 1h write")
            XCTAssertEqual(p.output, p.input * 5.0, accuracy: 0.0001, "\(model) output")
        }
    }

    /// The ledger's billableEquivalent weights are Anthropic's price ratios.
    /// Codex does not price that way, and this pins the gap so a future edit
    /// cannot quietly re-unify them.
    func testCodexRatiosDivergeFromTheLedgersSharedWeights() throws {
        let codex = try XCTUnwrap(try derivedCatalog().price(for: "example-codex-model"))
        XCTAssertNotEqual(codex.cacheRead / codex.input, 0.1, accuracy: 0.005)
        XCTAssertNotEqual(codex.cacheWrite5m / codex.input, 1.25, accuracy: 0.01)
        XCTAssertNotEqual(codex.output / codex.input, 5.0, accuracy: 0.05)

        // What the ledger assumes, for contrast.
        let ledger = TokenComponents(freshInput: 1_000_000)
        XCTAssertEqual(ledger.billableEquivalent, 1_000_000)
        let asCacheRead = TokenComponents(cacheRead: 1_000_000)
        XCTAssertEqual(asCacheRead.billableEquivalent, 100_000, "ledger hardcodes 0.1x")
    }

    func testUnknownModelYieldsUnavailableRatherThanAGuess() throws {
        let cost = TurnCostCalculator.cost(
            usage: usage(input: 1000, output: 100),
            model: "gpt-unreleased",
            catalog: try catalog(),
            today: "2026-08-01"
        )
        XCTAssertNil(cost.usd)
        XCTAssertEqual(cost.provenance, .unavailable)
    }

    func testUnavailableUsageNeverBecomesAZeroDollarTurn() throws {
        var blank = TokenUsage()
        blank.provenance = .unavailable
        let cost = TurnCostCalculator.cost(
            usage: blank, model: "claude-opus-5", catalog: try catalog(), today: "2026-08-01"
        )
        XCTAssertNil(cost.usd, "a turn with no usage data must not price as $0")
        XCTAssertEqual(cost.provenance, .unavailable)
    }

    func testOpusPricesAgainstPublishedRates() throws {
        // 1M fresh + 1M cache read + 1M output = 5.00 + 0.50 + 25.00
        let cost = TurnCostCalculator.cost(
            usage: usage(input: 1_000_000, cached: 1_000_000, output: 1_000_000),
            model: "claude-opus-5",
            catalog: try catalog(),
            today: "2026-08-01"
        )
        XCTAssertEqual(try XCTUnwrap(cost.usd), 30.50, accuracy: 0.001)
    }

    func testSonnetIntroRateAppliesBeforeExpiryAndStandardRateAfter() throws {
        let catalog = try catalog()
        let sample = usage(input: 1_000_000, output: 1_000_000)

        let intro = TurnCostCalculator.cost(
            usage: sample, model: "claude-sonnet-5", catalog: catalog, today: "2026-08-01"
        )
        XCTAssertEqual(try XCTUnwrap(intro.usd), 12.0, accuracy: 0.001, "2.00 + 10.00 intro")
        XCTAssertNil(intro.caveat)

        let after = TurnCostCalculator.cost(
            usage: sample, model: "claude-sonnet-5", catalog: catalog, today: "2026-09-01"
        )
        XCTAssertEqual(try XCTUnwrap(after.usd), 18.0, accuracy: 0.001, "3.00 + 15.00 standard")
        XCTAssertNotNil(after.caveat, "an expired promotional rate must announce itself")
    }

    func testUnobservableCacheWriteDowngradesProvenanceAndFlagsALowerBound() throws {
        let cost = TurnCostCalculator.cost(
            usage: usage(input: 1_000_000, output: 0),
            model: "example-codex-model",
            catalog: try derivedCatalog(),
            today: "2026-08-01",
            cacheWriteObservable: false
        )
        XCTAssertEqual(cost.provenance, .estimated)
        XCTAssertNotNil(cost.caveat)
        XCTAssertTrue(try XCTUnwrap(cost.caveat).contains("lower bound"))
    }

    func testDerivedRatesAreNeverReportedAsStrongAsPublishedOnes() throws {
        let catalog = try derivedCatalog()
        let sample = usage(input: 1_000_000)
        let published = TurnCostCalculator.cost(
            usage: sample, model: "claude-opus-5", catalog: catalog, today: "2026-08-01"
        )
        let derived = TurnCostCalculator.cost(
            usage: sample, model: "example-codex-model", catalog: catalog, today: "2026-08-01"
        )
        XCTAssertEqual(published.provenance, .derived)
        XCTAssertEqual(derived.provenance, .estimated, "account-derived rates are weaker evidence")
    }
}
