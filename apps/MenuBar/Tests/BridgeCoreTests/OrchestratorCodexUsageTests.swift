@testable import BridgeCore
import Foundation
import XCTest

final class OrchestratorCodexUsageTests: XCTestCase {
    private func estimate(_ balance: String, offset: TimeInterval = 0) -> QuotaEstimate {
        QuotaEstimate(agent: .codex, source: .live,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000 + offset),
            credits: QuotaCredits(balance: balance, hasCredits: true, unlimited: false),
            accountIdentityHash: "same-account")
    }

    private func orchestrator(
        codex: @escaping @Sendable () async -> QuotaEstimate,
        others: @escaping @Sendable () async -> [QuotaEstimate] = { [] }
    ) throws -> Orchestrator {
        Orchestrator(configuration: try BridgeConfiguration.makeDefault(),
            configurationSaver: { _ in }, recoveryLoader: { nil }, recoverySaver: { _ in },
            nonCodexUsageReader: others, codexUsageReader: codex,
            planUsageLoader: { [:] }, planUsageSaver: { _ in })
    }

    /// Let already-launched callers reach the actor while the controlled
    /// provider read remains suspended. No real clock or provider is involved.
    private func drainCallers(_ orchestrator: Orchestrator) async {
        for _ in 0..<32 {
            await Task.yield()
            _ = await orchestrator.status()
        }
    }

    func testConcurrentNarrowRequestsShareOneCodexWorker() async throws {
        let started = expectation(description: "First Codex read entered")
        let gate = ControlledCodexReader(first: estimate("20"), next: estimate("10", offset: 1),
            onStart: { started.fulfill() })
        let service = try orchestrator(codex: { await gate.read() })
        let first = Task { await service.hydrateCodexUsage() }
        await fulfillment(of: [started], timeout: 2)
        let second = Task { await service.hydrateCodexUsage() }
        let third = Task { await service.hydrateCodexUsage() }
        await drainCallers(service)
        await gate.release()
        await first.value
        await second.value
        await third.value
        let calls = await gate.count()
        let status = await service.status()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(status.quota["codex"]?.credits?.balance, "20")
    }

    func testFullAndNarrowRefreshShareCodexWithoutReadingOtherProvidersTwice() async throws {
        let codexStarted = expectation(description: "Codex read entered")
        let othersStarted = expectation(description: "Other provider read entered")
        let codex = ControlledCodexReader(first: estimate("20"), next: estimate("10", offset: 1),
            onStart: { codexStarted.fulfill() })
        let others = ControlledOtherUsageReader(values: [QuotaEstimate(agent: .claude, source: .live)],
            onStart: { othersStarted.fulfill() })
        let service = try orchestrator(codex: { await codex.read() }, others: { await others.read() })
        let full = Task { await service.hydratePlanUsage() }
        await fulfillment(of: [codexStarted, othersStarted], timeout: 2)
        let narrow = Task { await service.hydrateCodexUsage() }
        await drainCallers(service)
        await codex.release()
        await narrow.value
        await others.release()
        await full.value
        let codexCalls = await codex.count()
        let otherCalls = await others.count()
        XCTAssertEqual(codexCalls, 1)
        XCTAssertEqual(otherCalls, 1)
    }

    func testSlowFullCompletionCannotRestoreAnOlderCodexBalance() async throws {
        let codexStarted = expectation(description: "Codex read entered")
        let othersStarted = expectation(description: "Other provider read entered")
        let old = estimate("20")
        let codex = ControlledCodexReader(first: old, next: estimate("10", offset: 1),
            onStart: { codexStarted.fulfill() })
        // Even an injected non-Codex reader returning an old Codex value must
        // not become a second writer for the Codex account snapshot.
        let others = ControlledOtherUsageReader(values: [old, QuotaEstimate(agent: .claude)],
            onStart: { othersStarted.fulfill() })
        let service = try orchestrator(codex: { await codex.read() }, others: { await others.read() })
        let full = Task { await service.hydratePlanUsage() }
        await fulfillment(of: [codexStarted, othersStarted], timeout: 2)
        await codex.release()
        var firstApplied = false
        for _ in 0..<1_000 {
            if await service.status().quota["codex"]?.credits?.balance == "20" {
                firstApplied = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(firstApplied, "First Codex result must apply while other providers remain suspended")
        await service.hydrateCodexUsage()
        let newer = await service.status()
        XCTAssertEqual(newer.quota["codex"]?.credits?.balance, "10")
        await others.release()
        await full.value
        let final = await service.status()
        let codexCalls = await codex.count()
        XCTAssertEqual(codexCalls, 2)
        XCTAssertEqual(final.quota["codex"]?.credits?.balance, "10")
    }

    func testShutdownCancelsCodexWorkerAndDiscardsItsLateResult() async throws {
        let started = expectation(description: "Codex read entered")
        let canceled = expectation(description: "Codex read canceled")
        let gate = ControlledCodexReader(first: estimate("20"), next: estimate("10", offset: 1),
            onStart: { started.fulfill() }, onCancel: { canceled.fulfill() })
        let service = try orchestrator(codex: { await gate.read() })
        let narrow = Task { await service.hydrateCodexUsage() }
        await fulfillment(of: [started], timeout: 2)
        let shutdown = Task { await service.shutdown() }
        await fulfillment(of: [canceled], timeout: 2)
        await gate.release()
        await shutdown.value
        await narrow.value
        let status = await service.status()
        XCTAssertNil(status.quota["codex"]?.credits)
    }
}

private actor ControlledCodexReader {
    private let first: QuotaEstimate
    private let next: QuotaEstimate
    private let onStart: @Sendable () -> Void
    private let onCancel: @Sendable () -> Void
    private var calls = 0
    private var pending: CheckedContinuation<QuotaEstimate, Never>?

    init(first: QuotaEstimate, next: QuotaEstimate,
         onStart: @escaping @Sendable () -> Void,
         onCancel: @escaping @Sendable () -> Void = {}) {
        self.first = first
        self.next = next
        self.onStart = onStart
        self.onCancel = onCancel
    }

    func read() async -> QuotaEstimate {
        calls += 1
        guard calls == 1 else { return next }
        onStart()
        let cancellation = onCancel
        return await withTaskCancellationHandler {
            await withCheckedContinuation { pending = $0 }
        } onCancel: {
            cancellation()
        }
    }

    func release() {
        pending?.resume(returning: first)
        pending = nil
    }

    func count() -> Int { calls }
}

private actor ControlledOtherUsageReader {
    private let values: [QuotaEstimate]
    private let onStart: @Sendable () -> Void
    private var calls = 0
    private var pending: CheckedContinuation<[QuotaEstimate], Never>?

    init(values: [QuotaEstimate], onStart: @escaping @Sendable () -> Void) {
        self.values = values
        self.onStart = onStart
    }

    func read() async -> [QuotaEstimate] {
        calls += 1
        guard calls == 1 else { return values }
        onStart()
        return await withCheckedContinuation { pending = $0 }
    }

    func release() {
        pending?.resume(returning: values)
        pending = nil
    }

    func count() -> Int { calls }
}
