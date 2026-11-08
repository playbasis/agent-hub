import Foundation
import XCTest
@testable import BridgeCore
@testable import ClaudeCodexBridgeMenuBar

final class CreditHistoryPageModelTests: XCTestCase {
    private func snapshot(_ marker: String) -> CreditHistorySnapshot {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scope = CreditHistoryScope.anonymous("fixture")
        let report = CreditHistoryAnalytics.report(records: [], now: now, from: now.addingTimeInterval(-3600), to: now, scope: scope)
        return CreditHistorySnapshot(history: report, currentScope: scope, recordingWarning: marker)
    }
    @MainActor private func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Model did not settle",file:file,line:line)
    }

    @MainActor func testSameQueryFailureKeepsTheLastCompleteSnapshotAndReportsError() async throws {
        let first = snapshot("first")
        let queue = CreditReplyQueue(first)
        let model = CreditHistoryPageModel(reader: { _,_ in try await queue.next() })
        let client = BridgeAPIClient(configuration: try BridgeConfiguration.makeDefault())
        model.request(client:client,query:.init())
        await settle { model.snapshot == first && !model.loading }
        model.request(client:client,query:.init())
        await settle { model.error != nil && !model.loading }
        XCTAssertEqual(model.snapshot,first)
        model.deactivate()
    }

    @MainActor func testPendingScopeChangesCoalesceAndOldReplyCannotReplaceNewSelection() async throws {
        let first = snapshot("old"), last = snapshot("latest")
        let gate = CreditReplyGate(first:first,next:last)
        let model = CreditHistoryPageModel(reader:{ _, query in await gate.read(query) })
        let client = BridgeAPIClient(configuration: try BridgeConfiguration.makeDefault())
        model.request(client:client,query:.init(window:.day))
        for _ in 0..<1000 {
            if await gate.count() == 1 { break }
            await Task.yield()
        }
        model.request(client:client,query:.init(window:.week))
        model.request(client:client,query:.init(window:.all))
        await gate.release()
        await settle { model.snapshot == last && !model.loading }
        let queries = await gate.queries
        XCTAssertEqual(queries.map(\.window),[.day,.all])
        model.deactivate()
    }

    @MainActor func testReopenDuringCanceledReadRestartsOnlyTheLatestPendingWorker() async throws {
        let first = snapshot("canceled"), next = snapshot("reopened")
        let gate = CreditReplyGate(first:first,next:next)
        let model = CreditHistoryPageModel(reader:{ _,query in await gate.read(query) })
        let client = BridgeAPIClient(configuration: try BridgeConfiguration.makeDefault())
        model.request(client:client,query:.init())
        for _ in 0..<1000 {
            if await gate.count() == 1 { break }
            await Task.yield()
        }
        model.deactivate()
        model.request(client:client,query:.init(window:.week))
        await gate.release()
        await settle { model.snapshot == next && !model.loading }
        let count = await gate.count()
        XCTAssertEqual(count,2)
        model.deactivate()
    }
}

private actor CreditReplyQueue {
    let first: CreditHistorySnapshot
    var calls = 0
    init(_ first: CreditHistorySnapshot) { self.first = first }
    func next() throws -> CreditHistorySnapshot {
        calls += 1
        if calls == 1 { return first }
        throw BridgeError.network("Fixture read failed")
    }
}

private actor CreditReplyGate {
    let first: CreditHistorySnapshot
    let next: CreditHistorySnapshot
    var queries: [CreditHistoryQuery] = []
    var continuation: CheckedContinuation<CreditHistorySnapshot,Never>?
    init(first:CreditHistorySnapshot,next:CreditHistorySnapshot) { self.first=first; self.next=next }
    func read(_ query:CreditHistoryQuery) async -> CreditHistorySnapshot {
        queries.append(query)
        if queries.count == 1 { return await withCheckedContinuation { continuation = $0 } }
        return next
    }
    func count() -> Int { queries.count }
    func release() { continuation?.resume(returning:first); continuation=nil }
}
